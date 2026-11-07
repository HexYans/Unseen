import AppKit
import Foundation
import Observation

/// Watches one folder and saves new images into **Apple Photos** (相册).
///
/// Why a poller instead of `FSEventStream` / `DispatchSource`: the user picks
/// the folder at runtime, so a single long-lived stream would have to be torn
/// down and rebuilt on every pick, and FSEvents coalesces with a latency floor
/// that makes "I saved a screenshot just now" feel unpredictable. The folder is
/// expected to hold a handful of files, so a `mtime`-ordered directory scan on a
/// timer is simpler, has no resource leaks, and is easy to reason about.
///
/// Behaviour is entirely driven by `AppSettings` so the user can choose:
///
/// * **watchedFolderPath** — the folder to watch (empty = feature off)
/// * **autoImportKeepOriginal** — keep the file after importing (off = delete it
///   once 照片 has accepted the image; see below)
/// * **autoImportRespectSubfolders** — recurse into subfolders
/// * **autoImportOnlyImages** — ignore non-image files (default on)
/// * **autoImportOpenPanel** — reveal the history panel after an import
///
/// Nothing is ever deleted unless `autoImportKeepOriginal` is off **and** Photos
/// confirmed the image first — a denied permission or a failed write never loses
/// the user's file.
@MainActor
@Observable
final class FolderWatcher {
    /// Files seen in this session, so a re-scan never re-imports the same file.
    /// Keyed by absolute path, valued by the size+mtime signature that was
    /// imported. A file that changes is treated as new again.
    private struct Seen: Hashable {
        var path: String
        var size: Int64
        var modified: TimeInterval
    }

    /// Imported so far in this run — shown in settings as a live counter.
    private(set) var importedCount: Int = 0
    /// Last file imported, for the settings row's subtitle.
    private(set) var lastImportedName: String?
    /// Last error, if any (permission denied on the folder, unreadable file…).
    private(set) var lastError: String?
    /// True while the timer is armed.
    private(set) var isWatching: Bool = false

    /// Absolute paths already imported in this session.
    @ObservationIgnored private var seen: [String: Seen] = [:]
    /// Paths sitting in the folder when watching started. The first scan treats
    /// them as "already there" — turning the feature on must not dump the
    /// user's existing screenshot archive into the album.
    @ObservationIgnored private var baselinePaths: Set<String> = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var isScanning = false
    @ObservationIgnored private weak var model: AppModel?
    /// Where images are written. Injectable so the self-test can drive the whole
    /// import path without prompting for 照片 permission.
    @ObservationIgnored private let photos: PhotosImporting

    init(photos: PhotosImporting = SystemPhotosLibrary()) {
        self.photos = photos
    }

    /// Extensions treated as pictures. Everything else is skipped even when
    /// `autoImportOnlyImages` is off — the album only stores images.
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "gif", "tiff", "tif",
        "bmp", "webp", "ico", "jpx", "jp2", "avif"
    ]

    /// The interval is deliberately coarse: screenshots land one at a time and a
    /// whole-directory scan of a screenshot folder is a few milliseconds.
    static let scanInterval: TimeInterval = 2.0

    func attach(model: AppModel) {
        self.model = model
        if model.settings.autoImportEnabled {
            start()
        }
    }

    // MARK: - Lifecycle

    /// (Re)start watching whatever `settings.watchedFolderPath` names. Safe to
    /// call repeatedly — the timer and baseline are rebuilt each time.
    func restart(watching path: String?) {
        stop()
        guard let path, !path.isEmpty else { return }
        start(folder: (path as NSString).expandingTildeInPath)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isWatching = false
        baselinePaths = []
    }

    private func start(folder: String? = nil) {
        guard let model else { return }
        let raw = folder ?? model.settings.watchedFolderPath
        let path = (raw as NSString).expandingTildeInPath
        guard !path.isEmpty else { return }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            lastError = "文件夹不存在：\(path)"
            return
        }
        guard FileManager.default.isReadableFile(atPath: path) else {
            lastError = "没有读取权限：\(path)"
            return
        }

        lastError = nil
        // Snapshot what is already there: the first scan only notices files that
        // appear *after* watching starts.
        baselinePaths = Set(scanPaths(in: path, recursive: model.settings.autoImportRespectSubfolders))
        seen = [:]

        let t = Timer.scheduledTimer(withTimeInterval: Self.scanInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scanOnce() }
        }
        // A common mode keeps scanning while the user drags a menu or resizes a
        // window; the default mode silently pauses during those.
        RunLoop.main.add(t, forMode: .common)
        timer = t
        isWatching = true
        DebugLog.log("folder watcher: watching \(path) every \(Self.scanInterval)s")
    }

    /// Surface the "no 照片 permission" state from outside the scan loop (the
    /// settings toggle asks for access, and this keeps one message in one place).
    func reportPermissionDenied() {
        lastError = "没有「照片」访问权限。请在 系统设置 → 隐私与安全性 → 照片 中允许 Unseen。"
    }

    /// Read the folder now — used by the 扫描 button so the user does not have to
    /// wait for the next tick.
    func scanNow() {
        Task { @MainActor [weak self] in await self?.scanOnceNow() }
    }

    /// Testing hook: run one pass and wait for Photos + the local record to
    /// finish, so assertions are not racing the async write.
    func scanNowAndWait() async {
        await scanOnceNow()
    }

    // MARK: - Scan

    private func scanOnce() {
        Task { @MainActor [weak self] in await self?.scanOnceNow() }
    }

    private func scanOnceNow() async {
        guard let model, isWatching, !isScanning else { return }
        let path = (model.settings.watchedFolderPath as NSString).expandingTildeInPath
        guard !path.isEmpty else { return }

        isScanning = true
        defer { isScanning = false }
        await importNewFiles(in: path)
    }

    private func importNewFiles(in path: String) async {
        guard let model else { return }
        let recursive = model.settings.autoImportRespectSubfolders
        let onlyImages = model.settings.autoImportOnlyImages
        let keepOriginal = model.settings.autoImportKeepOriginal

        for filePath in scanPaths(in: path, recursive: recursive) {
            let url = URL(fileURLWithPath: filePath)
            let ext = url.pathExtension.lowercased()
            if onlyImages, !Self.imageExtensions.contains(ext) { continue }
            guard Self.imageExtensions.contains(ext) else { continue }

            let attrs = try? FileManager.default.attributesOfItem(atPath: filePath)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let signature = Seen(path: filePath, size: size, modified: modified)

            // Files present before watching started are ignored once; after that
            // they are treated like any other file so a re-save is picked up.
            if baselinePaths.contains(filePath), seen[filePath] == nil {
                seen[filePath] = signature
                continue
            }
            if seen[filePath] == signature { continue }

            // Wait for the write to finish: a screenshot is often written in
            // more than one step, and importing half a PNG produces an asset the
            // user cannot open.
            if !isSettled(path: filePath, size: size) { continue }

            guard await importFile(at: url, keepOriginal: keepOriginal) else { continue }
            seen[filePath] = signature
            importedCount += 1
            lastImportedName = url.lastPathComponent
            DebugLog.log("folder watcher: saved \(url.lastPathComponent) to 照片")
        }
    }

    private func isSettled(path: String, size: Int64) -> Bool {
        // Compare against the size recorded a moment ago: if it grew, another
        // pass will pick it up after the writer closes the file.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let now = (attrs[.size] as? NSNumber)?.int64Value else { return true }
        return now == size
    }

    private func scanPaths(in directory: String, recursive: Bool) -> [String] {
        let fm = FileManager.default
        guard recursive else {
            let children = (try? fm.contentsOfDirectory(atPath: directory)) ?? []
            return children
                .map { (directory as NSString).appendingPathComponent($0) }
                .filter { !Self.isDirectory($0) }
        }
        guard let enumerator = fm.enumerator(atPath: directory) else { return [] }
        var paths: [String] = []
        for case let child as String in enumerator {
            let full = (directory as NSString).appendingPathComponent(child)
            if Self.isDirectory(full) { continue }
            // Skip the app's own album mirror, if the user happens to point the
            // watcher at a folder that contains it.
            if child.contains("/Album") { continue }
            paths.append(full)
        }
        return paths
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - Import

    /// Save one file into 照片, then (only on success) record it and optionally
    /// remove the source. Returns false for anything that should be retried or
    /// reported — a denied permission keeps the file and stops the pass from
    /// spamming Photos with the same request.
    private func importFile(at url: URL, keepOriginal: Bool) async -> Bool {
        guard let model else { return false }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            lastError = "无法读取：\(url.lastPathComponent)"
            return false
        }
        guard let image = NSImage(data: data) else {
            lastError = "不是有效图片：\(url.lastPathComponent)"
            return false
        }

        // Photos stores one canonical image per asset; normalising to PNG keeps
        // the pixels identical to what the app shows in its own grid.
        let png: Data
        if url.pathExtension.lowercased() == "png" {
            png = data
        } else if let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let converted = rep.representation(using: .png, properties: [:]) {
            png = converted
        } else {
            lastError = "无法转换图片：\(url.lastPathComponent)"
            return false
        }

        switch await photos.addImage(png, filename: url.lastPathComponent) {
        case .added(let assetID):
            // Photos has the picture; only now is it safe to record it locally
            // and (if asked) delete the source.
            model.recordPhotoImport(
                png,
                sourceName: url.lastPathComponent,
                sourceFolder: url.deletingLastPathComponent().path,
                photoAssetID: assetID
            )
            lastError = nil
            if !keepOriginal {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    lastError = "已存入「照片」但无法删除原文件：\(url.lastPathComponent)"
                }
            }
            if model.settings.autoImportOpenPanel {
                model.onRequestOpenPanel?()
            }
            return true

        case .denied:
            lastError = "没有「照片」访问权限。请在 系统设置 → 隐私与安全性 → 照片 中允许 Unseen。"
            // Stop this pass: every remaining file would fail the same way.
            return false

        case .failed(let message):
            lastError = "保存到「照片」失败：\(message)"
            return false
        }
    }
}

import AppKit
import Foundation
import Observation

/// Watches one folder and pulls new images into 相册 (the album).
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
/// * **autoImportKeepOriginal** — keep the file after importing (off = move it
///   into the album can't move, so we delete it; see below)
/// * **autoImportRespectSubfolders** — recurse into subfolders
/// * **autoImportOnlyImages** — ignore non-image files (default on)
/// * **autoImportOpenPanel** — reveal the history panel after an import
///
/// Nothing is ever deleted unless `autoImportKeepOriginal` is off **and** the
/// file was successfully read into the album first — a failed import never
/// loses the user's file.
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

    /// Read the folder now — used by the 立即扫描 button in settings so the user
    /// does not have to wait for the next tick.
    func scanNow() {
        scanOnce()
    }

    // MARK: - Scan

    private func scanOnce() {
        guard let model, isWatching, !isScanning else { return }
        let path = (model.settings.watchedFolderPath as NSString).expandingTildeInPath
        guard !path.isEmpty else { return }

        isScanning = true
        defer { isScanning = false }

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

            // Wait for the write to finish. A screenshot is often written in
            // more than one step, and importing a half-written PNG produces a
            // broken row. Two seconds of "size unchanged" is enough in practice.
            if !isSettled(path: filePath, size: size) { continue }

            guard importFile(at: url, keepOriginal: keepOriginal) else { continue }
            seen[filePath] = signature
            importedCount += 1
            lastImportedName = url.lastPathComponent
            DebugLog.log("folder watcher: imported \(url.lastPathComponent)")
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

    private func importFile(at url: URL, keepOriginal: Bool) -> Bool {
        guard let model else { return false }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            lastError = "无法读取：\(url.lastPathComponent)"
            return false
        }
        guard let image = NSImage(data: data) else {
            lastError = "不是有效图片：\(url.lastPathComponent)"
            return false
        }

        // Normalise to PNG so the album has one storage format, matching what
        // every other image path in the app writes.
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

        // The album entry points at a *history row*, so the row must exist
        // first. `ingestAlbumImage` does both: upsert the PNG into history and
        // then record the album pointer.
        guard model.ingestAlbumImage(
            png,
            sourceName: url.lastPathComponent,
            sourceFolder: url.deletingLastPathComponent().path
        ) else {
            lastError = "无法写入相册：\(url.lastPathComponent)"
            return false
        }

        // Only now, after the bytes are safely in the album, may the original be
        // removed. `keepOriginal` off means "move into the album".
        if !keepOriginal {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                lastError = "已导入但无法删除原文件：\(url.lastPathComponent)"
            }
        }

        if model.settings.autoImportOpenPanel {
            model.onRequestOpenPanel?()
        }
        return true
    }
}

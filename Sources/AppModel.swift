import AppKit
import Foundation
import Observation

/// Central coordinator: owns the database, the monitor and the observable list
/// the UI renders.
@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    /// Images pinned onto the screen (钉图).
    let pinboard: Pinboard
    /// Watches the user's chosen folder and saves new screenshots into 照片.
    let folderWatcher: FolderWatcher

    /// The system photo library, injectable for the self-test (which must not
    /// trigger a real 照片 permission prompt).
    let photos: PhotosImporting

    /// Album entries, newest first. Mirrors `AlbumStore` on disk; reloaded by
    /// `reloadAlbum()` after any add/delete.
    private(set) var album: [AlbumStore.AlbumRecord] = []

    private(set) var items: [ClipItem] = []
    private(set) var totalCount: Int = 0
    private(set) var lastError: String?
    private(set) var storageURL: URL

    var searchText: String = "" {
        didSet { if searchText != oldValue { rebuildFiltered() } }
    }
    var filter: ClipFilter = .all {
        didSet { if filter != oldValue { rebuildFiltered() } }
    }
    private(set) var filteredItems: [ClipItem] = []
    private(set) var selectedIndex: Int = 0
    var hotKeyError: String?

    /// Mirrors `AXIsProcessTrusted()`. Re-read on demand — the system does not
    /// push a notification when the user grants Accessibility access.
    private(set) var accessibilityTrusted: Bool = PasteboardWriter.isAccessibilityTrusted

    /// UI callbacks, wired up by `AppDelegate`.
    @ObservationIgnored var onRequestClose: (() -> Void)?
    @ObservationIgnored var onRequestMainWindow: (() -> Void)?
    @ObservationIgnored var onRequestQuit: (() -> Void)?
    @ObservationIgnored var onHotKeyChanged: (() -> Void)?
    /// Re-apply the Dock/accessory activation policy after the user toggles it.
    @ObservationIgnored var onRequestApplyActivationPolicy: (() -> Void)?
    /// Start one of the four capture modes. Wired by `AppDelegate` to the
    /// `CaptureCoordinator`, so SwiftUI pages never own a screenshot session.
    @ObservationIgnored var onRequestCapture: ((CaptureMode) -> Void)?
    /// 固定大小截图's start: the preset region (⌃⌥⌘E), which has no
    /// `CaptureMode` of its own. Also wired by `AppDelegate`.
    @ObservationIgnored var onRequestPresetCapture: (() -> Void)?
    /// Re-apply the camera picture-in-picture switch / position / size.
    @ObservationIgnored var onCameraSettingsChanged: (() -> Void)?
    /// Show the floating clipboard panel (相册's optional "import 后打开面板").
    @ObservationIgnored var onRequestOpenPanel: (() -> Void)?
    /// Jump to 设置 → 相册 (used by the album page's "去设置" button).
    @ObservationIgnored var onRequestOpenAlbumSettings: (() -> Void)?
    /// Show a one-off message (used when saving to 照片 fails, so the click is
    /// not silent). Wired to an alert by `AppDelegate`.
    @ObservationIgnored var onRequestShowMessage: ((String) -> Void)?

    var selectedItem: ClipItem? {
        filteredItems.indices.contains(selectedIndex) ? filteredItems[selectedIndex] : nil
    }

    /// 钉住 the floating panel: while true, losing key focus (switching apps)
    /// must not close it. Deliberately **not** persisted — `show()` resets it,
    /// so every presentation starts unpinned.
    var panelPinned = false

    @ObservationIgnored private var database: Database?
    @ObservationIgnored private var monitor: PasteboardMonitor?
    @ObservationIgnored private(set) var lastExternalApp: NSRunningApplication?

    /// Decoded thumbnails, keyed by row id. A `LazyVStack` rebuilds rows while
    /// scrolling and on every selection change; without this cache each rebuild
    /// re-read the PNG from SQLite and decoded it again.
    @ObservationIgnored private let thumbnailCache: NSCache<NSNumber, NSImage> = {
        let cache = NSCache<NSNumber, NSImage>()
        cache.countLimit = 400
        return cache
    }()
    /// The last few full previews, so clicking back and forth between entries
    /// does not re-parse the same 5 MB PNG each time.
    @ObservationIgnored private let previewCache: NSCache<NSNumber, NSImage> = {
        let cache = NSCache<NSNumber, NSImage>()
        cache.countLimit = 3
        return cache
    }()

    // MARK: - Lifecycle

    /// `~/Library/Application Support/Unseen`, overridable with the
    /// `UNSEEN_HOME` environment variable (portable / testing use).
    static func resolveStorageDirectory() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["UNSEEN_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        return support.appendingPathComponent("Unseen", isDirectory: true)
    }

    /// Where the pinned-image records live. Normally the app's own defaults;

    init(
        settings: AppSettings = AppSettings(),
        photos: PhotosImporting = SystemPhotosLibrary()
    ) {
        self.settings = settings
        self.photos = photos
        self.pinboard = Pinboard()
        self.folderWatcher = FolderWatcher(photos: photos)

        let directory = Self.resolveStorageDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.storageURL = directory.appendingPathComponent("history.sqlite")

        do {
            let database = try Database(path: storageURL.path)
            self.database = database
            try? database.prune(olderThanDays: settings.retentionDays)
            try? database.trim(maxItems: settings.maxItems)
        } catch {
            self.lastError = error.localizedDescription
        }

        let monitor = PasteboardMonitor(settings: settings)
        monitor.onCapture = { [weak self] payload in
            self?.store(payload)
        }
        monitor.fallbackSource = { [weak self] in
            guard let app = self?.lastExternalApp else { return (nil, nil) }
            return (app.localizedName, app.bundleIdentifier)
        }
        self.monitor = monitor

        observeApplications()
        reload()
        // Drop album records whose file vanished (a half-copied folder) before
        // anything renders them.
        _ = AlbumStore.pruneMissingFiles()
        reloadAlbum()
        startMonitoring()
        pinboard.attach(model: self)
        folderWatcher.attach(model: self)
    }

    func startMonitoring() {
        monitor?.start()
    }

    func stopMonitoring() {
        monitor?.stop()
    }

    /// Track the app the user was in before opening our panel, so "paste" has a
    /// target. Selector-based observers are used because they are delivered on
    /// the posting thread (main for NSWorkspace) and need no `Sendable` dance.
    private func observeApplications() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func applicationActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        lastExternalApp = app
    }

    // MARK: - Ingest

    private func store(_ payload: ClipPayload) {
        guard let database else { return }
        do {
            try database.upsert(hash: payload.contentHash, payload: payload)
            try database.trim(maxItems: settings.maxItems)
            reload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Reads

    func reload() {
        guard let database else { return }
        do {
            items = try database.fetch(limit: 500, retentionDays: settings.retentionDays)
            totalCount = try database.count()
            rebuildFiltered()
            DebugLog.log("reload: fetched=\(items.count) total=\(totalCount) filtered=\(filteredItems.count)")
        } catch {
            lastError = error.localizedDescription
            DebugLog.log("reload failed: \(error.localizedDescription)")
        }
    }

    /// How many rows each sidebar segment would show (respecting the search).
    func count(for filter: ClipFilter) -> Int {
        searchedItems.filter { filter.matches($0) }.count
    }

    private var searchedItems: [ClipItem] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return items }
        return items.filter { item in
            if let text = item.text, text.lowercased().contains(needle) { return true }
            if let app = item.sourceApp, app.lowercased().contains(needle) { return true }
            if item.fileURLs.contains(where: { $0.lowercased().contains(needle) }) { return true }
            if item.kind.displayName.lowercased().contains(needle) { return true }
            return false
        }
    }

    private func rebuildFiltered() {
        // `searchedItems` already applies the search predicate (or returns
        // every row when the field is empty); the segment filter is the only
        // extra step.
        filteredItems = searchedItems.filter { filter.matches($0) }
        // Keep the selection on a valid row.
        selectedIndex = filteredItems.isEmpty ? 0 : min(selectedIndex, filteredItems.count - 1)
    }

    /// Reset transient state each time the panel is opened.
    func prepareForPresentation() {
        searchText = ""
        filter = .all
        selectedIndex = 0
        // 钉住 is per-presentation, not a preference: a panel that stayed
        // pinned forever would quietly change what "click outside" means.
        panelPinned = false
        reload()
    }

    func moveSelection(by delta: Int) {
        guard !filteredItems.isEmpty else { return }
        let next = selectedIndex + delta
        selectedIndex = min(max(next, 0), filteredItems.count - 1)
    }

    func activateSelected() {
        guard let selectedItem else { return }
        activate(selectedItem)
    }

    /// Cached, already-decoded thumbnail for a list row.
    func thumbnailImage(for item: ClipItem) -> NSImage? {
        guard item.hasImage, let database else { return nil }
        let key = NSNumber(value: item.id)
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        guard let data = try? database.loadImage(id: item.id, thumbnail: true),
              let image = NSImage(data: data)
        else { return nil }
        thumbnailCache.setObject(image, forKey: key)
        return image
    }

    /// Cached full-size image for the preview pane.
    func previewImage(for item: ClipItem) -> NSImage? {
        guard item.hasImage else { return nil }
        let key = NSNumber(value: item.id)
        if let cached = previewCache.object(forKey: key) { return cached }
        guard let data = fullImage(for: item), let image = NSImage(data: data) else { return nil }
        previewCache.setObject(image, forKey: key)
        return image
    }

    func fullImage(for item: ClipItem) -> Data? {
        guard item.hasImage, let database else { return nil }
        return try? database.loadImage(id: item.id, thumbnail: false)
    }

    /// Image bytes for an arbitrary row id — used by the pinboard to restore
    /// pins whose entry may not be in the currently loaded window.
    func imageData(forItemID id: Int64) -> Data? {
        guard let database else { return nil }
        return try? database.loadImage(id: id)
    }

    /// Called after the pinboard writes to the pasteboard on our behalf.
    func syncMonitorChangeCount() {
        monitor?.syncChangeCount()
    }

    /// Move the selection to a specific row (main window list clicks).
    func select(_ item: ClipItem) {
        guard let index = filteredItems.firstIndex(where: { $0.id == item.id }) else { return }
        selectedIndex = index
    }

    // MARK: - Actions

    /// Put an entry back on the clipboard, and (optionally) paste it into the
    /// app the user was in before opening the panel.
    func activate(_ item: ClipItem) {
        copy(item, paste: settings.autoPaste)
    }

    func copy(_ item: ClipItem, paste: Bool) {
        guard let database else { return }
        let payload = ClipPayload(
            kind: item.kind,
            text: item.text,
            imagePNG: item.hasImage ? fullImage(for: item) : nil,
            thumbnailPNG: nil,
            fileURLs: item.fileURLs,
            sourceApp: item.sourceApp,
            bundleID: item.bundleID
        )

        PasteboardWriter.write(payload)
        monitor?.syncChangeCount()
        try? database.bumpCopyCount(id: item.id)

        // Close the panel first so the target app gets a clean foreground.
        onRequestClose?()

        guard paste else { return }

        if !PasteboardWriter.isAccessibilityTrusted {
            PasteboardWriter.requestAccessibilityAccess()
            return
        }
        guard let target = lastExternalApp, !target.isTerminated else { return }
        target.activate(options: [])
        // Give the target app a moment to become frontmost before the keystroke.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            PasteboardWriter.sendCommandV()
        }
    }

    // MARK: - 相册 (album)

    /// Re-read the album index from disk.
    func reloadAlbum() {
        album = AlbumStore.load()
        backfillAlbumRows()
        let resolvable = Set(albumItems.map(\.record.id))
        let orphaned = album.filter { !resolvable.contains($0.id) }
        if !orphaned.isEmpty {
            // The history row was deleted (or trimmed): the album copy can no
            // longer be previewed or pasted, so drop it rather than show a tile
            // that opens nothing.
            DebugLog.log("album: dropping \(orphaned.count) record(s) whose history row is gone")
            for record in orphaned { AlbumStore.delete(record) }
            album = AlbumStore.load()
        }
    }

    /// Album entries resolved against the loaded history rows.
    ///
    /// The album does not depend on the *window*: `items` only holds the newest
    /// 500 rows, so a record whose row has scrolled past it (or was pinned from
    /// an older page) would silently disappear from the grid even though its
    /// image is still on disk. Rows outside the window are fetched on demand by
    /// `reloadAlbum()`; anything still missing has genuinely been deleted, so it
    /// is dropped from the wheel and reported once.
    var albumItems: [(record: AlbumStore.AlbumRecord, item: ClipItem)] {
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return album.compactMap { record in
            guard let item = byID[record.itemID] else { return nil }
            return (record, item)
        }
    }

    /// Load the history rows the album points at but `items` does not contain —
    /// without them the 图片库 grid would render nothing.
    func backfillAlbumRows() {
        guard let database, !album.isEmpty else { return }
        let known = Set(items.map(\.id))
        let missing = album.map(\.itemID).filter { !known.contains($0) }
        guard !missing.isEmpty else { return }
        var extra: [ClipItem] = []
        for id in missing {
            if let row = try? database.item(id: id), row.hasImage { extra.append(row) }
        }
        guard !extra.isEmpty else { return }
        items.append(contentsOf: extra)
        DebugLog.log("album: backfilled \(extra.count) history row(s) for the album")
    }

    /// Save one history image into **Apple Photos**.
    ///
    /// Async work happens in a task because `PHPhotoLibrary.performChanges` is
    /// async; the menu action cannot await, so a failure surfaces through
    /// `onRequestShowMessage` (an alert) instead of silently doing nothing.
    func saveToPhotos(_ item: ClipItem) {
        guard item.hasImage else {
            onRequestShowMessage?("这张记录不是图片，无法存入「照片」。")
            return
        }
        guard let data = fullImage(for: item), !data.isEmpty else {
            onRequestShowMessage?("读取图片失败，无法存入「照片」。")
            DebugLog.log("photos: cannot read image bytes for item \(item.id)")
            return
        }
        if AlbumStore.load(for: item.id) != nil {
            // Already saved once; saving again would duplicate it in 照片.
            onRequestShowMessage?("这张图片已经存入「照片」了。")
            return
        }

        let name = "Unseen-\(item.id).png"
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch await self.photos.addImage(data, filename: name) {
            case .added(let assetID):
                self.recordPhotoImport(
                    data,
                    sourceName: nil,
                    sourceFolder: nil,
                    photoAssetID: assetID
                )
                // Keep the history row out of the trimmer's way, otherwise a busy
                // clipboard could drop it and the grid tile would lose its row.
                self.protectFromTrimming(item)
            case .denied:
                self.lastError = "没有「照片」访问权限。"
                self.onRequestShowMessage?(
                    "没有「照片」访问权限。\n请到 系统设置 → 隐私与安全性 → 照片 中允许 Unseen。"
                )
            case .failed(let message):
                self.lastError = "保存到「照片」失败：\(message)"
                self.onRequestShowMessage?("保存到「照片」失败：\(message)")
            }
        }
    }

    /// True when this history row already has a record of being saved to 照片.
    func isSavedToPhotos(_ item: ClipItem) -> Bool {
        AlbumStore.load(for: item.id) != nil
    }

    /// Persist a PNG that did not come from the clipboard (folder import): it
    /// becomes a normal history row first, then an album entry pointing at it.
    @discardableResult
    func recordPhotoImport(
        _ pngData: Data,
        sourceName: String?,
        sourceFolder: String?,
        photoAssetID: String?
    ) -> Bool {
        guard let database else { return false }
        let payload = ClipPayload(
            kind: .image,
            text: nil,
            imagePNG: pngData,
            thumbnailPNG: PasteboardMonitor.thumbnail(from: pngData, maxPixel: 160),
            fileURLs: [],
            sourceApp: "文件夹导入",
            bundleID: Bundle.main.bundleIdentifier
        )
        do {
            let id = try database.upsert(hash: payload.contentHash, payload: payload)
            try database.trim(maxItems: settings.maxItems)
            reload()
            guard AlbumStore.save(
                pngData: pngData,
                itemID: id,
                sourceName: sourceName,
                sourceFolder: sourceFolder,
                photoAssetID: photoAssetID
            ) != nil else { return false }
            reloadAlbum()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Remove an album entry (and its album file). The history row stays so a
    /// pasted image does not vanish from 历史记录 as a side effect.
    func removeFromAlbum(_ record: AlbumStore.AlbumRecord) {
        AlbumStore.delete(record)
        reloadAlbum()
    }

    func togglePin(_ item: ClipItem) {
        guard let database else { return }
        do {
            try database.setPinned(id: item.id, pinned: !item.pinned)
            reload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Screen pins (钉图)

    /// Pin an image entry onto the screen as a floating window.
    @discardableResult
    func pinToScreen(_ item: ClipItem) -> Bool {
        pinboard.pin(item)
    }

    /// A pinned image must not be aged out from under the pin.
    func protectFromTrimming(_ item: ClipItem) {
        guard !item.pinned, let database else { return }
        try? database.setPinned(id: item.id, pinned: true)
        reload()
    }

    func delete(_ item: ClipItem) {
        guard let database else { return }
        do {
            try database.delete(ids: [item.id])
            reload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func clearHistory(keepingPinned: Bool) {
        guard let database else { return }
        do {
            try database.clearAll(keepingPinned: keepingPinned)
            reload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func ignoreApp(bundleID: String) {
        guard !bundleID.isEmpty else { return }
        settings.ignoredBundleIDs.insert(bundleID)
    }

    func unignoreApp(bundleID: String) {
        settings.ignoredBundleIDs.remove(bundleID)
    }

    func revealStorageInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([storageURL])
    }

    /// Daily capture counts for the usage page.
    func dailyCounts(days: Int) -> [Date: Int] {
        guard let database else { return [:] }
        return (try? database.dailyCounts(days: days)) ?? [:]
    }

    /// Re-apply everything after a preference import / reset.
    func preferencesDidChange() {
        settingsDidChange()
        onHotKeyChanged?()
        onRequestApplyActivationPolicy?()
    }

    func dismissError() {
        lastError = nil
    }

    func presentError(_ message: String) {
        lastError = message
    }

    /// Called after settings that affect the poll loop change.
    func settingsDidChange() {
        monitor?.restart()
        if let database {
            try? database.prune(olderThanDays: settings.retentionDays)
            try? database.trim(maxItems: settings.maxItems)
        }
        reload()
    }

    /// Called after any 相册 · 监听文件夹 setting changes, so the watcher picks up
    /// a new folder, a new recursion flag or the master switch immediately
    /// instead of on the next launch.
    func albumSettingsDidChange() {
        guard settings.autoImportEnabled else {
            folderWatcher.stop()
            return
        }
        folderWatcher.restart(watching: settings.watchedFolderPath)
        // Turning the feature on is the moment to ask 照片 for add-only access:
        // doing it here means the prompt appears while the user is looking at
        // the switch, not silently on the first screenshot hours later.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let granted = await self.photos.requestAccess()
            if !granted {
                self.folderWatcher.reportPermissionDenied()
            }
        }
    }

    /// Called after the hotkey preference changes.
    func hotKeySettingsDidChange() {
        onHotKeyChanged?()
    }

    /// Re-query the Accessibility grant and publish the result to the UI.
    @discardableResult
    func refreshAccessibilityStatus() -> Bool {
        let trusted = PasteboardWriter.isAccessibilityTrusted
        if trusted != accessibilityTrusted {
            DebugLog.log("accessibility trust changed: \(accessibilityTrusted) -> \(trusted)")
        }
        accessibilityTrusted = trusted
        return trusted
    }
}

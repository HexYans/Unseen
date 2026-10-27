import AppKit
import CryptoKit
import Foundation


/// Polls `NSPasteboard.general.changeCount` and hands new content to a delegate.
///
/// macOS has no pasteboard-change notification, so polling is the only supported
/// approach for a non-jailbroken app. At the default 0.4s interval the cost is
/// negligible (one integer read on the main run loop).
@MainActor
final class PasteboardMonitor: NSObject {
    private var timer: Timer?
    private var lastChangeCount: Int

    private let settings: AppSettings

    /// Called for every new, non-ignored pasteboard payload.
    var onCapture: ((ClipPayload) -> Void)?

    /// Supplies (name, bundleID) to attribute a capture to when our own app is
    /// frontmost, e.g. while the history panel is open.
    var fallbackSource: (() -> (String?, String?))?

    init(settings: AppSettings) {
        self.settings = settings
        self.lastChangeCount = NSPasteboard.general.changeCount
        super.init()
    }

    var isRunning: Bool { timer != nil }

    func start() {
        stop()
        let timer = Timer(
            timeInterval: max(0.1, settings.pollInterval),
            target: self,
            selector: #selector(tick),
            userInfo: nil,
            repeats: true
        )
        // .common keeps polling alive while menus / resizing are tracking events.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func restart() {
        guard isRunning else { return }
        start()
    }

    /// Mark the current pasteboard state as "already seen" so our own writes
    /// are not captured as a fresh user copy.
    func syncChangeCount() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    @objc private func tick() {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        capture(from: pasteboard)
    }

    private func capture(from pasteboard: NSPasteboard) {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return }

        let declaredTypes = Set(items.flatMap { $0.types.map(\.rawValue) })
        if settings.ignoreConcealed, !declaredTypes.isDisjoint(with: AppSettings.concealedTypeMarkers) {
            return
        }

        let app = NSWorkspace.shared.frontmostApplication
        var sourceName = app?.localizedName
        var bundleID = app?.bundleIdentifier
        if bundleID == Bundle.main.bundleIdentifier, let fallback = fallbackSource?() {
            sourceName = fallback.0
            bundleID = fallback.1
        }
        if let bundleID, settings.effectiveIgnores.contains(bundleID) {
            return
        }

        var payload = ClipPayload(
            kind: .text,
            text: nil,
            imagePNG: nil,
            thumbnailPNG: nil,
            fileURLs: [],
            sourceApp: sourceName,
            bundleID: bundleID
        )

        // File URLs: the whole pasteboard is one logical clip (multi-file copy).
        if declaredTypes.contains(NSPasteboard.PasteboardType.fileURL.rawValue) {
            let readObjects = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL] ?? []
            let perItem = items.compactMap { item -> String? in
                guard let raw = item.string(forType: .fileURL), let url = URL(string: raw) else { return nil }
                return url.path
            }
            DebugLog.log("file-url branch readObjects=\(readObjects.count) perItem=\(perItem.count)")
            // `readObjects` can under-report for pasteboards written by other
            // processes, so fall back to walking the items ourselves.
            payload.fileURLs = readObjects.count >= perItem.count
                ? readObjects.map(\.path)
                : perItem
        }

        // Image data.
        if settings.captureImages,
           let imageData = Self.imageData(from: items, pasteboard: pasteboard),
           imageData.count <= settings.maxImageBytes {
            payload.imagePNG = imageData
            payload.thumbnailPNG = Self.thumbnail(from: imageData, maxPixel: 160)
        }

        // Plain text.
        if declaredTypes.contains(NSPasteboard.PasteboardType.string.rawValue) {
            payload.text = pasteboard.string(forType: .string)
        }

        guard !payload.isEmpty else {
            DebugLog.log("capture skipped (empty) types=\(declaredTypes.sorted())")
            return
        }
        payload.kind = Self.classify(payload, declaredTypes: declaredTypes)
        DebugLog.log("capture items=\(items.count) kind=\(payload.kind.rawValue) files=\(payload.fileURLs.count) image=\(payload.imagePNG?.count ?? 0) text=\((payload.text ?? "").count)")
        onCapture?(payload)
    }

    // MARK: - Helpers

    private static func classify(_ payload: ClipPayload, declaredTypes: Set<String>) -> ClipKind {
        let hasFiles = !payload.fileURLs.isEmpty
        let hasImage = payload.imagePNG != nil
        let hasText = !(payload.text ?? "").isEmpty

        let kinds = [hasFiles, hasImage, hasText].filter { $0 }.count
        if kinds > 1 { return .mixed }
        if hasFiles { return .files }
        if hasImage { return .image }
        if hasText {
            let richMarkers: Set<String> = [
                NSPasteboard.PasteboardType.rtf.rawValue,
                NSPasteboard.PasteboardType.rtfd.rawValue,
                NSPasteboard.PasteboardType.html.rawValue
            ]
            return declaredTypes.isDisjoint(with: richMarkers) ? .text : .richText
        }
        return .text
    }

    /// Prefer PNG; fall back to converting whatever image representation exists.
    private static func imageData(
        from items: [NSPasteboardItem],
        pasteboard: NSPasteboard
    ) -> Data? {
        for item in items {
            if let png = item.data(forType: .png) { return png }
        }
        if let png = pasteboard.data(forType: .png) { return png }

        let candidates: [NSPasteboard.PasteboardType] = [.tiff, .init("public.jpeg")]
        for item in items {
            for type in candidates {
                if let data = item.data(forType: type), let converted = pngData(from: data) {
                    return converted
                }
            }
        }
        return nil
    }

    private static func pngData(from data: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func thumbnail(from png: Data, maxPixel: CGFloat) -> Data? {
        guard let image = NSImage(data: png) else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        // Small images are already cheap: re-encoding would only inflate them.
        if max(size.width, size.height) <= maxPixel { return png }

        let scale = min(maxPixel / size.width, maxPixel / size.height)
        let target = NSSize(width: max(1, size.width * scale), height: max(1, size.height * scale))

        let thumbnail = NSImage(size: target)
        thumbnail.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: target),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1
        )
        thumbnail.unlockFocus()

        guard let tiff = thumbnail.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - Content hashing

extension ClipPayload {
    /// Stable identity of the payload, used to de-duplicate history rows.
    var contentHash: String {
        var hasher = SHA256()
        hasher.update(data: Data(kind.rawValue.utf8))
        if let text { hasher.update(data: Data(text.utf8)) }
        if let imagePNG { hasher.update(data: imagePNG) }
        for path in fileURLs { hasher.update(data: Data(path.utf8)) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

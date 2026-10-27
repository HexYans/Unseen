import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Everything that can go wrong between "the user confirmed a rectangle" and
/// actual pixels. The messages are user-facing; the capture page shows them
/// verbatim, so they must say what to do next.
enum CaptureError: LocalizedError {
    case screenRecordingDenied
    case noDisplay
    case windowNotFound
    case pinFailed
    case encodingFailed
    case shareableContentUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .screenRecordingDenied:
            return "还没有屏幕录制权限。请到 系统设置 → 隐私与安全性 → 屏幕录制 中勾选「Unseen」，然后重新启动本 App。"
        case .noDisplay:
            return "找不到要截取的显示器。"
        case .windowNotFound:
            return "窗口已经关闭或不再可截取。"
        case .pinFailed:
            return "钉图失败，无法创建浮动窗口。"
        case .encodingFailed:
            return "图片编码失败，无法保存。"
        case .shareableContentUnavailable(let detail):
            return "无法读取屏幕内容：\(detail)"
        }
    }
}

/// One captured frame plus the scale factor that maps its pixels to points.
struct CapturedScreenshot {
    let image: CGImage
    /// Pixels per point of the display the frame came from.
    let scale: CGFloat

    /// Logical (point) size — what the size indicator showed before the shot.
    var pointSize: CGSize {
        CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }

    /// `NSImage` at point size, so copying it to the pasteboard preserves the
    /// "300 × 200" the user selected instead of the 2× pixel dimensions.
    var nsImage: NSImage {
        NSImage(cgImage: image, size: pointSize)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
    }
}

/// One window as the window picker sees it.
///
/// `bounds` is in the **same coordinate space as the point passed to
/// `WindowPicker.pick(at:)`**. The instant-capture data source converts
/// Quartz's top-left frames into AppKit's bottom-left global points so the
/// picker and `NSEvent.mouseLocation` share one space; the overlay keeps them
/// in its own screen-local space.
struct WindowCandidate: Equatable, Sendable {
    let windowNumber: Int
    let bounds: CGRect
    let layer: Int
    let ownerPID: pid_t
    let ownerName: String
    /// Window title as the window server reports it (often empty for utility
    /// windows). The hover capsule prefers it over the owner name, matching
    /// iShot's window picker.
    var windowName: String = ""
    let isOwnedBySelf: Bool
}

/// What measuring a window's bitmap said about its real content.
///
/// iShot's `+[Global calcuateRealRectFromIMageRef:withOriginalRect:]` renders
/// the window and walks its pixels; a window whose opaque content collapses to
/// nothing is discarded instead of being captured as a ghost rectangle.
enum WindowContentProbe: Equatable, Sendable {
    /// No bitmap could be rendered for the window (no screen-recording grant,
    /// window gone, offscreen). iShot keeps the window in this case: it only
    /// drops a window when the probe returned an image whose content was empty.
    case unavailable
    /// The image existed but its content rect collapsed (`NSZeroRect`).
    case empty
    /// Real content rect, in the same coordinate space as `bounds`.
    case content(CGRect)
}

/// Why one window of the on-screen stack did not become the target.
///
/// The picker reports every drop so `DebugLog` can print a per-candidate
/// ledger; "the picker found nothing" then names the failing condition instead
/// of being guessed at.
enum WindowReject: String, Sendable {
    /// A window this process owns that is capture chrome — the overlay, the
    /// clipboard panel, a pin, the recording indicator, a HUD, the cue. The
    /// app's own main window is **not** rejected: it is ordinary content the
    /// user may screenshot (see `OwnWindowCapture`).
    case ownWindow
    /// iShot's hard-coded helper overlays: LyricsX, HazeOver, TencentMeeting,
    /// and the Window Server cursor.
    case helperOverlay
    /// Layer < 0 windows are the desktop; iShot only accepts them for the
    /// wallpaper windows themselves.
    case desktopNotWallpaper
    /// Layer 25 mirrors the cursor and duplicates the menu bar; iShot drops it
    /// only when its height matches a real menu-bar window.
    case cursorMirror
    /// The bitmap's opaque content was empty or thinner than 10 pt.
    case emptyContent
    /// The pointer was not inside the window's frame.
    case notUnderPointer
    /// The frame contained the pointer but the trimmed content rect did not —
    /// the window's real pixels are somewhere else (a Dock that reports a
    /// full-screen frame, a window whose only opaque part is a title bar).
    case contentElsewhere
}

/// The window the pointer selects plus the rectangle to highlight and capture.
struct WindowPick: Equatable, Sendable {
    let candidate: WindowCandidate
    /// Window bounds, or the trimmed content rect when the bitmap's opaque area
    /// differed from the frame by more than 5 pt (iShot's
    /// `mappingWindowByiShot` rect adjustment).
    let rect: CGRect
    let trimmed: Bool
}

/// One candidate's fate, for the debug ledger.
struct WindowPickRow: Equatable, Sendable {
    let windowNumber: Int
    let ownerName: String
    let windowName: String
    let layer: Int
    let bounds: CGRect
    /// `nil` when this row is the one the pointer selected.
    let reject: WindowReject?
}

/// Result of one hit test: the pick (if any) and every row that lost.
struct WindowPickOutcome: Equatable, Sendable {
    var pick: WindowPick?
    var rows: [WindowPickRow]

}

/// Own-process windows the window picker may still select.
///
/// The picker drops every window this process owns — the capture overlay, the
/// clipboard panel, pins, the recording indicator, HUDs, the cue ring — because
/// they are drawn *for* the capture: an overlay that picked itself would
/// photograph its own dimming layer. The app's **main window** is the one
/// exception. It is ordinary content (历史记录 / 设置 / 截图页), the user may
/// legitimately want to screenshot it, and it never covers the overlay.
///
/// The allow-list is derived from the live window rather than registered when
/// windows are created. A registered number can only go stale, and a deny-list
/// fails *open*: a future chrome window that nobody registered would become
/// capturable — exactly the "the shot contains our own overlay" bug. Deriving
/// the answer from `MainWindow` keeps every other own window excluded by
/// default, and a new capture window needs no code at all.
///
/// `MainWindowController` owns exactly one `MainWindow`; only a *visible* one
/// counts, because the picker can only ever see on-screen windows (and that
/// also keeps a closed window's number from enabling an unrelated window if
/// the window server ever reuses it).
@MainActor
enum OwnWindowCapture {
    /// The window numbers `WindowPicker` may select even though this process
    /// owns them. Empty until the app's main window is on screen.
    static var capturableWindowNumbers: Set<Int> {
        numbers(in: NSApp.windows)
    }

    /// The same rule over an explicit window list, so callers and the self test
    /// can state the policy without depending on what else is on screen.
    static func numbers(in windows: [NSWindow]) -> Set<Int> {
        var numbers: Set<Int> = []
        for window in windows where window is MainWindow {
            guard window.isVisible, window.windowNumber > 0 else { continue }
            numbers.insert(window.windowNumber)
        }
        return numbers
    }
}

/// Pure window hit-testing shared by the instant capture path (`⌃⌥⌘W`) and the
/// overlay's window picker/confirmation modes.
///
/// The rules are a line-by-line port of iShot's
/// `+[NSImage getImageWindowUnderMouse]` (0x10003e438). In order, for every
/// window of `CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly)`,
/// front-most first:
///
/// 1. skip windows this process owns, except the main window (documented
///    deviation: iShot has no such rule because its own capture surface is not
///    in the stack it walks). The exception is what lets the user screenshot
///    Unseen's own history/settings page; the overlay, panels, pins
///    and HUDs stay excluded. `OwnWindowCapture` is the allow-list;
/// 2. skip iShot's hard-coded helper overlays — LyricsX at layer 3 whose height
///    equals the pointer screen's height, the Window Server `Cursor` mirror,
///    TencentMeeting / 腾讯会议 at layer 1000, and HazeOver at layer 0 whose
///    height equals the pointer screen's height;
/// 3. skip negative layers unless the window is a wallpaper
///    (`Desktop Picture -…` / `Wallpaper-…`); the desktop is not capturable;
/// 4. skip layer 25 when its height matches a real menu bar;
/// 5. for layer ≥ 1 (other than the menu bar itself), measure the bitmap's
///    opaque content: drop the window when that content is under 10 pt on
///    either side, and otherwise use the content rect when it differs from the
///    frame by more than 5 pt;
/// 6. keep only windows whose rectangle contains the pointer;
/// 7. the first survivor wins (the list is front-to-back).
///
/// There is deliberately **no** "layer must be 0" rule and **no** 40 pt
/// minimum: those were guesses, and they are exactly why ordinary layered
/// windows (many Electron apps, HUD-style tool windows) were invisible to the
/// picker. iShot's only size rule is the 10 pt content floor.
enum WindowPicker {
    /// iShot hard-codes these owner names; nothing here is a heuristic.
    static let helperOverlayOwners: Set<String> = [
        "LyricsX", "HazeOver", "TencentMeeting", "腾讯会议", "Cursor"
    ]

    static func isSystemOverlay(ownerName: String) -> Bool {
        helperOverlayOwners.contains(ownerName)
            || ownerName == "Window Server"
            || ownerName == "WindowServer"
    }

    /// The picker in one call. `screenHeight` is the pointer screen's frame
    /// height (iShot uses `[NSScreen currentScreenForMouseLocation].frame`);
    /// `menubarHeights` are the `Height` values of the real menu-bar windows.
    /// `ownCapturableWindowNumbers` names the own-process windows that are
    /// content rather than capture chrome (production passes
    /// `OwnWindowCapture.capturableWindowNumbers`; the default `[]` rejects
    /// every own window, which keeps the pure rule explicit in tests).
    static func pick(
        at point: CGPoint,
        candidates: [WindowCandidate],
        ownPID: pid_t,
        ownCapturableWindowNumbers: Set<Int> = [],
        screenHeight: CGFloat = 0,
        menubarHeights: Set<Int> = [],
        probe: (WindowCandidate) -> WindowContentProbe = { _ in .unavailable }
    ) -> WindowPickOutcome {
        var rows: [WindowPickRow] = []

        func reject(_ candidate: WindowCandidate, _ reason: WindowReject) {
            rows.append(
                WindowPickRow(
                    windowNumber: candidate.windowNumber,
                    ownerName: candidate.ownerName,
                    windowName: candidate.windowName,
                    layer: candidate.layer,
                    bounds: candidate.bounds,
                    reject: reason
                )
            )
        }

        for candidate in candidates {
            // Own windows are capture chrome (overlay, panel, pins, HUDs) and
            // are dropped; the app's main window is content and falls through
            // to the ordinary rules below like any other application window.
            let ownedBySelf = candidate.isOwnedBySelf
                || (ownPID != 0 && candidate.ownerPID == ownPID)
            if ownedBySelf,
               !ownCapturableWindowNumbers.contains(candidate.windowNumber) {
                reject(candidate, .ownWindow)
                continue
            }

            if isHelperOverlay(candidate, screenHeight: screenHeight) {
                reject(candidate, .helperOverlay)
                continue
            }

            if candidate.layer < 0, !isWallpaper(candidate) {
                reject(candidate, .desktopNotWallpaper)
                continue
            }

            if candidate.layer == 25,
               menubarHeights.contains(Int(candidate.bounds.height.rounded())) {
                reject(candidate, .cursorMirror)
                continue
            }

            // Cheap hit test first: trimming only ever shrinks the rectangle,
            // so a pointer outside the frame cannot be inside the content.
            // This keeps the expensive bitmap probe off the mouse-move path.
            guard candidate.bounds.contains(point) else {
                reject(candidate, .notUnderPointer)
                continue
            }

            var rect = candidate.bounds
            var trimmed = false
            if candidate.layer >= 1, candidate.layer != 24 {
                switch probe(candidate) {
                case .unavailable:
                    break
                case .empty:
                    reject(candidate, .emptyContent)
                    continue
                case .content(let content):
                    // iShot: `if (w < 10 || h < 10) CFRelease; continue;`
                    guard content.width >= 10, content.height >= 10 else {
                        reject(candidate, .emptyContent)
                        continue
                    }
                    // iShot: only adopt the trimmed rect on a >5 pt mismatch.
                    if abs(content.width - candidate.bounds.width) > 5
                        || abs(content.height - candidate.bounds.height) > 5 {
                        rect = content
                        trimmed = true
                    }
                }
            }

            guard rect.contains(point) else {
                reject(candidate, trimmed ? .contentElsewhere : .notUnderPointer)
                continue
            }

            rows.append(
                WindowPickRow(
                    windowNumber: candidate.windowNumber,
                    ownerName: candidate.ownerName,
                    windowName: candidate.windowName,
                    layer: candidate.layer,
                    bounds: candidate.bounds,
                    reject: nil
                )
            )
            return WindowPickOutcome(
                pick: WindowPick(candidate: candidate, rect: rect, trimmed: trimmed),
                rows: rows
            )
        }

        return WindowPickOutcome(pick: nil, rows: rows)
    }

    /// Convenience wrapper for callers that only need the candidate.
    static func window(
        under point: CGPoint,
        candidates: [WindowCandidate],
        ownPID: pid_t,
        ownCapturableWindowNumbers: Set<Int> = [],
        screenHeight: CGFloat = 0,
        menubarHeights: Set<Int> = [],
        probe: (WindowCandidate) -> WindowContentProbe = { _ in .unavailable }
    ) -> WindowCandidate? {
        pick(
            at: point,
            candidates: candidates,
            ownPID: ownPID,
            ownCapturableWindowNumbers: ownCapturableWindowNumbers,
            screenHeight: screenHeight,
            menubarHeights: menubarHeights,
            probe: probe
        ).pick?.candidate
    }

    /// iShot's four hard-coded skips. Each one needs both the layer/name and,
    /// for the two full-screen helpers, the pointer screen's height — the same
    /// conjunction the binary uses, so a small LyricsX window stays pickable.
    private static func isHelperOverlay(
        _ candidate: WindowCandidate,
        screenHeight: CGFloat
    ) -> Bool {
        if candidate.layer == 3,
           candidate.ownerName == "LyricsX",
           screenHeight > 0,
           candidate.bounds.height == screenHeight {
            return true
        }
        if candidate.windowName == "Cursor",
           candidate.ownerName == "Window Server" || candidate.ownerName == "WindowServer" {
            return true
        }
        if candidate.layer == 1000,
           candidate.ownerName == "TencentMeeting" || candidate.ownerName == "腾讯会议" {
            return true
        }
        if candidate.layer == 0,
           candidate.ownerName == "HazeOver",
           screenHeight > 0,
           candidate.bounds.height == screenHeight {
            return true
        }
        return false
    }

    private static func isWallpaper(_ candidate: WindowCandidate) -> Bool {
        candidate.windowName.hasPrefix("Desktop Picture -")
            || candidate.windowName.hasPrefix("Wallpaper-")
            || candidate.ownerName.hasPrefix("Desktop Picture -")
            || candidate.ownerName.hasPrefix("Wallpaper-")
    }
}

/// Port of iShot's `+[Global calcuateRealRectFromIMageRef:withOriginalRect:]`
/// (0x10000d510): find the opaque content rectangle inside a window bitmap.
///
/// The source rasterises every 2 points, counts a sample as "content" when its
/// alpha byte is at least 0xA9, and returns `NSZeroRect` when more than 99 % of
/// the samples are translucent or when the whole bitmap is one uniform,
/// non-opaque colour. That zero rect is what `getImageWindowUnderMouse`
/// translates into "this window has no content, drop it".
enum WindowContentMeasure {
    /// Alpha threshold the binary compares against (`0xA9`).
    static let alphaFloor: UInt8 = 0xA9
    /// Content thinner than this on either side is discarded by the caller.
    static let minimumSide: CGFloat = 10

    /// - Parameters:
    ///   - image: the window bitmap (`CGWindowListCreateImage`).
    ///   - originalRect: the window frame; only its origin and width are used,
    ///     so the result comes back in the same coordinate space.
    /// - Returns: the content rect, or `.zero` when the bitmap is empty.
    static func contentRect(of image: CGImage, in originalRect: CGRect) -> CGRect {
        let pixelWidth = image.width
        let pixelHeight = image.height
        guard pixelWidth > 0, pixelHeight > 0, originalRect.width > 0 else { return .zero }
        guard let data = image.dataProvider?.data as Data? else { return .zero }

        let bytesPerRow = image.bytesPerRow
        let pixelStride = bytesPerRow / 4
        let scale = CGFloat(pixelWidth) / originalRect.width
        guard scale > 0, pixelStride >= pixelWidth else { return .zero }

        let step = max(1, Int((2 * scale).rounded()))
        var samples: CGFloat = 0
        var translucentSamples: CGFloat = 0
        var firstPixel = 0
        var uniform = true
        var allNonOpaque = true
        var minX = Int.max
        var maxX = Int.min
        var minY = Int.max
        var maxY = Int.min

        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            var y = 0
            while y < pixelHeight {
                var x = 0
                while x < pixelWidth {
                    let offset = y * bytesPerRow + x * 4
                    guard offset + 3 < raw.count else { break }
                    let alpha = bytes[offset + 3]
                    let pixel = Int(bytes[offset])
                        | Int(bytes[offset + 1]) << 8
                        | Int(bytes[offset + 2]) << 16
                        | Int(alpha) << 24
                    samples += 1
                    if x == 0, y == 0 {
                        firstPixel = pixel
                    } else if pixel != firstPixel {
                        uniform = false
                    }
                    if alpha == 0xFF { allNonOpaque = false }

                    if alpha < alphaFloor {
                        translucentSamples += 1
                    } else {
                        minX = min(minX, x)
                        maxX = max(maxX, x)
                        minY = min(minY, y)
                        maxY = max(maxY, y)
                    }
                    x += step
                }
                y += step
            }
        }

        guard samples > 0 else { return .zero }
        // iShot: `v25/v20 > 0.99 || (uniform && no fully-opaque pixel)`.
        if translucentSamples / samples > 0.99 || (uniform && allNonOpaque) { return .zero }
        guard minX <= maxX, minY <= maxY else { return .zero }

        let originX = (Int(CGFloat(minX) / scale + 0.5) - 2)
        let originY = (Int(CGFloat(minY) / scale + 0.5) - 2)
        let maxScaledX = Int(CGFloat(maxX) / scale + 0.5) + 2
        let maxScaledY = Int(CGFloat(maxY) / scale + 0.5) + 2
        return CGRect(
            x: originalRect.origin.x + CGFloat(originX),
            y: originalRect.origin.y + CGFloat(originY),
            width: CGFloat(abs(maxScaledX - originX)),
            height: CGFloat(abs(maxScaledY - originY))
        )
    }
}

/// Pixel acquisition through ScreenCaptureKit.
///
/// Only this type talks to ScreenCaptureKit. The overlay never captures; the
/// coordinator never knows about `SCDisplay`. Keeping the mapping between
/// AppKit's bottom-left screen coordinates and ScreenCaptureKit's top-left
/// display coordinates in one file is what stops the two conventions from
/// leaking into selection geometry.
@MainActor
enum ScreenCapture {
    // MARK: - Permission

    static var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Shows the system prompt the first time; afterwards it only reports the
    /// current state. The app may need a relaunch before the grant takes
    /// effect, which the error message says.
    @discardableResult
    static func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openScreenRecordingSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        )
        if let url {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Window exclusion

    /// Windows that must never appear in a screenshot, even when the caller
    /// asked to include own windows (the camera picture-in-picture is the
    /// reason this exists: it is deliberately visible on screen while the
    /// overlay is being used).
    ///
    /// Pinned images and the history panel are *not* registered here — those
    /// are content the user may legitimately want in a shot.
    private(set) static var excludedWindowNumbers: Set<CGWindowID> = []

    static func excludeWindow(_ windowNumber: Int) {
        guard windowNumber > 0 else { return }
        excludedWindowNumbers.insert(CGWindowID(windowNumber))
    }

    static func includeWindow(_ windowNumber: Int) {
        guard windowNumber > 0 else { return }
        excludedWindowNumbers.remove(CGWindowID(windowNumber))
    }

    // MARK: - Area / full screen

    /// Capture a global, bottom-left AppKit rectangle from one screen.
    ///
    /// The caller (the overlay controller) guarantees the rectangle is inside
    /// `screen.frame`; this method intersects defensively anyway.
    /// - Parameter excludingOwnWindows: omit every window owned by this process
    ///   from the frame. Scrolling capture keeps a HUD on screen while the
    ///   timer samples the page, and that HUD must never end up in the long
    ///   image (the overlay itself is closed before sampling starts).
    /// - Parameter excludingWindowIDs: extra windows to leave out of the frame.
    ///   Scrolling capture passes the auxiliary windows an app keeps pinned in
    ///   front of its page (a translate bubble, a floating toolbar): they do
    ///   not scroll with the page and would otherwise defeat the overlap
    ///   search on every frame.
    static func captureArea(
        _ globalRect: CGRect,
        on screen: NSScreen,
        includeCursor: Bool,
        excludingOwnWindows: Bool = false,
        excludingWindowIDs: Set<CGWindowID> = []
    ) async throws -> CapturedScreenshot {
        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            throw CaptureError.noDisplay
        }

        let clipped = globalRect.intersection(screen.frame)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else {
            throw CaptureError.noDisplay
        }

        // AppKit global coordinates are bottom-left; ScreenCaptureKit's
        // `sourceRect` is display-local with a top-left origin.
        let localTopLeft = CGRect(
            x: clipped.minX - screen.frame.minX,
            y: screen.frame.maxY - clipped.maxY,
            width: clipped.width,
            height: clipped.height
        )
        let scale = screen.backingScaleFactor

        // The user's rectangle, snapped to the display's **device-pixel grid**.
        //
        // A free-hand drag lands on fractional points (the pointer is sampled
        // continuously: 100.5 pt is an ordinary origin on a 2× display), and
        // ScreenCaptureKit maps `sourceRect` onto `width × height` with a
        // resampling filter. A rect whose edges sit between pixels therefore
        // smears every edge across two pixels: measured with a 1 px vertical
        // line and an 800.5 pt selection, the line came back as two ~45 % grey
        // columns (113/116) and the bitmap was 1599×1199 instead of 1600×1200.
        let pixelLeft = (localTopLeft.minX * scale).rounded()
        let pixelTop = (localTopLeft.minY * scale).rounded()
        let pixelRight = (localTopLeft.maxX * scale).rounded()
        let pixelBottom = (localTopLeft.maxY * scale).rounded()
        let pixelWidth = max(1, Int(pixelRight - pixelLeft))
        let pixelHeight = max(1, Int(pixelBottom - pixelTop))

        // Ask for a whole-*point* rectangle that contains those pixels.
        //
        // Even a pixel-aligned fractional `sourceRect` (100.5 pt on a 2×
        // display) is resampled by ScreenCaptureKit — only whole points come
        // back 1:1. The request is grown outward to the next whole point, which
        // adds at most one point per edge, and the crop below cuts that sliver
        // off again without any filtering.
        let screenPixelsWide = screen.frame.width * scale
        let screenPixelsHigh = screen.frame.height * scale
        let requestLeft = max(0, (pixelLeft / scale).rounded(.down) * scale)
        let requestTop = max(0, (pixelTop / scale).rounded(.down) * scale)
        let requestRight = min(screenPixelsWide, (pixelRight / scale).rounded(.up) * scale)
        let requestBottom = min(screenPixelsHigh, (pixelBottom / scale).rounded(.up) * scale)
        let requestWidth = max(1, Int(requestRight - requestLeft))
        let requestHeight = max(1, Int(requestBottom - requestTop))

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(
            x: requestLeft / scale,
            y: requestTop / scale,
            width: CGFloat(requestWidth) / scale,
            height: CGFloat(requestHeight) / scale
        )
        configuration.width = requestWidth
        configuration.height = requestHeight
        configuration.showsCursor = includeCursor
        configuration.captureResolution = .best

        // Two independent reasons to leave a window out:
        // 1. the caller asked to drop every window owned by this process
        //    (scrolling capture keeps a HUD up while sampling);
        // 2. the window is registered in `excludedWindowNumbers` (the camera
        //    picture-in-picture, which stays visible during the overlay).
        var excludedWindows: [SCWindow] = []
        var excludedIDs: Set<CGWindowID> = []
        if excludingOwnWindows {
            for window in content.windows
            where window.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier {
                excludedWindows.append(window)
                excludedIDs.insert(window.windowID)
            }
        }
        for window in content.windows
        where excludedWindowNumbers.contains(window.windowID) && !excludedIDs.contains(window.windowID) {
            excludedWindows.append(window)
            excludedIDs.insert(window.windowID)
        }
        for window in content.windows
        where excludingWindowIDs.contains(window.windowID) && !excludedIDs.contains(window.windowID) {
            excludedWindows.append(window)
            excludedIDs.insert(window.windowID)
        }
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        let captured = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )

        // Cut the exact selection out of the 1:1 request. Cropping copies whole
        // pixels, so the delivered bitmap is the requested pixels — the request
        // was only grown to whole points so ScreenCaptureKit would not filter it.
        let cropRect = CGRect(
            x: pixelLeft - requestLeft,
            y: pixelTop - requestTop,
            width: CGFloat(pixelWidth),
            height: CGFloat(pixelHeight)
        )
        if cropRect.minX >= 0, cropRect.minY >= 0,
           cropRect.maxX <= CGFloat(captured.width),
           cropRect.maxY <= CGFloat(captured.height),
           let cropped = captured.cropping(to: cropRect) {
            return CapturedScreenshot(image: cropped, scale: scale)
        }
        return CapturedScreenshot(image: captured, scale: scale)
    }

    static func captureFullScreen(
        _ screen: NSScreen,
        includeCursor: Bool
    ) async throws -> CapturedScreenshot {
        try await captureArea(screen.frame, on: screen, includeCursor: includeCursor)
    }

    // MARK: - Window

    static func captureWindow(
        _ windowID: CGWindowID,
        includeCursor: Bool = false
    ) async throws -> CapturedScreenshot {
        let content = try await shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound
        }

        let scale = screenScale(forQuartzFrame: window.frame)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((window.frame.width * scale).rounded()))
        configuration.height = max(1, Int((window.frame.height * scale).rounded()))
        configuration.showsCursor = includeCursor
        // A single window shot with its drop shadow looks like a sticker with a
        // grey halo on a white document; the pin/annotation stages want pixels.
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        return CapturedScreenshot(image: image, scale: scale)
    }

    // MARK: - Instant window picker

    /// The on-screen window stack plus the two window-server facts iShot's
    /// `getImageWindowUnderMouse` derives before it walks that stack.
    struct WindowStack: Sendable {
        var candidates: [WindowCandidate]
        /// `Height` of every real menu bar (`layer 24` + name `Menubar` +
        /// owner `Window Server`). iShot collects them first so the layer-25
        /// cursor mirror can be recognised by height.
        var menubarHeights: Set<Int>
        /// Height of the screen the pointer is on — the binary uses it for the
        /// LyricsX / HazeOver full-screen-helper tests.
        var screenHeight: CGFloat

        static let empty = WindowStack(candidates: [], menubarHeights: [], screenHeight: 0)
    }

    /// The on-screen window stack for `WindowPicker`, front-most first.
    ///
    /// This uses `CGWindowListCopyWindowInfo` rather than ScreenCaptureKit:
    /// it is synchronous, returns the exact z-order the window server uses and
    /// needs no SCShareableContent round-trip before the hit test (the pixels
    /// are still acquired through ScreenCaptureKit afterwards).
    ///
    /// The list is **not** pre-filtered the way the old implementation did.
    /// iShot walks every on-screen window and decides per window, which is what
    /// lets layered tool windows (layer ≥ 1) be captured at all; hiding them at
    /// the data source is what made the picker return "no window" over real
    /// apps. Filtering now lives in `WindowPicker.pick`, which also records why
    /// each window lost.
    ///
    /// Quartz frames are top-left relative to the primary display; the result
    /// is converted to AppKit global bottom-left points so it can be compared
    /// with `NSEvent.mouseLocation`.
    @MainActor
    static func instantWindowStack(
        ownPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> WindowStack {
        let options: CGWindowListOption = [.optionOnScreenOnly]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else {
            DebugLog.log("window-stack: CGWindowListCopyWindowInfo returned nothing")
            return .empty
        }

        let flipHeight = NSScreen.screens.first?.frame.maxY ?? 0
        var candidates: [WindowCandidate] = []
        var menubarHeights: Set<Int> = []

        for info in raw {
            guard let number = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let quartz = CGRect(dictionaryRepresentation: boundsInfo) else {
                continue
            }
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            let title = info[kCGWindowName as String] as? String ?? ""

            // Pass 1 of the binary: the menu bar heights.
            if layer == 24, title == "Menubar",
               owner == "Window Server" || owner == "WindowServer" {
                menubarHeights.insert(Int(quartz.height.rounded()))
            }

            // Quartz: y grows down from the primary display's top edge.
            // AppKit: y grows up from its bottom edge.
            let bounds = CGRect(
                x: quartz.minX,
                y: flipHeight - quartz.maxY,
                width: quartz.width,
                height: quartz.height
            )
            candidates.append(
                WindowCandidate(
                    windowNumber: number,
                    bounds: bounds,
                    layer: layer,
                    ownerPID: pid,
                    ownerName: owner,
                    windowName: title,
                    isOwnedBySelf: pid == ownPID
                )
            )
        }

        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        return WindowStack(
            candidates: candidates,
            menubarHeights: menubarHeights,
            screenHeight: screen?.frame.height ?? 0
        )
    }

    /// Memoised `windowContentProbe` results.
    ///
    /// The probe renders the whole window, and the hover path asks on every
    /// mouse move. A 0.25 s memo (invalidated by a bounds change) keeps a
    /// full-screen window such as the Dock's from being re-rasterised 60 times
    /// a second while the pointer crosses the desktop.
    private struct ProbeMemo {
        let bounds: CGRect
        let at: TimeInterval
        let probe: WindowContentProbe
    }
    private static var probeMemo: [Int: ProbeMemo] = [:]

    /// iShot's content probe for one window: render it, then measure the opaque
    /// area. `.unavailable` when the window server refuses the bitmap, which
    /// keeps the window pickable (only a *measured* empty window is dropped).
    @MainActor
    static func windowContentProbe(
        for candidate: WindowCandidate,
        maxAge: TimeInterval = 0.25
    ) -> WindowContentProbe {
        let now = ProcessInfo.processInfo.systemUptime
        if let memo = probeMemo[candidate.windowNumber],
           memo.bounds == candidate.bounds,
           now - memo.at < maxAge {
            return memo.probe
        }
        let probe = measureWindowContent(for: candidate)
        if probeMemo.count > 64 { probeMemo.removeAll(keepingCapacity: true) }
        probeMemo[candidate.windowNumber] = ProbeMemo(
            bounds: candidate.bounds,
            at: now,
            probe: probe
        )
        return probe
    }

    private static func measureWindowContent(
        for candidate: WindowCandidate
    ) -> WindowContentProbe {
        guard CGPreflightScreenCaptureAccess() else { return .unavailable }
        let id = CGWindowID(candidate.windowNumber)
        // `CGWindowListCreateImage` is deprecated in favour of ScreenCaptureKit,
        // but SCK is async and screen-wide; iShot's rule is evaluated per window
        // inside the picker, so the synchronous window image is the honest port.
        guard id > 0,
              let image = CGWindowListCreateImage(
                  .null,
                  .optionIncludingWindow,
                  id,
                  [.boundsIgnoreFraming]
              )
        else {
            return .unavailable
        }
        let rect = WindowContentMeasure.contentRect(of: image, in: candidate.bounds)
        guard rect.width >= 1, rect.height >= 1 else { return .empty }
        return .content(rect)
    }

    // MARK: - Streaming lookup

    /// The ScreenCaptureKit display for an AppKit screen plus every window
    /// owned by this process.
    ///
    /// The recorder builds its `SCContentFilter` from these: passing the
    /// current own-window list keeps the recording indicator, the history
    /// panel and pinned images out of the video. The filter snapshots the list,
    /// so callers that want the HUD excluded must order it on screen *before*
    /// starting the stream.
    static func displayAndOwnWindows(
        matching screen: NSScreen,
        keepingWindowNumbers: Set<CGWindowID> = []
    ) async throws -> (display: SCDisplay, ownWindows: [SCWindow]) {
        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            throw CaptureError.noDisplay
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // `keepingWindowNumbers` is the camera overlay: it is registered for
        // screenshot exclusion but must stay in the recording.
        let ownWindows = content.windows.filter {
            $0.owningApplication?.processID == ownPID
                && !keepingWindowNumbers.contains($0.windowID)
        }
        return (display, ownWindows)
    }

    // MARK: - Shared plumbing

    private static func shareableContent() async throws -> SCShareableContent {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw CaptureError.screenRecordingDenied
        }
        do {
            return try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            throw CaptureError.shareableContentUnavailable(error.localizedDescription)
        }
    }

    /// Which display a Quartz (top-left) window frame sits on, and its scale.
    private static func screenScale(forQuartzFrame frame: CGRect) -> CGFloat {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let centre = CGPoint(x: frame.midX, y: primaryHeight - frame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(centre) } ?? NSScreen.main
        return screen?.backingScaleFactor ?? 2
    }
}

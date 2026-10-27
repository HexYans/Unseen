import AppKit
import Observation

/// The capture entry points exposed by the hotkey, menu and capture page.
///
/// `.window` is iShot's **confirmation** window mode: it opens the region
/// overlay in a window-only state (hover highlight, single click confirms).
/// The zero-UI instant shot stays separate: `⌃⌥⌘W` /
/// `InstantCaptureKind.window` never presents an overlay.
enum CaptureMode: String, CaseIterable, Identifiable, Sendable {
    case region
    case window
    case fullScreen

    var id: String { rawValue }

    var title: String {
        switch self {
        // iShot 的叫法：框选截图就叫「截图」；窗口/全屏保留原本的两字段。
        case .region: "截图"
        case .window: "窗口截图"
        case .fullScreen: "全屏截图"
        }
    }

    var symbol: String {
        switch self {
        case .region: "rectangle.dashed"
        case .window: "macwindow.on.rectangle"
        case .fullScreen: "rectangle.inset.filled"
        }
    }

    var detail: String {
        switch self {
        case .region:
            "拖拽框选区域，方向键逐个像素微调；回车拷贝，Esc 或右键退出。"
        case .window:
            "悬停高亮光标下的窗口，单击即截图，Esc 或右键退出。"
        case .fullScreen:
            "直接截取鼠标所在屏幕，不显示覆盖层。"
        }
    }

    /// One short line for the capture page's mode column.
    var shortDetail: String {
        switch self {
        case .region: "框选任意区域"
        case .window: "截图光标下的窗口"
        case .fullScreen: "整屏直接拷贝"
        }
    }
}

/// What to do with the pixels once they exist.
private enum CaptureDelivery {
    case copy
    case save
    case saveAs
    case pin
    case ocr
}

/// Entry orchestration: mode dispatch, overlay lifecycle, pixel delivery.
///
/// The only type that knows about all three modes. It talks to `ScreenCapture`
/// for pixels, `CaptureOverlayController` for selection, and `Pinboard` /
/// `NSPasteboard` / the file system for delivery.
@MainActor
@Observable
final class CaptureCoordinator {
    private let model: AppModel?
    private let settings: AppSettings
    private var overlay: CaptureOverlayController?
    /// Retained while the instant-capture confirmation ring fades out.
    private var instantCue: InstantCaptureCueController?
    /// Retained while the OCR result card is on screen; closing it releases.
    private var ocrWindow: OCRResultWindowController?
    /// One scrolling-capture session at a time.
    private var scrollController: ScrollCaptureController?
    /// The scrolling overlay's view. Kept because the session lives *inside*
    /// the same panel: the selection, the toolbar and the fixed viewfinder all
    /// stay visible until the user closes the result.
    private weak var scrollOverlayView: CaptureOverlayView?
    private var scrollRegion: CGRect?
    private var scrollScreen: NSScreen?
    /// The last stitched image, before annotations. 拷贝 (keep) uses this while
    /// the session is still running.
    private var scrollLiveShot: CapturedScreenshot?
    /// The final stitched image, kept after 停止 so toolbar actions pressed on
    /// the finished result still deliver.
    private var scrollFinalShot: CapturedScreenshot?
    /// The final image *before* annotations, so a tool action pressed after
    /// the session has stopped can still bake in the latest drawing.
    private var scrollFinalRaw: (image: CGImage, scale: CGFloat)?
    /// A terminal toolbar action that asked for the session to finish first.
    private var scrollPendingAction: CaptureToolbarAction?
    /// The confirmation that arrived while the compose was still running.
    ///
    /// The session stops sampling before it composes, so for that window its
    /// `isRunning` is already false while there is no result yet. Return, 完成
    /// or the shortcut pressed in that window used to close the overlay and
    /// throw the picture away; they are queued here instead and answered by
    /// `handleScrollFinished`.
    private var scrollConfirmWhenComposed = false
    /// Present only while a delayed screenshot counts down.
    private var delayController: DelayCountdownController?

    /// One recording session at a time. `nil` while idle.
    private var recorder: ScreenRecorder?
    private var recordingIndicator: RecordingIndicatorController?
    /// 录制中: the region selector that confirmed the stream. It stays on screen
    /// as the recording UI (mask, border, handles, size chip, crosshair) with
    /// its toolbar replaced by the recording HUD; this reference is what lets
    /// stop/failure close it again.
    private var recordingOverlay: CaptureOverlayController?
    private var recordingTicker: Task<Void, Never>?
    /// Mirrors the recorder's state for the status bar, menu and capture page.
    private(set) var recordingState: RecordingState = .idle
    private(set) var recordingElapsedText = "00:00"
    /// Present only while the colour picker is on screen.
    private var colorPicker: ColorPickerController?
    /// Present only while keys should be shown on screen.
    private var keyDisplay: KeyDisplayController?
    /// Present only while the 套壳 / 美化 preview is open.
    private var beautifyWindow: BeautifyWindowController?
    /// Present only while the camera picture-in-picture is on screen.
    private var cameraOverlay: CameraOverlayController?
    /// True when the camera was started by a recording rather than the menu, so
    /// stopping the recording also removes it.
    private var cameraAutoStarted = false

    /// Status-bar mirror, wired by `AppDelegate`. Called on every tick while a
    /// session is live and once on each transition.
    @ObservationIgnored var onRecordingChanged: ((RecordingState, String) -> Void)?

    /// True while ScreenCaptureKit is working, so a second hotkey press cannot
    /// stack two captures.
    private(set) var isBusy = false
    /// Short human-readable result for the capture page / debug log.
    private(set) var lastMessage: String?
    private(set) var lastErrorMessage: String?

    init(model: AppModel) {
        self.model = model
        self.settings = model.settings
    }

    /// Test-only entry: the instant path needs preferences and pixels, not the
    /// clipboard history. Keeping the model optional lets the self test drive
    /// the real coordinator without opening the user's database or starting the
    /// pasteboard monitor.
    init(settings: AppSettings) {
        self.model = nil
        self.settings = settings
    }

    var screenRecordingGranted: Bool {
        ScreenCapture.hasScreenRecordingPermission
    }

    // MARK: - Entry points

    /// Which surface each mode uses. Pure, so the self test can prove the
    /// routing without starting a ScreenCaptureKit capture.
    enum CaptureEntry: Equatable {
        /// Region overlay with drag selection (and the single-click window path).
        case regionOverlay
        /// iShot's confirmation window mode: the same overlay, but window-only —
        /// hover highlights the window under the pointer, one click captures it,
        /// Esc / right-click leaves. No rectangle, no drag.
        case windowOverlay
        /// Direct full-screen capture with no overlay (`fullScreen`).
        case directScreen
    }

    static func entry(for mode: CaptureMode) -> CaptureEntry {
        switch mode {
        case .region: .regionOverlay
        // `窗口截图` is a *confirmation* surface, not the instant hot key.
        // `⌃⌥⌘W` stays on `instant(.window)`; the two share the picker, not the
        // UI. This is the split the user asked for: one silent, one confirmed.
        case .window: .windowOverlay
        case .fullScreen: .directScreen
        }
    }

    /// The three modes all present a surface now; the zero-UI instant path is
    /// `startInstant` and is reached only from `⌃⌥⌘W` / `⌃⌥⌘F`.
    @discardableResult
    func start(_ mode: CaptureMode) -> Task<InstantCaptureResult, Never>? {
        guard !isBusy, overlay == nil else {
            DebugLog.log("capture: ignored \(mode.rawValue), already busy")
            return nil
        }

        switch Self.entry(for: mode) {
        case .regionOverlay:
            // Ask once; if it is already denied macOS shows the settings
            // guidance itself and the capture attempt reports the error.
            if !ScreenCapture.hasScreenRecordingPermission {
                ScreenCapture.requestScreenRecordingPermission()
            }
            DebugLog.log("capture: start mode=\(mode.rawValue)")
            presentOverlay(mode: .region, prefill: nil)
            return nil

        case .windowOverlay:
            if !ScreenCapture.hasScreenRecordingPermission {
                ScreenCapture.requestScreenRecordingPermission()
            }
            DebugLog.log("capture: start mode=\(mode.rawValue) (window confirmation overlay)")
            presentOverlay(mode: .region, prefill: nil, startsInWindowPick: true)
            return nil

        case .directScreen:
            if !ScreenCapture.hasScreenRecordingPermission {
                ScreenCapture.requestScreenRecordingPermission()
            }
            DebugLog.log("capture: start mode=\(mode.rawValue)")
            captureFullScreenNow()
            return nil
        }
    }

    func cancel() {
        overlay?.close()
        overlay = nil
        restoreFocusAfterCapture()
    }

    /// True while a selection surface is on screen. The instant path must leave
    /// this false from start to finish; the self test asserts it.
    var isOverlayPresenting: Bool { overlay != nil }

    // MARK: - Instant capture (no UI)

    /// Capture immediately, with no overlay, no confirmation and no focus
    /// change. The returned task finishes after the pasteboard has been written
    /// (and, when enabled, the ring has been ordered in), so the self test can
    /// await the whole path.
    ///
    /// `pointer` and `candidates` are test seams: production passes neither, so
    /// the pointer comes from `NSEvent.mouseLocation` and the window stack from
    /// `CGWindowListCopyWindowInfo`.
    @discardableResult
    func startInstant(
        _ kind: InstantCaptureKind,
        pointer: CGPoint? = nil,
        candidates: [WindowCandidate]? = nil
    ) -> Task<InstantCaptureResult, Never>? {
        guard !isBusy, overlay == nil else {
            DebugLog.log("instant: ignored \(kind.rawValue), another capture surface is busy")
            NSSound.beep()
            return nil
        }

        if !ScreenCapture.hasScreenRecordingPermission {
            ScreenCapture.requestScreenRecordingPermission()
        }

        isBusy = true
        DebugLog.log(
            "instant: start \(kind.rawValue) pointer="
            + NSStringFromPoint(pointer ?? NSEvent.mouseLocation)
        )

        return Task { @MainActor [weak self] in
            guard let self else { return InstantCaptureResult.failure(kind) }
            defer { self.isBusy = false }
            return await self.performInstant(
                kind,
                pointer: pointer,
                candidates: candidates
            )
        }
    }

    /// The whole instant pipeline: pick the target, acquire pixels, deliver.
    /// Never creates a selection window and never runs a modal alert.
    private func performInstant(
        _ kind: InstantCaptureKind,
        pointer: CGPoint?,
        candidates: [WindowCandidate]?
    ) async -> InstantCaptureResult {
        let point = pointer ?? NSEvent.mouseLocation

        // If the history panel was just hidden by the caller, give the window
        // server one frame so it cannot be sampled into the shot. 60 ms is well
        // below perceptible latency and only happens on this path.
        try? await Task.sleep(nanoseconds: 60_000_000)

        var windowNumber: Int?
        var windowFrame: CGRect?
        let shot: CapturedScreenshot

        do {
            switch kind {
            case .window:
                let stack: ScreenCapture.WindowStack = candidates.map {
                    ScreenCapture.WindowStack(
                        candidates: $0,
                        menubarHeights: [],
                        screenHeight: Self.screen(under: point)?.frame.height ?? 0
                    )
                } ?? ScreenCapture.instantWindowStack()

                let outcome = WindowPicker.pick(
                    at: point,
                    candidates: stack.candidates,
                    ownPID: ProcessInfo.processInfo.processIdentifier,
                    ownCapturableWindowNumbers: OwnWindowCapture.capturableWindowNumbers,
                    screenHeight: stack.screenHeight,
                    menubarHeights: stack.menubarHeights,
                    probe: { ScreenCapture.windowContentProbe(for: $0) }
                )

                DebugLog.log(
                    "instant: \(stack.candidates.count) on-screen windows, "
                    + "menubarHeights=\(stack.menubarHeights.sorted()) "
                    + "screenHeight=\(Int(stack.screenHeight))"
                )
                for row in outcome.rows {
                    DebugLog.log(
                        "instant:   #\(row.windowNumber) "
                        + "\(row.ownerName.isEmpty ? "?" : row.ownerName) "
                        + "\(row.windowName.isEmpty ? "" : "\"\(row.windowName)\" ")"
                        + "layer=\(row.layer) "
                        + "bounds=\(NSStringFromRect(row.bounds)) "
                        + "→ \(row.reject?.rawValue ?? "SELECTED")"
                    )
                }

                // iShot never falls back to the screen here: `getImageWindowUnderMouse`
                // always answers with a window or with nothing at all, and
                // `screenShotFromWindowID:` returns nil rather than a desktop
                // shot. Capturing the whole display when the pointer is over a
                // regular application window is precisely the bug this
                // replaces, so the miss is reported instead of hidden.
                guard let target = outcome.pick else {
                    DebugLog.log("instant: no window under \(NSStringFromPoint(point)) — refusing")
                    throw CaptureError.windowNotFound
                }

                DebugLog.log(
                    "instant: picked #\(target.candidate.windowNumber) "
                    + "owner=\(target.candidate.ownerName) "
                    + "title=\(target.candidate.windowName) "
                    + "layer=\(target.candidate.layer) "
                    + "rect=\(NSStringFromRect(target.rect)) trimmed=\(target.trimmed)"
                )
                shot = try await ScreenCapture.captureWindow(
                    CGWindowID(target.candidate.windowNumber)
                )
                windowNumber = target.candidate.windowNumber
                windowFrame = target.rect

            case .fullScreen:
                guard let screen = Self.screen(under: point) else {
                    throw CaptureError.noDisplay
                }
                shot = try await ScreenCapture.captureFullScreen(
                    screen,
                    includeCursor: settings.captureCursor
                )
            }
        } catch {
            return refuseInstant(kind, message: error.localizedDescription, error: error)
        }

        return deliverInstant(
            shot,
            kind: kind,
            windowNumber: windowNumber,
            windowFrame: windowFrame,
            point: point
        )
    }

    /// Clipboard + optional file + restrained feedback. No annotations exist on
    /// this path, so the pixels are copied as captured.
    private func deliverInstant(
        _ shot: CapturedScreenshot,
        kind: InstantCaptureKind,
        windowNumber: Int?,
        windowFrame: CGRect?,
        point: CGPoint
    ) -> InstantCaptureResult {
        copyToPasteboard(decorated(shot))

        var saved: URL?
        if settings.instantCaptureAlsoSave {
            do {
                saved = try writeToDisk(decorated(shot, opaqueBackground: exportBackground))
            } catch {
                // Saving is a side effect; never lose the clipboard copy over it.
                DebugLog.log("instant: save failed: \(error.localizedDescription)")
            }
        }

        if settings.instantCaptureSound {
            if let sound = NSSound(named: NSSound.Name("Grab")) {
                sound.play()
            } else {
                NSSound.beep()
            }
        }

        if settings.instantCaptureVisualCue, let screen = Self.screen(under: point) {
            let cue = InstantCaptureCueController()
            cue.show(at: point, on: screen, windowFrame: windowFrame)
            instantCue = cue
            // Drop the reference once the window has closed; the controller
            // closes itself after `duration`.
            Task { @MainActor [weak self] in
                try? await Task.sleep(
                    nanoseconds: UInt64((InstantCaptureCueController.duration + 0.15) * 1e9)
                )
                guard let self, self.instantCue === cue else { return }
                self.instantCue = nil
            }
        }

        let size = shot.pointSize
        let dimensions = "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
        lastErrorMessage = nil
        lastMessage = "已拷贝 \(dimensions)"
        DebugLog.log(
            "instant: delivered kind=\(kind.rawValue) "
            + "window=\(windowNumber.map(String.init) ?? "-") "
            + "pixels=\(shot.image.width)×\(shot.image.height) "
            + "saved=\(saved?.lastPathComponent ?? "-")"
        )
        return InstantCaptureResult(
            kind: kind,
            shot: shot,
            windowNumber: windowNumber,
            savedURL: saved,
            error: nil
        )
    }

    /// Failure feedback for the instant path: log + short beep, never a modal.
    private func refuseInstant(
        _ kind: InstantCaptureKind,
        message: String,
        error: Error?
    ) -> InstantCaptureResult {
        lastMessage = nil
        lastErrorMessage = message
        DebugLog.log("instant: \(kind.rawValue) refused: \(message)")
        NSSound.beep()
        return .failure(kind, error: error)
    }

    /// Hotkey entry point for OCR: draw a box, recognise it immediately.
    ///
    /// Deliberately not a `CaptureMode`: OCR is a *delivery* choice, not a
    /// different selection model, and adding it to the mode enum would change
    /// the capture page and every switch that handles modes.
    func startOCR() {
        guard !isBusy, overlay == nil else {
            DebugLog.log("capture: ignored OCR, already busy")
            return
        }
        if !ScreenCapture.hasScreenRecordingPermission {
            ScreenCapture.requestScreenRecordingPermission()
        }
        DebugLog.log("capture: start OCR")
        presentOverlay(
            mode: .region,
            prefill: nil,
            autoConfirmOnSelectionEnd: true,
            windowPickEnabled: false
        )
    }

    // MARK: - 套壳 / 美化截图

    /// Draw a region (reusing the normal overlay), then hand the pixels to the
    /// beautify preview window instead of copying them straight away.
    func startBeautify() {
        guard !isBusy, overlay == nil, scrollController == nil, delayController == nil else {
            DebugLog.log("capture: ignored beautify, already busy")
            return
        }
        if !ScreenCapture.hasScreenRecordingPermission {
            ScreenCapture.requestScreenRecordingPermission()
        }
        DebugLog.log("capture: start beautify selection")
        presentOverlay(
            mode: .region,
            prefill: nil,
            autoConfirmOnSelectionEnd: true,
            autoConfirmAsBeautify: true,
            windowPickEnabled: false
        )
    }

    private func beginBeautify(_ rect: CGRect) {
        guard let screen = Self.screen(containing: rect) else {
            report(CaptureError.noDisplay)
            return
        }
        isBusy = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isBusy = false }
            do {
                // Same compositor settle as every other capture path.
                try await Task.sleep(nanoseconds: 140_000_000)
                let shot = try await ScreenCapture.captureArea(
                    rect,
                    on: screen,
                    includeCursor: self.settings.captureCursor
                )
                self.presentBeautify(shot)
            } catch {
                self.report(error, title: "套壳截图失败")
            }
        }
    }

    private func presentBeautify(_ shot: CapturedScreenshot) {
        // A second invocation replaces the first preview instead of stacking
        // windows, mirroring the OCR result card.
        beautifyWindow?.close()
        beautifyWindow = nil

        let controller = BeautifyWindowController(shot: shot)
        controller.onClose = { [weak self] in
            self?.beautifyWindow = nil
            // The preview was the only reason this app held activation.
            self?.restoreFocusAfterCapture()
        }
        beautifyWindow = controller
        controller.show()
        // `show()` activates for its own window; keep the settings page behind
        // the app that was in front, exactly like the capture overlay does.
        OverlayActivation.activate()
        lastErrorMessage = nil
        lastMessage = "套壳预览：调整留白 / 圆角 / 阴影后拷贝或保存"
        playCaptureSoundIfEnabled()
        DebugLog.log(
            "beautify: opening preview for \(shot.image.width)×\(shot.image.height) px"
        )
    }

    // MARK: - 摄像头画中画

    /// Menu entry: show the camera now, or hide it if it is already visible.
    func toggleCameraOverlay() {
        if cameraOverlay != nil {
            stopCameraOverlay()
            lastMessage = "摄像头画中画已关闭"
        } else if startCameraOverlay(auto: false) {
            lastMessage = "摄像头画中画已开启，可拖动，右下角可缩放"
        }
    }

    /// Start the camera panel. Returns `false` (without an alert) when macOS
    /// has not granted camera access; the settings page is where the user is
    /// told and offered the Settings shortcut.
    @discardableResult
    func startCameraOverlay(auto: Bool) -> Bool {
        guard cameraOverlay == nil else { return true }
        guard let screen = Self.screenUnderMouse() else {
            lastMessage = "找不到可用的屏幕。"
            return false
        }

        let controller = CameraOverlayController()
        let started = controller.start(
            position: settings.cameraOverlayPositionValue,
            size: settings.cameraOverlaySizeValue,
            screenFrame: screen.frame
        )
        guard started else {
            lastMessage = controller.lastFailureReason ?? "无法开启摄像头画中画。"
            DebugLog.log("camera: overlay not started: \(lastMessage ?? "-")")
            return false
        }
        cameraOverlay = controller
        if auto { cameraAutoStarted = true }
        return true
    }

    func stopCameraOverlay() {
        cameraOverlay?.stop()
        cameraOverlay = nil
        cameraAutoStarted = false
    }

    /// Settings page hook: the switch/position/size changed.
    func applyCameraSettings() {
        if !settings.cameraOverlayEnabled {
            if cameraOverlay != nil { stopCameraOverlay() }
            return
        }
        if let cameraOverlay {
            let screen = Self.screenUnderMouse() ?? NSScreen.main
            guard let screen else { return }
            cameraOverlay.updatePlacement(
                position: settings.cameraOverlayPositionValue,
                size: settings.cameraOverlaySizeValue,
                screenFrame: screen.frame
            )
        } else if recordingState.isActive {
            _ = startCameraOverlay(auto: true)
        }
    }

    // MARK: - Scrolling capture

    /// The scroll hotkey and menu item are one toggle: start the overlay, stop
    /// a running session, or close the finished result and start again.
    func startScroll() {
        if let scrollController {
            if scrollController.isRunning {
                DebugLog.log("capture: stop scroll (hotkey)")
                finishScroll()
                return
            }
            // A stopped result is waiting for confirmation. The shortcut is a
            // deliberate "I am done", so it delivers instead of throwing the
            // long image away; a second press starts a fresh selection.
            DebugLog.log("capture: confirm scroll result (hotkey)")
            confirmScroll()
            return
        }
        guard !isBusy, overlay == nil, delayController == nil else {
            DebugLog.log("capture: ignored scroll, already busy")
            return
        }
        if !ScreenCapture.hasScreenRecordingPermission {
            ScreenCapture.requestScreenRecordingPermission()
        }
        DebugLog.log("capture: start scroll selection")
        presentOverlay(
            mode: .region,
            prefill: nil,
            autoConfirmOnSelectionEnd: true,
            autoConfirmAsScroll: true,
            windowPickEnabled: false
        )
    }

    /// A scrolling box was drawn (or redrawn). The overlay stays open; this
    /// starts the sampler and hands the viewfinder its first state.
    private func beginScroll(_ rect: CGRect, screen: NSScreen, view: CaptureOverlayView) {
        // A second box during a session replaces it: the old rows were sampled
        // from a different rectangle and would produce a seam.
        scrollController?.abandon()
        scrollController = nil

        scrollOverlayView = view
        scrollRegion = rect
        scrollScreen = screen
        scrollLiveShot = nil
        scrollFinalShot = nil
        scrollFinalRaw = nil
        scrollPendingAction = nil
        scrollConfirmWhenComposed = false

        let controller = ScrollCaptureController(
            region: rect,
            screen: screen,
            interval: settings.scrollCaptureInterval > 0
                ? settings.scrollCaptureInterval
                : ScrollCaptureController.defaultInterval,
            includeCursor: false,
            maxFrames: settings.scrollCaptureMaxFrames
        )
        // The overlay is click-through for the whole scrolling session, so the
        // page keeps the wheel; the viewfinder's own window stays clickable.
        // The page's pid is what lets activation travel with the transparency:
        // a wheel is delivered to the *active* app, so the page has to own it
        // for the rest of the session.
        controller.onPassthrough = { [weak self] enabled in
            self?.overlay?.setScrollPassthrough(
                enabled,
                targetPID: self?.scrollController?.targetPID
            )
        }
        // The viewfinder tells the session how big a band it needs, so the
        // pixel work composes exactly the pixels the pod draws instead of the
        // whole stitched image.
        controller.setPreviewBandSize(view.scrollBandSize)
        view.onScrollPreviewSizeChanged = { [weak controller] size in
            controller?.setPreviewBandSize(size)
        }
        controller.onUpdate = { [weak self] preview, _, autoScrolling in
            guard let self else { return }
            self.overlay?.updateScrollPreview(
                preview: preview,
                phase: .capturing,
                autoScrolling: autoScrolling
            )
        }
        if let rawDump = ProcessInfo.processInfo.environment["UNSEEN_SCROLL_DUMP"],
           !rawDump.isEmpty {
            let directory = URL(fileURLWithPath: rawDump, isDirectory: true)
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            var dumpIndex = 0
            controller.onFrame = { image, outcome, overlap in
                DebugLog.log("scroll: frame \(dumpIndex) outcome=\(outcome) overlap=\(overlap)")
                if let data = NSBitmapImageRep(cgImage: image)
                    .representation(using: .png, properties: [:]) {
                    try? data.write(to: directory.appendingPathComponent(
                        String(format: "frame-%03d.png", dumpIndex)))
                }
                dumpIndex += 1
            }
        }
        controller.onFinish = { [weak self] image, scale, frames in
            self?.handleScrollFinished(image, scale: scale, frames: frames)
        }
        controller.onCancel = { [weak self] reason in
            self?.handleScrollCancelled(reason)
        }
        scrollController = controller
        DebugLog.log(
            "scroll: session begin region=\(NSStringFromRect(rect)) "
                + "screen=\(screen.localizedName)"
        )
        controller.start()
    }

    private func toggleScrollAuto() {
        guard let controller = scrollController, controller.isRunning else { return }
        if controller.isAutoScrolling {
            controller.stopAutoScroll()
        } else {
            controller.startAutoScroll()
        }
    }

    /// The 停止 button, Return, the second hotkey press, or the bottom
    /// detector all land here.
    private func finishScroll() {
        guard let controller = scrollController else { return }
        if controller.isRunning {
            controller.finish()
        } else if controller.isComposing {
            // 停止 / Return arrived while the final image was being composed:
            // there is a result on the way, so this is the confirmation, not a
            // reason to close the overlay and drop it.
            scrollConfirmWhenComposed = true
            DebugLog.log("scroll: confirm queued until the compose lands")
        } else {
            closeScrollOverlay()
            restoreFocusAfterCapture()
        }
    }

    /// 继续 (or a wheel over the finished card): keep the same stitch and pick
    /// the page up where it stopped.
    ///
    /// The finished result is dropped from the coordinator's pending state —
    /// the user is asking for more page, not for an action on the image they
    /// just got. The session hands the wheel back to the page itself
    /// (`resume()` re-asserts click-through + activation), so the overlay keeps
    /// the same box, the same pod and the same accumulated rows.
    private func resumeScroll() {
        guard let controller = scrollController else {
            DebugLog.log("scroll: resume ignored, no session")
            return
        }
        guard controller.canResume else {
            DebugLog.log("scroll: resume refused (frame/height ceiling reached)")
            NSSound.beep()
            return
        }
        scrollPendingAction = nil
        scrollFinalShot = nil
        scrollFinalRaw = nil
        scrollLiveShot = nil
        lastMessage = "继续滚动：长图会接着变长"
        DebugLog.log("scroll: resume after finish")
        controller.resume()
    }

    /// Close the overlay and release the session. Safe after the session has
    /// finished; a running session is abandoned without reporting.
    private func closeScrollOverlay() {
        scrollConfirmWhenComposed = false
        scrollController?.abandon()
        scrollController = nil
        scrollOverlayView = nil
        scrollRegion = nil
        scrollScreen = nil
        scrollLiveShot = nil
        scrollFinalShot = nil
        scrollFinalRaw = nil
        scrollPendingAction = nil
        if let overlay {
            overlay.close()
            self.overlay = nil
        }
        DebugLog.log("scroll: overlay closed")
    }

    private func handleScrollCancelled(_ reason: String?) {
        scrollConfirmWhenComposed = false
        scrollController = nil
        scrollOverlayView = nil
        scrollRegion = nil
        scrollScreen = nil
        scrollLiveShot = nil
        scrollFinalShot = nil
        scrollFinalRaw = nil
        scrollPendingAction = nil
        if let overlay {
            overlay.close()
            self.overlay = nil
        }
        if let reason {
            lastErrorMessage = reason
            lastMessage = nil
            NSSound.beep()
            DebugLog.log("scroll: stopped with message: \(reason)")
        } else {
            lastMessage = "已取消滚动截图"
        }
        restoreFocusAfterCapture()
    }

    /// Copy the current stitch without stopping. The annotation toolbar's
    /// 拷贝 is non-terminal by contract, so the session keeps running.
    private func copyScrollCurrent(_ annotations: [Annotation]) {
        guard let region = scrollRegion, let controller = scrollController else {
            NSSound.beep()
            return
        }
        let scale = max(controller.screen.backingScaleFactor, 1)
        // The live session only keeps an append-only store and a small band;
        // this one action composes the whole picture on the stitch queue.
        Task { @MainActor in
            guard let image = await controller.snapshot() else {
                NSSound.beep()
                return
            }
            let flattened = scrollDeliverable(
                image,
                region: region,
                scale: scale,
                annotations: annotations
            )
            let shot = CapturedScreenshot(image: flattened, scale: scale)
            copyToPasteboard(decorated(shot))
            lastErrorMessage = nil
            lastMessage = "已拷贝当前长图（可继续滚动）"
            playCaptureSoundIfEnabled()
            DebugLog.log("scroll: copy-current \(shot.image.width)×\(shot.image.height)")
        }
    }

    /// A terminal toolbar action. While the session runs, stop first and let
    /// `handleScrollFinished` deliver; on a finished result, deliver from the
    /// stored image. Both paths use the ordinary capture delivery so 保存 /
    /// 另存为 / 贴图 / OCR mean exactly what they mean for a region shot.
    private func handleScrollAction(
        _ action: CaptureToolbarAction,
        saveCopy: Bool = false
    ) {
        guard action != .cancel, !action.keepsOverlayOpen else { return }
        if let controller = scrollController, controller.isRunning {
            scrollPendingAction = action
            controller.finish()
            return
        }
        guard let raw = scrollFinalRaw, let region = scrollRegion else {
            NSSound.beep()
            return
        }
        // Annotations may have been drawn after the session stopped; flatten
        // the current set into the top of the final image now.
        let annotations = scrollOverlayView?.annotationsForExport ?? []
        let flattened = scrollDeliverable(
            raw.image,
            region: region,
            scale: raw.scale,
            annotations: annotations
        )
        let shot = CapturedScreenshot(image: flattened, scale: raw.scale)
        scrollFinalShot = nil
        scrollFinalRaw = nil
        scrollConfirmWhenComposed = false
        closeScrollOverlay()
        deliverScroll(shot, action: action, region: region, saveCopy: saveCopy)
    }

    /// The scrolling session stopped on its own (bottom detector), on 停止, on
    /// Return, or on the shortcut.
    ///
    /// Nothing is delivered here. The stitch becomes the *pending* result and
    /// the overlay goes back to being an ordinary selection with its toolbar:
    /// the user annotates if they want, then Return (or 完成 / 保存 / 拷贝)
    /// confirms. That is the same contract as a region shot, and it is the one
    /// the owner asked for — "回到选区 + 工具栏状态，按 Return 或完成才真正交付".
    /// Before this, the stop path copied and wrote the file immediately and
    /// left the finished card on screen, so the picture was already delivered
    /// before anyone confirmed it.
    private func handleScrollFinished(_ image: CGImage, scale: CGFloat, frames: Int) {
        guard let view = scrollOverlayView, let region = scrollRegion else {
            handleScrollCancelled("滚动截图的选区已丢失。")
            return
        }
        let annotations = view.annotationsForExport
        let flattened = scrollDeliverable(
            image,
            region: region,
            scale: scale,
            annotations: annotations
        )
        let shot = CapturedScreenshot(image: flattened, scale: max(scale, 1))
        scrollLiveShot = shot

        let pending = scrollPendingAction
        scrollPendingAction = nil
        if let pending {
            // Terminal action: an explicit toolbar button was pressed while
            // the session ran. The click is the confirmation, so deliver it and
            // let the overlay go (save-as and OCR open their own windows).
            let region = scrollRegion
            scrollFinalShot = nil
            scrollFinalRaw = nil
            closeScrollOverlay()
            deliverScroll(shot, action: pending, region: region)
            return
        }

        // 停止 / bottom reached / Return: hold the result. The selection, the
        // toolbar and the viewfinder stay live so the user can annotate, 继续,
        // press Return, or press Esc to throw it away.
        let resumable = scrollController?.canResume ?? false
        scrollFinalShot = shot
        scrollFinalRaw = (image, scale)
        overlay?.presentScrollResult(flattened, resumable: resumable)
        let size = shot.pointSize
        let dimensions = "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
        lastErrorMessage = nil
        lastMessage = "滚动截图完成：\(frames) 帧 → \(dimensions)，按 Return 或点「完成」交付"
        DebugLog.log(
            "scroll: awaiting confirmation frames=\(frames) size=\(dimensions) "
                + "resumable=\(resumable)"
        )
        if scrollConfirmWhenComposed {
            // The user confirmed while the compose was still running. The
            // result is here now, so honour that Return / 完成 exactly once.
            scrollConfirmWhenComposed = false
            DebugLog.log("scroll: delivering the queued confirmation")
            confirmScroll()
        }
    }

    /// Return, the viewfinder's 完成, or the scroll shortcut on a stopped
    /// result. `handleScrollAction` owns the actual delivery: it flattens the
    /// annotations drawn *after* the stop, closes the overlay, and runs the
    /// same copy / save / pin / OCR path a region shot uses.
    private func confirmScroll() {
        guard let controller = scrollController else { return }
        if controller.isRunning {
            // Return during the run stops it; the next one delivers.
            finishScroll()
            return
        }
        if controller.isComposing {
            scrollConfirmWhenComposed = true
            DebugLog.log("scroll: confirm queued until the compose lands")
            return
        }
        guard scrollFinalRaw != nil else {
            DebugLog.log("scroll: confirm ignored, no pending result")
            NSSound.beep()
            return
        }
        DebugLog.log("scroll: confirmed, delivering")
        // A confirmed long screenshot is copied *and* written to the capture
        // folder, exactly like the stop path did before the confirmation step
        // existed. Copying alone made "保存" silently stop happening.
        handleScrollAction(.copyClosing, saveCopy: true)
    }

    private func deliverScroll(
        _ shot: CapturedScreenshot,
        action: CaptureToolbarAction,
        region: CGRect?,
        saveCopy: Bool = false
    ) {
        let delivery: CaptureDelivery
        switch action {
        case .copyClosing: delivery = .copy
        case .save: delivery = .save
        case .saveAs: delivery = .saveAs
        case .pin: delivery = .pin
        case .ocr: delivery = .ocr
        // `.record` belongs to the recording overlay and is intercepted before
        // this funnel. Reaching here would mean a recording action on a
        // screenshot path, which must capture nothing rather than copy a box.
        case .record, .copyKeeping, .cancel: return
        }
        do {
            try deliver(shot, as: delivery, pinFrame: region, alsoSave: saveCopy)
        } catch is SavePanelCancelled {
            lastMessage = "已取消保存"
            lastErrorMessage = nil
        } catch {
            report(error)
        }
        if delivery != .ocr || ocrWindow == nil {
            restoreFocusAfterCapture()
        }
    }

    /// Bake annotations into the **top** of the long image.
    ///
    /// The selection's first frame is the top of the stitch, so annotation
    /// coordinates normalised to the selection map to exactly that first
    /// screen. Later rows are untouched. This keeps every drawing tool usable
    /// during a scroll capture instead of pretending they are UI decoration.
    /// The pixels a scrolling capture delivers: annotations baked into the top
    /// slice, then the window corners clipped out (P6) so a long shot comes out
    /// with the same Apple corner the overlay shaded.
    private func scrollDeliverable(
        _ image: CGImage,
        region: CGRect,
        scale: CGFloat,
        annotations: [Annotation]
    ) -> CGImage {
        let flattened = flattenScrollAnnotations(
            image,
            region: region,
            scale: scale,
            annotations: annotations
        )
        return CaptureCorner.clipped(flattened, scale: scale)
    }

    private func flattenScrollAnnotations(
        _ image: CGImage,
        region: CGRect,
        scale: CGFloat,
        annotations: [Annotation]
    ) -> CGImage {
        guard !annotations.isEmpty, image.width > 0, image.height > 0 else { return image }
        let topHeight = min(
            image.height,
            max(1, Int((region.height * max(scale, 1)).rounded()))
        )
        guard let top = image.cropping(to: CGRect(
            x: 0,
            y: 0,
            width: image.width,
            height: topHeight
        )) else { return image }
        let flattenedTop = AnnotationRenderer.flattened(
            base: top,
            annotations: annotations,
            referencePointSize: region.size
        ) ?? top
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        let pixelSize = CGSize(width: image.width, height: image.height)
        context.draw(image, in: CGRect(origin: .zero, size: pixelSize))
        // Bottom-left context: the first frame is the top slice.
        context.draw(
            flattenedTop,
            in: CGRect(
                x: 0,
                y: CGFloat(image.height - topHeight),
                width: CGFloat(image.width),
                height: CGFloat(topHeight)
            )
        )
        return context.makeImage() ?? image
    }

    // MARK: - Delayed screenshot

    /// Count down, then capture the screen under the mouse (the screen the
    /// countdown HUD is on). Menu-only entry: a delay is a setup step, not a
    /// separate selection model.
    func startDelay() {
        if let delayController {
            DebugLog.log("capture: cancel delay")
            delayController.cancel()
            return
        }
        guard !isBusy, overlay == nil, scrollController == nil else {
            DebugLog.log("capture: ignored delay, already busy")
            return
        }
        if !ScreenCapture.hasScreenRecordingPermission {
            ScreenCapture.requestScreenRecordingPermission()
        }

        let screen = Self.screenUnderMouse()
        let controller = DelayCountdownController(
            seconds: settings.timeOfDelayScreenshots,
            screen: screen
        )
        controller.onComplete = { [weak self] in
            guard let self else { return }
            self.delayController = nil
            self.captureFullScreenNow(on: screen)
        }
        controller.onCancel = { [weak self] in
            self?.delayController = nil
            self?.lastMessage = "已取消延时截图"
            DebugLog.log("delay: cancelled")
        }
        delayController = controller
        controller.start()
    }

    // MARK: - Multi-window capture

    /// Highlight every capturable window, let the user click several, then
    /// composite them at their screen positions.
    func startMultiWindow() {
        guard !isBusy, overlay == nil, scrollController == nil, delayController == nil else {
            DebugLog.log("capture: ignored multi-window, already busy")
            return
        }
        if !ScreenCapture.hasScreenRecordingPermission {
            ScreenCapture.requestScreenRecordingPermission()
        }
        DebugLog.log("capture: start multi-window selection")
        presentOverlay(mode: .multiWindow, prefill: nil)
    }

    // MARK: - Preset size

    /// Region selection pre-filled with the configured width/height, centred on
    /// the screen under the mouse. Still fully adjustable before confirming.
    func startPreset() {
        guard !isBusy, overlay == nil, scrollController == nil, delayController == nil else {
            DebugLog.log("capture: ignored preset, already busy")
            return
        }
        if !ScreenCapture.hasScreenRecordingPermission {
            ScreenCapture.requestScreenRecordingPermission()
        }
        guard let screen = Self.screenUnderMouse() else {
            report(CaptureError.noDisplay)
            return
        }
        let rect = PresetSelection.rect(for: settings.presetCaptureSize, on: screen.frame)
        DebugLog.log(
            "capture: preset \(Int(rect.width))×\(Int(rect.height)) at \(NSStringFromRect(rect))"
        )
        presentOverlay(
            mode: .region,
            prefill: rect,
            screen: screen,
            windowPickEnabled: false
        )
    }

    // MARK: - Screen recording

    /// Hotkey / menu entry: start a region recording, or stop the one already
    /// running. The same key therefore does both jobs.
    ///
    /// Recording now shares the screenshot grammar: press the key, get the
    /// region overlay, drag a box (or click a window, or press F for the whole
    /// screen), then Return / 开始录制. Selecting the full screen in that
    /// overlay is the full-screen recording; there is no separate whole-screen
    /// mode.
    func toggleRecording() {
        if recorder?.isActive == true {
            stopRecording()
        } else {
            startRecordingRegion()
        }
    }

    /// Region recording: reuse the region overlay; the confirmed rectangle is
    /// exactly the stream's source rect. Nothing is captured until the user
    /// confirms, so Esc / right-click leaves no file behind.
    func startRecordingRegion() {
        guard recorder?.isActive != true else {
            lastMessage = "正在录制，先停止当前录制。"
            DebugLog.log("recording: ignored region request, already recording")
            return
        }
        guard !isBusy, overlay == nil, scrollController == nil, delayController == nil else {
            DebugLog.log("recording: ignored region request, already busy")
            return
        }
        if !ScreenCapture.hasScreenRecordingPermission {
            ScreenCapture.requestScreenRecordingPermission()
        }
        DebugLog.log("recording: start region selection")
        presentOverlay(
            mode: .region,
            prefill: nil,
            recordingMode: true,
            windowPickEnabled: true
        )
    }

    private func startRecording(region: CGRect?) {
        guard recorder?.isActive != true else { return }
        // `overlay` is allowed here: the region selector *is* the recording UI
        // and it deliberately stays open (it is `recordingOverlay` below).
        guard !isBusy,
              colorPicker == nil,
              delayController == nil,
              scrollController == nil else {
            DebugLog.log("recording: ignored start, another capture surface is open")
            return
        }
        if !ScreenCapture.hasScreenRecordingPermission {
            ScreenCapture.requestScreenRecordingPermission()
        }
        let targetScreen = region.flatMap { Self.screen(containing: $0) } ?? Self.screenUnderMouse()
        guard let screen = targetScreen else {
            report(CaptureError.noDisplay, title: "录屏失败")
            return
        }

        // The overlay (mask, border, handles, HUD) must already be on screen
        // before the stream's content filter is built, otherwise
        // `SCContentFilter(excludingWindows:)` cannot keep it out of the video.
        //
        // When the stream came from the region selector, that selector has
        // already frozen itself and parked the HUD on the toolbar's frame. The
        // standalone HUD is only for callers that start without an overlay.
        recordingOverlay = overlay
        if overlay == nil {
            let indicator = RecordingIndicatorController()
            indicator.onStop = { [weak self] in self?.stopRecording() }
            indicator.onPauseToggle = { [weak self] in self?.toggleRecordingPause() }
            indicator.show(state: .recording, elapsedText: "00:00")
            recordingIndicator = indicator
        }
        recordingState = .recording
        recordingElapsedText = "00:00"

        let configuration = settings.recordingConfiguration
        isBusy = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Let the window server actually order the HUD in: the stream's
            // own-window exclusion is a snapshot, and a panel that has not
            // reached the window server yet would be left out of it.
            try? await Task.sleep(nanoseconds: 150_000_000)
            do {
                let recorder = ScreenRecorder()
                recorder.onStateChange = { [weak self] state in
                    self?.applyRecordingState(state)
                }
                let url = try await recorder.start(
                    screen: screen,
                    region: region,
                    configuration: configuration,
                    directory: self.settings.captureDirectory
                )
                self.recorder = recorder
                self.isBusy = false
                self.lastErrorMessage = nil
                self.recordingState = .recording
                self.recordingElapsedText = "00:00"
                self.applyRecordingState(.recording)
                self.startKeyDisplaySessionIfEnabled()
                self.startRecordingTicker()
                if self.settings.cameraOverlayEnabled {
                    _ = self.startCameraOverlay(auto: true)
                }
                if let warning = recorder.warning {
                    self.lastMessage = warning
                } else {
                    self.lastMessage = region == nil ? "开始录制整屏" : "开始录制选定区域"
                }
                DebugLog.log(
                    "recording: started \(url.lastPathComponent) points="
                    + "\(Int((region ?? screen.frame).width))×\(Int((region ?? screen.frame).height)) "
                    + "pixels=\(Int(recorder.pixelSize.width))×\(Int(recorder.pixelSize.height)) "
                    + "format=\(configuration.format.rawValue) fps=\(configuration.effectiveFrameRate) "
                    + "mic=\(recorder.microphoneActive)"
                )
                self.onRecordingChanged?(.recording, "00:00")
            } catch {
                self.isBusy = false
                self.recorder = nil
                self.recordingState = .idle
                self.hideRecordingDecorations()
                self.stopKeyDisplaySession()
                self.report(error, title: "录屏失败")
            }
        }
    }

    /// Self-test hook: the exact path the overlay's 开始录制 button takes.
    /// Exposed (not a second implementation) so the harness can prove the
    /// recording UI appears on start and disappears on stop.
    func startRecordingForTesting(region: CGRect?) {
        startRecording(region: region)
    }

    /// Self-test hook: the selector that the stream was started from, `nil`
    /// when the session did not come from the overlay or has ended.
    var recordingOverlayForTesting: CaptureOverlayController? { recordingOverlay }

    /// Self-test hook: the standalone HUD on screen, `nil` when idle (or when
    /// the recording HUD belongs to the overlay).
    var recordingIndicatorForTesting: RecordingIndicatorController? { recordingIndicator }

    /// Stop the running session and save the file. Safe to call twice: the
    /// second call is a logged no-op.
    func stopRecording() {
        guard let recorder, recorder.isActive else {
            DebugLog.log("recording: stop ignored, not recording")
            return
        }
        recordingTicker?.cancel()
        recordingTicker = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await recorder.stop()
                self.recorder = nil
                self.recordingState = .finished
                self.recordingElapsedText = ScreenRecorder.elapsedText(result.elapsed)
                self.hideRecordingDecorations()
                self.stopKeyDisplaySession()
                if self.cameraAutoStarted { self.stopCameraOverlay() }
                self.lastErrorMessage = nil
                self.lastMessage = "已保存 \(result.url.lastPathComponent)（"
                    + "\(ScreenRecorder.elapsedText(result.elapsed))，"
                    + "\(Int(result.pixelSize.width))×\(Int(result.pixelSize.height))）"
                self.playCaptureSoundIfEnabled()
                self.onRecordingChanged?(.finished, self.recordingElapsedText)
                DebugLog.log(
                    "recording: saved \(result.url.path) elapsed="
                    + String(format: "%.2f", result.elapsed)
                    + "s frames=\(result.framesWritten) dropped=\(result.framesDropped)"
                )
                self.restoreFocusAfterCapture()
            } catch {
                self.recorder = nil
                self.recordingState = .idle
                self.hideRecordingDecorations()
                self.stopKeyDisplaySession()
                if self.cameraAutoStarted { self.stopCameraOverlay() }
                self.report(error, title: "录屏失败")
                self.restoreFocusAfterCapture()
            }
        }
    }

    /// Pause / resume from the floating HUD. Paused time is not part of the
    /// file's duration; see `ScreenRecorder`.
    func toggleRecordingPause() {
        guard let recorder else { return }
        if recorder.state == .paused {
            recorder.resume()
        } else {
            recorder.pause()
        }
        recordingElapsedText = recorder.elapsedText()
        applyRecordingState(recorder.state)
    }

    private func applyRecordingState(_ state: RecordingState) {
        recordingState = state
        switch state {
        case .recording, .paused:
            recordingElapsedText = recorder?.elapsedText() ?? recordingElapsedText
            recordingIndicator?.update(state: state, elapsedText: recordingElapsedText)
            recordingOverlay?.updateRecordingHUD(
                state: state,
                elapsedText: recordingElapsedText
            )
        case .finished, .idle:
            hideRecordingDecorations()
        }
        onRecordingChanged?(state, recordingElapsedText)
    }

    /// Tear down the recording UI together: the HUD and the overlay that hosts
    /// it exist only while a session is live, so every exit path (stop,
    /// failure, cancel) goes through here.
    private func hideRecordingDecorations() {
        recordingIndicator?.hide()
        recordingIndicator = nil
        recordingOverlay?.finishRecordingSession()
        recordingOverlay = nil
        overlay = nil
    }

    private func startRecordingTicker() {
        recordingTicker?.cancel()
        recordingTicker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let recorder = self.recorder, recorder.isActive else { return }
                let text = recorder.elapsedText()
                self.recordingElapsedText = text
                self.recordingIndicator?.update(state: self.recordingState, elapsedText: text)
                self.recordingOverlay?.updateRecordingHUD(
                    state: self.recordingState,
                    elapsedText: text
                )
                self.onRecordingChanged?(self.recordingState, text)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    // MARK: - Colour picker

    func startColorPicker() {
        guard colorPicker == nil else {
            DebugLog.log("color picker: ignored, already presenting")
            return
        }
        if !ScreenCapture.hasScreenRecordingPermission {
            ScreenCapture.requestScreenRecordingPermission()
        }
        let controller = ColorPickerController(format: settings.colorPickFormat)
        controller.onPick = { [weak self] color, text in
            guard let self else { return }
            self.colorPicker = nil
            self.lastErrorMessage = nil
            self.settings.recordPickedColor(color.hex)
            self.lastMessage = "已复制 \(text)（\(color.rgbString) · \(color.hslString)）"
            self.playCaptureSoundIfEnabled()
            DebugLog.log(
                "color picker: picked \(color.hexString) text=\(text) "
                + "rgb=(\(color.rgbString)) hsl=\(color.hslString)"
            )
        }
        controller.onCancel = { [weak self] in
            self?.colorPicker = nil
            self?.lastMessage = "已取消取色"
            DebugLog.log("color picker: cancelled")
        }
        colorPicker = controller
        controller.present()
    }

    // MARK: - Key display

    /// Best-effort overlay: without Accessibility permission the controller
    /// reports `false` and nothing is shown, with no prompt and no crash.
    private func startKeyDisplaySessionIfEnabled() {
        guard settings.keyDisplayEnabled else { return }
        guard keyDisplay == nil else { return }
        let controller = KeyDisplayController()
        let installed = controller.start(
            position: settings.keyDisplayPositionValue,
            duration: settings.keyDisplayDuration
        )
        keyDisplay = controller
        if !installed {
            DebugLog.log("key display: listener not installed (permission or settings)")
        }
    }

    private func stopKeyDisplaySession() {
        keyDisplay?.stop()
        keyDisplay = nil
    }

    // MARK: - Overlay

    @discardableResult
    private func presentOverlay(
        mode: CaptureOverlayView.Mode,
        prefill: CGRect?,
        screen: NSScreen? = nil,
        autoConfirmOnSelectionEnd: Bool = false,
        autoConfirmAsScroll: Bool = false,
        recordingMode: Bool = false,
        autoConfirmAsBeautify: Bool = false,
        startsInWindowPick: Bool = false,
        windowPickEnabled: Bool = true,
        panelsForTestingOn testScreen: NSScreen? = nil
    ) -> CaptureOverlayController {
        let controller = CaptureOverlayController(
            mode: mode,
            prefilledSelection: prefill,
            showCrosshair: settings.showCrosshair,
            preferredScreen: screen,
            includeCursor: settings.captureCursor,
            settings: settings,
            autoConfirmOnSelectionEnd: autoConfirmOnSelectionEnd,
            autoConfirmAsScroll: autoConfirmAsScroll,
            recordingMode: recordingMode,
            autoConfirmAsBeautify: autoConfirmAsBeautify,
            startsInWindowPick: startsInWindowPick,
            windowPickEnabled: windowPickEnabled
        )

        controller.onRegionConfirmed = { [weak self] rect, annotations, toolbarAction in
            guard let self else { return }
            self.overlay = nil
            self.stopKeyDisplaySession()
            // `.record` never reaches this closure: it keeps the overlay open
            // and arrives through `onRecordingStarted` instead.
            self.handleRegion(rect, annotations: annotations, action: toolbarAction)
        }
        controller.onRecordingStarted = { [weak self] rect, _ in
            guard let self else { return }
            // Deliberately keeps `overlay`/`recordingOverlay`: the selector is
            // the recording UI. The stream's own content filter excludes every
            // window this process owns, so neither the mask, the border, the
            // handles, the size chip nor the HUD can land in the video.
            self.startRecording(region: rect)
        }
        controller.onRecordingPauseToggle = { [weak self] in
            self?.toggleRecordingPause()
        }
        controller.onRecordingStop = { [weak self] in
            self?.stopRecording()
        }
        controller.onCopyKeeping = { [weak self] rect, annotations, shot in
            guard let self else { return }
            self.handleCopyKeeping(rect, annotations: annotations, shot: shot)
        }
        controller.onWindowsConfirmed = { [weak self] selection in
            guard let self else { return }
            self.overlay = nil
            self.stopKeyDisplaySession()
            self.captureWindowsNow(selection)
        }
        controller.onWindowPicked = { [weak self] windowID, _ in
            guard let self else { return }
            self.overlay = nil
            self.stopKeyDisplaySession()
            self.capturePickedWindowNow(windowID)
        }
        controller.onScrollSessionStarted = { [weak self] rect, screen, view in
            guard let self else { return }
            // Deliberately does NOT clear `overlay`: the panels are the
            // scrolling interface now.
            self.beginScroll(rect, screen: screen, view: view)
        }
        controller.onScrollToggleAuto = { [weak self] in self?.toggleScrollAuto() }
        controller.onScrollStop = { [weak self] in self?.finishScroll() }
        controller.onScrollConfirm = { [weak self] in self?.confirmScroll() }
        controller.onScrollClose = { [weak self] in
            self?.closeScrollOverlay()
            self?.restoreFocusAfterCapture()
        }
        controller.onScrollResume = { [weak self] in self?.resumeScroll() }
        controller.onScrollAction = { [weak self] action in self?.handleScrollAction(action) }
        controller.onScrollCopyCurrent = { [weak self] annotations in
            self?.copyScrollCurrent(annotations)
        }
        controller.onScrollRegionCommitted = { [weak self] rect, _ in
            guard let self, let controller = self.scrollController,
                  controller.isRunning else { return }
            controller.updateRegion(rect)
        }
        controller.onScrollWheel = { [weak self] event in
            self?.scrollController?.forwardWheel(event)
        }
        controller.onBeautifyRegionConfirmed = { [weak self] rect in
            guard let self else { return }
            self.overlay = nil
            self.stopKeyDisplaySession()
            self.beginBeautify(rect)
        }
        controller.onCancelled = { [weak self] in
            guard let self else { return }
            // Esc / right-click closes the scrolling UI too; the session must
            // not keep sampling an overlay that no longer exists.
            let hadScroll = self.scrollController != nil
            self.scrollController?.abandon()
            self.scrollController = nil
            self.scrollOverlayView = nil
            self.scrollRegion = nil
            self.scrollScreen = nil
            self.scrollLiveShot = nil
            self.scrollFinalShot = nil
            self.scrollFinalRaw = nil
            self.scrollPendingAction = nil
            self.overlay = nil
            self.stopKeyDisplaySession()
            DebugLog.log("capture: cancelled scroll=\(hadScroll)")
            // Esc is a finished capture too: give the keyboard back to the app
            // the user was in instead of keeping our (unshown) main window as
            // the active app.
            OverlayActivation.restoreIfNeeded()
        }

        overlay = controller
        startKeyDisplaySessionIfEnabled()
        if let testScreen {
            // Real panels, real view, real callbacks — only the ScreenCaptureKit
            // backdrop is skipped (the harness has no window server snapshot).
            controller.presentPanelsForTesting(on: testScreen)
        } else {
            controller.present()
        }
        return controller
    }

    /// Self-test hook: the shipping region-recording entry point with its real
    /// panels and every production callback, for the end-to-end 录制中 test.
    @discardableResult
    func presentRecordingOverlayForTesting(
        on screen: NSScreen,
        prefill: CGRect
    ) -> CaptureOverlayController {
        presentOverlay(
            mode: .region,
            prefill: prefill,
            screen: screen,
            recordingMode: true,
            windowPickEnabled: true,
            panelsForTestingOn: screen
        )
    }

    /// "Copy and keep" never closes the overlay, so it does not go through
    /// `handleRegion`. The controller supplies the pixels (startup snapshot).
    private func handleCopyKeeping(
        _ rect: CGRect,
        annotations: [Annotation],
        shot: CapturedScreenshot?
    ) {
        guard let shot else {
            report(CaptureError.shareableContentUnavailable("无法取得选区的像素"))
            return
        }
        let flattened = shot.flattened(annotations: annotations)
        copyToPasteboard(decorated(flattened))
        lastMessage = "已拷贝并保留（可继续编辑）"
        playCaptureSoundIfEnabled()
        DebugLog.log(
            "capture: copy-keeping \(NSStringFromRect(rect)) annotations=\(annotations.count)"
        )
    }

    private func handleRegion(
        _ rect: CGRect,
        annotations: [Annotation],
        action: CaptureToolbarAction
    ) {
        guard action != .cancel, !action.keepsOverlayOpen else { return }
        guard let screen = Self.screen(containing: rect) else {
            report(CaptureError.noDisplay)
            return
        }

        let delivery: CaptureDelivery
        switch action {
        case .copyClosing: delivery = .copy
        case .save: delivery = .save
        case .saveAs: delivery = .saveAs
        case .pin: delivery = .pin
        case .ocr: delivery = .ocr
        // `.record` belongs to the recording overlay and is intercepted before
        // this funnel. Reaching here would mean a recording action on a
        // screenshot path, which must capture nothing rather than copy a box.
        case .record, .copyKeeping, .cancel: return
        }

        DebugLog.log(
            "capture: region \(NSStringFromRect(rect)) action=\(action.rawValue) "
            + "annotations=\(annotations.count)"
        )
        captureArea(rect, on: screen, delivery: delivery, annotations: annotations)
    }

    // MARK: - Pixel acquisition

    private func captureArea(
        _ rect: CGRect,
        on screen: NSScreen,
        delivery: CaptureDelivery,
        annotations: [Annotation]
    ) {
        isBusy = true
        Task { @MainActor in
            defer { isBusy = false }
            do {
                // Let the overlay panels actually leave the screen before the
                // compositor samples it, otherwise they appear in the shot.
                try await Task.sleep(nanoseconds: 140_000_000)
                let shot = try await ScreenCapture.captureArea(
                    rect,
                    on: screen,
                    includeCursor: settings.captureCursor
                )
                // P1a: annotations are baked into the pixels for copy, save and
                // pin alike. The normalised geometry is resolved against the
                // image's pixel size here, so Retina needs no special case.
                // The window corner (P6) is cut out of the delivered pixels:
                // the veil's rounding is a preview, this is the file.
                let flattened = shot.flattened(annotations: annotations)
                let cornered = CapturedScreenshot(
                    image: CaptureCorner.clipped(flattened.image, scale: flattened.scale),
                    scale: flattened.scale
                )
                try deliver(cornered, as: delivery, pinFrame: rect)
                // OCR is the one delivery that can keep the session alive for
                // its result card; the card hands focus back when it closes.
                if delivery != .ocr || ocrWindow == nil {
                    restoreFocusAfterCapture()
                }
            } catch is SavePanelCancelled {
                lastMessage = "已取消保存"
                lastErrorMessage = nil
                restoreFocusAfterCapture()
            } catch {
                report(error)
                restoreFocusAfterCapture()
            }
        }
    }

    /// Hand the keyboard back after a capture has been delivered.
    ///
    /// This runs *after* the pixels exist on purpose: a region or window shot
    /// samples the other application while this one is still active, and
    /// switching apps first would give the captured window an active title bar.
    /// A no-op when the capture was started from an already-active app (there
    /// is nothing to hand back).
    private func restoreFocusAfterCapture() {
        OverlayActivation.restoreIfNeeded()
    }

    private func captureFullScreenNow(on target: NSScreen? = nil) {
        guard let screen = target ?? Self.screenUnderMouse() else {
            report(CaptureError.noDisplay)
            return
        }
        isBusy = true
        Task { @MainActor in
            defer { isBusy = false }
            do {
                let shot = try await ScreenCapture.captureFullScreen(
                    screen,
                    includeCursor: settings.captureCursor
                )
                try deliver(shot, as: .copy, pinFrame: screen.frame)
                restoreFocusAfterCapture()
            } catch {
                report(error)
                restoreFocusAfterCapture()
            }
        }
    }

    /// A single click in the region overlay resolved to this window. Delivers
    /// exactly like a region shot (copy + close) and never opens an editor: the
    /// click itself was the confirmation, so there is nothing left to confirm.
    private func capturePickedWindowNow(_ windowID: CGWindowID) {
        isBusy = true
        Task { @MainActor in
            defer { isBusy = false }
            do {
                // Long enough for the closing overlay to stop being the key
                // window; the window's own pixels do not depend on it, but its
                // inactive title bar should settle before the shot.
                try await Task.sleep(nanoseconds: 80_000_000)
                let shot = try await ScreenCapture.captureWindow(windowID)
                DebugLog.log(
                    "window-pick: captured window \(windowID) "
                    + "pixels=\(shot.image.width)×\(shot.image.height)"
                )
                try deliver(shot, as: .copy, pinFrame: nil)
                restoreFocusAfterCapture()
            } catch {
                report(error, title: "窗口截图失败")
                restoreFocusAfterCapture()
            }
        }
    }

    /// Capture each selected window separately, then composite them at their
    /// screen positions. Windows are captured one at a time because
    /// `desktopIndependentWindow` is the only filter that reliably leaves out
    /// whatever is stacked above them.
    private func captureWindowsNow(_ selection: [(CGWindowID, CGRect)]) {
        guard !selection.isEmpty else { return }
        isBusy = true
        Task { @MainActor in
            defer { isBusy = false }
            do {
                // Let the overlay panels leave the compositor first.
                try await Task.sleep(nanoseconds: 140_000_000)

                var pieces: [MultiWindowComposer.Piece] = []
                for (windowID, frame) in selection {
                    do {
                        let shot = try await ScreenCapture.captureWindow(windowID)
                        pieces.append(MultiWindowComposer.Piece(image: shot.image, frame: frame))
                    } catch {
                        DebugLog.log(
                            "multi-window: window \(windowID) failed: \(error.localizedDescription)"
                        )
                    }
                }
                guard !pieces.isEmpty else { throw CaptureError.windowNotFound }
                guard let union = MultiWindowComposer.boundingRect(of: pieces.map(\.frame)) else {
                    throw CaptureError.encodingFailed
                }
                let scale = Self.screen(containing: union)?.backingScaleFactor ?? 2
                guard let composed = MultiWindowComposer.compose(pieces: pieces, scale: scale) else {
                    throw CaptureError.encodingFailed
                }
                DebugLog.log(
                    "multi-window: composed \(pieces.count)/\(selection.count) "
                    + "window(s) \(composed.width)×\(composed.height) px"
                )
                try deliver(
                    CapturedScreenshot(image: composed, scale: scale),
                    as: .copy,
                    pinFrame: union
                )
                restoreFocusAfterCapture()
            } catch {
                report(error)
                restoreFocusAfterCapture()
            }
        }
    }

    // MARK: - Delivery

    // MARK: Export decoration (截图圆角 / 截图阴影)

    /// JPEG cannot carry the transparent padding a shadow needs, so a rounded
    /// JPEG is composited onto white instead of the encoder's black.
    private var exportBackground: NSColor? {
        settings.captureFormat.lowercased() == "jpg" ? .white : nil
    }

    /// Applies the user's corner/shadow settings to one export copy of `shot`.
    /// Returns `shot` untouched when both toggles are off, so an untouched
    /// install keeps the exact pixels it always had.
    private func decorated(
        _ shot: CapturedScreenshot,
        opaqueBackground: NSColor? = nil
    ) -> CapturedScreenshot {
        let decoration = settings.screenshotDecoration
        guard decoration.isActive else { return shot }
        let image = ScreenshotDecorator.render(
            shot.image,
            scale: shot.scale,
            decoration: decoration,
            background: opaqueBackground
        )
        DebugLog.log(
            "export: decorated \(shot.image.width)×\(shot.image.height) → "
            + "\(image.width)×\(image.height) radius=\(decoration.cornerRadius) "
            + "shadow=\(decoration.shadowSize)"
        )
        return CapturedScreenshot(image: image, scale: shot.scale)
    }

    /// The pinned panel is sized from the frame, so a padded export needs the
    /// frame grown by the same amount — otherwise the decoration would shrink
    /// the content the user just selected.
    private func pinFrameForPin(
        _ frame: CGRect?,
        shot: CapturedScreenshot,
        export: CapturedScreenshot
    ) -> CGRect? {
        guard let frame,
              shot.pointSize.width > 0,
              export.pointSize != shot.pointSize else { return frame }
        let dx = (export.pointSize.width - shot.pointSize.width) / 2
        let dy = (export.pointSize.height - shot.pointSize.height) / 2
        return CGRect(
            x: frame.minX - dx,
            y: frame.minY - dy,
            width: export.pointSize.width,
            height: export.pointSize.height
        )
    }

    private func deliver(
        _ shot: CapturedScreenshot,
        as delivery: CaptureDelivery,
        pinFrame: CGRect?,
        alsoSave: Bool = false
    ) throws {
        // 截图 → 保存 & 动作 → 截图圆角 / 截图阴影. Only the export deliveries
        // get the decoration: the overlay already showed the raw pixels, and
        // OCR must keep reading the undecorated text.
        var shouldPlayCaptureSound = true

        switch delivery {
        case .copy:
            copyToPasteboard(decorated(shot))
            let size = "\(Int(shot.pointSize.width.rounded())) × \(Int(shot.pointSize.height.rounded()))"
            if alsoSave {
                do {
                    let url = try writeToDisk(
                        decorated(shot, opaqueBackground: exportBackground)
                    )
                    lastMessage = "已拷贝并保存为 \(url.lastPathComponent)（\(size)）"
                } catch {
                    lastMessage = "已拷贝 \(size)，保存失败：\(error.localizedDescription)"
                    DebugLog.log("capture: save after copy failed: \(error.localizedDescription)")
                }
            } else {
                lastMessage = "已拷贝 \(size)"
            }

        case .save:
            let url = try writeToDisk(decorated(shot, opaqueBackground: exportBackground))
            lastMessage = "已保存到 \(url.lastPathComponent)"

        case .saveAs:
            let url = try presentSavePanel(for: decorated(shot, opaqueBackground: exportBackground))
            lastMessage = "已保存到 \(url.lastPathComponent)"

        case .pin:
            guard let model else { throw CaptureError.pinFailed }
            let export = decorated(shot)
            let pinned = model.pinboard.pinImage(
                export.nsImage,
                preferredFrame: pinFrameForPin(pinFrame, shot: shot, export: export)
            )
            guard pinned else { throw CaptureError.pinFailed }
            lastMessage = "已钉在屏幕上"

        case .ocr:
            // The empty case already beeps; the capture sound would double up.
            shouldPlayCaptureSound = presentOCR(for: shot)
        }

        if shouldPlayCaptureSound {
            playCaptureSoundIfEnabled()
        }
        DebugLog.log("capture: delivered \(String(describing: delivery)) \(lastMessage ?? "")")
    }

    /// Recognise text and barcodes, then either show the result card or give a
    /// lightweight nudge. An empty result is not an error worth a modal alert.
    /// Returns whether anything was recognised.
    @discardableResult
    private func presentOCR(for shot: CapturedScreenshot) -> Bool {
        let items = TextRecognition.recognize(in: shot.nsImage)
        guard !items.isEmpty else {
            lastMessage = "没有识别到文字或二维码"
            NSSound.beep()
            DebugLog.log("ocr: no results")
            // Nothing stays on screen: the capture is over.
            restoreFocusAfterCapture()
            return false
        }

        let model = OCRResultModel(items: items)

        // 设置 → OCR → 识别后直接复制并关闭: skip the card entirely.
        if settings.ocrAutoCopy {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(model.text, forType: .string)
            let barcodes = items.filter { $0.kind == .barcode }.count
            let texts = items.count - barcodes
            lastMessage = "已复制 \(texts) 段文字"
                + (barcodes > 0 ? " · \(barcodes) 个条码" : "")
            DebugLog.log("ocr: auto-copied \(items.count) item(s)")
            // No result card is going to stay on screen, so hand the keyboard
            // back now instead of leaving the app active with no front window.
            restoreFocusAfterCapture()
            return true
        }

        // A second OCR run replaces the first card instead of stacking panels.
        ocrWindow?.close()
        ocrWindow = nil

        let controller = OCRResultWindowController(items: items)
        controller.onClose = { [weak self] in
            self?.ocrWindow = nil
            DebugLog.log("ocr: result window closed")
            // The card kept the capture's activation session alive; closing it
            // is the end of the capture for focus purposes.
            self?.restoreFocusAfterCapture()
        }
        ocrWindow = controller
        controller.show()
        // `show()` activates for the card; keep the app's background windows
        // behind the application that was in front before the capture.
        OverlayActivation.activate()

        let barcodes = items.filter { $0.kind == .barcode }.count
        let texts = items.count - barcodes
        lastMessage = "识别到 \(texts) 段文字" + (barcodes > 0 ? " · \(barcodes) 个条码" : "")
        DebugLog.log(
            "ocr: \(items.count) item(s) text=\(texts) barcode=\(barcodes) "
            + "first=\(items.first?.text.prefix(40) ?? "-")"
        )
        return true
    }

    /// Shared by "copy and close" and "copy and keep".
    ///
    /// The pasteboard carries the same two representations the system
    /// screenshot tool publishes: PNG (which most apps ask for first) and TIFF
    /// (which AppKit's own `NSImage` reading uses). `encodedData` writes both
    /// with the selection's point size as their DPI, so a 1600×1200 capture of
    /// an 800×600 pt box lands as a 2× image everywhere instead of a 72 dpi
    /// bitmap that some destinations rasterise at one pixel per point.
    private func copyToPasteboard(_ shot: CapturedScreenshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        var hasData = false
        if let png = try? Self.encodedData(for: shot, format: "png") {
            item.setData(png, forType: .png)
            hasData = true
        }
        if let tiff = shot.nsImage.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
            hasData = true
        }
        if hasData, pasteboard.writeObjects([item]) {
            // Deliberately not syncing the monitor's change count: a screenshot
            // is content the user wants in the history too.
            return
        }
        // Encoding failed: the NSImage still carries the full-resolution frame.
        pasteboard.clearContents()
        pasteboard.writeObjects([shot.nsImage])
        // Deliberately not syncing the monitor's change count: a screenshot is
        // content the user wants in the history too.
    }

    /// `NSSavePanel` hand-off for the "保存至…" action.
    ///
    /// Split into "ask for a URL" (blocks in a modal, cannot be automated) and
    /// "write the file" (`writeScreenshot`, pure and covered by the self test).
    private func presentSavePanel(for shot: CapturedScreenshot) throws -> URL {
        guard let url = askForSaveURL() else { throw SavePanelCancelled() }
        try Self.writeScreenshot(shot, to: url, format: settings.captureFormat)
        return url
    }

    /// The blocking half: panel configuration plus `runModal`.
    private func askForSaveURL() -> URL? {
        let isJPEG = settings.captureFormat.lowercased() == "jpg"
        let fileExtension = isJPEG ? "jpg" : "png"

        let panel = NSSavePanel()
        panel.title = "保存截图"
        panel.canCreateDirectories = true
        panel.directoryURL = settings.captureDirectory
        panel.nameFieldStringValue = "截图-\(fileNameTimestamp()).\(fileExtension)"
        panel.allowedContentTypes = [isJPEG ? .jpeg : .png]

        // The panel is the only window that should come forward; the app's own
        // background windows stay where the capture found them.
        OverlayActivation.activate()
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private struct SavePanelCancelled: LocalizedError {
        var errorDescription: String? { "已取消保存。" }
    }

    private func writeToDisk(_ shot: CapturedScreenshot) throws -> URL {
        let directory = settings.captureDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let isJPEG = settings.captureFormat.lowercased() == "jpg"
        let fileExtension = isJPEG ? "jpg" : "png"
        let url = directory.appendingPathComponent(
            "截图-\(fileNameTimestamp()).\(fileExtension)"
        )
        try Self.writeScreenshot(shot, to: url, format: settings.captureFormat)
        return url
    }

    /// The file-writing half of both "存储" and "保存至…".
    ///
    /// Deliberately static and free of UI so the self test can point it at a
    /// temporary URL and assert the real bytes, dimensions and format without
    /// driving an `NSSavePanel`.
    static func writeScreenshot(
        _ shot: CapturedScreenshot,
        to url: URL,
        format: String
    ) throws {
        let data = try encodedData(for: shot, format: format)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    static func encodedData(
        for shot: CapturedScreenshot,
        format: String
    ) throws -> Data {
        let isJPEG = format.lowercased() == "jpg"
        let representation = NSBitmapImageRep(cgImage: shot.image)
        // Tell the file what size the user actually selected, in points. PNG
        // and JPEG carry that as their DPI: a 1600×1200 capture of an 800×600 pt
        // selection is written as 144 dpi, which is exactly what the system
        // screenshot tool writes. Leaving `NSBitmapImageRep` at its default
        // (pixels = points, 72 dpi) makes every app that inserts the picture at
        // "actual size" give it 1600×1200 pt — one image pixel per point — so
        // it renders at half resolution on a Retina screen and reads as soft.
        representation.size = shot.pointSize
        let data: Data?
        if isJPEG {
            data = representation.representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.9]
            )
        } else {
            data = representation.representation(using: .png, properties: [:])
        }
        guard let data else { throw CaptureError.encodingFailed }
        return data
    }

    private func playCaptureSoundIfEnabled() {
        guard settings.captureSound else { return }
        if let sound = NSSound(named: NSSound.Name("Grab")) {
            sound.play()
        } else {
            NSSound.beep()
        }
    }

    // MARK: - Errors

    private func report(_ error: Error, title: String = "截图失败") {
        let message = error.localizedDescription
        lastErrorMessage = message
        lastMessage = nil
        DebugLog.log("capture: error \(message)")

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")

        var permissionDenied = false
        if case CaptureError.screenRecordingDenied = error {
            permissionDenied = true
        }
        if permissionDenied {
            alert.addButton(withTitle: "打开系统设置")
        }

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if permissionDenied, response == .alertSecondButtonReturn {
            ScreenCapture.openScreenRecordingSettings()
        }
    }

    // MARK: - Geometry helpers

    static func screen(containing rect: CGRect) -> NSScreen? {
        NSScreen.screens.first { screen in
            let intersection = screen.frame.intersection(rect)
            return intersection.width >= SelectionBorderView.minimumSide
                && intersection.height >= SelectionBorderView.minimumSide
        } ?? NSScreen.screens.first { $0.frame.intersects(rect) }
            ?? NSScreen.main
    }

    /// The screen containing `point` (global AppKit points). Half-open like
    /// `CGRect.contains`, so a point on a shared edge picks the first screen.
    static func screen(under point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private static func screenUnderMouse() -> NSScreen? {
        screen(under: NSEvent.mouseLocation)
    }
}

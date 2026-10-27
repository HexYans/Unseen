import AppKit
import QuartzCore

/// A borderless, non-activating panel that can still become key so Escape and
/// Return reach the overlay.
final class CaptureOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns one overlay panel per screen and the overlay's lifecycle.
///
/// It converts the confirmed local rectangle back into global AppKit points
/// before handing it to the coordinator — the view never needs to know where
/// its screen is in the world, and the coordinator never needs to know about
/// panels.
///
/// Before the panels exist it captures one **full-screen snapshot per screen**.
/// The snapshot is not what the user sees (the dimming hole still reveals the
/// live desktop); it is the pixel source the mosaic preview needs, because by
/// the time a mosaic is drawn the selection's real pixels are long gone.
@MainActor
final class CaptureOverlayController {
    private struct Entry {
        let panel: CaptureOverlayPanel
        let view: CaptureOverlayView
        let screen: NSScreen
    }

    private var entries: [Entry] = []
    private let mode: CaptureOverlayView.Mode
    private let prefilledSelection: CGRect?
    private let showCrosshair: Bool
    private let preferredScreen: NSScreen?
    /// Passed through to the overlay's second toolbar row (export shadow +
    /// crosshair). Optional so the offscreen harness can present panels
    /// without touching the user's preferences.
    private let settings: AppSettings?
    /// Whether the *live* fallback capture (copy-and-keep without a snapshot)
    /// should include the cursor.
    private let includeCursor: Bool
    /// OCR entry: a finished new selection confirms with `.ocr` immediately.
    private let autoConfirmOnSelectionEnd: Bool
    /// Scroll entry: the same auto-confirm, but reported through
    /// `onScrollRegionConfirmed` instead of the OCR toolbar action.
    private let autoConfirmAsScroll: Bool
    /// Recording entry: the region grammar, but the toolbar offers 开始录制
    /// and nothing starts until Return / that button is used.
    private let recordingMode: Bool
    /// 套壳 / 美化 entry: the same auto-confirm, reported through
    /// `onBeautifyRegionConfirmed`.
    private let autoConfirmAsBeautify: Bool
    /// `.window` mode: the overlay opens already hovering, and only window
    /// clicks are accepted (no rectangle dragging).
    private let startsInWindowPick: Bool
    /// Whether a plain single click may resolve to a window. Off for OCR /
    /// scroll / recording / beautify / preset entries, where a stray click must
    /// stay a no-op instead of silently switching to window capture.
    private let windowPickEnabled: Bool
    private var didFinish = false
    private var isPreparing = false
    /// The live viewfinder's own window. Present for the whole scrolling
    /// session; closed with the overlay.
    private var scrollPreviewPanel: ScrollPreviewPanelController?
    /// Whether the session-scoped bare-Escape hot key is currently registered.
    /// It exists only while the overlay is click-through; see
    /// `installScrollEscapeHotKey`.
    private var scrollEscapeHotKeyInstalled = false
    /// A scrolling session asked for click-through so the page keeps the wheel.
    /// The request is not applied to the whole panel (that would kill the
    /// toolbar's clicks); `applyScrollPassthroughPolicy` turns it into a
    /// per-pointer decision. See `setScrollPassthrough`.
    private var scrollPassthroughRequested = false
    /// Polls `NSEvent.mouseLocation` while the session runs click-through. The
    /// panel cannot receive pointer events in that state, so a timer is the only
    /// way to know the pointer reached the toolbar.
    private var scrollPointerTimer: Timer?
    /// Pointer source for the hot-zone policy. Production reads the real
    /// pointer; the self test injects a point so the verdict does not depend on
    /// where the mouse happens to be during the run.
    var scrollPointerLocationOverride: CGPoint?
    /// 设置 → 滚图 → 显示进度卡片. Off means the session runs without the
    /// viewfinder; the selection and toolbar are unaffected.
    private var showsScrollPreview: Bool { settings?.scrollCaptureShowsHUD ?? true }
    /// Multi-window selection accumulated across panels, in global AppKit
    /// points and in click order (later clicks are drawn on top). The view owns
    /// its own per-screen highlight; this list is what makes a cross-screen
    /// selection possible.
    private var selectedWindows: [(id: CGWindowID, frame: CGRect)] = []
    /// 录制中: the recording HUD that replaces the capture toolbar. It is a
    /// separate panel because the overlay is click-through for the session (the
    /// recorded app has to stay usable) but the controls must take clicks.
    private var recordingIndicator: RecordingIndicatorController?
    /// The panel that owns the selection being recorded.
    private var recordingEntry: Entry?
    /// True from the moment 开始录制 is confirmed until the session is torn
    /// down. Guards a second confirm and makes the teardown idempotent.
    private var recordingIsLive = false

    /// Global rectangle in bottom-left AppKit points, plus the annotations
    /// normalised to that rectangle.
    var onRegionConfirmed: ((CGRect, [Annotation], CaptureToolbarAction) -> Void)?
    /// 录制中: the user confirmed 开始录制. The overlay deliberately stays open
    /// and becomes the recording UI; the coordinator starts the stream and
    /// reports the clock back through `updateRecordingHUD`.
    var onRecordingStarted: ((CGRect, NSScreen) -> Void)?
    /// The HUD's pause/resume button. The coordinator owns the recorder.
    var onRecordingPauseToggle: (() -> Void)?
    /// The HUD's stop button.
    var onRecordingStop: (() -> Void)?
    /// "Copy and keep". `CapturedScreenshot?` is `nil` only when neither the
    /// startup snapshot nor a temporary live capture produced pixels.
    var onCopyKeeping: ((CGRect, [Annotation], CapturedScreenshot?) -> Void)?
    /// Multi-window mode: the full selection, with global frames.
    var onWindowsConfirmed: (([(CGWindowID, CGRect)]) -> Void)?
    /// Window pick confirmed: the window id and its global frame.
    var onWindowPicked: ((CGWindowID, CGRect) -> Void)?
    /// Scroll entry: a new box is ready, in global points. The overlay stays
    /// open — the coordinator starts the session and drives the viewfinder.
    var onScrollSessionStarted: ((CGRect, NSScreen, CaptureOverlayView) -> Void)?
    /// Scrolling controls from the viewfinder footer.
    var onScrollToggleAuto: (() -> Void)?
    var onScrollStop: (() -> Void)?
    /// The finished long image was confirmed (Return or the footer's 完成).
    var onScrollConfirm: (() -> Void)?
    /// The finished long image was discarded (Esc or the shortcut).
    var onScrollClose: (() -> Void)?
    var onScrollResume: (() -> Void)?
    var onScrollAction: ((CaptureToolbarAction) -> Void)?
    var onScrollCopyCurrent: (([Annotation]) -> Void)?
    /// The box moved/resized; the session must sample the new global rectangle.
    var onScrollRegionCommitted: ((CGRect, NSScreen) -> Void)?
    /// The user's own wheel, forwarded to the page under the overlay.
    var onScrollWheel: ((NSEvent) -> Void)?
    /// 套壳 / 美化 entry: a finished new box, in global points.
    var onBeautifyRegionConfirmed: ((CGRect) -> Void)?
    var onCancelled: (() -> Void)?

    init(
        mode: CaptureOverlayView.Mode,
        prefilledSelection: CGRect?,
        showCrosshair: Bool,
        preferredScreen: NSScreen? = nil,
        includeCursor: Bool = false,
        settings: AppSettings? = nil,
        autoConfirmOnSelectionEnd: Bool = false,
        autoConfirmAsScroll: Bool = false,
        recordingMode: Bool = false,
        autoConfirmAsBeautify: Bool = false,
        startsInWindowPick: Bool = false,
        windowPickEnabled: Bool = true
    ) {
        self.mode = mode
        self.prefilledSelection = prefilledSelection
        self.showCrosshair = showCrosshair
        self.preferredScreen = preferredScreen
        self.settings = settings
        self.includeCursor = includeCursor
        self.autoConfirmOnSelectionEnd = autoConfirmOnSelectionEnd
        self.autoConfirmAsScroll = autoConfirmAsScroll
        self.recordingMode = recordingMode
        self.autoConfirmAsBeautify = autoConfirmAsBeautify
        self.startsInWindowPick = startsInWindowPick
        self.windowPickEnabled = windowPickEnabled
    }

    var isPresenting: Bool { !entries.isEmpty || isPreparing }

    /// Test seams: the self test drives the real panels and asserts that a
    /// picked/empty single click leaves them in the expected state.
    var overlayViewsForTesting: [CaptureOverlayView] { entries.map(\.view) }
    var panelsForTesting: [CaptureOverlayPanel] { entries.map(\.panel) }
    var hasPanelsForTesting: Bool { !entries.isEmpty }
    /// The click-through flag of every live panel, in screen order. The scroll
    /// session must put it back to `false` when it ends.
    var panelPassthroughForTesting: [Bool] { entries.map(\.panel.ignoresMouseEvents) }

    /// Build the real panels synchronously, skipping the ScreenCaptureKit
    /// snapshot. The lifecycle under test (a pick closes every panel) does not
    /// depend on the backdrop, and the async snapshot can take seconds or wedge
    /// under a busy window server.
    func presentPanelsForTesting(on screen: NSScreen) {
        guard entries.isEmpty, !isPreparing, !didFinish else { return }
        buildPanels(screens: [screen], snapshots: [:])
    }

    // MARK: - Presentation

    /// Capture the snapshots **before** any panel exists, then build the
    /// panels. Failure is not fatal: the overlay opens without a base image and
    /// mosaic previews degrade to a placeholder.
    func present() {
        guard entries.isEmpty, !isPreparing, !didFinish else { return }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        isPreparing = true
        // Activate before the async snapshot: activation is asynchronous, and
        // waiting for it here means the panels are ordered into an already
        // active app and get their first display pass immediately.
        //
        // Activating an app raises *all* of its visible windows, including a
        // settings page the user had covered with another app. `begin()`
        // records those windows first; the helper pushes them back behind the
        // front app once activation has landed.
        OverlayActivation.begin()
        OverlayActivation.activate()
        Task { @MainActor [weak self] in
            guard let self else { return }
            var snapshots: [CGDirectDisplayID: CapturedScreenshot] = [:]

            for screen in screens {
                do {
                    snapshots[screen.displayID] = try await ScreenCapture.captureFullScreen(
                        screen,
                        includeCursor: false
                    )
                } catch {
                    DebugLog.log(
                        "overlay: snapshot failed on \(screen.localizedName): "
                        + error.localizedDescription
                    )
                }
            }

            self.isPreparing = false
            guard !self.didFinish, self.entries.isEmpty else { return }
            self.buildPanels(screens: screens, snapshots: snapshots)
        }
    }

    private func buildPanels(
        screens: [NSScreen],
        snapshots: [CGDirectDisplayID: CapturedScreenshot]
    ) {
        let mouseLocation = NSEvent.mouseLocation
        DebugLog.log(
            "overlay: buildPanels screens=\(screens.count) snapshots=\(snapshots.count) "
            + "isActive=\(NSApp.isActive) policy=\(NSApp.activationPolicy().rawValue)"
        )

        // Activate *before* ordering the panels. Presentation now happens
        // after an async snapshot, and an inactive app's fresh non-activating
        // panel can be ordered on screen without ever getting a display pass —
        // the overlay then looks blank until the first pointer event.
        // Activating first and forcing a display after ordering narrows that
        // gap; the first pointer-down is also what makes the window server
        // composite the fresh surface in the environment we tested.
        OverlayActivation.activate()
        DebugLog.log("overlay: activate requested, isActive=\(NSApp.isActive)")

        for screen in screens {
            let panel = CaptureOverlayPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .screenSaver
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.animationBehavior = .none
            panel.isMovableByWindowBackground = false
            panel.collectionBehavior = [
                .canJoinAllSpaces,
                .fullScreenAuxiliary,
                .stationary,
                .ignoresCycle
            ]
            panel.ignoresMouseEvents = false
            // Without this AppKit does not deliver mouseMoved, so the
            // multi-window hover highlight and the crosshair would never update.
            panel.acceptsMouseMovedEvents = true

            let localPrefill = Self.localRect(
                for: prefilledSelection,
                on: screen
            )

            let snapshot = snapshots[screen.displayID]
            // Derive pixels-per-point from the actual image, so a scaled
            // display's snapshot maps correctly even if it is not exactly 2×.
            let imageScale: CGSize = {
                guard let snapshot else { return .zero }
                let width = max(1, screen.frame.width)
                let height = max(1, screen.frame.height)
                return CGSize(
                    width: CGFloat(snapshot.image.width) / width,
                    height: CGFloat(snapshot.image.height) / height
                )
            }()

            let view = CaptureOverlayView(
                frame: CGRect(origin: .zero, size: screen.frame.size),
                mode: mode,
                prefilledSelection: localPrefill,
                showCrosshair: showCrosshair,
                rendersOffscreen: false,
                baseImage: snapshot?.image,
                baseImageScale: imageScale,
                autoConfirmOnSelectionEnd: autoConfirmOnSelectionEnd,
                startsInWindowPick: startsInWindowPick,
                windowPickEnabled: windowPickEnabled,
                showLoupe: settings?.showLoupe ?? true,
                scrollMode: autoConfirmAsScroll,
                scrollPreviewEnabled: settings?.scrollCaptureShowsHUD ?? true,
                scrollPreviewExternal: autoConfirmAsScroll,
                recordingMode: recordingMode,
                settings: settings
            )
            view.screenFrame = screen.frame
            view.onConfirm = { [weak self] localRect, annotations, action in
                self?.finishRegion(localRect, annotations: annotations, action: action, on: screen)
            }
            view.onCopyKeeping = { [weak self] localRect, annotations in
                self?.copyKeeping(
                    localRect,
                    annotations: annotations,
                    on: screen,
                    snapshot: snapshot
                )
            }
            if autoConfirmAsScroll {
                // The overlay is *not* closed here: that is the whole change.
                // The pod and the controls live in this same panel, and the
                // selection stays visible and grabbable for the entire session.
                view.onSelectionDrawn = { [weak self, weak view] localRect, annotations in
                    guard let self, let view else { return }
                    let global = Self.globalRect(localRect, on: screen)
                    self.presentScrollPreview(for: global, on: screen)
                    self.onScrollSessionStarted?(global, screen, view)
                    _ = annotations
                }
                view.onScrollToggleAuto = { [weak self] in self?.onScrollToggleAuto?() }
                view.onScrollStop = { [weak self] in self?.onScrollStop?() }
                view.onScrollConfirm = { [weak self] in self?.onScrollConfirm?() }
                view.onScrollClose = { [weak self] in self?.onScrollClose?() }
                view.onScrollResume = { [weak self] in self?.onScrollResume?() }
                view.onScrollAction = { [weak self] action in self?.onScrollAction?(action) }
                view.onScrollCopyCurrent = { [weak self] annotations in
                    self?.onScrollCopyCurrent?(annotations)
                }
                view.onScrollRegionCommitted = { [weak self] localRect in
                    guard let self else { return }
                    let global = Self.globalRect(localRect, on: screen)
                    self.presentScrollPreview(for: global, on: screen)
                    self.onScrollRegionCommitted?(global, screen)
                }
                view.onScrollWheel = { [weak self] event in self?.onScrollWheel?(event) }
            } else if autoConfirmAsBeautify {
                view.onSelectionDrawn = { [weak self] localRect, _ in
                    self?.finishBeautifyRegion(localRect, on: screen)
                }
            }
            // Both multi-window mode and the region overlay's Shift-click set
            // report through these three callbacks.
            view.onWindowToggled = { [weak self] windowID, localRect, selected in
                self?.trackWindow(windowID, localRect: localRect, selected: selected, on: screen)
            }
            view.onWindowSelectionCleared = { [weak self] in
                self?.clearWindowSelection()
            }
            view.onWindowsConfirmed = { [weak self] _ in
                self?.finishWindows()
            }
            view.onWindowPicked = { [weak self] windowID, localRect in
                self?.finishPickedWindow(windowID, localRect: localRect, on: screen)
            }
            view.onCancel = { [weak self] in
                self?.cancel()
            }

            panel.contentView = view
            panel.makeFirstResponder(view)
            panel.orderFrontRegardless()
            // Explicitly place the panel above every other window in its level;
            // orderFrontRegardless alone can leave the surface ordered but not
            // composited until the next mouse-down in some display states.
            panel.order(.above, relativeTo: 0)
            DebugLog.log(
                "overlay: ordered \(screen.localizedName) visible=\(panel.isVisible) "
                + "alpha=\(panel.alphaValue) frame=\(NSStringFromRect(panel.frame))"
            )
            entries.append(Entry(panel: panel, view: view, screen: screen))
        }

        // The panel under the pointer becomes key; other screens are still
        // dimmed and clickable.
        let keyEntry = entries.first { entry in
            if let preferredScreen {
                return entry.screen === preferredScreen
            }
            return entry.screen.frame.contains(mouseLocation)
        } ?? entries[0]
        keyEntry.panel.makeKeyAndOrderFront(nil)
        keyEntry.panel.makeFirstResponder(keyEntry.view)
        DebugLog.log(
            "overlay: keyed isKey=\(keyEntry.panel.isKeyWindow) "
            + "appKey=\(NSApp.keyWindow === keyEntry.panel)"
        )

        // Force the first frame now; see the activation note above.
        for entry in entries {
            entry.view.needsDisplay = true
            entry.view.displayIfNeeded()
        }
        CATransaction.flush()

        // A newly ordered panel occasionally misses its first display pass
        // when presentation follows an async snapshot: the window server has
        // the surface, but the content is only committed after the next user
        // event (which made the first hotkey look blank until the user
        // dragged). Re-assert the display on the next run-loop turns.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self, !self.didFinish else { return }
            DebugLog.log(
                "overlay: reassert display isActive=\(NSApp.isActive) "
                + "keyWindow=\(String(describing: NSApp.keyWindow))"
            )
            OverlayActivation.activate()
            for entry in self.entries {
                entry.panel.orderFrontRegardless()
                if entry.screen.frame.contains(NSEvent.mouseLocation) {
                    entry.panel.makeKeyAndOrderFront(nil)
                }
                entry.panel.viewsNeedDisplay = true
                entry.view.needsDisplay = true
                entry.view.displayIfNeeded()
            }
            CATransaction.flush()
            // This second activation can raise the app's other windows again;
            // put them back behind the front app.
            OverlayActivation.sinkIfNeeded()
        }
    }

    // MARK: - Scrolling viewfinder

    /// Create (or move) the live viewfinder window for a global box.
    func presentScrollPreview(for globalRect: CGRect, on screen: NSScreen) {
        guard showsScrollPreview else { return }
        let placement = ScrollPreviewPlacement.make(
            region: globalRect,
            screen: screen.frame
        )
        if scrollPreviewPanel == nil {
            let panel = ScrollPreviewPanelController()
            panel.onToggleAutoScroll = { [weak self] in self?.onScrollToggleAuto?() }
            panel.onStop = { [weak self] in self?.onScrollStop?() }
            panel.onConfirm = { [weak self] in self?.onScrollConfirm?() }
            panel.onResume = { [weak self] in self?.onScrollResume?() }
            // The card shrinks once the page is longer than the selection, and
            // the session must compose its band at the size the *panel's* pod
            // actually draws. The view is the one that owns the session callback
            // (`onScrollPreviewSizeChanged`), so the panel reports through it.
            panel.pod.onDrawnSizeChange = { [weak self] size in
                guard let self else { return }
                for entry in self.entries {
                    entry.view.adoptScrollBandSize(
                        ScrollPreviewPod.bandSize(forCardSize: size)
                    )
                }
            }
            scrollPreviewPanel = panel
            DebugLog.log("scroll: viewfinder panel at \(NSStringFromRect(placement.frame))")
        }
        scrollPreviewPanel?.present(placement: placement)
    }

    /// Feed the live viewfinder. Called by the coordinator after every sample.
    func updateScrollPreview(
        preview: ScrollPreviewFrame?,
        phase: ScrollPreviewPod.Phase,
        autoScrolling: Bool
    ) {
        if phase != .finished { scrollPreviewPanel?.pod.isResumable = false }
        scrollPreviewPanel?.update(
            preview: preview,
            phase: phase,
            autoScrolling: autoScrolling
        )
        // The captured-length boundary lives in the overlay, next to the
        // selection it describes — not in the viewfinder's own window.
        for entry in entries {
            entry.view.updateScrollProgress(preview)
        }
    }

    /// Show the finished long image in whichever viewfinder is live.
    /// `resumable` decides whether the footer also offers 继续.
    func presentScrollResult(_ image: CGImage?, resumable: Bool = false) {
        if let panel = scrollPreviewPanel {
            let size = ScrollPreviewPod.bandSize(forCardSize: panel.pod.bandCardSize)
            panel.pod.isResumable = resumable
            panel.update(
                preview: image.flatMap { ScrollPreviewFrame.make(from: $0, size: size) },
                phase: .finished,
                autoScrolling: false
            )
        }
        for entry in entries {
            entry.view.presentScrollResult(image, resumable: resumable)
        }
    }

    /// Mouse-transparency for the capture panels. While it is on, the wheel
    /// reaches the page underneath; the viewfinder keeps its own window and
    /// stays clickable.
    ///
    /// Transparency alone is not enough. macOS delivers a scroll wheel to the
    /// window under the pointer *of the active application*; when this app is
    /// the active one and its full-screen panel has just been made
    /// click-through, the wheel is addressed to that panel and then discarded —
    /// it reaches neither the view's `scrollWheel` nor the page. Measured on
    /// the shipping build: 8 of 8 physical wheels disappeared this way.
    ///
    /// So the session also hands activation to the application that owns the
    /// page, exactly as if the user had clicked it. The overlay keeps drawing
    /// (its level is `.screenSaver`, far above the page) and the viewfinder is
    /// a separate window, so both stay visible and clickable.
    ///
    /// "Click-through" is not a property of the whole panel any more, because
    /// the capture toolbar — ✕, 拷贝, 保存, OCR — is a subview of that same
    /// panel: with the panel click-through its clicks fell on the page and the
    /// ✕ looked broken. The request is applied per pointer position instead:
    /// click-through everywhere, so the page keeps the wheel, and an interactive
    /// window exactly while the pointer is on the toolbar
    /// (`applyScrollPassthroughPolicy`). The toolbar stays reachable, the page
    /// keeps scrolling natively, and no wheel is ever re-posted.
    func setScrollPassthrough(_ enabled: Bool, targetPID: pid_t? = nil) {
        guard !didFinish else { return }
        if enabled {
            let alreadyRequested = scrollPassthroughRequested
            scrollPassthroughRequested = true
            // The page now owns the keyboard, so there is no `keyDown` left
            // for Esc. Own it for as long as the passthrough lasts.
            installScrollEscapeHotKey()
            if !alreadyRequested { startScrollPointerTracking() }
            // Give the page's own application the wheel. `activate` is what
            // makes the difference between "transparent and scrolling" and
            // "transparent and swallowing".
            if let targetPID,
               let pageApp = NSRunningApplication(processIdentifier: targetPID) {
                DebugLog.log(
                    "scroll: handing activation to \(pageApp.localizedName ?? "?") "
                        + "(pid \(targetPID))"
                )
                pageApp.activate(options: [])
                DebugLog.log(
                    "scroll: page activation requested, ours=\(NSApp.isActive) "
                        + "front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")"
                )
            }
            applyScrollPassthroughPolicy()
        } else {
            scrollPassthroughRequested = false
            stopScrollPointerTracking()
            for entry in entries {
                entry.view.setScrollPointerOverToolbar(false)
                if entry.panel.ignoresMouseEvents {
                    entry.panel.ignoresMouseEvents = false
                }
            }
            // Esc goes back to the overlay's own `keyDown` as soon as the app
            // owns the keyboard again.
            removeScrollEscapeHotKey()
            // The overlay is the interaction surface again: after a scroll run
            // that was click-through, the wheel, Return and Esc must come back
            // to it. Asked for unconditionally because `NSApp.isActive` reports
            // true while another app is frontmost in this state (measured on
            // the shipping build), so gating on it skipped the request.
            OverlayActivation.activate()
            entries.first?.panel.makeKey()
            DebugLog.log(
                "scroll: activation back to us requested "
                    + "ours=\(NSApp.isActive) "
                    + "front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")"
            )
        }
        DebugLog.log(
            "scroll: panel passthrough=\(enabled) appActive=\(NSApp.isActive)"
        )
    }

    /// Turn the session's click-through request into a per-pointer decision.
    ///
    /// * pointer away from the toolbar → the panel ignores mouse events, so the
    ///   page under it gets the wheel natively;
    /// * pointer on the toolbar → the panel is an ordinary (but non-activating)
    ///   window again, so the plate's controls take the click even though the
    ///   page is still the active application.
    ///
    /// Only the difference is written, so a 60 Hz tick does not churn the
    /// window server. The interactive ring is the toolbar plus a few points
    /// (`CaptureOverlayView.scrollToolbarHotMargin`); everything else stays
    /// click-through, including the rest of the selection.
    private func applyScrollPassthroughPolicy() {
        guard scrollPassthroughRequested, !didFinish else { return }
        let pointer = scrollPointerLocationOverride ?? NSEvent.mouseLocation
        for entry in entries {
            let hot = entry.view.scrollToolbarScreenFrame.map { frame in
                frame.insetBy(
                    dx: -CaptureOverlayView.scrollToolbarHotMargin,
                    dy: -CaptureOverlayView.scrollToolbarHotMargin
                ).contains(pointer)
            } ?? false
            entry.view.setScrollPointerOverToolbar(hot)
            let ignoresMouseEvents = !hot
            guard entry.panel.ignoresMouseEvents != ignoresMouseEvents else { continue }
            entry.panel.ignoresMouseEvents = ignoresMouseEvents
            DebugLog.log(
                "scroll: pointer \(hot ? "on" : "off") the toolbar → panel "
                    + (ignoresMouseEvents ? "click-through" : "interactive")
                    + " pointer=\(NSStringFromPoint(pointer))"
            )
        }
    }

    /// Track the pointer for as long as the session is click-through. A timer is
    /// the only transport available: the click-through panel deliberately
    /// receives no mouse events, and a global event monitor would need
    /// Accessibility / Input Monitoring access this app does not ask for (see
    /// `GlobalHotKeyCenter`). The poll is main-thread, allocation-free and only
    /// alive for a scrolling session.
    private func startScrollPointerTracking() {
        guard scrollPointerTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated { self.applyScrollPassthroughPolicy() }
        }
        RunLoop.main.add(timer, forMode: .common)
        scrollPointerTimer = timer
    }

    private func stopScrollPointerTracking() {
        scrollPointerTimer?.invalidate()
        scrollPointerTimer = nil
    }

    /// Register bare Esc for the click-through window of a scroll session.
    ///
    /// The handler funnels into `CaptureOverlayView.handleScrollEscape()`, so
    /// Esc ends exactly like it does in region / window / full-screen mode:
    /// cancel the sampling (or discard the pending long image), close the
    /// overlay and viewfinder, restore the mouse-transparency flag and hand
    /// activation back. Carbon hot keys are the app's existing transport and
    /// need no Accessibility grant.
    private func installScrollEscapeHotKey() {
        guard !scrollEscapeHotKeyInstalled else { return }
        scrollEscapeHotKeyInstalled = GlobalHotKeyCenter.shared.setScrollEscape { [weak self] in
            guard let self, !self.didFinish else { return }
            DebugLog.log("scroll: escape hotkey fired while click-through")
            for entry in self.entries {
                entry.view.handleScrollEscape()
            }
        }
        if !scrollEscapeHotKeyInstalled {
            DebugLog.log("scroll: Esc hotkey unavailable; ⌥Z still ends the session")
        }
    }

    private func removeScrollEscapeHotKey() {
        guard scrollEscapeHotKeyInstalled else { return }
        scrollEscapeHotKeyInstalled = false
        GlobalHotKeyCenter.shared.clearScrollEscape()
    }

    /// Test seam: false once the session has released Esc.
    var isScrollEscapeHotKeyInstalledForTesting: Bool { scrollEscapeHotKeyInstalled }

    /// Test seam: whether the session still wants the panels click-through.
    var scrollPassthroughRequestedForTesting: Bool { scrollPassthroughRequested }
    /// Test seam: whether the pointer poller is alive.
    var isScrollPointerTrackingForTesting: Bool { scrollPointerTimer != nil }
    /// Test seam: re-evaluate the hot-zone policy without waiting for a tick.
    func applyScrollPassthroughPolicyForTesting() { applyScrollPassthroughPolicy() }

    var scrollPreviewPanelForTesting: ScrollPreviewPanelController? { scrollPreviewPanel }

    func close() {
        // Also marks the controller finished so a snapshot task that is still
        // in flight cannot build panels after an early cancel.
        didFinish = true
        isPreparing = false
        // A direct close (cancel, a failed start) must never leave the
        // recording HUD or the pointer poller behind.
        recordingIndicator?.hide()
        recordingIndicator = nil
        recordingEntry?.view.endRecordingUI()
        recordingEntry = nil
        recordingIsLive = false
        // A cancel can arrive while the session is still click-through (Esc,
        // the ⌥Z hotkey, a failed sample); never leave bare Esc owned by us or
        // a transparent panel behind. The pointer poller that keeps the toolbar
        // clickable goes with it, or it would tick forever on a dead session.
        scrollPassthroughRequested = false
        stopScrollPointerTracking()
        removeScrollEscapeHotKey()
        scrollPreviewPanel?.close()
        scrollPreviewPanel = nil
        OverlayActivation.logWindowOrder("close-before")
        for entry in entries {
            let number = entry.panel.windowNumber
            let wasKey = entry.panel.isKeyWindow
            entry.panel.ignoresMouseEvents = false
            entry.panel.orderOut(nil)
            DebugLog.log(
                "overlay: ordered out panel #\(number) wasKey=\(wasKey) "
                + "keyNow=\(NSApp.keyWindow?.windowNumber ?? -1)"
            )
            OverlayActivation.logWindowOrder("close-after-out")
            entry.panel.contentView = nil
        }
        entries.removeAll()
        selectedWindows.removeAll()
        // Ordering out the key panel hands key status to the next window this
        // app owns (the settings page) and AppKit orders it in, which lifts it
        // above the application the user came from — the flash the finish path
        // must not show. Put the recorded windows straight back; this runs in
        // the same run-loop turn as the order-out, so the window server only
        // ever commits the restored order.
        OverlayActivation.sinkIfNeeded()
        OverlayActivation.logWindowOrder("close-after-sink")
    }

    // MARK: - Copy and keep

    /// The overlay must stay open, so it cannot be closed for a live shot. The
    /// startup snapshot is the normal source; when it is unavailable (screen
    /// recording denied or a transient failure) the panels are hidden just long
    /// enough to sample the live desktop and then restored with their state.
    private func copyKeeping(
        _ localRect: CGRect,
        annotations: [Annotation],
        on screen: NSScreen,
        snapshot: CapturedScreenshot?
    ) {
        let global = Self.globalRect(localRect, on: screen)

        if let snapshot, let cropped = Self.crop(snapshot, localRect: localRect, on: screen) {
            onCopyKeeping?(global, annotations, CapturedScreenshot(
                image: cropped,
                scale: snapshot.scale
            ))
            return
        }

        // Degraded path: hide the panels, sample, restore. State (selection,
        // annotations, key status) is never touched; only visibility blinks.
        let restore = entries
        let keyPanel = NSApp.keyWindow as? CaptureOverlayPanel
        let keyView = restore.first { $0.panel === keyPanel }?.view

        for entry in restore { entry.panel.orderOut(nil) }

        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 140_000_000)
            let shot = try? await ScreenCapture.captureArea(
                global,
                on: screen,
                includeCursor: self.includeCursor
            )

            for entry in restore {
                entry.panel.orderFrontRegardless()
            }
            if let keyPanel, restore.contains(where: { $0.panel === keyPanel }) {
                keyPanel.makeKeyAndOrderFront(nil)
                if let keyView { keyPanel.makeFirstResponder(keyView) }
            }
            self.onCopyKeeping?(global, annotations, shot)
        }
    }

    /// Crop the selection out of a full-screen snapshot. The snapshot is
    /// screen-sized in pixels; the selection is bottom-left points local to
    /// that screen.
    static func crop(
        _ snapshot: CapturedScreenshot,
        localRect: CGRect,
        on screen: NSScreen
    ) -> CGImage? {
        guard screen.frame.width > 0, screen.frame.height > 0 else { return nil }
        let scaleX = CGFloat(snapshot.image.width) / screen.frame.width
        let scaleY = CGFloat(snapshot.image.height) / screen.frame.height

        let pixelRect = CGRect(
            x: localRect.minX * scaleX,
            y: (screen.frame.height - localRect.maxY) * scaleY,
            width: localRect.width * scaleX,
            height: localRect.height * scaleY
        ).integral

        let bounds = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(snapshot.image.width),
            height: CGFloat(snapshot.image.height)
        )
        let clipped = pixelRect.intersection(bounds)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }
        return snapshot.image.cropping(to: clipped)
    }

    // MARK: - Finish

    private func finishRegion(
        _ localRect: CGRect,
        annotations: [Annotation],
        action: CaptureToolbarAction,
        on screen: NSScreen
    ) {
        guard !didFinish else { return }
        let global = Self.globalRect(localRect, on: screen)

        // 录制 is the one delivery action that does *not* close the overlay:
        // the selector becomes the recording UI. The mask, the border, its
        // handles, the size chip and the crosshair stay exactly where the
        // screenshot overlay put them; only the toolbar is swapped for the
        // recording HUD, in the same place.
        if action == .record, recordingMode {
            beginRecordingSession(on: screen)
            onRecordingStarted?(global, screen)
            return
        }

        didFinish = true
        close()
        if let onRegionConfirmed {
            onRegionConfirmed(global, annotations, action)
        } else {
            onCancelled?()
        }
    }

    // MARK: - Live recording

    /// Switch the overlay into its recording state: freeze the selection, make
    /// every panel click-through (the user keeps working inside the recorded
    /// area) and put the HUD exactly where the capture toolbar was.
    private func beginRecordingSession(on screen: NSScreen) {
        guard !recordingIsLive,
              let entry = entries.first(where: { $0.screen === screen }) ?? entries.first
        else { return }
        recordingIsLive = true
        recordingEntry = entry

        entry.view.beginRecordingUI()
        for panelEntry in entries {
            panelEntry.panel.ignoresMouseEvents = true
        }

        let hudOrigin = Self.recordingHUDOrigin(
            controlFrame: entry.view.recordingControlFrame,
            screenFrame: screen.frame
        )
        let indicator = RecordingIndicatorController()
        indicator.onPauseToggle = { [weak self] in self?.onRecordingPauseToggle?() }
        indicator.onStop = { [weak self] in self?.onRecordingStop?() }
        indicator.show(state: .recording, elapsedText: "00:00", origin: hudOrigin)
        recordingIndicator = indicator
        // The stream's own-window exclusion is a snapshot taken a moment from
        // now; make sure this panel has actually reached the window server by
        // then (a fresh borderless panel is otherwise only queued locally).
        indicator.panel?.displayIfNeeded()
        CATransaction.flush()

        DebugLog.log(
            "overlay: recording started region="
            + "\(NSStringFromRect(entry.view.committedRect ?? .zero)) "
            + "hud=\(NSStringFromPoint(hudOrigin))"
        )
    }

    /// Centre the HUD (208 × 40) on the toolbar frame it replaces, clamped to
    /// the display. Pure, so the self test can prove the placement.
    static func recordingHUDOrigin(
        controlFrame: CGRect,
        screenFrame: CGRect,
        panelSize: CGSize = RecordingIndicatorPlacement.panelSize,
        margin: CGFloat = 6
    ) -> CGPoint {
        let size = panelSize
        let x = controlFrame.midX - size.width / 2
        let y = controlFrame.midY - size.height / 2
        let maxX = max(screenFrame.minX + margin, screenFrame.maxX - size.width - margin)
        let maxY = max(screenFrame.minY + margin, screenFrame.maxY - size.height - margin)
        return CGPoint(
            x: min(max(x, screenFrame.minX + margin), maxX).rounded(),
            y: min(max(y, screenFrame.minY + margin), maxY).rounded()
        )
    }

    /// The coordinator's clock / pause state, mirrored into the HUD.
    func updateRecordingHUD(state: RecordingState, elapsedText: String) {
        recordingIndicator?.update(state: state, elapsedText: elapsedText)
    }

    /// Tear the recording UI down: hide the HUD, return the panels to their
    /// normal click-through/visible state and close the overlay. Idempotent —
    /// stop, failure and cancel all funnel here.
    func finishRecordingSession() {
        guard recordingIsLive || recordingIndicator != nil else {
            close()
            return
        }
        recordingIndicator?.hide()
        recordingIndicator = nil
        recordingEntry?.view.endRecordingUI()
        recordingEntry = nil
        recordingIsLive = false
        close()
    }

    var isRecordingSessionForTesting: Bool { recordingIsLive }
    var recordingIndicatorForTesting: RecordingIndicatorController? { recordingIndicator }
    /// Every live overlay panel's window number, for the own-window exclusion
    /// proof (the screen panels are the ones that draw the mask and border).
    var panelWindowNumbersForTesting: [Int] { entries.map(\.panel.windowNumber) }

    private func finishBeautifyRegion(_ localRect: CGRect, on screen: NSScreen) {
        guard !didFinish else { return }
        didFinish = true
        let global = Self.globalRect(localRect, on: screen)
        close()
        if let onBeautifyRegionConfirmed {
            onBeautifyRegionConfirmed(global)
        } else {
            onCancelled?()
        }
    }

    // MARK: - Multi-window

    private func trackWindow(
        _ windowID: CGWindowID,
        localRect: CGRect,
        selected: Bool,
        on screen: NSScreen
    ) {
        if selected {
            guard !selectedWindows.contains(where: { $0.id == windowID }) else { return }
            selectedWindows.append((windowID, Self.globalRect(localRect, on: screen)))
        } else {
            selectedWindows.removeAll { $0.id == windowID }
        }
    }

    private func clearWindowSelection() {
        selectedWindows.removeAll()
        for entry in entries {
            entry.view.clearWindowSelection()
        }
    }

    // MARK: - Window pick

    private func finishPickedWindow(
        _ windowID: CGWindowID,
        localRect: CGRect,
        on screen: NSScreen
    ) {
        guard !didFinish else { return }
        didFinish = true
        let global = Self.globalRect(localRect, on: screen)
        close()
        if let onWindowPicked {
            onWindowPicked(windowID, global)
        } else {
            onCancelled?()
        }
    }

    private func finishWindows() {
        guard !didFinish, !selectedWindows.isEmpty else {
            NSSound.beep()
            return
        }
        didFinish = true
        // Click order is the z-order: the last window the user added is drawn
        // last, so it wins where two windows overlap.
        let selection = selectedWindows
        close()
        if let onWindowsConfirmed {
            onWindowsConfirmed(selection)
        } else {
            onCancelled?()
        }
    }

    private func cancel() {
        guard !didFinish else { return }
        didFinish = true
        close()
        onCancelled?()
    }

    // MARK: - Coordinate conversion

    static func localRect(for globalRect: CGRect?, on screen: NSScreen) -> CGRect? {
        guard let globalRect else { return nil }
        let local = CGRect(
            x: globalRect.minX - screen.frame.minX,
            y: globalRect.minY - screen.frame.minY,
            width: globalRect.width,
            height: globalRect.height
        )
        let clipped = local.intersection(CGRect(origin: .zero, size: screen.frame.size))
        guard clipped.width >= SelectionBorderView.minimumSide,
              clipped.height >= SelectionBorderView.minimumSide else {
            return nil
        }
        return clipped
    }

    static func globalRect(_ localRect: CGRect, on screen: NSScreen) -> CGRect {
        CGRect(
            x: screen.frame.minX + localRect.minX,
            y: screen.frame.minY + localRect.minY,
            width: localRect.width,
            height: localRect.height
        )
    }
}

import AppKit
import CoreGraphics

/// Root of one screen's capture overlay.
///
/// Its only jobs are: own the four child views, route mouse/keyboard events to
/// them, and keep their frames in sync with the selection. It draws nothing
/// except the optional crosshair (a separate child view). Every piece of
/// chrome lives in its own view, matching the iShot decomposition in
/// `Docs/iShot-capability-map.md` §2.
final class CaptureOverlayView: NSView, NSTextFieldDelegate {
    enum Mode {
        case region
        /// Click windows to add/remove them from a set; Return captures the
        /// set as one composited image. No resize handles by design.
        case multiWindow
    }

    // Window picking is a sub-state of the region overlay, not a third `Mode`.
    //
    // It is deliberately **not** a third `Mode`: the panel lifecycle, the
    // dimming veil, the event router and the whole `SelectionBorderView` drag
    // machine stay exactly as they are. Only this view's event layer changes
    // meaning: the first click on a window **arms** it (outline + "再次单击
    // 确认" capsule) and a second click on that same window captures it.
    //
    // `⌃⌥⌘W` (instant window) and the `窗口截图` overlay
    // (`startsInWindowPick`, one click confirms) never come through this path:
    // the instant one does not use this view at all, and the confirmation
    // overlay's `windowConfirmationOnly` branch returns before arming.

    // MARK: - Callbacks

    /// Selection confirmed with a **terminal** toolbar action (or Return /
    /// double-click, which map to `.copyClosing`). The rectangle is in this
    /// view's coordinates and the annotations are normalised to it, ready to be
    /// flattened into the captured pixels.
    var onConfirm: ((CGRect, [Annotation], CaptureToolbarAction) -> Void)?
    /// "Copy and keep": flatten + pasteboard, but the overlay must stay open.
    /// The view only reports the intent; the controller supplies the pixels
    /// (from the startup snapshot, or a temporary live capture).
    var onCopyKeeping: ((CGRect, [Annotation]) -> Void)?
    /// Multi-window mode: one click toggled a window in/out of the set.
    /// `position` is the view-local frame; the controller converts it.
    var onWindowToggled: ((CGWindowID, CGRect, Bool) -> Void)?
    /// Multi-window mode: a click on empty desktop cleared the selection.
    var onWindowSelectionCleared: (() -> Void)?
    /// Multi-window mode: Return pressed. The view reports the local frames it
    /// currently has selected; the controller owns the cross-screen set.
    var onWindowsConfirmed: (([(CGWindowID, CGRect)]) -> Void)?
    /// Window picking: the user clicked the highlighted window. The rectangle
    /// is that window's local frame (the controller converts it for delivery).
    var onWindowPicked: ((CGWindowID, CGRect) -> Void)?
    /// Scroll entry: a finished new selection is reported here instead of
    /// `.ocr` auto-confirm.
    var onSelectionDrawn: ((CGRect, [Annotation]) -> Void)?
    /// Scrolling capture: the footer's Auto Scroll control was pressed.
    var onScrollToggleAuto: (() -> Void)?
    /// Scrolling capture: 停止, Return, or the second press of the shortcut.
    var onScrollStop: (() -> Void)?
    /// Scrolling capture: 完成 (or Return) after the result is final. This is the
    /// confirmation that actually delivers the long image; until it arrives
    /// nothing has been copied or written.
    var onScrollConfirm: (() -> Void)?
    /// Scrolling capture: the finished result was thrown away (Esc, or the
    /// shortcut). Nothing is delivered and the overlay goes.
    var onScrollClose: (() -> Void)?
    /// Scrolling capture: the finished card's 继续 (or a wheel over the finished
    /// overlay). The session restarts on the same stitch.
    var onScrollResume: (() -> Void)?
    /// Scrolling capture: a capture-toolbar action was pressed. The coordinator
    /// finishes the session and delivers the long image with that action.
    var onScrollAction: ((CaptureToolbarAction) -> Void)?
    /// Scrolling capture: 拷贝 with the session still running.
    var onScrollCopyCurrent: (([Annotation]) -> Void)?
    /// Scrolling capture: the user moved or resized the box. The session must
    /// sample the new rectangle (and restart its stitch).
    var onScrollRegionCommitted: ((CGRect) -> Void)?
    /// The viewfinder's well + spill, in points, so the session can compose its
    /// preview band at the exact size the pod draws.
    var onScrollPreviewSizeChanged: ((CGSize) -> Void)?
    /// Scrolling capture: forward the wheel to the page under the overlay.
    var onScrollWheel: ((NSEvent) -> Void)?
    var onCancel: (() -> Void)?

    // MARK: - Configuration

    let mode: Mode

    /// Global AppKit (bottom-left) frame of the screen this overlay covers.
    /// The controller sets it before presenting; window hit testing needs it
    /// to translate Quartz window bounds into local coordinates.
    var screenFrame: CGRect = .zero

    /// Live crosshair state. Seeded from `AppSettings.showCrosshair` and owned
    /// by the toolbar's small switch from there on, so the switch changes what
    /// this capture shows *and* the stored preference.
    private var showCrosshair: Bool
    private let rendersOffscreen: Bool
    /// The app's settings, when present. The overlay needs them for the two
    /// real controls in the toolbar's left auxiliary group (export shadow +
    /// crosshair).
    /// Optional so the offscreen harness can build an overlay without touching
    /// the user's defaults.
    private let settings: AppSettings?
    /// OCR entry point: finishing the *drawing* of a new box confirms
    /// immediately with `.ocr`, without requiring a toolbar click. Resizing or
    /// moving an existing selection still goes through the toolbar.
    private let autoConfirmOnSelectionEnd: Bool
    /// `.window` confirmation mode: the overlay is window-only. No rectangle
    /// drag, no F / ratio / Shift-multi; a single click confirms the highlighted
    /// window. `⌃⌥⌘W` does not use this view at all.
    private let windowConfirmationOnly: Bool
    /// Whether a plain single click may resolve to a window. Off for OCR /
    /// scroll / recording / beautify / preset, where a stray click must stay a
    /// no-op instead of silently switching to window capture.
    private let windowPickEnabled: Bool
    /// 设置 → 截图 → 显示放大镜. The loupe shows the pixels under the pointer at
    /// a fixed zoom while the crosshair is still following the mouse.
    private let showLoupe: Bool
    /// Last pointer position in view coordinates. The loupe follows it, and
    /// the freeze/unfreeze paths reuse it so the loupe cannot be left behind.
    private var lastPointerPoint: CGPoint?
    /// Scrolling entry: the region overlay stays open for the whole session and
    /// grows the fixed viewfinder, instead of closing on selection and showing
    /// a separate preview panel.
    private let scrollMode: Bool
    /// 设置 → 滚图 → 显示进度卡片. When off the session still runs; only the
    /// viewfinder is hidden.
    private let scrollPreviewEnabled: Bool
    /// The live viewfinder is hosted by its own window (`ScrollPreviewPanel`)
    /// so it stays clickable while the overlay is mouse-transparent for the
    /// page's wheel events. Offscreen renders keep it as a subview.
    private let scrollPreviewExternal: Bool
    /// Region recording: the overlay behaves exactly like a region capture
    /// (drag, arrow nudge, window pick, size chip) but its delivery action is
    /// 开始录制 instead of 拷贝, and nothing starts until the user presses
    /// Return or the toolbar's record button. Closing without confirming never
    /// starts a stream.
    private let recordingMode: Bool

    // MARK: - Children (one responsibility each)

    private let dimming = DimmingView()
    /// Annotations sit above the veil and below the border, so the eight
    /// handles stay grabbable even where a stroke crosses them.
    private let annotationCanvas = AnnotationCanvasView()
    private let selectionBorder = SelectionBorderView()
    /// Multi-window mode only. Sits above the veil and replaces the selection
    /// border; hit testing stays on the root view.
    private let windowHighlight = WindowHighlightView()

    private let toolbar: CaptureToolbarView
    private let indicator = SizeIndicatorView()
    private let crosshair = CrosshairView()
    /// The loupe beside the pointer. Hidden unless there is a snapshot to
    /// magnify and the cross is still following the pointer.
    private let loupe = LoupeView()
    /// The crosshair's frozen corner, expressed as *which* corner of the
    /// selection it is pinned to (AppKit: x = left/right, y = bottom/top).
    /// Stored as a role rather than a point on purpose: the box can be nudged,
    /// resized, rebuilt by F or by the size chip while the cross is frozen, and
    /// the cross must keep lying exactly on the selection's edges. Nil while
    /// the crosshair follows the pointer.
    private struct FrozenCorner {
        var onMaxX: Bool
        var onMinY: Bool
    }
    private var frozenCorner: FrozenCorner?
    /// Where the frozen cross currently sits, in view coordinates.
    private(set) var frozenCrosshairPoint: CGPoint?
    /// Captured length of the live session, in units of the selection's height.
    ///
    /// Deliberately data only. A live long-capture must not paint anything
    /// extra on the selection: the user asked for no boundary line, no end
    /// ticks, no progress pill and no "captured" tint. The fixed preview card
    /// is the whole progress affordance; the selection stays exactly the box
    /// the user drew.
    private(set) var scrollProgressRatio: CGFloat = 0
    /// The fixed viewfinder pod. Its frame is a pure function of the selection;
    /// the picture inside is what moves.
    private let scrollPod = ScrollPreviewPod()
    private(set) var isScrollActive = false
    private(set) var scrollPhase: ScrollPreviewPod.Phase = .empty
    private var lastNotifiedScrollRect: CGRect?
    private var scrollRegionCommitTask: Task<Void, Never>?
    private var lastScrollBandSize: CGSize = .zero

    // MARK: - Live recording state

    /// Set while a recording session owns this overlay.
    ///
    /// The overlay **is** the recording UI: the user confirms 开始录制 and the
    /// mask, the border, its eight handles, the size chip and (when enabled)
    /// the crosshair stay exactly as they were, so the screen still reads as
    /// the region selector. Only the capture toolbar changes: it is replaced by
    /// the recording HUD (dot / timer / pause / stop), which the controller
    /// centres on `recordingControlFrame`.
    ///
    /// The panels are made click-through for the session — the app being
    /// recorded has to stay usable — so the rectangle cannot be dragged: it is
    /// the stream's source rect. Everything that could still mutate it is
    /// guarded below.
    private(set) var isRecordingLive = false
    /// Where the capture toolbar sat when the session began, in this view's
    /// coordinates. The HUD is centred on it, so the toolbar is visually
    /// replaced in place.
    private(set) var recordingControlFrame: CGRect = .zero

    // MARK: - Annotation state

    private let annotationStore = AnnotationStore()
    private var currentTool: AnnotationTool = .move
    /// The stroke being dragged. Committed to the store on mouse-up.
    private var activeStroke: Annotation?
    /// True while the mouse-down that started inside the selection is painting
    /// rather than moving/resizing.
    private var isPainting = false

    // MARK: - Window hit testing

    private struct CandidateWindow {
        let id: CGWindowID
        let frame: CGRect
        let owner: String
        let title: String
    }

    private var candidateWindows: [CandidateWindow] = []
    private var hoveredWindowID: CGWindowID?
    /// Window-pick candidates in this view's coordinates, front-most first.
    private var windowPickCandidates: [WindowCandidate] = []
    /// Menu bar heights and pointer-screen height captured with the stack.
    /// `WindowPicker` needs both for iShot's full-screen-helper rules.
    private var windowPickMenubarHeights: Set<Int> = []
    private var windowPickScreenHeight: CGFloat = 0
    /// The self test injects a deterministic stack; production must refresh it
    /// from the window server at click time instead.
    private var usesInjectedWindowCandidates = false
    /// Region overlay only: the window the first click selected. A second
    /// click on the *same* window captures it; a click anywhere else (or a
    /// drag, or Esc) drops back to normal region drawing.
    private var armedWindowPick: WindowPick?
    /// The armed pick that was on screen when the mouse went down. Mouse-up
    /// needs it to tell "second click on the same window" from "clicked
    /// somewhere else", because mouse-down already clears the visual state.
    private var armedPickAtPress: WindowPick?
    /// Window hovered by the pointer while no selection exists (iShot's
    /// pre-click highlight). Clicks arm the window; this is the preview.
    /// It carries the picker's rectangle, not the raw frame: a layered window is
    /// trimmed to its opaque content, and the highlight must match what will be
    /// captured.
    private var hoveredPick: WindowPick?
    private var hoverPoint: CGPoint?
    /// Edges the moving corner can magnet to: windows plus the screen.
    private var snapTargets: [CGRect] = []
    /// iShot's "tap Control to hide the toolbar" state.
    private var toolbarSuppressed = false
    private var controlWasDown = false
    /// Whether the cursor rects currently describe the armed (arrow) state.
    /// Only the transition invalidates them; moving the pointer does not.
    private var cursorShowsArrow = false
    /// How far outside a committed window the pointer may roam before the arm
    /// is dropped. It has to clear the 12 pt gap to the toolbar, otherwise the
    /// toolbar could never be reached without cancelling the selection.
    static let armedLeaveSlop: CGFloat = 24
    /// Click → armed-highlight timing, off unless `UNSEEN_CLICK_TIMING`
    /// is set. The numbers land in the same trace file as the rest of `DebugLog`.
    private static let clickTimingEnabled =
        ProcessInfo.processInfo.environment["UNSEEN_CLICK_TIMING"] != nil
    /// `mouseDown` of the click currently being resolved.
    private var pressStartedAt: CFAbsoluteTime?
    /// iShot's 0.5 s toolbar popup delay. Offscreen renders and the self test
    /// bypass it so screenshots stay deterministic; production waits.
    static let toolbarRevealDelay: TimeInterval = 0.5
    private var toolbarRevealTask: Task<Void, Never>?
    private var toolbarIsRevealed = false
    /// iShot's number-key ratio lock (nil = free).
    private var lockedAspect: CGFloat?
    /// Per-tool style overrides from the annotation style panel. Missing tools
    /// fall back to `AnnotationStyle.defaultStyle(for:)`.
    private var toolStyles: [AnnotationTool: AnnotationStyle] = [:]
    private var stylePopover: NSPopover?
    /// A Shift-click on a window consumed the mouse cycle (multi-select).
    private var suppressMouseUp = false
    /// Mouse-down origin for the click-vs-drag decision.
    private var pressOrigin: CGPoint?
    /// The selection as it was at mouse-down, so mouse-up can tell a real
    /// gesture (which may freeze the crosshair) from a bare click.
    private var pressSelectionRect: CGRect = .zero
    /// Whether a selection already existed when the mouse went down. A click
    /// outside an existing box starts a new box, but it must not also be read
    /// as "capture the window under the pointer".
    private var pressHadSelection = false
    /// Multi-window selection set, by window id.
    private var selectedWindowIDs: Set<CGWindowID> = []
    private var lastWindowRefresh: TimeInterval = 0
    private var trackingArea: NSTrackingArea?

    // MARK: - Inline text input

    /// The field editor for `.text` / `.note`, created on click and removed on
    /// Enter (commit) or Escape (discard).
    private var textInputField: NSTextField?
    /// Click point in view coordinates: the annotation anchor.
    private var textInputAnchor: CGPoint?
    /// Local key monitor active while the field exists. The field editor's
    /// delegate forwarding for Return/Escape is unreliable in a non-activating
    /// panel, so the monitor is the authoritative commit/cancel path.
    private var textKeyMonitor: Any?

    // MARK: - Editable size chip

    /// True while the size chip is a two-field editor. The chip's click grammar
    /// lives at this event router (like window picking and the inline text
    /// field) so it can pre-empt the region drag machine entirely.
    private var sizeEditActive = false
    /// The mouse cycle that opened the editor must not also start a box or
    /// resolve a window tap.
    private var sizeEditConsumedClick = false
    /// Local key monitor active while editing: Return commits, Escape cancels,
    /// Tab moves between width and height. The field editor of a
    /// non-activating panel is not authoritative for these keys, exactly like
    /// the inline text field above.
    private var sizeEditKeyMonitor: Any?

    // MARK: - Click placement (counter / sticker)

    /// The live emoji popover. Only one exists at a time; a second click on the
    /// sticker tool moves it rather than stacking popovers.
    private var stickerPicker: StickerPickerController?
    /// View-space point the picker was opened at. The chosen emoji lands here.
    private var pendingStickerAnchor: CGPoint?

    /// Anything shorter than this between mouse-down and mouse-up is a click,
    /// not a drag. 4 pt sits below AppKit's own drag slop (3–5 pt depending on
    /// the pointing device) and far below `SelectionBorderView.minimumSide`
    /// (40 pt), so a click never leaves a stray box and a deliberate 50 pt drag
    /// is unambiguously a region drag.
    static let singleTapSlop: CGFloat = 4

    // MARK: - Init

    init(
        frame: NSRect,
        mode: Mode,
        prefilledSelection: CGRect? = nil,
        showCrosshair: Bool,
        rendersOffscreen: Bool,
        baseImage: CGImage? = nil,
        baseImageScale: CGSize = .zero,
        autoConfirmOnSelectionEnd: Bool = false,
        startsInWindowPick: Bool = false,
        windowPickEnabled: Bool = true,
        showLoupe: Bool = true,
        scrollMode: Bool = false,
        scrollPreviewEnabled: Bool = true,
        scrollPreviewExternal: Bool = false,
        recordingMode: Bool = false,
        settings: AppSettings? = nil
    ) {
        self.mode = mode
        self.showCrosshair = showCrosshair
        self.settings = settings
        self.rendersOffscreen = rendersOffscreen
        self.autoConfirmOnSelectionEnd = autoConfirmOnSelectionEnd
        self.windowConfirmationOnly = startsInWindowPick
        self.windowPickEnabled = windowPickEnabled
        self.showLoupe = showLoupe
        self.scrollMode = scrollMode
        self.scrollPreviewEnabled = scrollPreviewEnabled
        self.scrollPreviewExternal = scrollPreviewExternal
        self.recordingMode = recordingMode
        self.toolbar = CaptureToolbarView(offscreen: rendersOffscreen)
        super.init(frame: frame)

        // Recording is its own toolbar: 开始录制 / 取消 / handle, no annotation
        // tools and no copy-save-OCR-pin. Set before the first layout so the
        // plate is never measured at the screenshot width.
        toolbar.isRecordingMode = recordingMode

        wantsLayer = true

        dimming.frame = bounds
        dimming.autoresizingMask = [.width, .height]
        addSubview(dimming)

        annotationCanvas.frame = bounds
        annotationCanvas.autoresizingMask = [.width, .height]
        annotationCanvas.mosaicBaseImage = baseImage
        annotationCanvas.mosaicImageScale = baseImageScale
        addSubview(annotationCanvas)

        // The crosshair is a coordinate readout: it belongs above the veil, the
        // captured pixels and the annotations, but **under** every piece of
        // chrome the user has to see and grab. In particular it is under the
        // selection border, so the eight blue handles are never sliced by a
        // line that happens to run through a corner. Drawing order *is* the
        // z-order here; there is no separate layer for the handles.
        crosshair.frame = bounds
        crosshair.autoresizingMask = [.width, .height]
        crosshair.isHidden = !showCrosshair
        addSubview(crosshair)

        selectionBorder.frame = bounds
        selectionBorder.autoresizingMask = [.width, .height]
        addSubview(selectionBorder)

        windowHighlight.frame = bounds
        windowHighlight.autoresizingMask = [.width, .height]
        windowHighlight.isHidden = true
        addSubview(windowHighlight)

        // The pod sits above the veil and the selection border but below the
        // toolbar. Its frame includes the strip above the card, so clicks in
        // either area are swallowed instead of starting a new box.
        scrollPod.isHidden = true
        addSubview(scrollPod)
        scrollPod.onToggleAutoScroll = { [weak self] in self?.onScrollToggleAuto?() }
        scrollPod.onStop = { [weak self] in self?.onScrollStop?() }
        scrollPod.onConfirm = { [weak self] in self?.onScrollConfirm?() }
        scrollPod.onResume = { [weak self] in self?.onScrollResume?() }
        // The card can shrink once the page is longer than the selection, and
        // the session composes its band at exactly the size the card draws.
        scrollPod.onDrawnSizeChange = { [weak self] size in
            self?.adoptScrollBandSize(
                ScrollPreviewPod.bandSize(forCardSize: size)
            )
        }

        loupe.frame = bounds
        loupe.autoresizingMask = [.width, .height]
        loupe.isHidden = true
        loupe.magnifiedImage = baseImage
        loupe.imageScale = baseImageScale
        // Above the crosshair: the magnified pixels are the point of the card,
        // and the tracking cross has a 5 pt gap plus an 18 pt offset, so it
        // never reaches under it in practice.
        addSubview(loupe)

        toolbar.isHidden = true
        addSubview(toolbar)

        indicator.isHidden = true
        addSubview(indicator)
        indicator.onFieldAction = { [weak self] in
            self?.commitSizeEdit()
        }
        indicator.onPreferredSizeChange = { [weak self] in
            // The chip changed width (read-only ↔ editor); re-run placement so
            // it still dodges the toolbar and the screen edge.
            self?.layoutSelection()
        }

        toolbar.onAction = { [weak self] action in
            self?.toolbarAction(action)
        }
        toolbar.onToolSelected = { [weak self] tool in
            self?.selectTool(tool)
        }
        toolbar.onUndo = { [weak self] in
            self?.undoAnnotation()
        }
        toolbar.onRedo = { [weak self] in
            self?.redoAnnotation()
        }
        toolbar.onStyle = { [weak self] in
            self?.presentStylePanel()
        }
        // Left auxiliary group: the chip is the same `SizeIndicatorView` the
        // overlay has always owned, placed in the plate's reserved slot. The
        // steppers, the shadow menu and the crosshair switch all report through
        // callbacks so the toolbar keeps knowing nothing about selections or
        // preferences.
        toolbar.onSizeChipTap = { [weak self] in
            self?.handleSizeChipTap()
        }
        toolbar.onStepSize = { [weak self] delta in
            self?.stepSelectionSize(by: delta)
        }
        toolbar.onShadowLevelChanged = { [weak self] level in
            self?.applyShadowLevel(level)
        }
        toolbar.onCrosshairToggled = { [weak self] on in
            self?.applyCrosshairVisibility(on)
        }
        toolbar.onUserMoved = { [weak self] in
            self?.layoutSelection()
        }
        toolbar.onAuxRowVisibilityChanged = { [weak self] in
            self?.layoutSelection()
        }
        toolbar.setCrosshairOn(showCrosshair)
        toolbar.setShadowLevel(Self.shadowLevel(for: settings))

        annotationStore.onChange = { [weak self] in
            self?.annotationsChanged()
        }

        if let prefilledSelection, prefilledSelection.width >= 1, prefilledSelection.height >= 1 {
            selectionBorder.setSelection(prefilledSelection)
        }

        if mode == .multiWindow {
            dimming.dimAlpha = 0.30
            selectionBorder.isHidden = true
            annotationCanvas.isHidden = true
            windowHighlight.isHidden = false
            windowHighlight.hint = "点击窗口加入选择 · 回车合成 · Esc 取消"
        }

        // `.window` mode never presents this view: it captures immediately with
        // `InstantCaptureKind.window`. A single click inside ordinary region
        // capture is resolved by `mouseUp` below.

        layoutSelection()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Layout

    override func layout() {
        super.layout()
        dimming.frame = bounds
        selectionBorder.frame = bounds
        windowHighlight.frame = bounds
        loupe.frame = bounds
        crosshair.frame = bounds
        layoutSelection()
    }

    /// Keep dimming, border, toolbar and indicator in agreement. Called after
    /// every drag tick so the toolbar visibly follows the selection; nothing
    /// is frozen at mouse-up.
    private func layoutSelection() {
        let rect = selectionBorder.selectionRect
        // No box, no freeze: a crosshair pinned to a selection that no longer
        // exists would be a stray line across the screen.
        if !selectionBorder.hasSelection {
            unfreezeCrosshair()
        } else if frozenCorner != nil {
            // The box moved without a drag (arrow-key nudge, F, the size chip,
            // the ratio lock). A frozen cross is a *coordinate readout*, so it
            // has to travel with the corners it names instead of being left
            // behind on the old ones.
            applyFrozenCrosshair(for: rect)
        }

        // An armed window and a live rectangle cannot coexist: any path that
        // produced a selection (drag, F, prefilled, test seam) means the user
        // went back to ordinary region drawing.
        if selectionBorder.hasSelection, armedWindowPick != nil {
            armedWindowPick = nil
        }
        updateCursorForArmedState()

        if !isScrollActive {
            scrollPod.isHidden = true
        }

        // A live recording keeps the selector's chrome and drops only the
        // capture toolbar, which the recording HUD replaces in place.
        if isRecordingLive {
            layoutRecordingChrome(for: rect)
            return
        }

        // Multi-window mode has no rectangle selection at all; the highlight
        // view owns the whole screen and the toolbar/indicator stay hidden.
        if mode == .multiWindow {
            dimming.selectionRect = .zero
            annotationCanvas.isHidden = true
            toolbar.isHidden = true
            indicator.isHidden = true
            crosshair.isHidden = true
            updateWindowHighlights()
            return
        }

        // Shift-selected windows: the set owns the highlight and no rectangle
        // exists yet. Enter composites, Esc clears the set first.
        if !selectedWindowIDs.isEmpty {
            dimming.selectionRect = .zero
            annotationCanvas.selectionRect = .zero
            toolbar.isHidden = true
            indicator.isHidden = true
            crosshair.isHidden = true
            windowHighlight.isHidden = false
            updateWindowHighlights()
            return
        }

        // Armed: the first click picked this window. From here on it *is* the
        // selection: the same toolbar, indicator, Return key and annotation
        // surface as a dragged box, computed from `committedRect`. The capsule
        // still asks for the second click, and the crosshair is gone.
        if let armedWindowPick, !selectionBorder.hasSelection {
            let rect = armedWindowPick.rect
            dimming.selectionRect = rect
            annotationCanvas.selectionRect = rect
            crosshair.isHidden = true
            windowHighlight.isHidden = false
            windowHighlight.entries = [
                WindowHighlightView.Entry(
                    frame: rect,
                    selected: true,
                    hovered: true
                )
            ]
            // No window title / app name here: the highlight already says
            // *which* window is armed, and the owner's titles are their own
            // content (a terminal title is the command that is running, not
            // something this overlay should echo back).
            windowHighlight.hint = recordingMode
                ? "回车开始录制 · Esc 取消"
                : "再次单击确认截取 · Esc 取消"
            windowHighlight.hintAnchor = hoverPoint
            layoutCommittedChrome(for: rect, revealImmediately: true)
            return
        }

        // iShot's pre-click state: with no selection, the window under the
        // pointer is punched out of the veil and outlined, with a hint capsule.
        // It does not change the click semantics: mouse-up arms the window.
        if let hoveredPick, !selectionBorder.hasSelection {
            dimming.selectionRect = hoveredPick.rect
            annotationCanvas.selectionRect = .zero
            toolbar.isHidden = true
            indicator.isHidden = true
            crosshair.isHidden = !showCrosshair
            windowHighlight.isHidden = false
            windowHighlight.entries = [
                WindowHighlightView.Entry(
                    frame: hoveredPick.rect,
                    selected: false,
                    hovered: true
                )
            ]
            // Size only, never the window's title or owner name. The title is
            // the *other* app's content (a terminal shows the running command,
            // an editor the file); echoing it back looked like the overlay was
            // advertising an unrelated name. The punched-out highlight plus the
            // outline is what identifies the target.
            let size = hoveredPick.rect.size
            if windowConfirmationOnly {
                windowHighlight.hint =
                    "单击确认 \(Int(size.width))×\(Int(size.height)) · Esc 退出"
            } else if recordingMode {
                windowHighlight.hint =
                    "单击选中 \(Int(size.width))×\(Int(size.height)) · 回车录制"
            } else {
                windowHighlight.hint =
                    "单击选中 \(Int(size.width))×\(Int(size.height)) · 再单击截取"
            }
            windowHighlight.hintAnchor = hoverPoint
            return
        }

        windowHighlight.entries = []
        windowHighlight.hint = ""
        windowHighlight.hintAnchor = nil
        windowHighlight.isHidden = true

        dimming.selectionRect = rect
        // The canvas scales stored normalised points to the new rect, so a
        // handle drag moves the annotations with the selection.
        annotationCanvas.selectionRect = rect

        let hasChrome = rect.width >= 2 && rect.height >= 2
        indicator.isHidden = !hasChrome
        crosshair.isHidden = !showCrosshair

        guard hasChrome else {
            cancelToolbarReveal()
            toolbar.isHidden = true
            toolbarIsRevealed = false
            toolbar.resetUserOffset()
            indicator.isHidden = true
            refreshCrosshairExclusions()
            return
        }

        layoutCommittedChrome(for: rect, revealImmediately: false)
        layoutScrollPod(for: rect)
        refreshCrosshairExclusions()
        if isScrollActive, rect != lastNotifiedScrollRect {
            scheduleScrollRegionCommit(rect)
        }
    }

    private func scheduleToolbarReveal() {
        guard toolbarRevealTask == nil else { return }
        toolbarRevealTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(
                nanoseconds: UInt64(Self.toolbarRevealDelay * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            self.toolbarRevealTask = nil
            self.toolbarIsRevealed = true
            self.toolbar.alphaValue = 0
            self.toolbar.isHidden = false
            // The chip travels with the toolbar: it was hidden while the plate
            // waited out iShot's 0.5 s, so it becomes visible with it.
            let chipRidesWithToolbar = self.toolbar.isAuxRowVisible
            if chipRidesWithToolbar {
                self.indicator.isHidden = false
                self.indicator.alphaValue = 0
                let chip = self.toolbar.sizeChipFrame
                self.indicator.frame = chip.offsetBy(
                    dx: self.toolbar.frame.minX,
                    dy: self.toolbar.frame.minY
                )
            }
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0.15
            self.toolbar.animator().alphaValue = 1
            if chipRidesWithToolbar {
                // The plate is one surface: the chip fades in with it instead
                // of popping in fully opaque over a half-transparent toolbar.
                self.indicator.animator().alphaValue = 1
            }
            NSAnimationContext.endGrouping()
        }
    }

    private func cancelToolbarReveal() {
        toolbarRevealTask?.cancel()
        toolbarRevealTask = nil
    }

    // MARK: - The committed rectangle

    /// The one rectangle every commit path acts on.
    ///
    /// A drawn selection wins; otherwise an armed window stands in for one.
    /// This is the deliberate product deviation from iShot documented in
    /// `Docs/iShot-capability-map.md` §15: iShot turns a picked window into a
    /// crop rectangle before any toolbar exists, while this overlay keeps the
    /// window pick as a sub-state but gives it the same committed-rect angle.
    var committedRect: CGRect? {
        let selection = selectionBorder.selectionRect
        if selectionBorder.hasSelection, selection.width >= 1, selection.height >= 1 {
            return selection
        }
        if let armedWindowPick, !selectionBorder.hasSelection {
            return armedWindowPick.rect
        }
        return nil
    }

    /// Lay out the floating chrome for one committed rectangle.
    ///
    /// `revealImmediately` is the armed-window rule: the click that commits the
    /// window is itself the "selection settled" event, so waiting another 0.5 s
    /// would hide the toolbar behind the user's next move. A dragged box keeps
    /// iShot's delayed reveal.
    private func layoutCommittedChrome(for rect: CGRect, revealImmediately: Bool) {
        if toolbarSuppressed {
            cancelToolbarReveal()
            toolbar.isHidden = true
        } else if revealImmediately || rendersOffscreen || toolbarIsRevealed {
            cancelToolbarReveal()
            toolbar.isHidden = false
            toolbar.alphaValue = 1
        } else {
            toolbar.isHidden = true
            scheduleToolbarReveal()
        }

        // The size chip has exactly one home at a time:
        //
        // * auxiliary group visible — it is the plate's chip. The toolbar
        //   reserves the slot from the chip's own `preferredSize` (so the
        //   two-field editor still grows), and the chip rides with the
        //   toolbar. Hiding the toolbar (Ctrl or the 0.5 s delay) hides the
        //   chip with it, because they are one surface.
        // * auxiliary group hidden — the historical floating chip returns
        //   unchanged, dodging the toolbar exactly as before.
        indicator.chipStyle = toolbar.isAuxRowVisible ? .toolbar : .floating
        // The text must land before the slot is measured: the toolbar reserves
        // exactly the chip's `preferredSize`, which is derived from the text
        // (and from the two-field editor while editing).
        indicator.text = SizeIndicatorView.text(for: rect.size)
        if toolbar.isAuxRowVisible {
            toolbar.auxSizeChipSize = indicator.preferredSize
        }

        toolbar.frame = toolbar.placement(for: rect, screenBounds: bounds)
        toolbar.layoutSubtreeIfNeeded()

        if toolbar.isAuxRowVisible {
            indicator.isHidden = toolbar.isHidden
            let chip = toolbar.sizeChipFrame
            indicator.frame = chip.offsetBy(
                dx: toolbar.frame.minX,
                dy: toolbar.frame.minY
            )
        } else {
            indicator.isHidden = false
            indicator.frame = indicator.placement(
                for: rect,
                screenBounds: bounds,
                avoiding: toolbar.frame
            )
        }
        // The plate may just have appeared (the 0.5 s reveal) or moved under a
        // stationary pointer; the loupe has to step aside either way.
        updateLoupe(at: lastPointerPoint)
    }

    // MARK: - Live recording UI

    /// Turn this overlay into the recording control surface.
    ///
    /// Nothing about the selector's *look* changes: the veil keeps its hole,
    /// the border keeps its eight handles, the size chip stays where it was and
    /// the crosshair stays exactly where the drag released it. Only the capture
    /// toolbar is swapped out — the coordinator's recording HUD takes its exact
    /// place through `recordingControlFrame`.
    ///
    /// 十字线在录制期间是**冻结**的，和区域截图完全一致: the panels are
    /// click-through for the session, so no `mouseMoved` arrives, and nothing
    /// polls the pointer to fake one. Freezing is a coordinate readout — "this
    /// box starts here" — and it names the same corner for as long as the box
    /// exists.
    ///
    /// A window that was armed becomes the same plain rectangle a drag would
    /// have produced, because a recording is a rectangle no matter how it was
    /// chosen.
    func beginRecordingUI() {
        guard recordingMode, !isRecordingLive else { return }
        isRecordingLive = true

        commitTextInput()
        cancelSizeEdit()
        dismissStickerPicker()
        cancelToolbarReveal()
        toolbarIsRevealed = false
        toolbarSuppressed = false

        if !selectionBorder.hasSelection, let armedWindowPick {
            selectionBorder.setSelection(armedWindowPick.rect)
        }
        armedWindowPick = nil
        hoveredPick = nil
        hoverPoint = nil
        selectedWindowIDs.removeAll()
        lockedAspect = nil

        annotationCanvas.isHidden = true
        loupe.isHidden = true
        // Pin the cross *before* `layoutSelection` so every later layout pass
        // re-derives it from `frozenCorner` instead of leaving it tracking.
        pinCrosshairForRecording()
        layoutSelection()
        DebugLog.log(
            "overlay: recording UI selection="
            + "\(NSStringFromRect(selectionBorder.selectionRect)) "
            + "crosshair=\(frozenCrosshairPoint.map(NSStringFromPoint) ?? "nil") "
            + "hud=\(NSStringFromRect(recordingControlFrame))"
        )
    }

    /// Leave the recording state. The controller closes the panels right after,
    /// so this only drops the flag and the HUD anchor.
    func endRecordingUI() {
        guard isRecordingLive else { return }
        isRecordingLive = false
        recordingControlFrame = .zero
    }

    /// 录制开始后把十字线钉在松手时的位置 — exactly what a screenshot's
    /// committed box does (`mouseUp` → `freezeCrosshair`).
    ///
    /// A box the user dragged already froze its cross on release; keeping that
    /// state is the whole fix, because reaching for 开始录制 must not move it
    /// to the toolbar. A box that never went through `mouseUp` (prefilled from
    /// the last capture, or a picked window) has no release point, so it gets
    /// the same rule applied to the last known pointer: pin to the corner of
    /// the committed rectangle nearest that point.
    private func pinCrosshairForRecording() {
        let rect = selectionBorder.selectionRect
        guard showCrosshair,
              !windowConfirmationOnly,
              rect.width >= 2,
              rect.height >= 2
        else {
            unfreezeCrosshair()
            return
        }
        if crosshair.isFrozen, frozenCorner != nil {
            // Re-derive from the stored corner so the arms sit on *this* rect.
            applyFrozenCrosshair(for: rect)
        } else {
            freezeCrosshair(
                for: rect,
                releasedAt: lastPointerPoint
                    ?? CGPoint(x: rect.maxX, y: rect.maxY)
            )
        }
    }

    /// Keep the selector's chrome — veil, border, handles, size chip — and drop
    /// only the capture toolbar (the HUD is a separate panel over its frame).
    private func layoutRecordingChrome(for rect: CGRect) {
        windowHighlight.entries = []
        windowHighlight.hint = ""
        windowHighlight.hintAnchor = nil
        windowHighlight.isHidden = true
        scrollPod.isHidden = true
        annotationCanvas.isHidden = true
        annotationCanvas.selectionRect = rect
        crosshair.isHidden = !showCrosshair

        // Exactly what `layoutCommittedChrome` draws for a screenshot box.
        dimming.selectionRect = rect
        indicator.isHidden = false
        indicator.chipStyle = .floating
        indicator.text = SizeIndicatorView.text(for: rect.size)
        toolbar.frame = toolbar.placement(for: rect, screenBounds: bounds)
        recordingControlFrame = toolbar.frame
        indicator.frame = indicator.placement(
            for: rect,
            screenBounds: bounds,
            avoiding: toolbar.frame
        )

        // The toolbar's contents are the screenshot actions; they make no sense
        // for a video and the panel is click-through anyway. The HUD replaces
        // it at this exact frame.
        toolbar.isHidden = true
        refreshCrosshairExclusions()
        updateLoupe(at: lastPointerPoint)
    }

    // MARK: - Scrolling capture

    /// Enter the scrolling state for the current committed selection. Called by
    /// the view itself when a fresh box finishes, and by the coordinator when
    /// the prefilled selection is scrolled without a redraw (probe).
    ///
    /// Idempotent: drawing a second box while a session is running keeps the
    /// pod up and lets the coordinator restart the stitch for the new region.
    func beginScrollSession() {
        guard scrollMode, committedRect != nil else { return }
        if !isScrollActive {
            isScrollActive = true
            scrollPhase = .empty
            scrollPod.reset()
            scrollPod.isHidden = !scrollPreviewEnabled
            scrollProgressRatio = 0
        }
        // The user just chose the region and needs the full capture toolbar
        // immediately — iShot's 0.5 s wait is for a box that is still settling.
        cancelToolbarReveal()
        toolbarIsRevealed = true
        toolbarSuppressed = false
        lastNotifiedScrollRect = selectionBorder.selectionRect
        layoutSelection()
    }

    // MARK: - Scroll keyboard grammar

    /// Return / Escape for a live scrolling session.
    ///
    /// Shared by `keyDown` (the overlay is key: before the session starts, and
    /// again once the result is finished) and by the controller's temporary
    /// global Escape hotkey (the session is click-through: the page owns the
    /// keyboard). One implementation means both transports end in exactly the
    /// same coordinator cleanup as region / window / full-screen captures.
    ///
    /// * Return stops a running session; on a finished result it confirms.
    /// * Esc cancels while running; on a finished result it discards — nothing
    ///   has been copied or written yet at that point.
    @discardableResult
    func handleScrollKey(_ keyCode: UInt16) -> Bool {
        guard isScrollActive, [53, 36, 76].contains(keyCode) else { return false }
        if keyCode == 53 {
            handleScrollEscape()
        } else if scrollPhase == .finished {
            onScrollConfirm?()
        } else {
            onScrollStop?()
        }
        return true
    }

    /// Esc for a scrolling capture, independent of how the key arrived.
    func handleScrollEscape() {
        guard isScrollActive else { return }
        DebugLog.log("scroll: escape in phase \(scrollPhase)")
        if scrollPhase == .finished {
            // The finished result is still only pending: throw it away exactly
            // like Esc on a region shot discards the selection.
            onScrollClose?()
        } else {
            // Running / empty: stop sampling and close through the overlay's
            // ordinary cancel funnel (`onCancel` → coordinator cleanup).
            requestCancel("escape while scrolling")
        }
    }

    /// Feed one stitched frame to the fixed viewfinder.
    func updateScrollPreview(
        preview: ScrollPreviewFrame?,
        phase: ScrollPreviewPod.Phase,
        autoScrolling: Bool
    ) {
        guard isScrollActive else { return }
        scrollPhase = phase
        scrollPod.update(preview: preview, phase: phase, autoScrolling: autoScrolling)
        updateScrollProgress(preview)
        if scrollPod.isHidden, scrollPreviewEnabled, !scrollPreviewExternal {
            scrollPod.isHidden = false
            layoutSelection()
        }
    }

    /// Feed the captured-length ratio. It is bookkeeping only: nothing is
    /// drawn on the selection for it. Kept separate from the viewfinder so the
    /// coordinator can drive it even when the pod lives in its own window.
    func updateScrollProgress(_ preview: ScrollPreviewFrame?) {
        guard isScrollActive, scrollMode else { return }
        let region = selectionBorder.selectionRect
        guard let preview, preview.image.width > 0, region.height >= 1 else {
            scrollProgressRatio = 0
            return
        }
        // `contentHeight` is the whole stitch at the *band's* width. One point
        // of the band is `preview.image.width` pixels of the page, so the same
        // length expressed at the selection's width is this ratio.
        let stitchedPoints = preview.contentHeight
            * (region.width / CGFloat(preview.image.width))
        scrollProgressRatio = stitchedPoints / region.height
    }

    /// Show the finished long image in the viewfinder. The full image is
    /// composed once by the session; the pod still receives only the band it
    /// draws, so 完成 does not depend on the picture's length.
    ///
    /// `resumable` is what the session says about continuing: a finished
    /// session that stopped on its own or on 停止 can append more rows, so the
    /// footer offers 继续 next to 完成. A session that ran out of frames or
    /// height cannot, and offering the button would be a lie.
    func presentScrollResult(_ image: CGImage?, resumable: Bool = false) {
        guard isScrollActive else { return }
        scrollPhase = .finished
        scrollPod.isResumable = resumable
        guard let image else {
            scrollPod.update(preview: nil, phase: .finished, autoScrolling: false)
            return
        }
        let size = ScrollPreviewPod.bandSize(forCardSize: scrollPod.bandCardSize)
        let band = ScrollPreviewFrame.make(from: image, size: size)
        scrollPod.update(preview: band, phase: .finished, autoScrolling: false)
    }

    /// The viewfinder band size, in points, for the size the band is composed at.
    var scrollBandSize: CGSize {
        ScrollPreviewPod.bandSize(forCardSize: scrollPod.bandCardSize)
    }

    // MARK: - Scrolling: keeping the toolbar clickable

    /// Where the capture toolbar sits, in screen coordinates, while a scrolling
    /// session runs.
    ///
    /// The session has to hand the wheel to the page, and that is done by making
    /// the whole overlay panel click-through. The capture toolbar (✕, 拷贝, 保存,
    /// OCR…) lives in that same panel, so a fully click-through panel drops its
    /// clicks on the page — exactly the "工具栏的错叉点不动" report. The
    /// controller polls the pointer and turns the panel back into an interactive
    /// window while the pointer is on this rect (plus `scrollToolbarHotMargin`),
    /// so the plate is clickable without ever swallowing a wheel aimed at the
    /// page. `nil` means there is nothing to click: no live session, or the
    /// toolbar is hidden (Ctrl) / not yet revealed.
    var scrollToolbarScreenFrame: CGRect? {
        guard isScrollActive, let window,
              !toolbarSuppressed,
              !toolbar.isHidden,
              toolbar.alphaValue > 0,
              toolbar.frame.width > 0,
              toolbar.frame.height > 0
        else { return nil }
        return window.convertToScreen(convert(toolbar.frame, to: nil))
    }

    /// Slack around the plate so the pointer does not have to land on it
    /// pixel-perfectly for the click to register. Deliberately small: everything
    /// in this ring is still overlay, not page, so a click there is consumed by
    /// the capture UI rather than reaching the app behind it.
    static let scrollToolbarHotMargin: CGFloat = 6

    /// True while the session has made the panel interactive because the pointer
    /// is on the toolbar. Only the controller sets this, and only for a
    /// click-through session.
    private(set) var scrollPointerIsOverToolbar = false

    /// The controller's verdict for "the pointer is on the chrome right now".
    /// Flipping back to click-through also has to drop the toolbar's hover
    /// state: the window stops receiving pointer events, so no `mouseExited`
    /// ever arrives to clear it.
    func setScrollPointerOverToolbar(_ over: Bool) {
        guard scrollPointerIsOverToolbar != over else { return }
        scrollPointerIsOverToolbar = over
        if !over { toolbar.clearPointerHover() }
    }

    /// The card's drawn size changed (it grew, or it scaled down past the
    /// selection's height). The session has to compose its band at the new size.
    /// Called by the pod in this view and, for the external viewfinder, by the
    /// controller once it has the panel's own pod.
    func adoptScrollBandSize(_ size: CGSize) {
        guard size != lastScrollBandSize else { return }
        lastScrollBandSize = size
        onScrollPreviewSizeChanged?(size)
    }

    /// The viewfinder is a pure function of the selection: same box, same
    /// frame, no matter how long the stitched image becomes.
    private func layoutScrollPod(for rect: CGRect) {
        guard isScrollActive, scrollPreviewEnabled,
              rect.width >= 2, rect.height >= 2 else {
            scrollPod.isHidden = true
            return
        }
        let placement = ScrollPreviewPlacement.make(region: rect, screen: bounds)
        // The frame is the card's *box* (the selection's height); the card drawn
        // inside starts short, grows to that height, and then scales down inside
        // the same box so the frame never has to move.
        scrollPod.configure(
            cardSize: placement.cardSize,
            innerEdgeOnRight: placement.onLeft
        )
        // The external panel uses the same placement; the in-view copy is only
        // drawn for offscreen renders (the panel would otherwise be a second,
        // translucent copy showing through).
        scrollPod.isHidden = scrollPreviewExternal
        if scrollPod.frame != placement.frame {
            scrollPod.frame = placement.frame
        }
        scrollPod.needsDisplay = true
        adoptScrollBandSize(
            ScrollPreviewPod.bandSize(forCardSize: scrollPod.bandCardSize)
        )
    }

    /// A handle drag, a keyboard nudge or the size chip changed the box. Wait
    /// for the gesture to settle (180 ms) before telling the session, so a live
    /// drag does not restart the stitcher on every tick.
    private func scheduleScrollRegionCommit(_ rect: CGRect) {
        guard isScrollActive else { return }
        scrollRegionCommitTask?.cancel()
        scrollRegionCommitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard let self, !Task.isCancelled, self.isScrollActive else { return }
            let current = self.selectionBorder.selectionRect
            guard current != self.lastNotifiedScrollRect else { return }
            self.lastNotifiedScrollRect = current
            self.onScrollRegionCommitted?(current)
        }
    }

    /// The armed window is a committed selection, so the crosshair gives way to
    /// the ordinary arrow and no crossline is drawn. iShot draws its crosshair
    /// as a software cursor image and swaps it for the arrow over its own
    /// chrome (§15); a committed selection has no crosshair to show either.
    private func updateCursorForArmedState() {
        let armed = armedWindowPick != nil && !selectionBorder.hasSelection
        guard armed != cursorShowsArrow else { return }
        cursorShowsArrow = armed
        window?.invalidateCursorRects(for: self)
    }

    /// Keep the arm while the pointer is on the window or on the chrome that
    /// belongs to it; anywhere else drops back to plain crosshair hunting.
    private func isInsideArmedRegion(_ point: CGPoint, armed: WindowPick) -> Bool {
        if armed.rect.insetBy(dx: -Self.armedLeaveSlop, dy: -Self.armedLeaveSlop)
            .contains(point) {
            return true
        }
        if !toolbar.isHidden, toolbar.frame.insetBy(dx: -8, dy: -8).contains(point) {
            return true
        }
        if !indicator.isHidden, indicator.frame.insetBy(dx: -8, dy: -8).contains(point) {
            return true
        }
        return false
    }

    // MARK: - Crosshair freeze

    /// Pin the cross to the corner the drag was released on.
    ///
    /// The release point *is* a corner of the finished rectangle (snapping and
    /// the ratio lock can move the edge away from the raw pointer, which is why
    /// the corner is taken from the rect and only *chosen* by the pointer). The
    /// two arms then run along the right/left and bottom/top edges out to the
    /// screen edges, so they coincide with the selection's own two edges.
    private func freezeCrosshair(for rect: CGRect, releasedAt point: CGPoint) {
        guard showCrosshair, !windowConfirmationOnly,
              rect.width >= 2, rect.height >= 2 else {
            unfreezeCrosshair()
            return
        }
        frozenCorner = FrozenCorner(
            onMaxX: abs(point.x - rect.maxX) <= abs(point.x - rect.minX),
            onMinY: abs(point.y - rect.minY) <= abs(point.y - rect.maxY)
        )
        applyFrozenCrosshair(for: rect)
        updateLoupe(at: lastPointerPoint)
    }

    /// Put the frozen cross on the corner `frozenCorner` names, for the
    /// selection as it is *now*.
    private func applyFrozenCrosshair(for rect: CGRect) {
        guard let frozenCorner, rect.width >= 1, rect.height >= 1 else { return }
        let corner = CGPoint(
            x: frozenCorner.onMaxX ? rect.maxX : rect.minX,
            y: frozenCorner.onMinY ? rect.minY : rect.maxY
        )
        frozenCrosshairPoint = corner
        crosshair.point = corner
        crosshair.frozenRect = rect
    }

    // MARK: - Loupe

    /// Show, move or hide the magnifier for one pointer position.
    ///
    /// It follows the crosshair only while the crosshair is *tracking*: while
    /// the user hunts for a region, drags a box out, or drags a handle. Once
    /// the selection is committed the cross freezes to the box's edge and the
    /// pointer stops naming a pixel of that box, so the magnifier goes away
    /// rather than showing a patch that no longer relates to the selection.
    /// It also steps aside for every piece of chrome it could cover (toolbar,
    /// size chip, viewfinder), because those are click targets.
    private func updateLoupe(at point: CGPoint?) {
        guard showLoupe,
              mode == .region,
              !windowConfirmationOnly,
              // The magnifier is a selection tool. A recording's box is locked
              // and the pointer is free to work in the recorded app, so the
              // loupe has nothing to say.
              !isRecordingLive,
              !crosshair.isFrozen,
              armedWindowPick == nil,
              selectedWindowIDs.isEmpty,
              let point,
              bounds.contains(point),
              loupe.magnifiedImage != nil,
              toolbar.isHidden || !toolbar.frame.insetBy(dx: -6, dy: -6).contains(point),
              indicator.isHidden || !indicator.frame.insetBy(dx: -6, dy: -6).contains(point),
              scrollPod.isHidden || !scrollPod.frame.insetBy(dx: -6, dy: -6).contains(point)
        else {
            loupe.isHidden = true
            loupe.point = nil
            return
        }
        loupe.point = point
        loupe.isHidden = false
    }

    /// Keep the crosshair out of the chrome it sits below.
    ///
    /// The cross is drawn above the veil and the annotations but *under* the
    /// selection border, its handles, the toolbar and the size chip — the
    /// chrome is translucent glass and the handles are click targets. Without
    /// this clip the frozen line showed straight through the plate — a bright
    /// 1.2 pt cut across the buttons. The view clips its stroke to the
    /// complement of these rects.
    private func refreshCrosshairExclusions() {
        var rects: [CGRect] = []
        if !toolbar.isHidden, toolbar.frame.width > 0 {
            rects.append(toolbar.frame)
        }
        if !indicator.isHidden, indicator.frame.width > 0 {
            rects.append(indicator.frame)
        }
        if !scrollPod.isHidden, scrollPod.frame.width > 0 {
            rects.append(scrollPod.frame)
        }
        crosshair.exclusionRects = rects
    }

    /// Back to tracking the pointer.
    private func unfreezeCrosshair() {
        if frozenCorner != nil || frozenCrosshairPoint != nil || crosshair.isFrozen {
            frozenCorner = nil
            frozenCrosshairPoint = nil
            crosshair.frozenRect = nil
        }
        updateLoupe(at: lastPointerPoint)
    }

    // MARK: - Mouse

    /// Synthetic events in the self test run on a view with no window, where
    /// window-space conversion is meaningless. In production this is always
    /// the window-space conversion.
    private func localPoint(for event: NSEvent) -> CGPoint {
        if window == nil { return event.locationInWindow }
        return convert(event.locationInWindow, from: nil)
    }

    override func mouseDown(with event: NSEvent) {
        // The panels are click-through for a live recording; if an event does
        // arrive (test seam, a synthetic click), the rectangle is frozen.
        guard !isRecordingLive else { return }
        let point = localPoint(for: event)
        lastPointerPoint = point

        // The size chip owns its own click grammar and is checked before every
        // other branch: without this, a click on the chip would start a new
        // selection (or arm the window behind it) on the way to editing.
        if !indicator.isHidden, indicator.frame.contains(point) {
            if sizeEditActive {
                // Click inside the editor's padding: keep editing, no new box.
                indicator.focusField(indicator.activeField)
            } else {
                beginSizeEditing()
            }
            sizeEditConsumedClick = true
            return
        }
        if sizeEditActive {
            // Lost focus (clicked anywhere else): commit, and consume the click
            // so the new size is not immediately destroyed by a new box.
            commitSizeEdit()
            sizeEditConsumedClick = true
            return
        }

        window?.makeFirstResponder(self)
        // A missing mouse-up (app switch, panel teardown) must not swallow the
        // next gesture's mouse-up forever.
        sizeEditConsumedClick = false
        pressStartedAt = Self.clickTimingEnabled ? CFAbsoluteTimeGetCurrent() : nil
        let hoveredAtPress = hoveredPick

        // The pre-click window preview stays on screen through the press.
        //
        // This is the whole "click once and the window pops in late" fix: the
        // overlay used to drop the hovered window's punched-out highlight on
        // mouse-down and only rebuild it on mouse-up, so a normal 100–150 ms
        // press read as a black flash followed by the selection appearing.
        // Nothing is lost by keeping it: `mouseDragged` drops the preview the
        // moment the gesture becomes a rectangle, and mouse-up still decides
        // click-versus-drag from `armedPickAtPress` / `hoveredAtPress` copies.
        armedPickAtPress = armedWindowPick

        if windowConfirmationOnly {
            pressOrigin = point
            // The pointer is already on a window when the overlay opens; if
            // not, resolve now so the first click has a target.
            if !usesInjectedWindowCandidates { refreshCandidateWindows() }
            hoveredPick = hoveredAtPress ?? pickWindowUnderPoint(point).pick
            hoverPoint = point
            layoutSelection()
            return
        }

        // A plain click while a Shift-set exists clears it and then behaves
        // normally (the click can still capture the window under the pointer).
        if mode == .region, windowPickEnabled, !selectedWindowIDs.isEmpty,
           !event.modifierFlags.contains(.shift) {
            selectedWindowIDs.removeAll()
            updateWindowHighlights()
            layoutSelection()
        }

        // iShot: hold Shift and click windows to build a multi-window set.
        // This branch must land before every region drag branch.
        if mode == .region,
           windowPickEnabled,
           !windowConfirmationOnly,
           event.modifierFlags.contains(.shift),
           !selectionBorder.hasSelection {
            if !usesInjectedWindowCandidates { refreshCandidateWindowsIfStale() }
            if let target = hoveredAtPress?.candidate
                ?? pickWindowUnderPoint(point).pick?.candidate {
                toggleRegionWindow(target)
                suppressMouseUp = true
                return
            }
        }

        // A click outside the field ends the current text entry first; the
        // click then continues as whatever the new tool wants to do.
        if let field = textInputField, !field.frame.contains(point) {
            commitTextInput()
        }

        if mode == .multiWindow {
            if let hit = candidateWindow(at: point) {
                toggleWindow(hit)
            } else {
                // A click on empty desktop clears the set rather than
                // cancelling outright; Esc/right-click still exits.
                selectedWindowIDs.removeAll()
                updateWindowHighlights()
                onWindowSelectionCleared?()
            }
            return
        }

        // Double-click inside a valid selection is the "copy now" shortcut.
        // Only with the move tool: with a drawing tool a double-click should
        // paint, not confirm a capture the user did not ask for.
        if event.clickCount >= 2, currentTool == .move {
            let rect = selectionBorder.selectionRect
            if rect.width >= SelectionBorderView.minimumSide,
               rect.height >= SelectionBorderView.minimumSide,
               rect.contains(point) {
                onConfirm?(
                    rect,
                    annotationsForExport,
                    recordingMode ? .record : .copyClosing
                )
                return
            }
        }

        // Only a tracking cross may follow the press. A frozen cross is pinned
        // to the selection's corner, and this line used to move it to every
        // mouse-down on the canvas — so starting a paint stroke inside a
        // committed box dragged the "coordinate readout" to the pointer and
        // left it there for the rest of the stroke.
        if !crosshair.isFrozen {
            crosshair.point = point
        }

        // Text and note wait for a click inside the selection and open an
        // inline field instead of starting a stroke.
        if currentTool.isTextTool, canBeginText(at: point) {
            beginTextInput(at: point)
            return
        }

        // Counter stamps the next number immediately; sticker asks for an emoji
        // first. Both are single-click placements, never drags.
        if canPlaceClickTool(at: point) {
            if currentTool == .counter {
                placeCounter(at: point)
            } else {
                presentStickerPicker(at: point)
            }
            return
        }

        // Drawing tools paint only *inside* the selection and away from the
        // handles. A handle hit still resizes, and a drag outside still starts
        // a new box — the P0 state machine keeps those branches untouched.
        if canPaint(at: point) {
            beginStroke(at: point)
            return
        }

        // Remembered only for the box-creating path; handle/move/paint
        // branches above return before this and must not arm window picking.
        pressOrigin = allowsWindowPick ? point : nil
        pressHadSelection = selectionBorder.hasSelection
        pressSelectionRect = selectionBorder.selectionRect
        // A drag is a new gesture: the cross goes back to following the pointer
        // (it freezes again on release).
        unfreezeCrosshair()
        selectionBorder.beginInteraction(at: point, screenBounds: bounds)
        layoutSelection()
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .region, !isRecordingLive else { return }
        // The chip's editor swallows the gesture that opened it.
        if sizeEditActive || sizeEditConsumedClick { return }
        // Window confirmation has no rectangle gesture.
        if windowConfirmationOnly { return }
        var point = localPoint(for: event)
        lastPointerPoint = point

        // A paint stroke must not disturb the box that defines it. In the
        // armed-window state that box *is* `armedWindowPick`, so the drop below
        // (which a box-creating drag needs) used to run first: it cleared the
        // only source of `committedRect`, every later tick bailed out of
        // `continueStroke`, and the whole stroke was discarded on mouse-up.
        // Painting therefore wins over the drop.
        if isPainting {
            if !crosshair.isFrozen { crosshair.point = point }
            updateLoupe(at: point)
            continueStroke(to: point)
            return
        }

        // The press turned into a rectangle: from here on it is not a window
        // pick, so the preview mouse-down deliberately kept must go before the
        // box starts previewing. Dropping it here (rather than on mouse-down)
        // is what lets a click keep the window highlighted for its whole press.
        if hoveredPick != nil || armedWindowPick != nil {
            hoveredPick = nil
            hoverPoint = nil
            armedWindowPick = nil
        }

        // iShot's magnet: only a brand-new box snaps (moving/resizing keeps
        // the border view's exact maths), and each axis is independent.
        if selectionBorder.isCreatingSelection, !snapTargets.isEmpty {
            point = SelectionSnapping.snap(point, targets: snapTargets)
        }
        if selectionBorder.isCreatingSelection,
           let lockedAspect,
           let origin = pressOrigin {
            point = AspectLock.adjust(anchor: origin, point: point, ratio: lockedAspect)
        }
        if !crosshair.isFrozen {
            crosshair.point = point
        }
        updateLoupe(at: point)

        selectionBorder.continueInteraction(to: point)
        layoutSelection()
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .region, !isRecordingLive else { return }
        // Every exit leaves the loupe agreeing with the crosshair state: a
        // committed box hides it, a cancelled one brings it back.
        defer { updateLoupe(at: lastPointerPoint) }
        // The click that opened / committed / dismissed the size editor never
        // reaches the capture gestures.
        if sizeEditConsumedClick {
            sizeEditConsumedClick = false
            return
        }
        if sizeEditActive { return }
        if suppressMouseUp {
            suppressMouseUp = false
            return
        }
        let point = localPoint(for: event)
        if !crosshair.isFrozen {
            crosshair.point = point
        }

        if windowConfirmationOnly {
            guard let origin = pressOrigin else { return }
            pressOrigin = nil
            if Self.isSingleTap(from: origin, to: point, hadSelection: false) {
                pickWindowImmediately(at: point)
            }
            return
        }

        if isPainting {
            finishStroke(at: point)
            return
        }

        // Read these before `endInteraction`, which resets the creating flag.
        let wasCreating = selectionBorder.isCreatingSelection
        // Whether a committed box existed when the mouse went down. A click
        // outside it is a *cancel*, not a window pick: the pointer happens to
        // be over some window, but the user's last act was dismissing their
        // selection.
        let hadSelectionAtPress = pressHadSelection
        let origin = pressOrigin
        pressOrigin = nil
        pressHadSelection = false
        // The final edge must land on the same magnet as the drag did.
        var interactionPoint = point
        if wasCreating, !snapTargets.isEmpty {
            interactionPoint = SelectionSnapping.snap(point, targets: snapTargets)
        }
        if wasCreating, let lockedAspect, let origin = origin {
            interactionPoint = AspectLock.adjust(
                anchor: origin,
                point: interactionPoint,
                ratio: lockedAspect
            )
        }
        selectionBorder.endInteraction(at: interactionPoint)
        layoutSelection()

        // The selection is settled: the cross stops at the corner it was released
        // on and stays there until the user starts another gesture, draws a new
        // box, or the session ends. Reaching for the toolbar does *not* release
        // it: pinning means pinned, and a click on the toolbar never needs the
        // cross to follow the pointer.
        if selectionBorder.hasSelection,
           wasCreating || selectionBorder.selectionRect != pressSelectionRect {
            freezeCrosshair(
                for: selectionBorder.selectionRect,
                releasedAt: interactionPoint
            )
        }

        // A click (rather than a drag) means "capture the window under the
        // pointer". The decision lives here, at the event router: the border
        // view is only asked to clear the box its own minimum-size rule may
        // have grown out of a sub-4 pt wobble, and its drag semantics are
        // untouched.
        //
        // iShot does not veto this when a box already exists, and neither do we
        // any more: `hadSelection` used to turn the tap into "start a new box",
        // which is why single-click window capture appeared dead. `wasCreating`
        // still keeps a click *inside* the box a move gesture.
        if allowsWindowPick,
           wasCreating,
           !hadSelectionAtPress,
           let origin,
           Self.isWindowPickTap(from: origin, to: point) {
            if Self.clickTimingEnabled, let press = pressStartedAt {
                DebugLog.log(String(
                    format: "timing: mouseUp %.1f ms after mouseDown (press duration)",
                    (CFAbsoluteTimeGetCurrent() - press) * 1000
                ))
            }
            selectionBorder.clearSelection()
            layoutSelection()
            resolveWindowTap(at: point, armedAtPress: armedPickAtPress)
            armedPickAtPress = nil
            return
        }
        // Any other mouse-up ends the "second click?" question.
        armedPickAtPress = nil

        // OCR mode: the user just drew a box, so recognise it now instead of
        // making them hunt for the toolbar button. A click that collapsed the
        // box leaves `selectionIsValid` false and is ignored.
        if autoConfirmOnSelectionEnd, wasCreating, selectionIsValid {
            if scrollMode {
                // The whole point of the scrolling interface: the region
                // overlay (veil, border, handles, size chip, full toolbar)
                // stays on screen; only the pod is added.
                beginScrollSession()
            }
            if let onSelectionDrawn {
                onSelectionDrawn(selectionBorder.selectionRect, annotationsForExport)
            } else {
                onConfirm?(selectionBorder.selectionRect, annotationsForExport, .ocr)
            }
        } else if isScrollActive {
            // A moved/resized selection is only settled at mouse-up.
            scheduleScrollRegionCommit(selectionBorder.selectionRect)
        }
    }

    // MARK: - Painting

    private var selectionIsValid: Bool {
        guard let rect = committedRect else { return false }
        return rect.width >= 1 && rect.height >= 1
    }

    private func canPaint(at point: CGPoint) -> Bool {
        guard currentTool.isDrawingTool, let rect = committedRect else { return false }
        // Handles win over painting even when a drawing tool is active.
        guard selectionBorder.handle(at: point) == nil else { return false }
        return rect.contains(point)
    }

    private func beginStroke(at point: CGPoint) {
        guard let rect = committedRect else { return }
        let normalized = AnnotationCanvasView.normalized(point, in: rect)
        let style = style(for: currentTool)
        var color = style.color
        if currentTool == .highlighter {
            color = color.withAlphaComponent(style.opacity)
        }
        var annotation = Annotation(
            tool: currentTool,
            points: [normalized, normalized],
            color: color,
            lineWidth: style.lineWidth
        )
        if currentTool.isFreehand {
            annotation.points = [normalized]
        }
        activeStroke = annotation
        isPainting = true
        annotationCanvas.draft = annotation
    }

    private func continueStroke(to point: CGPoint) {
        guard isPainting, var stroke = activeStroke, let rect = committedRect else { return }
        let normalized = AnnotationCanvasView.normalized(point, in: rect)

        if stroke.isFreehand {
            // One point per pixel of travel keeps the polyline light without
            // visibly flattening the curve.
            let previous = AnnotationCanvasView.viewPoint(
                stroke.points[stroke.points.count - 1],
                in: rect
            )
            let current = AnnotationCanvasView.viewPoint(normalized, in: rect)
            guard hypot(current.x - previous.x, current.y - previous.y) >= 1 else { return }
            stroke.points.append(normalized)
        } else {
            stroke.points = [stroke.points[0], normalized]
        }

        activeStroke = stroke
        annotationCanvas.draft = stroke
    }

    private func finishStroke(at point: CGPoint) {
        defer {
            isPainting = false
            activeStroke = nil
            annotationCanvas.draft = nil
        }
        guard var stroke = activeStroke, let rect = committedRect else { return }

        let normalized = AnnotationCanvasView.normalized(point, in: rect)
        if stroke.isFreehand {
            let previous = AnnotationCanvasView.viewPoint(
                stroke.points[stroke.points.count - 1],
                in: rect
            )
            let current = AnnotationCanvasView.viewPoint(normalized, in: rect)
            if hypot(current.x - previous.x, current.y - previous.y) >= 1 {
                stroke.points.append(normalized)
            }
        } else {
            stroke.points = [stroke.points[0], normalized]
        }

        // A click with no drag must not leave a dot behind.
        guard stroke.hasMinimumGeometry(in: rect.size) else { return }
        annotationStore.add(stroke)
    }

    // MARK: - Inline text input

    /// Click target for `.text` / `.note`: inside the selection, not on a
    /// resize handle (the P0 handle precedence still wins).
    private func canBeginText(at point: CGPoint) -> Bool {
        guard currentTool.isTextTool, let rect = committedRect else { return false }
        guard selectionBorder.handle(at: point) == nil else { return false }
        return rect.contains(point)
    }

    private func beginTextInput(at point: CGPoint) {
        guard currentTool.isTextTool, canBeginText(at: point) else { return }
        commitTextInput()

        // Top-left of the field (AppKit y-up) sits exactly on the click; the
        // field is normally 28 pt tall, and `layoutTextInputField` may push it
        // back inside the screen, which the commit then follows.
        let fontSize = style(for: currentTool).fontSize
        let fieldHeight = max(28, ceil(fontSize * 1.45))
        let field = NSTextField(frame: CGRect(
            x: point.x,
            y: point.y - fieldHeight,
            width: 180,
            height: fieldHeight
        ))
        field.font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        field.focusRingType = .none
        field.isBordered = false
        field.bezelStyle = .squareBezel
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.cell?.sendsActionOnEndEditing = false

        if currentTool == .note {
            field.textColor = AnnotationTool.note.defaultColor
            field.drawsBackground = true
            field.backgroundColor = NSColor(
                srgbRed: 1.00,
                green: 0.96,
                blue: 0.72,
                alpha: 1
            )
            field.wantsLayer = true
            field.layer?.cornerRadius = 6
            field.layer?.borderWidth = 1
            field.layer?.borderColor = NSColor(
                srgbRed: 0.52,
                green: 0.42,
                blue: 0.14,
                alpha: 1
            ).cgColor
            field.placeholderString = "输入备注，回车确认"
        } else {
            field.textColor = AnnotationTool.text.defaultColor
            field.drawsBackground = false
            field.placeholderString = "输入文字，回车确认"
        }

        field.delegate = self
        field.target = self
        field.action = #selector(textFieldAction(_:))
        addSubview(field)
        textInputField = field
        textInputAnchor = point
        layoutTextInputField()
        installTextKeyMonitor()

        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    /// Size the field to its content without letting it run off the screen.
    ///
    /// This is also the only place that moves the field after the click: near a
    /// screen edge it is pushed back inside the screen, and `commitTextInput`
    /// reads the resulting origin so the text follows the box.
    private func layoutTextInputField() {
        guard let field = textInputField else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: field.font ?? NSFont.systemFont(ofSize: AnnotationRenderer.textFontSize)
        ]
        let measured = (field.stringValue as NSString).size(withAttributes: attributes)
        let padding: CGFloat = currentTool == .note ? 24 : 14
        let width = min(max(measured.width + padding, 120), 520)
        var frame = field.frame
        frame.size.width = width
        let maxX = max(bounds.minX, bounds.maxX - frame.width)
        let maxY = max(bounds.minY, bounds.maxY - frame.height)
        frame.origin.x = min(max(frame.origin.x, bounds.minX), maxX)
        frame.origin.y = min(max(frame.origin.y, bounds.minY), maxY)
        field.frame = frame
    }

    /// Commit the field into an `Annotation`. Empty text is discarded, exactly
    /// like a zero-length stroke.
    ///
    /// The annotation anchor is the **field's top-left corner**, not the click
    /// that opened it: near a screen edge the field is pushed back inside the
    /// screen, and committing the raw click made the text land up to a field
    /// width to the right / one field height below its own input box (the
    /// "text drifts right and down by ~20 pt" bug).
    private func commitTextInput() {
        guard let field = textInputField, let clickAnchor = textInputAnchor else { return }
        let value = field.stringValue
        let boxOrigin = CGPoint(x: field.frame.minX, y: field.frame.maxY)
        removeTextInput()

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            window?.makeFirstResponder(self)
            return
        }

        guard let rect = committedRect, rect.width >= 1, rect.height >= 1 else {
            window?.makeFirstResponder(self)
            return
        }
        let normalized = AnnotationCanvasView.normalized(boxOrigin, in: rect)
        let tool = currentTool
        let style = style(for: tool)
        let annotation = Annotation(
            tool: tool,
            points: [normalized, normalized],
            color: style.color,
            lineWidth: 1,
            fontSize: tool.isTextTool ? style.fontSize : nil,
            text: trimmed
        )
        annotationStore.add(annotation)
        DebugLog.log(
            "text: committed \(tool.rawValue) '\(trimmed)' "
            + "click=(\(Int(clickAnchor.x)),\(Int(clickAnchor.y))) "
            + "box=(\(Int(boxOrigin.x)),\(Int(boxOrigin.y)))"
        )
        window?.makeFirstResponder(self)
    }

    /// Escape path: drop the field, add nothing.
    private func cancelTextInput() {
        guard textInputField != nil else { return }
        removeTextInput()
        window?.makeFirstResponder(self)
    }

    private func removeTextInput() {
        if let textKeyMonitor {
            NSEvent.removeMonitor(textKeyMonitor)
            self.textKeyMonitor = nil
        }
        textInputField?.removeFromSuperview()
        textInputField = nil
        textInputAnchor = nil
    }

    /// The field editor's delegate path can be skipped by a non-activating
    /// panel, so Return/Escape are caught at the app's event queue. The monitor
    /// exists only while the field exists and sees only this app's key events.
    private func installTextKeyMonitor() {
        guard textKeyMonitor == nil else { return }
        textKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.textInputField != nil else { return event }
            switch event.keyCode {
            case 53: // esc
                self.cancelTextInput()
                return nil
            case 36, 76: // return / keypad enter
                self.commitTextInput()
                return nil
            default:
                return event
            }
        }
    }

    /// Fallback for the standard single-line Return action.
    @objc private func textFieldAction(_ sender: Any?) {
        commitTextInput()
    }

    /// `NSTextFieldDelegate`: Enter commits, Escape discards. Kept as a
    /// secondary path for hosts where the field editor does forward commands.
    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        DebugLog.log("text: field command \(commandSelector)")
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitTextInput()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelTextInput()
            return true
        }
        return false
    }

    func controlTextDidChange(_ notification: Notification) {
        layoutTextInputField()
    }

    // MARK: - Editable size chip

    /// A single click on the size capsule turns it into a two-field editor.
    ///
    /// The armed-window case is deliberately allowed: the chip already shows a
    /// committed size there, and typing a size is an explicit request for a
    /// rectangle, so committing turns the armed window into an ordinary
    /// selection (documented as a product choice).
    private func beginSizeEditing() {
        guard !sizeEditActive, let rect = committedRect else { return }
        sizeEditActive = true
        // An annotation text field can never coexist (different tool / focus),
        // but committing keeps the responder chain unambiguous if it somehow
        // does.
        commitTextInput()
        dismissStickerPicker()
        indicator.beginEditing(
            width: Int(rect.width.rounded()),
            height: Int(rect.height.rounded())
        )
        installSizeEditKeyMonitor()
        indicator.focusField(0)
        layoutSelection()
        DebugLog.log(
            "size-chip: editing \(SizeIndicatorView.text(for: rect.size)) "
            + "armed=\(armedWindowPick != nil && !selectionBorder.hasSelection)"
        )
    }

    /// The toolbar's left-group chip and the overlay's floating chip are the same
    /// view, so a tap always lands in this one grammar.
    private func handleSizeChipTap() {
        if sizeEditActive {
            indicator.focusField(indicator.activeField)
            return
        }
        beginSizeEditing()
    }

    /// One stepper press: both axes move by ±1 pt (Shift ±10), centre-anchored
    /// by the same `centeredResize` every other size commit uses. The steppers
    /// are a coarse nudge; the chip's editor remains the exact path.
    private func stepSelectionSize(by delta: CGFloat) {
        if sizeEditActive { commitSizeEdit() }
        guard let rect = committedRect else { return }
        let target = CGSize(
            width: max(1, rect.width + delta),
            height: max(1, rect.height + delta)
        )
        let resized = SelectionBorderView.centeredResize(rect, to: target, within: bounds)
        // Same rule as the chip editor: an armed window that gets an explicit
        // rectangle becomes an ordinary selection.
        armedWindowPick = nil
        selectionBorder.setSelection(resized)
        layoutSelection()
        DebugLog.log(
            "toolbar size-step: \(SizeIndicatorView.text(for: rect.size)) → "
            + "\(SizeIndicatorView.text(for: resized.size)) delta=\(delta)"
        )
    }

    /// The left group's export-shadow menu writes the real 截图阴影 preference
    /// (`captureShadowEnabled` + `captureShadowSize`), the pair `d92461f` added
    /// to the export decoration.
    private func applyShadowLevel(_ level: CaptureToolbarShadowLevel) {
        settings?.captureShadowEnabled = level.isEnabled
        if level.isEnabled {
            settings?.captureShadowSize = level.size
        }
        toolbar.setShadowLevel(level)
        DebugLog.log(
            "toolbar shadow: \(level.title) enabled=\(level.isEnabled) size=\(level.size)"
        )
    }

    /// The left group's switch is the real 显示十字线 preference. Changing it also
    /// updates the live capture, which is the point of having it here.
    private func applyCrosshairVisibility(_ on: Bool) {
        showCrosshair = on
        crosshair.isHidden = !on
        settings?.showCrosshair = on
        toolbar.setCrosshairOn(on)
        DebugLog.log("toolbar crosshair: \(on)")
    }

    /// Map the stored export-shadow pair onto the four menu choices.
    private static func shadowLevel(for settings: AppSettings?) -> CaptureToolbarShadowLevel {
        guard let settings else { return .none }
        return CaptureToolbarShadowLevel.level(
            enabled: settings.captureShadowEnabled,
            size: settings.captureShadowSize
        )
    }

    /// Commit the typed size and leave the editor.
    ///
    /// Empty or non-numeric axes keep their current value; the whole rectangle
    /// is then clamped by `SelectionBorderView.centeredResize` (40 pt minimum,
    /// screen maximum, centre anchored).
    private func commitSizeEdit() {
        guard sizeEditActive, let rect = committedRect else {
            finishSizeEditing()
            return
        }
        let values = indicator.editingValues()
        finishSizeEditing()

        var size = rect.size
        if let width = values.width { size.width = CGFloat(width) }
        if let height = values.height { size.height = CGFloat(height) }
        let resized = SelectionBorderView.centeredResize(rect, to: size, within: bounds)

        // Editing an armed window promotes it to a real selection: the user
        // just asked for an exact rectangle, so the window identity no longer
        // describes what will be captured.
        armedWindowPick = nil
        selectionBorder.setSelection(resized)
        layoutSelection()
        DebugLog.log(
            "size-chip: commit \(SizeIndicatorView.text(for: rect.size)) → "
            + "\(SizeIndicatorView.text(for: resized.size)) "
            + "\(NSStringFromRect(resized))"
        )
    }

    /// Escape path: drop the editor, leave the selection exactly as it was.
    private func cancelSizeEdit() {
        guard sizeEditActive else { return }
        finishSizeEditing()
        DebugLog.log("size-chip: edit cancelled")
    }

    /// Tear down the editor without touching the selection.
    private func finishSizeEditing() {
        guard sizeEditActive else {
            removeSizeEditKeyMonitor()
            return
        }
        sizeEditActive = false
        sizeEditConsumedClick = false
        removeSizeEditKeyMonitor()
        // Clear first responder before detaching the fields, so AppKit does not
        // tear down a field editor for a view that is already gone.
        window?.makeFirstResponder(self)
        indicator.endEditing()
        layoutSelection()
    }

    private func toggleSizeEditField() {
        guard sizeEditActive else { return }
        indicator.focusField(indicator.activeField == 0 ? 1 : 0)
    }

    /// The field editor's delegate cannot be trusted for Return/Escape in a
    /// non-activating panel (same constraint as the inline text field), so the
    /// keys are caught at the app's event queue. The monitor lives only while
    /// the editor exists.
    private func installSizeEditKeyMonitor() {
        guard sizeEditKeyMonitor == nil else { return }
        sizeEditKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.sizeEditActive else { return event }
            switch event.keyCode {
            case 53: // esc
                self.cancelSizeEdit()
                return nil
            case 36, 76: // return / keypad enter
                self.commitSizeEdit()
                return nil
            case 48: // tab
                guard !event.modifierFlags.contains(.command) else { return event }
                self.toggleSizeEditField()
                return nil
            default:
                return event
            }
        }
    }

    private func removeSizeEditKeyMonitor() {
        if let sizeEditKeyMonitor {
            NSEvent.removeMonitor(sizeEditKeyMonitor)
            self.sizeEditKeyMonitor = nil
        }
    }

    // MARK: - Click placement (counter / sticker)

    /// Counter and sticker place one anchor per click: inside the selection and
    /// never on a resize handle (the P0 handle precedence still wins).
    private func canPlaceClickTool(at point: CGPoint) -> Bool {
        guard currentTool == .counter || currentTool == .sticker else { return false }
        guard let rect = committedRect else { return false }
        guard selectionBorder.handle(at: point) == nil else { return false }
        return rect.contains(point)
    }

    /// Stamp the next badge number. The number itself is decided by
    /// `AnnotationStore.nextCounterValue`, which applies the "highest + 1"
    /// rule including badges that were undone.
    private func placeCounter(at point: CGPoint) {
        guard let rect = committedRect, rect.width >= 1, rect.height >= 1 else { return }
        let normalized = AnnotationCanvasView.normalized(point, in: rect)
        let value = annotationStore.nextCounterValue
        let style = style(for: .counter)
        let annotation = Annotation(
            tool: .counter,
            points: [normalized, normalized],
            color: style.color,
            lineWidth: 0,
            text: String(value)
        )
        annotationStore.add(annotation)
        DebugLog.log("counter: placed \(value) at (\(Int(point.x)),\(Int(point.y)))")
    }

    /// Drop the picked emoji at the anchor the picker was opened at.
    private func placeSticker(_ emoji: String, at point: CGPoint) {
        guard let rect = committedRect, rect.width >= 1, rect.height >= 1 else { return }
        let normalized = AnnotationCanvasView.normalized(point, in: rect)
        let annotation = Annotation(
            tool: .sticker,
            points: [normalized, normalized],
            color: AnnotationTool.sticker.defaultColor,
            lineWidth: 0,
            text: emoji
        )
        annotationStore.add(annotation)
        DebugLog.log("sticker: placed \(emoji) at (\(Int(point.x)),\(Int(point.y)))")
    }

    /// Open the emoji grid next to the click. The popover is transient, so a
    /// click elsewhere (or Escape) cancels it without changing anything.
    private func presentStickerPicker(at point: CGPoint) {
        // Close first: the old popover's delegate clears the pending anchor.
        dismissStickerPicker()
        pendingStickerAnchor = point

        // Offscreen harness (no window): a popover needs a window server. The
        // self test drives `placeSticker` through the same commit path.
        guard let window else {
            DebugLog.log("sticker: offscreen, picker suppressed")
            return
        }

        let picker = StickerPickerController()
        // Identity checks: a *previous* popover can finish closing after the
        // new one is already assigned, and its late `onClose` must not clear
        // the new picker or its pending anchor.
        picker.onPick = { [weak self, weak picker] emoji in
            guard let self, let picker, self.stickerPicker === picker else { return }
            let anchor = self.pendingStickerAnchor ?? point
            self.stickerPicker = nil
            self.pendingStickerAnchor = nil
            self.placeSticker(emoji, at: anchor)
        }
        picker.onClose = { [weak self, weak picker] in
            guard let self, let picker, self.stickerPicker === picker else { return }
            self.stickerPicker = nil
            self.pendingStickerAnchor = nil
        }
        stickerPicker = picker
        picker.present(
            anchorRect: CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2),
            in: self
        )
        window.makeFirstResponder(self)
    }

    private func dismissStickerPicker() {
        stickerPicker?.close()
        stickerPicker = nil
        pendingStickerAnchor = nil
    }

    // MARK: - Tools & history

    func style(for tool: AnnotationTool) -> AnnotationStyle {
        toolStyles[tool] ?? .defaultStyle(for: tool)
    }

    func setStyle(_ style: AnnotationStyle, for tool: AnnotationTool) {
        toolStyles[tool] = style.clamped(for: tool)
    }

    /// Present the style popover anchored to the toolbar's palette button.
    private func presentStylePanel() {
        guard window != nil, let frame = toolbar.styleButtonFrame else {
            DebugLog.log("style panel: offscreen, suppressed")
            return
        }
        stylePopover?.close()
        let controller = AnnotationStylePanelController(
            tool: currentTool,
            style: style(for: currentTool)
        ) { [weak self] style in
            guard let self else { return }
            self.setStyle(style, for: self.currentTool)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = controller
        popover.show(relativeTo: frame, of: toolbar, preferredEdge: .maxY)
        stylePopover = popover
    }

    /// Selecting a tool never touches the selection or the stored annotations;
    /// after painting, the tool stays selected for the next stroke.
    /// Match one key-down against the configured annotation-tool shortcuts.
    ///
    /// The settings store is optional so the offscreen harness can build an
    /// overlay without touching the user's defaults; in that case the shipped
    /// defaults are the fallback. Only a usable combination (⌘ / ⌥ / ⌃) can
    /// match, so ordinary typing never changes tools.
    private func handleAnnotationToolShortcut(_ event: NSEvent) -> Bool {
        guard !windowConfirmationOnly, !isScrollActive, textInputField == nil else {
            return false
        }
        let carbon = KeyCodeFormatter.carbonModifiers(from: event.modifierFlags)
        guard KeyCodeFormatter.isUsableGlobalHotKey(carbon) else { return false }
        let pressed = HotKeyConfiguration(
            keyCode: UInt32(event.keyCode),
            modifiers: carbon
        )
        guard pressed.isBound else { return false }

        let tool = settings?.annotationTool(matching: pressed)
            ?? AnnotationTool.allCases.first {
                HotKeyConfiguration.annotationTool($0) == pressed
            }
        guard let tool else { return false }
        selectTool(tool)
        DebugLog.log("tool: \(pressed.displayString) → \(tool.rawValue)")
        return true
    }

    private func selectTool(_ tool: AnnotationTool) {
        // Switching tools is an implicit "done" for an open text field, an
        // open size editor and a sticker picker that is still waiting for a
        // pick.
        if sizeEditActive { commitSizeEdit() }
        commitTextInput()
        dismissStickerPicker()
        currentTool = tool
        toolbar.setCurrentTool(tool)

        // A tool switch mid-stroke discards only the uncommitted draft.
        if isPainting {
            isPainting = false
            activeStroke = nil
            annotationCanvas.draft = nil
        }
        window?.invalidateCursorRects(for: self)
    }

    private func annotationsChanged() {
        annotationCanvas.annotations = annotationStore.annotations
        // Keep a draft that predates a store change (undo during painting is
        // impossible from the UI, but the test hooks can do it).
        annotationCanvas.draft = activeStroke
        refreshHistoryButtons()
    }

    private func refreshHistoryButtons() {
        toolbar.setHistoryState(
            canUndo: annotationStore.canUndo,
            canRedo: annotationStore.canRedo
        )
    }

    private func undoAnnotation() {
        annotationStore.undo()
    }

    private func redoAnnotation() {
        annotationStore.redo()
    }

    /// Annotations as they will be exported. Normalised to the selection.
    var annotationsForExport: [Annotation] { annotationStore.annotations }

    override func mouseMoved(with event: NSEvent) {
        guard !isRecordingLive else { return }
        let point = localPoint(for: event)
        // A live scrolling session is click-through, so the only `mouseMoved`
        // that can arrive is a trip across the toolbar's interactive hot zone.
        // The pointer is then on the chrome, not on the page: neither the
        // crosshair readout nor the loupe has anything to say about it. This is
        // the key that opens the toolbar, not a selection gesture.
        if scrollPointerIsOverToolbar {
            lastPointerPoint = point
            return
        }
        // A frozen cross never moves again on `mouseMoved` — not through the
        // canvas, and not when the pointer reaches the toolbar or the size
        // chip. Those are clickable either way; unfreezing for them was the bug.
        // Only a new gesture (drag / handle / new box) or a cleared selection
        // unfreezes it.
        if !crosshair.isFrozen {
            crosshair.point = point
        }
        lastPointerPoint = point
        updateLoupe(at: point)
        // While the size editor is open the pointer cannot re-arm / dismiss a
        // window or repaint the hover highlight underneath it.
        if sizeEditActive { return }
        if mode == .multiWindow {
            refreshCandidateWindowsIfStale()
            updateMultiWindowHover(at: point)
            return
        }

        // While a window is armed the highlight belongs to it; the pointer only
        // moves the hint capsule, it does not re-pick a window under the cursor.
        // Leaving the committed window (and its toolbar) drops the arm, which
        // brings the crosshair back — the arm only lives where the user can see
        // and click it.
        if let armed = armedWindowPick {
            if isInsideArmedRegion(point, armed: armed) {
                if hoverPoint != point {
                    hoverPoint = point
                    windowHighlight.hintAnchor = point
                }
                return
            }
            clearArmedWindowPick()
        }

        guard mode == .region,
              windowPickEnabled,
              !selectionBorder.hasSelection,
              textInputField == nil,
              stickerPicker == nil else {
            clearWindowHover()
            return
        }

        if !usesInjectedWindowCandidates { refreshCandidateWindowsIfStale() }
        let target = pickWindowUnderPoint(point).pick
        guard target?.candidate.windowNumber != hoveredPick?.candidate.windowNumber else {
            if hoverPoint != point {
                hoverPoint = point
                windowHighlight.hintAnchor = point
            }
            return
        }
        hoveredPick = target
        hoverPoint = point
        layoutSelection()
    }

    override func mouseExited(with event: NSEvent) {
        guard mode == .region else { return }
        clearWindowHover()
    }

    /// iShot: the scroll wheel adjusts the highlighter's opacity.
    override func scrollWheel(with event: NSEvent) {
        // Whether the wheel reaches the overlay at all is the whole question
        // behind "长截图滑不动", so arrival is traced before any policy runs.
        DebugLog.log(
            "scroll: wheel@overlay appActive=\(NSApp.isActive) "
                + "key=\(window?.isKeyWindow == true) session=\(isScrollActive) "
                + "phase=\(scrollPhase) delta=\(event.scrollingDeltaY)"
        )
        // The wheel reached the *chrome*: the pointer is on the toolbar's hot
        // zone, which is the one part of the overlay that is interactive while
        // the session runs click-through. The page underneath is not what the
        // user is aiming at, and re-asserting transparency from here would only
        // take the toolbar away from under the pointer. Swallow it.
        if isScrollActive, scrollPhase != .finished, scrollPointerIsOverToolbar {
            DebugLog.log(
                "scroll: wheel over the toolbar consumed "
                    + "delta=\(event.scrollingDeltaY)"
            )
            return
        }
        // While the session is live the overlay is click-through, so the page
        // receives the user's own wheel directly and this branch is dead code
        // in practice. It stays as a repair: the session re-asserts
        // transparency rather than re-posting (a re-post lands on this same
        // window and turns one scroll into an endless one).
        if isScrollActive, scrollPhase != .finished, let onScrollWheel {
            DebugLog.log(
                "scroll: overlay wheel delta=\(event.scrollingDeltaY) "
                    + "precise=\(event.hasPreciseScrollingDeltas) "
                    + "cg=\(event.cgEvent == nil ? "nil" : "yes")"
            )
            onScrollWheel(event)
            return
        }
        // Finished, and the wheel is back on an interactive overlay: this is
        // exactly the "still won't scroll" state. The user is asking for more
        // page, so resume the session instead of swallowing the wheel and
        // leaving the card frozen with a dead overlay. The gesture's remaining
        // events land on the page (click-through + activation are restored by
        // the resume); this one is consumed here, and deliberately not
        // re-posted — that loop is what the previous fix removed.
        if isScrollActive, scrollPhase == .finished, scrollPod.isResumable {
            DebugLog.log("scroll: wheel after finish → resume instead of swallowing")
            onScrollResume?()
            return
        }
        guard mode == .region,
              currentTool == .highlighter,
              selectionBorder.hasSelection else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY
            : event.scrollingDeltaY * 3
        var style = style(for: .highlighter)
        style.opacity = min(max(0.15, style.opacity + delta * 0.02), 1.0)
        setStyle(style, for: .highlighter)
        DebugLog.log(
            "highlighter: opacity=\(Int((style.opacity * 100).rounded()))%"
        )
    }

    override func rightMouseDown(with event: NSEvent) {
        guard !isRecordingLive else { return }
        // In a Shift-selected set, the first right-click clears the set.
        if !selectedWindowIDs.isEmpty {
            clearWindowSelection()
            return
        }
        // iShot exits on right-click; drop the editor (and its key monitor)
        // first so teardown cannot leave one behind.
        cancelSizeEdit()
        requestCancel("right click")
    }

    override func resetCursorRects() {
        let cursor: NSCursor
        if armedWindowPick != nil, !selectionBorder.hasSelection {
            // No crosshair over a committed window: it is a selection now.
            cursor = .arrow
        } else if currentTool.isTextTool {
            cursor = .iBeam
        } else {
            cursor = .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    private func clearWindowHover() {
        guard hoveredPick != nil else { return }
        hoveredPick = nil
        hoverPoint = nil
        layoutSelection()
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // Esc / Return must not tear the overlay down while a stream owns it:
        // the HUD's 停止 is the only way out.
        guard !isRecordingLive else { return }
        // While editing, every key belongs to the chip. This is the safety net
        // for hosts where the field editor does not hold first responder: the
        // local monitor handles the same keys in production, and no key may
        // leak into the ratio / nudge / Return-capture branches below.
        if sizeEditActive {
            switch event.keyCode {
            case 53:  // esc
                cancelSizeEdit()
            case 36, 76:  // return / keypad enter
                commitSizeEdit()
            case 48:  // tab
                // Leave ⌘⇄ alone: that is the system app switcher, not field
                // traversal.
                if !event.modifierFlags.contains(.command) {
                    toggleSizeEditField()
                }
            default:
                break
            }
            return
        }

        // Escape first closes an open emoji grid; only a second press cancels
        // the capture. The popover is not key while the overlay panel is, so
        // its own Escape handling never runs.
        if event.keyCode == 53, stickerPicker != nil {
            dismissStickerPicker()
            return
        }

        // ⌘Z / ⇧⌘Z for the annotation history. Handled before the key-code
        // switch so the text input path never sees it.
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            if event.modifierFlags.contains(.shift) {
                redoAnnotation()
            } else {
                undoAnnotation()
            }
            return
        }

        // 设置 → 快捷键 → 标注工具. These are overlay-local: the overlay
        // matches the stored combination itself, so they never become global
        // Carbon hotkeys. The shipped defaults are ⌘1…⌘9 / ⌘0 / ⌘- / ⌘=, which
        // leaves the bare digits below free for the aspect-ratio lock.
        if handleAnnotationToolShortcut(event) {
            return
        }

        // iShot: number keys lock width:height (0=Free, 1=1:1 … 9=4:3).
        if !windowConfirmationOnly,
           textInputField == nil,
           !event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.control),
           let chars = event.charactersIgnoringModifiers,
           chars.count == 1,
           let digit = Int(chars),
           (0...9).contains(digit) {
            if digit == 0 {
                lockedAspect = nil
            } else if let ratio = AspectLock.ratio(for: digit) {
                lockedAspect = ratio
                if selectionBorder.hasSelection {
                    selectionBorder.setSelection(
                        AspectLock.fit(selectionBorder.selectionRect, ratio: ratio, within: bounds)
                    )
                }
            }
            layoutSelection()
            return
        }

        // iShot: F selects the whole screen as the rectangle.
        if event.keyCode == 3, !windowConfirmationOnly, textInputField == nil,
           !event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.control) {
            selectedWindowIDs.removeAll()
            updateWindowHighlights()
            selectionBorder.setSelection(bounds)
            lockedAspect = nil
            layoutSelection()
            return
        }

        // iShot: arrow keys nudge the selection one pixel (Shift = ten).
        if [123, 124, 125, 126].contains(event.keyCode),
           selectionBorder.hasSelection,
           textInputField == nil {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let dx: CGFloat = event.keyCode == 123 ? -step : (event.keyCode == 124 ? step : 0)
            let dy: CGFloat = event.keyCode == 125 ? -step : (event.keyCode == 126 ? step : 0)
            nudgeSelection(dx: dx, dy: dy)
            return
        }

        // The scrolling session's Return/Esc grammar. While the session is
        // click-through these keys reach the page, not us; the controller's
        // temporary global Escape hotkey funnels into the same method.
        if handleScrollKey(event.keyCode) {
            return
        }

        switch event.keyCode {
        case 53:  // esc
            if armedWindowPick != nil || armedPickAtPress != nil {
                clearArmedWindowPick()
                armedPickAtPress = nil
                return
            }
            if !selectedWindowIDs.isEmpty {
                clearWindowSelection()
                return
            }
            requestCancel("escape")
        case 36, 76:  // return / keypad enter
            if windowConfirmationOnly {
                if let hoveredPick {
                    onWindowPicked?(CGWindowID(hoveredPick.candidate.windowNumber), hoveredPick.rect)
                } else {
                    NSSound.beep()
                }
            } else if mode == .multiWindow || !selectedWindowIDs.isEmpty {
                confirmMultiWindow()
            } else if recordingMode {
                confirmRecording()
            } else {
                confirmCopy()
            }
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        guard !isRecordingLive else { return }
        if sizeEditActive {
            cancelSizeEdit()
            return
        }
        requestCancel("cancelOperation")
    }

    /// iShot: tapping Control hides/shows the annotation toolbar.
    override func flagsChanged(with event: NSEvent) {
        guard !isRecordingLive else { return }
        let down = event.modifierFlags.contains(.control)
        guard down != controlWasDown else { return }
        controlWasDown = down
        guard down, selectionBorder.hasSelection else { return }
        toolbarSuppressed.toggle()
        if !toolbarSuppressed {
            cancelToolbarReveal()
            toolbarIsRevealed = true
        }
        layoutSelection()
    }

    /// One funnel for the five ways the overlay can be dismissed, so a trace
    /// can tell which one fired.
    private func requestCancel(_ reason: String) {
        DebugLog.log("overlay: cancel from \(reason)")
        onCancel?()
    }

    private func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        var rect = selectionBorder.selectionRect
        guard rect.width >= 1, rect.height >= 1 else { return }
        let maxX = max(bounds.minX, bounds.maxX - rect.width)
        let maxY = max(bounds.minY, bounds.maxY - rect.height)
        rect.origin.x = min(max(rect.origin.x + dx, bounds.minX), maxX)
        rect.origin.y = min(max(rect.origin.y + dy, bounds.minY), maxY)
        selectionBorder.setSelection(rect)
        layoutSelection()
    }

    private func confirmCopy() {
        commitTextInput()
        guard let rect = committedRect, rect.width >= 1, rect.height >= 1 else { return }
        onConfirm?(rect, annotationsForExport, .copyClosing)
    }

    /// Return (or the toolbar's 开始录制) in a recording overlay. The rectangle
    /// is the same one a screenshot would capture; the coordinator turns it
    /// into the stream's source rect.
    private func confirmRecording() {
        commitTextInput()
        guard let rect = committedRect, rect.width >= 1, rect.height >= 1 else { return }
        onConfirm?(rect, annotationsForExport, .record)
    }

    private func toolbarAction(_ action: CaptureToolbarAction) {
        dismissStickerPicker()
        if action == .cancel {
            cancelSizeEdit()
            cancelTextInput()
            requestCancel("toolbar cancel")
            return
        }
        // Clicking a toolbar button is "done" for the size editor; commit
        // before the action reads the rectangle.
        if sizeEditActive { commitSizeEdit() }
        guard let rect = committedRect, rect.width >= 1, rect.height >= 1 else { return }

        // "Copy and keep" is the only non-terminal action: it reports the
        // payload and returns, leaving the panel, selection and annotations
        // untouched so the user can keep editing.
        if isScrollActive {
            // A long capture cannot be "copied as pixels" before it has been
            // stitched. Copy-and-keep writes the current stitch and lets the
            // session run; every terminal action finishes first and then
            // delivers the long image through the same pipeline.
            if action.keepsOverlayOpen {
                commitTextInput()
                onScrollCopyCurrent?(annotationsForExport)
            } else {
                commitTextInput()
                onScrollAction?(action)
            }
            return
        }

        if action.keepsOverlayOpen {
            commitTextInput()
            onCopyKeeping?(rect, annotationsForExport)
            return
        }

        commitTextInput()
        onConfirm?(rect, annotationsForExport, action)
    }

    // MARK: - Window hit testing

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Tear down the inline field (and its local key monitor) if the
        // overlay is closed while the user is still editing, plus any open
        // emoji grid.
        if window == nil {
            cancelToolbarReveal()
            finishSizeEditing()
            removeTextInput()
            dismissStickerPicker()
            return
        }
        if mode == .multiWindow { refreshCandidateWindows() }
        if windowConfirmationOnly {
            // The view only has a real window (and screenFrame) after init.
            refreshCandidateWindows()
            if let window {
                let local = convert(
                    window.convertPoint(fromScreen: NSEvent.mouseLocation),
                    from: nil
                )
                hoverPoint = local
                hoveredPick = pickWindowUnderPoint(local).pick
                layoutSelection()
            }
        }
    }

    private func refreshCandidateWindowsIfStale() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastWindowRefresh > 0.25 else { return }
        refreshCandidateWindows()
    }

    /// CGWindowList needs no screen-recording permission for bounds and window
    /// ids, so multi-window hover and the single-click window hit test work
    /// even before the screen-recording grant.
    ///
    /// The list is handed to the picker **unfiltered by layer**, exactly like
    /// iShot's `getImageWindowUnderMouse`: layered tool windows are capturable,
    /// and hiding them here is what made single-click pick nothing over real
    /// apps. The picker owns the per-window decision and reports why each window
    /// lost, which `pickWindowImmediately` logs.
    private func refreshCandidateWindows() {
        lastWindowRefresh = ProcessInfo.processInfo.systemUptime
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        var result: [CandidateWindow] = []
        var pickCandidates: [WindowCandidate] = []
        var menubarHeights: Set<Int> = []

        for info in raw {
            guard
                let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                let quartz = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
            else { continue }

            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            let windowName = info[kCGWindowName as String] as? String ?? ""

            // iShot's pass 1: the real menu bar heights.
            if layer == 24, windowName == "Menubar",
               owner == "Window Server" || owner == "WindowServer" {
                menubarHeights.insert(Int(quartz.height.rounded()))
            }

            // Quartz window bounds are top-left global; this view is
            // bottom-left local to its screen.
            let local = CGRect(
                x: quartz.minX - screenFrame.minX,
                y: primaryHeight - quartz.maxY - screenFrame.minY,
                width: quartz.width,
                height: quartz.height
            )
            guard local.intersects(bounds) else { continue }

            let clipped = local.intersection(bounds)
            pickCandidates.append(WindowCandidate(
                windowNumber: Int(windowID),
                bounds: local,
                layer: layer,
                ownerPID: ownerPID,
                ownerName: owner,
                windowName: windowName,
                isOwnedBySelf: ownerPID == ownPID
            ))

            // The highlight/snap list keeps only what iShot would actually
            // capture as "a window": no menu bar, no cursor mirror, no helper
            // overlay, no speck-sized chrome.
            guard layer >= 0, layer != 24, layer != 25,
                  !owner.isEmpty,
                  !WindowPicker.isSystemOverlay(ownerName: owner),
                  ownerPID != ownPID,
                  quartz.width >= SelectionBorderView.minimumSide,
                  quartz.height >= SelectionBorderView.minimumSide
            else { continue }
            result.append(CandidateWindow(
                id: windowID,
                frame: clipped,
                owner: owner,
                title: windowName
            ))
        }

        candidateWindows = result
        windowPickCandidates = pickCandidates
        windowPickMenubarHeights = menubarHeights
        windowPickScreenHeight = screenFrame.height
        snapTargets = result.map(\.frame) + [bounds]
        if mode == .multiWindow || !selectedWindowIDs.isEmpty {
            // Windows close while the overlay is up; a stale id would be
            // impossible to capture later.
            selectedWindowIDs.formIntersection(Set(result.map(\.id)))
            updateWindowHighlights()
        }
    }

    /// The content probe for the overlay's screen-local candidate space.
    ///
    /// `WindowPicker` measures in global AppKit points (that is the space
    /// `CGWindowListCreateImage` bounds belong to), so the candidate is lifted
    /// back to global, probed, and the answer shifted into this view's space.
    private func contentProbe(for candidate: WindowCandidate) -> WindowContentProbe {
        let global = WindowCandidate(
            windowNumber: candidate.windowNumber,
            bounds: candidate.bounds.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY),
            layer: candidate.layer,
            ownerPID: candidate.ownerPID,
            ownerName: candidate.ownerName,
            windowName: candidate.windowName,
            isOwnedBySelf: candidate.isOwnedBySelf
        )
        switch ScreenCapture.windowContentProbe(for: global) {
        case .unavailable: return .unavailable
        case .empty: return .empty
        case .content(let rect):
            return .content(rect.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY))
        }
    }

    /// One pick at `point` in this view's coordinates, with the debug ledger.
    private func pickWindowUnderPoint(_ point: CGPoint) -> WindowPickOutcome {
        WindowPicker.pick(
            at: point,
            candidates: windowPickCandidates,
            ownPID: ProcessInfo.processInfo.processIdentifier,
            ownCapturableWindowNumbers: OwnWindowCapture.capturableWindowNumbers,
            screenHeight: windowPickScreenHeight,
            menubarHeights: windowPickMenubarHeights,
            probe: { [weak self] candidate in
                self?.contentProbe(for: candidate) ?? .unavailable
            }
        )
    }

    private func candidateWindow(at point: CGPoint) -> CandidateWindow? {
        candidateWindows.first { $0.frame.contains(point) }
    }

    // MARK: - Multi-window selection

    /// Shift-click in the region overlay: add/remove one window without
    /// leaving the overlay, exactly like iShot's multi-window modifier.
    private func toggleRegionWindow(_ window: WindowCandidate) {
        let selected: Bool
        if selectedWindowIDs.contains(CGWindowID(window.windowNumber)) {
            selectedWindowIDs.remove(CGWindowID(window.windowNumber))
            selected = false
        } else {
            selectedWindowIDs.insert(CGWindowID(window.windowNumber))
            selected = true
        }
        hoveredWindowID = nil
        updateWindowHighlights()
        layoutSelection()
        onWindowToggled?(CGWindowID(window.windowNumber), window.bounds, selected)
        DebugLog.log(
            "window-pick: shift \(selected ? "added" : "removed") window "
            + "\(window.windowNumber), set=\(selectedWindowIDs.count)"
        )
    }

    private func toggleWindow(_ window: CandidateWindow) {
        let selected: Bool
        if selectedWindowIDs.contains(window.id) {
            selectedWindowIDs.remove(window.id)
            selected = false
        } else {
            selectedWindowIDs.insert(window.id)
            selected = true
        }
        updateWindowHighlights()
        onWindowToggled?(window.id, window.frame, selected)
    }

    private func updateMultiWindowHover(at point: CGPoint) {
        let id = candidateWindow(at: point)?.id
        guard id != hoveredWindowID else { return }
        hoveredWindowID = id
        updateWindowHighlights()
    }

    private func updateWindowHighlights() {
        if mode != .multiWindow, selectedWindowIDs.isEmpty {
            windowHighlight.entries = []
            windowHighlight.hint = ""
            windowHighlight.hintAnchor = nil
            windowHighlight.isHidden = true
            return
        }
        // `windowPickCandidates` is the shared stack (global-pick data in local
        // coordinates); using it keeps the region Shift-set drawing even when
        // the multi-window render cache has not been populated.
        windowHighlight.entries = windowPickCandidates.map { window in
            let id = CGWindowID(window.windowNumber)
            return WindowHighlightView.Entry(
                frame: window.bounds,
                selected: selectedWindowIDs.contains(id),
                hovered: hoveredWindowID == id
            )
        }
        let count = selectedWindowIDs.count
        windowHighlight.hint = count == 0
            ? "点击窗口加入选择 · 回车合成 · Esc 取消"
            : "已选 \(count) 个窗口 · 回车合成 · Esc 取消"
        windowHighlight.hintAnchor = nil
        windowHighlight.isHidden = false
    }

    private func confirmMultiWindow() {
        // `windowPickCandidates` is the stack both modes share; using it keeps
        // the region Shift-set working even when `candidateWindows` (the
        // multi-window render list) was not refreshed.
        let selected = windowPickCandidates.compactMap { candidate -> (CGWindowID, CGRect)? in
            let id = CGWindowID(candidate.windowNumber)
            return selectedWindowIDs.contains(id) ? (id, candidate.bounds) : nil
        }
        guard !selected.isEmpty else {
            NSSound.beep()
            return
        }
        onWindowsConfirmed?(selected)
    }

    /// Called by the controller when another screen cleared the shared set.
    func clearWindowSelection() {
        guard mode == .multiWindow || !selectedWindowIDs.isEmpty else { return }
        selectedWindowIDs.removeAll()
        hoveredWindowID = nil
        updateWindowHighlights()
        layoutSelection()
    }

    // MARK: - Window picking

    /// Normal region capture resolves a single click to a window; OCR / scroll /
    /// recording / beautify / preset opt out so a stray click stays a no-op
    /// instead of silently changing what is being captured.
    private var allowsWindowPick: Bool {
        mode == .region && windowPickEnabled
    }

    /// Pure click-vs-drag rule, so the 4 pt threshold is verifiable without a
    /// window server. A click with no selection behind it and less than `slop`
    /// of travel is a single tap.
    static func isSingleTap(
        from origin: CGPoint,
        to point: CGPoint,
        hadSelection: Bool,
        slop: CGFloat = singleTapSlop
    ) -> Bool {
        guard !hadSelection else { return false }
        return isWindowPickTap(from: origin, to: point, slop: slop)
    }

    /// The click-vs-drag threshold on its own, with no "is there a selection?"
    /// veto.
    ///
    /// iShot's window pick is not conditioned on the overlay being empty: a
    /// click that does not travel still lands on the window under the pointer.
    /// Gating it on `hadSelection` was what made "single click captures the
    /// window" silently do nothing whenever a box was still on screen.
    static func isWindowPickTap(
        from origin: CGPoint,
        to point: CGPoint,
        slop: CGFloat = singleTapSlop
    ) -> Bool {
        hypot(point.x - origin.x, point.y - origin.y) < slop
    }

    /// Drop the armed highlight without touching the selection. Used by Esc,
    /// by a click somewhere else, and by the confirmation itself.
    private func clearArmedWindowPick() {
        guard armedWindowPick != nil else { return }
        armedWindowPick = nil
        layoutSelection()
    }

    /// Region overlay: one click arms a window, the second click on that same
    /// window captures it.
    ///
    /// `armedAtPress` is the armed window as it was when this click started:
    /// * same window → confirm and report it to the controller;
    /// * anything else (another window, the desktop) → cancel the armed state
    ///   and stay in normal region drawing. It deliberately does **not** arm
    ///   the new window, so "click anywhere twice" can never capture something
    ///   the user did not confirm twice.
    private func resolveWindowTap(at point: CGPoint, armedAtPress: WindowPick?) {
        // The confirmation (second click) must see the window's *current*
        // frame: its pixels are captured immediately after this, so the stack
        // is refreshed and the click is resolved again. ~1 ms; not the
        // perceived latency.
        if let armed = armedAtPress {
            // Recording: a window is just a rectangle source. The second click
            // keeps it armed and the user starts the stream explicitly, so a
            // double-click can never begin a recording by accident.
            if recordingMode {
                DebugLog.log(
                    "window-pick: recording keeps armed window "
                    + "\(armed.candidate.windowNumber); waiting for Return"
                )
                return
            }
            let outcome = pickWindowFresh(at: point)
            guard let target = outcome.pick,
                  target.candidate.windowNumber == armed.candidate.windowNumber else {
                // Clicked elsewhere: back to normal region drawing.
                clearArmedWindowPick()
                DebugLog.log(
                    "window-pick: dismissed armed window "
                    + "\(armed.candidate.windowNumber) — click landed elsewhere"
                )
                return
            }
            DebugLog.log(
                "window-pick: second tap confirms window \(target.candidate.windowNumber) "
                + "owner=\(target.candidate.ownerName) title=\(target.candidate.windowName) "
                + "rect=\(NSStringFromRect(target.rect))"
            )
            // A committed window accepts annotations (its rect drives the
            // canvas), so a second-click confirmation must not drop them. With
            // no drawings, keep the window-ID capture path and its exact window
            // pixels; with drawings, take the region path so they get baked in.
            let annotations = annotationsForExport
            let rect = target.rect
            clearArmedWindowPick()
            if annotations.isEmpty {
                onWindowPicked?(CGWindowID(target.candidate.windowNumber), rect)
            } else {
                onConfirm?(rect, annotations, .copyClosing)
            }
            return
        }

        // First click: the window under the pointer is already highlighted and
        // already on screen. Promoting that preview is both faster and more
        // honest than querying the stack again — the user clicked the window
        // they could see, and nothing has to be torn down and rebuilt.
        if let preview = hoveredPick,
           preview.rect.insetBy(dx: -1, dy: -1).contains(point) {
            armWindow(preview, at: point)
            return
        }

        let outcome = pickWindowFresh(at: point)
        guard let target = outcome.pick else {
            // Empty desktop with nothing armed: no capture and no state change.
            // The overlay stays open so the user can drag a region next.
            NSSound.beep()
            DebugLog.log(
                "window-pick: no window under \(NSStringFromPoint(point)) "
                + "(\(windowPickCandidates.count) candidates); overlay stays open"
            )
            return
        }
        armWindow(target, at: point)
    }

    /// Refresh the window stack, pick at `point`, and write the debug ledger.
    /// Production refreshes at click time: the overlay may have been up for a
    /// while and windows move/close underneath it.
    private func pickWindowFresh(at point: CGPoint) -> WindowPickOutcome {
        let startedAt = CFAbsoluteTimeGetCurrent()
        if window != nil, !usesInjectedWindowCandidates { refreshCandidateWindows() }
        let afterRefresh = CFAbsoluteTimeGetCurrent()
        let outcome = pickWindowUnderPoint(point)
        let afterPick = CFAbsoluteTimeGetCurrent()
        if Self.clickTimingEnabled {
            DebugLog.log(String(
                format: "timing: refresh %.1f ms, pick %.1f ms, candidates=%d",
                (afterRefresh - startedAt) * 1000,
                (afterPick - afterRefresh) * 1000,
                windowPickCandidates.count
            ))
        }
        for row in outcome.rows {
            DebugLog.log(
                "window-pick:   #\(row.windowNumber) "
                + "\(row.ownerName.isEmpty ? "?" : row.ownerName) "
                + "layer=\(row.layer) "
                + "bounds=\(NSStringFromRect(row.bounds)) "
                + "→ \(row.reject?.rawValue ?? "SELECTED")"
            )
        }
        return outcome
    }

    /// Make `target` the armed window and put its highlighted pixels on screen
    /// in this same event turn.
    private func armWindow(_ target: WindowPick, at point: CGPoint) {
        let armedAt = CFAbsoluteTimeGetCurrent()
        armedWindowPick = target
        hoverPoint = point
        if Self.clickTimingEnabled, let press = pressStartedAt {
            windowHighlight.armedPaintProbe = { paintedAt in
                DebugLog.log(String(
                    format: "timing: armed highlight visible %.1f ms after mouseDown "
                        + "(%.1f ms after mouseUp)",
                    (paintedAt - press) * 1000,
                    (paintedAt - armedAt) * 1000
                ))
            }
        }
        layoutSelection()
        // The hover pixels were already on screen, so this only promotes them
        // to "selected". Painting now (instead of waiting for the next display
        // pass) keeps that promotion inside the click's own frame.
        windowHighlight.displayIfNeeded()
        DebugLog.log(
            "window-pick: armed window \(target.candidate.windowNumber) "
            + "owner=\(target.candidate.ownerName) title=\(target.candidate.windowName) "
            + "layer=\(target.candidate.layer) rect=\(NSStringFromRect(target.rect)); "
            + "second click confirms"
        )
    }

    /// Resolve the window under `point` and report it **before** the controller
    /// hides the panels. The overlay's own panels are already filtered out by
    /// owner PID, and resolving first keeps the z-order the user clicked on.
    private func pickWindowImmediately(at point: CGPoint) {
        // Production refreshes the stack at click time: the overlay may have
        // been up for a while and windows move/close underneath it. Offscreen
        // tests inject candidates and have no window.
        if window != nil, !usesInjectedWindowCandidates { refreshCandidateWindows() }
        let outcome = pickWindowUnderPoint(point)
        for row in outcome.rows {
            DebugLog.log(
                "window-pick:   #\(row.windowNumber) "
                + "\(row.ownerName.isEmpty ? "?" : row.ownerName) "
                + "layer=\(row.layer) "
                + "bounds=\(NSStringFromRect(row.bounds)) "
                + "→ \(row.reject?.rawValue ?? "SELECTED")"
            )
        }
        guard let target = outcome.pick else {
            // Empty desktop: no capture and no state change. The overlay stays
            // open so the user can drag a region next.
            NSSound.beep()
            DebugLog.log(
                "window-pick: no window under \(NSStringFromPoint(point)) "
                + "(\(windowPickCandidates.count) candidates); overlay stays open"
            )
            return
        }
        DebugLog.log(
            "window-pick: single tap → window \(target.candidate.windowNumber) "
            + "owner=\(target.candidate.ownerName) "
            + "title=\(target.candidate.windowName) "
            + "layer=\(target.candidate.layer) "
            + "rect=\(NSStringFromRect(target.rect)) trimmed=\(target.trimmed)"
        )
        onWindowPicked?(CGWindowID(target.candidate.windowNumber), target.rect)
    }

    // MARK: - Self-test hooks

    var selectionRectForTesting: CGRect { selectionBorder.selectionRect }
    var isScrollActiveForTesting: Bool { isScrollActive }
    var scrollPhaseForTesting: ScrollPreviewPod.Phase { scrollPhase }
    var scrollPodFrameForTesting: CGRect { scrollPod.frame }
    var scrollPodForTesting: ScrollPreviewPod { scrollPod }
    var scrollPreviewVisibleForTesting: Bool { !scrollPod.isHidden }
    var scrollPodCardFrameForTesting: CGRect {
        scrollPod.frame.offsetBy(dx: 0, dy: 0).intersection(scrollPod.frame)
    }
    func beginScrollSessionForTesting() { beginScrollSession() }
    var scrollPointerIsOverToolbarForTesting: Bool { scrollPointerIsOverToolbar }
    var scrollToolbarScreenFrameForTesting: CGRect? { scrollToolbarScreenFrame }

    /// The ✕'s frame in screen coordinates, for the real-click and hit-test
    /// checks. `nil` when the toolbar is not on screen.
    var scrollCancelButtonScreenFrameForTesting: CGRect? {
        guard let window, !toolbar.isHidden else { return nil }
        guard let item = toolbar.buttonFramesForTesting()
            .first(where: { $0.action == .cancel })
        else { return nil }
        return window.convertToScreen(toolbar.convert(item.frame, to: nil))
    }

    // Live recording UI seams. `beginRecordingUI` is the production method the
    // controller calls when the user confirms 开始录制.
    func beginRecordingUIForTesting() { beginRecordingUI() }
    var isRecordingLiveForTesting: Bool { isRecordingLive }
    var recordingControlFrameForTesting: CGRect { recordingControlFrame }
    /// The veil's hole. Equal to the selection means the mask is still drawn.
    /// (`dimmingSelectionRectForTesting` is declared with the other window
    /// seams below.)
    var isSelectionBorderVisibleForTesting: Bool { !selectionBorder.isHidden }
    var isAnnotationCanvasHiddenForTesting: Bool { annotationCanvas.isHidden }
    var isLoupeHiddenForTesting: Bool { loupe.isHidden }
    var isCrosshairHiddenForTesting: Bool { crosshair.isHidden }
    var sizeIndicatorTextForTesting: String { indicator.text }

    var toolbarFrameForTesting: CGRect { toolbar.frame }
    var indicatorFrameForTesting: CGRect { indicator.frame }
    var isToolbarVisibleForTesting: Bool { !toolbar.isHidden }
    var isIndicatorVisibleForTesting: Bool { !indicator.isHidden }

    /// Button frames translated into overlay coordinates.
    func toolbarButtonFramesForTesting() -> [(action: CaptureToolbarAction, frame: CGRect)] {
        toolbar.buttonFramesForTesting().map { item in
            (
                item.action,
                item.frame.offsetBy(dx: toolbar.frame.minX, dy: toolbar.frame.minY)
            )
        }
    }

    /// Same code path as the arrow keys, without a synthetic key event.
    func nudgeSelectionForTesting(dx: CGFloat, dy: CGFloat) {
        nudgeSelection(dx: dx, dy: dy)
    }

    /// Drive the overlay from the offscreen render harness.
    func applySelectionForTesting(_ rect: CGRect) {
        selectionBorder.setSelection(rect)
        layoutSelection()
    }

    /// Skip iShot's 0.5 s toolbar delay. The live size-chip test needs the
    /// chrome on screen because the chip now travels with the plate.
    func revealToolbarForTesting() {
        cancelToolbarReveal()
        toolbarIsRevealed = true
        layoutSelection()
    }

    // MARK: - Capture-toolbar self-test hooks

    var isAuxRowVisibleForTesting: Bool { toolbar.isAuxRowVisibleForTesting }
    var toolbarRowOneFrameForTesting: CGRect {
        toolbar.rowOneFrameForTesting.offsetBy(dx: toolbar.frame.minX, dy: toolbar.frame.minY)
    }
    /// The left auxiliary group's visible extent, in overlay coordinates.
    var toolbarAuxFrameForTesting: CGRect {
        toolbar.auxGroupFrameForTesting.offsetBy(dx: toolbar.frame.minX, dy: toolbar.frame.minY)
    }
    var toolbarSizeChipFrameForTesting: CGRect {
        toolbar.sizeChipFrame.offsetBy(dx: toolbar.frame.minX, dy: toolbar.frame.minY)
    }
    var toolbarMoreFrameForTesting: CGRect {
        toolbar.moreButtonFrame.offsetBy(dx: toolbar.frame.minX, dy: toolbar.frame.minY)
    }
    var toolbarDragHandleFrameForTesting: CGRect {
        toolbar.dragHandleFrame.offsetBy(dx: toolbar.frame.minX, dy: toolbar.frame.minY)
    }
    var toolbarShadowChipFrameForTesting: CGRect {
        toolbar.shadowChipFrameForTesting.offsetBy(dx: toolbar.frame.minX, dy: toolbar.frame.minY)
    }
    var toolbarStepDownFrameForTesting: CGRect {
        toolbar.stepDownFrameForTesting.offsetBy(dx: toolbar.frame.minX, dy: toolbar.frame.minY)
    }
    var toolbarStepUpFrameForTesting: CGRect {
        toolbar.stepUpFrameForTesting.offsetBy(dx: toolbar.frame.minX, dy: toolbar.frame.minY)
    }
    var toolbarCrosshairSwitchFrameForTesting: CGRect {
        toolbar.crosshairSwitchFrameForTesting.offsetBy(
            dx: toolbar.frame.minX,
            dy: toolbar.frame.minY
        )
    }
    var toolbarSeparatorXsForTesting: [CGFloat] {
        toolbar.separatorXsForTesting.map { $0 + toolbar.frame.minX }
    }
    var toolbarShadowLevelForTesting: CaptureToolbarShadowLevel { toolbar.shadowLevelForTesting }
    var toolbarCrosshairSwitchOnForTesting: Bool { toolbar.isCrosshairOnForTesting }
    var toolbarUserOffsetForTesting: CGSize { toolbar.userOffsetForTesting }
    var toolbarMoreMenuTitlesForTesting: [String] { toolbar.moreMenuItemTitlesForTesting }

    func sizeStepForTesting(shrink: Bool, shift: Bool) {
        toolbar.performSizeStepForTesting(shrink: shrink, shift: shift)
    }

    /// The real click path for the size chip: a click lands on the toolbar
    /// (the chip is an overlay sibling with no hit of its own while idle) and
    /// the toolbar calls back into the overlay's one editing grammar.
    func tapSizeChipForTesting() { handleSizeChipTap() }

    func toggleCrosshairSwitchForTesting() {
        toolbar.performCrosshairToggleForTesting()
    }

    /// Self-test seam for the hover render: pin the pointer state on one icon.
    func setToolHoverForTesting(_ tool: AnnotationTool, hovering: Bool) {
        toolbar.setToolHoverForTesting(tool, hovering: hovering)
    }

    func selectShadowLevelForTesting(_ level: CaptureToolbarShadowLevel) {
        toolbar.performShadowSelectionForTesting(level)
    }

    func dragToolbarForTesting(by offset: CGSize) {
        toolbar.applyUserOffsetForTesting(offset)
    }

    @discardableResult
    func performMoreMenuForTesting(title: String) -> Bool {
        let handled = toolbar.performMoreMenuItemForTesting(title: title)
        if handled { layoutSelection() }
        return handled
    }

    var sizeChipAppearanceForTesting: String {
        indicator.chipStyle == .toolbar ? "toolbar" : "floating"
    }

    // MARK: - Editable size chip self-test hooks

    var isSizeEditingForTesting: Bool { sizeEditActive }
    var sizeEditFieldCountForTesting: Int { indicator.isEditing ? 2 : 0 }
    var sizeEditActiveFieldForTesting: Int { indicator.activeField }
    var sizeEditValuesForTesting: (width: String, height: String) {
        indicator.editingTextValues
    }
    var indicatorTextForTesting: String { indicator.text }

    /// The eight handle centres computed from the *current* selection; the
    /// drawing reads the same function, so this is what is on screen.
    var selectionHandleCentresForTesting: [CGPoint] {
        selectionBorder.handleCentres(for: selectionBorder.selectionRect).map(\.point)
    }

    func beginSizeEditingForTesting() { beginSizeEditing() }
    func setSizeEditValuesForTesting(width: String, height: String) {
        indicator.setEditingValuesForTesting(width: width, height: height)
    }
    func toggleSizeEditFieldForTesting() { toggleSizeEditField() }

    // MARK: - Annotation self-test hooks

    var currentToolForTesting: AnnotationTool { currentTool }
    var annotationCountForTesting: Int { annotationStore.annotations.count }
    var annotationsForTesting: [Annotation] { annotationStore.annotations }
    var canUndoForTesting: Bool { annotationStore.canUndo }
    var canRedoForTesting: Bool { annotationStore.canRedo }
    var isUndoEnabledForTesting: Bool { toolbar.canUndoForTesting }
    var isRedoEnabledForTesting: Bool { toolbar.canRedoForTesting }
    var annotationCanvasFrameForTesting: CGRect { annotationCanvas.frame }
    var isAnnotationCanvasVisibleForTesting: Bool { !annotationCanvas.isHidden }

    func selectToolForTesting(_ tool: AnnotationTool) {
        selectTool(tool)
        toolbar.setCurrentTool(tool)
    }

    func addAnnotationForTesting(_ annotation: Annotation) {
        annotationStore.add(annotation)
    }

    @discardableResult
    func undoForTesting() -> Bool { annotationStore.undo() }

    @discardableResult
    func redoForTesting() -> Bool { annotationStore.redo() }

    /// Tool button frames translated into overlay coordinates.
    var visibleToolCountForTesting: Int { toolbar.visibleToolCountForTesting }
    var visibleHistoryCountForTesting: Int { toolbar.visibleHistoryCountForTesting }

    func toolbarToolFramesForTesting() -> [(tool: AnnotationTool, frame: CGRect)] {
        toolbar.toolButtonFramesForTesting().map { item in
            (item.tool, item.frame.offsetBy(dx: toolbar.frame.minX, dy: toolbar.frame.minY))
        }
    }

    func toolbarHistoryFramesForTesting() -> [(isRedo: Bool, frame: CGRect)] {
        toolbar.historyButtonFramesForTesting().map { item in
            (item.isRedo, item.frame.offsetBy(dx: toolbar.frame.minX, dy: toolbar.frame.minY))
        }
    }

    // MARK: - Text / action self-test hooks

    var textInputFieldForTesting: NSTextField? { textInputField }
    var textInputAnchorForTesting: CGPoint? { textInputAnchor }
    var mosaicBaseImageForTesting: CGImage? { annotationCanvas.mosaicBaseImage }
    var mosaicImageScaleForTesting: CGSize { annotationCanvas.mosaicImageScale }

    func setTextInputValueForTesting(_ value: String) {
        textInputField?.stringValue = value
        layoutTextInputField()
    }

    /// Route a selector through the real `NSTextFieldDelegate` method so the
    /// self test exercises Enter/Escape, not a parallel test-only branch.
    @discardableResult
    func handleTextCommandForTesting(_ selector: Selector) -> Bool {
        guard let field = textInputField else { return false }
        return control(field, textView: NSTextView(frame: .zero), doCommandBy: selector)
    }

    func commitTextInputForTesting() { commitTextInput() }

    /// Drive the same action path the toolbar buttons use. `.copyKeeping` must
    /// not close or clear anything.
    func performToolbarActionForTesting(_ action: CaptureToolbarAction) {
        toolbarAction(action)
    }

    // MARK: - Click-placement self-test hooks

    var nextCounterValueForTesting: Int { annotationStore.nextCounterValue }
    var counterHighWaterForTesting: Int { annotationStore.counterHighWater }
    /// Set by a sticker-tool click; the picker is suppressed offscreen, so the
    /// test asserts the anchor and then drives the pick through the same path.
    var pendingStickerAnchorForTesting: CGPoint? { pendingStickerAnchor }

    /// Same code path as `StickerPickerController.onPick`: the emoji lands at
    /// the anchor the picker was opened at.
    @discardableResult
    func pickStickerForTesting(_ emoji: String) -> Bool {
        guard let anchor = pendingStickerAnchor else { return false }
        stickerPicker = nil
        pendingStickerAnchor = nil
        placeSticker(emoji, at: anchor)
        return true
    }

    // MARK: - Window-pick self-test hooks

    var isCrosshairVisibleForTesting: Bool { !crosshair.isHidden }
    /// Whether the crosshair is drawn *under* the selection's border and
    /// handles. AppKit paints later subviews on top, so this is the whole
    /// z-order contract the handles depend on.
    var isCrosshairBelowSelectionHandlesForTesting: Bool {
        guard let cross = subviews.firstIndex(of: crosshair),
              let border = subviews.firstIndex(of: selectionBorder)
        else { return false }
        return cross < border
    }
    /// Subview class names back-to-front, for diagnosing an ordering regression.
    var subviewOrderForTesting: [String] {
        subviews.map { String(describing: type(of: $0)) }
    }
    var crosshairPointForTesting: CGPoint? { crosshair.point }
    var isCrosshairFrozenForTesting: Bool { crosshair.isFrozen }
    var crosshairArmsForTesting: [(CGPoint, CGPoint)] {
        guard let point = crosshair.point else { return [] }
        return CrosshairView.segments(
            point: point,
            in: crosshair.bounds,
            frozenRect: crosshair.frozenRect
        )
    }
    var crosshairExclusionRectsForTesting: [CGRect] { crosshair.exclusionRects }
    var isLoupeEnabledForTesting: Bool { showLoupe }
    var isLoupeVisibleForTesting: Bool { !loupe.isHidden }
    var loupePointForTesting: CGPoint? { loupe.point }
    var loupeFrameForTesting: CGRect {
        guard let point = loupe.point else { return .zero }
        return LoupeView.cardRect(for: point, in: bounds)
    }
    var loupeSourceRectForTesting: CGRect {
        guard let point = loupe.point else { return .zero }
        return loupe.sourceRect(for: point, in: bounds)
    }
    /// Offscreen renders have no snapshot; inject a synthetic one so the
    /// magnifier's geometry and pixels can be asserted.
    func setLoupeImageForTesting(_ image: CGImage?, scale: CGSize) {
        loupe.magnifiedImage = image
        loupe.imageScale = scale
        updateLoupe(at: lastPointerPoint)
    }
    /// Force the freeze without a synthetic drag, for the offscreen renders.
    func freezeCrosshairForTesting(at point: CGPoint, for rect: CGRect) {
        freezeCrosshair(for: rect, releasedAt: point)
    }
    var scrollProgressRatioForTesting: CGFloat { scrollProgressRatio }
    func updateScrollProgressForTesting(_ preview: ScrollPreviewFrame?) {
        updateScrollProgress(preview)
    }
    var scrollPodDrawnSizeForTesting: CGSize { scrollPod.drawnCardSize }
    var scrollPodScaleForTesting: CGFloat { scrollPod.scale }
    var scrollPodCardRectForTesting: CGRect { scrollPod.cardRect }
    var scrollPodIsFrozenForTesting: Bool { scrollPod.isFrozen }
    var dimmingHoleCornerRadiusForTesting: CGFloat { dimming.holeCornerRadius }
    var dimmingDimAlphaForTesting: CGFloat { dimming.dimAlpha }
    func dimmingCoversForTesting(_ point: CGPoint) -> Bool { dimming.covers(point) }
    var isWindowHighlightVisibleForTesting: Bool { !windowHighlight.isHidden }
    /// The rectangle the commit paths (Return / toolbar) would use right now.
    var committedRectForTesting: CGRect? { committedRect }
    /// The window armed by the first click, if any (region overlay only).
    var armedWindowIDForTesting: CGWindowID? {
        armedWindowPick.map { CGWindowID($0.candidate.windowNumber) }
    }
    var armedWindowFrameForTesting: CGRect? { armedWindowPick?.rect }
    var hoveredWindowIDForTesting: CGWindowID? {
        hoveredPick.map { CGWindowID($0.candidate.windowNumber) }
    }
    var windowHoverHintForTesting: String { windowHighlight.hint }
    var windowHoverFramesForTesting: [CGRect] { windowHighlight.entries.map(\.frame) }
    var dimmingSelectionRectForTesting: CGRect { dimming.selectionRect }
    var isToolbarSuppressedForTesting: Bool { toolbarSuppressed }
    var isWindowConfirmationModeForTesting: Bool { windowConfirmationOnly }
    var lockedAspectForTesting: CGFloat? { lockedAspect }
    var highlighterOpacityForTesting: CGFloat { style(for: .highlighter).opacity }
    var selectedWindowIDsForTesting: [CGWindowID] {
        selectedWindowIDs.sorted { $0 < $1 }
    }
    var lastAnnotationColorForTesting: NSColor? {
        annotationStore.annotations.last?.color
    }
    var lastAnnotationFontSizeForTesting: CGFloat? {
        annotationStore.annotations.last?.fontSize
    }
    var lastAnnotationLineWidthForTesting: CGFloat? {
        annotationStore.annotations.last?.lineWidth
    }
    func setStyleForTesting(_ style: AnnotationStyle, for tool: AnnotationTool) {
        setStyle(style, for: tool)
    }

    /// Feed the picker a synthetic window stack in view coordinates. Production
    /// builds the same values from `CGWindowListCopyWindowInfo`.
    func setWindowPickCandidatesForTesting(_ candidates: [WindowCandidate]) {
        windowPickCandidates = candidates
        snapTargets = candidates.map(\.bounds) + [bounds]
        usesInjectedWindowCandidates = true
    }

}

/// Crosshair lines through the cursor. Isolated so the root view has no
/// drawing of its own to speak of.
///
/// Two states:
///
/// * **tracking** — the classic cross with a gap around the pointer, following
///   the mouse while the user hunts for a region;
/// * **frozen** — after the mouse is released on a finished selection the cross
///   is pinned to the corner the drag ended on and becomes **two full-screen
///   lines**: one vertical through that corner's `x`, one horizontal through
///   its `y`. Because the corner is a real corner of the selection, those lines
///   lie exactly on the selection's two edges *and* continue through it. The
///   old frozen state drew only the two arms that pointed away from the box, so
///   the segments inside the selection were missing — the "缺了一部分" the owner
///   reported. A coordinate readout is either the whole line or nothing.
///
/// Both states draw a dark halo under a light core. The core is 1.2 pt — a
/// step above the original 1 pt hairline so it cannot be mistaken for a seam,
/// and a clear step down from the 1.8 pt the owner found too heavy. The halo is
/// 2.8 pt: it keeps the line visible over a light document, a dark terminal and
/// a photo alike, without the thick black edging that made the stroke read as a
/// 4 pt bar. Measured offscreen, the ink spans 6 device pixels at 2× (2 px white
/// core inside a 2 px dark shoulder on each side) instead of the old 8 px with
/// a 4 px core.
final class CrosshairView: NSView {
    /// White core width, in points.
    static let coreWidth: CGFloat = 1.2
    /// Black halo width under the core, in points.
    static let haloWidth: CGFloat = 2.8

    var point: CGPoint? {
        didSet {
            guard point != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Non-nil while the cross is pinned to a finished selection.
    var frozenRect: CGRect? {
        didSet {
            guard frozenRect != oldValue else { return }
            needsDisplay = true
        }
    }

    var isFrozen: Bool { frozenRect != nil }

    /// Rects the stroke must not paint over, in this view's coordinates. The
    /// overlay fills these with the toolbar / size chip / viewfinder frames,
    /// which are translucent glass above the cross: without the clip the frozen
    /// line reads straight through the plate.
    var exclusionRects: [CGRect] = [] {
        didSet {
            guard exclusionRects != oldValue else { return }
            needsDisplay = true
        }
    }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The segments drawn for a given state, in this view's coordinates.
    /// Exposed so the self test can assert the frozen lines sit *on* the
    /// selection's edges and reach both screen edges, instead of trusting the
    /// rendered pixels.
    ///
    /// Frozen: exactly two segments spanning the whole view. Tracking: four
    /// short arms with a gap around the pointer, so the cursor stays visible
    /// while hunting.
    static func segments(
        point: CGPoint,
        in bounds: CGRect,
        frozenRect: CGRect?,
        gap: CGFloat = 5
    ) -> [(CGPoint, CGPoint)] {
        guard let rect = frozenRect, rect.width >= 1, rect.height >= 1 else {
            return [
                (CGPoint(x: bounds.minX, y: point.y), CGPoint(x: point.x - gap, y: point.y)),
                (CGPoint(x: point.x + gap, y: point.y), CGPoint(x: bounds.maxX, y: point.y)),
                (CGPoint(x: point.x, y: bounds.minY), CGPoint(x: point.x, y: point.y - gap)),
                (CGPoint(x: point.x, y: point.y + gap), CGPoint(x: point.x, y: bounds.maxY))
            ]
        }
        // Which corner was the release point on? The nearest one — snap / ratio
        // lock can leave the raw pointer a few points away from the final edge.
        let goesRight = abs(point.x - rect.maxX) <= abs(point.x - rect.minX)
        let goesDown = abs(point.y - rect.minY) <= abs(point.y - rect.maxY)
        let corner = CGPoint(
            x: goesRight ? rect.maxX : rect.minX,
            y: goesDown ? rect.minY : rect.maxY
        )
        // Two lines through the corner, each spanning the screen. The corner is
        // on both the selection's vertical edge and its horizontal edge, so
        // these coincide with those edges by construction.
        return [
            (
                CGPoint(x: corner.x, y: bounds.minY),
                CGPoint(x: corner.x, y: bounds.maxY)
            ),
            (
                CGPoint(x: bounds.minX, y: corner.y),
                CGPoint(x: bounds.maxX, y: corner.y)
            )
        ]
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let point else { return }
        NSGraphicsContext.current?.shouldAntialias = true

        let path = NSBezierPath()
        for (start, end) in Self.segments(point: point, in: bounds, frozenRect: frozenRect) {
            path.move(to: start)
            path.line(to: end)
        }
        path.lineCapStyle = .butt

        NSGraphicsContext.saveGraphicsState()
        // Even-odd clip: the bounds minus every exclusion rect. AppKit treats
        // the full-view rect as the outer region and each chrome rect as a hole.
        if !exclusionRects.isEmpty {
            let clip = NSBezierPath(rect: bounds)
            for rect in exclusionRects where rect.width > 0 && rect.height > 0 {
                clip.append(NSBezierPath(rect: rect))
            }
            clip.windingRule = .evenOdd
            clip.addClip()
        }

        NSColor.black.withAlphaComponent(isFrozen ? 0.36 : 0.34).setStroke()
        path.lineWidth = Self.haloWidth
        path.stroke()
        NSColor.white.withAlphaComponent(isFrozen ? 0.90 : 0.78).setStroke()
        path.lineWidth = Self.coreWidth
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}

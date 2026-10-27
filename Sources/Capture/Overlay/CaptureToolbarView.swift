import AppKit
import SwiftUI

/// The eight capture actions. Annotation tools have their own enum
/// (`AnnotationTool`) and live to the left of these in the toolbar.
///
/// Copy is deliberately split into two buttons: "keep" writes the pasteboard
/// and leaves the overlay open for more edits, "close" is the classic
/// one-shot action. Save is split the same way into the settings directory and
/// an explicit `NSSavePanel`. OCR sits next to pin: same "produce content from
/// the pixels" family, before the destructive cancel.
///
/// The strip shows copy-keep / copy-close / save / OCR as glyphs and keeps pin
/// and cancel in the pinned tail; 另存为 is the one uncommon action and moves
/// into the ⋯ menu. Every case stays reachable through `onAction`, so the
/// keyboard paths (Return = copy-close) and the action enum itself are
/// untouched.
enum CaptureToolbarAction: String, CaseIterable {
    case copyKeeping
    case copyClosing
    case save
    case saveAs
    case pin
    case ocr
    case cancel
    /// Region recording only: confirm the box and start the stream. Hidden
    /// from every screenshot / scroll / OCR toolbar; it is not a delivery
    /// action and never closes a capture.
    case record

    var symbol: String {
        switch self {
        case .copyKeeping: "doc.on.doc"
        case .copyClosing: "doc.on.clipboard"
        case .save: "square.and.arrow.down"
        case .saveAs: "square.and.arrow.down.on.square"
        case .pin: "pin"
        case .ocr: "text.viewfinder"
        case .cancel: "xmark"
        case .record: "record.circle"
        }
    }

    var label: String {
        switch self {
        // iShot 的叫法：拷贝 / 拷贝后退出 / 保存 / 另存为… / 贴图 / OCR。
        case .copyKeeping: "拷贝"
        case .copyClosing: "拷贝后退出"
        case .save: "保存"
        case .saveAs: "另存为…"
        case .pin: "贴图"
        case .ocr: "OCR"
        case .cancel: "取消"
        case .record: "开始录制"
        }
    }

    /// Only "keep" is non-terminal: it never closes the overlay.
    var keepsOverlayOpen: Bool { self == .copyKeeping }

    /// Glyphs that stay on the strip. Pin and cancel are laid out separately as
    /// the pinned tail; 另存为 lives in the ⋯ menu. Recording has its own
    /// strip: copy/save/OCR/pin make no sense for a video, so a recording
    /// overlay shows exactly one delivery action — 开始录制.
    static let stripActions: [CaptureToolbarAction] = [
        .copyKeeping, .copyClosing, .save, .ocr
    ]
    /// The pinned tail, left to right: 更多 · 贴图 · 取消 · 拖拽手柄.
    static let tailActions: [CaptureToolbarAction] = [.pin, .cancel]
    /// The only action a region-recording overlay offers.
    static let recordingActions: [CaptureToolbarAction] = [.record]
}

/// The four export-shadow strengths the left auxiliary group offers. The names are the
/// menu's copy; the sizes are the same points `ScreenshotDecoration` consumes
/// through `AppSettings.captureShadowSize` (0–40), so choosing a level in the
/// overlay and moving the slider in 设置 → 截图 output are the same value.
enum CaptureToolbarShadowLevel: Int, CaseIterable {
    case none
    case light
    case medium
    case strong

    var title: String {
        switch self {
        case .none: "无阴影"
        case .light: "轻微"
        case .medium: "中等"
        case .strong: "明显"
        }
    }

    /// Points handed to `AppSettings.captureShadowSize`.
    var size: Double {
        switch self {
        case .none: 0
        case .light: 8
        case .medium: 16
        case .strong: 28
        }
    }

    var isEnabled: Bool { self != .none }

    /// Classify a stored (enabled, size) pair back into a menu choice. The
    /// defaults seed 12 pt with the toggle off, so an untouched install reads
    /// 无阴影; turning the toggle on in 设置 reads 轻微.
    static func level(enabled: Bool, size: Double) -> CaptureToolbarShadowLevel {
        guard enabled else { return .none }
        switch size {
        case ...12: return .light
        case ...22: return .medium
        default: return .strong
        }
    }
}

/// The floating one-row toolbar that follows the selection.
///
/// Left to right, on **one** rounded-rectangle plate:
///
///     [◀] [1242 × 479] [▶] │ [无阴影 ▾] │ [switch] │
///     [move arrow rect ellipse line pencil highlighter mosaic text note
///      counter sticker | palette | undo redo] │ [copy-keep copy-close save
///      OCR] │ [⋯ pin cancel ⠿]
///
/// The composition follows the pinned-image toolbar (`PinnedImageView`): one
/// solid/glass plate, bare glyphs at rest, a hover-only highlight on exactly
/// the control under the pointer (the shared `ToolbarInk` hover tier), and
/// hairlines between groups. The highlight is a **rounded square** (6 pt
/// continuous corner), not a disc: the pointer target reads like a small key,
/// which matches the square 26 pt hit boxes. The current annotation tool is
/// the single latched state and is drawn as a 1 pt rounded-square ring —
/// never a fill — so the plate carries no per-button chrome at rest.
///
/// The auxiliary controls used to be a separate 28 pt capsule underneath
/// (`◀ 尺寸 ▶ │ 阴影 ▾ │ 开关`). They now sit at the far left of the same
/// plate, vertically centred with the icons; there is no second row and no
/// row-gap animation. ⋯ can still hide the whole auxiliary group, which
/// returns the editable size chip to its historical floating position.
///
/// **The size chip is not duplicated.** The left group's chip *is* the
/// editable `SizeIndicatorView` from `dd090db`: the overlay positions that one
/// view inside the plate's reserved slot instead of floating it beside the
/// selection, so there is exactly one size readout and the existing
/// click-to-edit grammar, two fields, Return / Tab / Escape monitor and
/// centred-resize commit all stay in place. Hiding the auxiliary group with ⋯
/// returns the same view to its floating position (see
/// `CaptureOverlayView.layoutCommittedChrome`).
///
/// Glass: the single plate reuses `GlassSurfaceFactory.makeBackdrop` with the
/// same `.liquidGlass` recipe the two-row toolbar used (plus the wash and
/// `labelColor` hairline drawn below). No new material is introduced.
///
/// It owns only the toolbar: the buttons and its placement. It does not know
/// about the selection border or the annotation array; the overlay hands it a
/// selection and a screen rectangle and it answers with its own frame, and it
/// reports taps through callbacks. Clicks land on real subviews, so they never
/// fall through to the root and start a new selection drag.
@MainActor
final class CaptureToolbarView: NSView {
    // MARK: - Metrics

    /// 26 pt square hit boxes. The 2026-10-24 compact pass took the icons
    /// from 28 → 26, the item gap 8 → 6 and the group gap 10 → 8: the plate
    /// got 126 pt narrower while every glyph kept its 13 pt size, so the row
    /// reads tighter without the icons shrinking.
    static let buttonSize: CGFloat = 26
    static let gap: CGFloat = 6
    /// Extra space added at a group boundary, so the hairline has room.
    static let groupGap: CGFloat = 8
    static let horizontalPadding: CGFloat = 10
    /// One row: 26 pt icons with 4 pt of plate above and below.
    static let rowHeight: CGFloat = 34
    /// Fixed corner radius: a rounded rectangle, deliberately not `height / 2`
    /// (that would turn the 34 pt bar back into a capsule).
    static let cornerRadius: CGFloat = 12
    static let stepperSize: CGFloat = 20
    static let shadowChipWidth: CGFloat = 70
    static let switchSize = CGSize(width: 32, height: 17)
    /// The reserved width of the size chip before the overlay writes its own
    /// measured width (the editor is wider than the read-only label). Left at
    /// 76 because a large readout ("1242 × 479") measures that wide; shrinking
    /// it would either clip the chip or make the plate jitter per selection.
    static let defaultChipWidth: CGFloat = 76
    static let separatorHeight: CGFloat = 16

    /// Canonical single-row height. Kept as a static so every placement test
    /// reads the same number the view lays out.
    static var height: CGFloat { rowHeight }

    /// Canonical width with the auxiliary group visible, the default chip and
    /// every built-in tool. `preferredSize` uses the live chip width and the
    /// user's visible-tool count instead.
    static var width: CGFloat {
        contentWidth(
            chipWidth: defaultChipWidth,
            auxVisible: true,
            toolCount: AnnotationTool.allCases.count
        )
    }

    var preferredSize: NSSize {
        NSSize(
            width: Self.contentWidth(
                chipWidth: max(auxSizeChipSize.width, Self.defaultChipWidth),
                auxVisible: isAuxRowVisible,
                toolCount: AnnotationToolbarLayout.visibleTools.count,
                recording: isRecordingMode
            ),
            height: Self.rowHeight
        )
    }

    /// Width of the whole plate for one chip width / visibility / tool count.
    ///
    /// This is the single source of truth for both `preferredSize` and
    /// `layoutButtons`: the layout walks the same widths in the same order and
    /// adds `gap` between every pair of items plus `groupGap` at a boundary.
    static func contentWidth(
        chipWidth: CGFloat,
        auxVisible: Bool,
        toolCount: Int,
        recording: Bool = false
    ) -> CGFloat {
        var widths: [CGFloat] = []
        var groups = 0
        func addGroup(_ group: [CGFloat]) {
            guard !group.isEmpty else { return }
            groups += 1
            widths.append(contentsOf: group)
        }

        if auxVisible {
            addGroup([stepperSize, chipWidth, stepperSize])
            addGroup([shadowChipWidth])
            addGroup([switchSize.width])
        }
        // 12 tools + palette + undo + redo.
        // Recording replaces the capture strip and drops every annotation
        // tool: a box being recorded is not an annotation surface, and the
        // plate should not offer actions that would screenshot it instead.
        addGroup(Array(
            repeating: buttonSize,
            count: recording ? 0 : toolCount + 3
        ))
        addGroup(Array(repeating: buttonSize, count: recording
            ? CaptureToolbarAction.recordingActions.count
            : CaptureToolbarAction.stripActions.count))
        // ⋯ + pin + cancel + drag handle; a recording bar is 取消 + handle.
        addGroup(Array(
            repeating: buttonSize,
            count: recording ? 2 : CaptureToolbarAction.tailActions.count + 2
        ))

        let itemGaps = CGFloat(max(0, widths.count - 1)) * gap
        let groupGaps = CGFloat(max(0, groups - 1)) * groupGap
        return horizontalPadding * 2
        + widths.reduce(0, +)
        + itemGaps
        + groupGaps
    }

    // MARK: - Callbacks

    var onToolSelected: ((AnnotationTool) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onStyle: (() -> Void)?
    var onAction: ((CaptureToolbarAction) -> Void)?
    /// ±1 pt, or ±10 with Shift. The overlay owns the rectangle maths.
    var onStepSize: ((CGFloat) -> Void)?
    /// A click on the size chip (the editable `SizeIndicatorView` lives above
    /// this view but is laid out in the plate's reserved slot).
    var onSizeChipTap: (() -> Void)?
    var onShadowLevelChanged: ((CaptureToolbarShadowLevel) -> Void)?
    var onCrosshairToggled: ((Bool) -> Void)?
    /// The drag handle moved the toolbar; the overlay must re-run placement.
    var onUserMoved: (() -> Void)?
    /// The left auxiliary group was shown or hidden from ⋯; the overlay
    /// re-runs placement (and decides where the size chip lives).
    var onAuxRowVisibilityChanged: (() -> Void)?

    // MARK: - State

    private let rendersOffscreen: Bool
    private var toolButtons: [AnnotationTool: CaptureToolbarToolButton] = [:]
    private var actionButtons: [CaptureToolbarAction: CaptureToolbarButton] = [:]
    private var undoButton: CaptureToolbarHistoryButton!
    private var redoButton: CaptureToolbarHistoryButton!
    private var styleButton: CaptureToolbarIconButton!
    private var moreButton: CaptureToolbarIconButton!
    private var dragHandle: CaptureToolbarDragHandleButton!

    private var stepDownButton: CaptureToolbarIconButton!
    private var stepUpButton: CaptureToolbarIconButton!
    private var shadowChip: CaptureToolbarMenuChip!
    private var crosshairSwitch: CaptureToolbarToggleSwitch!

    /// The one plate: either `NSGlassEffectView` (macOS 26) or the pre-26
    /// flat-tint view. Wrapped in a pass-through host so clicks in the
    /// toolbar's gaps still reach the toolbar (which needs them for the size
    /// chip).
    private var plateBackdrop: NSView?
    private var usesGlassBackdrop = false
    private var usesOpaqueBackdrop = false

    /// Every group boundary's hairline, in this view's coordinates.
    private var separatorXs: [CGFloat] = []
    private(set) var plateRect: CGRect = .zero

    private(set) var currentTool: AnnotationTool = .move
    private var canUndo = false
    private var canRedo = false

    /// The size the auxiliary chip slot reserves. The overlay writes the
    /// indicator's `preferredSize` here (it grows into the two-field editor).
    var auxSizeChipSize = CGSize(width: 76, height: 22) {
        didSet {
            guard auxSizeChipSize != oldValue else { return }
            needsLayout = true
            needsDisplay = true
        }
    }

    /// Reserved chip rect in this view's coordinates (filled by `layout`).
    private(set) var sizeChipFrame: CGRect = .zero

    /// User drag offset, applied on top of the default placement.
    private(set) var userOffset: CGSize = .zero
    private var dragBaseOffset: CGSize = .zero

    /// The left auxiliary group's persisted visibility. Defaults to visible.
    /// ⋯ can hide it for a compact capture; the plate stays one row and the
    /// size chip returns to its floating position.
    static let auxRowVisibleDefaultsKey = "captureToolbarAuxRowVisible"
    private(set) var isAuxRowVisible: Bool
    /// Self-test seam: pin the initial visibility without reading or writing
    /// the user's own preference.
    nonisolated(unsafe) static var auxRowVisibleOverrideForTesting: Bool?

    private(set) var shadowLevel: CaptureToolbarShadowLevel = .none
    private(set) var isCrosshairOn = true
    /// Region-recording overlay: one 开始录制 action, no annotation tools and
    /// no copy/save/OCR/pin. Set once before the first layout.
    var isRecordingMode = false {
        didSet {
            guard isRecordingMode != oldValue else { return }
            // A recording box is not an annotation surface and its shadow /
            // crosshair switches are screenshot preferences. Fold the
            // auxiliary row away (without touching the stored preference) so
            // the floating size chip keeps measuring the box.
            if isRecordingMode { setAuxRowVisible(false, persist: false) }
            for button in toolButtons.values { button.isHidden = isRecordingMode }
            styleButton.isHidden = isRecordingMode
            undoButton.isHidden = isRecordingMode
            redoButton.isHidden = isRecordingMode
            moreButton.isHidden = isRecordingMode
            needsLayout = true
            needsDisplay = true
        }
    }

    // MARK: - Init

    init(offscreen: Bool) {
        self.rendersOffscreen = offscreen
        self.isAuxRowVisible = Self.auxRowVisibleOverrideForTesting
            ?? (UserDefaults.standard.object(forKey: Self.auxRowVisibleDefaultsKey) as? Bool ?? true)
        super.init(frame: NSRect(origin: .zero, size: NSSize(
            width: Self.width,
            height: Self.rowHeight
        )))
        wantsLayer = true

        for tool in AnnotationToolbarLayout.visibleTools {
            let button = CaptureToolbarToolButton(tool: tool)
            button.onTap = { [weak self] in
                self?.setCurrentTool(tool)
                self?.onToolSelected?(tool)
            }
            addSubview(button)
            toolButtons[tool] = button
        }

        styleButton = CaptureToolbarIconButton(symbolName: "paintpalette", label: "标注样式")
        styleButton.onTap = { [weak self] in self?.onStyle?() }
        addSubview(styleButton)

        undoButton = CaptureToolbarHistoryButton(isRedo: false)
        undoButton.onTap = { [weak self] in self?.onUndo?() }
        addSubview(undoButton)

        redoButton = CaptureToolbarHistoryButton(isRedo: true)
        redoButton.onTap = { [weak self] in self?.onRedo?() }
        addSubview(redoButton)

        for action in CaptureToolbarAction.stripActions + [.record] {
            let button = CaptureToolbarButton(action: action)
            button.onTap = { [weak self] in self?.onAction?(action) }
            button.isHidden = action == .record
            addSubview(button)
            actionButtons[action] = button
        }

        // The pinned tail: 更多 · 贴图 · 取消 · 拖拽手柄. Pin and cancel keep
        // their `CaptureToolbarButton` identity so their ids, hit tests and
        // callbacks are the same objects the strip always had.
        moreButton = CaptureToolbarIconButton(symbolName: "ellipsis", label: "更多")
        moreButton.onTap = { [weak self] in self?.presentMoreMenu() }
        addSubview(moreButton)

        for action in CaptureToolbarAction.tailActions {
            let button = CaptureToolbarButton(action: action)
            button.onTap = { [weak self] in self?.onAction?(action) }
            addSubview(button)
            actionButtons[action] = button
        }

        dragHandle = CaptureToolbarDragHandleButton()
        dragHandle.onDragBegan = { [weak self] in
            self?.dragBaseOffset = self?.userOffset ?? .zero
        }
        dragHandle.onDrag = { [weak self] delta in
            guard let self else { return }
            self.userOffset = CGSize(
                width: self.dragBaseOffset.width + delta.width,
                height: self.dragBaseOffset.height + delta.height
            )
            self.onUserMoved?()
        }
        addSubview(dragHandle)

        // The left auxiliary group lives on the same plate as the icons now.
        // The size chip itself is an overlay sibling placed in the reserved
        // slot; only its steppers and the two preference controls are subviews.
        stepDownButton = CaptureToolbarIconButton(
            symbolName: "chevron.left",
            label: "尺寸减小",
            symbolPointSize: 11
        )
        stepDownButton.onTap = { [weak self] in
            self?.onStepSize?(-CaptureToolbarView.sizeStep())
        }
        addSubview(stepDownButton)

        stepUpButton = CaptureToolbarIconButton(
            symbolName: "chevron.right",
            label: "尺寸增大",
            symbolPointSize: 11
        )
        stepUpButton.onTap = { [weak self] in
            self?.onStepSize?(CaptureToolbarView.sizeStep())
        }
        addSubview(stepUpButton)

        shadowChip = CaptureToolbarMenuChip(title: shadowLevel.title, label: "导出阴影")
        shadowChip.onTap = { [weak self] in self?.presentShadowMenu() }
        addSubview(shadowChip)

        crosshairSwitch = CaptureToolbarToggleSwitch(label: "显示十字线")
        crosshairSwitch.onToggle = { [weak self] on in
            guard let self else { return }
            self.isCrosshairOn = on
            self.onCrosshairToggled?(on)
        }
        addSubview(crosshairSwitch)
        setAuxControlsHidden(!isAuxRowVisible)

        setCurrentTool(.move)
        setHistoryState(canUndo: false, canRedo: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Shift means a ten-point step (the same convention arrow-key nudging
    /// uses); everything else is one point.
    private static func sizeStep() -> CGFloat {
        NSEvent.modifierFlags.contains(.shift) ? 10 : 1
    }

    // MARK: - State

    func setCurrentTool(_ tool: AnnotationTool) {
        currentTool = tool
        for (candidate, button) in toolButtons {
            button.isSelected = candidate == tool
        }
    }

    func setHistoryState(canUndo: Bool, canRedo: Bool) {
        self.canUndo = canUndo
        self.canRedo = canRedo
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
    }

    var canUndoForTesting: Bool { canUndo }
    var canRedoForTesting: Bool { canRedo }

    func setShadowLevel(_ level: CaptureToolbarShadowLevel) {
        guard level != shadowLevel else { return }
        shadowLevel = level
        shadowChip.title = level.title
        needsLayout = true
        needsDisplay = true
    }

    func setCrosshairOn(_ on: Bool) {
        guard on != isCrosshairOn else { return }
        isCrosshairOn = on
        crosshairSwitch.isOn = on
    }

    /// Hide/show the left auxiliary group. Dispatched from the ⋯ menu;
    /// persisted across captures in the app's own defaults (not `AppSettings`:
    /// this is chrome, not a capture preference, and it must not appear in the
    /// settings pages). The plate never changes height — only its width and
    /// which controls the left edge starts with.
    func setAuxRowVisible(_ visible: Bool, persist: Bool = true) {
        guard visible != isAuxRowVisible else { return }
        isAuxRowVisible = visible
        if persist {
            UserDefaults.standard.set(visible, forKey: Self.auxRowVisibleDefaultsKey)
        }
        setAuxControlsHidden(!visible)
        needsLayout = true
        needsDisplay = true
        onAuxRowVisibilityChanged?()
    }

    /// The controls that belong to the left auxiliary group. The size chip is
    /// the overlay's sibling; it is hidden by the overlay when the group is
    /// off (it returns to its floating position instead).
    private func setAuxControlsHidden(_ hidden: Bool) {
        for view in [stepDownButton, stepUpButton, shadowChip, crosshairSwitch] {
            view?.isHidden = hidden
        }
    }

    /// Forget a drag-handle move. Called when the chrome disappears so a fresh
    /// selection starts at the default position again.
    func resetUserOffset() {
        guard userOffset != .zero else { return }
        userOffset = .zero
        needsDisplay = true
    }

    // MARK: - Test hooks

    /// Self-test hook: every action's frame in this view's coordinates.
    func buttonFramesForTesting() -> [(action: CaptureToolbarAction, frame: CGRect)] {
        actionButtons.compactMap { action, button in
            button.isHidden ? nil : (action, button.frame)
        }
        .sorted { $0.1.minX < $1.1.minX }
    }

    /// Recording mode folds the drawing tools away; this is the only way to
    /// tell "laid out" from "still a subview at a stale frame".
    var visibleToolCountForTesting: Int {
        AnnotationToolbarLayout.visibleTools.filter {
            toolButtons[$0]?.isHidden == false
        }.count
    }

    var visibleHistoryCountForTesting: Int {
        [undoButton, redoButton].filter { $0?.isHidden == false }.count
    }

    func toolButtonFramesForTesting() -> [(tool: AnnotationTool, frame: CGRect)] {
        AnnotationToolbarLayout.visibleTools.compactMap { tool in
            toolButtons[tool].map { (tool, $0.frame) }
        }
    }

    func historyButtonFramesForTesting() -> [(isRedo: Bool, frame: CGRect)] {
        [(false, undoButton.frame), (true, redoButton.frame)]
    }

    /// Anchor for the annotation style popover.
    var styleButtonFrame: CGRect? {
        styleButton.map { $0.frame }
    }

    var moreButtonFrame: CGRect { moreButton.frame }
    var dragHandleFrame: CGRect { dragHandle.frame }
    /// The whole plate is the single row now.
    var rowOneFrameForTesting: CGRect { plateRect }
    var stepDownFrameForTesting: CGRect { stepDownButton.frame }
    var stepUpFrameForTesting: CGRect { stepUpButton.frame }
    var shadowChipFrameForTesting: CGRect { shadowChip.frame }
    var crosshairSwitchFrameForTesting: CGRect { crosshairSwitch.frame }
    var separatorXsForTesting: [CGFloat] { separatorXs }
    var isAuxRowVisibleForTesting: Bool { isAuxRowVisible }
    var userOffsetForTesting: CGSize { userOffset }
    var shadowLevelForTesting: CaptureToolbarShadowLevel { shadowLevel }
    var isCrosshairOnForTesting: Bool { crosshairSwitch.isOn }

    /// The visible extent of the left auxiliary group (steppers · chip ·
    /// shadow · switch) in this view's coordinates; `.zero` when hidden.
    var auxGroupFrameForTesting: CGRect {
        guard isAuxRowVisible else { return .zero }
        return stepDownButton.frame
            .union(stepUpButton.frame)
            .union(shadowChip.frame)
            .union(crosshairSwitch.frame)
            .union(sizeChipFrame)
    }

    func performSizeStepForTesting(shrink: Bool, shift: Bool) {
        let amount: CGFloat = shift ? 10 : 1
        onStepSize?(shrink ? -amount : amount)
    }

    func performCrosshairToggleForTesting() {
        crosshairSwitch.performToggleForTesting()
    }

    func performShadowSelectionForTesting(_ level: CaptureToolbarShadowLevel) {
        setShadowLevel(level)
        onShadowLevelChanged?(level)
    }

    func applyUserOffsetForTesting(_ offset: CGSize) {
        userOffset = offset
        onUserMoved?()
    }

    /// Self-test seam for the hover render: the pointer state cannot be driven
    /// through `NSTrackingArea` offscreen.
    func setToolHoverForTesting(_ tool: AnnotationTool, hovering: Bool) {
        toolButtons[tool]?.setHoverForTesting(hovering)
    }

    /// Drop every control's pointer state, as if the pointer had stepped off the
    /// plate.
    ///
    /// A scrolling session makes the capture panel click-through everywhere but
    /// the toolbar (the page has to keep the wheel), so the window can stop
    /// receiving pointer events while one of these controls is still marked
    /// hovered — AppKit never sends the `mouseExited` that would clear it. The
    /// controller calls this at exactly that transition, or the last glyph the
    /// pointer touched keeps its hover disc while the page scrolls.
    func clearPointerHover() {
        for button in toolButtons.values { button.setHover(false) }
        for button in actionButtons.values { button.setHover(false) }
        moreButton.setHover(false)
        dragHandle.setHover(false)
        stepDownButton.setHover(false)
        stepUpButton.setHover(false)
        shadowChip.clearPointerHover()
    }

    var moreMenuItemTitlesForTesting: [String] {
        MoreMenuItem.allCases.map { $0.title(auxVisible: isAuxRowVisible) }
    }

    @discardableResult
    func performMoreMenuItemForTesting(title: String) -> Bool {
        guard let item = MoreMenuItem.allCases.first(
            where: { $0.title(auxVisible: isAuxRowVisible) == title }
        ) else { return false }
        perform(item)
        return true
    }

    var backdropViewClassNameForTesting: String? {
        // The installed plate backdrop, not the pass-through host around it.
        plateBackdrop?.subviews.first.map { String(describing: type(of: $0)) }
    }

    /// The corner the glass factory clipped the plate to.
    var backdropCornerRadiusForTesting: CGFloat? {
        plateBackdrop?.subviews.first?.layer?.cornerRadius
    }

    // MARK: - Placement

    /// Default below the selection by 12 pt; flip above when the bottom of the
    /// screen is too close; otherwise clamp inside the screen. Horizontal
    /// centring uses the *selection* midpoint, not the screen midpoint. A drag
    /// from the handle is added on top of that default and is clamped too, so
    /// the toolbar can be moved but never lost off-screen.
    func placement(for selection: CGRect, screenBounds: CGRect) -> CGRect {
        let size = preferredSize
        let margin: CGFloat = 8
        let gap: CGFloat = 12

        var x = selection.midX - size.width / 2
        x = min(max(x, screenBounds.minX + margin), screenBounds.maxX - size.width - margin)

        var y = selection.minY - gap - size.height
        if y < screenBounds.minY + margin {
            let above = selection.maxY + gap
            if above + size.height <= screenBounds.maxY - margin {
                y = above
            }
        }
        y = min(max(y, screenBounds.minY + margin), screenBounds.maxY - size.height - margin)

        let shiftedX = x + userOffset.width
        let shiftedY = y + userOffset.height
        x = min(
            max(shiftedX, screenBounds.minX + margin),
            screenBounds.maxX - size.width - margin
        )
        y = min(
            max(shiftedY, screenBounds.minY + margin),
            screenBounds.maxY - size.height - margin
        )

        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    // MARK: - Glass

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateEffectViews()
    }

    override func layout() {
        super.layout()
        layoutPlate()
        layoutBackdrops()
    }

    private func layoutBackdrops() {
        plateBackdrop?.frame = plateRect
    }

    /// One item on the plate. The size chip is the only item without a view:
    /// the overlay hosts the editable `SizeIndicatorView` as a sibling and
    /// places it in the slot recorded here.
    private struct PlanItem {
        let view: NSView?
        let width: CGFloat
        let height: CGFloat
        let group: Group
        let isSizeChip: Bool
    }

    /// Lay out the single row: left auxiliary group │ tools │ actions │ tail.
    ///
    /// The widths come from the same `contentWidth` the placement uses, so the
    /// preferred size and the frames can never drift apart. Group boundaries
    /// get `gap + groupGap` and a centred hairline.
    private func layoutPlate() {
        separatorXs.removeAll()
        sizeChipFrame = .zero
        // The plate is one row tall and anchored at the top of the view, so a
        // caller that hands this view a taller frame (the style test does, to
        // keep a real window around the glass backdrop) still lays the row out
        // exactly as production does.
        plateRect = CGRect(
            x: 0,
            y: bounds.height - Self.rowHeight,
            width: bounds.width,
            height: Self.rowHeight
        )
        guard bounds.width > 0, bounds.height > 0 else { return }

        var plan: [PlanItem] = []
        if isAuxRowVisible, !isRecordingMode {
            plan.append(PlanItem(
                view: stepDownButton,
                width: Self.stepperSize,
                height: Self.stepperSize,
                group: .auxSize,
                isSizeChip: false
            ))
            // The chip breathes with the row: 22 pt read-only, 26 pt editor,
            // never taller than the 26 pt icons beside it.
            let chipHeight = min(max(auxSizeChipSize.height, 22), Self.rowHeight - 8)
            plan.append(PlanItem(
                view: nil,
                // Reserve at least the read-only slot width: the chip view is
                // centred in it, so a short readout does not make the whole
                // plate jitter narrower than its canonical width.
                width: max(auxSizeChipSize.width, Self.defaultChipWidth),
                height: chipHeight,
                group: .auxSize,
                isSizeChip: true
            ))
            plan.append(PlanItem(
                view: stepUpButton,
                width: Self.stepperSize,
                height: Self.stepperSize,
                group: .auxSize,
                isSizeChip: false
            ))
            plan.append(PlanItem(
                view: shadowChip,
                width: Self.shadowChipWidth,
                height: 22,
                group: .auxShadow,
                isSizeChip: false
            ))
            plan.append(PlanItem(
                view: crosshairSwitch,
                width: Self.switchSize.width,
                height: Self.switchSize.height,
                group: .auxSwitch,
                isSizeChip: false
            ))
        }

        if !isRecordingMode {
            for tool in AnnotationToolbarLayout.visibleTools {
                guard let button = toolButtons[tool] else { continue }
                plan.append(PlanItem(
                    view: button,
                    width: Self.buttonSize,
                    height: Self.buttonSize,
                    group: .tools,
                    isSizeChip: false
                ))
            }
            for button in [styleButton, undoButton, redoButton] {
                plan.append(PlanItem(
                    view: button,
                    width: Self.buttonSize,
                    height: Self.buttonSize,
                    group: .tools,
                    isSizeChip: false
                ))
            }
        }
        let strip = isRecordingMode
            ? CaptureToolbarAction.recordingActions
            : CaptureToolbarAction.stripActions
        // A button that is not in this mode's plan must not paint or take
        // clicks at a stale frame.
        for (action, button) in actionButtons {
            button.isHidden = !strip.contains(action)
                && !(isRecordingMode ? action == .cancel : CaptureToolbarAction.tailActions.contains(action))
        }
        for action in strip {
            guard let button = actionButtons[action] else { continue }
            button.isHidden = false
            plan.append(PlanItem(
                view: button,
                width: Self.buttonSize,
                height: Self.buttonSize,
                group: .actions,
                isSizeChip: false
            ))
        }
        var tailButtons: [NSView] = []
        if isRecordingMode {
            tailButtons.append(contentsOf: actionButtons[.cancel].map { [$0] } ?? [])
        } else {
            tailButtons.append(moreButton)
            tailButtons.append(contentsOf: CaptureToolbarAction.tailActions.compactMap {
                actionButtons[$0]
            })
        }
        for button in tailButtons {
            plan.append(PlanItem(
                view: button,
                width: Self.buttonSize,
                height: Self.buttonSize,
                group: .tail,
                isSizeChip: false
            ))
        }
        plan.append(PlanItem(
            view: dragHandle,
            width: Self.buttonSize,
            height: Self.buttonSize,
            group: .tail,
            isSizeChip: false
        ))

        var x = Self.horizontalPadding
        for (index, item) in plan.enumerated() {
            if index > 0 {
                x += Self.gap
                if item.group != plan[index - 1].group {
                    x += Self.groupGap
                    // Centre the hairline in the combined gap we just left.
                    separatorXs.append(x - (Self.gap + Self.groupGap) / 2)
                }
            }
            let frame = CGRect(
                x: x,
                y: plateRect.minY + (Self.rowHeight - item.height) / 2,
                width: item.width,
                height: item.height
            )
            if let view = item.view {
                view.frame = frame
            } else if item.isSizeChip {
                sizeChipFrame = frame
            }
            x += item.width
        }
        needsDisplay = true
    }

    /// Real windows get one live backdrop for the whole plate. Offscreen
    /// renders draw the opaque fallback instead (see `draw`), because a blur
    /// without the window server comes out black.
    private func updateEffectViews() {
        guard !rendersOffscreen, window != nil else {
            plateBackdrop?.removeFromSuperview()
            plateBackdrop = nil
            usesGlassBackdrop = false
            usesOpaqueBackdrop = false
            needsDisplay = true
            return
        }
        rebuildBackdrop()
    }

    private func rebuildBackdrop() {
        guard !rendersOffscreen, window != nil else { return }
        plateBackdrop?.removeFromSuperview()

        let plate = Self.makeBackdropHost(cornerRadius: Self.cornerRadius)
        addSubview(plate, positioned: .below, relativeTo: nil)
        plateBackdrop = plate

        let concrete = plate.subviews.first
        if #available(macOS 26.0, *) {
            usesGlassBackdrop = concrete is NSGlassEffectView
        } else {
            usesGlassBackdrop = false
        }
        usesOpaqueBackdrop = concrete is GlassCardBackdropView
        needsLayout = true
        needsDisplay = true
    }

    /// Wrap the factory's view so a click in the plate's empty area reaches
    /// the toolbar (which needs it to open the size editor) instead of being
    /// swallowed by the backdrop.
    private static func makeBackdropHost(cornerRadius: CGFloat) -> NSView {
        let host = CaptureToolbarBackdropHost()
        host.wantsLayer = true
        let backdrop = GlassSurfaceFactory.makeBackdrop(
            cornerRadius: cornerRadius,
            style: .regular,
            interactive: true,
            offscreen: false,
            backgroundStyle: .liquidGlass,
            glassAllowed: AppearanceRuntime.useGlass
        )
        backdrop.frame = host.bounds
        backdrop.autoresizingMask = [.width, .height]
        host.addSubview(backdrop)
        return host
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.shouldAntialias = true
        drawPlate(plateRect)

        // Group hairlines: aux-size | aux-shadow | aux-switch | tools |
        // actions | tail. They are the only chrome between controls, exactly
        // like the pinned toolbar's grouping.
        NSColor.labelColor.withAlphaComponent(0.18).setFill()
        for x in separatorXs {
            NSRect(
                x: x,
                y: plateRect.minY + (Self.rowHeight - Self.separatorHeight) / 2,
                width: 1,
                height: Self.separatorHeight
            ).fill()
        }
    }

    private func drawPlate(_ rect: CGRect) {
        guard rect.width > 0, rect.height > 0 else { return }
        // A fixed 12 pt *continuous* corner: the same shape the glass backdrop
        // clips to. Deliberately not `rect.height / 2`, which would turn the
        // one-row plate back into the capsule the user asked to remove.
        let plate = NSBezierPath(
            cgPath: RoundedRectangle(
                cornerRadius: Self.cornerRadius,
                style: .continuous
            ).path(in: rect.insetBy(dx: 0.5, dy: 0.5)).cgPath
        )

        // Liquid Glass / the flat tint draws the surface; the fallback fill is
        // only for offscreen renders and the no-window-server path.
        if !usesGlassBackdrop {
            let alpha: CGFloat = usesOpaqueBackdrop ? 0.0
                : ((rendersOffscreen || window == nil) ? 0.90 : 0.35)
            if alpha > 0 {
                NSColor.windowBackgroundColor.withAlphaComponent(alpha).setFill()
                plate.fill()
            }
        }

        // `labelColor` is white in dark and black in light: the dark rendering
        // is unchanged, and light keeps a visible plate edge over the white
        // screenshots this usually floats on.
        NSColor.labelColor.withAlphaComponent(0.18).setStroke()
        plate.lineWidth = 1
        plate.stroke()
    }

    // MARK: - More menu

    private enum Group {
        case auxSize
        case auxShadow
        case auxSwitch
        case tools
        case actions
        case tail
    }

    private enum MoreMenuItem: CaseIterable {
        case saveAs
        case toggleAuxRow
        case resetPosition

        func title(auxVisible: Bool) -> String {
            switch self {
            case .saveAs: "另存为…"
            case .toggleAuxRow:
                auxVisible ? "隐藏左侧辅助控件" : "显示左侧辅助控件"
            case .resetPosition: "重置工具栏位置"
            }
        }
    }

    private func perform(_ item: MoreMenuItem) {
        switch item {
        case .saveAs:
            onAction?(.saveAs)
        case .toggleAuxRow:
            setAuxRowVisible(!isAuxRowVisible)
        case .resetPosition:
            resetUserOffset()
            onUserMoved?()
        }
    }

    private func presentMoreMenu() {
        guard window != nil else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in MoreMenuItem.allCases {
            let menuItem = NSMenuItem(
                title: item.title(auxVisible: isAuxRowVisible),
                action: #selector(handleMoreMenu(_:)),
                keyEquivalent: ""
            )
            menuItem.target = self
            menuItem.representedObject = item
            menu.addItem(menuItem)
        }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: moreButton.frame.minX, y: moreButton.frame.minY - 4),
            in: self
        )
    }

    @objc private func handleMoreMenu(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? MoreMenuItem else { return }
        perform(item)
    }

    private func presentShadowMenu() {
        guard window != nil else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for level in CaptureToolbarShadowLevel.allCases {
            let item = NSMenuItem(
                title: level.title,
                action: #selector(handleShadowMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = level
            item.state = level == shadowLevel ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: shadowChip.frame.minX, y: shadowChip.frame.minY - 4),
            in: self
        )
    }

    @objc private func handleShadowMenu(_ sender: NSMenuItem) {
        guard let level = sender.representedObject as? CaptureToolbarShadowLevel else { return }
        setShadowLevel(level)
        onShadowLevelChanged?(level)
    }

    // MARK: - Size chip taps

    /// A real click on the chip arrives here because the chip view itself is an
    /// overlay sibling (it has no window hit when it is not editing). The
    /// overlay owns the editing grammar; this only reports the tap.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isAuxRowVisible, sizeChipFrame.contains(point) {
            onSizeChipTap?()
            return
        }
        super.mouseDown(with: event)
    }
}

// MARK: - Buttons

/// The capture toolbar's ink, expressed on the same ladder as the pinned-image
/// toolbar (`PinToolbarSurface` / `ToolbarInk`).
///
/// The rule copied from the pin toolbar: a control draws **nothing** at rest —
/// the plate is the only background — and only the control under the pointer
/// gets a shape. The one exception is the current annotation tool, and it is a
/// 1 pt ring rather than a fill, so "this is the current mode" never reads as
/// another button chrome.
enum CaptureToolbarInk {
    /// Resting fill / hairline of an icon. Zero: the plate shows through.
    static let restingFill: Double = 0
    static let restingStroke: Double = 0
    /// Resting glyph ink. Slightly under full label colour so the selected
    /// tool's full ink reads as a state without adding a shape.
    static let restingGlyph: Double = 0.85
    /// Latched (current tool): a hairline ring only, using the panel's
    /// `active` tier so "on" is not the same signature as "pointed at".
    static let selectedStroke: Double = ToolbarInk.capsuleActiveStroke
    /// Pointer-over fill / hairline. Exactly the pin toolbar's hover tier.
    static let hoverFill: Double = ToolbarInk.hoverFill
    static let hoverStroke: Double = ToolbarInk.hoverStroke
    /// A press is one notch above hover so the click has feedback.
    static let pressedFill: Double = ToolbarInk.hoverFill * 1.25
    /// The text chips (size readout / export shadow) use the pin's % chip tier.
    static let chipHoverFill: Double = ToolbarInk.chipHoverFill
    static let chipHoverStroke: Double = ToolbarInk.chipHoverStroke
    /// Corner radius of the pointer / selection shape. A 6 pt *continuous*
    /// rounded square inside the 26 pt hit box — never a circle. The owner
    /// asked for "有圆角的小正方形" instead of the old disc, and the selected
    /// tool's ring uses the same shape so the two states cannot disagree.
    static let controlCornerRadius: CGFloat = 6
    /// Inset of that shape from the hit box. 2 pt keeps the square visibly
    /// inside the 26 pt target (22 × 22) without crowding the 13 pt glyph.
    static let controlInset: CGFloat = 2
}

/// Shared custom-drawn icon button. Custom drawing (rather than SwiftUI or
/// control bezels) is what makes the offscreen render identical to the live
/// window.
@MainActor
class CaptureToolbarIconButton: NSView {
    let symbolName: String
    let label: String
    var symbolPointSize: CGFloat = 13

    var onTap: (() -> Void)?

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            needsDisplay = true
        }
    }

    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            alphaValue = isEnabled ? 1 : 0.38
            needsDisplay = true
        }
    }

    fileprivate var isHovering = false {
        didSet { needsDisplay = true }
    }
    fileprivate var isPressed = false {
        didSet { needsDisplay = true }
    }

    init(symbolName: String, label: String, symbolPointSize: CGFloat = 13) {
        self.symbolName = symbolName
        self.label = label
        self.symbolPointSize = symbolPointSize
        super.init(frame: .zero)
        toolTip = label
        setAccessibilityLabel(label)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` arrives in the *superview's* coordinate system, so the frame —
        // not `bounds` — is the correct test.
        guard !isHidden, alphaValue > 0, isEnabled else { return nil }
        return frame.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        isPressed = false
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if inside { onTap?() }
    }

    /// Set the pointer-over state directly, without a `NSTrackingArea`.
    ///
    /// Production needs it when the capture window turns click-through under a
    /// hovered control (no `mouseExited` will ever arrive), and the self test
    /// needs it because an offscreen render has no real pointer.
    func setHover(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
    }

    /// Self-test seam: drive the pointer state without a real tracking area.
    func setHoverForTesting(_ hovering: Bool) {
        setHover(hovering)
    }

    /// The pointer / selection shape: a 6 pt continuous rounded square, not a
    /// disc. Both states share this one path so a hover and a latched tool
    /// always have the same silhouette.
    private var controlShape: NSBezierPath {
        NSBezierPath(
            cgPath: RoundedRectangle(
                cornerRadius: CaptureToolbarInk.controlCornerRadius,
                style: .continuous
            ).path(
                in: bounds.insetBy(
                    dx: CaptureToolbarInk.controlInset,
                    dy: CaptureToolbarInk.controlInset
                )
            ).cgPath
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.shouldAntialias = true

        // One plate, bare glyphs. The fill exists only while the pointer (or a
        // press) is on this one control; the current tool is marked by a
        // hairline rounded-square ring, never a resting fill.
        if isEnabled, isHovering || isPressed {
            let shape = controlShape
            NSColor.labelColor.withAlphaComponent(
                isPressed ? CaptureToolbarInk.pressedFill : CaptureToolbarInk.hoverFill
            ).setFill()
            shape.fill()
            NSColor.labelColor.withAlphaComponent(CaptureToolbarInk.hoverStroke).setStroke()
            shape.lineWidth = 1
            shape.stroke()
        } else if isSelected {
            let ring = controlShape
            NSColor.labelColor.withAlphaComponent(CaptureToolbarInk.selectedStroke).setStroke()
            ring.lineWidth = 1
            ring.stroke()
        }

        // Glyph ink: full for the current mode / pointer target, a notch
        // quieter otherwise. No per-icon shape at rest.
        let inkAlpha = (isSelected || isHovering || isPressed)
            ? 1.0
            : CaptureToolbarInk.restingGlyph
        let palette = NSColor.labelColor.withAlphaComponent(inkAlpha)
        let configuration = NSImage.SymbolConfiguration(
            pointSize: symbolPointSize,
            weight: isSelected ? .semibold : .medium
        ).applying(NSImage.SymbolConfiguration(paletteColors: [palette]))
        guard let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: label
        )?.withSymbolConfiguration(configuration) else { return }

        let target = NSRect(
            x: (bounds.width - image.size.width) / 2,
            y: (bounds.height - image.size.height) / 2,
            width: image.size.width,
            height: image.size.height
        )
        image.draw(
            in: target,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }
}

/// One capture action (copy / save / OCR / pin / cancel).
@MainActor
final class CaptureToolbarButton: CaptureToolbarIconButton {
    let toolbarAction: CaptureToolbarAction

    init(action: CaptureToolbarAction) {
        self.toolbarAction = action
        super.init(symbolName: action.symbol, label: action.label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// One annotation tool. The selected one gets a hairline ring (not a fill).
@MainActor
final class CaptureToolbarToolButton: CaptureToolbarIconButton {
    let tool: AnnotationTool

    init(tool: AnnotationTool) {
        self.tool = tool
        super.init(symbolName: tool.symbol, label: tool.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Undo / redo. Disabled (dimmed and non-clickable) while its stack is empty.
@MainActor
final class CaptureToolbarHistoryButton: CaptureToolbarIconButton {
    let isRedo: Bool

    init(isRedo: Bool) {
        self.isRedo = isRedo
        super.init(
            symbolName: isRedo ? "arrow.uturn.forward" : "arrow.uturn.backward",
            label: isRedo ? "重做" : "撤销"
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// The ⠿ handle. It reports a screen-space drag delta (so the toolbar moving
/// under the pointer cannot feed back into its own coordinates) and never
/// fires a tap.
@MainActor
final class CaptureToolbarDragHandleButton: CaptureToolbarIconButton {
    var onDragBegan: (() -> Void)?
    var onDrag: ((CGSize) -> Void)?
    private var origin: CGPoint = .zero

    init() {
        super.init(
            symbolName: "line.3.horizontal",
            label: "拖动工具栏",
            symbolPointSize: 12
        )
        setAccessibilityLabel("拖动工具栏")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        origin = NSEvent.mouseLocation
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isPressed else { return }
        let point = NSEvent.mouseLocation
        onDrag?(CGSize(width: point.x - origin.x, height: point.y - origin.y))
    }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
    }
}

/// Pass-through host for the backdrop so clicks in the plate's empty area
/// reach the toolbar (which opens the size editor there).
@MainActor
private final class CaptureToolbarBackdropHost: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The `无阴影 ▾` chip in the left auxiliary group. Text + chevron, bare at
/// rest like the icons, capsule highlight only under the pointer. Opens a menu
/// of `CaptureToolbarShadowLevel` cases.
@MainActor
final class CaptureToolbarMenuChip: NSView {
    var title: String {
        didSet {
            guard title != oldValue else { return }
            needsDisplay = true
        }
    }
    let label: String
    var onTap: (() -> Void)?

    private var isHovering = false {
        didSet { needsDisplay = true }
    }

    private static let font = NSFont.systemFont(ofSize: 11, weight: .medium)

    init(title: String, label: String) {
        self.title = title
        self.label = label
        super.init(frame: .zero)
        setAccessibilityLabel(label)
        setAccessibilityRole(.button)
        toolTip = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onTap?()
    }

    /// See `CaptureToolbarView.clearPointerHover()`: the window can turn
    /// click-through underneath a hovered chip.
    func clearPointerHover() {
        isHovering = false
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.shouldAntialias = true
        let chip = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: bounds.height / 2,
            yRadius: bounds.height / 2
        )
        // Same rule as the icons: no capsule at rest, one only under the
        // pointer, on the pin toolbar's `%` chip tier.
        if isHovering {
            NSColor.labelColor.withAlphaComponent(CaptureToolbarInk.chipHoverFill).setFill()
            chip.fill()
            NSColor.labelColor.withAlphaComponent(CaptureToolbarInk.chipHoverStroke).setStroke()
            chip.lineWidth = 1
            chip.stroke()
        }

        let inkAlpha = isHovering ? 1.0 : CaptureToolbarInk.restingGlyph
        let ink = NSColor.labelColor.withAlphaComponent(inkAlpha)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: ink
        ]
        let text = title as NSString
        let textSize = text.size(withAttributes: attributes)
        let chevron = NSImage(
            systemSymbolName: "chevron.down",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [ink]))
        )
        let chevronWidth = (chevron?.size.width ?? 6) + 4
        let contentWidth = textSize.width + chevronWidth
        let startX = (bounds.width - contentWidth) / 2
        text.draw(
            at: CGPoint(x: startX, y: (bounds.height - textSize.height) / 2),
            withAttributes: attributes
        )
        if let chevron {
            chevron.draw(
                in: CGRect(
                    x: startX + textSize.width + 4,
                    y: (bounds.height - chevron.size.height) / 2,
                    width: chevron.size.width,
                    height: chevron.size.height
                ),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
        }
    }
}

/// The little switch in the left auxiliary group: 显示十字线, wired to the real
/// `AppSettings.showCrosshair`. Monochrome like the rest of the bar (the system
/// accent-blue track was the one coloured control left in the toolbar).
@MainActor
final class CaptureToolbarToggleSwitch: NSView {
    var isOn = true {
        didSet {
            guard isOn != oldValue else { return }
            needsDisplay = true
        }
    }
    var onToggle: ((Bool) -> Void)?
    let label: String

    init(label: String) {
        self.label = label
        super.init(frame: .zero)
        setAccessibilityLabel(label)
        setAccessibilityRole(.button)
        toolTip = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        performToggleForTesting()
    }

    func performToggleForTesting() {
        isOn.toggle()
        onToggle?(isOn)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.shouldAntialias = true
        let track = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: bounds.height / 2,
            yRadius: bounds.height / 2
        )
        // Same monochrome ladder as `NeutralSwitchStyle` in the settings rows.
        NSColor.labelColor.withAlphaComponent(isOn ? 0.22 : 0.11).setFill()
        track.fill()
        NSColor.labelColor.withAlphaComponent(0.10).setStroke()
        track.lineWidth = 1
        track.stroke()

        let knobDiameter = bounds.height - 4
        let knobX = isOn ? bounds.maxX - knobDiameter - 2 : 2
        let knob = NSBezierPath(
            ovalIn: CGRect(
                x: knobX,
                y: 2,
                width: knobDiameter,
                height: knobDiameter
            )
        )
        NSColor.labelColor.withAlphaComponent(isOn ? 0.92 : 0.45).setFill()
        knob.fill()
        NSColor.labelColor.withAlphaComponent(0.10).setStroke()
        knob.lineWidth = 1
        knob.stroke()
    }
}

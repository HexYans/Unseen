import AppKit
import Observation
import SwiftUI

/// One entry in the left column. Replaces the old two-state design
/// (`section` + `settingsSection`) which could disagree with each other — now
/// there is a single source of truth and the section is derived.
enum NavItem: String, CaseIterable, Identifiable, Hashable {
    case history, pins, capture
    // Capture-tool pages. They are *not* left-column rows any more (the four
    // modes live under 截图 → 截图); the cases survive so `SettingsSection`
    // can share their names for titles and symbols.
    case regionCapture, windowCapture, fixedSizeCapture, fullScreenCapture
    case scrollCapture, recording, ocr, colorPicker, keyDisplay, camera
    case annotation
    // 系统 section.
    case general, hotkeys, appearance, usage, privacy, storage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .history: "历史记录"
        case .pins: "钉图"
        case .capture: "截图"
        case .regionCapture: "区域截图"
        case .windowCapture: "窗口截图"
        case .fixedSizeCapture: "固定大小截图"
        case .fullScreenCapture: "全屏截图"
        case .scrollCapture: "长截图"
        case .recording: "录屏"
        case .ocr: "OCR"
        case .colorPicker: "取色"
        case .keyDisplay: "按键显示"
        case .camera: "摄像头"
        case .annotation: "标注"
        case .general: "通用"
        case .hotkeys: "快捷键"
        case .appearance: "外观"
        case .usage: "用量"
        case .privacy: "隐私"
        case .storage: "存储"
        }
    }

    var symbol: String {
        switch self {
        case .history: "clock.arrow.circlepath"
        case .pins: "pin.fill"
        case .capture: "camera.viewfinder"
        case .regionCapture: "rectangle.dashed"
        case .windowCapture: "macwindow.on.rectangle"
        case .fixedSizeCapture: "aspectratio"
        case .fullScreenCapture: "rectangle.inset.filled"
        case .scrollCapture: "arrow.up.and.down.text.horizontal"
        case .recording: "record.circle"
        case .ocr: "text.viewfinder"
        case .colorPicker: "eyedropper"
        case .keyDisplay: "keyboard"
        case .camera: "video"
        case .annotation: "pencil.tip"
        case .general: "gearshape"
        case .hotkeys: "command"
        case .appearance: "paintpalette"
        case .usage: "chart.bar"
        case .privacy: "hand.raised"
        case .storage: "internaldrive"
        }
    }

    /// Settings pages share their raw value with `SettingsSection`.
    var settingsSection: SettingsSection? { SettingsSection(rawValue: rawValue) }

    /// Used when the colour palette is switched on.
    var color: Color {
        switch self {
        case .history: SectionPalette.history
        case .pins: SectionPalette.pins
        case .capture, .regionCapture, .windowCapture, .fixedSizeCapture,
             .fullScreenCapture, .scrollCapture, .recording, .ocr,
             .colorPicker, .keyDisplay, .camera, .annotation:
            SectionPalette.capture
        case .general, .hotkeys, .appearance, .usage, .privacy, .storage:
            SectionPalette.settings
        }
    }

    /// The left column, grouped the way 设置 is organised now.
    ///
    /// 2026-10: the four capture modes are no longer separate left-column
    /// entries. They live under 截图 → 截图 (one entry, whose middle column
    /// lists the four modes), so the same settings page can never be reached
    /// from two places. 截图 is the first row in the column, followed by 长截图
    /// and 录屏; the remaining tools sit in their own 工具 group below it, 标注
    /// last.
    static let groups: [(String, [NavItem])] = [
        ("截图", [.capture, .scrollCapture, .recording]),
        ("工具", [.ocr, .colorPicker, .keyDisplay, .camera, .annotation]),
        ("系统", [.general, .hotkeys, .appearance, .usage, .privacy, .storage]),
        ("资料库", [.history, .pins])
    ]
}

/// The four modes listed under 截图 → 截图.
///
/// Each one *is* an existing settings page: the middle column lists these four
/// rows, and the right pane draws that page in full. Keeping the mapping here
/// means the middle column, the right pane and the old page names cannot
/// disagree about which page a mode means.
enum CaptureToolMode: String, CaseIterable, Identifiable, Hashable {
    case region, window, fixedSize, fullScreen

    var id: String { rawValue }

    var settingsSection: SettingsSection {
        switch self {
        case .region: .regionCapture
        case .window: .windowCapture
        case .fixedSize: .fixedSizeCapture
        case .fullScreen: .fullScreenCapture
        }
    }

    var title: String { settingsSection.title }
    var symbol: String { settingsSection.symbol }

    /// The mode the coordinator starts. 固定大小 has no `CaptureMode`; it goes
    /// through the preset entry (⌃⌥⌘E) instead.
    var captureMode: CaptureMode? {
        switch self {
        case .region: .region
        case .window: .window
        case .fixedSize: nil
        case .fullScreen: .fullScreen
        }
    }

    init?(settingsSection: SettingsSection) {
        guard let match = Self.allCases.first(where: { $0.settingsSection == settingsSection })
        else { return nil }
        self = match
    }

    init(defaultCaptureMode: CaptureMode) {
        switch defaultCaptureMode {
        case .region: self = .region
        case .window: self = .window
        case .fullScreen: self = .fullScreen
        }
    }

    /// `UNSEEN_OPEN` names from before the modes moved under the
    /// 截图 entry, still mapped to the row they now select. "screenshot" is the
    /// pre-2026-10 name for 区域截图, kept so older verification scripts work.
    static let legacyOpenNames: [String: CaptureToolMode] = [
        "screenshot": .region,
        "regionCapture": .region,
        "windowCapture": .window,
        "fixedSizeCapture": .fixedSize,
        "fullScreenCapture": .fullScreen
    ]
}

/// The default capture mode chosen in 设置 → 截图. Read when the navigation
/// state is created, so the capture tool opens on the user's mode.
@MainActor
enum NavigationDefaults {
    static var captureMode: CaptureMode = .region

    /// The 截图 page's initial row.
    static var captureTool: CaptureToolMode {
        CaptureToolMode(defaultCaptureMode: captureMode)
    }
}


/// Which kind of page is on screen, used for the column layout.
enum NavigationSection: String, Hashable {
    case history, pins, capture, settings
}

/// One entry in the middle column: a *group* of rows inside a settings page.
/// The middle column lists these names; the detail pane draws only the group
/// whose `id` is selected, so the two columns never show the same rows twice.
struct PageGroup: Identifiable, Hashable {
    /// Stable identity, e.g. "startup". Never shown to the user.
    let id: String
    /// Matches the `group("…")` / `GroupHeader("…")` title drawn on the right.
    let title: String
    /// SF Symbol for the middle-column row.
    let symbol: String
}

/// Group ids, kept in one place so the middle column and the detail pane cannot
/// drift apart by a typo.
enum PageGroupID {
    /// Placeholder for pages with no middle column (history / pins).
    static let none = ""

    // 系统 → 通用
    static let startup = "startup"
    static let menuBar = "menu-bar"
    static let generalBehavior = "general-behavior"
    static let pin = "pin"
    static let backup = "backup"

    /// The four blocks of the 快捷键 page. The prefix keeps these ids
    /// disjoint from the other pages' group ids (`pin` already names
    /// 通用 → 钉图).
    static func hotKeyGroup(_ group: HotKeyGroup) -> String {
        "hotkey-group-\(group.rawValue)"
    }

    // 截图 — split by capture mode. Shared output settings live on 区域截图;
    // the other mode pages carry only their own shortcuts/behaviour.
    static let captureDefault = "capture-default"
    static let regionHotKey = "region-hotkey"
    static let regionBehavior = "region-behavior"
    static let screenshotOutput = "screenshot-output"
    static let beautifyCapture = "beautify-capture"
    static let windowHotKey = "window-hotkey"
    static let fixedSizePreset = "fixed-size-preset"
    static let fullScreenHotKey = "full-screen-hotkey"
    static let instantFeedback = "instant-feedback"
    static let fullScreenDelay = "full-screen-delay"

    // 标注
    static let annotationStyle = "annotation-style"
    static let annotationTools = "annotation-tools"

    // 滚图
    static let scrollBehavior = "scroll-behavior"
    static let scrollAlgorithm = "scroll-algorithm"

    // 录屏
    static let recordingEncode = "recording-encode"
    static let recordingOutput = "recording-output"

    // OCR
    static let ocrLanguage = "ocr-language"
    static let ocrBehavior = "ocr-behavior"

    // 取色器
    static let colorPickerFormat = "color-picker-format"
    static let colorPickerRecent = "color-picker-recent"

    // 按键显示
    static let keyDisplayToggle = "key-display-toggle"
    static let keyDisplayPlacement = "key-display-placement"

    // 摄像头
    static let cameraToggle = "camera-toggle"
    static let cameraPlacement = "camera-placement"

    // 外观: one 主题 card (外观 / 风格 / 不透明度) plus 图标.
    static let theme = "theme"
    static let iconColour = "icon-colour"

    static let usageHeatmap = "usage-heatmap"
    static let usageWeek = "usage-week"
    static let usageSummary = "usage-summary"

    static let privacyFilter = "privacy-filter"
    static let privacyIgnore = "privacy-ignore"

    static let storageRetention = "storage-retention"
    static let storageDatabase = "storage-database"
}

@MainActor
@Observable
final class NavigationState {
    var item: NavItem = .history {
        // Changing page must land on that page's first group, otherwise the
        // middle column would highlight a name the detail pane does not draw.
        didSet {
            guard item != oldValue else { return }
            groupID = Self.firstGroupID(for: item)
        }
    }

    /// Selected group inside the middle column, for `.settings`.
    var groupID: String = PageGroupID.none

    /// Selected row of 截图 → 截图, shown in the middle column. Seeded from
    /// 设置 → 截图 → 默认模式.
    var captureTool: CaptureToolMode = NavigationDefaults.captureTool

    /// The first group of whichever page the item maps to (empty for pages
    /// that have no middle column).
    private static func firstGroupID(for item: NavItem) -> String {
        switch item {
        case .history, .pins, .capture: return PageGroupID.none
        default: return item.settingsSection?.pageGroups.first?.id ?? PageGroupID.none
        }
    }

    var section: NavigationSection {
        switch item {
        case .history: .history
        case .pins: .pins
        case .capture: .capture
        default: .settings
        }
    }

    var settingsSection: SettingsSection {
        item.settingsSection ?? .general
    }

    /// Navigate by section (application menu, Dock reopen, …).
    func show(_ section: NavigationSection) {
        switch section {
        case .history: item = .history
        case .pins: item = .pins
        case .capture: item = .capture
        case .settings: if item.settingsSection == nil { item = .general }
        }
    }
}

/// The settings pages, listed in the sidebar rather than as a tab strip.
///
/// 2026-10 refactor: the four capture modes each own a page (区域 / 窗口 /
/// 固定大小 / 全屏), followed by the remaining capture tools and 标注 last.
/// `NavItem.groups` draws the same split in the left column.
enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case regionCapture, windowCapture, fixedSizeCapture, fullScreenCapture
    case scrollCapture, recording, ocr, colorPicker, keyDisplay, camera
    case annotation
    case general, hotkeys, appearance, usage, privacy, storage

    var id: String { rawValue }

    var title: String { NavItem(rawValue: rawValue)?.title ?? rawValue }

    var symbol: String { NavItem(rawValue: rawValue)?.symbol ?? "gearshape" }

    /// The groups this page is divided into, in drawing order. The middle
    /// column lists exactly these names, and `SettingsView` draws exactly one
    /// of them at a time — so `id` must identify a real group in the page and
    /// `title` must equal the `group("…")` title it draws.
    var pageGroups: [PageGroup] {
        switch self {
        case .regionCapture:
            [
                PageGroup(id: PageGroupID.captureDefault, title: "默认模式", symbol: "slider.horizontal.3"),
                PageGroup(id: PageGroupID.regionHotKey, title: "快捷键", symbol: "command"),
                PageGroup(id: PageGroupID.regionBehavior, title: "框选行为", symbol: "cursorarrow"),
                PageGroup(id: PageGroupID.screenshotOutput, title: "保存 & 动作", symbol: "square.and.arrow.down"),
                PageGroup(id: PageGroupID.beautifyCapture, title: "套壳 / 美化", symbol: "sparkles.rectangle.stack")
            ]
        case .windowCapture:
            [
                PageGroup(id: PageGroupID.windowHotKey, title: "即时窗口", symbol: "macwindow")
            ]
        case .fixedSizeCapture:
            [
                PageGroup(id: PageGroupID.fixedSizePreset, title: "预设尺寸", symbol: "aspectratio")
            ]
        case .fullScreenCapture:
            [
                PageGroup(id: PageGroupID.fullScreenHotKey, title: "即时全屏", symbol: "bolt.fill"),
                PageGroup(id: PageGroupID.instantFeedback, title: "即时反馈", symbol: "speaker.wave.2"),
                PageGroup(id: PageGroupID.fullScreenDelay, title: "延时截图", symbol: "timer")
            ]
        case .annotation:
            [
                PageGroup(id: PageGroupID.annotationStyle, title: "默认样式", symbol: "paintpalette"),
                PageGroup(id: PageGroupID.annotationTools, title: "工具", symbol: "pencil.tip")
            ]
        case .scrollCapture:
            [
                PageGroup(id: PageGroupID.scrollBehavior, title: "捕获", symbol: "arrow.up.and.down.text.horizontal"),
                PageGroup(id: PageGroupID.scrollAlgorithm, title: "拼接参数", symbol: "square.stack.3d.up")
            ]
        case .recording:
            [
                PageGroup(id: PageGroupID.recordingEncode, title: "编码", symbol: "film"),
                PageGroup(id: PageGroupID.recordingOutput, title: "输出与权限", symbol: "folder")
            ]
        case .ocr:
            [
                PageGroup(id: PageGroupID.ocrLanguage, title: "语言", symbol: "character.book.closed"),
                PageGroup(id: PageGroupID.ocrBehavior, title: "识别与结果", symbol: "text.viewfinder")
            ]
        case .colorPicker:
            [
                PageGroup(id: PageGroupID.colorPickerFormat, title: "复制格式", symbol: "eyedropper"),
                PageGroup(id: PageGroupID.colorPickerRecent, title: "最近颜色", symbol: "swatchpalette")
            ]
        case .keyDisplay:
            [
                PageGroup(id: PageGroupID.keyDisplayToggle, title: "开关与权限", symbol: "keyboard"),
                PageGroup(id: PageGroupID.keyDisplayPlacement, title: "显示位置", symbol: "rectangle.bottomthird.inset.filled")
            ]
        case .camera:
            [
                PageGroup(id: PageGroupID.cameraToggle, title: "开关与权限", symbol: "video"),
                PageGroup(id: PageGroupID.cameraPlacement, title: "位置与尺寸", symbol: "rectangle.inset.filled")
            ]
        case .general:
            [
                PageGroup(id: PageGroupID.startup, title: "启动", symbol: "power"),
                PageGroup(id: PageGroupID.menuBar, title: "菜单栏", symbol: "menubar.rectangle"),
                PageGroup(id: PageGroupID.generalBehavior, title: "面板行为", symbol: "menubar.rectangle"),
                PageGroup(id: PageGroupID.pin, title: "钉图", symbol: "pin"),
                PageGroup(id: PageGroupID.backup, title: "备份 & 恢复", symbol: "arrow.triangle.2.circlepath")
            ]
        case .hotkeys:
            // The four shortcut blocks. The middle column lists them and the
            // right pane draws the selected block's card, exactly like every
            // other settings page draws its selected group.
            HotKeyGroup.allCases.map { group in
                PageGroup(
                    id: PageGroupID.hotKeyGroup(group),
                    title: group.title,
                    symbol: group.symbol
                )
            }
        case .appearance:
            [
                PageGroup(id: PageGroupID.theme, title: "主题", symbol: "paintpalette"),
                PageGroup(id: PageGroupID.iconColour, title: "图标", symbol: "paintbrush")
            ]
        case .usage:
            [
                PageGroup(id: PageGroupID.usageHeatmap, title: "每日用量", symbol: "square.grid.3x3"),
                PageGroup(id: PageGroupID.usageSummary, title: "汇总", symbol: "sum"),
                PageGroup(id: PageGroupID.usageWeek, title: "最近 7 天", symbol: "calendar")
            ]
        case .privacy:
            [
                PageGroup(id: PageGroupID.privacyFilter, title: "过滤规则", symbol: "line.3.horizontal.decrease.circle"),
                PageGroup(id: PageGroupID.privacyIgnore, title: "永不记录的应用", symbol: "hand.raised.slash")
            ]
        case .storage:
            [
                PageGroup(id: PageGroupID.storageRetention, title: "保留策略", symbol: "clock.arrow.circlepath"),
                PageGroup(id: PageGroupID.storageDatabase, title: "数据库", symbol: "internaldrive")
            ]
        }
    }
}

/// The window's four-corner chrome.
///
/// A `.fullSizeContentView` window normally rounds only its bottom corners:
/// once the content fills the titlebar (which 液态玻璃 does, because the glass
/// is drawn behind the traffic lights) the top two corners stay square.
/// Clipping the content layer to the same radius and curve as the system rounds
/// all four consistently. 12 pt matches the system window corner on macOS 26/27.
@MainActor
enum MainWindowChrome {
    static let cornerRadius: CGFloat = 12

    /// Only 纯色 is a genuinely opaque window; the other two must stay
    /// transparent so the blur/glass can sample the desktop behind them.
    static func isOpaqueBackground(_ style: AppBackgroundStyle) -> Bool {
        style == .solid
    }

    static func windowBackgroundColor(for style: AppBackgroundStyle) -> NSColor {
        style == .solid ? .windowBackgroundColor : .clear
    }

    /// - Parameter fullScreen: full-screen windows have no rounded corners, so
    ///   the mask is removed instead of being clamped to a tiny radius.
    static func apply(to contentView: NSView?, fullScreen: Bool) {
        guard let contentView else { return }
        contentView.wantsLayer = true
        guard let layer = contentView.layer else { return }
        let radius = fullScreen ? 0 : cornerRadius
        layer.cornerRadius = radius
        // `.continuous` matches the system windows' squircle, not a circular arc.
        layer.cornerCurve = .continuous
        layer.masksToBounds = radius > 0
    }
}

/// Main window that keeps all four corners rounded, and drops the rounding in
/// full screen where the system does not round windows.
@MainActor
final class MainWindow: NSWindow {
    private(set) var chromeIsFullScreen = false

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidEnterFullScreen),
            name: NSWindow.didEnterFullScreenNotification,
            object: self
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidExitFullScreen),
            name: NSWindow.didExitFullScreenNotification,
            object: self
        )
    }

    @objc private func handleDidEnterFullScreen() {
        applyChrome(fullScreen: true)
    }

    @objc private func handleDidExitFullScreen() {
        applyChrome(fullScreen: false)
    }

    /// Applies a 外观 → 背景 choice to the window shell: opacity plus corners.
    func applyBackgroundStyle(_ style: AppBackgroundStyle) {
        isOpaque = MainWindowChrome.isOpaqueBackground(style)
        backgroundColor = MainWindowChrome.windowBackgroundColor(for: style)
        applyChrome()
    }

    /// - Parameter fullScreen: `nil` keeps the tracked state (used by the
    ///   notifications); tests pass it explicitly.
    func applyChrome(fullScreen: Bool? = nil) {
        if let fullScreen { chromeIsFullScreen = fullScreen }
        MainWindowChrome.apply(to: contentView, fullScreen: chromeIsFullScreen)
    }
}

/// The three traffic lights, placed by geometry rather than by eye.
///
/// 2026-10-25 (second pass). The first pass moved the buttons 3 pt right and
/// 3 pt down *and* enlarged the drawing by 12 %. The owner kept the vertical
/// drop, rejected the size ("大小不做改动, 系统默认") and asked for the red dot's
/// **visual** left edge to sit on the same vertical line as the left column's
/// card edge ("左边界与卡片对齐,保持一条直线").
///
/// Three rules, and none of them touches the drawing:
///
/// 1. **Size: untouched.** No `bounds` juggling any more — the buttons draw at
///    the system's own 12 pt circle, exactly as an unmodified window does.
/// 2. **Horizontal: solved, not guessed.** The target is the card's outer left
///    edge, `MainColumnMetrics.outerPadding` from the window's left edge. The
///    button's *frame* is not that edge: the 12 pt circle is centred inside a
///    14 × 16 pt frame, so 1 pt of padding sits to its left. The offset is
///    therefore computed as `target - (frame.origin.x + inset)`; on the measured
///    macOS 27 geometry (system frame x = 9) that evaluates to 0 — the system's
///    own x already lines the circle up, and only the old +3 pt nudge had
///    broken it. Because it is derived from the constant, it stays aligned if
///    the column padding ever changes.
/// 3. **Vertical: 3 pt lower than the system position**, the drop the owner
///    asked for and kept.
///
/// The buttons stay the real `standardWindowButton`s, so close / miniaturise /
/// zoom keep their AppKit behaviour, their hover symbols and their hit areas;
/// only `frame.origin` is written, and it is re-derived from a remembered
/// system frame so a resize or a full-screen round trip replays idempotently.
@MainActor
enum MainWindowTrafficLights {
    /// The system traffic-light circle. AppKit draws 12 pt inside a 14 × 16 pt
    /// button frame, i.e. 1 pt of padding on each side; the visual left edge of
    /// the red dot is `frame.origin.x + (frame.width - 12) / 2`, *not*
    /// `frame.origin.x`. Measured on macOS 27 at 2× pixels (12.0 pt).
    static let systemDotDiameter: CGFloat = 12

    /// How far below the system position the three buttons sit, in points.
    /// The system frame already centres a 16 pt button in the 28 pt titlebar
    /// band; the 3 pt drop sits the circle between the window's top edge and
    /// the first card (11 pt above, 15 pt below at the measured layout).
    static let verticalOffset: CGFloat = 3

    private static let types: [NSWindow.ButtonType] = [
        .closeButton, .miniaturizeButton, .zoomButton
    ]

    /// The system frame of each button, remembered so re-applying (after a
    /// resize) is idempotent instead of accumulating the offset.
    private static var baseFrames: [ObjectIdentifier: NSRect] = [:]

    /// The horizontal travel that lands the **red dot's** visual left edge on
    /// the left column's card edge. Applied to all three buttons alike: their
    /// 20 pt centre spacing is the system's and stays exactly as it is.
    ///
    /// - Parameters:
    ///   - base: the close button's system frame, in its superview's coordinates.
    ///   - superview: the frame's owner, used to convert into window coordinates
    ///     so a titlebar view that is not at x = 0 cannot skew the result.
    private static func horizontalOffset(for base: NSRect, in superview: NSView) -> CGFloat {
        let inset = max(0, (base.width - systemDotDiameter) / 2)
        let systemVisualLeft = superview.convert(base.origin, to: nil).x + inset
        return MainColumnMetrics.outerPadding - systemVisualLeft
    }

    /// The button's system frame, remembered on first sight so re-applying after
    /// a resize or a full-screen round trip is idempotent instead of
    /// accumulating the offset. Returns nil while the titlebar has not laid the
    /// button out yet (an empty frame would anchor every later apply to
    /// nothing).
    private static func systemFrame(for button: NSButton) -> NSRect? {
        let key = ObjectIdentifier(button)
        let base = baseFrames[key] ?? button.frame
        guard base.width > 0, base.height > 0 else { return nil }
        baseFrames[key] = base
        return base
    }

    /// Moves the three standard buttons: same size, lower by `verticalOffset`,
    /// and shifted horizontally so the red dot's visual left edge sits on the
    /// card edge. All three use one shared horizontal delta, so the group moves
    /// rigidly and the spacing never changes.
    static func apply(to window: NSWindow) {
        guard let close = window.standardWindowButton(.closeButton),
              let closeSuperview = close.superview,
              let closeBase = systemFrame(for: close) else { return }
        let dx = horizontalOffset(for: closeBase, in: closeSuperview)

        for buttonType in types {
            guard let button = window.standardWindowButton(buttonType),
                  let superview = button.superview,
                  let base = systemFrame(for: button) else { continue }
            var frame = base
            frame.origin.x = base.origin.x + dx
            // Measured on macOS 27: `NSTitlebarView` is not flipped and its
            // origin sits at the bottom of the titlebar, so decreasing y moves
            // the button *down* the screen (the gap from the window top went
            // from 6 pt to 9 pt). Keep the sign honest for either host kind.
            frame.origin.y = base.origin.y + (superview.isFlipped ? verticalOffset : -verticalOffset)
            button.frame = frame
            // Deliberately no `button.bounds` write: the widget draws at the
            // system size. (The previous revision shrank bounds to 1/1.12 to
            // enlarge the drawing by 12 %; that was reverted on request.)
        }
    }

    // MARK: - Verification probe (test-only)

    /// `UNSEEN_TRAFFIC_PROBE=dump[,watch]` prints each button's frame,
    /// bounds, window-relative rect and the visual-left-vs-card-edge numbers so
    /// a verification run can quote measurements instead of eyeballing a
    /// screenshot. `watch` repeats the dump once a second for 12 s, so an
    /// externally driven click or resize shows up in the trace.
    static func dump(_ label: String, window: NSWindow) {
        var header = "traffic \(label) window=\(NSStringFromRect(window.frame))"
        header += " visible=\(window.isVisible ? 1 : 0)"
        header += " miniaturized=\(window.isMiniaturized ? 1 : 0)"
        header += " fullscreen=\(window.styleMask.contains(.fullScreen) ? 1 : 0)"
        header += " key=\(window.isKeyWindow ? 1 : 0)"
        DebugLog.log(header)
        for buttonType in types {
            let name = buttonName(buttonType)
            guard let button = window.standardWindowButton(buttonType),
                  let superview = button.superview else {
                DebugLog.log("traffic \(label) \(name) missing")
                continue
            }
            let inWindow = button.convert(button.bounds, to: nil)
            let inset = max(0, (button.frame.width - systemDotDiameter) / 2)
            // The number the owner cares about: where the circle's left edge
            // actually lands, next to the card edge it has to line up with.
            let visualLeft = inWindow.minX + inset
            let cardLeft = MainColumnMetrics.outerPadding
            var line = "traffic \(label) \(name)"
            line += " frame=\(NSStringFromRect(button.frame))"
            line += " bounds=\(NSStringFromRect(button.bounds))"
            line += " windowRect=\(NSStringFromRect(inWindow))"
            line += " visualLeft=\(String(format: "%.2f", visualLeft))"
            line += " cardLeft=\(String(format: "%.2f", cardLeft))"
            line += " delta=\(String(format: "%+.2f", visualLeft - cardLeft))"
            line += " superview=\(NSStringFromClass(Swift.type(of: superview)))"
            line += " flipped=\(superview.isFlipped ? 1 : 0)"
            DebugLog.log(line)
        }
    }

    private static func buttonName(_ buttonType: NSWindow.ButtonType) -> String {
        switch buttonType {
        case .closeButton: "close"
        case .miniaturizeButton: "miniaturize"
        case .zoomButton: "zoom"
        default: "other"
        }
    }
}

/// The app's main window: one content column on the left (header, search,
/// filters, list, mode bar) and a detail pane on the right.
@MainActor
final class MainWindowController {
    private let model: AppModel
    private let navigation: NavigationState
    private var window: MainWindow?

    init(model: AppModel, navigation: NavigationState) {
        self.model = model
        self.navigation = navigation
        // Keep the window shell in sync even when the style is changed while
        // the window is closed (or before it is first created).
        observeBackgroundStyle()
    }

    var isOpen: Bool { window?.isVisible ?? false }

    func show(section: NavigationSection) {
        navigation.show(section)
        if window == nil { window = makeWindow() }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        // The titlebar has laid its buttons out once the window is on screen,
        // so the micro-tuning is applied here rather than at construction time.
        if let window {
            MainWindowTrafficLights.apply(to: window)
            scheduleTrafficProbeIfRequested()
        }
    }

    /// Dock-icon click, or launching the app again.
    func showFrontmost() {
        show(section: navigation.section)
    }

    private func makeWindow() -> MainWindow {
        let root = MainView(model: model, navigation: navigation)
        let hosting = NSHostingView(rootView: root)
        // SwiftUI's hosting view otherwise paints an opaque window-background
        // layer, which would defeat the 外观 → 背景 translucency.
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.isOpaque = false

        let window = MainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Unseen"
        // The 外观 → 背景 setting draws translucent/glass backdrops; the window
        // itself must be non-opaque for them to show the desktop.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        // A standard resizable window can go full screen; declare it so
        // AppKit offers Enter Full Screen and the green button behaves as
        // users expect (full screen = no rounded corners, see `MainWindow`).
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.minSize = NSSize(width: 820, height: 520)
        window.setFrameAutosaveName("MainWindow")
        // 纯色 is opaque; 半透明/液态玻璃 must stay transparent for the backdrop.
        window.applyBackgroundStyle(model.settings.backgroundStyleValue)
        window.center()

        // No NSToolbar. Until 2026-10-25 this window carried an empty one just
        // for the unified look, and AppKit still reserved a full unified band
        // for it: the content safe-area top measured 52 pt, so the cards began
        // 62 pt down and every settings page's title sat 77 pt below the
        // window's top edge — a large empty strip above the page. The titlebar
        // alone insets the content by 27.5 pt here, so the cards now begin at
        // 37.5 pt and the title at 53 pt: the gap is still deliberate (10 pt of
        // `MainColumnMetrics.outerPadding` plus the 10 pt page header padding),
        // it just no longer carries a toolbar band. The toolbar never had an
        // item and nothing referenced it, so nothing else changes.
        observeWindowLayout(window)
        return window
    }

    /// AppKit lays the titlebar out again on every resize; the offset is
    /// re-applied so the buttons stay put instead of snapping back.
    private func observeWindowLayout(_ window: NSWindow) {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let window = self?.window else { return }
                MainWindowTrafficLights.apply(to: window)
            }
        }
        // Full screen hides the traffic lights; coming back lays them out again.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let window = self?.window else { return }
                MainWindowTrafficLights.apply(to: window)
            }
        }
    }

    // MARK: - Verification probe (test-only)

    private var trafficProbeScheduled = false

    /// `UNSEEN_TRAFFIC_PROBE=dump[,watch]` prints the three buttons'
    /// frames and window rects so a verification run can quote numbers.
    private func scheduleTrafficProbeIfRequested() {
        guard !trafficProbeScheduled,
              let raw = ProcessInfo.processInfo.environment["UNSEEN_TRAFFIC_PROBE"],
              let window else { return }
        trafficProbeScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            MainWindowTrafficLights.dump("settled", window: window)
            guard raw.contains("watch") else { return }
            for _ in 0..<12 {
                try? await Task.sleep(for: .seconds(1))
                MainWindowTrafficLights.dump("watch", window: window)
            }
        }
    }

    /// The 背景 setting can change while the window is open (or after it was
    /// closed and reopened), so the window's opacity and corner mask follow it.
    private func observeBackgroundStyle() {
        NotificationCenter.default.addObserver(
            forName: .backgroundStyleDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.window?.applyBackgroundStyle(self?.model.settings.backgroundStyleValue ?? .solid)
            }
        }
    }
}

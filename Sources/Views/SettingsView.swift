import AppKit
import SwiftUI

/// An optional primary action in a settings page's header.
///
/// 截图 → 截图 uses it to keep the old capture page's 开始截图 button: the
/// right pane is that mode's settings page, but the page still starts a capture.
struct SettingsPageAction {
    let title: String
    let symbol: String
    let handler: () -> Void
}

/// Vertical rhythm of a settings page header.
///
/// Every settings page draws the same big title / subtitle block, so the
/// numbers live here instead of being repeated in `SettingsView.page` and
/// `UsagePage` (which has its own copy of the same header). The previous
/// values (top 4, title→subtitle 3, header→first group 20) put the title
/// almost on the card's top edge — the 2026-10 polish pass lifted the whole
/// block and evened out the three gaps.
enum SettingsPageMetrics {
    /// Space between the window's content edge and the big title.
    static let headerTopPadding: CGFloat = 10
    /// Title → subtitle. One step larger than the old 3 pt so the subtitle
    /// does not read as part of the title.
    static let headerTitleSpacing: CGFloat = 5
    /// Subtitle → first group header. The group header already adds 6 pt of
    /// its own bottom padding, so this is the visual gap above the first slab.
    static let sectionSpacing: CGFloat = 22
}

/// Settings: one page per sidebar section. Each page is a scrolling stack of
/// grouped slabs (see `GroupedList.swift`) rather than a `Form(.grouped)`, so
/// the settings read exactly like the rest of the app's surfaces.
///
/// 2026-10 IA refactor:
///
///     截图 → 截图 → 区域 / 窗口 / 固定大小 / 全屏（each mode is a page here）
///     截图 → 长截图 / 录屏
///     工具 → OCR / 取色 / 按键显示 / 摄像头 / 标注
///     系统 → 通用 / 快捷键 / 外观 / 用量 / 隐私 / 存储
///     资料库 → 历史记录 / 钉图
///
/// Every page keeps its groups (listed in the middle column) and the detail
/// pane draws only the selected group. 截图 passes `groupID: none`, so the
/// selected mode's page is drawn in full. 通用 no longer carries every capture
/// setting; each capture feature now has exactly one home — the four mode pages
/// are reachable only through 截图.
struct SettingsView: View {
    @Bindable var model: AppModel
    let section: SettingsSection
    /// Which group of this page the middle column has selected. Only that group
    /// is drawn on the right; the middle column already lists the rest.
    var groupID: String = PageGroupID.none
    /// Shown at the trailing edge of the page header, when the page has a
    /// primary verb (only 截图 today).
    var action: SettingsPageAction? = nil
    @State private var newBundleID = ""
    @State private var toast: String?
    @State private var screenRecordingGranted = ScreenCapture.hasScreenRecordingPermission
    @State private var keyDisplayTrusted = KeyDisplayPermission.current.isGranted
    @State private var cameraPermission = CameraPermission.current

    private var settings: AppSettings { model.settings }

    /// Named locations offered by the 保存位置 picker. Any other stored value is
    /// shown as 自定义 and can be replaced with the folder panel.
    private static let standardDirectories: [(title: String, path: String)] = [
        ("桌面", "~/Desktop"),
        ("图片", "~/Pictures"),
        ("文稿", "~/Documents")
    ]
    private static let customDirectoryTag = "__custom__"

    /// The pull-down's rows: the three presets plus the folder-panel entry.
    private static let directorySelections: [String] =
        standardDirectories.map(\.path) + [customDirectoryTag]

    /// Label shown both on the closed capsule and in the menu.
    private func directoryTitle(for path: String) -> String {
        if path == Self.customDirectoryTag { return "自定义" }
        return Self.standardDirectories.first { $0.path == path }?.title ?? "自定义"
    }

    private static let ocrLanguageOptions: [(value: String, title: String)] = [
        ("zh+en", "中文 + English"),
        ("zh", "中文"),
        ("en", "English")
    ]

    /// Picker value: a preset path, or `customDirectoryTag` for any other path.
    private var captureDirectorySelection: Binding<String> {
        Binding(
            get: {
                let path = settings.captureDirectoryPath
                return Self.standardDirectories.contains { $0.path == path }
                    ? path
                    : Self.customDirectoryTag
            },
            set: { newValue in
                if newValue == Self.customDirectoryTag {
                    chooseDirectory()
                } else {
                    settings.captureDirectoryPath = newValue
                }
            }
        )
    }

    /// True when the middle column has this group selected. An empty
    /// `groupID` means there is no middle column, so every group is drawn.
    private func isSelected(_ id: String) -> Bool {
        groupID.isEmpty || groupID == id
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .overlay(alignment: .bottom) { toastView }
        .onAppear(perform: refreshPermissions)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    /// Permission grants only change while the app is in the background (the
    /// user is in System Settings), so every activation re-reads both.
    private func refreshPermissions() {
        screenRecordingGranted = ScreenCapture.hasScreenRecordingPermission
        keyDisplayTrusted = KeyDisplayPermission.current.isGranted
        cameraPermission = CameraPermission.current
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .regionCapture: regionCaptureTab
        case .windowCapture: windowCaptureTab
        case .fixedSizeCapture: fixedSizeCaptureTab
        case .fullScreenCapture: fullScreenCaptureTab
        case .scrollCapture: scrollTab
        case .recording: recordingTab
        case .ocr: ocrTab
        case .colorPicker: colorPickerTab
        case .keyDisplay: keyDisplayTab
        case .camera: cameraTab
        case .annotation: annotationTab
        case .general: generalTab
        case .hotkeys: hotkeysTab
        case .appearance: appearanceTab
        case .privacy: privacyTab
        case .storage: storageTab
        case .usage: UsagePage(model: model)
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.system(size: 12))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassSurface(cornerRadius: 10)
                .padding(.bottom, 18)
                .transition(.opacity)
        }
    }

    private func flash(_ message: String) {
        withAnimation { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { toast = nil }
        }
    }

    private func binding<T>(_ keyPath: ReferenceWritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { settings[keyPath: keyPath] }, set: { settings[keyPath: keyPath] = $0 })
    }

    /// The 不透明度 read-out: a percentage, because the slider is 0–1 and
    /// "10%" says more at a glance than "0.10". Rounded to whole percent —
    /// the slider's 0.01 step *is* one percent, so no precision is lost.
    private static func percentLabel(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    // MARK: - 统一的快捷键位

    /// One editable shortcut row: the live bindings plus the default the
    /// recorder's 默认 button restores.
    private struct HotKeySlot: Identifiable {
        let id: HotKeyBindingID
        let keyCode: Binding<Int>
        let modifiers: Binding<Int>
        let defaultConfiguration: HotKeyConfiguration
        let isEnabled: Bool

        var configuration: HotKeyConfiguration {
            HotKeyConfiguration(
                keyCode: UInt32(keyCode.wrappedValue),
                modifiers: UInt32(modifiers.wrappedValue)
            )
        }

        var binding: HotKeyBinding {
            HotKeyBinding(
                id: id.rawValue,
                title: id.title,
                configuration: configuration,
                isEnabled: isEnabled
            )
        }
    }

    /// Every bindable action, in the order the 快捷键 page draws it.
    ///
    /// The annotation tools come first because that is the block the owner
    /// pointed at in the reference image; each group's own `members` array
    /// carries the row order, so the cards and the group metadata cannot drift.
    private var hotKeySlots: [HotKeySlot] {
        HotKeyGroup.allCases.flatMap(\.members).map(hotKeySlot)
    }

    /// One row's live bindings plus its shipped default.
    private func hotKeySlot(_ id: HotKeyBindingID) -> HotKeySlot {
        if let tool = id.annotationTool {
            return HotKeySlot(
                id: id,
                keyCode: Binding(
                    get: { Int(settings.annotationToolConfiguration(tool).keyCode) },
                    set: { newValue in
                        var updated = settings.annotationToolConfiguration(tool)
                        updated.keyCode = UInt32(max(0, newValue))
                        settings.setAnnotationToolConfiguration(updated, for: tool)
                    }
                ),
                modifiers: Binding(
                    get: { Int(settings.annotationToolConfiguration(tool).modifiers) },
                    set: { newValue in
                        var updated = settings.annotationToolConfiguration(tool)
                        updated.modifiers = UInt32(max(0, newValue))
                        settings.setAnnotationToolConfiguration(updated, for: tool)
                    }
                ),
                defaultConfiguration: .annotationTool(tool),
                // Overlay-local: there is no feature switch to gate it, and the
                // overlay simply matches it while it is open.
                isEnabled: true
            )
        }

        switch id {
        case .openPanel:
            return HotKeySlot(
                id: id,
                keyCode: binding(\.hotKeyKeyCode),
                modifiers: binding(\.hotKeyModifiers),
                defaultConfiguration: .default,
                isEnabled: settings.hotKeyEnabled
            )
        case .pin:
            return HotKeySlot(
                id: id,
                keyCode: binding(\.pinHotKeyKeyCode),
                modifiers: binding(\.pinHotKeyModifiers),
                defaultConfiguration: .pinLastImage,
                isEnabled: settings.pinHotKeyEnabled
            )
        case .region:
            return HotKeySlot(
                id: id,
                keyCode: binding(\.screenshotHotKeyKeyCode),
                modifiers: binding(\.screenshotHotKeyModifiers),
                defaultConfiguration: .screenshot,
                isEnabled: settings.screenshotHotKeyEnabled
            )
        case .window:
            return HotKeySlot(
                id: id,
                keyCode: binding(\.windowHotKeyKeyCode),
                modifiers: binding(\.windowHotKeyModifiers),
                defaultConfiguration: .windowCapture,
                isEnabled: settings.windowHotKeyEnabled
            )
        case .fullScreen:
            return HotKeySlot(
                id: id,
                keyCode: binding(\.fullScreenHotKeyKeyCode),
                modifiers: binding(\.fullScreenHotKeyModifiers),
                defaultConfiguration: .fullScreenCapture,
                isEnabled: settings.fullScreenHotKeyEnabled
            )
        case .instantWindow:
            return HotKeySlot(
                id: id,
                keyCode: binding(\.instantWindowHotKeyKeyCode),
                modifiers: binding(\.instantWindowHotKeyModifiers),
                defaultConfiguration: .instantWindow,
                isEnabled: settings.instantWindowHotKeyEnabled
            )
        case .instantFullScreen:
            return HotKeySlot(
                id: id,
                keyCode: binding(\.instantFullScreenHotKeyKeyCode),
                modifiers: binding(\.instantFullScreenHotKeyModifiers),
                defaultConfiguration: .instantFullScreen,
                isEnabled: settings.instantFullScreenHotKeyEnabled
            )
        case .scroll:
            return HotKeySlot(
                id: id,
                keyCode: binding(\.scrollHotKeyKeyCode),
                modifiers: binding(\.scrollHotKeyModifiers),
                defaultConfiguration: .scroll,
                isEnabled: settings.scrollHotKeyEnabled
            )
        case .record:
            return HotKeySlot(
                id: id,
                keyCode: binding(\.recordHotKeyKeyCode),
                modifiers: binding(\.recordHotKeyModifiers),
                defaultConfiguration: .record,
                isEnabled: settings.recordHotKeyEnabled
            )
        case .ocr:
            return HotKeySlot(
                id: id,
                keyCode: binding(\.ocrHotKeyKeyCode),
                modifiers: binding(\.ocrHotKeyModifiers),
                defaultConfiguration: .ocr,
                isEnabled: settings.ocrHotKeyEnabled
            )
        case .colorPicker:
            return HotKeySlot(
                id: id,
                keyCode: binding(\.colorPickerHotKeyKeyCode),
                modifiers: binding(\.colorPickerHotKeyModifiers),
                defaultConfiguration: .colorPicker,
                isEnabled: settings.colorPickerHotKeyEnabled
            )
        case .keyDisplay:
            return HotKeySlot(
                id: id,
                keyCode: binding(\.keyDisplayHotKeyKeyCode),
                modifiers: binding(\.keyDisplayHotKeyModifiers),
                defaultConfiguration: .unbound,
                isEnabled: settings.keyDisplayHotKeyEnabled
            )
        case .beautify:
            return HotKeySlot(
                id: id,
                keyCode: binding(\.beautifyHotKeyKeyCode),
                modifiers: binding(\.beautifyHotKeyModifiers),
                defaultConfiguration: .beautify,
                isEnabled: settings.beautifyHotKeyEnabled
            )
        case .capturePreset:
            return HotKeySlot(
                id: id,
                keyCode: binding(\.capturePresetHotKeyKeyCode),
                modifiers: binding(\.capturePresetHotKeyModifiers),
                defaultConfiguration: .capturePreset,
                isEnabled: true
            )
        case .delayCapture:
            return HotKeySlot(
                id: id,
                keyCode: binding(\.delayCaptureHotKeyKeyCode),
                modifiers: binding(\.delayCaptureHotKeyModifiers),
                defaultConfiguration: .delayCapture,
                isEnabled: true
            )
        case .multiWindow:
            return HotKeySlot(
                id: id,
                keyCode: binding(\.multiWindowHotKeyKeyCode),
                modifiers: binding(\.multiWindowHotKeyModifiers),
                defaultConfiguration: .multiWindowCapture,
                isEnabled: true
            )
        case .camera:
            return HotKeySlot(
                id: id,
                keyCode: binding(\.cameraHotKeyKeyCode),
                modifiers: binding(\.cameraHotKeyModifiers),
                defaultConfiguration: .cameraOverlay,
                isEnabled: true
            )
        case .openSettings:
            return HotKeySlot(
                id: id,
                keyCode: binding(\.openSettingsHotKeyKeyCode),
                modifiers: binding(\.openSettingsHotKeyModifiers),
                defaultConfiguration: .openSettings,
                isEnabled: true
            )
        case .toolMove, .toolArrow, .toolRectangle, .toolEllipse,
             .toolLine, .toolPencil, .toolHighlighter, .toolMosaic,
             .toolText, .toolNote, .toolCounter, .toolSticker:
            // Handled by the `annotationTool` branch above; this keeps the
            // switch exhaustive without duplicating the mapping.
            fatalError("annotation tool row handled before the switch")
        }
    }

    private func conflictLabel(for id: HotKeyBindingID) -> String? {
        HotKeyConflicts.duplicateLabel(for: id.rawValue, among: hotKeySlots.map(\.binding))
    }

    // MARK: - Page scaffolding

    /// Big title + one-line description, the same header every other page uses.
    private func pageHeader(_ subtitle: String) -> some View {
        // `.center` keeps the trailing primary action (`开始截图`) centred on
        // the title block instead of pinning it to the title's cap line.
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: SettingsPageMetrics.headerTitleSpacing) {
                Text(section.title)
                    .font(.system(size: 26, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let action {
                // `.borderedProminent` with a `Color.primary` tint resolves to
                // AppKit's own white pill (the tint does not survive the
                // control's own bezel drawing), which is the same pure-white
                // slab the owner rejected on 去授权 / 检查. The header verb now
                // wears the row buttons' primary capsule one step taller.
                NeutralCapsuleButton(
                    title: action.title,
                    symbol: action.symbol,
                    emphasis: .primary,
                    height: 28,
                    fontSize: 12,
                    help: action.title,
                    action: action.handler
                )
            }
        }
    }

    /// A titled slab: grey section header plus the rounded row container.
    private func group<Content: View>(
        _ title: String,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeader(title)
            GroupSlab(footer: footer) { content() }
        }
    }

    /// The 已允许 / 未允许 read-out that sits beside a permission row's
    /// buttons. It shares the capsule height so its centre line matches the
    /// button labels, instead of hanging off the row's text baseline.
    private func permissionStatusLabel(_ granted: Bool) -> some View {
        Text(granted ? "已允许" : "未允许")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(granted ? Color.secondary : Color.orange)
            .lineLimit(1)
            .frame(height: NeutralControlMetrics.height)
            .help(granted ? "系统已授权" : "系统尚未授权")
    }

    /// Trailing switch, the way every toggle row in the app does it.
    private func toggle(_ isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn)
            .labelsHidden()
            .toggleStyle(NeutralSwitchStyle())
    }

    /// One scrolling page with the header pinned to the top of the content.
    private func page<Content: View>(
        _ subtitle: String,
        maxWidth: CGFloat? = 720,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsPageMetrics.sectionSpacing) {
                pageHeader(subtitle)
                content()
            }
            .padding(.horizontal, 22)
            .padding(.top, SettingsPageMetrics.headerTopPadding)
            .padding(.bottom, 24)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - 截图

    private var regionCaptureTab: some View {
        page("区域截图的快捷键与框选行为；保存位置与格式对所有截图生效。") {
            if isSelected(PageGroupID.captureDefault) { captureDefaultGroup }
            if isSelected(PageGroupID.regionHotKey) { regionHotKeyGroup }
            if isSelected(PageGroupID.regionBehavior) { regionBehaviorGroup }
            if isSelected(PageGroupID.screenshotOutput) { screenshotOutputGroup }
            if isSelected(PageGroupID.beautifyCapture) { beautifyCaptureGroup }
        }
    }

    private var captureDefaultGroup: some View {
        group(
            "默认模式",
            footer: "截图页会停在这个模式上；框选在确认之前一直可调。"
        ) {
            GroupRow(
                symbol: "rectangle.dashed",
                color: .green,
                title: "默认截图模式",
                subtitle: settings.defaultCaptureModeValue.detail
            ) {
                NeutralSegmentedControl(
                    items: CaptureMode.allCases,
                    selection: Binding(
                        get: { settings.defaultCaptureModeValue },
                        set: { settings.defaultCaptureMode = $0.rawValue }
                    ),
                    title: { mode in
                        switch mode {
                        case .region: "截图"
                        case .window: "窗口"
                        case .fullScreen: "全屏"
                        }
                    }
                )
                .fixedSize()
            }
        }
    }

    private var regionHotKeyGroup: some View {
        group(
            "快捷键",
            footer: "走系统 Hot Key API，不需要辅助功能权限。"
        ) {
            GroupRow(
                symbol: "command",
                color: .indigo,
                title: "启用区域截图快捷键",
                subtitle: "关掉后区域截图只从菜单触发"
            ) {
                toggle(Binding(
                    get: { settings.screenshotHotKeyEnabled },
                    set: {
                        settings.screenshotHotKeyEnabled = $0
                        model.hotKeySettingsDidChange()
                    }
                ))
            }

            GroupDivider()

            GroupRow(
                symbol: "camera.viewfinder",
                color: .green,
                title: "区域截图",
                subtitle: "框选任意区域，回车拷贝"
            ) {
                HotKeyRecorderView(
                    keyCode: binding(\.screenshotHotKeyKeyCode),
                    modifiers: binding(\.screenshotHotKeyModifiers),
                    defaultConfiguration: .screenshot,
                    conflictLabel: conflictLabel(for: .region)
                ) { model.hotKeySettingsDidChange() }
            }

            if let error = model.hotKeyError {
                GroupDivider()
                GroupRow(symbol: "exclamationmark.triangle.fill", color: .orange, title: error)
            }
        }
    }

    private var regionBehaviorGroup: some View {
        group(
            "框选行为",
            footer: "十字线只影响区域框选；截取光标决定截图里是否包含鼠标指针。"
        ) {
            GroupRow(
                symbol: "plus.viewfinder",
                color: .mint,
                title: "显示十字线"
            ) {
                toggle(binding(\.showCrosshair))
            }

            GroupDivider()

            GroupRow(
                symbol: "plus.magnifyingglass",
                color: .indigo,
                title: "显示放大镜",
                subtitle: "框选时在光标旁放大显示 \(Int(LoupeView.zoom))× 细节"
            ) {
                toggle(binding(\.showLoupe))
            }

            GroupDivider()

            GroupRow(symbol: "cursorarrow", color: .teal, title: "截取光标") {
                toggle(binding(\.captureCursor))
            }

            GroupDivider()

            GroupRow(
                symbol: "speaker.wave.2.fill",
                color: .purple,
                title: "截图提示音"
            ) {
                toggle(binding(\.captureSound))
            }
        }
    }

    private var screenshotOutputGroup: some View {
        group(
            "保存 & 动作",
            footer: "截图默认先进入剪贴板历史；「保存」和即时截图的「同时保存一份」都会写入下面的文件夹。圆角 / 阴影只加在导出图上，覆盖层预览和选区边框保持不变。"
        ) {
            GroupRow(symbol: "doc.badge.gearshape", color: .blue, title: "保存格式") {
                NeutralSegmentedControl(
                    items: ["png", "jpg"],
                    selection: binding(\.captureFormat),
                    title: { $0 == "png" ? "PNG" : "JPEG" }
                )
            }

            GroupDivider()

            GroupRow(
                symbol: "folder.fill",
                color: .indigo,
                title: "保存位置"
            ) {
                HStack(spacing: 8) {
                    NeutralCapsuleMenu(
                        items: Self.directorySelections,
                        selection: captureDirectorySelection,
                        title: directoryTitle(for:),
                        width: 112,
                        help: "选择默认保存文件夹"
                    )
                    NeutralCapsuleButton(
                        title: "选择…",
                        help: "用文件夹面板选择保存位置"
                    ) {
                        chooseDirectory()
                    }
                }
            }

            GroupDivider()

            GroupRow(symbol: "text.alignleft", color: .gray, title: "路径", value: settings.captureDirectory.path)

            GroupDivider()

            // 导出图自身的外观（iShot 的 needFillet / needShadow）。These are
            // export-only: the capture overlay keeps showing raw pixels and no
            // selection border is ever rounded.
            GroupRow(
                symbol: "rectangle.roundedtop",
                color: .pink,
                title: "截图圆角",
                subtitle: "只作用于拷贝 / 保存 / 钉图的导出图"
            ) {
                toggle(binding(\.captureCornerRadiusEnabled))
            }

            if settings.captureCornerRadiusEnabled {
                GroupDivider()
                exportSlider(
                    title: "圆角半径",
                    value: binding(\.captureCornerRadius),
                    range: 0...AppSettings.maxExportCornerRadius,
                    unit: "pt"
                )
            }

            GroupDivider()

            GroupRow(
                symbol: "shadow",
                color: .purple,
                title: "截图阴影",
                subtitle: "在导出图四周留出投影空间，覆盖层预览不受影响"
            ) {
                toggle(binding(\.captureShadowEnabled))
            }

            if settings.captureShadowEnabled {
                GroupDivider()
                exportSlider(
                    title: "阴影强度",
                    value: binding(\.captureShadowSize),
                    range: 1...AppSettings.maxExportShadowSize,
                    unit: "pt"
                )
            }

            GroupDivider()

            // The old combined capture page owned this status; the page is now this
            // settings page, so the permission lives here (it applies to every
            // mode, and this is the page that owns the shared 保存 & 动作 rows).
            GroupRow(
                symbol: screenRecordingGranted ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
                color: screenRecordingGranted ? .green : .orange,
                title: "屏幕录制权限",
                subtitle: screenRecordingGranted ? "已授权，可以截图" : "未授权，截图会失败"
            ) {
                HStack(spacing: 8) {
                    NeutralCapsuleButton(
                        title: screenRecordingGranted ? "重新检查" : "请求权限",
                        symbol: "arrow.clockwise",
                        emphasis: .primary,
                        help: screenRecordingGranted ? "重新读取屏幕录制授权" : "向系统请求屏幕录制授权"
                    ) {
                        requestScreenRecordingPermission()
                    }
                    NeutralCapsuleButton(
                        title: "打开设置",
                        symbol: "gearshape",
                        help: "打开系统设置的屏幕录制面板"
                    ) {
                        ScreenCapture.openScreenRecordingSettings()
                    }
                    permissionStatusLabel(screenRecordingGranted)
                }
            }
        }
    }

    /// First-run path, shared by the 截图 page: ask the system, then reflect
    /// whatever the current state is. The coordinator also requests on start.
    private func requestScreenRecordingPermission() {
        if !ScreenCapture.hasScreenRecordingPermission {
            ScreenCapture.requestScreenRecordingPermission()
        }
        refreshPermissions()
    }

    /// One labelled slider row for the export-only 圆角 / 阴影 settings.
    private func exportSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        unit: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 8)
                Text("\(Int(value.wrappedValue.rounded())) \(unit)")
                    .font(.system(size: 11, design: .monospaced))
                    // The read-out is the only numeric feedback for the slider;
                    // `.tertiary` made it fade into the slab in dark.
                    .foregroundStyle(SupportingInk.text)
            }
            Slider(value: value, in: range)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var beautifyCaptureGroup: some View {
        group(
            "套壳 / 美化",
            footer: "框选后调留白、圆角、阴影；这个快捷键入口可以单独关掉。"
        ) {
            GroupRow(
                symbol: "sparkles.rectangle.stack",
                color: .purple,
                title: "启用美化截图快捷键",
                subtitle: "关掉后只从菜单「截图 → 套壳 / 美化」触发"
            ) {
                toggle(Binding(
                    get: { settings.beautifyHotKeyEnabled },
                    set: {
                        settings.beautifyHotKeyEnabled = $0
                        model.hotKeySettingsDidChange()
                    }
                ))
            }

            GroupDivider()

            GroupRow(
                symbol: "sparkles.rectangle.stack",
                color: .purple,
                title: "套壳 / 美化截图"
            ) {
                HotKeyRecorderView(
                    keyCode: binding(\.beautifyHotKeyKeyCode),
                    modifiers: binding(\.beautifyHotKeyModifiers),
                    defaultConfiguration: .beautify,
                    conflictLabel: conflictLabel(for: .beautify)
                ) { model.hotKeySettingsDidChange() }
            }
        }
    }

    // MARK: - 窗口截图

    private var windowCaptureTab: some View {
        page("窗口截图悬停高亮、单击确认；即时窗口不显示覆盖层、不抢焦点。") {
            if isSelected(PageGroupID.windowHotKey) { windowHotKeyGroup }
        }
    }

    private var windowHotKeyGroup: some View {
        group(
            "快捷键",
            footer: "窗口截图是悬停高亮、单击确认的覆盖层；即时窗口不显示覆盖层、不抢焦点。两项各自独立绑定。"
        ) {
            GroupRow(
                symbol: "macwindow",
                color: .cyan,
                title: "启用窗口截图快捷键",
                subtitle: "从菜单「截图 → 窗口截图」也能进入"
            ) {
                toggle(Binding(
                    get: { settings.windowHotKeyEnabled },
                    set: {
                        settings.windowHotKeyEnabled = $0
                        model.hotKeySettingsDidChange()
                    }
                ))
            }

            GroupDivider()

            GroupRow(
                symbol: "macwindow",
                color: .cyan,
                title: "窗口截图"
            ) {
                HotKeyRecorderView(
                    keyCode: binding(\.windowHotKeyKeyCode),
                    modifiers: binding(\.windowHotKeyModifiers),
                    defaultConfiguration: .windowCapture,
                    conflictLabel: conflictLabel(for: .window)
                ) { model.hotKeySettingsDidChange() }
            }

            GroupDivider()

            GroupRow(
                symbol: "macwindow.on.rectangle",
                color: .indigo,
                title: "启用即时窗口快捷键"
            ) {
                toggle(Binding(
                    get: { settings.instantWindowHotKeyEnabled },
                    set: {
                        settings.instantWindowHotKeyEnabled = $0
                        model.hotKeySettingsDidChange()
                    }
                ))
            }

            GroupDivider()

            GroupRow(
                symbol: "macwindow.on.rectangle",
                color: .indigo,
                title: "即时窗口截图",
                subtitle: "鼠标下最上层的窗口"
            ) {
                HotKeyRecorderView(
                    keyCode: binding(\.instantWindowHotKeyKeyCode),
                    modifiers: binding(\.instantWindowHotKeyModifiers),
                    defaultConfiguration: .instantWindow,
                    conflictLabel: conflictLabel(for: .instantWindow)
                ) { model.hotKeySettingsDidChange() }
            }
        }
    }

    // MARK: - 固定大小截图

    private var fixedSizeCaptureTab: some View {
        page("固定宽高的居中选区，仍可微调。") {
            if isSelected(PageGroupID.fixedSizePreset) { fixedSizePresetGroup }
        }
    }

    private var fixedSizePresetGroup: some View {
        group(
            "预设尺寸",
            footer: "菜单「截图 → 预设区域尺寸截图」与截图页的固定大小模式都用这里的宽高。"
        ) {
            GroupRow(
                symbol: "rectangle.dashed",
                color: .green,
                title: "预设尺寸",
                subtitle: "居中选区，仍可微调"
            ) {
                HStack(spacing: 5) {
                    TextField("宽", value: binding(\.presetCaptureWidth), format: .number)
                        .multilineTextAlignment(.center)
                        .neutralCapsuleField(width: 58)
                    Text("×").foregroundStyle(.secondary)
                    TextField("高", value: binding(\.presetCaptureHeight), format: .number)
                        .multilineTextAlignment(.center)
                        .neutralCapsuleField(width: 58)
                }
                .fixedSize()
            }
        }
    }

    // MARK: - 全屏截图

    private var fullScreenCaptureTab: some View {
        page("全屏截图的快捷键、即时截图的反馈，以及延时截图。") {
            if isSelected(PageGroupID.fullScreenHotKey) { fullScreenHotKeyGroup }
            if isSelected(PageGroupID.instantFeedback) { instantFeedbackGroup }
            if isSelected(PageGroupID.fullScreenDelay) { fullScreenDelayGroup }
        }
    }

    private var fullScreenHotKeyGroup: some View {
        group(
            "快捷键",
            footer: "全屏截图走模式入口；即时全屏不显示覆盖层、不抢焦点。两项各自独立绑定。"
        ) {
            GroupRow(
                symbol: "rectangle.inset.filled",
                color: .green,
                title: "启用全屏截图快捷键",
                subtitle: "从菜单「截图 → 全屏截图」也能进入"
            ) {
                toggle(Binding(
                    get: { settings.fullScreenHotKeyEnabled },
                    set: {
                        settings.fullScreenHotKeyEnabled = $0
                        model.hotKeySettingsDidChange()
                    }
                ))
            }

            GroupDivider()

            GroupRow(
                symbol: "rectangle.inset.filled",
                color: .green,
                title: "全屏截图"
            ) {
                HotKeyRecorderView(
                    keyCode: binding(\.fullScreenHotKeyKeyCode),
                    modifiers: binding(\.fullScreenHotKeyModifiers),
                    defaultConfiguration: .fullScreenCapture,
                    conflictLabel: conflictLabel(for: .fullScreen)
                ) { model.hotKeySettingsDidChange() }
            }

            GroupDivider()

            GroupRow(
                symbol: "bolt.fill",
                color: .yellow,
                title: "启用即时全屏快捷键"
            ) {
                toggle(Binding(
                    get: { settings.instantFullScreenHotKeyEnabled },
                    set: {
                        settings.instantFullScreenHotKeyEnabled = $0
                        model.hotKeySettingsDidChange()
                    }
                ))
            }

            GroupDivider()

            GroupRow(
                symbol: "bolt.fill",
                color: .yellow,
                title: "即时全屏截图"
            ) {
                HotKeyRecorderView(
                    keyCode: binding(\.instantFullScreenHotKeyKeyCode),
                    modifiers: binding(\.instantFullScreenHotKeyModifiers),
                    defaultConfiguration: .instantFullScreen,
                    conflictLabel: conflictLabel(for: .instantFullScreen)
                ) { model.hotKeySettingsDidChange() }
            }
        }
    }

    private var instantFeedbackGroup: some View {
        group(
            "即时反馈",
            footer: "即时窗口与即时全屏共用这些反馈；区域 / 窗口覆盖层另有「截图提示音」。"
        ) {
            GroupRow(
                symbol: "speaker.wave.2.fill",
                color: .blue,
                title: "提示音",
                subtitle: "截完后播一下系统 Grab 声，默认开启"
            ) {
                toggle(binding(\.instantCaptureSound))
            }

            GroupDivider()

            GroupRow(
                symbol: "circle.dotted",
                color: .pink,
                title: "视觉提示",
                subtitle: "鼠标处闪一圈细边，约 0.25 秒淡出；不拦截任何点击"
            ) {
                toggle(binding(\.instantCaptureVisualCue))
            }

            GroupDivider()

            GroupRow(
                symbol: "square.and.arrow.down",
                color: .green,
                title: "同时保存一份",
                subtitle: "除剪贴板外，再静默写入保存位置的截图文件夹"
            ) {
                toggle(binding(\.instantCaptureAlsoSave))
            }
        }
    }

    private var fullScreenDelayGroup: some View {
        group(
            "延时截图",
            footer: "倒计时结束后截取鼠标所在屏幕，菜单「截图 → 延时截图」触发。"
        ) {
            GroupRow(
                symbol: "timer",
                color: .orange,
                title: "倒计时"
            ) {
                NeutralCapsuleMenu(
                    items: AppSettings.delayOptions,
                    selection: binding(\.timeOfDelayScreenshots),
                    title: { "\($0) 秒" },
                    width: 92,
                    help: "选择延时截图的倒计时"
                )
            }
        }
    }

    // MARK: - 标注

    private var annotationTab: some View {
        page("下一次标注使用的颜色、线宽、字号，以及工具栏里显示哪些工具。") {
            if isSelected(PageGroupID.annotationStyle) { annotationStyleGroup }
            if isSelected(PageGroupID.annotationTools) { annotationToolsGroup }
        }
    }

    private var annotationStyleGroup: some View {
        group(
            "默认样式",
            footer: "只影响之后画出的标注，已经画好的内容不会变。"
        ) {
            GroupRow(
                symbol: "paintpalette.fill",
                color: .pink,
                title: "默认颜色",
                subtitle: settings.annotationColorHex.isEmpty
                    ? "跟随各工具的内置颜色"
                    : "#\(settings.annotationColorHex.uppercased())"
            ) {
                AnnotationColorSwatches(
                    selected: AnnotationDefaults.parseHex(settings.annotationColorHex)
                ) { color in
                    settings.annotationColorHex = AnnotationDefaults.hexString(of: color)
                }
                NeutralCapsuleButton(
                    title: "跟随工具",
                    help: "让每个标注工具用它自己的内置颜色"
                ) {
                    settings.annotationColorHex = ""
                    flash("颜色已跟随工具默认值")
                }
            }

            GroupDivider()

            GroupRow(
                symbol: "line.diagonal",
                color: .orange,
                title: "默认线宽",
                subtitle: settings.annotationLineWidth > 0
                    ? "\(String(format: "%.1f", settings.annotationLineWidth)) pt"
                    : "跟随各工具的内置线宽"
            ) {
                NeutralCapsuleMenu(
                    items: [0.0, 1.5, 2.0, 2.5, 3.0, 4.0, 6.0, 8.0, 12.0],
                    selection: binding(\.annotationLineWidth),
                    title: { $0 == 0 ? "跟随工具" : String(format: "%.1f pt", $0) },
                    width: 104,
                    help: "选择下一次标注的默认线宽"
                )
            }

            GroupDivider()

            GroupRow(
                symbol: "textformat.size",
                color: .indigo,
                title: "默认字号",
                subtitle: "文字与备注工具"
            ) {
                NeutralCapsuleMenu(
                    items: [12.0, 14.0, 16.0, 20.0, 24.0, 32.0, 40.0],
                    selection: binding(\.annotationFontSize),
                    title: { "\(Int($0)) pt" },
                    width: 88,
                    help: "选择文字与备注工具的默认字号"
                )
            }
        }
    }

    private var annotationToolsGroup: some View {
        group(
            "工具栏",
            footer: "移动工具不能隐藏；隐藏的工具只是不出现在截图工具栏里，已有标注与撤销不受影响。"
        ) {
            ForEach(Array(orderedAnnotationTools.enumerated()), id: \.element) { index, tool in
                annotationToolRow(tool)

                if index < orderedAnnotationTools.count - 1 {
                    GroupDivider()
                }
            }
        }
    }

    private func annotationToolRow(_ tool: AnnotationTool) -> some View {
        let hidden = settings.annotationHiddenTools.contains(tool.rawValue)
        return GroupRow(
            symbol: tool.symbol,
            color: .gray,
            title: tool.title,
            subtitle: tool == .move ? "选择与移动选区" : nil,
            isEnabled: tool != .move || !hidden
        ) {
            HStack(spacing: 4) {
                Button {
                    moveAnnotationTool(tool, offset: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)
                .disabled(orderedAnnotationTools.first == tool)

                Button {
                    moveAnnotationTool(tool, offset: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain)
                .disabled(orderedAnnotationTools.last == tool)

                Toggle("", isOn: Binding(
                    get: { !hidden },
                    set: { setToolHidden(tool, hidden: !$0) }
                ))
                .labelsHidden()
                // Same monochrome switch as every other toggle row: the
                // system `.switch` paints the on state in the accent colour,
                // the one blue slab the app's whole control language avoids.
                .toggleStyle(NeutralSwitchStyle())
                .disabled(tool == .move)
            }
        }
    }

    private var orderedAnnotationTools: [AnnotationTool] {
        var order: [AnnotationTool] = []
        for raw in settings.annotationToolOrder {
            guard let tool = AnnotationTool(rawValue: raw), !order.contains(tool) else { continue }
            order.append(tool)
        }
        for tool in AnnotationTool.allCases where !order.contains(tool) {
            order.append(tool)
        }
        return order
    }

    private func moveAnnotationTool(_ tool: AnnotationTool, offset: Int) {
        var order = orderedAnnotationTools
        guard let index = order.firstIndex(of: tool) else { return }
        let target = index + offset
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
        settings.annotationToolOrder = order.map(\.rawValue)
    }

    private func setToolHidden(_ tool: AnnotationTool, hidden: Bool) {
        guard tool != .move else { return }
        var hiddenTools = settings.annotationHiddenTools
        if hidden {
            if !hiddenTools.contains(tool.rawValue) { hiddenTools.append(tool.rawValue) }
        } else {
            hiddenTools.removeAll { $0 == tool.rawValue }
        }
        settings.annotationHiddenTools = hiddenTools
    }

    // MARK: - 滚图

    private var scrollTab: some View {
        page("长截图的采样节奏、自动结束条件和状态卡；拼接算法保持固定参数。") {
            if isSelected(PageGroupID.scrollBehavior) { scrollBehaviorGroup }
            if isSelected(PageGroupID.scrollAlgorithm) { scrollAlgorithmGroup }
        }
    }

    private var scrollBehaviorGroup: some View {
        group(
            "捕获",
            footer: "默认每 0.35 秒抓一帧，达到上限自动拼接结束；再按一次同一个快捷键也会结束。"
        ) {
            GroupRow(
                symbol: "timer",
                color: .orange,
                title: "采样间隔",
                subtitle: "越短越稳，帧数更多"
            ) {
                NeutralSegmentedControl(
                    items: [0.2, 0.35, 0.5, 1.0],
                    selection: binding(\.scrollCaptureInterval),
                    title: { $0 == 1.0 ? "1 秒" : "\(String(format: "%.2g", $0)) 秒" }
                )
                .fixedSize()
            }

            GroupDivider()

            GroupRow(
                symbol: "stop.circle",
                color: .red,
                title: "自动结束"
            ) {
                NeutralCapsuleMenu(
                    items: [50, 100, 200, 400, 800],
                    selection: binding(\.scrollCaptureMaxFrames),
                    title: { "\($0) 帧" },
                    width: 100,
                    help: "选择长截图自动结束的帧数上限"
                )
            }

            GroupDivider()

            GroupRow(
                symbol: "rectangle.topthird.inset.filled",
                color: .blue,
                title: "显示进度卡片",
                subtitle: "录制中显示帧数、已捕获高度与「完成 / 取消」"
            ) {
                toggle(binding(\.scrollCaptureShowsHUD))
            }

            GroupDivider()

            GroupRow(
                symbol: "command",
                color: .indigo,
                title: "启用滚动截图快捷键",
                subtitle: "关掉后只从菜单「截图 → 滚动截图」触发"
            ) {
                toggle(Binding(
                    get: { settings.scrollHotKeyEnabled },
                    set: {
                        settings.scrollHotKeyEnabled = $0
                        model.hotKeySettingsDidChange()
                    }
                ))
            }

            GroupDivider()

            GroupRow(
                symbol: "command",
                color: .indigo,
                title: "滚动截图快捷键",
                subtitle: "再按一次结束并拼接"
            ) {
                HotKeyRecorderView(
                    keyCode: binding(\.scrollHotKeyKeyCode),
                    modifiers: binding(\.scrollHotKeyModifiers),
                    defaultConfiguration: .scroll,
                    conflictLabel: conflictLabel(for: .scroll)
                ) { model.hotKeySettingsDidChange() }
            }
        }
    }

    private var scrollAlgorithmGroup: some View {
        group(
            "拼接参数",
            footer: "参数由像素列比对算法固定，保证「冻结页面不增长、重复分隔线不会被当成滚动」；这里只展示，不提供会降低可靠性的开关。"
        ) {
            GroupRow(
                symbol: "square.grid.3x3",
                color: .teal,
                title: "每行采样点",
                subtitle: "横向均匀取 180 个点参与比对",
                value: "\(ScrollStitcher.sampleColumns)"
            )

            GroupDivider()

            GroupRow(
                symbol: "square.stack.3d.up",
                color: .purple,
                title: "采样行数",
                subtitle: "每个候选重叠比较 24 行",
                value: "\(ScrollStitcher.sampleRows)"
            )

            GroupDivider()

            GroupRow(
                symbol: "arrow.up.and.down",
                color: .indigo,
                title: "最小重叠",
                subtitle: "更小的「匹配」通常只是重复的分隔线",
                value: "\(ScrollStitcher.minimumOverlap) px"
            )

            GroupDivider()

            GroupRow(
                symbol: "equal.circle",
                color: .orange,
                title: "像素容差",
                subtitle: "单通道差超过它即视为不同；允许抗锯齿与光标闪烁",
                value: "\(ScrollStitcher.differenceTolerance) / 255"
            )

            GroupDivider()

            GroupRow(
                symbol: "arrow.up.to.line",
                color: .red,
                title: "输出高度上限",
                subtitle: "超过后停止追加，避免一次分配几百 MB",
                value: "\(ScrollStitcher.maximumOutputHeight) px"
            )
        }
    }

    // MARK: - 录屏

    private var recordingTab: some View {
        page("H.264 录屏的格式、帧率、码率、麦克风与保存位置。") {
            if isSelected(PageGroupID.recordingEncode) { recordingEncodeGroup }
            if isSelected(PageGroupID.recordingOutput) { recordingOutputGroup }
        }
    }

    private var recordingEncodeGroup: some View {
        group(
            "编码",
            footer: "H.264 编码；录制中状态栏显示红点与计时，可随时暂停，暂停时间不计入时长。"
        ) {
            GroupRow(symbol: "film.fill", color: .red, title: "格式") {
                NeutralSegmentedControl(
                    items: RecordingFormat.allCases.map(\.rawValue),
                    selection: binding(\.recordingFormat),
                    title: { RecordingFormat(rawValue: $0)?.title ?? $0 }
                )
            }

            GroupDivider()

            GroupRow(
                symbol: "speedometer",
                color: .orange,
                title: "帧率",
                subtitle: "\(settings.recordingFrameRate) fps"
            ) {
                NeutralCapsuleMenu(
                    items: RecordingConfiguration.frameRateOptions,
                    selection: binding(\.recordingFrameRate),
                    title: { "\($0) fps" },
                    width: 100,
                    help: "选择录屏帧率"
                )
            }

            GroupDivider()

            GroupRow(
                symbol: "gauge.with.dots.needle.67percent",
                color: .blue,
                title: "码率",
                subtitle: RecordingConfiguration.bitrateLabel(settings.recordingBitrate)
            ) {
                NeutralCapsuleMenu(
                    items: RecordingConfiguration.bitrateOptions,
                    selection: binding(\.recordingBitrate),
                    title: RecordingConfiguration.bitrateLabel,
                    width: 100,
                    help: "选择录屏码率"
                )
            }

            GroupDivider()

            GroupRow(
                symbol: "mic.fill",
                color: .purple,
                title: "录制麦克风",
                subtitle: "macOS 15+；未授权时自动只录画面"
            ) {
                toggle(binding(\.recordingMicrophone))
            }
        }
    }

    private var recordingOutputGroup: some View {
        group(
            "输出与权限",
            footer: "录像与截图放在同一目录；开始 / 停止用上面的快捷键。"
        ) {
            GroupRow(
                symbol: "folder.fill",
                color: .indigo,
                title: "保存位置",
                subtitle: "与截图共用"
            ) {
                HStack(spacing: 8) {
                    NeutralCapsuleMenu(
                        items: Self.directorySelections,
                        selection: captureDirectorySelection,
                        title: directoryTitle(for:),
                        width: 112,
                        help: "选择默认保存文件夹"
                    )
                    NeutralCapsuleButton(
                        title: "选择…",
                        help: "用文件夹面板选择保存位置"
                    ) {
                        chooseDirectory()
                    }
                }
            }

            GroupDivider()

            GroupRow(
                symbol: screenRecordingGranted ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
                color: screenRecordingGranted ? .green : .orange,
                title: "屏幕录制权限",
                subtitle: screenRecordingGranted ? "已授权，可以录制" : "未授权，录制会失败"
            ) {
                HStack(spacing: 8) {
                    NeutralCapsuleButton(
                        title: "检查",
                        symbol: "arrow.clockwise",
                        emphasis: .primary,
                        help: "重新读取屏幕录制授权"
                    ) {
                        refreshPermissions()
                    }
                    NeutralCapsuleButton(
                        title: "打开设置",
                        symbol: "gearshape",
                        help: "打开系统设置的屏幕录制面板"
                    ) {
                        ScreenCapture.openScreenRecordingSettings()
                    }
                    permissionStatusLabel(screenRecordingGranted)
                }
            }

            GroupDivider()

            GroupRow(
                symbol: "command",
                color: .indigo,
                title: "启用录屏快捷键",
                subtitle: "关掉后只从菜单启动录制"
            ) {
                toggle(Binding(
                    get: { settings.recordHotKeyEnabled },
                    set: {
                        settings.recordHotKeyEnabled = $0
                        model.hotKeySettingsDidChange()
                    }
                ))
            }

            GroupDivider()

            GroupRow(
                symbol: "command",
                color: .indigo,
                title: "录屏快捷键",
                subtitle: "开始 / 停止整屏录制"
            ) {
                HotKeyRecorderView(
                    keyCode: binding(\.recordHotKeyKeyCode),
                    modifiers: binding(\.recordHotKeyModifiers),
                    defaultConfiguration: .record,
                    conflictLabel: conflictLabel(for: .record)
                ) { model.hotKeySettingsDidChange() }
            }
        }
    }

    // MARK: - OCR

    private var ocrTab: some View {
        page("Vision 的识别语言、条码检测，以及结果窗口的行为。") {
            if isSelected(PageGroupID.ocrLanguage) { ocrLanguageGroup }
            if isSelected(PageGroupID.ocrBehavior) { ocrBehaviorGroup }
        }
    }

    private var ocrLanguageGroup: some View {
        group(
            "语言",
            footer: "语言包缺失时会自动退回 English，不会丢掉整次识别。"
        ) {
            GroupRow(
                symbol: "character.book.closed",
                color: .teal,
                title: "识别语言",
                subtitle: "混合排版建议中英"
            ) {
                NeutralSegmentedControl(
                    items: Self.ocrLanguageOptions.map(\.value),
                    selection: binding(\.ocrLanguage),
                    title: { value in
                        Self.ocrLanguageOptions.first { $0.value == value }?.title ?? value
                    }
                )
                .fixedSize()
            }

            GroupDivider()

            GroupRow(
                symbol: "command",
                color: .indigo,
                title: "启用识别文字快捷键",
                subtitle: "关掉后只从菜单「截图 → 识别文字」触发"
            ) {
                toggle(Binding(
                    get: { settings.ocrHotKeyEnabled },
                    set: {
                        settings.ocrHotKeyEnabled = $0
                        model.hotKeySettingsDidChange()
                    }
                ))
            }

            GroupDivider()

            GroupRow(
                symbol: "command",
                color: .indigo,
                title: "识别文字快捷键",
                subtitle: "框选后直接识别"
            ) {
                HotKeyRecorderView(
                    keyCode: binding(\.ocrHotKeyKeyCode),
                    modifiers: binding(\.ocrHotKeyModifiers),
                    defaultConfiguration: .ocr,
                    conflictLabel: conflictLabel(for: .ocr)
                ) { model.hotKeySettingsDidChange() }
            }
        }
    }

    private var ocrBehaviorGroup: some View {
        group(
            "识别与结果",
            footer: "结果窗口的文字可选、可复制，高度上限 500 pt；条码/二维码结果排在最前。"
        ) {
            GroupRow(
                symbol: "barcode.viewfinder",
                color: .blue,
                title: "同时识别条码 / 二维码",
                subtitle: "QR、Code128、EAN 等常见码制"
            ) {
                toggle(binding(\.ocrDetectBarcodes))
            }

            GroupDivider()

            GroupRow(
                symbol: "doc.on.clipboard",
                color: .green,
                title: "识别后直接复制并关闭",
                subtitle: "跳过结果窗口；适合只想要文字的场景"
            ) {
                toggle(binding(\.ocrAutoCopy))
            }

            GroupDivider()

            GroupRow(
                symbol: "macwindow",
                color: .indigo,
                title: "结果窗口",
                subtitle: "非激活浮层，Esc 关闭，⌘C 复制当前选中的文字"
            )
        }
    }

    // MARK: - 取色器

    private var colorPickerTab: some View {
        page("放大镜的复制格式、快捷键，以及最近拾取的颜色。") {
            if isSelected(PageGroupID.colorPickerFormat) { colorPickerFormatGroup }
            if isSelected(PageGroupID.colorPickerRecent) { colorPickerRecentGroup }
        }
    }

    private var colorPickerFormatGroup: some View {
        group(
            "复制格式",
            footer: "打开放大镜后 Tab 在 HEX / RGB 之间切换；点击复制，Esc 取消。"
        ) {
            GroupRow(
                symbol: "eyedropper.halffull",
                color: .pink,
                title: "默认格式",
                subtitle: settings.colorPickFormat == .hsl
                    ? "HSL，例如 hsl(30, 100%, 50%)"
                    : (settings.colorPickFormat == .hex ? "HEX（#RRGGBB）" : "RGB（rgb(r, g, b)）")
            ) {
                NeutralSegmentedControl(
                    items: ColorPickFormat.allCases,
                    selection: Binding(
                        get: { settings.colorPickFormat },
                        set: { settings.colorPickerFormat = $0.rawValue }
                    ),
                    title: { $0.title }
                )
                .fixedSize()
            }

            GroupDivider()

            GroupRow(
                symbol: "command",
                color: .indigo,
                title: "启用取色器快捷键",
                subtitle: "关掉后只从菜单打开放大镜"
            ) {
                toggle(Binding(
                    get: { settings.colorPickerHotKeyEnabled },
                    set: {
                        settings.colorPickerHotKeyEnabled = $0
                        model.hotKeySettingsDidChange()
                    }
                ))
            }

            GroupDivider()

            GroupRow(
                symbol: "command",
                color: .indigo,
                title: "取色器快捷键",
                subtitle: "可在快捷键行直接修改"
            ) {
                HotKeyRecorderView(
                    keyCode: binding(\.colorPickerHotKeyKeyCode),
                    modifiers: binding(\.colorPickerHotKeyModifiers),
                    defaultConfiguration: .colorPicker,
                    conflictLabel: conflictLabel(for: .colorPicker)
                ) { model.hotKeySettingsDidChange() }
            }

            GroupDivider()

            GroupRow(
                symbol: "camera.metering.center.weighted",
                color: .teal,
                title: "取色数据源",
                subtitle: "启动时抓一张整屏快照，之后只读快照，不会把放大镜截进去"
            )
        }
    }

    private var colorPickerRecentGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeader("最近颜色")
            GroupSlab(footer: "点击色块复制 HEX；最多保留 \(AppSettings.recentPickedColorsLimit) 个。") {
                if settings.recentPickedColors.isEmpty {
                    GroupRow(
                        symbol: "swatchpalette",
                        color: .gray,
                        title: "还没有取过色",
                        subtitle: "用取色快捷键打开放大镜，点一下屏幕"
                    )
                } else {
                    HStack(spacing: 10) {
                        ForEach(settings.recentPickedColors, id: \.self) { hex in
                            Button {
                                copyRecentColor(hex)
                            } label: {
                                VStack(spacing: 4) {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(AnnotationDefaults.parseHex(hex).map { Color(nsColor: $0) } ?? .gray)
                                        .frame(width: 30, height: 30)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                                        )
                                    Text("#\(hex)")
                                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .help("复制 #\(hex)")
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)

                    GroupDivider()

                    GroupRow(
                        symbol: "trash",
                        color: .orange,
                        title: "清空最近颜色"
                    ) {
                        NeutralCapsuleButton(
                            title: "清空",
                            ink: .red,
                            help: "清空最近拾取的颜色"
                        ) {
                            settings.recentPickedColors = []
                        }
                    }
                }
            }
        }
    }

    private func copyRecentColor(_ hex: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("#\(hex)", forType: .string)
        flash("已复制 #\(hex)")
    }

    // MARK: - 按键显示

    private var keyDisplayTab: some View {
        page("录制或截图时在屏幕上显示最近按下的组合键。") {
            if isSelected(PageGroupID.keyDisplayToggle) { keyDisplayToggleGroup }
            if isSelected(PageGroupID.keyDisplayPlacement) { keyDisplayPlacementGroup }
        }
    }

    private var keyDisplayToggleGroup: some View {
        group(
            "开关与权限",
            footer: "通过 CGEventTap 只读监听按键，不拦截也不改写输入。没有辅助功能权限时不会安装监听，也不会反复弹窗。"
        ) {
            GroupRow(
                symbol: "keyboard.fill",
                color: .blue,
                title: "显示按下的按键"
            ) {
                toggle(binding(\.keyDisplayEnabled))
            }

            GroupDivider()

            GroupRow(
                symbol: "command",
                color: .indigo,
                title: "启用按键显示快捷键",
                subtitle: "用一个全局键快速切换按键提示"
            ) {
                toggle(Binding(
                    get: { settings.keyDisplayHotKeyEnabled },
                    set: {
                        settings.keyDisplayHotKeyEnabled = $0
                        model.hotKeySettingsDidChange()
                    }
                ))
            }

            GroupDivider()

            GroupRow(
                symbol: "keyboard",
                color: .indigo,
                title: "按键显示"
            ) {
                HotKeyRecorderView(
                    keyCode: binding(\.keyDisplayHotKeyKeyCode),
                    modifiers: binding(\.keyDisplayHotKeyModifiers),
                    defaultConfiguration: .unbound,
                    conflictLabel: conflictLabel(for: .keyDisplay)
                ) { model.hotKeySettingsDidChange() }
            }

            GroupDivider()

            GroupRow(
                symbol: keyDisplayTrusted ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
                color: keyDisplayTrusted ? .green : .orange,
                title: "辅助功能权限",
                subtitle: keyDisplayTrusted ? "已授权，可以监听按键" : "需要辅助功能权限",
                value: keyDisplayTrusted ? "已允许" : "未允许"
            ) {
                HStack(spacing: 6) {
                    NeutralCapsuleButton(
                        title: "去授权",
                        symbol: "arrow.up.forward.app",
                        help: "打开系统设置，把 Unseen 加进辅助功能列表"
                    ) {
                        KeyEventMonitor.requestAccessibilityPermission()
                        KeyEventMonitor.openAccessibilitySettings()
                        refreshPermissions()
                    }
                    NeutralCapsuleButton(
                        title: "检查",
                        help: "重新读取辅助功能授权状态"
                    ) {
                        refreshPermissions()
                    }
                }
            }
        }
    }

    private var keyDisplayPlacementGroup: some View {
        group(
            "显示位置",
            footer: "快捷键卡片不拦截点击；停留在上面的时长到后会淡出。"
        ) {
            GroupRow(symbol: "rectangle.bottomthird.inset.filled", color: .indigo, title: "显示位置") {
                NeutralCapsuleMenu(
                    items: KeyDisplayPosition.allCases.map(\.rawValue),
                    selection: binding(\.keyDisplayPosition),
                    title: { KeyDisplayPosition(rawValue: $0)?.title ?? $0 },
                    width: 110,
                    help: "选择按键提示出现在屏幕的哪一处"
                )
            }

            GroupDivider()

            GroupRow(
                symbol: "timer",
                color: .orange,
                title: "停留时长",
                subtitle: String(format: "%.0f 秒后淡出", settings.keyDisplayDuration)
            ) {
                NeutralCapsuleMenu(
                    items: [1.0, 2.0, 3.0, 5.0],
                    selection: binding(\.keyDisplayDuration),
                    title: { String(format: "%.0f 秒", $0) },
                    width: 92,
                    help: "选择按键提示停留多久后淡出"
                )
            }
        }
    }

    // MARK: - 摄像头

    private var cameraTab: some View {
        page("录屏时的摄像头画中画：开关、权限、角落与尺寸。") {
            if isSelected(PageGroupID.cameraToggle) { cameraToggleGroup }
            if isSelected(PageGroupID.cameraPlacement) { cameraPlacementGroup }
        }
    }

    private var cameraToggleGroup: some View {
        group(
            "开关与权限",
            footer: "画中画在录屏时自然进入画面；截图和滚动截图会通过 ScreenCapture 的窗口排除机制把它排除。没有摄像头权限时不会反复弹窗，只在这里提示。"
        ) {
            GroupRow(
                symbol: "video.fill",
                color: .teal,
                title: "录屏时显示摄像头",
                subtitle: "开始录屏时自动出现在角落，停止时关闭；菜单里也可手动开关"
            ) {
                toggle(Binding(
                    get: { settings.cameraOverlayEnabled },
                    set: { enabled in
                        settings.cameraOverlayEnabled = enabled
                        model.onCameraSettingsChanged?()
                    }
                ))
            }

            GroupDivider()

            GroupRow(
                symbol: cameraPermission.isAuthorized ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
                color: cameraPermission.isAuthorized ? .green : .orange,
                title: "摄像头权限",
                subtitle: cameraPermission.subtitle,
                value: cameraPermission.title
            ) {
                HStack(spacing: 6) {
                    if cameraPermission == .notDetermined {
                        NeutralCapsuleButton(
                            title: "请求权限",
                            symbol: "video",
                            emphasis: .primary,
                            help: "向系统请求摄像头授权"
                        ) {
                            Task { @MainActor in
                                _ = await CameraPermission.requestAccess()
                                cameraPermission = CameraPermission.current
                                flash(cameraPermission.isAuthorized ? "已获得摄像头权限" : "未获得摄像头权限")
                            }
                        }
                    } else {
                        NeutralCapsuleButton(
                            title: "去授权",
                            symbol: "arrow.up.forward.app",
                            emphasis: .primary,
                            help: "打开系统设置的摄像头面板"
                        ) {
                            CameraPermission.openSettings()
                        }
                    }
                    NeutralCapsuleButton(
                        title: "检查",
                        help: "重新读取摄像头授权状态"
                    ) {
                        cameraPermission = CameraPermission.current
                    }
                }
            }
        }
    }

    private var cameraPlacementGroup: some View {
        group("位置与尺寸") {
            GroupRow(
                symbol: "rectangle.inset.filled",
                color: .indigo,
                title: "位置",
                subtitle: "四角任意一角，自动避开屏幕边缘"
            ) {
                NeutralCapsuleMenu(
                    items: CameraPosition.allCases.map(\.rawValue),
                    selection: Binding(
                        get: { settings.cameraOverlayPosition },
                        set: { raw in
                            settings.cameraOverlayPosition = raw
                            model.onCameraSettingsChanged?()
                        }
                    ),
                    title: { CameraPosition(rawValue: $0)?.title ?? $0 },
                    width: 100,
                    help: "选择摄像头画中画所在的角落"
                )
            }

            GroupDivider()

            GroupRow(
                symbol: "arrow.up.left.and.arrow.down.right",
                color: .purple,
                title: "尺寸",
                subtitle: "\(Int(settings.cameraOverlaySizeValue.size.width)) × "
                    + "\(Int(settings.cameraOverlaySizeValue.size.height)) pt"
            ) {
                NeutralSegmentedControl(
                    items: CameraSize.allCases.map(\.rawValue),
                    selection: Binding(
                        get: { settings.cameraOverlaySize },
                        set: { raw in
                            settings.cameraOverlaySize = raw
                            model.onCameraSettingsChanged?()
                        }
                    ),
                    title: { CameraSize(rawValue: $0)?.title ?? $0 }
                )
                .fixedSize()
            }
        }
    }

    // MARK: - 通用

    private var generalTab: some View {
        page("启动、菜单栏内容、面板行为、钉图手势和偏好备份。") {
            if isSelected(PageGroupID.startup) { generalStartupGroup }
            if isSelected(PageGroupID.menuBar) { menuBarGroup }
            if isSelected(PageGroupID.generalBehavior) { generalBehaviorGroup }
            if isSelected(PageGroupID.pin) { generalPinGroup }
            if isSelected(PageGroupID.backup) { generalBackupGroup }
        }
    }

    private var generalStartupGroup: some View {
        group("启动") {
            GroupRow(symbol: "power", color: .blue, title: "登录时启动") {
                toggle(binding(\.launchAtLogin))
            }

            GroupDivider()

            GroupRow(symbol: "dock.rectangle", color: .indigo, title: "在 Dock 中显示", subtitle: "关掉就只留菜单栏图标") {
                toggle(Binding(
                    get: { settings.showInDock },
                    set: { settings.showInDock = $0; model.onRequestApplyActivationPolicy?() }
                ))
            }

            GroupDivider()

            GroupRow(symbol: "menubar.rectangle", color: .teal, title: "显示菜单栏图标", subtitle: "点一下就能调出历史面板") {
                toggle(Binding(
                    get: { settings.menuBarIconVisible },
                    set: { settings.menuBarIconVisible = $0; model.onRequestApplyActivationPolicy?() }
                ))
            }
        }
    }

    private var menuBarGroup: some View {
        group(
            "菜单栏",
            footer: "勾选决定哪些行出现在状态栏菜单；用左侧把手拖动，或点箭头排序。"
                + "「设置」和「退出」固定显示并固定在最末尾，避免把恢复入口藏掉。改动立即重建菜单。"
                + "铅笔框可改状态栏菜单里的显示名称，留空 = 默认名称；"
                + "只改菜单文字，左侧行标题仍是固定名称，便于排序和隐藏。"
        ) {
            let entries = settings.menuBarOrderValue
            ForEach(Array(entries.enumerated()), id: \.element) { index, entry in
                menuBarRow(entry)
                    .dropDestination(for: String.self) { values, _ in
                        guard let raw = values.first else { return false }
                        moveMenuBarEntry(raw, before: entry)
                        return true
                    }

                if index < entries.count - 1 {
                    GroupDivider()
                }
            }
        }
    }

    private func menuBarRow(_ entry: MenuBarEntry) -> some View {
        let hidden = settings.isMenuBarEntryHidden(entry)
        let movable = settings.menuBarOrderValue.filter { !$0.isPinned }
        let canMoveUp = !entry.isPinned && movable.first != entry
        let canMoveDown = !entry.isPinned && movable.last != entry

        return GroupRow(
            symbol: entry.symbol,
            color: entry.isPinned ? .gray : .teal,
            title: entry.title,
            subtitle: entry.detail,
            value: hidden ? "已隐藏" : (entry.isPinned ? "固定" : nil)
        ) {
            HStack(spacing: 6) {
                NeutralInlineTextField(
                    placeholder: entry.title,
                    text: Binding(
                        get: { settings.menuBarCustomTitles[entry.rawValue] ?? "" },
                        set: { settings.setMenuBarTitle($0, for: entry) }
                    ),
                    width: 128,
                    help: "状态栏菜单里显示「\(settings.menuBarTitle(for: entry))」；留空恢复「\(entry.title)」"
                )

                menuBarDragHandle(entry)

                Button {
                    moveMenuBarEntry(entry, offset: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)
                .disabled(!canMoveUp)

                Button {
                    moveMenuBarEntry(entry, offset: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain)
                .disabled(!canMoveDown)

                if entry.isPinned {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(SupportingInk.text)
                        .help("固定显示，不能隐藏")
                } else {
                    Toggle("", isOn: Binding(
                        get: { !hidden },
                        set: { settings.setMenuBarEntry(entry, hidden: !$0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(NeutralSwitchStyle())
                    .help(hidden ? "在状态栏菜单中显示" : "从状态栏菜单隐藏")
                }
            }
        }
    }

    @ViewBuilder
    private func menuBarDragHandle(_ entry: MenuBarEntry) -> some View {
        if entry.isPinned {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.quaternary)
                .help("固定项不能拖动")
        } else {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .bold))
                // A drag handle is an affordance, not a separator: `.tertiary`
                // made it vanish into the row on the dark ground.
                .foregroundStyle(SupportingInk.text)
                .help("拖动排序")
                .draggable(entry.rawValue)
                .accessibilityLabel("拖动排序")
        }
    }

    private func moveMenuBarEntry(_ entry: MenuBarEntry, offset: Int) {
        settings.moveMenuBarEntry(entry, offset: offset)
    }

    private func moveMenuBarEntry(_ raw: String, before target: MenuBarEntry) {
        guard let dragged = MenuBarEntry(rawValue: raw) else { return }
        settings.moveMenuBarEntry(dragged, before: target)
    }

    // MARK: - 快捷键

    /// 系统 → 快捷键. Every bindable action, as one card per block.
    ///
    /// The page keeps the app's three-column shape: the middle column lists the
    /// four blocks (标注工具 / 截图 / 工具 / 应用) and this pane draws the one
    /// it selected. `groupID == PageGroupID.none` draws all four, which is what
    /// an offscreen render and the page's own preview do.
    ///
    /// 2026-10-24 (second pass): the data table is gone. Each block is the same
    /// `GroupHeader` + `GroupSlab` pair 通用 / 外观 / 截图 draw, so 快捷键 now
    /// reads as one of the settings pages rather than as a spreadsheet.
    private var hotkeysTab: some View {
        page(
            "所有可绑定的快捷键，按「标注工具 / 截图 / 工具 / 应用」分成四组。"
                + "标注工具键位只在截图覆盖层里生效；其余键位全局生效。未绑定显示灰色"
                + "「快捷键」，点一下开始录制；「默认」恢复出厂键位。"
        ) {
            ForEach(visibleHotKeyGroups) { block in
                hotKeyGroupCard(block)
            }
            hotKeyClearingHint
        }
    }

    /// The blocks the right pane draws. The middle column picked one of them;
    /// when the page is rendered with no selection every block is drawn, and a
    /// group id from another page falls back to the same "draw everything"
    /// instead of an empty pane.
    private var visibleHotKeyGroups: [HotKeyGroup] {
        let selected = HotKeyGroup.allCases.filter {
            isSelected(PageGroupID.hotKeyGroup($0))
        }
        return selected.isEmpty ? HotKeyGroup.allCases : selected
    }

    /// The one place the 快捷键 page explains how to leave a slot empty.
    ///
    /// The slot used to carry a visible `×`; the owner asked for the plain
    /// single-label capsule back, so both clearing paths are spelled out here
    /// instead of on every row. Secondary ink, one line, under the last card.
    private var hotKeyClearingHint: some View {
        Text("想留空：点键位开始录制后按 Delete 清除，或右键点键位选择「清除快捷键」。")
            .font(.system(size: 11))
            .foregroundStyle(SupportingInk.text)
            .padding(.horizontal, 4)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// One card per block: the same `GroupHeader` + `GroupSlab` pair every other
    /// settings page draws. Rows are separated by `GroupDivider` hairlines —
    /// never by alternating row fills, and never by a caption strip.
    private func hotKeyGroupCard(_ block: HotKeyGroup) -> some View {
        group(block.title, footer: hotKeyFooter(block)) {
            ForEach(Array(block.members.enumerated()), id: \.element) { index, id in
                if index > 0 { GroupDivider() }
                hotKeyRow(hotKeySlot(id))
            }
        }
    }

    /// The one line each card adds under itself. 标注工具 is the block whose
    /// default keys need explaining: the tools ship on ⌘1–⌘9, while the bare
    /// digits still lock the aspect ratio.
    private func hotKeyFooter(_ block: HotKeyGroup) -> String {
        switch block {
        case .annotationTools:
            "只在截图覆盖层里生效；默认 ⌘1–⌘9，裸数字 1–9 仍是宽高比锁定。"
        case .capture:
            "全局键位，走系统 Hot Key API，不需要辅助功能权限。"
        case .tools, .application:
            "全局键位，走系统 Hot Key API。"
        }
    }

    /// One block's accent. With the shipped 单色 icons setting the tiles all
    /// turn neutral; in colour mode each card keeps one family instead of
    /// thirty unrelated colours.
    private func hotKeyAccent(_ id: HotKeyBindingID) -> Color {
        switch HotKeyGroup.group(of: id) {
        case .annotationTools: .orange
        case .capture: .green
        case .tools: .indigo
        case .application: .blue
        }
    }

    /// One row: `GroupRow` (icon tile, title, hover wash) with the recorder and
    /// the 默认 capsule in its trailing slot.
    ///
    /// The two trailing cells are the only fixed widths on the row, which is
    /// what keeps the shortcut column aligned even though nothing captions it.
    private func hotKeyRow(_ slot: HotKeySlot) -> some View {
        GroupRow(
            symbol: slot.id.symbol,
            color: hotKeyAccent(slot.id),
            title: slot.id.title,
            isEnabled: slot.isEnabled
        ) {
            HStack(spacing: HotKeyListMetrics.controlGap) {
                HotKeyRecorderView(
                    keyCode: slot.keyCode,
                    modifiers: slot.modifiers,
                    defaultConfiguration: slot.defaultConfiguration,
                    conflictLabel: conflictLabel(for: slot.id),
                    isEnabled: slot.isEnabled,
                    showsDefaultButton: false
                ) { model.hotKeySettingsDidChange() }
                .frame(width: HotKeyListMetrics.shortcutColumn, alignment: .leading)
                .overlay(alignment: .leading) {
                    HotKeyListColumnMarker.anchor(.shortcut)
                }

                NeutralCapsuleButton(
                    title: "默认",
                    height: NeutralControlMetrics.compactHeight,
                    width: HotKeyListMetrics.defaultColumn,
                    help: slot.defaultConfiguration.isBound
                        ? "恢复默认快捷键（\(slot.defaultConfiguration.displayString)）"
                        : "清除快捷键（这一项没有默认键位）"
                ) {
                    restoreDefault(of: slot)
                }
                .overlay(alignment: .leading) {
                    HotKeyListColumnMarker.anchor(.defaultValue)
                }
            }
        }
        .help(slot.id.detail)
    }

    /// The 默认 cell: the same reset the recorder's paired button does.
    private func restoreDefault(of slot: HotKeySlot) {
        slot.keyCode.wrappedValue = Int(slot.defaultConfiguration.keyCode)
        slot.modifiers.wrappedValue = Int(slot.defaultConfiguration.modifiers)
        model.hotKeySettingsDidChange()
    }

    private var generalBehaviorGroup: some View {
        group(
            "面板行为",
            footer: "快捷键走系统 Hot Key API，不需要辅助功能权限；自动粘贴需要辅助功能权限。"
        ) {
            GroupRow(
                symbol: "command",
                color: .indigo,
                title: "启用历史面板快捷键",
                subtitle: "关掉后只能从菜单栏图标打开"
            ) {
                toggle(Binding(
                    get: { settings.hotKeyEnabled },
                    set: { settings.hotKeyEnabled = $0; model.hotKeySettingsDidChange() }
                ))
            }

            GroupDivider()

            GroupRow(
                symbol: "pin.fill",
                color: .pink,
                title: "启用钉图快捷键",
                subtitle: "关掉后仍可从菜单钉住"
            ) {
                toggle(Binding(
                    get: { settings.pinHotKeyEnabled },
                    set: { settings.pinHotKeyEnabled = $0; model.hotKeySettingsDidChange() }
                ))
            }

            GroupDivider()

            GroupRow(
                symbol: "arrow.down.doc",
                color: .green,
                title: "选中后自动粘贴",
                subtitle: model.accessibilityTrusted
                    ? "已授权辅助功能，回车会直接粘贴到原来的 App"
                    : "需要辅助功能权限；未授权时只复制"
            ) {
                toggle(binding(\.autoPaste))
            }

            GroupDivider()

            GroupRow(
                symbol: "timer",
                color: .orange,
                title: "剪贴板监测间隔",
                subtitle: "\(String(format: "%.1f", settings.pollInterval)) 秒"
            ) {
                NeutralCapsuleMenu(
                    items: [0.2, 0.4, 0.8, 1.5],
                    selection: binding(\.pollInterval),
                    title: { String(format: "%.1f 秒", $0) },
                    width: 92,
                    help: "选择剪贴板监测的轮询间隔"
                )
            }
        }
    }

    private var generalPinGroup: some View {
        group("钉图") {
            GroupRow(symbol: "pin.fill", color: .pink, title: "滚轮缩放钉图") {
                toggle(binding(\.pinScrollZoom))
            }

            GroupDivider()

            GroupRow(
                symbol: "arrow.up.arrow.down",
                color: .pink,
                title: "指针反转",
                subtitle: "上滑放大、下滑缩小（默认下滑放大）"
            ) {
                toggle(binding(\.pinScrollInverted))
            }

            GroupDivider()

            GroupRow(
                symbol: "circle.lefthalf.filled",
                color: .pink,
                title: "⌘ + 滚轮调整钉图不透明度",
                subtitle: "20%–100%，松开 ⌘ 立刻回到缩放"
            ) {
                toggle(binding(\.pinCommandScrollOpacity))
            }
        }
    }

    private var generalBackupGroup: some View {
        group("备份 & 恢复", footer: "备份偏好设置以恢复或导入到其他设备。") {
            GroupRow(symbol: "square.and.arrow.up", color: .blue, title: "导出偏好", subtitle: "写出成 plist 备份文件") {
                NeutralCapsuleButton(
                    title: "导出…",
                    symbol: "square.and.arrow.up",
                    help: "把当前偏好设置导出成 plist 文件"
                ) {
                    exportPreferences()
                }
            }

            GroupDivider()

            GroupRow(symbol: "square.and.arrow.down", color: .green, title: "导入偏好") {
                NeutralCapsuleButton(
                    title: "导入…",
                    symbol: "square.and.arrow.down",
                    help: "从 plist 备份文件导入偏好设置"
                ) {
                    importPreferences()
                }
            }

            GroupDivider()

            GroupRow(symbol: "arrow.counterclockwise", color: .red, title: "重置全部设置") {
                NeutralCapsuleButton(
                    title: "重置",
                    ink: .red,
                    help: "把所有偏好设置恢复成出厂值"
                ) {
                    resetPreferences()
                }
            }
        }
    }

    // MARK: - 外观

    private var appearanceTab: some View {
        page("主题：外观、风格和两个不透明度 —— 背景一层，板块一层。") {
            if isSelected(PageGroupID.theme) { appearanceTopicGroup }
            if isSelected(PageGroupID.iconColour) { iconColourGroup }
        }
    }

    private var iconColourGroup: some View {
        group(
            "图标",
            footer: "单色时整个界面只有选中项有颜色；彩色则按功能给图标上色。"
        ) {
            GroupRow(
                symbol: "paintbrush.fill",
                color: .gray,
                title: "配色",
                subtitle: settings.monochromeIcons ? "单色，更克制" : "彩色，更好分辨"
            ) {
                NeutralSegmentedControl(
                    items: [true, false],
                    selection: binding(\.monochromeIcons),
                    title: { $0 ? "单色" : "彩色" }
                )
            }
        }
    }

    /// The one 主题 card: exactly three sections, in this order.
    ///
    /// 外观  → 浅色 / 深色 / 跟随系统  (the old 默认主题 group)
    /// 风格  → 液态玻璃 / 半透明 / 实色  (the old 背景 group, renamed; 纯色
    ///          now reads 实色)
    /// 两个滑条 → 背景不透明度 (the window's glass wash) and 板块不透明度
    ///          (the three column cards)
    ///
    /// 2026-10-25: the old 主题风格 group (玻璃 / 经典) and the split into
    /// separate 背景 / 默认主题 groups are gone. The owner's report was that two
    /// groups with similar names made the page impossible to scan; the 经典
    /// material switch has no row here because 风格's 液态玻璃 choice and the
    /// automatic pre-26 fallback already cover it.
    ///
    /// 2026-10-25 (later): the one slider became **two**. The owner's request was
    /// "滑条还是改成两个，一个控制背景，一个控制三个板块"; the first attempt at two
    /// sliders had been withdrawn earlier that day, this one is the accepted
    /// shape: same 主题 card, same three sections, the 风格 row followed by two
    /// stacked, separately labelled sliders.
    private var appearanceTopicGroup: some View {
        group(
            "主题",
            footer: Self.appearanceOpacityFooter
        ) {
            GroupRow(
                symbol: "circle.lefthalf.filled",
                color: .indigo,
                title: "外观",
                subtitle: Self.appearanceThemeTitle(settings.appearanceTheme)
            )
            HStack(spacing: 14) {
                ForEach(Self.appearanceThemeOptions, id: \.value) { option in
                    ThemePreview(
                        title: option.title,
                        style: option.value,
                        selected: settings.appearanceTheme == option.value
                    ) {
                        settings.appearanceTheme = option.value
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)

            GroupDivider()

            GroupRow(
                symbol: "square.on.square",
                color: .blue,
                title: "风格",
                subtitle: settings.backgroundStyleValue.detail
            )
            HStack(spacing: 14) {
                ForEach(AppBackgroundStyle.displayOrder) { style in
                    ThemePreview(
                        title: style.title,
                        style: style.rawValue,
                        selected: settings.backgroundStyleValue == style
                    ) {
                        settings.backgroundStyle = style.rawValue
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)

            GroupDivider()

            // TWO opacities, one per layer. Each label names its own layer, so
            // the two rows can never be confused for each other:
            //
            // * 背景不透明度 — `glassOpacity`, the window's glass wash.
            // * 板块不透明度 — `panelOpacity`, the three column cards.
            //
            // The labels say 不透明度, not 透明度, because the numbers are
            // *opacities*: 0 % = fully clear, 100 % = the solid coat. Under 实色
            // neither layer exists (the window is an opaque card and every
            // surface falls back to one), so both sliders are disabled there and
            // a note says why.
            VStack(alignment: .leading, spacing: 12) {
                opacitySlider(
                    label: Self.appearanceOpacityLabels[0],
                    detail: "只改窗口那一层玻璃底色",
                    value: binding(\.glassOpacity),
                    isEnabled: !isSolidBackground
                )
                opacitySlider(
                    label: Self.appearanceOpacityLabels[1],
                    detail: "只改三栏卡片（含卡片里的分组与列表底）",
                    value: binding(\.panelOpacity),
                    isEnabled: !isSolidBackground
                )
                if isSolidBackground {
                    Text(Self.appearanceSolidOpacityNote)
                        .font(.system(size: 11))
                        .foregroundStyle(SupportingInk.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
    }

    /// 风格 == 实色: no glass layer anywhere, so both sliders are meaningless.
    private var isSolidBackground: Bool {
        settings.backgroundStyleValue == .solid
    }

    /// One labelled opacity row: name, one-line scope, percentage, slider.
    private func opacitySlider(
        label: String,
        detail: String,
        value: Binding<Double>,
        isEnabled: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(Self.percentLabel(value.wrappedValue))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(SupportingInk.text)
            }
            Slider(
                value: value,
                in: GlassOpacityRuntime.range,
                // 0.01 lands on a round percentage every time.
                step: 0.01
            )
            .controlSize(.small)
            .disabled(!isEnabled)
        }
        .opacity(isEnabled ? 1 : 0.45)
        .help("\(label)：0% 最透，100% 最实")
    }

    /// The two slider names, in draw order. Data, not literals inside the body,
    /// so the self test can pin that the names are distinct and layer-specific
    /// without scraping SwiftUI text.
    static let appearanceOpacityLabels = ["背景不透明度", "板块不透明度"]

    /// The 主题 card's footer: one sentence per slider, plus the 实色 caveat.
    static let appearanceOpacityFooter =
        "外观只改明暗；风格改窗口材质；两个不透明度各管一层 —— "
        + "背景不透明度管窗口那一层玻璃底色，板块不透明度管三栏卡片（含卡片里的"
        + "分组与列表底）。两者互不影响：0% 最透，100% 最实。实色档没有玻璃层，"
        + "两个滑条都不生效。"

    /// The line shown under the sliders while 风格 is 实色.
    static let appearanceSolidOpacityNote =
        "当前是实色档：窗口和卡片都是不透明卡片，两个不透明度滑条已禁用。"

    /// 外观's three choices, in the order the row draws them.
    private static let appearanceThemeOptions: [(value: String, title: String)] = [
        ("light", "浅色"),
        ("dark", "深色"),
        ("system", "跟随系统")
    ]

    private static func appearanceThemeTitle(_ value: String) -> String {
        appearanceThemeOptions.first { $0.value == value }?.title ?? "跟随系统"
    }

    // MARK: - 隐私

    private var privacyTab: some View {
        page("哪些内容不进入历史记录。") {
            if isSelected(PageGroupID.privacyFilter) { privacyFilterGroup }
            if isSelected(PageGroupID.privacyIgnore) { privacyIgnoreGroup }
        }
    }

    private var privacyFilterGroup: some View {
        group(
            "过滤规则",
            footer: "密码管理器若遵循 nspasteboard 约定，会主动打上 ConcealedType 标记，从而不会被记录。"
        ) {
            GroupRow(
                symbol: "eye.slash",
                color: .orange,
                title: "忽略标记为「临时/隐藏」的剪贴板内容"
            ) {
                toggle(binding(\.ignoreConcealed))
            }

            GroupDivider()

            GroupRow(
                symbol: "lock.fill",
                color: .blue,
                title: "始终忽略已知密码管理器",
                subtitle: "1Password、Bitwarden 等默认不记录"
            ) {
                toggle(binding(\.ignorePasswordManagers))
            }
        }
    }

    private var privacyIgnoreGroup: some View {
        group("永不记录的应用", footer: "名单里的 App 复制的内容永远不会进历史。") {
            if settings.ignoredBundleIDs.isEmpty {
                GroupRow(symbol: "checkmark.circle", color: .green, title: "（空）", subtitle: "还没有例外应用")
            } else {
                ForEach(Array(settings.ignoredBundleIDs.sorted().enumerated()), id: \.element) { index, bundleID in
                    GroupRow(symbol: "hand.raised.slash.fill", color: .red, title: bundleID) {
                        Button {
                            model.unignoreApp(bundleID: bundleID)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .help("从忽略名单里移除")
                    }

                    if index < settings.ignoredBundleIDs.count - 1 {
                        GroupDivider()
                    }
                }
            }

            GroupDivider()

            GroupRow(symbol: "plus.circle.fill", color: .blue, title: "添加 Bundle ID", subtitle: "com.example.app") {
                HStack(spacing: 6) {
                    TextField("Bundle ID", text: $newBundleID)
                        .font(.system(size: 11))
                        .neutralCapsuleField(width: 180)
                    NeutralCapsuleButton(
                        title: "添加",
                        help: "把填写的 Bundle ID 加进忽略名单",
                        isEnabled: !newBundleID.trimmingCharacters(in: .whitespaces).isEmpty
                    ) {
                        model.ignoreApp(bundleID: newBundleID.trimmingCharacters(in: .whitespaces))
                        newBundleID = ""
                    }
                }
            }

            GroupDivider()

            GroupRow(
                symbol: "macwindow.on.rectangle",
                color: .purple,
                title: "把当前最前台 App 加入忽略名单"
            ) {
                NeutralCapsuleButton(
                    title: "加入",
                    help: "把当前最前台 App 的 Bundle ID 加进忽略名单"
                ) {
                    if let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                       id != Bundle.main.bundleIdentifier {
                        model.ignoreApp(bundleID: id)
                    }
                }
            }
        }
    }

    // MARK: - 存储

    private var storageTab: some View {
        page("历史记录的保留策略、图片上限和数据库位置。") {
            if isSelected(PageGroupID.storageRetention) { storageRetentionGroup }
            if isSelected(PageGroupID.storageDatabase) { storageDatabaseGroup }
        }
    }

    private var storageRetentionGroup: some View {
        group("保留策略", footer: "已固定或被钉图的记录不会被清理。") {
            GroupRow(symbol: "tray.full.fill", color: .blue, title: "最多保留", subtitle: "超出上限后从最旧的开始丢") {
                NeutralStepper(
                    value: Binding(
                        get: { settings.maxItems },
                        set: { settings.maxItems = $0; model.settingsDidChange() }
                    ),
                    range: 50...20_000,
                    step: 50,
                    width: 104,
                    help: "最多保留多少条历史记录（50–20000，每步 50）"
                )
            }

            GroupDivider()

            GroupRow(
                symbol: "clock.arrow.circlepath",
                color: .orange,
                title: "自动清理",
                subtitle: settings.retentionDays == 0 ? "永不按时间清理" : "超过 \(settings.retentionDays) 天后清理"
            ) {
                NeutralCapsuleMenu(
                    items: [0, 7, 30, 90, 365],
                    selection: Binding(
                        get: { settings.retentionDays },
                        set: { settings.retentionDays = $0; model.settingsDidChange() }
                    ),
                    title: { $0 == 0 ? "永不" : "\($0) 天" },
                    width: 100,
                    help: "选择历史记录保留多少天后自动清理"
                )
            }

            GroupDivider()

            GroupRow(
                symbol: "photo",
                color: .green,
                title: "记录图片",
                subtitle: "关掉后只收集文字"
            ) {
                toggle(binding(\.captureImages))
            }

            GroupDivider()

            GroupRow(
                symbol: "arrow.up.left.and.arrow.down.right",
                color: .purple,
                title: "单张图片上限",
                subtitle: "更大的图片直接跳过，避免数据库膨胀"
            ) {
                NeutralCapsuleMenu(
                    items: [2, 4, 8, 16, 32].map { $0 * 1024 * 1024 },
                    selection: binding(\.maxImageBytes),
                    title: { "\($0 / (1024 * 1024)) MB" },
                    width: 92,
                    help: "选择单张图片的体积上限"
                )
            }
        }
    }

    private var storageDatabaseGroup: some View {
        group(
            "数据库",
            footer: "当前共 \(model.totalCount) 条记录，\(model.pinboard.count) 张钉图。"
        ) {
            // `.textSelection` so the path can still be copied out by hand —
            // GroupRow has no dedicated selectable slot.
            GroupRow(symbol: "internaldrive.fill", color: .gray, title: "位置", value: model.storageURL.path)
                .textSelection(.enabled)
                .help(model.storageURL.path)

            GroupDivider()

            GroupRow(symbol: "folder.fill", color: .blue, title: "在访达中显示") {
                NeutralCapsuleButton(
                    title: "显示",
                    symbol: "folder",
                    help: "在访达里打开数据库所在的文件夹"
                ) {
                    model.revealStorageInFinder()
                }
            }

            GroupDivider()

            GroupRow(symbol: "trash", color: .orange, title: "清空（保留固定项）") {
                NeutralCapsuleButton(
                    title: "清空",
                    ink: .red,
                    help: "删掉历史记录，保留固定项和钉图"
                ) {
                    model.clearHistory(keepingPinned: true)
                }
            }

            GroupDivider()

            GroupRow(symbol: "trash.fill", color: .red, title: "全部清空", subtitle: "连固定项和钉图一起删掉") {
                NeutralCapsuleButton(
                    title: "全部清空",
                    ink: .red,
                    help: "连固定项和钉图一起删掉"
                ) {
                    model.clearHistory(keepingPinned: false)
                }
            }
        }
    }

    // MARK: - Actions

    /// Folder panel for 保存位置. Cancelling leaves the stored path untouched.
    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.directoryURL = settings.captureDirectory
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            settings.captureDirectoryPath = url.path
        }
    }

    private func exportPreferences() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Unseen-Preferences.plist"
        panel.allowedContentTypes = [.propertyList]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try settings.writePreferences(to: url)
                flash("已导出")
            } catch {
                model.presentError("导出失败：\(error.localizedDescription)")
            }
        }
    }

    private func importPreferences() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try settings.readPreferences(from: url)
                model.preferencesDidChange()
                flash("已导入")
            } catch {
                model.presentError("导入失败：\(error.localizedDescription)")
            }
        }
    }

    private func resetPreferences() {
        settings.resetAll()
        model.preferencesDidChange()
        flash("已重置")
    }
}

/// The selection ring drawn around the chosen theme mock-up.
///
/// It is `SelectionBorderStyle`'s language, scaled down to a 92 × 62 pt tile: a
/// crisp white keyline over a soft dark halo. The old ring was
/// `Color.primary.opacity(0.55)` — in 浅色 that is a hard 2 pt *black* frame,
/// which read as a foreign object on a Liquid Glass window ("套了一层黑框，丑且
/// 不和谐"). White alone would disappear on the white 浅色 mock and on a light
/// page, so the halo stays; it is blurred and low-alpha, which is what turns the
/// frame into a lifted edge instead of a drawn border.
enum ThemeSelectionRing {
    /// 2 pt, and drawn *outside* the tile (`inset`), so it never eats the
    /// mock-up's own edge — the 浅色 thumbnail is nearly white and an inner
    /// white ring would vanish into it.
    static let width: CGFloat = 2
    static let inset: CGFloat = -3
    static let cornerRadius: CGFloat = 11
    static let color = Color.white.opacity(0.92)
    /// The halo under the white line. Low alpha + a blur, never a hard stroke.
    static let halo = Color.black.opacity(0.30)
    static let haloRadius: CGFloat = 2.5
    /// The selected tile lifts a hair; the label already goes semibold.
    static let scale: CGFloat = 1.02
}

/// Miniature window mock-ups for picking a theme. Selection uses
/// `ThemeSelectionRing` instead of the system accent border (the accent would
/// fight the forced 外观, and 跟随系统 would be highlighted in the wrong colour).
private struct ThemePreview: View {
    let title: String
    let style: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(background)
                    VStack(spacing: 0) {
                        HStack(spacing: 3) {
                            Circle().fill(.red).frame(width: 5, height: 5)
                            Circle().fill(.yellow).frame(width: 5, height: 5)
                            Circle().fill(.green).frame(width: 5, height: 5)
                            Spacer()
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                        Spacer()
                    }
                }
                .frame(width: 92, height: 62)
                // The tile's own edge stays quiet; it is what the *unselected*
                // mocks look like, so selected/unselected share one silhouette.
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                )
                .overlay(alignment: .center) {
                    if selected {
                        RoundedRectangle(
                            cornerRadius: ThemeSelectionRing.cornerRadius,
                            style: .continuous
                        )
                        .stroke(ThemeSelectionRing.color, lineWidth: ThemeSelectionRing.width)
                        .padding(ThemeSelectionRing.inset)
                        .shadow(
                            color: ThemeSelectionRing.halo,
                            radius: ThemeSelectionRing.haloRadius
                        )
                    }
                }
                .scaleEffect(selected ? ThemeSelectionRing.scale : 1)

                Text(title)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    private var background: LinearGradient {
        switch style {
        case "light":
            LinearGradient(colors: [.white, Color(white: 0.88)], startPoint: .top, endPoint: .bottom)
        case "dark":
            LinearGradient(colors: [Color(white: 0.28), Color(white: 0.13)], startPoint: .top, endPoint: .bottom)
        case "classic":
            LinearGradient(colors: [Color(white: 0.45), Color(white: 0.3)], startPoint: .top, endPoint: .bottom)
        case "solid":
            LinearGradient(colors: [Color(white: 0.96), Color(white: 0.84)], startPoint: .top, endPoint: .bottom)
        case "translucent":
            LinearGradient(
                colors: [.blue.opacity(0.45), .purple.opacity(0.30), .white.opacity(0.35)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case "liquidGlass":
            LinearGradient(
                colors: [.cyan.opacity(0.65), .blue.opacity(0.55), .purple.opacity(0.55)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        default:
            LinearGradient(colors: [.blue.opacity(0.75), .purple.opacity(0.55)], startPoint: .top, endPoint: .bottom)
        }
    }
}

// The `.compactMenuPicker(width:)` helper that used to live here is gone: every
// numeric / enum row now draws `NeutralCapsuleMenu`, because a SwiftUI `Picker`
// in `.menu` style always renders AppKit's own popup — a pure-white bezel in
// 浅色 (dark metal in 深色) with the system's blue up/down arrows, which is the
// control the owner flagged as "这种纯白的很扎眼". The capsule keeps the system
// *menu* (that is the platform's own popup, not an in-window bezel) and replaces
// only the label with the app's ink, hairline and one custom chevron.

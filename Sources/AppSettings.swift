import Carbon.HIToolbox
import Foundation
import SwiftUI
import Observation
import ServiceManagement

/// How the main window shows the desktop behind it.
///
/// `.solid` keeps the classic opaque window; `.translucent` and `.liquidGlass`
/// make the window non-opaque so an `NSVisualEffectView` / `NSGlassEffectView`
/// backdrop can show through.
enum AppBackgroundStyle: String, CaseIterable, Identifiable, Sendable {
    case solid
    case translucent
    case liquidGlass

    /// The order 外观 → 主题 → 风格 draws the three previews in: glass first,
    /// then the blur, then the opaque plate (实色). Kept separate from
    /// `allCases` so the storage / preference order stays put.
    static let displayOrder: [AppBackgroundStyle] = [.liquidGlass, .translucent, .solid]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .solid: "实色"
        case .translucent: "半透明"
        case .liquidGlass: "液态玻璃"
        }
    }

    var detail: String {
        switch self {
        case .solid: "不透明实色背景，最省电"
        case .translucent: "透出桌面并做轻微模糊"
        case .liquidGlass: "macOS 26 的 Liquid Glass；旧系统退回毛玻璃"
        }
    }
}

/// User preferences, persisted in `UserDefaults`.
@MainActor
@Observable
final class AppSettings {
    enum Key {
        static let pollInterval = "pollInterval"
        static let maxItems = "maxItems"
        static let retentionDays = "retentionDays"
        static let ignoreConcealed = "ignoreConcealed"
        static let ignorePasswordManagers = "ignorePasswordManagers"
        static let captureImages = "captureImages"
        static let maxImageBytes = "maxImageBytes"
        static let autoPaste = "autoPaste"
        static let ignoredBundleIDs = "ignoredBundleIDs"
        static let hotKeyEnabled = "hotKeyEnabled"
        static let hotKeyKeyCode = "hotKeyKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let pinHotKeyEnabled = "pinHotKeyEnabled"
        static let pinHotKeyKeyCode = "pinHotKeyKeyCode"
        static let pinHotKeyModifiers = "pinHotKeyModifiers"
        static let screenshotHotKeyEnabled = "screenshotHotKeyEnabled"
        static let screenshotHotKeyKeyCode = "screenshotHotKeyKeyCode"
        static let screenshotHotKeyModifiers = "screenshotHotKeyModifiers"
        static let ocrHotKeyEnabled = "ocrHotKeyEnabled"
        static let ocrHotKeyKeyCode = "ocrHotKeyKeyCode"
        static let ocrHotKeyModifiers = "ocrHotKeyModifiers"
        static let scrollHotKeyEnabled = "scrollHotKeyEnabled"
        static let scrollHotKeyKeyCode = "scrollHotKeyKeyCode"
        static let scrollHotKeyModifiers = "scrollHotKeyModifiers"
        static let recordHotKeyEnabled = "recordHotKeyEnabled"
        static let recordHotKeyKeyCode = "recordHotKeyKeyCode"
        static let recordHotKeyModifiers = "recordHotKeyModifiers"
        static let colorPickerHotKeyEnabled = "colorPickerHotKeyEnabled"
        static let colorPickerHotKeyKeyCode = "colorPickerHotKeyKeyCode"
        static let colorPickerHotKeyModifiers = "colorPickerHotKeyModifiers"
        static let beautifyHotKeyEnabled = "beautifyHotKeyEnabled"
        static let beautifyHotKeyKeyCode = "beautifyHotKeyKeyCode"
        static let beautifyHotKeyModifiers = "beautifyHotKeyModifiers"
        static let instantWindowHotKeyEnabled = "instantWindowHotKeyEnabled"
        static let instantWindowHotKeyKeyCode = "instantWindowHotKeyKeyCode"
        static let instantWindowHotKeyModifiers = "instantWindowHotKeyModifiers"
        static let instantFullScreenHotKeyEnabled = "instantFullScreenHotKeyEnabled"
        static let instantFullScreenHotKeyKeyCode = "instantFullScreenHotKeyKeyCode"
        static let instantFullScreenHotKeyModifiers = "instantFullScreenHotKeyModifiers"
        // 窗口截图 (the confirmation overlay) and 全屏截图 (the mode entry) had
        // no bindable shortcut before; 按键显示 gains one too. Their shipped
        // values come from the owner's preference file: ⌥Q / ⌥W bound,
        // 按键显示 unbound.
        static let windowHotKeyEnabled = "windowHotKeyEnabled"
        static let windowHotKeyKeyCode = "windowHotKeyKeyCode"
        static let windowHotKeyModifiers = "windowHotKeyModifiers"
        static let fullScreenHotKeyEnabled = "fullScreenHotKeyEnabled"
        static let fullScreenHotKeyKeyCode = "fullScreenHotKeyKeyCode"
        static let fullScreenHotKeyModifiers = "fullScreenHotKeyModifiers"
        static let keyDisplayHotKeyEnabled = "keyDisplayHotKeyEnabled"
        static let keyDisplayHotKeyKeyCode = "keyDisplayHotKeyKeyCode"
        static let keyDisplayHotKeyModifiers = "keyDisplayHotKeyModifiers"
        // 固定大小 / 延时 / 多窗口 / 摄像头 / 打开设置. These actions existed
        // only as menu items; they are ordinary bindable slots now. The three
        // capture modes ship with the app-menu combinations (⌃⌥⌘E / D / M),
        // 摄像头 and 打开设置 ship unbound.
        static let capturePresetHotKeyKeyCode = "capturePresetHotKeyKeyCode"
        static let capturePresetHotKeyModifiers = "capturePresetHotKeyModifiers"
        static let delayCaptureHotKeyKeyCode = "delayCaptureHotKeyKeyCode"
        static let delayCaptureHotKeyModifiers = "delayCaptureHotKeyModifiers"
        static let multiWindowHotKeyKeyCode = "multiWindowHotKeyKeyCode"
        static let multiWindowHotKeyModifiers = "multiWindowHotKeyModifiers"
        static let cameraHotKeyKeyCode = "cameraHotKeyKeyCode"
        static let cameraHotKeyModifiers = "cameraHotKeyModifiers"
        static let openSettingsHotKeyKeyCode = "openSettingsHotKeyKeyCode"
        static let openSettingsHotKeyModifiers = "openSettingsHotKeyModifiers"
        static let instantCaptureSound = "instantCaptureSound"
        static let instantCaptureVisualCue = "instantCaptureVisualCue"
        static let instantCaptureAlsoSave = "instantCaptureAlsoSave"
        static let recordingFormat = "recordingFormat"
        static let recordingFrameRate = "recordingFrameRate"
        static let recordingBitrate = "recordingBitrate"
        static let recordingMicrophone = "recordingMicrophone"
        static let colorPickerFormat = "colorPickerFormat"
        static let cameraOverlayEnabled = "cameraOverlayEnabled"
        static let cameraOverlayPosition = "cameraOverlayPosition"
        static let cameraOverlaySize = "cameraOverlaySize"
        static let keyDisplayEnabled = "keyDisplayEnabled"
        static let keyDisplayPosition = "keyDisplayPosition"
        static let keyDisplayDuration = "keyDisplayDuration"
        static let captureDirectoryPath = "captureDirectoryPath"
        static let captureFormat = "captureFormat"
        static let captureSound = "captureSound"
        static let captureCursor = "captureCursor"
        static let captureCornerRadiusEnabled = "captureCornerRadiusEnabled"
        static let captureCornerRadius = "captureCornerRadius"
        static let captureShadowEnabled = "captureShadowEnabled"
        static let captureShadowSize = "captureShadowSize"
        static let showCrosshair = "showCrosshair"
        static let showLoupe = "showLoupe"
        static let timeOfDelayScreenshots = "timeOfDelayScreenshots"
        static let presetCaptureWidth = "presetCaptureWidth"
        static let presetCaptureHeight = "presetCaptureHeight"
        static let showInDock = "showInDock"
        static let menuBarIconVisible = "menuBarIconVisible"
        /// Which rows the status-bar menu shows, in `MenuBarEntry.rawValue`
        /// order. Missing entries are appended; 设置 / 退出 are always last.
        static let menuBarItemOrder = "menuBarItemOrder"
        /// `MenuBarEntry.rawValue` strings hidden from the status-bar menu.
        /// Pinned entries cannot be hidden.
        static let menuBarHiddenItems = "menuBarHiddenItems"
        /// `MenuBarEntry.rawValue` → user-chosen status-menu label. Missing or
        /// blank entries use the canonical `MenuBarEntry.title`.
        static let menuBarCustomTitles = "menuBarCustomTitles"
        static let pinScrollZoom = "pinScrollZoom"
        static let pinCommandScrollOpacity = "pinCommandScrollOpacity"
        static let pinScrollInverted = "pinScrollInverted"
        static let appearanceStyle = "appearanceStyle"
        static let backgroundStyle = "backgroundStyle"
        static let appearanceTheme = "appearanceTheme"
        static let monochromeIcons = "monochromeIcons"
        static let glassOpacity = "glassOpacity"
        /// 外观 → 主题 → 板块不透明度: the three column cards' layer. Same units
        /// and range as `glassOpacity`, but a separate key with its own slider.
        static let panelOpacity = "panelOpacity"

        // MARK: 截图 / 标注 / 滚图 / OCR（2026-10 设置页重构）
        static let defaultCaptureMode = "defaultCaptureMode"
        static let annotationColorHex = "annotationColorHex"
        static let annotationLineWidth = "annotationLineWidth"
        static let annotationFontSize = "annotationFontSize"
        static let annotationHiddenTools = "annotationHiddenTools"
        static let annotationToolOrder = "annotationToolOrder"
        /// Overlay-local annotation-tool shortcuts: `AnnotationTool.rawValue` →
        /// `["keyCode": Int, "modifiers": Int]`. A missing tool uses its shipped
        /// default and `0 / 0` is the grey placeholder.
        static let annotationToolHotKeys = "annotationToolHotKeys"
        static let scrollCaptureInterval = "scrollCaptureInterval"
        static let scrollCaptureMaxFrames = "scrollCaptureMaxFrames"
        static let scrollCaptureShowsHUD = "scrollCaptureShowsHUD"
        static let ocrLanguage = "ocrLanguage"
        static let ocrDetectBarcodes = "ocrDetectBarcodes"
        static let ocrAutoCopy = "ocrAutoCopy"
        static let recentPickedColors = "recentPickedColors"
    }

    /// Pasteboard types that mean "do not record me" (password managers, transient drags…).
    static let concealedTypeMarkers: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        "de.petermaurer.TransientPasteboardType",
        "com.typeit4me.clipping",
        "com.agilebits.onepassword",
        "net.antelle.keeweb",
        "Pasteboard generator type"
    ]

    /// Apps that copy secrets by default; skipped unless the user removes them.
    static let knownPasswordManagers: [String] = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "in.sinew.Enpass-Desktop",
        "com.dashlane.dashlanephonefinal",
        "org.keepassxc.keepassxc",
        "me.proton.pass.electron"
    ]

    @ObservationIgnored private let defaults: UserDefaults

    var pollInterval: Double {
        didSet { defaults.set(pollInterval, forKey: Key.pollInterval) }
    }
    var maxItems: Int {
        didSet { defaults.set(maxItems, forKey: Key.maxItems) }
    }
    var retentionDays: Int {
        didSet { defaults.set(retentionDays, forKey: Key.retentionDays) }
    }
    var ignoreConcealed: Bool {
        didSet { defaults.set(ignoreConcealed, forKey: Key.ignoreConcealed) }
    }
    var ignorePasswordManagers: Bool {
        didSet { defaults.set(ignorePasswordManagers, forKey: Key.ignorePasswordManagers) }
    }
    var captureImages: Bool {
        didSet { defaults.set(captureImages, forKey: Key.captureImages) }
    }
    var maxImageBytes: Int {
        didSet { defaults.set(maxImageBytes, forKey: Key.maxImageBytes) }
    }
    var autoPaste: Bool {
        didSet { defaults.set(autoPaste, forKey: Key.autoPaste) }
    }
    var ignoredBundleIDs: Set<String> {
        didSet { defaults.set(Array(ignoredBundleIDs).sorted(), forKey: Key.ignoredBundleIDs) }
    }
    var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            applyLaunchAtLogin()
        }
    }
    var hotKeyEnabled: Bool {
        didSet { defaults.set(hotKeyEnabled, forKey: Key.hotKeyEnabled) }
    }
    var hotKeyKeyCode: Int {
        didSet { defaults.set(hotKeyKeyCode, forKey: Key.hotKeyKeyCode) }
    }
    var hotKeyModifiers: Int {
        didSet { defaults.set(hotKeyModifiers, forKey: Key.hotKeyModifiers) }
    }

    var hotKeyConfiguration: HotKeyConfiguration {
        HotKeyConfiguration(
            keyCode: UInt32(hotKeyKeyCode),
            modifiers: UInt32(hotKeyModifiers)
        )
    }

    var pinHotKeyEnabled: Bool {
        didSet { defaults.set(pinHotKeyEnabled, forKey: Key.pinHotKeyEnabled) }
    }
    var pinHotKeyKeyCode: Int {
        didSet { defaults.set(pinHotKeyKeyCode, forKey: Key.pinHotKeyKeyCode) }
    }
    var pinHotKeyModifiers: Int {
        didSet { defaults.set(pinHotKeyModifiers, forKey: Key.pinHotKeyModifiers) }
    }

    var pinHotKeyConfiguration: HotKeyConfiguration {
        HotKeyConfiguration(
            keyCode: UInt32(pinHotKeyKeyCode),
            modifiers: UInt32(pinHotKeyModifiers)
        )
    }

    var screenshotHotKeyEnabled: Bool {
        didSet { defaults.set(screenshotHotKeyEnabled, forKey: Key.screenshotHotKeyEnabled) }
    }
    var screenshotHotKeyKeyCode: Int {
        didSet { defaults.set(screenshotHotKeyKeyCode, forKey: Key.screenshotHotKeyKeyCode) }
    }
    var screenshotHotKeyModifiers: Int {
        didSet { defaults.set(screenshotHotKeyModifiers, forKey: Key.screenshotHotKeyModifiers) }
    }

    var screenshotHotKeyConfiguration: HotKeyConfiguration {
        HotKeyConfiguration(
            keyCode: UInt32(screenshotHotKeyKeyCode),
            modifiers: UInt32(screenshotHotKeyModifiers)
        )
    }

    var ocrHotKeyEnabled: Bool {
        didSet { defaults.set(ocrHotKeyEnabled, forKey: Key.ocrHotKeyEnabled) }
    }
    var ocrHotKeyKeyCode: Int {
        didSet { defaults.set(ocrHotKeyKeyCode, forKey: Key.ocrHotKeyKeyCode) }
    }
    var ocrHotKeyModifiers: Int {
        didSet { defaults.set(ocrHotKeyModifiers, forKey: Key.ocrHotKeyModifiers) }
    }

    var ocrHotKeyConfiguration: HotKeyConfiguration {
        HotKeyConfiguration(
            keyCode: UInt32(ocrHotKeyKeyCode),
            modifiers: UInt32(ocrHotKeyModifiers)
        )
    }

    var scrollHotKeyEnabled: Bool {
        didSet { defaults.set(scrollHotKeyEnabled, forKey: Key.scrollHotKeyEnabled) }
    }
    var scrollHotKeyKeyCode: Int {
        didSet { defaults.set(scrollHotKeyKeyCode, forKey: Key.scrollHotKeyKeyCode) }
    }
    var scrollHotKeyModifiers: Int {
        didSet { defaults.set(scrollHotKeyModifiers, forKey: Key.scrollHotKeyModifiers) }
    }

    var scrollHotKeyConfiguration: HotKeyConfiguration {
        HotKeyConfiguration(
            keyCode: UInt32(scrollHotKeyKeyCode),
            modifiers: UInt32(scrollHotKeyModifiers)
        )
    }

    var recordHotKeyEnabled: Bool {
        didSet { defaults.set(recordHotKeyEnabled, forKey: Key.recordHotKeyEnabled) }
    }
    var recordHotKeyKeyCode: Int {
        didSet { defaults.set(recordHotKeyKeyCode, forKey: Key.recordHotKeyKeyCode) }
    }
    var recordHotKeyModifiers: Int {
        didSet { defaults.set(recordHotKeyModifiers, forKey: Key.recordHotKeyModifiers) }
    }

    var recordHotKeyConfiguration: HotKeyConfiguration {
        HotKeyConfiguration(
            keyCode: UInt32(recordHotKeyKeyCode),
            modifiers: UInt32(recordHotKeyModifiers)
        )
    }

    var colorPickerHotKeyEnabled: Bool {
        didSet { defaults.set(colorPickerHotKeyEnabled, forKey: Key.colorPickerHotKeyEnabled) }
    }
    var colorPickerHotKeyKeyCode: Int {
        didSet { defaults.set(colorPickerHotKeyKeyCode, forKey: Key.colorPickerHotKeyKeyCode) }
    }
    var colorPickerHotKeyModifiers: Int {
        didSet { defaults.set(colorPickerHotKeyModifiers, forKey: Key.colorPickerHotKeyModifiers) }
    }

    var colorPickerHotKeyConfiguration: HotKeyConfiguration {
        HotKeyConfiguration(
            keyCode: UInt32(colorPickerHotKeyKeyCode),
            modifiers: UInt32(colorPickerHotKeyModifiers)
        )
    }

    var beautifyHotKeyEnabled: Bool {
        didSet { defaults.set(beautifyHotKeyEnabled, forKey: Key.beautifyHotKeyEnabled) }
    }
    var beautifyHotKeyKeyCode: Int {
        didSet { defaults.set(beautifyHotKeyKeyCode, forKey: Key.beautifyHotKeyKeyCode) }
    }
    var beautifyHotKeyModifiers: Int {
        didSet { defaults.set(beautifyHotKeyModifiers, forKey: Key.beautifyHotKeyModifiers) }
    }

    var beautifyHotKeyConfiguration: HotKeyConfiguration {
        HotKeyConfiguration(
            keyCode: UInt32(beautifyHotKeyKeyCode),
            modifiers: UInt32(beautifyHotKeyModifiers)
        )
    }

    // MARK: - 即时截图

    var instantWindowHotKeyEnabled: Bool {
        didSet { defaults.set(instantWindowHotKeyEnabled, forKey: Key.instantWindowHotKeyEnabled) }
    }
    var instantWindowHotKeyKeyCode: Int {
        didSet { defaults.set(instantWindowHotKeyKeyCode, forKey: Key.instantWindowHotKeyKeyCode) }
    }
    var instantWindowHotKeyModifiers: Int {
        didSet {
            defaults.set(instantWindowHotKeyModifiers, forKey: Key.instantWindowHotKeyModifiers)
        }
    }

    var instantWindowHotKeyConfiguration: HotKeyConfiguration {
        HotKeyConfiguration(
            keyCode: UInt32(instantWindowHotKeyKeyCode),
            modifiers: UInt32(instantWindowHotKeyModifiers)
        )
    }

    var instantFullScreenHotKeyEnabled: Bool {
        didSet {
            defaults.set(instantFullScreenHotKeyEnabled, forKey: Key.instantFullScreenHotKeyEnabled)
        }
    }
    var instantFullScreenHotKeyKeyCode: Int {
        didSet {
            defaults.set(instantFullScreenHotKeyKeyCode, forKey: Key.instantFullScreenHotKeyKeyCode)
        }
    }
    var instantFullScreenHotKeyModifiers: Int {
        didSet {
            defaults.set(
                instantFullScreenHotKeyModifiers,
                forKey: Key.instantFullScreenHotKeyModifiers
            )
        }
    }

    var instantFullScreenHotKeyConfiguration: HotKeyConfiguration {
        HotKeyConfiguration(
            keyCode: UInt32(instantFullScreenHotKeyKeyCode),
            modifiers: UInt32(instantFullScreenHotKeyModifiers)
        )
    }

    // MARK: - 新补的快捷键位（窗口 / 全屏 / 按键显示）

    var windowHotKeyEnabled: Bool {
        didSet { defaults.set(windowHotKeyEnabled, forKey: Key.windowHotKeyEnabled) }
    }
    var windowHotKeyKeyCode: Int {
        didSet { defaults.set(windowHotKeyKeyCode, forKey: Key.windowHotKeyKeyCode) }
    }
    var windowHotKeyModifiers: Int {
        didSet { defaults.set(windowHotKeyModifiers, forKey: Key.windowHotKeyModifiers) }
    }

    var windowHotKeyConfiguration: HotKeyConfiguration {
        HotKeyConfiguration(
            keyCode: UInt32(windowHotKeyKeyCode),
            modifiers: UInt32(windowHotKeyModifiers)
        )
    }

    var fullScreenHotKeyEnabled: Bool {
        didSet { defaults.set(fullScreenHotKeyEnabled, forKey: Key.fullScreenHotKeyEnabled) }
    }
    var fullScreenHotKeyKeyCode: Int {
        didSet { defaults.set(fullScreenHotKeyKeyCode, forKey: Key.fullScreenHotKeyKeyCode) }
    }
    var fullScreenHotKeyModifiers: Int {
        didSet { defaults.set(fullScreenHotKeyModifiers, forKey: Key.fullScreenHotKeyModifiers) }
    }

    var fullScreenHotKeyConfiguration: HotKeyConfiguration {
        HotKeyConfiguration(
            keyCode: UInt32(fullScreenHotKeyKeyCode),
            modifiers: UInt32(fullScreenHotKeyModifiers)
        )
    }

    var keyDisplayHotKeyEnabled: Bool {
        didSet { defaults.set(keyDisplayHotKeyEnabled, forKey: Key.keyDisplayHotKeyEnabled) }
    }
    var keyDisplayHotKeyKeyCode: Int {
        didSet { defaults.set(keyDisplayHotKeyKeyCode, forKey: Key.keyDisplayHotKeyKeyCode) }
    }
    var keyDisplayHotKeyModifiers: Int {
        didSet { defaults.set(keyDisplayHotKeyModifiers, forKey: Key.keyDisplayHotKeyModifiers) }
    }

    var keyDisplayHotKeyConfiguration: HotKeyConfiguration {
        HotKeyConfiguration(
            keyCode: UInt32(keyDisplayHotKeyKeyCode),
            modifiers: UInt32(keyDisplayHotKeyModifiers)
        )
    }

    var capturePresetHotKeyKeyCode: Int {
        didSet { defaults.set(capturePresetHotKeyKeyCode, forKey: Key.capturePresetHotKeyKeyCode) }
    }
    var capturePresetHotKeyModifiers: Int {
        didSet {
            defaults.set(capturePresetHotKeyModifiers, forKey: Key.capturePresetHotKeyModifiers)
        }
    }
    var capturePresetHotKeyConfiguration: HotKeyConfiguration {
        HotKeyConfiguration(
            keyCode: UInt32(capturePresetHotKeyKeyCode),
            modifiers: UInt32(capturePresetHotKeyModifiers)
        )
    }

    var delayCaptureHotKeyKeyCode: Int {
        didSet { defaults.set(delayCaptureHotKeyKeyCode, forKey: Key.delayCaptureHotKeyKeyCode) }
    }
    var delayCaptureHotKeyModifiers: Int {
        didSet {
            defaults.set(delayCaptureHotKeyModifiers, forKey: Key.delayCaptureHotKeyModifiers)
        }
    }
    var delayCaptureHotKeyConfiguration: HotKeyConfiguration {
        HotKeyConfiguration(
            keyCode: UInt32(delayCaptureHotKeyKeyCode),
            modifiers: UInt32(delayCaptureHotKeyModifiers)
        )
    }

    var multiWindowHotKeyKeyCode: Int {
        didSet { defaults.set(multiWindowHotKeyKeyCode, forKey: Key.multiWindowHotKeyKeyCode) }
    }
    var multiWindowHotKeyModifiers: Int {
        didSet { defaults.set(multiWindowHotKeyModifiers, forKey: Key.multiWindowHotKeyModifiers) }
    }
    var multiWindowHotKeyConfiguration: HotKeyConfiguration {
        HotKeyConfiguration(
            keyCode: UInt32(multiWindowHotKeyKeyCode),
            modifiers: UInt32(multiWindowHotKeyModifiers)
        )
    }

    var cameraHotKeyKeyCode: Int {
        didSet { defaults.set(cameraHotKeyKeyCode, forKey: Key.cameraHotKeyKeyCode) }
    }
    var cameraHotKeyModifiers: Int {
        didSet { defaults.set(cameraHotKeyModifiers, forKey: Key.cameraHotKeyModifiers) }
    }
    var cameraHotKeyConfiguration: HotKeyConfiguration {
        HotKeyConfiguration(
            keyCode: UInt32(cameraHotKeyKeyCode),
            modifiers: UInt32(cameraHotKeyModifiers)
        )
    }

    var openSettingsHotKeyKeyCode: Int {
        didSet { defaults.set(openSettingsHotKeyKeyCode, forKey: Key.openSettingsHotKeyKeyCode) }
    }
    var openSettingsHotKeyModifiers: Int {
        didSet {
            defaults.set(openSettingsHotKeyModifiers, forKey: Key.openSettingsHotKeyModifiers)
        }
    }
    var openSettingsHotKeyConfiguration: HotKeyConfiguration {
        HotKeyConfiguration(
            keyCode: UInt32(openSettingsHotKeyKeyCode),
            modifiers: UInt32(openSettingsHotKeyModifiers)
        )
    }

    /// What the Carbon layer should register: only an enabled, actually-bound
    /// shortcut. The unbound sentinel must never reach `RegisterEventHotKey`,
    /// where key code 0 / mask 0 would grab the plain A key globally.
    static func registeredConfiguration(
        enabled: Bool,
        _ configuration: HotKeyConfiguration
    ) -> HotKeyConfiguration? {
        enabled && configuration.isBound ? configuration : nil
    }

    /// The switch and the stored combination behind one bindable action.
    ///
    /// This is the read-only projection the status menu needs: it must show
    /// exactly what the Carbon layer registered, so a switched-off feature or
    /// an unbound slot must advertise no key at all. `SettingsView` keeps the
    /// writable key-code bindings; both read the same stored values.
    func hotKeyState(_ id: HotKeyBindingID) -> (enabled: Bool, configuration: HotKeyConfiguration) {
        switch id {
        case .openPanel: (hotKeyEnabled, hotKeyConfiguration)
        case .pin: (pinHotKeyEnabled, pinHotKeyConfiguration)
        case .region: (screenshotHotKeyEnabled, screenshotHotKeyConfiguration)
        case .window: (windowHotKeyEnabled, windowHotKeyConfiguration)
        case .fullScreen: (fullScreenHotKeyEnabled, fullScreenHotKeyConfiguration)
        case .instantWindow: (instantWindowHotKeyEnabled, instantWindowHotKeyConfiguration)
        case .instantFullScreen: (instantFullScreenHotKeyEnabled, instantFullScreenHotKeyConfiguration)
        case .scroll: (scrollHotKeyEnabled, scrollHotKeyConfiguration)
        case .record: (recordHotKeyEnabled, recordHotKeyConfiguration)
        case .ocr: (ocrHotKeyEnabled, ocrHotKeyConfiguration)
        case .colorPicker: (colorPickerHotKeyEnabled, colorPickerHotKeyConfiguration)
        case .keyDisplay: (keyDisplayHotKeyEnabled, keyDisplayHotKeyConfiguration)
        case .beautify: (beautifyHotKeyEnabled, beautifyHotKeyConfiguration)
        case .capturePreset: (true, capturePresetHotKeyConfiguration)
        case .delayCapture: (true, delayCaptureHotKeyConfiguration)
        case .multiWindow: (true, multiWindowHotKeyConfiguration)
        case .camera: (true, cameraHotKeyConfiguration)
        case .openSettings: (true, openSettingsHotKeyConfiguration)
        case .toolMove, .toolArrow, .toolRectangle, .toolEllipse,
             .toolLine, .toolPencil, .toolHighlighter, .toolMosaic,
             .toolText, .toolNote, .toolCounter, .toolSticker:
            (true, annotationToolConfiguration(id.annotationTool!))
        }
    }

    // MARK: - 标注工具快捷键（overlay-local）

    /// Shipped overlay shortcuts: one ⌘-numeral per tool.
    static let defaultAnnotationToolHotKeys: [String: [String: Int]] = Dictionary(
        uniqueKeysWithValues: AnnotationTool.allCases.map { tool in
            let configuration = HotKeyConfiguration.annotationTool(tool)
            return (
                tool.rawValue,
                ["keyCode": Int(configuration.keyCode), "modifiers": Int(configuration.modifiers)]
            )
        }
    )

    /// The stored shortcut for one annotation tool, with the shipped default
    /// when the preference has no entry.
    func annotationToolConfiguration(_ tool: AnnotationTool) -> HotKeyConfiguration {
        if let entry = annotationToolHotKeys[tool.rawValue],
           let keyCode = entry["keyCode"],
           let modifiers = entry["modifiers"] {
            return HotKeyConfiguration(
                keyCode: UInt32(max(0, keyCode)),
                modifiers: UInt32(max(0, modifiers))
            )
        }
        return .annotationTool(tool)
    }

    func setAnnotationToolConfiguration(
        _ configuration: HotKeyConfiguration,
        for tool: AnnotationTool
    ) {
        var updated = annotationToolHotKeys
        updated[tool.rawValue] = [
            "keyCode": Int(configuration.keyCode),
            "modifiers": Int(configuration.modifiers)
        ]
        annotationToolHotKeys = updated
    }

    /// The tool whose stored combination is `configuration`, if any. Used by
    /// the capture overlay's own `keyDown`; the first match wins when two tools
    /// were deliberately bound together (the settings table flags that).
    func annotationTool(matching configuration: HotKeyConfiguration) -> AnnotationTool? {
        guard configuration.isBound else { return nil }
        return AnnotationTool.allCases.first {
            annotationToolConfiguration($0) == configuration
        }
    }

    func resetAnnotationToolHotKeys() {
        annotationToolHotKeys = Self.defaultAnnotationToolHotKeys
    }

    /// Plist import sanitising: keep only known tools and the two integer
    /// fields, so a hand-edited / older backup cannot inject arbitrary values.
    static func normalizedAnnotationToolHotKeys(_ value: Any?) -> [String: [String: Int]] {
        guard let raw = value as? [String: Any] else { return [:] }
        var result: [String: [String: Int]] = [:]
        for tool in AnnotationTool.allCases {
            guard let entry = raw[tool.rawValue] as? [String: Any],
                  let keyCode = (entry["keyCode"] as? NSNumber)?.intValue,
                  let modifiers = (entry["modifiers"] as? NSNumber)?.intValue else { continue }
            result[tool.rawValue] = ["keyCode": keyCode, "modifiers": modifiers]
        }
        return result
    }

    /// Short confirmation sound for the instant path. Independent of
    /// `captureSound` because the two experiences have different expectations
    /// (the overlay is deliberate, the instant path should be quiet).
    var instantCaptureSound: Bool {
        didSet { defaults.set(instantCaptureSound, forKey: Key.instantCaptureSound) }
    }
    /// The transient ring at the pointer. Never intercepts input.
    var instantCaptureVisualCue: Bool {
        didSet { defaults.set(instantCaptureVisualCue, forKey: Key.instantCaptureVisualCue) }
    }
    /// Silently write a copy into `captureDirectory` in addition to the
    /// clipboard. Off by default: "instant" means pasteboard only.
    var instantCaptureAlsoSave: Bool {
        didSet { defaults.set(instantCaptureAlsoSave, forKey: Key.instantCaptureAlsoSave) }
    }

    // MARK: - 录屏

    /// `mp4` or `mov`. Both are H.264; only the container differs.
    var recordingFormat: String {
        didSet { defaults.set(recordingFormat, forKey: Key.recordingFormat) }
    }
    var recordingFrameRate: Int {
        didSet { defaults.set(recordingFrameRate, forKey: Key.recordingFrameRate) }
    }
    /// Bits per second. Free text in the UI, clamped by
    /// `RecordingConfiguration.effectiveBitrate` when used.
    var recordingBitrate: Int {
        didSet { defaults.set(recordingBitrate, forKey: Key.recordingBitrate) }
    }
    var recordingMicrophone: Bool {
        didSet { defaults.set(recordingMicrophone, forKey: Key.recordingMicrophone) }
    }

    var recordingConfiguration: RecordingConfiguration {
        RecordingConfiguration(
            format: RecordingFormat(rawValue: recordingFormat) ?? .mp4,
            frameRate: recordingFrameRate,
            bitrate: recordingBitrate,
            capturesMicrophone: recordingMicrophone
        )
    }

    // MARK: - 取色器 / 按键显示

    /// `hex` or `rgb`. HEX is the default copy format.
    var colorPickerFormat: String {
        didSet { defaults.set(colorPickerFormat, forKey: Key.colorPickerFormat) }
    }

    var colorPickFormat: ColorPickFormat {
        ColorPickFormat(rawValue: colorPickerFormat) ?? .hex
    }

    var keyDisplayEnabled: Bool {
        didSet { defaults.set(keyDisplayEnabled, forKey: Key.keyDisplayEnabled) }
    }

    // MARK: - 摄像头画中画

    /// Show the camera picture-in-picture while recording. The menu item can
    /// still toggle it manually at any time.
    var cameraOverlayEnabled: Bool {
        didSet { defaults.set(cameraOverlayEnabled, forKey: Key.cameraOverlayEnabled) }
    }
    /// `topLeft` / `topRight` / `bottomLeft` / `bottomRight`.
    var cameraOverlayPosition: String {
        didSet { defaults.set(cameraOverlayPosition, forKey: Key.cameraOverlayPosition) }
    }
    /// `small` / `medium` / `large`.
    var cameraOverlaySize: String {
        didSet { defaults.set(cameraOverlaySize, forKey: Key.cameraOverlaySize) }
    }

    var cameraOverlayPositionValue: CameraPosition {
        CameraPosition(rawValue: cameraOverlayPosition) ?? .bottomRight
    }

    var cameraOverlaySizeValue: CameraSize {
        CameraSize(rawValue: cameraOverlaySize) ?? .medium
    }
    /// `bottomCenter` or `bottomRight`.
    var keyDisplayPosition: String {
        didSet { defaults.set(keyDisplayPosition, forKey: Key.keyDisplayPosition) }
    }
    /// Seconds the shortcut stays on screen before fading out.
    var keyDisplayDuration: Double {
        didSet { defaults.set(keyDisplayDuration, forKey: Key.keyDisplayDuration) }
    }

    var keyDisplayPositionValue: KeyDisplayPosition {
        KeyDisplayPosition(rawValue: keyDisplayPosition) ?? .bottomCenter
    }

    // MARK: - 截图

    /// `png` or `jpg`.
    var captureFormat: String {
        didSet { defaults.set(captureFormat, forKey: Key.captureFormat) }
    }
    var captureSound: Bool {
        didSet { defaults.set(captureSound, forKey: Key.captureSound) }
    }
    var captureCursor: Bool {
        didSet { defaults.set(captureCursor, forKey: Key.captureCursor) }
    }
    var showCrosshair: Bool {
        didSet { defaults.set(showCrosshair, forKey: Key.showCrosshair) }
    }
    /// 设置 → 截图 → 显示放大镜. On by default: seeing the pixels under the
    /// crosshair is the point of a snipping tool, and the magnifier steps
    /// aside once the selection is committed.
    var showLoupe: Bool {
        didSet { defaults.set(showLoupe, forKey: Key.showLoupe) }
    }

    // MARK: 截图输出：圆角 + 阴影（只作用于导出图）

    /// iShot's `needFilletOfnotSingleWindow`: round the exported screenshot.
    var captureCornerRadiusEnabled: Bool {
        didSet { defaults.set(captureCornerRadiusEnabled, forKey: Key.captureCornerRadiusEnabled) }
    }
    /// iShot's `sizeOfImageFillet`, in points. Not self-clamped inside
    /// `didSet` — assigning there would re-enter the observer; the read-side
    /// helpers below clamp instead.
    var captureCornerRadius: Double {
        didSet { defaults.set(captureCornerRadius, forKey: Key.captureCornerRadius) }
    }

    /// The radius the renderer actually uses, inside the UI's bounds.
    var exportCornerRadius: Double {
        min(max(captureCornerRadius, 0), Self.maxExportCornerRadius)
    }
    /// iShot's `needShadowOfnotSingleWindow`: drop shadow on the exported image.
    var captureShadowEnabled: Bool {
        didSet { defaults.set(captureShadowEnabled, forKey: Key.captureShadowEnabled) }
    }
    /// iShot's `sizeOfShadow`, in points: pads the canvas and sets the blur.
    var captureShadowSize: Double {
        didSet { defaults.set(captureShadowSize, forKey: Key.captureShadowSize) }
    }

    var exportShadowSize: Double {
        min(max(captureShadowSize, 0), Self.maxExportShadowSize)
    }

    /// Bounds of the two export sliders. 40 pt is already a very soft shadow on
    /// a Retina capture; beyond that the padding starts to dominate the image.
    static let maxExportCornerRadius: Double = 40
    static let maxExportShadowSize: Double = 40
    /// Defaults chosen to match iShot's neutral starting point (fillet and
    /// shadow enabled, radius 0 until the user asks for one) while keeping this
    /// app's existing output byte-identical until a toggle is flipped.
    static let defaultExportCornerRadius: Double = 12
    static let defaultExportShadowSize: Double = 12

    /// No custom status-menu labels ship: the menu bar draws each entry's
    /// canonical `MenuBarEntry.title`. A user who renamed a row keeps their
    /// value, because custom names live in their own persistent domain and
    /// only win over this registration default.
    static let defaultMenuBarCustomTitles: [String: String] = [:]

    /// Annotation toolbar order that ships with the app. 直线 sits before
    /// 椭圆, which is the order the toolbar has always drawn in practice.
    static let defaultAnnotationToolOrder: [String] = [
        AnnotationTool.move, .arrow, .rectangle, .line, .ellipse, .pencil,
        .highlighter, .mosaic, .text, .note, .counter, .sticker
    ].map(\.rawValue)

    /// The decoration the next export should apply; empty when both toggles
    /// are off, which keeps the pre-existing (undecorated) output.
    var screenshotDecoration: ScreenshotDecoration {
        ScreenshotDecoration(
            cornerRadius: captureCornerRadiusEnabled ? CGFloat(exportCornerRadius) : 0,
            shadowSize: captureShadowEnabled ? CGFloat(exportShadowSize) : 0
        )
    }
    /// Delay before a timed screenshot fires, in whole seconds.
    var timeOfDelayScreenshots: Int {
        didSet { defaults.set(timeOfDelayScreenshots, forKey: Key.timeOfDelayScreenshots) }
    }
    /// Initial selection for the preset-size mode, in points.
    var presetCaptureWidth: Int {
        didSet { defaults.set(presetCaptureWidth, forKey: Key.presetCaptureWidth) }
    }
    var presetCaptureHeight: Int {
        didSet { defaults.set(presetCaptureHeight, forKey: Key.presetCaptureHeight) }
    }

    /// `region` / `window` / `fullScreen`. The capture page opens on this mode,
    /// and the 截图 menu follows it for its default action.
    var defaultCaptureMode: String {
        didSet {
            defaults.set(defaultCaptureMode, forKey: Key.defaultCaptureMode)
            NavigationDefaults.captureMode = defaultCaptureModeValue
        }
    }

    var defaultCaptureModeValue: CaptureMode {
        CaptureMode(rawValue: defaultCaptureMode) ?? .region
    }

    // MARK: - 标注

    /// `FF3B30`-style hex. Empty means "use each tool's built-in colour", which
    /// is the historical behaviour.
    var annotationColorHex: String {
        didSet {
            defaults.set(annotationColorHex, forKey: Key.annotationColorHex)
            applyAnnotationDefaults()
        }
    }
    /// 0 means "use each tool's built-in width".
    var annotationLineWidth: Double {
        didSet {
            defaults.set(annotationLineWidth, forKey: Key.annotationLineWidth)
            applyAnnotationDefaults()
        }
    }
    var annotationFontSize: Double {
        didSet {
            defaults.set(annotationFontSize, forKey: Key.annotationFontSize)
            applyAnnotationDefaults()
        }
    }
    /// `AnnotationTool.rawValue` strings hidden from the floating toolbar.
    var annotationHiddenTools: [String] {
        didSet {
            defaults.set(annotationHiddenTools, forKey: Key.annotationHiddenTools)
            applyAnnotationDefaults()
        }
    }
    /// Full toolbar order as `AnnotationTool.rawValue` strings; tools missing
    /// from the array are appended in their built-in order.
    var annotationToolOrder: [String] {
        didSet {
            defaults.set(annotationToolOrder, forKey: Key.annotationToolOrder)
            applyAnnotationDefaults()
        }
    }
    /// Overlay-local tool shortcuts. The overlay reads this group through
    /// `annotationToolConfiguration(_:)`; it is not a Carbon registration.
    var annotationToolHotKeys: [String: [String: Int]] {
        didSet { defaults.set(annotationToolHotKeys, forKey: Key.annotationToolHotKeys) }
    }

    // MARK: - 滚图

    /// Seconds between samples. Clamped by `ScrollCaptureController`.
    var scrollCaptureInterval: Double {
        didSet { defaults.set(scrollCaptureInterval, forKey: Key.scrollCaptureInterval) }
    }
    /// Frame cap before the session finishes on its own.
    var scrollCaptureMaxFrames: Int {
        didSet { defaults.set(scrollCaptureMaxFrames, forKey: Key.scrollCaptureMaxFrames) }
    }
    /// The live progress card. Turning it off leaves the hotkey as the only way
    /// to finish; the defaults keep it on.
    var scrollCaptureShowsHUD: Bool {
        didSet { defaults.set(scrollCaptureShowsHUD, forKey: Key.scrollCaptureShowsHUD) }
    }

    // MARK: - OCR

    /// `zh+en` / `zh` / `en`. Applied to the next recognition request.
    var ocrLanguage: String {
        didSet {
            defaults.set(ocrLanguage, forKey: Key.ocrLanguage)
            TextRecognitionRuntime.languages = TextRecognition.languages(for: ocrLanguage)
        }
    }
    var ocrDetectBarcodes: Bool {
        didSet {
            defaults.set(ocrDetectBarcodes, forKey: Key.ocrDetectBarcodes)
            TextRecognitionRuntime.detectsBarcodes = ocrDetectBarcodes
        }
    }
    /// Copy the combined text and close instead of showing the result card.
    var ocrAutoCopy: Bool {
        didSet { defaults.set(ocrAutoCopy, forKey: Key.ocrAutoCopy) }
    }

    /// Most recent first, at most `recentPickedColorsLimit` entries.
    var recentPickedColors: [String] {
        didSet { defaults.set(recentPickedColors, forKey: Key.recentPickedColors) }
    }

    static let recentPickedColorsLimit = 8

    func recordPickedColor(_ hex: String) {
        var colors = recentPickedColors.filter { $0.uppercased() != hex.uppercased() }
        colors.insert(hex.uppercased(), at: 0)
        recentPickedColors = Array(colors.prefix(Self.recentPickedColorsLimit))
    }

    // MARK: - 通用

    /// The save folder chosen in Settings → 通用 → 保存. The legacy name is kept
    /// for compatibility; the value is either a `~`-prefixed preset such as
    /// `~/Desktop` or an absolute path picked with the folder panel.
    var captureDirectoryPath: String {
        didSet { defaults.set(captureDirectoryPath, forKey: Key.captureDirectoryPath) }
    }
    /// Show a Dock icon so the app can be used as a normal app window too.
    var showInDock: Bool {
        didSet { defaults.set(showInDock, forKey: Key.showInDock) }
    }
    var menuBarIconVisible: Bool {
        didSet { defaults.set(menuBarIconVisible, forKey: Key.menuBarIconVisible) }
    }

    // MARK: - 菜单栏内容

    /// Full status-menu row order. Stored as raw strings so an unknown value
    /// from a future build cannot break the menu; `menuBarOrderValue` fills in
    /// missing rows and pins 设置 / 退出 to the tail.
    var menuBarItemOrder: [String] {
        didSet {
            defaults.set(menuBarItemOrder, forKey: Key.menuBarItemOrder)
            NotificationCenter.default.post(name: .menuBarSettingsDidChange, object: self)
        }
    }

    /// Rows the user switched off. 设置 and 退出 are filtered out here as well
    /// as in the UI, so a hand-edited plist cannot lock the user out.
    var menuBarHiddenItems: [String] {
        didSet {
            defaults.set(menuBarHiddenItems, forKey: Key.menuBarHiddenItems)
            NotificationCenter.default.post(name: .menuBarSettingsDidChange, object: self)
        }
    }

    /// Custom status-menu labels, keyed by `MenuBarEntry.rawValue`.
    ///
    /// Only the status menu reads this. The 通用 → 菜单栏 row keeps the
    /// canonical title, so reordering / hiding stays recognisable even after
    /// a row was renamed; the inline field beside it shows the override.
    var menuBarCustomTitles: [String: String] {
        didSet {
            defaults.set(menuBarCustomTitles, forKey: Key.menuBarCustomTitles)
            NotificationCenter.default.post(name: .menuBarSettingsDidChange, object: self)
        }
    }

    var menuBarOrderValue: [MenuBarEntry] {
        Self.normalizedMenuBarOrder(menuBarItemOrder)
    }

    /// The label the status menu should use for `entry`.
    func menuBarTitle(for entry: MenuBarEntry) -> String {
        let custom = (menuBarCustomTitles[entry.rawValue] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? entry.title : custom
    }

    /// Store (or clear, when blank) one status-menu label. Whitespace-only
    /// input is treated as "use the default", which is what the inline editor
    /// promises.
    func setMenuBarTitle(_ title: String, for entry: MenuBarEntry) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var titles = menuBarCustomTitles
        if trimmed.isEmpty {
            titles.removeValue(forKey: entry.rawValue)
        } else {
            titles[entry.rawValue] = String(trimmed.prefix(48))
        }
        guard titles != menuBarCustomTitles else { return }
        menuBarCustomTitles = titles
    }

    /// Drop unknown rows and blank labels from a hand-edited plist.
    ///
    /// The legacy `capture` key is dropped here: one old label cannot name the
    /// four capture rows that replaced it, and applying it to all four would
    /// make the menu unreadable. The four rows fall back to their canonical
    /// titles; the order and hidden positions survive the same migration.
    static func normalizedMenuBarCustomTitles(_ raw: [String: String]) -> [String: String] {
        var titles: [String: String] = [:]
        for (key, value) in raw {
            guard MenuBarEntry(rawValue: key) != nil else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            titles[key] = String(trimmed.prefix(48))
        }
        return titles
    }

    var menuBarHiddenSet: Set<String> {
        Set(Self.normalizedMenuBarHidden(menuBarHiddenItems))
    }

    func isMenuBarEntryHidden(_ entry: MenuBarEntry) -> Bool {
        !entry.isPinned && menuBarHiddenSet.contains(entry.rawValue)
    }

    func setMenuBarEntry(_ entry: MenuBarEntry, hidden: Bool) {
        guard !entry.isPinned else { return }
        var hiddenItems = Self.normalizedMenuBarHidden(menuBarHiddenItems)
        if hidden {
            if !hiddenItems.contains(entry.rawValue) { hiddenItems.append(entry.rawValue) }
        } else {
            hiddenItems.removeAll { $0 == entry.rawValue }
        }
        menuBarHiddenItems = hiddenItems
    }

    /// Move one row by one position (the arrow buttons). Pinned rows and the
    /// pinned tail are immovable, so the user cannot hide 设置 / 退出 by
    /// parking another row after them.
    func moveMenuBarEntry(_ entry: MenuBarEntry, offset: Int) {
        guard !entry.isPinned else { return }
        var order = menuBarOrderValue
        guard let index = order.firstIndex(of: entry) else { return }
        let target = index + offset
        guard order.indices.contains(target), !order[target].isPinned else { return }
        order.swapAt(index, target)
        menuBarItemOrder = order.map(\.rawValue)
    }

    /// Drop `entry` immediately before `target` (the drag handle). Both ends
    /// must be movable; dropping onto the pinned tail is ignored.
    func moveMenuBarEntry(_ entry: MenuBarEntry, before target: MenuBarEntry) {
        guard !entry.isPinned, !target.isPinned, entry != target else { return }
        var order = menuBarOrderValue
        guard let from = order.firstIndex(of: entry),
              let to = order.firstIndex(of: target) else { return }
        order.remove(at: from)
        order.insert(entry, at: from < to ? to - 1 : to)
        menuBarItemOrder = order.map(\.rawValue)
    }

    /// Known rows in the stored order, followed by any row the stored order is
    /// missing (in declaration order), with 设置 / 退出 forced to the tail.
    ///
    /// Older builds stored one `capture` row for all four capture modes. A
    /// stored `"capture"` expands **in place** into the four rows, so an
    /// upgraded user keeps the same position and the same visibility; the
    /// array is only rewritten (cleanly) the next time the user reorders.
    static func normalizedMenuBarOrder(_ raw: [String]) -> [MenuBarEntry] {
        var order: [MenuBarEntry] = []
        for value in raw {
            if value == MenuBarEntry.legacyCaptureRawValue {
                for entry in MenuBarEntry.captureEntries where !order.contains(entry) {
                    order.append(entry)
                }
                continue
            }
            guard let entry = MenuBarEntry(rawValue: value), !order.contains(entry) else { continue }
            order.append(entry)
        }
        for entry in MenuBarEntry.allCases where !order.contains(entry) {
            order.append(entry)
        }
        let pinned = Set(MenuBarEntry.pinned)
        order.removeAll { pinned.contains($0) }
        order.append(contentsOf: MenuBarEntry.pinned)
        return order
    }

    /// Pinned rows and unknown values are dropped, duplicates collapse, and a
    /// legacy `"capture"` hides all four capture rows (the old toggle hid the
    /// single row that carried the whole submenu).
    static func normalizedMenuBarHidden(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var hidden: [String] = []
        func append(_ value: String) {
            guard let entry = MenuBarEntry(rawValue: value), !entry.isPinned else { return }
            guard seen.insert(value).inserted else { return }
            hidden.append(value)
        }
        for value in raw {
            if value == MenuBarEntry.legacyCaptureRawValue {
                MenuBarEntry.captureEntries.forEach { append($0.rawValue) }
            } else {
                append(value)
            }
        }
        return hidden
    }

    var pinScrollZoom: Bool {
        didSet { defaults.set(pinScrollZoom, forKey: Key.pinScrollZoom) }
    }
    var pinCommandScrollOpacity: Bool {
        didSet { defaults.set(pinCommandScrollOpacity, forKey: Key.pinCommandScrollOpacity) }
    }
    /// 指针反转: scroll up to zoom in on a pinned image. Off by default, which
    /// keeps the direction the app has always had (scroll down = larger).
    var pinScrollInverted: Bool {
        didSet { defaults.set(pinScrollInverted, forKey: Key.pinScrollInverted) }
    }

    /// Expanded, absolute path of the folder chosen in 保存位置. Only a leading
    /// `~` is expanded; an absolute path passes through untouched.
    var captureDirectory: URL {
        URL(fileURLWithPath: (captureDirectoryPath as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Preset selection size with the UI's own bounds applied. The settings
    /// fields accept free text; clamping here keeps a zero or a 9000 pt value
    /// from producing a degenerate or off-screen selection.
    var presetCaptureSize: CGSize {
        CGSize(
            width: CGFloat(min(max(presetCaptureWidth, Int(PresetSelection.minimumSide)), 10_000)),
            height: CGFloat(min(max(presetCaptureHeight, Int(PresetSelection.minimumSide)), 10_000))
        )
    }

    /// Delay options offered by the settings picker.
    static let delayOptions = [3, 5, 10]

    // MARK: - 外观

    /// `glass` or `classic`
    var appearanceStyle: String {
        didSet {
            defaults.set(appearanceStyle, forKey: Key.appearanceStyle)
            AppearanceRuntime.useGlass = appearanceStyle == "glass"
        }
    }
    /// Grey glyphs everywhere, with the selection as the only colour.
    var monochromeIcons: Bool {
        didSet {
            defaults.set(monochromeIcons, forKey: Key.monochromeIcons)
            AppearanceRuntime.monochromeIcons = monochromeIcons
        }
    }
    /// 外观 → 主题 → 背景不透明度. The dark-appearance **window wash** opacity
    /// (larger = more coat = more opaque); it drives *only* the window's own
    /// glass layer (`LiquidGlassWash` / `GlassOpacityRuntime.windowWash`).
    ///
    /// 2026-10-25: this used to be shared with the three column cards. The owner
    /// asked for two sliders, so the cards moved to `panelOpacity`; this key kept
    /// its name, meaning and default, so no preference needs migrating.
    var glassOpacity: Double {
        didSet {
            defaults.set(glassOpacity, forKey: Key.glassOpacity)
            // `apply` clamps for the runtime; the stored value stays as typed
            // so a future range change does not silently rewrite preferences.
            GlassOpacityRuntime.shared.apply(glassOpacity)
        }
    }
    /// 外观 → 主题 → 板块不透明度. The three vertical column cards — their coat,
    /// their depth plate and the grouped slabs / list insets nested inside them.
    ///
    /// Defaults to `GlassOpacityRuntime.panelDefaultValue` (the same 8 % the one
    /// shared slider shipped with), which reproduces the pre-split card stack
    /// exactly: an untouched install looks identical.
    var panelOpacity: Double {
        didSet {
            defaults.set(panelOpacity, forKey: Key.panelOpacity)
            GlassOpacityRuntime.shared.applyPanel(panelOpacity)
        }
    }
    /// A stored value is squeezed into the slider's range before it reaches the
    /// renderer. Today's 0–1 range is a superset of the old 0.05–0.40 one, so
    /// nobody's saved look moves; the clamp is for a hand-edited defaults file
    /// (or a future range change), where an out-of-range wash would otherwise
    /// render something the slider cannot express. It does not write back — see
    /// `glassOpacity.didSet`.
    static func clampedGlassOpacity(_ value: Double) -> Double {
        min(max(value, GlassOpacityRuntime.range.lowerBound),
            GlassOpacityRuntime.range.upperBound)
    }
    /// The same clamp for 板块不透明度. `NaN` cannot come out of a slider, but a
    /// hand-edited defaults file can hold one, and every min/max would propagate
    /// it into the renderer.
    static func clampedPanelOpacity(_ value: Double) -> Double {
        guard value.isFinite else { return GlassOpacityRuntime.panelDefaultValue }
        return min(max(value, GlassOpacityRuntime.range.lowerBound),
            GlassOpacityRuntime.range.upperBound)
    }
    /// `solid` / `translucent` / `liquidGlass` for the main window backdrop.
    var backgroundStyle: String {
        didSet {
            defaults.set(backgroundStyle, forKey: Key.backgroundStyle)
            // Glass surfaces are built from this too, not just the window shell.
            AppearanceRuntime.backgroundStyle = backgroundStyleValue
            // The window shell (opacity + clear background) depends on this,
            // not just the SwiftUI backdrop, so tell the controller to reapply.
            NotificationCenter.default.post(name: .backgroundStyleDidChange, object: self)
        }
    }

    var backgroundStyleValue: AppBackgroundStyle {
        AppBackgroundStyle(rawValue: backgroundStyle) ?? .solid
    }

    /// `light` / `dark` / `system`
    var appearanceTheme: String {
        didSet {
            defaults.set(appearanceTheme, forKey: Key.appearanceTheme)
            AppearanceRuntime.colorScheme = preferredColorScheme
        }
    }

    /// Push the current appearance into the runtime after launch.
    func applyAppearance() {
        AppearanceRuntime.useGlass = appearanceStyle == "glass"
        AppearanceRuntime.colorScheme = preferredColorScheme
        AppearanceRuntime.monochromeIcons = monochromeIcons
        applyRuntimeDefaults()
    }

    var preferredColorScheme: ColorScheme? {
        switch appearanceTheme {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Shipping preferences. Only keys that were never written fall back to
        // these, so a stored value — anything an existing user has ever
        // touched — always wins, and a default can move without a migration.
        //
        // The appearance pair ships as 液态玻璃.
        //
        // Every key below is the owner's exported preference file
        // (`Unseen-Preferences.plist`, 2026-10-23) turned into a
        // registration default, including the twelve bound hot keys. The one
        // deliberate exception is `menuBarCustomTitles`: the owner asked that
        // the status-menu renames not be baked in, so it stays empty and the
        // status menu keeps drawing each row's canonical title.
        //
        // `register(defaults:)` lands in the *registration* domain, never in
        // the persistent one, so nothing is written to disk and an existing
        // user's stored value always wins.
        defaults.register(defaults: [
            Key.pollInterval: 0.4,
            Key.maxItems: 1000,
            Key.retentionDays: 30,
            Key.ignoreConcealed: true,
            Key.ignorePasswordManagers: true,
            Key.captureImages: true,
            Key.maxImageBytes: 8 * 1024 * 1024,
            Key.autoPaste: true,
            Key.ignoredBundleIDs: [String](),
            Key.hotKeyEnabled: true,
            Key.hotKeyKeyCode: Int(HotKeyConfiguration.default.keyCode),
            Key.hotKeyModifiers: Int(HotKeyConfiguration.default.modifiers),
            Key.pinHotKeyEnabled: true,
            Key.pinHotKeyKeyCode: Int(HotKeyConfiguration.pinLastImage.keyCode),
            Key.pinHotKeyModifiers: Int(HotKeyConfiguration.pinLastImage.modifiers),
            Key.screenshotHotKeyEnabled: true,
            Key.screenshotHotKeyKeyCode: Int(HotKeyConfiguration.screenshot.keyCode),
            Key.screenshotHotKeyModifiers: Int(HotKeyConfiguration.screenshot.modifiers),
            Key.ocrHotKeyEnabled: true,
            Key.ocrHotKeyKeyCode: Int(HotKeyConfiguration.ocr.keyCode),
            Key.ocrHotKeyModifiers: Int(HotKeyConfiguration.ocr.modifiers),
            Key.scrollHotKeyEnabled: true,
            Key.scrollHotKeyKeyCode: Int(HotKeyConfiguration.scroll.keyCode),
            Key.scrollHotKeyModifiers: Int(HotKeyConfiguration.scroll.modifiers),
            Key.recordHotKeyEnabled: true,
            Key.recordHotKeyKeyCode: Int(HotKeyConfiguration.record.keyCode),
            Key.recordHotKeyModifiers: Int(HotKeyConfiguration.record.modifiers),
            Key.colorPickerHotKeyEnabled: true,
            Key.colorPickerHotKeyKeyCode: Int(HotKeyConfiguration.colorPicker.keyCode),
            Key.colorPickerHotKeyModifiers: Int(HotKeyConfiguration.colorPicker.modifiers),
            Key.beautifyHotKeyEnabled: true,
            Key.beautifyHotKeyKeyCode: Int(HotKeyConfiguration.beautify.keyCode),
            Key.beautifyHotKeyModifiers: Int(HotKeyConfiguration.beautify.modifiers),
            Key.instantWindowHotKeyEnabled: true,
            Key.instantWindowHotKeyKeyCode: Int(HotKeyConfiguration.instantWindow.keyCode),
            Key.instantWindowHotKeyModifiers: Int(HotKeyConfiguration.instantWindow.modifiers),
            Key.instantFullScreenHotKeyEnabled: true,
            Key.instantFullScreenHotKeyKeyCode: Int(HotKeyConfiguration.instantFullScreen.keyCode),
            Key.instantFullScreenHotKeyModifiers: Int(HotKeyConfiguration.instantFullScreen.modifiers),
            Key.windowHotKeyEnabled: true,
            Key.windowHotKeyKeyCode: Int(HotKeyConfiguration.windowCapture.keyCode),
            Key.windowHotKeyModifiers: Int(HotKeyConfiguration.windowCapture.modifiers),
            Key.fullScreenHotKeyEnabled: true,
            Key.fullScreenHotKeyKeyCode: Int(HotKeyConfiguration.fullScreenCapture.keyCode),
            Key.fullScreenHotKeyModifiers: Int(HotKeyConfiguration.fullScreenCapture.modifiers),
            Key.keyDisplayHotKeyEnabled: true,
            Key.keyDisplayHotKeyKeyCode: Int(HotKeyConfiguration.unbound.keyCode),
            Key.keyDisplayHotKeyModifiers: Int(HotKeyConfiguration.unbound.modifiers),
            Key.capturePresetHotKeyKeyCode: Int(HotKeyConfiguration.capturePreset.keyCode),
            Key.capturePresetHotKeyModifiers: Int(HotKeyConfiguration.capturePreset.modifiers),
            Key.delayCaptureHotKeyKeyCode: Int(HotKeyConfiguration.delayCapture.keyCode),
            Key.delayCaptureHotKeyModifiers: Int(HotKeyConfiguration.delayCapture.modifiers),
            Key.multiWindowHotKeyKeyCode: Int(HotKeyConfiguration.multiWindowCapture.keyCode),
            Key.multiWindowHotKeyModifiers: Int(HotKeyConfiguration.multiWindowCapture.modifiers),
            Key.cameraHotKeyKeyCode: Int(HotKeyConfiguration.cameraOverlay.keyCode),
            Key.cameraHotKeyModifiers: Int(HotKeyConfiguration.cameraOverlay.modifiers),
            Key.openSettingsHotKeyKeyCode: Int(HotKeyConfiguration.openSettings.keyCode),
            Key.openSettingsHotKeyModifiers: Int(HotKeyConfiguration.openSettings.modifiers),
            Key.instantCaptureSound: true,
            Key.instantCaptureVisualCue: true,
            Key.instantCaptureAlsoSave: false,
            Key.recordingFormat: "mp4",
            Key.recordingFrameRate: 30,
            Key.recordingBitrate: 12_000_000,
            Key.recordingMicrophone: false,
            Key.colorPickerFormat: "hex",
            Key.cameraOverlayEnabled: false,
            Key.cameraOverlayPosition: "bottomRight",
            Key.cameraOverlaySize: "medium",
            Key.keyDisplayEnabled: false,
            Key.keyDisplayPosition: "bottomCenter",
            Key.keyDisplayDuration: 2.0,
            Key.captureDirectoryPath: "~/Desktop",
            Key.captureFormat: "png",
            Key.captureSound: true,
            Key.captureCursor: true,
            Key.captureCornerRadiusEnabled: false,
            Key.captureCornerRadius: AppSettings.defaultExportCornerRadius,
            Key.captureShadowEnabled: false,
            Key.captureShadowSize: AppSettings.defaultExportShadowSize,
            Key.showCrosshair: true,
            Key.showLoupe: true,
            Key.timeOfDelayScreenshots: 3,
            Key.presetCaptureWidth: 600,
            Key.presetCaptureHeight: 400,
            Key.showInDock: true,
            Key.menuBarIconVisible: true,
            Key.menuBarItemOrder: MenuBarEntry.defaultOrder.map(\.rawValue),
            Key.menuBarHiddenItems: [String](),
            Key.menuBarCustomTitles: AppSettings.defaultMenuBarCustomTitles,
            Key.pinScrollZoom: true,
            Key.pinCommandScrollOpacity: true,
            Key.pinScrollInverted: false,
            Key.appearanceStyle: "glass",
            Key.backgroundStyle: "liquidGlass",
            Key.appearanceTheme: "system",
            Key.monochromeIcons: true,
            Key.glassOpacity: GlassOpacityRuntime.defaultValue,
            Key.panelOpacity: GlassOpacityRuntime.panelDefaultValue,
            Key.defaultCaptureMode: "region",
            Key.annotationColorHex: "",
            Key.annotationLineWidth: 0.0,
            Key.annotationFontSize: 20.0,
            Key.annotationHiddenTools: [String](),
            Key.annotationToolOrder: AppSettings.defaultAnnotationToolOrder,
            Key.annotationToolHotKeys: AppSettings.defaultAnnotationToolHotKeys,
            Key.scrollCaptureInterval: 0.35,
            Key.scrollCaptureMaxFrames: 200,
            Key.scrollCaptureShowsHUD: true,
            Key.ocrLanguage: "zh+en",
            Key.ocrDetectBarcodes: true,
            Key.ocrAutoCopy: false,
            Key.recentPickedColors: [String]()
        ])

        pollInterval = defaults.double(forKey: Key.pollInterval)
        maxItems = defaults.integer(forKey: Key.maxItems)
        retentionDays = defaults.integer(forKey: Key.retentionDays)
        ignoreConcealed = defaults.bool(forKey: Key.ignoreConcealed)
        ignorePasswordManagers = defaults.bool(forKey: Key.ignorePasswordManagers)
        captureImages = defaults.bool(forKey: Key.captureImages)
        maxImageBytes = defaults.integer(forKey: Key.maxImageBytes)
        autoPaste = defaults.bool(forKey: Key.autoPaste)
        hotKeyEnabled = defaults.bool(forKey: Key.hotKeyEnabled)
        hotKeyKeyCode = defaults.integer(forKey: Key.hotKeyKeyCode)
        hotKeyModifiers = defaults.integer(forKey: Key.hotKeyModifiers)
        pinHotKeyEnabled = defaults.bool(forKey: Key.pinHotKeyEnabled)
        pinHotKeyKeyCode = defaults.integer(forKey: Key.pinHotKeyKeyCode)
        pinHotKeyModifiers = defaults.integer(forKey: Key.pinHotKeyModifiers)
        screenshotHotKeyEnabled = defaults.bool(forKey: Key.screenshotHotKeyEnabled)
        screenshotHotKeyKeyCode = defaults.integer(forKey: Key.screenshotHotKeyKeyCode)
        screenshotHotKeyModifiers = defaults.integer(forKey: Key.screenshotHotKeyModifiers)
        ocrHotKeyEnabled = defaults.bool(forKey: Key.ocrHotKeyEnabled)
        ocrHotKeyKeyCode = defaults.integer(forKey: Key.ocrHotKeyKeyCode)
        ocrHotKeyModifiers = defaults.integer(forKey: Key.ocrHotKeyModifiers)
        scrollHotKeyEnabled = defaults.bool(forKey: Key.scrollHotKeyEnabled)
        scrollHotKeyKeyCode = defaults.integer(forKey: Key.scrollHotKeyKeyCode)
        scrollHotKeyModifiers = defaults.integer(forKey: Key.scrollHotKeyModifiers)
        recordHotKeyEnabled = defaults.bool(forKey: Key.recordHotKeyEnabled)
        recordHotKeyKeyCode = defaults.integer(forKey: Key.recordHotKeyKeyCode)
        recordHotKeyModifiers = defaults.integer(forKey: Key.recordHotKeyModifiers)
        colorPickerHotKeyEnabled = defaults.bool(forKey: Key.colorPickerHotKeyEnabled)
        colorPickerHotKeyKeyCode = defaults.integer(forKey: Key.colorPickerHotKeyKeyCode)
        colorPickerHotKeyModifiers = defaults.integer(forKey: Key.colorPickerHotKeyModifiers)
        beautifyHotKeyEnabled = defaults.bool(forKey: Key.beautifyHotKeyEnabled)
        beautifyHotKeyKeyCode = defaults.integer(forKey: Key.beautifyHotKeyKeyCode)
        beautifyHotKeyModifiers = defaults.integer(forKey: Key.beautifyHotKeyModifiers)
        instantWindowHotKeyEnabled = defaults.bool(forKey: Key.instantWindowHotKeyEnabled)
        instantWindowHotKeyKeyCode = defaults.integer(forKey: Key.instantWindowHotKeyKeyCode)
        instantWindowHotKeyModifiers = defaults.integer(forKey: Key.instantWindowHotKeyModifiers)
        instantFullScreenHotKeyEnabled = defaults.bool(forKey: Key.instantFullScreenHotKeyEnabled)
        instantFullScreenHotKeyKeyCode = defaults.integer(
            forKey: Key.instantFullScreenHotKeyKeyCode
        )
        instantFullScreenHotKeyModifiers = defaults.integer(
            forKey: Key.instantFullScreenHotKeyModifiers
        )
        windowHotKeyEnabled = defaults.bool(forKey: Key.windowHotKeyEnabled)
        windowHotKeyKeyCode = defaults.integer(forKey: Key.windowHotKeyKeyCode)
        windowHotKeyModifiers = defaults.integer(forKey: Key.windowHotKeyModifiers)
        fullScreenHotKeyEnabled = defaults.bool(forKey: Key.fullScreenHotKeyEnabled)
        fullScreenHotKeyKeyCode = defaults.integer(forKey: Key.fullScreenHotKeyKeyCode)
        fullScreenHotKeyModifiers = defaults.integer(forKey: Key.fullScreenHotKeyModifiers)
        keyDisplayHotKeyEnabled = defaults.bool(forKey: Key.keyDisplayHotKeyEnabled)
        keyDisplayHotKeyKeyCode = defaults.integer(forKey: Key.keyDisplayHotKeyKeyCode)
        keyDisplayHotKeyModifiers = defaults.integer(forKey: Key.keyDisplayHotKeyModifiers)
        capturePresetHotKeyKeyCode = defaults.integer(forKey: Key.capturePresetHotKeyKeyCode)
        capturePresetHotKeyModifiers = defaults.integer(forKey: Key.capturePresetHotKeyModifiers)
        delayCaptureHotKeyKeyCode = defaults.integer(forKey: Key.delayCaptureHotKeyKeyCode)
        delayCaptureHotKeyModifiers = defaults.integer(forKey: Key.delayCaptureHotKeyModifiers)
        multiWindowHotKeyKeyCode = defaults.integer(forKey: Key.multiWindowHotKeyKeyCode)
        multiWindowHotKeyModifiers = defaults.integer(forKey: Key.multiWindowHotKeyModifiers)
        cameraHotKeyKeyCode = defaults.integer(forKey: Key.cameraHotKeyKeyCode)
        cameraHotKeyModifiers = defaults.integer(forKey: Key.cameraHotKeyModifiers)
        openSettingsHotKeyKeyCode = defaults.integer(forKey: Key.openSettingsHotKeyKeyCode)
        openSettingsHotKeyModifiers = defaults.integer(forKey: Key.openSettingsHotKeyModifiers)
        instantCaptureSound = defaults.bool(forKey: Key.instantCaptureSound)
        instantCaptureVisualCue = defaults.bool(forKey: Key.instantCaptureVisualCue)
        instantCaptureAlsoSave = defaults.bool(forKey: Key.instantCaptureAlsoSave)
        recordingFormat = defaults.string(forKey: Key.recordingFormat) ?? "mp4"
        recordingFrameRate = defaults.integer(forKey: Key.recordingFrameRate)
        recordingBitrate = defaults.integer(forKey: Key.recordingBitrate)
        recordingMicrophone = defaults.bool(forKey: Key.recordingMicrophone)
        colorPickerFormat = defaults.string(forKey: Key.colorPickerFormat) ?? "hex"
        cameraOverlayEnabled = defaults.bool(forKey: Key.cameraOverlayEnabled)
        cameraOverlayPosition = defaults.string(forKey: Key.cameraOverlayPosition) ?? "bottomRight"
        cameraOverlaySize = defaults.string(forKey: Key.cameraOverlaySize) ?? "medium"
        keyDisplayEnabled = defaults.bool(forKey: Key.keyDisplayEnabled)
        keyDisplayPosition = defaults.string(forKey: Key.keyDisplayPosition) ?? "bottomCenter"
        keyDisplayDuration = defaults.double(forKey: Key.keyDisplayDuration)
        captureDirectoryPath = defaults.string(forKey: Key.captureDirectoryPath) ?? "~/Desktop"
        captureFormat = defaults.string(forKey: Key.captureFormat) ?? "png"
        captureSound = defaults.bool(forKey: Key.captureSound)
        captureCursor = defaults.bool(forKey: Key.captureCursor)
        captureCornerRadiusEnabled = defaults.bool(forKey: Key.captureCornerRadiusEnabled)
        captureCornerRadius = defaults.double(forKey: Key.captureCornerRadius)
        captureShadowEnabled = defaults.bool(forKey: Key.captureShadowEnabled)
        captureShadowSize = defaults.double(forKey: Key.captureShadowSize)
        showCrosshair = defaults.bool(forKey: Key.showCrosshair)
        showLoupe = defaults.bool(forKey: Key.showLoupe)
        timeOfDelayScreenshots = defaults.integer(forKey: Key.timeOfDelayScreenshots)
        presetCaptureWidth = defaults.integer(forKey: Key.presetCaptureWidth)
        presetCaptureHeight = defaults.integer(forKey: Key.presetCaptureHeight)
        showInDock = defaults.bool(forKey: Key.showInDock)
        menuBarIconVisible = defaults.bool(forKey: Key.menuBarIconVisible)
        menuBarItemOrder = defaults.stringArray(forKey: Key.menuBarItemOrder) ?? []
        menuBarHiddenItems = defaults.stringArray(forKey: Key.menuBarHiddenItems) ?? []
        menuBarCustomTitles = Self.normalizedMenuBarCustomTitles(
            defaults.dictionary(forKey: Key.menuBarCustomTitles) as? [String: String] ?? [:]
        )
        pinScrollZoom = defaults.bool(forKey: Key.pinScrollZoom)
        pinCommandScrollOpacity = defaults.bool(forKey: Key.pinCommandScrollOpacity)
        pinScrollInverted = defaults.bool(forKey: Key.pinScrollInverted)
        appearanceStyle = defaults.string(forKey: Key.appearanceStyle) ?? "glass"
        backgroundStyle = defaults.string(forKey: Key.backgroundStyle) ?? "liquidGlass"
        appearanceTheme = defaults.string(forKey: Key.appearanceTheme) ?? "system"
        monochromeIcons = defaults.bool(forKey: Key.monochromeIcons)
        glassOpacity = Self.clampedGlassOpacity(defaults.double(forKey: Key.glassOpacity))
        panelOpacity = Self.clampedPanelOpacity(defaults.double(forKey: Key.panelOpacity))
        defaultCaptureMode = defaults.string(forKey: Key.defaultCaptureMode) ?? "region"
        annotationColorHex = defaults.string(forKey: Key.annotationColorHex) ?? ""
        annotationLineWidth = defaults.double(forKey: Key.annotationLineWidth)
        annotationFontSize = defaults.double(forKey: Key.annotationFontSize)
        annotationHiddenTools = defaults.stringArray(forKey: Key.annotationHiddenTools) ?? []
        annotationToolOrder = defaults.stringArray(forKey: Key.annotationToolOrder) ?? []
        annotationToolHotKeys = AppSettings.normalizedAnnotationToolHotKeys(
            defaults.object(forKey: Key.annotationToolHotKeys)
        )
        scrollCaptureInterval = defaults.double(forKey: Key.scrollCaptureInterval)
        scrollCaptureMaxFrames = defaults.integer(forKey: Key.scrollCaptureMaxFrames)
        scrollCaptureShowsHUD = defaults.bool(forKey: Key.scrollCaptureShowsHUD)
        ocrLanguage = defaults.string(forKey: Key.ocrLanguage) ?? "zh+en"
        ocrDetectBarcodes = defaults.bool(forKey: Key.ocrDetectBarcodes)
        ocrAutoCopy = defaults.bool(forKey: Key.ocrAutoCopy)
        recentPickedColors = defaults.stringArray(forKey: Key.recentPickedColors) ?? []
        launchAtLogin = SMAppService.mainApp.status == .enabled

        // `ignoredBundleIDs` now ships as an empty list (the owner's exported
        // preference file). The fallback only runs when the registration
        // domain is absent, which keeps a hand-built `UserDefaults` object
        // behaving like the old build.
        if let stored = defaults.array(forKey: Key.ignoredBundleIDs) as? [String] {
            ignoredBundleIDs = Set(stored)
        } else {
            ignoredBundleIDs = Set(Self.knownPasswordManagers)
        }

        // Property observers do not run during init, so push the runtimes once
        // by hand. `applyAppearance()` also does this at launch, but self-test
        // settings objects never reach that call.
        applyRuntimeDefaults()
    }

    /// Bundle IDs that should never be recorded.
    var effectiveIgnores: Set<String> {
        var ignored = ignoredBundleIDs
        if ignorePasswordManagers {
            ignored.formUnion(Self.knownPasswordManagers)
        }
        return ignored
    }


    // MARK: - 备份 & 恢复

    /// Every persisted preference, as a plist-friendly dictionary.
    func exportPreferences() -> [String: Any] {
        var payload: [String: Any] = [:]
        for key in Self.exportedKeys {
            if let value = defaults.object(forKey: key) { payload[key] = value }
        }
        return payload
    }

    func writePreferences(to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: exportPreferences(),
            format: .xml,
            options: 0
        )
        try data.write(to: url)
    }

    func readPreferences(from url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let payload = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        for (key, value) in payload where Self.exportedKeys.contains(key) {
            defaults.set(value, forKey: key)
        }
        reloadFromDefaults()
    }

    /// Wipe every preference and re-read the defaults.
    func resetAll() {
        for key in Self.exportedKeys {
            defaults.removeObject(forKey: key)
        }
        reloadFromDefaults()
    }

    static let exportedKeys: Set<String> = [
        Key.pollInterval, Key.maxItems, Key.retentionDays, Key.ignoreConcealed,
        Key.ignorePasswordManagers, Key.captureImages, Key.maxImageBytes, Key.autoPaste,
        Key.ignoredBundleIDs, Key.hotKeyEnabled, Key.hotKeyKeyCode, Key.hotKeyModifiers,
        Key.pinHotKeyEnabled, Key.pinHotKeyKeyCode, Key.pinHotKeyModifiers,
        Key.screenshotHotKeyEnabled, Key.screenshotHotKeyKeyCode, Key.screenshotHotKeyModifiers,
        Key.ocrHotKeyEnabled, Key.ocrHotKeyKeyCode, Key.ocrHotKeyModifiers,
        Key.scrollHotKeyEnabled, Key.scrollHotKeyKeyCode, Key.scrollHotKeyModifiers,
        Key.recordHotKeyEnabled, Key.recordHotKeyKeyCode, Key.recordHotKeyModifiers,
        Key.colorPickerHotKeyEnabled, Key.colorPickerHotKeyKeyCode, Key.colorPickerHotKeyModifiers,
        Key.beautifyHotKeyEnabled, Key.beautifyHotKeyKeyCode, Key.beautifyHotKeyModifiers,
        Key.instantWindowHotKeyEnabled, Key.instantWindowHotKeyKeyCode,
        Key.instantWindowHotKeyModifiers,
        Key.instantFullScreenHotKeyEnabled, Key.instantFullScreenHotKeyKeyCode,
        Key.instantFullScreenHotKeyModifiers,
        Key.windowHotKeyEnabled, Key.windowHotKeyKeyCode, Key.windowHotKeyModifiers,
        Key.fullScreenHotKeyEnabled, Key.fullScreenHotKeyKeyCode,
        Key.fullScreenHotKeyModifiers,
        Key.keyDisplayHotKeyEnabled, Key.keyDisplayHotKeyKeyCode,
        Key.keyDisplayHotKeyModifiers,
        Key.capturePresetHotKeyKeyCode, Key.capturePresetHotKeyModifiers,
        Key.delayCaptureHotKeyKeyCode, Key.delayCaptureHotKeyModifiers,
        Key.multiWindowHotKeyKeyCode, Key.multiWindowHotKeyModifiers,
        Key.cameraHotKeyKeyCode, Key.cameraHotKeyModifiers,
        Key.openSettingsHotKeyKeyCode, Key.openSettingsHotKeyModifiers,
        Key.instantCaptureSound, Key.instantCaptureVisualCue, Key.instantCaptureAlsoSave,
        Key.recordingFormat, Key.recordingFrameRate, Key.recordingBitrate, Key.recordingMicrophone,
        Key.colorPickerFormat, Key.keyDisplayEnabled, Key.keyDisplayPosition, Key.keyDisplayDuration,
        Key.cameraOverlayEnabled, Key.cameraOverlayPosition, Key.cameraOverlaySize,
        Key.captureDirectoryPath, Key.captureFormat,
        Key.captureSound, Key.captureCursor,
        Key.captureCornerRadiusEnabled, Key.captureCornerRadius,
        Key.captureShadowEnabled, Key.captureShadowSize,
        Key.showCrosshair, Key.showLoupe,
        Key.timeOfDelayScreenshots, Key.presetCaptureWidth, Key.presetCaptureHeight,
        Key.showInDock, Key.menuBarIconVisible,
        Key.menuBarItemOrder, Key.menuBarHiddenItems, Key.menuBarCustomTitles,
        Key.pinScrollZoom, Key.pinCommandScrollOpacity, Key.pinScrollInverted,
        Key.appearanceStyle, Key.backgroundStyle, Key.appearanceTheme, Key.monochromeIcons,
        Key.glassOpacity, Key.panelOpacity, Key.defaultCaptureMode,
        Key.annotationColorHex, Key.annotationLineWidth, Key.annotationFontSize,
        Key.annotationHiddenTools, Key.annotationToolOrder,
        Key.annotationToolHotKeys,
        Key.scrollCaptureInterval, Key.scrollCaptureMaxFrames, Key.scrollCaptureShowsHUD,
        Key.ocrLanguage, Key.ocrDetectBarcodes, Key.ocrAutoCopy,
        Key.recentPickedColors
    ]

    /// Re-reads every stored property after an import or reset. Assigning runs
    /// the `didSet` observers, which is harmless — they just write back.
    private func reloadFromDefaults() {
        pollInterval = defaults.double(forKey: Key.pollInterval)
        maxItems = defaults.integer(forKey: Key.maxItems)
        retentionDays = defaults.integer(forKey: Key.retentionDays)
        ignoreConcealed = defaults.bool(forKey: Key.ignoreConcealed)
        ignorePasswordManagers = defaults.bool(forKey: Key.ignorePasswordManagers)
        captureImages = defaults.bool(forKey: Key.captureImages)
        maxImageBytes = defaults.integer(forKey: Key.maxImageBytes)
        autoPaste = defaults.bool(forKey: Key.autoPaste)
        hotKeyEnabled = defaults.bool(forKey: Key.hotKeyEnabled)
        hotKeyKeyCode = defaults.integer(forKey: Key.hotKeyKeyCode)
        hotKeyModifiers = defaults.integer(forKey: Key.hotKeyModifiers)
        pinHotKeyEnabled = defaults.bool(forKey: Key.pinHotKeyEnabled)
        pinHotKeyKeyCode = defaults.integer(forKey: Key.pinHotKeyKeyCode)
        pinHotKeyModifiers = defaults.integer(forKey: Key.pinHotKeyModifiers)
        screenshotHotKeyEnabled = defaults.bool(forKey: Key.screenshotHotKeyEnabled)
        screenshotHotKeyKeyCode = defaults.integer(forKey: Key.screenshotHotKeyKeyCode)
        screenshotHotKeyModifiers = defaults.integer(forKey: Key.screenshotHotKeyModifiers)
        ocrHotKeyEnabled = defaults.bool(forKey: Key.ocrHotKeyEnabled)
        ocrHotKeyKeyCode = defaults.integer(forKey: Key.ocrHotKeyKeyCode)
        ocrHotKeyModifiers = defaults.integer(forKey: Key.ocrHotKeyModifiers)
        scrollHotKeyEnabled = defaults.bool(forKey: Key.scrollHotKeyEnabled)
        scrollHotKeyKeyCode = defaults.integer(forKey: Key.scrollHotKeyKeyCode)
        scrollHotKeyModifiers = defaults.integer(forKey: Key.scrollHotKeyModifiers)
        recordHotKeyEnabled = defaults.bool(forKey: Key.recordHotKeyEnabled)
        recordHotKeyKeyCode = defaults.integer(forKey: Key.recordHotKeyKeyCode)
        recordHotKeyModifiers = defaults.integer(forKey: Key.recordHotKeyModifiers)
        colorPickerHotKeyEnabled = defaults.bool(forKey: Key.colorPickerHotKeyEnabled)
        colorPickerHotKeyKeyCode = defaults.integer(forKey: Key.colorPickerHotKeyKeyCode)
        colorPickerHotKeyModifiers = defaults.integer(forKey: Key.colorPickerHotKeyModifiers)
        beautifyHotKeyEnabled = defaults.bool(forKey: Key.beautifyHotKeyEnabled)
        beautifyHotKeyKeyCode = defaults.integer(forKey: Key.beautifyHotKeyKeyCode)
        beautifyHotKeyModifiers = defaults.integer(forKey: Key.beautifyHotKeyModifiers)
        instantWindowHotKeyEnabled = defaults.bool(forKey: Key.instantWindowHotKeyEnabled)
        instantWindowHotKeyKeyCode = defaults.integer(forKey: Key.instantWindowHotKeyKeyCode)
        instantWindowHotKeyModifiers = defaults.integer(forKey: Key.instantWindowHotKeyModifiers)
        instantFullScreenHotKeyEnabled = defaults.bool(forKey: Key.instantFullScreenHotKeyEnabled)
        instantFullScreenHotKeyKeyCode = defaults.integer(
            forKey: Key.instantFullScreenHotKeyKeyCode
        )
        instantFullScreenHotKeyModifiers = defaults.integer(
            forKey: Key.instantFullScreenHotKeyModifiers
        )
        windowHotKeyEnabled = defaults.bool(forKey: Key.windowHotKeyEnabled)
        windowHotKeyKeyCode = defaults.integer(forKey: Key.windowHotKeyKeyCode)
        windowHotKeyModifiers = defaults.integer(forKey: Key.windowHotKeyModifiers)
        fullScreenHotKeyEnabled = defaults.bool(forKey: Key.fullScreenHotKeyEnabled)
        fullScreenHotKeyKeyCode = defaults.integer(forKey: Key.fullScreenHotKeyKeyCode)
        fullScreenHotKeyModifiers = defaults.integer(forKey: Key.fullScreenHotKeyModifiers)
        keyDisplayHotKeyEnabled = defaults.bool(forKey: Key.keyDisplayHotKeyEnabled)
        keyDisplayHotKeyKeyCode = defaults.integer(forKey: Key.keyDisplayHotKeyKeyCode)
        keyDisplayHotKeyModifiers = defaults.integer(forKey: Key.keyDisplayHotKeyModifiers)
        capturePresetHotKeyKeyCode = defaults.integer(forKey: Key.capturePresetHotKeyKeyCode)
        capturePresetHotKeyModifiers = defaults.integer(forKey: Key.capturePresetHotKeyModifiers)
        delayCaptureHotKeyKeyCode = defaults.integer(forKey: Key.delayCaptureHotKeyKeyCode)
        delayCaptureHotKeyModifiers = defaults.integer(forKey: Key.delayCaptureHotKeyModifiers)
        multiWindowHotKeyKeyCode = defaults.integer(forKey: Key.multiWindowHotKeyKeyCode)
        multiWindowHotKeyModifiers = defaults.integer(forKey: Key.multiWindowHotKeyModifiers)
        cameraHotKeyKeyCode = defaults.integer(forKey: Key.cameraHotKeyKeyCode)
        cameraHotKeyModifiers = defaults.integer(forKey: Key.cameraHotKeyModifiers)
        openSettingsHotKeyKeyCode = defaults.integer(forKey: Key.openSettingsHotKeyKeyCode)
        openSettingsHotKeyModifiers = defaults.integer(forKey: Key.openSettingsHotKeyModifiers)
        instantCaptureSound = defaults.bool(forKey: Key.instantCaptureSound)
        instantCaptureVisualCue = defaults.bool(forKey: Key.instantCaptureVisualCue)
        instantCaptureAlsoSave = defaults.bool(forKey: Key.instantCaptureAlsoSave)
        recordingFormat = defaults.string(forKey: Key.recordingFormat) ?? "mp4"
        recordingFrameRate = defaults.integer(forKey: Key.recordingFrameRate)
        recordingBitrate = defaults.integer(forKey: Key.recordingBitrate)
        recordingMicrophone = defaults.bool(forKey: Key.recordingMicrophone)
        colorPickerFormat = defaults.string(forKey: Key.colorPickerFormat) ?? "hex"
        cameraOverlayEnabled = defaults.bool(forKey: Key.cameraOverlayEnabled)
        cameraOverlayPosition = defaults.string(forKey: Key.cameraOverlayPosition) ?? "bottomRight"
        cameraOverlaySize = defaults.string(forKey: Key.cameraOverlaySize) ?? "medium"
        keyDisplayEnabled = defaults.bool(forKey: Key.keyDisplayEnabled)
        keyDisplayPosition = defaults.string(forKey: Key.keyDisplayPosition) ?? "bottomCenter"
        keyDisplayDuration = defaults.double(forKey: Key.keyDisplayDuration)
        captureDirectoryPath = defaults.string(forKey: Key.captureDirectoryPath) ?? "~/Desktop"
        captureFormat = defaults.string(forKey: Key.captureFormat) ?? "png"
        captureSound = defaults.bool(forKey: Key.captureSound)
        captureCursor = defaults.bool(forKey: Key.captureCursor)
        captureCornerRadiusEnabled = defaults.bool(forKey: Key.captureCornerRadiusEnabled)
        captureCornerRadius = defaults.double(forKey: Key.captureCornerRadius)
        captureShadowEnabled = defaults.bool(forKey: Key.captureShadowEnabled)
        captureShadowSize = defaults.double(forKey: Key.captureShadowSize)
        showCrosshair = defaults.bool(forKey: Key.showCrosshair)
        showLoupe = defaults.bool(forKey: Key.showLoupe)
        timeOfDelayScreenshots = defaults.integer(forKey: Key.timeOfDelayScreenshots)
        presetCaptureWidth = defaults.integer(forKey: Key.presetCaptureWidth)
        presetCaptureHeight = defaults.integer(forKey: Key.presetCaptureHeight)
        showInDock = defaults.bool(forKey: Key.showInDock)
        menuBarIconVisible = defaults.bool(forKey: Key.menuBarIconVisible)
        menuBarItemOrder = defaults.stringArray(forKey: Key.menuBarItemOrder) ?? []
        menuBarHiddenItems = defaults.stringArray(forKey: Key.menuBarHiddenItems) ?? []
        menuBarCustomTitles = Self.normalizedMenuBarCustomTitles(
            defaults.dictionary(forKey: Key.menuBarCustomTitles) as? [String: String] ?? [:]
        )
        pinScrollZoom = defaults.bool(forKey: Key.pinScrollZoom)
        pinCommandScrollOpacity = defaults.bool(forKey: Key.pinCommandScrollOpacity)
        pinScrollInverted = defaults.bool(forKey: Key.pinScrollInverted)
        appearanceStyle = defaults.string(forKey: Key.appearanceStyle) ?? "glass"
        backgroundStyle = defaults.string(forKey: Key.backgroundStyle) ?? "liquidGlass"
        appearanceTheme = defaults.string(forKey: Key.appearanceTheme) ?? "system"
        monochromeIcons = defaults.bool(forKey: Key.monochromeIcons)
        glassOpacity = Self.clampedGlassOpacity(defaults.double(forKey: Key.glassOpacity))
        panelOpacity = Self.clampedPanelOpacity(defaults.double(forKey: Key.panelOpacity))
        defaultCaptureMode = defaults.string(forKey: Key.defaultCaptureMode) ?? "region"
        annotationColorHex = defaults.string(forKey: Key.annotationColorHex) ?? ""
        annotationLineWidth = defaults.double(forKey: Key.annotationLineWidth)
        annotationFontSize = defaults.double(forKey: Key.annotationFontSize)
        annotationHiddenTools = defaults.stringArray(forKey: Key.annotationHiddenTools) ?? []
        annotationToolOrder = defaults.stringArray(forKey: Key.annotationToolOrder) ?? []
        annotationToolHotKeys = AppSettings.normalizedAnnotationToolHotKeys(
            defaults.object(forKey: Key.annotationToolHotKeys)
        )
        scrollCaptureInterval = defaults.double(forKey: Key.scrollCaptureInterval)
        scrollCaptureMaxFrames = defaults.integer(forKey: Key.scrollCaptureMaxFrames)
        scrollCaptureShowsHUD = defaults.bool(forKey: Key.scrollCaptureShowsHUD)
        ocrLanguage = defaults.string(forKey: Key.ocrLanguage) ?? "zh+en"
        ocrDetectBarcodes = defaults.bool(forKey: Key.ocrDetectBarcodes)
        ocrAutoCopy = defaults.bool(forKey: Key.ocrAutoCopy)
        recentPickedColors = defaults.stringArray(forKey: Key.recentPickedColors) ?? []
        applyRuntimeDefaults()
    }

    /// Push the annotation defaults into the live renderer. The five annotation
    /// keys act as one group, so every `didSet` calls this.
    private func applyAnnotationDefaults() {
        AnnotationDefaults.apply(
            colorHex: annotationColorHex,
            lineWidth: annotationLineWidth,
            fontSize: annotationFontSize,
            hiddenTools: annotationHiddenTools,
            toolOrder: annotationToolOrder
        )
    }

    /// Push the appearance / annotation / OCR / capture-mode runtime mirrors.
    /// Property observers do not run during init, so init calls this by hand.
    private func applyRuntimeDefaults() {
        AppearanceRuntime.backgroundStyle = backgroundStyleValue
        GlassOpacityRuntime.shared.apply(glassOpacity)
        GlassOpacityRuntime.shared.applyPanel(panelOpacity)
        applyAnnotationDefaults()
        TextRecognitionRuntime.languages = TextRecognition.languages(for: ocrLanguage)
        TextRecognitionRuntime.detectsBarcodes = ocrDetectBarcodes
        NavigationDefaults.captureMode = defaultCaptureModeValue
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Roll the toggle back so the UI never lies about the real state.
            let actual = SMAppService.mainApp.status == .enabled
            if actual != launchAtLogin {
                launchAtLogin = actual
            }
        }
    }
}


extension Notification.Name {
    /// Posted when 外观 → 背景 changes, so the main window can update its
    /// opacity and background colour (`isOpaque` must be true only for 纯色).
    static let backgroundStyleDidChange = Notification.Name("Unseen.backgroundStyleDidChange")

    /// Posted when 通用 → 菜单栏 changes the status-menu contents, so the
    /// status item can rebuild its menu immediately.
    static let menuBarSettingsDidChange = Notification.Name("Unseen.menuBarSettingsDidChange")
}

import AppKit
import Carbon.HIToolbox
import Foundation

/// A global shortcut: Carbon virtual key code + Carbon modifier mask.
struct HotKeyConfiguration: Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32

    /// The shipped default for each action, taken from the owner's exported
    /// preference file (`Unseen-Preferences.plist`): a fresh install
    /// opens with the combinations they actually use, not thirteen empty
    /// slots. OCR / 取色 / 按键显示 / 套壳 stay unbound because that file has
    /// them unbound.
    ///
    /// These are **registration defaults** only: `AppSettings.register(defaults:)`
    /// mirrors the same numbers for a fresh preference domain, and a stored
    /// value always wins, so an existing user's bindings never move.
    ///
    /// The named constants exist because the settings rows, the recorder's
    /// 默认 button and the self test refer to them by action.
    static let `default` = HotKeyConfiguration(keyCode: 35, modifiers: UInt32(cmdKey))
    static let pinLastImage = HotKeyConfiguration(
        keyCode: 35,
        modifiers: UInt32(cmdKey | shiftKey)
    )
    static let screenshot = HotKeyConfiguration(keyCode: 0, modifiers: UInt32(optionKey))
    static let ocr = HotKeyConfiguration.unbound
    static let scroll = HotKeyConfiguration(keyCode: 6, modifiers: UInt32(optionKey))
    static let record = HotKeyConfiguration(keyCode: 7, modifiers: UInt32(optionKey))
    static let colorPicker = HotKeyConfiguration.unbound
    static let beautify = HotKeyConfiguration.unbound
    static let instantWindow = HotKeyConfiguration(keyCode: 1, modifiers: UInt32(optionKey))
    static let instantFullScreen = HotKeyConfiguration(keyCode: 2, modifiers: UInt32(optionKey))
    static let windowCapture = HotKeyConfiguration(keyCode: 12, modifiers: UInt32(optionKey))
    static let fullScreenCapture = HotKeyConfiguration(keyCode: 13, modifiers: UInt32(optionKey))
    /// 固定大小 / 延时 / 多窗口 were menu-only. They now have their own
    /// configurable slots, seeded with the app-menu combinations they have
    /// always used (⌃⌥⌘E / ⌃⌥⌘D / ⌃⌥⌘M) so the two surfaces never disagree.
    static let capturePreset = HotKeyConfiguration(
        keyCode: UInt32(kVK_ANSI_E),
        modifiers: UInt32(controlKey | optionKey | cmdKey)
    )
    static let delayCapture = HotKeyConfiguration(
        keyCode: UInt32(kVK_ANSI_D),
        modifiers: UInt32(controlKey | optionKey | cmdKey)
    )
    static let multiWindowCapture = HotKeyConfiguration(
        keyCode: UInt32(kVK_ANSI_M),
        modifiers: UInt32(controlKey | optionKey | cmdKey)
    )
    static let cameraOverlay = HotKeyConfiguration.unbound
    static let openSettings = HotKeyConfiguration.unbound

    /// The overlay-local default for one annotation tool.
    ///
    /// The tools deliberately ship on **⌘1 … ⌘9, ⌘0, ⌘-, ⌘=**: the bare
    /// digits are already the overlay's aspect-ratio lock (0 = free, 1 = 1:1
    /// …), and moving those would change a gesture the owner uses on every
    /// capture. ⌘1 and friends keep the numeral mnemonic without taking the
    /// bare digits away. None of these is registered as a system-wide hotkey —
    /// the overlay matches them inside its own `keyDown`.
    static func annotationTool(_ tool: AnnotationTool) -> HotKeyConfiguration {
        HotKeyConfiguration(
            keyCode: annotationToolKeyCode(tool),
            modifiers: UInt32(cmdKey)
        )
    }

    private static func annotationToolKeyCode(_ tool: AnnotationTool) -> UInt32 {
        switch tool {
        case .move: UInt32(kVK_ANSI_1)
        case .arrow: UInt32(kVK_ANSI_2)
        case .rectangle: UInt32(kVK_ANSI_3)
        case .ellipse: UInt32(kVK_ANSI_4)
        case .line: UInt32(kVK_ANSI_5)
        case .pencil: UInt32(kVK_ANSI_6)
        case .highlighter: UInt32(kVK_ANSI_7)
        case .mosaic: UInt32(kVK_ANSI_8)
        case .text: UInt32(kVK_ANSI_9)
        case .note: UInt32(kVK_ANSI_0)
        case .counter: UInt32(kVK_ANSI_Minus)
        case .sticker: UInt32(kVK_ANSI_Equal)
        }
    }

    /// No shortcut. `modifiers == 0` is the wire form: every usable global
    /// hotkey needs at least one of ⌘ / ⌥ / ⌃, so a zero mask can never be a
    /// real binding (key code 0 alone is just the A key).
    static let unbound = HotKeyConfiguration(keyCode: 0, modifiers: 0)

    /// `false` for the grey 「快捷键」 placeholder in the recorder.
    var isBound: Bool { modifiers != 0 }

    var displayString: String {
        KeyCodeFormatter.display(keyCode: keyCode, modifiers: modifiers)
    }
}

/// The shortcuts the app can own. Raw values feed the Carbon hot key id.
enum HotKeyAction: UInt32, CaseIterable {
    case openPanel = 1
    case pinLastImage = 2
    case screenshot = 3
    case ocr = 4
    case scroll = 5
    case record = 6
    case colorPicker = 7
    case beautify = 8
    case instantWindow = 9
    case instantFullScreen = 10
    case windowCapture = 11
    case fullScreenCapture = 12
    case keyDisplay = 13
    case capturePreset = 14
    case delayCapture = 15
    case multiWindowCapture = 16
    case cameraOverlay = 17
    case openSettings = 18
    /// Not a user binding. Bare Escape, registered only while a scrolling
    /// capture has handed the keyboard to the page (see `setScrollEscape`).
    case scrollEscape = 19
}

/// Every row that owns a configurable shortcut, in the order the
/// 系统 → 快捷键 page draws it.
///
/// The twelve annotation tools are **overlay-local**: the capture overlay
/// matches their combination inside its own `keyDown`, so they never reach
/// Carbon and can never steal a key from another app. Every other row is a
/// real global hotkey and is registered by `AppDelegate`.
enum HotKeyBindingID: String, CaseIterable, Identifiable, Sendable {
    // 标注工具 — twelve tools, matched by the capture overlay.
    case toolMove
    case toolArrow
    case toolRectangle
    case toolEllipse
    case toolLine
    case toolPencil
    case toolHighlighter
    case toolMosaic
    case toolText
    case toolNote
    case toolCounter
    case toolSticker

    // 截图
    case region
    case window
    case capturePreset
    case fullScreen
    case instantWindow
    case instantFullScreen
    case scroll
    case beautify

    // 工具
    case ocr
    case colorPicker
    case keyDisplay
    case record

    // 应用
    case openPanel
    case pin
    case delayCapture
    case multiWindow
    case camera
    case openSettings

    var id: String { rawValue }

    /// The annotation tool this row selects, or `nil` for a global action.
    var annotationTool: AnnotationTool? {
        switch self {
        case .toolMove: .move
        case .toolArrow: .arrow
        case .toolRectangle: .rectangle
        case .toolEllipse: .ellipse
        case .toolLine: .line
        case .toolPencil: .pencil
        case .toolHighlighter: .highlighter
        case .toolMosaic: .mosaic
        case .toolText: .text
        case .toolNote: .note
        case .toolCounter: .counter
        case .toolSticker: .sticker
        default: nil
        }
    }

    /// `false` for the overlay-local rows: no Carbon registration at all.
    var isGlobal: Bool { annotationTool == nil }

    var title: String {
        switch self {
        case .toolMove: "移动"
        case .toolArrow: "箭头"
        case .toolRectangle: "矩形"
        case .toolEllipse: "椭圆"
        case .toolLine: "直线"
        case .toolPencil: "铅笔"
        case .toolHighlighter: "荧光笔"
        case .toolMosaic: "马赛克"
        case .toolText: "文字"
        case .toolNote: "便签"
        case .toolCounter: "序号"
        case .toolSticker: "贴纸"
        case .region: "区域截图"
        case .window: "窗口截图"
        case .fullScreen: "全屏截图"
        case .instantWindow: "即时窗口"
        case .instantFullScreen: "即时全屏"
        case .scroll: "长截图"
        case .beautify: "套壳·美化"
        case .ocr: "OCR"
        case .colorPicker: "取色"
        case .keyDisplay: "按键显示"
        case .record: "录屏"
        case .openPanel: "打开面板"
        case .pin: "钉图"
        case .capturePreset: "固定大小截图"
        case .delayCapture: "延时截图"
        case .multiWindow: "多窗口截图"
        case .camera: "摄像头画中画"
        case .openSettings: "打开设置"
        }
    }

    var symbol: String {
        switch self {
        case .toolMove: "hand.raised"
        case .toolArrow: "arrow.up.right"
        case .toolRectangle: "rectangle"
        case .toolEllipse: "circle"
        case .toolLine: "line.diagonal"
        case .toolPencil: "scribble"
        case .toolHighlighter: "highlighter"
        case .toolMosaic: "squareshape.split.2x2"
        case .toolText: "text.cursor"
        case .toolNote: "note.text"
        case .toolCounter: "number.circle"
        case .toolSticker: "theatermasks"
        case .region: "rectangle.dashed"
        case .window: "macwindow"
        case .fullScreen: "rectangle.inset.filled"
        case .instantWindow: "macwindow.on.rectangle"
        case .instantFullScreen: "bolt.fill"
        case .scroll: "arrow.up.and.down.text.horizontal"
        case .beautify: "sparkles.rectangle.stack"
        case .ocr: "text.viewfinder"
        case .colorPicker: "eyedropper"
        case .keyDisplay: "keyboard"
        case .record: "record.circle"
        case .openPanel: "doc.on.clipboard"
        case .pin: "pin.fill"
        case .capturePreset: "aspectratio"
        case .delayCapture: "timer"
        case .multiWindow: "rectangle.on.rectangle"
        case .camera: "video"
        case .openSettings: "gearshape"
        }
    }

    var detail: String {
        switch self {
        case .toolMove: "拖动选区 / 标注"
        case .toolArrow: "画箭头"
        case .toolRectangle: "画矩形"
        case .toolEllipse: "画椭圆"
        case .toolLine: "画直线"
        case .toolPencil: "自由绘制"
        case .toolHighlighter: "荧光笔高亮"
        case .toolMosaic: "马赛克遮挡"
        case .toolText: "点击输入文字"
        case .toolNote: "点击添加便签"
        case .toolCounter: "点击放置序号"
        case .toolSticker: "选择表情贴纸"
        case .region: "拖拽框选区域"
        case .window: "悬停高亮，单击确认窗口"
        case .fullScreen: "直接截取鼠标所在屏幕"
        case .instantWindow: "无覆盖层，直接截光标下的窗口"
        case .instantFullScreen: "无覆盖层，直接截整屏"
        case .scroll: "滚动页面自动拼接成长图"
        case .beautify: "框选后调留白、圆角、阴影"
        case .ocr: "框选后直接识别文字"
        case .colorPicker: "放大镜取色并复制"
        case .keyDisplay: "在屏幕上显示按下的组合键"
        case .record: "开始 / 停止整屏录制"
        case .openPanel: "打开剪贴板历史面板"
        case .pin: "不用打开面板，直接钉住最近一张图片"
        case .capturePreset: "按预设的宽 × 高截取"
        case .delayCapture: "倒计时后截取鼠标所在屏幕"
        case .multiWindow: "连续点选多个窗口，合成一张图"
        case .camera: "显示 / 隐藏摄像头画中画"
        case .openSettings: "打开设置窗口"
        }
    }
}

/// The four blocks the 快捷键 page is divided into.
///
/// The order here is the order the page draws, and together the blocks cover
/// `HotKeyBindingID.allCases` exactly once (the self test pins that).
enum HotKeyGroup: String, CaseIterable, Identifiable, Sendable {
    case annotationTools
    case capture
    case tools
    case application

    var id: String { rawValue }

    var title: String {
        switch self {
        case .annotationTools: "标注工具"
        case .capture: "截图"
        case .tools: "工具"
        case .application: "应用"
        }
    }

    var symbol: String {
        switch self {
        case .annotationTools: "pencil.tip"
        case .capture: "camera.viewfinder"
        case .tools: "wrench.and.screwdriver"
        case .application: "app.badge"
        }
    }

    var members: [HotKeyBindingID] {
        switch self {
        case .annotationTools:
            [
                .toolMove, .toolArrow, .toolRectangle, .toolEllipse,
                .toolLine, .toolPencil, .toolHighlighter, .toolMosaic,
                .toolText, .toolNote, .toolCounter, .toolSticker
            ]
        case .capture:
            [
                .region, .window, .capturePreset, .fullScreen,
                .instantWindow, .instantFullScreen, .scroll, .beautify
            ]
        case .tools: [.ocr, .colorPicker, .keyDisplay, .record]
        case .application:
            [.openPanel, .pin, .delayCapture, .multiWindow, .camera, .openSettings]
        }
    }

    /// The group that owns `id`.
    static func group(of id: HotKeyBindingID) -> HotKeyGroup {
        allCases.first { $0.members.contains(id) } ?? .application
    }
}

/// One row's current binding, as the conflict detector sees it.
struct HotKeyBinding: Identifiable, Equatable {
    let id: String
    let title: String
    let configuration: HotKeyConfiguration
    let isEnabled: Bool

    /// Only an enabled, actually-bound row can collide: an unbound row has no
    /// key to press, and a disabled feature is never registered.
    var isActive: Bool { isEnabled && configuration.isBound }
}

/// Duplicate detection across the app's own shortcuts. The system cannot tell
/// us about another app's registration here, but two of ours sharing a combo
/// is exactly the case the settings page can prevent.
enum HotKeyConflicts {
    /// The label of the first *other* active row that uses the same combo.
    static func duplicateLabel(for id: String, among bindings: [HotKeyBinding]) -> String? {
        guard let binding = bindings.first(where: { $0.id == id }), binding.isActive else {
            return nil
        }
        guard let other = bindings.first(where: {
            $0.id != id && $0.isActive && $0.configuration == binding.configuration
        }) else { return nil }
        return "与「\(other.title)」重复"
    }

    static func conflictingIDs(in bindings: [HotKeyBinding]) -> Set<String> {
        let active = bindings.filter(\.isActive)
        var result: Set<String> = []
        for binding in active where active.contains(where: {
            $0.id != binding.id && $0.configuration == binding.configuration
        }) {
            result.insert(binding.id)
        }
        return result
    }
}

/// Nonisolated constant so the C event callback can compare against it.
private enum HotKeyIdentity {
    static let signature: OSType = 0x484D4342  // 'HMCB'
}

/// Registers system-wide hotkeys through the Carbon Hot Key API.
///
/// This deliberately avoids `NSEvent.addGlobalMonitorForEvents`, which would
/// require the user to grant Accessibility / Input Monitoring access.
/// `RegisterEventHotKey` needs no permission at all.
@MainActor
final class GlobalHotKeyCenter {
    static let shared = GlobalHotKeyCenter()

    private var references: [HotKeyAction: EventHotKeyRef] = [:]
    private var handlers: [HotKeyAction: () -> Void] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private(set) var lastErrors: [HotKeyAction: String] = [:]

    private init() {}

    /// Register (or replace) the shortcut for one action.
    /// Returns `false` when the combo is already taken by someone else.
    @discardableResult
    func set(
        _ action: HotKeyAction,
        configuration: HotKeyConfiguration?,
        handler: @escaping () -> Void
    ) -> Bool {
        unregister(action)
        installEventHandlerIfNeeded()

        guard let configuration, configuration.isBound else {
            handlers[action] = nil
            lastErrors[action] = nil
            return true
        }

        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            configuration.keyCode,
            configuration.modifiers,
            EventHotKeyID(signature: HotKeyIdentity.signature, id: action.rawValue),
            GetApplicationEventTarget(),
            0,
            &reference
        )

        guard status == noErr, let reference else {
            lastErrors[action] = "无法注册 \(configuration.displayString)（错误码 \(status)），可能已被其他 App 占用。"
            handlers[action] = nil
            return false
        }

        references[action] = reference
        handlers[action] = handler
        lastErrors[action] = nil
        DebugLog.log("registered \(action) hotkey as \(configuration.displayString)")
        return true
    }

    func unregister(_ action: HotKeyAction) {
        if let reference = references.removeValue(forKey: action) {
            UnregisterEventHotKey(reference)
        }
        handlers[action] = nil
    }

    /// Own bare Escape for the lifetime of a scrolling session.
    ///
    /// A running scroll capture is mouse-transparent **and** hands activation
    /// to the page it is sampling, so the overlay never receives `keyDown`:
    /// the page's app owns the keyboard. Carbon hot keys are the app's
    /// existing, permission-free transport, and a zero-modifier binding is
    /// deliberately unavailable to users (`HotKeyConfiguration.isBound`), so
    /// this can only ever be the internal escape hatch for that session.
    ///
    /// Returns `false` when the key cannot be registered; ⌥Z still stops the
    /// session, so the capture is never trapped.
    @discardableResult
    func setScrollEscape(handler: @escaping () -> Void) -> Bool {
        unregister(.scrollEscape)
        installEventHandlerIfNeeded()

        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_Escape),
            0,
            EventHotKeyID(
                signature: HotKeyIdentity.signature,
                id: HotKeyAction.scrollEscape.rawValue
            ),
            GetApplicationEventTarget(),
            0,
            &reference
        )

        guard status == noErr, let reference else {
            lastErrors[.scrollEscape] = "无法注册 Esc（错误码 \(status)），滚动截图仍可用 ⌥Z 结束。"
            handlers[.scrollEscape] = nil
            DebugLog.log("scroll: escape hotkey registration failed (\(status))")
            return false
        }

        references[.scrollEscape] = reference
        handlers[.scrollEscape] = handler
        lastErrors[.scrollEscape] = nil
        DebugLog.log("registered scroll escape hotkey (bare Esc)")
        return true
    }

    /// Give Escape back to the system. Called on every scroll exit.
    func clearScrollEscape() {
        guard references[.scrollEscape] != nil || handlers[.scrollEscape] != nil else { return }
        unregister(.scrollEscape)
        DebugLog.log("unregistered scroll escape hotkey")
    }

    fileprivate func fire(_ action: HotKeyAction) {
        handlers[action]?()
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var specification = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )
                guard status == noErr,
                      identifier.signature == HotKeyIdentity.signature,
                      let action = HotKeyAction(rawValue: identifier.id) else {
                    return OSStatus(eventNotHandledErr)
                }
                // Carbon delivers hot key events on the main run loop.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { GlobalHotKeyCenter.shared.fire(action) }
                }
                return noErr
            },
            1,
            &specification,
            nil,
            &eventHandlerRef
        )
    }

    // MARK: - Testing hook

    /// Posts the same Carbon event the window server would send, so the handler
    /// chain can be verified without actually pressing keys.
    static func postSyntheticHotKeyForDebugging(_ action: HotKeyAction = .openPanel) {
        var event: EventRef?
        guard CreateEvent(
            nil,
            OSType(kEventClassKeyboard),
            UInt32(kEventHotKeyPressed),
            GetCurrentEventTime(),
            EventAttributes(kEventAttributeNone),
            &event
        ) == noErr, let event else { return }

        var identifier = EventHotKeyID(signature: HotKeyIdentity.signature, id: action.rawValue)
        SetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            MemoryLayout<EventHotKeyID>.size,
            &identifier
        )
        SendEventToEventTarget(event, GetApplicationEventTarget())
        ReleaseEvent(event)
    }
}

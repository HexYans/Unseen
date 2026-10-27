import AppKit

/// One configurable row of the status-bar menu.
///
/// 设置 → 通用 → 菜单栏 lists these rows: the user ticks which ones appear,
/// drags (or arrows) them into order, and the status menu is rebuilt from
/// `AppSettings.menuBarOrderValue` / `menuBarHiddenItems`. 设置 and 退出 are
/// pinned: hiding them would leave no way back into the app.
///
/// The four capture modes are four *separate* rows rather than one 截图
/// submenu. The user asked for them to be listed directly in the status menu
/// ("点击后才弹出四个截图类型…直接罗列到菜单栏"), so each mode is now its own
/// configurable row: it can be hidden, renamed and reordered on its own.
enum MenuBarEntry: String, CaseIterable, Identifiable, Sendable {
    case openClipboard
    case captureRegion
    case captureWindow
    case capturePreset
    case captureFullScreen
    case ocr
    case scroll
    case recording
    case colorPicker
    case keyDisplay
    case camera
    case about
    case settings
    case quit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openClipboard: "打开剪贴板"
        case .captureRegion: "区域截图"
        case .captureWindow: "窗口截图"
        case .capturePreset: "固定大小截图"
        case .captureFullScreen: "全屏截图"
        case .ocr: "识别文字（OCR）"
        case .scroll: "长截图"
        case .recording: "开始 / 停止录屏"
        case .colorPicker: "取色"
        case .keyDisplay: "按键显示"
        case .camera: "摄像头画中画"
        case .about: "关于"
        case .settings: "设置"
        case .quit: "退出"
        }
    }

    var symbol: String {
        switch self {
        case .openClipboard: "doc.on.clipboard"
        case .captureRegion: "rectangle.dashed"
        case .captureWindow: "macwindow"
        case .capturePreset: "aspectratio"
        case .captureFullScreen: "rectangle.inset.filled"
        case .ocr: "text.viewfinder"
        case .scroll: "arrow.up.and.down.text.horizontal"
        case .recording: "record.circle"
        case .colorPicker: "eyedropper"
        case .keyDisplay: "keyboard"
        case .camera: "video"
        case .about: "info.circle"
        case .settings: "gearshape"
        case .quit: "power"
        }
    }

    /// One line of explanation under the row title.
    var detail: String {
        switch self {
        case .openClipboard: "左键点菜单栏图标时调出历史面板"
        case .captureRegion: "拖拽框选任意区域"
        case .captureWindow: "悬停高亮，单击确认要截的窗口"
        case .capturePreset: "按预设的宽 × 高截取"
        case .captureFullScreen: "直接截取鼠标所在屏幕"
        case .ocr: "框选后直接识别文字"
        case .scroll: "滚动页面自动拼接成长图"
        case .recording: "开始 / 停止整屏录制"
        case .colorPicker: "放大镜取色并复制"
        case .keyDisplay: "在屏幕上显示按下的组合键"
        case .camera: "录屏时显示摄像头画中画"
        case .about: "版本与版权信息"
        case .settings: "固定显示，不能隐藏"
        case .quit: "固定显示，不能隐藏"
        }
    }

    /// Hiding either of these would leave no way back into the app.
    var isPinned: Bool { self == .settings || self == .quit }

    /// 关于 / 设置 / 退出 sit below the status menu's divider.
    var isUtility: Bool { self == .about || self == .settings || self == .quit }

    static let pinned: [MenuBarEntry] = [.settings, .quit]

    /// The four capture rows, in the order they ship and the order the legacy
    /// single 截图 row expands into.
    static let captureEntries: [MenuBarEntry] = [
        .captureRegion, .captureWindow, .capturePreset, .captureFullScreen
    ]

    /// The one status-menu row older builds stored for all four capture modes.
    /// It survives only as a *read-time* migration token: a stored order or
    /// hidden list containing `"capture"` expands to `captureEntries` in place.
    /// It is deliberately not a case any more, so nothing can newly write it
    /// and `MenuBarEntry(rawValue: "capture")` stays nil for titles.
    static let legacyCaptureRawValue = "capture"

    static let defaultOrder: [MenuBarEntry] = allCases
}

extension MenuBarEntry {
    /// The bindable global shortcut this status row stands for.
    ///
    /// Five rows have none by design: 固定大小截图 (only the app menu's ⌃⌥⌘E),
    /// 摄像头, 关于 and the pinned 设置 / 退出. They fall back to the app-menu
    /// combination in `AppMenuBuilder.shortcut(for:settings:)`, or to nothing.
    var hotKeyID: HotKeyBindingID? {
        switch self {
        case .openClipboard: .openPanel
        case .captureRegion: .region
        case .captureWindow: .window
        case .captureFullScreen: .fullScreen
        case .capturePreset: .capturePreset
        case .ocr: .ocr
        case .scroll: .scroll
        case .recording: .record
        case .colorPicker: .colorPicker
        case .keyDisplay: .keyDisplay
        case .camera: .camera
        case .about, .settings, .quit: nil
        }
    }
}

/// Builds the standard application menu.
///
/// An accessory (menu-bar-only) app can get away with having no main menu, but
/// as soon as it shows a Dock icon and real windows people expect ⌘Q, ⌘W and —
/// crucially — ⌘C/⌘V inside text fields, which only work via an Edit menu.
@MainActor
enum AppMenuBuilder {
    static func install(appName: String, delegate: AppDelegate) {
        let mainMenu = NSMenu()

        mainMenu.addItem(appMenu(appName: appName, delegate: delegate))
        mainMenu.addItem(editMenu())
        mainMenu.addItem(viewMenu(delegate: delegate))
        mainMenu.addItem(captureMenu(delegate: delegate))
        mainMenu.addItem(windowMenu())
        mainMenu.addItem(helpMenu(appName: appName, delegate: delegate))

        NSApp.mainMenu = mainMenu
    }

    /// The status-item menu. Left-clicking the menu bar icon opens this instead
    /// of the clipboard panel; the panel keeps its global shortcut (⌘P).
    ///
    /// The capture entries reuse the same selectors as the main 截图 menu, so
    /// both surfaces cannot drift apart in behaviour.
    ///
    /// **Every row that has a shortcut names it in the right-hand column.** The
    /// key is the one that actually invokes the row: its bindable global hotkey
    /// (only while the feature's switch is on and the slot is bound), or — for
    /// the rows that have no bindable slot — the app-menu equivalent they share
    /// (固定大小截图 ⌃⌥⌘E, 设置 ⌘, 退出 ⌘Q). A row with neither draws nothing:
    /// an empty right column is the honest answer, not a placeholder.
    ///
    /// The key equivalent is *not* a second registration. `RegisterEventHotKey`
    /// consumes the press system-wide, so on a globally bound row the menu
    /// never sees a key-down; the column is what AppKit draws from
    /// `keyEquivalent` + `keyEquivalentModifierMask`, and the action still runs
    /// through the one Carbon handler. For the utility rows there is no Carbon
    /// registration at all, so the menu item is the only handler and it fires
    /// while the menu is open, exactly like the same item in the app menu.
    ///
    /// Which rows appear, and in what order, comes from `settings`: the
    /// 通用 → 菜单栏 page edits `menuBarItemOrder` / `menuBarHiddenItems`.
    /// 设置 / 退出 stay visible and stay last.
    static func statusMenu(settings: AppSettings, target: AnyObject) -> NSMenu {
        let menu = NSMenu(title: "Unseen")

        var addedTailSeparator = false
        for entry in settings.menuBarOrderValue where !settings.isMenuBarEntryHidden(entry) {
            // One divider separates the feature rows from the utility tail
            // (关于 / 设置 / 退出). 设置 / 退出 are pinned last, but 关于 stays
            // reorderable, so anchor the divider at the first utility row the
            // user actually kept above the pinned pair.
            if entry.isUtility, !menu.items.isEmpty, !addedTailSeparator {
                menu.addItem(.separator())
                addedTailSeparator = true
            }
            let item = addStatusEntry(entry, to: menu, target: target, settings: settings)
            applyShortcut(entry, to: item, settings: settings)
        }

        return menu
    }

    /// The shortcut column of one status row.
    ///
    /// `nil` means "draw nothing": either the action's switch is off, its slot
    /// is unbound, or the row simply has no shortcut (摄像头 / 关于). No
    /// placeholder is written in that case — a greyed-out stand-in would claim
    /// a key that does not exist.
    private static func shortcut(
        for entry: MenuBarEntry,
        settings: AppSettings
    ) -> (key: String, mask: NSEvent.ModifierFlags)? {
        if let id = entry.hotKeyID {
            let state = settings.hotKeyState(id)
            guard state.enabled, state.configuration.isBound else { return nil }
            return KeyCodeFormatter.menuKeyEquivalent(
                keyCode: state.configuration.keyCode,
                modifiers: state.configuration.modifiers
            )
        }

        // Rows with no bindable global slot still have the shortcut the app
        // menu gives them. Keeping the same combination in both places means
        // the menu never shows two different keys for one action.
        switch entry {
        case .capturePreset: return ("e", [.control, .option, .command])
        case .settings: return (",", [.command])
        case .quit: return ("q", [.command])
        default: return nil
        }
    }

    private static func applyShortcut(
        _ entry: MenuBarEntry,
        to item: NSMenuItem,
        settings: AppSettings
    ) {
        guard let shortcut = shortcut(for: entry, settings: settings) else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        item.keyEquivalent = shortcut.key
        item.keyEquivalentModifierMask = shortcut.mask
    }

    @discardableResult
    private static func addStatusEntry(
        _ entry: MenuBarEntry,
        to menu: NSMenu,
        target: AnyObject,
        settings: AppSettings
    ) -> NSMenuItem {
        // 通用 → 菜单栏 can rename any row (设置 / 退出 included). The four
        // capture rows are ordinary rows now, so their titles are configurable
        // too — there is no submenu to keep canonical.
        let title = settings.menuBarTitle(for: entry)
        switch entry {
        case .openClipboard:
            return add(to: menu, title, #selector(AppDelegate.openPanelFromMenu), "", target: target)

        case .captureRegion:
            // Region selection: the drag-a-box overlay.
            return add(
                to: menu,
                title,
                #selector(AppDelegate.captureRegionFromMenu),
                "",
                target: target
            )

        case .captureWindow:
            // `CaptureMode.window`: the hover-and-click confirmation overlay.
            return add(
                to: menu,
                title,
                #selector(AppDelegate.captureWindowFromMenu),
                "",
                target: target
            )

        case .capturePreset:
            // 固定大小截图 reuses the 预设区域尺寸截图 action (⌃⌥⌘E).
            return add(
                to: menu,
                title,
                #selector(AppDelegate.capturePresetFromMenu),
                "",
                target: target
            )

        case .captureFullScreen:
            // 全屏截图 is the zero-UI instant path.
            return add(
                to: menu,
                title,
                #selector(AppDelegate.instantFullScreenFromMenu),
                "",
                target: target
            )

        case .ocr:
            return add(to: menu, title, #selector(AppDelegate.captureOCRFromMenu), "", target: target)

        case .scroll:
            return add(to: menu, title, #selector(AppDelegate.captureScrollFromMenu), "", target: target)

        case .recording:
            return add(
                to: menu,
                title,
                #selector(AppDelegate.toggleRecordingFromMenu),
                "",
                target: target
            )

        case .colorPicker:
            return add(
                to: menu,
                title,
                #selector(AppDelegate.colorPickerFromMenu),
                "",
                target: target
            )

        case .keyDisplay:
            let item = add(
                to: menu,
                title,
                #selector(AppDelegate.toggleKeyDisplayFromMenu),
                "",
                target: target
            )
            item.state = settings.keyDisplayEnabled ? .on : .off
            return item

        case .camera:
            let item = add(
                to: menu,
                title,
                #selector(AppDelegate.toggleCameraFromMenu),
                "",
                target: target
            )
            item.state = settings.cameraOverlayEnabled ? .on : .off
            return item

        case .about:
            return add(to: menu, title, #selector(AppDelegate.showAbout), "", target: target)

        case .settings:
            return add(
                to: menu,
                title,
                #selector(AppDelegate.openSettingsFromMenu),
                "",
                target: target
            )

        case .quit:
            let quit = menu.addItem(
                withTitle: title,
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: ""
            )
            quit.target = NSApp
            return quit
        }
    }

    @discardableResult
    private static func add(
        to menu: NSMenu,
        _ title: String,
        _ selector: Selector,
        _ key: String,
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: key)
        item.target = target
        return item
    }

    // MARK: - App

    private static func appMenu(appName: String, delegate: AppDelegate) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: appName)

        add(to: menu, "关于 \(appName)", #selector(AppDelegate.showAbout), "", target: delegate)
        menu.addItem(.separator())
        add(to: menu, "设置", #selector(AppDelegate.openSettingsFromMenu), ",", target: delegate)
        menu.addItem(.separator())
        add(to: menu, "隐藏 \(appName)", #selector(NSApplication.hide(_:)), "h")
        let hideOthers = menu.addItem(
            withTitle: "隐藏其他",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        add(to: menu, "显示全部", #selector(NSApplication.unhideAllApplications(_:)), "")
        menu.addItem(.separator())
        add(to: menu, "退出 \(appName)", #selector(NSApplication.terminate(_:)), "q")

        item.submenu = menu
        return item
    }

    // MARK: - Edit

    private static func editMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "编辑")

        add(to: menu, "撤销", Selector(("undo:")), "z")
        add(to: menu, "重做", Selector(("redo:")), "Z")
        menu.addItem(.separator())
        add(to: menu, "剪切", #selector(NSText.cut(_:)), "x")
        add(to: menu, "拷贝", #selector(NSText.copy(_:)), "c")
        add(to: menu, "粘贴", #selector(NSText.paste(_:)), "v")
        add(to: menu, "全选", #selector(NSText.selectAll(_:)), "a")

        item.submenu = menu
        return item
    }

    // MARK: - View

    private static func viewMenu(delegate: AppDelegate) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "显示")

        add(to: menu, "历史记录", #selector(AppDelegate.showHistoryPage), "1", target: delegate)
        add(to: menu, "钉图", #selector(AppDelegate.showPinboardPage), "2", target: delegate)
        add(to: menu, "截图", #selector(AppDelegate.showCapturePage), "3", target: delegate)
        add(to: menu, "设置", #selector(AppDelegate.showSettingsPage), "4", target: delegate)
        menu.addItem(.separator())
        // The standard full-screen command; AppKit does not add it to a custom
        // View menu, and the main window needs it so 全屏 can be entered (the
        // window drops its corner rounding while in full screen).
        add(to: menu, "进入全屏幕", #selector(NSWindow.toggleFullScreen(_:)), "f")
        menu.items.last?.keyEquivalentModifierMask = [.control, .command]
        menu.addItem(.separator())
        add(to: menu, "打开历史面板", #selector(AppDelegate.openPanelFromMenu), "p", target: delegate)

        item.submenu = menu
        return item
    }

    // MARK: - Capture

    private static func captureMenu(delegate: AppDelegate) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "截图")

        // Region and OCR are owned by the Carbon global hotkeys; the other
        // entries only have app-local equivalents so the two paths cannot
        // double-fire. The instant entries below are global too, so their menu
        // items deliberately carry no local key equivalent.
        add(to: menu, "截图", #selector(AppDelegate.captureRegionFromMenu), "", target: delegate)
        // `CaptureMode.window`: same instant shot as ⌃⌥⌘W, listed so the three
        // modes are discoverable. No local key equivalent — the Carbon global
        // hotkey already owns the shortcut, and a second one would double-fire.
        add(
            to: menu,
            "截图光标下的窗口",
            #selector(AppDelegate.captureWindowFromMenu),
            "",
            target: delegate
        )
        add(
            to: menu,
            "即时全屏",
            #selector(AppDelegate.instantFullScreenFromMenu),
            "",
            target: delegate
        )
        add(
            to: menu,
            "即时窗口",
            #selector(AppDelegate.instantWindowFromMenu),
            "",
            target: delegate
        )
        menu.addItem(.separator())
        // OCR and scrolling capture are owned by their Carbon global hotkeys
        // (⌃⌥⌘O / ⌃⌥⌘S); their menu items have no local key equivalent so the
        // two paths cannot double-fire.
        add(to: menu, "识别文字（OCR）", #selector(AppDelegate.captureOCRFromMenu), "", target: delegate)
        add(to: menu, "长截图", #selector(AppDelegate.captureScrollFromMenu), "", target: delegate)
        menu.addItem(.separator())
        add(to: menu, "延时截图", #selector(AppDelegate.captureDelayFromMenu), "d", target: delegate)
        add(to: menu, "多窗口截图", #selector(AppDelegate.captureMultiWindowFromMenu), "m", target: delegate)
        add(to: menu, "预设区域尺寸截图", #selector(AppDelegate.capturePresetFromMenu), "e", target: delegate)
        menu.addItem(.separator())
        // Recording and the colour picker are owned by their Carbon global
        // hotkeys (⌃⌥⌘R / ⌃⌥⌘C); no local key equivalents so the two paths
        // cannot double-fire.
        // One entry: the key opens the region overlay; selecting the whole
        // screen there is the full-screen recording.
        add(to: menu, "开始 / 停止录屏", #selector(AppDelegate.toggleRecordingFromMenu), "", target: delegate)
        add(to: menu, "取色", #selector(AppDelegate.colorPickerFromMenu), "", target: delegate)
        menu.addItem(.separator())
        // 套壳 uses its Carbon hotkey (⌃⌥⌘B); the camera has no global key.
        add(to: menu, "带壳截图", #selector(AppDelegate.beautifyFromMenu), "", target: delegate)
        add(to: menu, "摄像头画中画", #selector(AppDelegate.toggleCameraFromMenu), "", target: delegate)

        for menuItem in menu.items where !menuItem.keyEquivalent.isEmpty {
            menuItem.keyEquivalentModifierMask = [.control, .option, .command]
        }

        item.submenu = menu
        return item
    }

    // MARK: - Window

    private static func windowMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "窗口")

        add(to: menu, "最小化", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(to: menu, "缩放", #selector(NSWindow.performZoom(_:)), "")
        menu.addItem(.separator())
        add(to: menu, "关闭窗口", #selector(NSWindow.performClose(_:)), "w")
        add(to: menu, "前置全部窗口", #selector(NSApplication.arrangeInFront(_:)), "")

        item.submenu = menu
        NSApp.windowsMenu = menu
        return item
    }

    // MARK: - Help

    private static func helpMenu(appName: String, delegate: AppDelegate) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "帮助")
        add(to: menu, "\(appName) 帮助", #selector(AppDelegate.showHelp), "?", target: delegate)
        item.submenu = menu
        NSApp.helpMenu = menu
        return item
    }
}

import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var panelController: PanelController!
    private var quickLook: QuickLookController!
    private var navigation: NavigationState!
    private var mainWindow: MainWindowController!
    private var statusItem: NSStatusItem!
    private var capture: CaptureCoordinator!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Offscreen overlay verification. Gated by an environment variable;
        // it renders PNGs and drives synthetic events, then exits without
        // touching the database or the window server.
        if OverlaySelfTest.isRequested {
            NSApp.setActivationPolicy(.accessory)
            NSApp.appearance = NSAppearance(named: .darkAqua)
            DispatchQueue.main.async {
                // The harness is async now: the recording group records real
                // SCStream sessions and reads the files back with AVURLAsset.
                Task { @MainActor in
                    let code = await OverlaySelfTest.run()
                    exit(code)
                }
            }
            return
        }

        // Support hook: report what this exact bundle is allowed to do, then
        // exit. Used to tell whether TCC grants survived an install/move.
        if ProcessInfo.processInfo.environment["UNSEEN_PERMCHECK"] != nil {
            print("bundle          : \(Bundle.main.bundlePath)")
            print("identifier      : \(Bundle.main.bundleIdentifier ?? "?")")
            print("accessibility   : \(PasteboardWriter.isAccessibilityTrusted)")
            let probe = AppSettings()
            print("showInDock      : \(probe.showInDock)")
            print("menuBarIcon     : \(probe.menuBarIconVisible)")
            print("appearanceStyle : \(probe.appearanceStyle)")
            print("appearanceTheme : \(probe.appearanceTheme)")
            let raw = UserDefaults.standard.bool(forKey: "showInDock")
            print("rawShowInDock   : \(raw)")
            exit(0)
        }

        // Support hook: run one real scrolling capture over a fixed rectangle
        // instead of the interactive selection, and dump every sampled frame.
        if ScrollCaptureProbe.isRequested {
            ScrollCaptureProbe.run()
        }

        // Support hook: answer "which window would 窗口截图 pick here, and why
        // not the others?" without running an interactive capture.
        // `UNSEEN_PICK_PROBE` is either `pointer` (default) or an
        // AppKit global `x,y`.
        if let raw = ProcessInfo.processInfo.environment["UNSEEN_PICK_PROBE"] {
            let point: CGPoint
            if raw.isEmpty || raw == "pointer" {
                point = NSEvent.mouseLocation
            } else {
                let parts = raw.split(separator: ",").compactMap { Double($0) }
                guard parts.count == 2 else {
                    print("pick-probe : unreadable point \(raw); expected 'pointer' or 'x,y'")
                    exit(2)
                }
                point = CGPoint(x: parts[0], y: parts[1])
            }
            MainActor.assumeIsolated {
                _ = printWindowPickLedger(at: point, label: "pick-probe")
            }
            exit(0)
        }

        // Support hook: run the real zero-UI window capture at a point (or at
        // the pointer) and report the pixels that landed on the pasteboard.
        // `UNSEEN_INSTANT_PROBE` is `pointer` or an AppKit `x,y`.
        if let raw = ProcessInfo.processInfo.environment["UNSEEN_INSTANT_PROBE"] {
            let point: CGPoint
            if raw.isEmpty || raw == "pointer" {
                point = NSEvent.mouseLocation
            } else {
                let parts = raw.split(separator: ",").compactMap { Double($0) }
                guard parts.count == 2 else {
                    print("instant-probe: unreadable point \(raw); expected 'pointer' or 'x,y'")
                    exit(2)
                }
                point = CGPoint(x: parts[0], y: parts[1])
            }
            NSApp.setActivationPolicy(.accessory)
            DispatchQueue.main.async {
                Task { @MainActor in
                    let coordinator = CaptureCoordinator(settings: AppSettings())
                    guard let task = coordinator.startInstant(.window, pointer: point) else {
                        print("instant-probe: coordinator refused (busy)")
                        exit(1)
                    }
                    let result = await task.value
                    print("instant-probe: succeeded=\(result.succeeded) "
                        + "window=\(result.windowNumber.map(String.init) ?? "-") "
                        + "pixels=\(Int(result.pixelSize.width))×\(Int(result.pixelSize.height)) "
                        + "error=\(result.error?.localizedDescription ?? "-")")
                    let pasted = NSPasteboard.general
                        .readObjects(forClasses: [NSImage.self], options: nil)?
                        .first as? NSImage
                    let reps = pasted?.representations.compactMap { $0 as? NSBitmapImageRep } ?? []
                    print("instant-probe: pasteboard="
                        + "\(reps.map(\.pixelsWide).max() ?? 0)×\(reps.map(\.pixelsHigh).max() ?? 0)")
                    exit(result.succeeded ? 0 : 1)
                }
            }
            return
        }

        let model = AppModel()
        self.model = model

        navigation = NavigationState()
        // 设置 → 截图 → 默认模式 seeds the capture tool's selected mode; the
        // state already starts from `NavigationDefaults.captureTool`.
        quickLook = QuickLookController(model: model)
        panelController = PanelController(model: model, quickLook: quickLook)
        mainWindow = MainWindowController(model: model, navigation: navigation)
        capture = CaptureCoordinator(model: model)

        model.onRequestCapture = { [weak self] mode in self?.startCapture(mode) }
        model.onRequestPresetCapture = { [weak self] in self?.startPreset() }
        model.onRequestClose = { [weak self] in self?.panelController.hide(restoreFocus: true) }
        model.onRequestMainWindow = { [weak self] in self?.mainWindow.show(section: .history) }
        model.onRequestQuit = { NSApp.terminate(nil) }
        model.onHotKeyChanged = { [weak self] in self?.applyHotKeys() }
        model.onCameraSettingsChanged = { [weak self] in self?.capture.applyCameraSettings() }
        model.onRequestApplyActivationPolicy = { [weak self] in self?.applyActivationPolicy() }
        // The status item is the "status bar red dot + timer" surface.
        capture.onRecordingChanged = { [weak self] state, elapsedText in
            self?.updateRecordingStatus(state: state, elapsedText: elapsedText)
        }

        setUpStatusItem()
        applyHotKeys()
        AppMenuBuilder.install(appName: "Unseen", delegate: self)
        applyActivationPolicy()
        model.refreshAccessibilityStatus()
        DebugLog.log("accessibility trusted at launch: \(model.accessibilityTrusted)")

        // The user leaves for System Settings to grant Accessibility access and
        // comes back through this notification; nothing else would refresh it.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationBecameActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

        // Support hook: prove, inside the real app, that the window picker
        // treats the app's own main window as capturable while every capture
        // surface stays excluded. Runs instead of the interactive session and
        // exits when done. Test-only; see `scheduleOwnWindowProbe`.
        if ProcessInfo.processInfo.environment["UNSEEN_OWN_PROBE"] != nil {
            scheduleOwnWindowProbe()
            return
        }

        // Support hook: open straight to a page, e.g. UNSEEN_OPEN=pins,
        // or to a settings page by name, e.g. UNSEEN_OPEN=ocr.
        //
        // The four capture modes are no longer left-column pages: they are rows
        // of 截图 → 截图. Every old name therefore opens that one page with
        // the matching row selected — including the pre-2026-10 "screenshot".
        scheduleStatusMenuProbeIfRequested()
        let legacyCaptureTools = CaptureToolMode.legacyOpenNames
        var openedPage = false
        if let raw = ProcessInfo.processInfo.environment["UNSEEN_OPEN"] {
            if let tool = legacyCaptureTools[raw] {
                navigation.captureTool = tool
                mainWindow.show(section: .capture)
                openedPage = true
            } else if let section = NavigationSection(rawValue: raw) {
                mainWindow.show(section: section)
                openedPage = true
            } else if let page = SettingsSection(rawValue: raw),
                      let item = NavItem(rawValue: page.rawValue) {
                // Settings pages are navigation *items*, not sections, so set
                // the item directly — `show(.settings)` alone lands on 通用.
                navigation.item = item
                mainWindow.show(section: .settings)
                openedPage = true
            }
        }
        if openedPage {
            // Optional companion to UNSEEN_OPEN: jumps straight to one
            // settings group. Used by the UI checks in Scripts.
            if let group = ProcessInfo.processInfo.environment["UNSEEN_GROUP"], !group.isEmpty {
                navigation.groupID = group
            }
            scheduleCaptureProbeIfRequested()
            return
        }

        scheduleCaptureProbeIfRequested()

        // Every launch opens on 设置, the way an ordinary app comes up on a
        // window instead of nowhere. This is one plain "order it in" call and
        // nothing else: no persisted "已弹过" flag exists, because a process
        // launch happens exactly once. Closing the window (or ⌘W) therefore
        // keeps it closed for the rest of this run, and the next launch — a
        // new process — shows it again. 设置 in the status menu and the app
        // menu (⌘,) still re-fronts the same window: it is not released on
        // close, so `show(section:)` just orders it back in.
        mainWindow.show(section: .settings)
        // With 通用 → 在 Dock 中显示 switched off the process starts as an
        // accessory app, and AppKit does not give a freshly launched accessory
        // app the foreground: the window would be built but stay behind
        // whatever was frontmost. `show` already calls `NSApp.activate()`,
        // which is not enough here, so ask for the activation explicitly —
        // 「启动即见设置页」 must hold for both activation policies.
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])

        // The interactive probe posts synthetic keystrokes and opens windows;
        // trace-only runs (UNSEEN_TRACE) must not arm it.
        if ProcessInfo.processInfo.environment["UNSEEN_DEBUG"] != nil {
            scheduleDebugProbe()
        }
    }

    @objc private func applicationBecameActive() {
        model.refreshAccessibilityStatus()
    }

    /// Support hook: pop the status-bar menu open after launch so a screenshot
    /// shows the real menu (used by the 菜单栏 verification captures). Test-only.
    private func scheduleStatusMenuProbeIfRequested() {
        guard ProcessInfo.processInfo.environment["UNSEEN_STATUS_MENU"] == "1" else { return }
        step(after: 1.0) { [weak self] in
            guard let self, let button = self.statusItem.button,
                  let menu = self.statusItem.menu else { return }
            DebugLog.log("status menu probe: popping up the status menu")
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: button.bounds.height + 6),
                in: button
            )
        }
    }

    /// Support hook: start one capture mode shortly after launch so the live
    /// overlay can be inspected. `UNSEEN_CAPTURE_PROBE=region` or
    /// `fullScreen`. Test-only.
    private func scheduleCaptureProbeIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["UNSEEN_CAPTURE_PROBE"],
              let mode = CaptureMode(rawValue: raw) else { return }
        step(after: 1.4) { [weak self] in
            DebugLog.log("capture probe: starting \(raw)")
            self?.startCapture(mode)
        }
    }

    // MARK: - Own-window probe

    /// Support hook: prove this app's own-window rule on the real app.
    ///
    /// The window picker must keep the capture surfaces (overlay, clipboard
    /// panel, pins, HUDs) out of the candidate set, while the app's own main
    /// window — ordinary content the user may want to screenshot — stays
    /// selectable. `UNSEEN_OWN_PROBE=main` prints the picker ledger for
    /// the main window's centre and captures it; `=all` also opens the panel, a
    /// pin and the region overlay and prints their ledgers. Test-only: it exits
    /// when done, so nothing else in the app runs.
    private func scheduleOwnWindowProbe() {
        let all = ProcessInfo.processInfo.environment["UNSEEN_OWN_PROBE"] == "all"
        Task { @MainActor in
            // The window must be on screen before the window server lists it.
            // A probe launched from a script can land in the background, and a
            // window behind another app's window is a different (correct) pick
            // — so ask for the same activation a user click would give us.
            mainWindow.show(section: .history)
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(nanoseconds: 900_000_000)
            // Activation may land a beat later; make sure the main window is
            // the front window of the front app before measuring.
            if let main = NSApp.windows.first(where: { $0 is MainWindow }) {
                main.orderFrontRegardless()
            }
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let window = NSApp.windows.first(where: { $0 is MainWindow }),
                  window.isVisible,
                  window.windowNumber > 0
            else {
                print("own-probe  : no visible MainWindow — refusing")
                exit(1)
            }
            let point = CGPoint(x: window.frame.midX, y: window.frame.midY)
            print("own-probe  : main window #\(window.windowNumber) "
                + "frame=\(NSStringFromRect(window.frame)) "
                + "capturable=\(OwnWindowCapture.capturableWindowNumbers.sorted())")
            let outcome = printWindowPickLedger(at: point, label: "own-probe")
            guard let pick = outcome.pick else {
                print("own-probe  : NO PICK on the app's own main window")
                exit(1)
            }
            print("own-probe  : PICK owner=\(pick.candidate.ownerName) "
                + "title=\"\(pick.candidate.windowName)\" "
                + "rect=\(NSStringFromRect(pick.rect)) trimmed=\(pick.trimmed)")
            do {
                let shot = try await ScreenCapture.captureWindow(
                    CGWindowID(pick.candidate.windowNumber)
                )
                let expectedWidth = Int((pick.rect.width * shot.scale).rounded())
                let expectedHeight = Int((pick.rect.height * shot.scale).rounded())
                let matches = shot.image.width == expectedWidth
                    && shot.image.height == expectedHeight
                print("own-probe  : captured=\(shot.image.width)×\(shot.image.height) "
                    + "expected=\(expectedWidth)×\(expectedHeight) "
                    + "scale=\(shot.scale) → \(matches ? "MATCH" : "MISMATCH")")
            } catch {
                print("own-probe  : capture failed: \(error.localizedDescription)")
                exit(1)
            }

            guard all else { exit(0) }

            // 1. The history panel (⌥⌘V): a floating own window in front of the
            //    main one. It must be rejected, never selected.
            panelController.show()
            try? await Task.sleep(nanoseconds: 700_000_000)
            if let panel = NSApp.windows.first(where: { $0 is ClipboardPanel }),
               panel.isVisible {
                print("own-probe  : clipboard panel #\(panel.windowNumber) "
                    + "frame=\(NSStringFromRect(panel.frame))")
                _ = printWindowPickLedger(
                    at: CGPoint(x: panel.frame.midX, y: panel.frame.midY),
                    label: "own-probe/panel"
                )
            } else {
                print("own-probe  : clipboard panel did not appear")
            }
            panelController.hide(restoreFocus: false)
            try? await Task.sleep(nanoseconds: 300_000_000)

            // 2. A pin (钉图): same rule.
            let pinImage = NSImage(size: NSSize(width: 160, height: 100))
            pinImage.lockFocus()
            NSColor.systemTeal.setFill()
            NSRect(x: 0, y: 0, width: 160, height: 100).fill()
            pinImage.unlockFocus()
            if model.pinboard.pinImage(pinImage),
               let record = model.pinboard.pins.last,
               let panel = model.pinboard.panelForTesting(record.id) {
                try? await Task.sleep(nanoseconds: 500_000_000)
                print("own-probe  : pin #\(panel.windowNumber) "
                    + "frame=\(NSStringFromRect(panel.frame))")
                _ = printWindowPickLedger(
                    at: CGPoint(x: panel.frame.midX, y: panel.frame.midY),
                    label: "own-probe/pin"
                )
                model.pinboard.unpin(record.id)
            } else {
                print("own-probe  : pin did not appear")
            }

            // 3. The region overlay (⌃⌥⌘A): full-screen own panels above
            //    everything. The pick must walk past them to the main window.
            startCapture(.region)
            try? await Task.sleep(nanoseconds: 900_000_000)
            let overlayNumbers = NSApp.windows
                .compactMap { $0 as? CaptureOverlayPanel }
                .filter(\.isVisible)
                .map { "#\($0.windowNumber)" }
            print("own-probe  : overlay panels="
                + (overlayNumbers.isEmpty ? "none" : overlayNumbers.joined(separator: ",")))
            _ = printWindowPickLedger(at: point, label: "own-probe/overlay")
            capture.cancel()
            try? await Task.sleep(nanoseconds: 300_000_000)
            print("own-probe  : done")
            exit(0)
        }
    }

    /// The window picker's per-candidate ledger for one point, printed for the
    /// support probes. Returns the outcome so a caller can act on the pick.
    @discardableResult
    private func printWindowPickLedger(at point: CGPoint, label: String) -> WindowPickOutcome {
        let stack = ScreenCapture.instantWindowStack()
        print("\(label): point=\(NSStringFromPoint(point)) "
            + "screenHeight=\(Int(stack.screenHeight)) "
            + "menubarHeights=\(stack.menubarHeights.sorted()) "
            + "candidates=\(stack.candidates.count) "
            + "ownCapturable=\(OwnWindowCapture.capturableWindowNumbers.sorted())")
        let outcome = WindowPicker.pick(
            at: point,
            candidates: stack.candidates,
            ownPID: ProcessInfo.processInfo.processIdentifier,
            ownCapturableWindowNumbers: OwnWindowCapture.capturableWindowNumbers,
            screenHeight: stack.screenHeight,
            menubarHeights: stack.menubarHeights,
            probe: { ScreenCapture.windowContentProbe(for: $0) }
        )
        for row in outcome.rows {
            print("\(label):   #\(row.windowNumber) "
                + "\(row.ownerName.isEmpty ? "?" : row.ownerName) "
                + "\(row.windowName.isEmpty ? "" : "\"\(row.windowName)\" ")"
                + "layer=\(row.layer) bounds=\(NSStringFromRect(row.bounds)) "
                + "→ \(row.reject?.rawValue ?? "SELECTED")")
        }
        if let pick = outcome.pick {
            print("\(label): PICK #\(pick.candidate.windowNumber) "
                + "owner=\(pick.candidate.ownerName) "
                + "layer=\(pick.candidate.layer) "
                + "rect=\(NSStringFromRect(pick.rect)) trimmed=\(pick.trimmed)")
        } else {
            print("\(label): NO PICK (the instant path reports 窗口已经关闭或不再可截取 "
                + "instead of capturing the screen)")
        }
        return outcome
    }

    // MARK: - Dock / activation policy

    /// A clipboard manager lives in the menu bar, but the user asked for a real
    /// app window too — so the Dock icon is on by default and can be turned off.
    private func applyActivationPolicy() {
        NSApp.setActivationPolicy(model.settings.showInDock ? .regular : .accessory)
        statusItem?.isVisible = model.settings.menuBarIconVisible
        model.settings.applyAppearance()
    }

    /// Clicking the Dock icon (or re-launching) brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        mainWindow.showFrontmost()
        return true
    }

    /// Quitting from the Dock happens with windows open; do not treat the last
    /// window closing as a reason to quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Application menu actions

    /// The standard panel renders `版本 1.1.7 (5)` when AppKit can read both
    /// version keys: the parenthesised part is `CFBundleVersion`, the build
    /// counter the release script bumps. That number only matters to the build
    /// and the signature, so it is suppressed here; `Info.plist` still carries
    /// it. The intro is one line on purpose — the panel is a name card, not a
    /// feature list.
    @objc func showAbout() {
        let shortVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? ""
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Unseen",
            .applicationVersion: shortVersion,
            .version: "",
            .credits: NSAttributedString(
                string: "截图工具+剪贴板",
                attributes: [.font: NSFont.systemFont(ofSize: 11)]
            )
        ])
    }

    @objc func showHelp() {
        NSWorkspace.shared.open(
            URL(fileURLWithPath: Bundle.main.bundlePath)
                .deletingLastPathComponent()
                .appendingPathComponent("README.md")
        )
    }

    @objc func showHistoryPage() { mainWindow.show(section: .history) }
    @objc func showPinboardPage() { mainWindow.show(section: .pins) }
    @objc func showCapturePage() { mainWindow.show(section: .capture) }
    @objc func showSettingsPage() { mainWindow.show(section: .settings) }

    // MARK: - Capture menu actions

    @objc func captureRegionFromMenu() { startCapture(.region) }
    @objc func instantWindowFromMenu() { startInstant(.window) }
    @objc func captureWindowFromMenu() { startCapture(.window) }
    @objc func instantFullScreenFromMenu() { startInstant(.fullScreen) }
    @objc func captureOCRFromMenu() { startOCR() }
    @objc func captureScrollFromMenu() { startScroll() }
    @objc func captureDelayFromMenu() { startDelay() }
    @objc func captureMultiWindowFromMenu() { startMultiWindow() }
    @objc func capturePresetFromMenu() { startPreset() }
    @objc func toggleRecordingFromMenu() { startRecording() }
    @objc func colorPickerFromMenu() { startColorPicker() }
    @objc func beautifyFromMenu() { startBeautify() }
    @objc func toggleCameraFromMenu() { capture.toggleCameraOverlay() }

    /// 按键显示 is a preference, and the status item is the quickest way to
    /// flip it without opening 设置. The capture overlay starts its listener on
    /// the next capture, exactly like the settings switch.
    @objc func toggleKeyDisplayFromMenu() {
        model.settings.keyDisplayEnabled.toggle()
        refreshStatusMenu()
    }

    /// One funnel for every capture entry point. The floating history panel
    /// must be gone before the overlay appears, otherwise "area" captures the
    /// panel the user just clicked.
    private func startCapture(_ mode: CaptureMode) {
        hidePanelForCapture()
        capture.start(mode)
    }

    /// OCR entry: same overlay, but the confirmed region is recognised instead
    /// of copied/saved/pinned.
    private func startOCR() {
        hidePanelForCapture()
        capture.startOCR()
    }

    /// Scroll capture reuses the region overlay; a second invocation (menu or
    /// the same global hotkey) stops the running session and stitches it.
    private func startScroll() {
        hidePanelForCapture()
        capture.startScroll()
    }

    private func startDelay() {
        hidePanelForCapture()
        capture.startDelay()
    }

    private func startMultiWindow() {
        hidePanelForCapture()
        capture.startMultiWindow()
    }

    private func startPreset() {
        hidePanelForCapture()
        capture.startPreset()
    }

    private func startBeautify() {
        hidePanelForCapture()
        capture.startBeautify()
    }

    /// The zero-UI path: hide the history panel so it cannot end up in the
    /// pixels, then let the coordinator capture, copy and confirm. No window is
    /// ever ordered in by this path (the optional cue is a non-activating,
    /// click-through overlay drawn *after* the pixels exist).
    private func startInstant(_ kind: InstantCaptureKind) {
        hidePanelForCapture()
        _ = capture.startInstant(kind)
    }

    /// One key / menu item does both jobs: start when idle, stop when live.
    private func startRecording() {
        hidePanelForCapture()
        capture.toggleRecording()
    }

    private func startColorPicker() {
        hidePanelForCapture()
        capture.startColorPicker()
    }

    private func hidePanelForCapture() {
        if panelController.isVisible {
            panelController.hide(restoreFocus: false)
        }
    }
    @objc func openSettingsFromMenu() { mainWindow.show(section: .settings) }
    @objc func openPanelFromMenu() { panelController.show() }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        DebugLog.log("terminating with \(model.pinboard.count) pin(s)")
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        // AppKit owns the left click once `menu` is set. Deliberately no
        // target/action here: the old action toggled the clipboard panel, and
        // setting both would show the menu *and* pop the panel.
        button.imagePosition = .imageOnly
        refreshStatusMenu()
        refreshStatusItem()
        updateToolTip()

        // 通用 → 菜单栏 edits which rows appear and in what order; rebuild the
        // menu as soon as a switch or a drag changes the configuration.
        NotificationCenter.default.addObserver(
            forName: .menuBarSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatusMenu() }
        }
    }

    /// Rebuilds the status item's menu from the current 菜单栏 preferences.
    private func refreshStatusMenu() {
        guard let statusItem, model != nil else { return }
        statusItem.menu = AppMenuBuilder.statusMenu(settings: model.settings, target: self)
    }

    // MARK: - Global hotkeys

    private func applyHotKeys() {
        let settings = model.settings

        // An unbound slot (the grey 「快捷键」 placeholder) must not reach
        // RegisterEventHotKey: key code 0 with a zero mask is the plain A key.
        func registration(
            _ enabled: Bool,
            _ configuration: HotKeyConfiguration
        ) -> HotKeyConfiguration? {
            AppSettings.registeredConfiguration(enabled: enabled, configuration)
        }

        func register(
            _ action: HotKeyAction,
            _ enabled: Bool,
            _ configuration: HotKeyConfiguration,
            _ handler: @escaping () -> Void
        ) {
            GlobalHotKeyCenter.shared.set(
                action,
                configuration: registration(enabled, configuration),
                handler: handler
            )
        }

        register(.openPanel, settings.hotKeyEnabled, settings.hotKeyConfiguration) { [weak self] in
            self?.panelController.toggle()
        }

        register(.pinLastImage, settings.pinHotKeyEnabled, settings.pinHotKeyConfiguration) { [weak self] in
            guard let self else { return }
            // ⌘⇧P is also the panel's local "pin the row under the pointer"
            // shortcut. Carbon sees the key before the panel's local monitor,
            // so while the panel owns the keyboard the press belongs to the
            // panel — not to the no-panel "pin the newest image" action.
            if self.panelController.isKeyWindow {
                self.panelController.pinHoveredOrSelected()
            } else {
                self.pinLastImage()
            }
        }

        register(.screenshot, settings.screenshotHotKeyEnabled, settings.screenshotHotKeyConfiguration) { [weak self] in
            self?.startCapture(.region)
        }

        register(.ocr, settings.ocrHotKeyEnabled, settings.ocrHotKeyConfiguration) { [weak self] in
            self?.startOCR()
        }

        register(.scroll, settings.scrollHotKeyEnabled, settings.scrollHotKeyConfiguration) { [weak self] in
            self?.startScroll()
        }

        register(.record, settings.recordHotKeyEnabled, settings.recordHotKeyConfiguration) { [weak self] in
            self?.startRecording()
        }

        register(.colorPicker, settings.colorPickerHotKeyEnabled, settings.colorPickerHotKeyConfiguration) { [weak self] in
            self?.startColorPicker()
        }

        register(.beautify, settings.beautifyHotKeyEnabled, settings.beautifyHotKeyConfiguration) { [weak self] in
            self?.startBeautify()
        }

        register(.instantWindow, settings.instantWindowHotKeyEnabled, settings.instantWindowHotKeyConfiguration) { [weak self] in
            self?.startInstant(.window)
        }

        register(.instantFullScreen, settings.instantFullScreenHotKeyEnabled, settings.instantFullScreenHotKeyConfiguration) { [weak self] in
            self?.startInstant(.fullScreen)
        }

        // The two new capture-mode slots and 按键显示 start unbound, so these
        // registrations are no-ops until the user records a combination.
        register(.windowCapture, settings.windowHotKeyEnabled, settings.windowHotKeyConfiguration) { [weak self] in
            self?.startCapture(.window)
        }

        register(.fullScreenCapture, settings.fullScreenHotKeyEnabled, settings.fullScreenHotKeyConfiguration) { [weak self] in
            self?.startCapture(.fullScreen)
        }

        register(.keyDisplay, settings.keyDisplayHotKeyEnabled, settings.keyDisplayHotKeyConfiguration) { [weak self] in
            self?.toggleKeyDisplayFromMenu()
        }

        // The four menu-only actions now have bindable slots too. They ship
        // with the app-menu combinations for the three capture modes and
        // unbound for 摄像头 / 打开设置.
        register(.capturePreset, true, settings.capturePresetHotKeyConfiguration) { [weak self] in
            self?.startPreset()
        }

        register(.delayCapture, true, settings.delayCaptureHotKeyConfiguration) { [weak self] in
            self?.startDelay()
        }

        register(.multiWindowCapture, true, settings.multiWindowHotKeyConfiguration) { [weak self] in
            self?.startMultiWindow()
        }

        register(.cameraOverlay, true, settings.cameraHotKeyConfiguration) { [weak self] in
            self?.capture.toggleCameraOverlay()
        }

        register(.openSettings, true, settings.openSettingsHotKeyConfiguration) { [weak self] in
            self?.showSettingsPage()
        }

        // First registration failure wins; the array keeps the long `??` chain
        // from defeating the type checker as the action list grows.
        let registeredActions: [HotKeyAction] = [
            .openPanel, .pinLastImage, .screenshot, .ocr, .scroll, .record,
            .colorPicker, .beautify, .instantWindow, .instantFullScreen,
            .windowCapture, .fullScreenCapture, .keyDisplay,
            .capturePreset, .delayCapture, .multiWindowCapture,
            .cameraOverlay, .openSettings
        ]
        model.hotKeyError = registeredActions.lazy
            .compactMap { GlobalHotKeyCenter.shared.lastErrors[$0] }
            .first

        // The status menu prints each row's shortcut, so a re-bind or a
        // switched-off feature has to rebuild it — the menu is a snapshot.
        refreshStatusMenu()
        updateToolTip()
    }

    /// Global shortcut: pin the newest image without opening the panel first.
    /// Reuses the exact ⌘P path — `PanelController.pinSelected` also ends in
    /// `AppModel.pinToScreen` — so both entry points share one implementation.
    private func pinLastImage() {
        let newest = model.items
            .filter { $0.hasImage }
            .max { $0.updatedAt < $1.updatedAt }

        guard let newest else {
            DebugLog.log("pinLastImage: no image in history")
            if panelController.isVisible {
                // There is a surface for the alert, so say why nothing happened.
                model.presentError("历史里还没有图片，先复制一张图片再试。")
            } else {
                // No panel to host an alert; a beep confirms the key did fire
                // instead of stashing an error that pops up much later.
                NSSound.beep()
            }
            return
        }

        DebugLog.log("pinLastImage: pinning item \(newest.id)")
        let pinned = model.pinToScreen(newest)
        DebugLog.log("pinLastImage: result=\(pinned) pins=\(model.pinboard.count)")
    }

    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        let image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Unseen")
        image?.isTemplate = true
        button.imagePosition = .imageOnly
        button.image = image
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
    }

    /// While a recording runs the status item becomes "● MM:SS" (red) or
    /// "⏸ MM:SS" (orange, paused) and widens to fit; on stop it returns to the
    /// normal clipboard glyph.
    private func updateRecordingStatus(state: RecordingState, elapsedText: String) {
        guard let statusItem, let button = statusItem.button else { return }
        switch state {
        case .recording, .paused:
            statusItem.length = NSStatusItem.variableLength
            button.image = nil
            button.imagePosition = .noImage
            let badge = RecordingStatusBadge.text(state: state, elapsedText: elapsedText)
                ?? "\(elapsedText)"
            button.attributedTitle = NSAttributedString(
                string: badge,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: RecordingStatusBadge.isPaused(state)
                        ? NSColor.systemOrange
                        : NSColor.systemRed
                ]
            )
            DebugLog.log("status item: recording \(state.rawValue) \(elapsedText)")
        case .finished, .idle:
            statusItem.length = NSStatusItem.squareLength
            refreshStatusItem()
        }
    }

    private func updateToolTip() {
        let settings = model.settings

        // A cleared slot is unbound; printing "A" for the zero key code would
        // claim a shortcut that the app does not own.
        func label(_ enabled: Bool, _ configuration: HotKeyConfiguration) -> String {
            enabled && configuration.isBound ? configuration.displayString : "未绑定"
        }

        let parts = [
            "历史 \(label(settings.hotKeyEnabled, settings.hotKeyConfiguration))",
            "钉图 \(label(settings.pinHotKeyEnabled, settings.pinHotKeyConfiguration))",
            "截图 \(label(settings.screenshotHotKeyEnabled, settings.screenshotHotKeyConfiguration))",
            "窗口 \(label(settings.windowHotKeyEnabled, settings.windowHotKeyConfiguration))",
            "全屏 \(label(settings.fullScreenHotKeyEnabled, settings.fullScreenHotKeyConfiguration))",
            "OCR \(label(settings.ocrHotKeyEnabled, settings.ocrHotKeyConfiguration))",
            "滚动 \(label(settings.scrollHotKeyEnabled, settings.scrollHotKeyConfiguration))",
            "录屏 \(label(settings.recordHotKeyEnabled, settings.recordHotKeyConfiguration))",
            "取色 \(label(settings.colorPickerHotKeyEnabled, settings.colorPickerHotKeyConfiguration))"
        ]
        statusItem?.button?.toolTip = "Unseen（\(parts.joined(separator: " · "))）"
    }

    // MARK: - Debug probe

    /// `UNSEEN_DEBUG=1` fires a synthetic hotkey event shortly after
    /// launch, which exercises registration → Carbon handler → panel, then
    /// walks the keyboard path with synthetic key events.
    private func scheduleDebugProbe() {
        step(after: 4.0) { self.probeHotKey() }
        step(after: 5.0) { self.probeState("after hotkey") }

        // A space must remain typeable while a multi-word query is in progress.
        step(after: 5.5) { self.model.searchText = "seeded" }
        step(after: 6.0) { self.probeKey(49, "space while searching") }
        step(after: 6.5) { self.probePreview("space during search (want preview=false)") }

        step(after: 7.0) { self.model.searchText = "" }
        step(after: 7.5) { self.probeKey(49, "space with empty search") }
        step(after: 8.0) { self.probePreview("space with empty search (want preview=true)") }

        step(after: 8.5) { self.probeKey(53, "escape (close preview)") }
        step(after: 9.0) { self.probeKey(35, "cmd+P (pin)", modifiers: .command) }
        step(after: 9.5) { self.probePinState("after cmd+P") }

        step(after: 10.0) { self.mainWindow.show(section: .pins) }
        step(after: 10.5) { self.probeWindow("main window @ pins") }
        step(after: 11.0) { self.mainWindow.show(section: .settings) }
        step(after: 11.5) { self.probeWindow("main window @ settings") }
        step(after: 12.0) { self.mainWindow.show(section: .history) }
        step(after: 12.5) { self.probeWindow("main window @ history") }

        // Leave the panel + preview on screen so they can be inspected.
        step(after: 13.5) { self.probeHotKey() }
        step(after: 14.5) { self.probeKey(49, "space (leave preview open)") }
        step(after: 15.0) { self.probePreview("final: preview left open") }

        // Leave the settings page open for inspection.
        step(after: 17.0) { self.mainWindow.show(section: .settings) }

        // Periodic heartbeat so an external driver can interleave actions.
        for index in 1...10 {
            step(after: 22.0 + Double(index) * 2.0) { self.probeState("t+\(22 + index * 2)s") }
        }
    }

    private func probeWindow(_ label: String) {
        DebugLog.log("\(label): mainWindowOpen=\(mainWindow.isOpen) section=\(navigation.section.rawValue)")
    }

    private func step(after delay: TimeInterval, _ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated(body)
        }
    }

    private func probeHotKey() {
        DebugLog.log("hotkeyError: \(model.hotKeyError ?? "none")")
        DebugLog.log("sending synthetic hot key event…")
        GlobalHotKeyCenter.postSyntheticHotKeyForDebugging()
    }

    private func probeState(_ label: String) {
        panelController.debugHitTest()
        DebugLog.log("\(label): db=\(model.storageURL.path) panel=\(panelController.isVisible) items=\(model.items.count) rows=\(model.filteredItems.count) total=\(model.totalCount) selected=\(model.selectedIndex) q=\"\(model.searchText)\" error=\(model.lastError ?? "none") first=\(model.selectedItem?.preview.prefix(18) ?? "-")")
    }

    private func probePreview(_ label: String) {
        DebugLog.log("\(label): preview=\(quickLook.isVisible) selected=\(model.selectedItem?.kind.rawValue ?? "-")")
    }

    private func probePinState(_ label: String) {
        DebugLog.log("\(label): pins=\(model.pinboard.count) panel=\(panelController.isVisible)")
    }

    private func probeKey(_ keyCode: UInt16, _ label: String, modifiers: NSEvent.ModifierFlags = []) {
        DebugLog.log("posting synthetic key: \(label)")
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panelController.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        ) else { return }
        NSApp.postEvent(event, atStart: false)
    }
}

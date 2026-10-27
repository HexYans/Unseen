import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Modifier keys as a set, independent of AppKit, so formatting is testable.
struct KeyModifiers: OptionSet, Sendable, Equatable {
    let rawValue: Int

    static let command = KeyModifiers(rawValue: 1 << 0)
    static let control = KeyModifiers(rawValue: 1 << 1)
    static let option = KeyModifiers(rawValue: 1 << 2)
    static let shift = KeyModifiers(rawValue: 1 << 3)

    /// Display order. `⌘` first matches the requirement's `⌘ + ⇧ + 4` and how
    /// iShot prints shortcuts; the remaining three keep Apple's ⌃⌥⇧ order.
    static let displayOrder: [(flag: KeyModifiers, symbol: String)] = [
        (.command, "⌘"),
        (.control, "⌃"),
        (.option, "⌥"),
        (.shift, "⇧")
    ]

    init(rawValue: Int) { self.rawValue = rawValue }

    init(modifierFlags: NSEvent.ModifierFlags) {
        var value: KeyModifiers = []
        if modifierFlags.contains(.command) { value.insert(.command) }
        if modifierFlags.contains(.control) { value.insert(.control) }
        if modifierFlags.contains(.option) { value.insert(.option) }
        if modifierFlags.contains(.shift) { value.insert(.shift) }
        self = value
    }

    var symbols: [String] {
        Self.displayOrder.compactMap { contains($0.flag) ? $0.symbol : nil }
    }

    var displayString: String { symbols.joined() }
}

/// One keyboard event, reduced to what the overlay needs.
struct KeyEventDescriptor: Equatable, Sendable {
    let modifiers: KeyModifiers
    let keyCode: UInt16

    var displayText: String {
        KeyDisplayFormatter.text(modifiers: modifiers, keyCode: keyCode)
    }
}

/// Turns a key code + modifiers into `⌘ + ⇧ + 4`.
///
/// Key names reuse `KeyCodeFormatter.keySymbol`, which already knows the
/// special keys (arrows, F-keys, space) and asks the current keyboard layout
/// for letters and digits. Modifier-only events (flagsChanged) render as their
/// symbols, e.g. `⌘ + ⇧`.
enum KeyDisplayFormatter {
    static func text(modifiers: KeyModifiers, keyCode: UInt16) -> String {
        var parts = modifiers.symbols
        let key = keyName(keyCode)
        if !key.isEmpty { parts.append(key) }
        return parts.joined(separator: " + ")
    }

    static func text(modifierFlags: NSEvent.ModifierFlags, keyCode: UInt16) -> String {
        text(modifiers: KeyModifiers(modifierFlags: modifierFlags), keyCode: keyCode)
    }

    /// Empty for the modifier keys themselves, whose symbol already came from
    /// the modifier set.
    static func keyName(_ keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Command, kVK_RightCommand,
             kVK_Shift, kVK_RightShift,
             kVK_Option, kVK_RightOption,
             kVK_Control, kVK_RightControl,
             kVK_CapsLock, kVK_Function:
            return ""
        default:
            return KeyCodeFormatter.keySymbol(UInt32(keyCode))
        }
    }

    static func descriptor(modifierFlags: NSEvent.ModifierFlags, keyCode: UInt16) -> KeyEventDescriptor {
        KeyEventDescriptor(
            modifiers: KeyModifiers(modifierFlags: modifierFlags),
            keyCode: keyCode
        )
    }
}

/// Where the key pill appears.
enum KeyDisplayPosition: String, Sendable, Equatable, CaseIterable, Identifiable {
    case bottomCenter
    case bottomRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bottomCenter: "底部居中"
        case .bottomRight: "右下角"
        }
    }
}

/// Placement arithmetic, kept pure for the self test.
enum KeyDisplayPlacement {
    static let bottomInset: CGFloat = 96
    static let sideInset: CGFloat = 40
    static let height: CGFloat = 44

    static func panelSize(for text: String) -> CGSize {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold)
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        return CGSize(width: max(120, (textSize.width + 40).rounded()), height: height)
    }

    static func origin(
        panelSize: CGSize,
        screenFrame: CGRect,
        position: KeyDisplayPosition
    ) -> CGPoint {
        let y = screenFrame.minY + bottomInset
        switch position {
        case .bottomCenter:
            return CGPoint(x: (screenFrame.midX - panelSize.width / 2).rounded(), y: y)
        case .bottomRight:
            return CGPoint(
                x: (screenFrame.maxX - panelSize.width - sideInset).rounded(),
                y: y
            )
        }
    }
}

/// Accessibility status for the key listener.
///
/// The key display is the only feature that needs an event tap. Everything
/// else in the app works without Accessibility access, so this degrades to
/// "feature unavailable, no prompts" rather than failing the app.
enum KeyDisplayPermission: String, Sendable, Equatable {
    case granted
    case denied

    var isGranted: Bool { self == .granted }

    var title: String {
        switch self {
        case .granted: "已授权"
        case .denied: "需要辅助功能权限"
        }
    }

    static var current: KeyDisplayPermission {
        AXIsProcessTrusted() ? .granted : .denied
    }
}

/// Shared box handed to the C event-tap callback.
private final class KeyEventTapBox: @unchecked Sendable {
    var handler: ((KeyEventDescriptor) -> Void)?
    var tap: CFMachPort?
}

/// Session-level listen-only event tap for keyDown / flagsChanged.
///
/// Listen-only means the tap never consumes or rewrites events: typing keeps
/// working in every app, including the ones being recorded. Without
/// Accessibility permission no tap is created at all — `start` returns `false`,
/// `isInstalled` stays `false`, and nothing is prompted. The settings page is
/// the only place that may ask the system for the grant.
@MainActor
final class KeyEventMonitor {
    private let permissionOverride: Bool?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var box: KeyEventTapBox?

    private(set) var isInstalled = false
    private(set) var permission: KeyDisplayPermission
    /// A disabled monitor never installs a tap, even with permission.
    var isEnabled = true
    /// Exposed for diagnostics and the self test.
    private(set) var lastFailureReason: String?

    init(permissionOverride: Bool? = nil) {
        self.permissionOverride = permissionOverride
        self.permission = (permissionOverride ?? AXIsProcessTrusted()) ? .granted : .denied
    }

    var hasAccessibilityPermission: Bool {
        permissionOverride ?? AXIsProcessTrusted()
    }

    /// Install the tap. Returns `false` (without crashing or prompting) when
    /// the feature is disabled, access is denied, or the system refuses the tap.
    @discardableResult
    func start(onEvent: @escaping @MainActor (KeyEventDescriptor) -> Void) -> Bool {
        if isInstalled { return true }
        guard isEnabled else {
            lastFailureReason = "已关闭"
            return false
        }
        guard hasAccessibilityPermission else {
            permission = .denied
            lastFailureReason = "需要辅助功能权限"
            DebugLog.log("key display: accessibility permission missing, tap not installed")
            return false
        }

        let box = KeyEventTapBox()
        box.handler = { descriptor in
            Task { @MainActor in onEvent(descriptor) }
        }

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: keyDisplayEventTapCallback,
            userInfo: Unmanaged.passUnretained(box).toOpaque()
        ) else {
            permission = .denied
            lastFailureReason = "系统拒绝创建事件监听"
            DebugLog.log("key display: CGEvent.tapCreate returned nil")
            return false
        }
        box.tap = tap

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            permission = .denied
            lastFailureReason = "无法创建事件监听运行源"
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        self.box = box
        self.isInstalled = true
        self.permission = .granted
        self.lastFailureReason = nil
        DebugLog.log("key display: event tap installed")
        return true
    }

    /// Remove the tap. Safe to call repeatedly and when `start` failed.
    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        tap = nil
        box?.handler = nil
        box?.tap = nil
        box = nil
        if isInstalled {
            DebugLog.log("key display: event tap removed")
        }
        isInstalled = false
    }

    /// Explicit user action from Settings. Never called automatically: that is
    /// what stops the app from re-prompting on every launch.
    @discardableResult
    static func requestAccessibilityPermission() -> Bool {
        // `kAXTrustedCheckOptionPrompt` is a mutable global in the SDK and is
        // rejected as concurrency-unsafe in Swift 6 mode; the option key's
        // string value is the documented, stable spelling.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
        if let url {
            NSWorkspace.shared.open(url)
        }
    }
}

/// C callback: read the key code/flags, hand them to the box, never consume.
private func keyDisplayEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let box = Unmanaged<KeyEventTapBox>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = box.tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown || type == .flagsChanged else {
        return Unmanaged.passUnretained(event)
    }

    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags
    var modifiers: KeyModifiers = []
    if flags.contains(.maskCommand) { modifiers.insert(.command) }
    if flags.contains(.maskControl) { modifiers.insert(.control) }
    if flags.contains(.maskAlternate) { modifiers.insert(.option) }
    if flags.contains(.maskShift) { modifiers.insert(.shift) }

    box.handler?(KeyEventDescriptor(modifiers: modifiers, keyCode: keyCode))
    return Unmanaged.passUnretained(event)
}

/// Floating pill that shows the last shortcut for a few seconds.
@MainActor
final class KeyDisplayController {
    private(set) var monitor: KeyEventMonitor
    private var panel: NSPanel?
    private var hud: KeyDisplayHUDView?
    private var hideTask: Task<Void, Never>?

    private(set) var position: KeyDisplayPosition = .bottomCenter
    private(set) var displayDuration: TimeInterval = 2
    private(set) var currentText: String?
    /// Incremented on every `showText`; a fade animation belonging to an older
    /// generation must not hide a newer pill.
    private var showGeneration = 0

    var isActive: Bool { monitor.isInstalled }
    var isVisible: Bool { panel?.isVisible ?? false }

    /// `permissionOverride` exists for the self test: `false` simulates a Mac
    /// without Accessibility permission.
    init(permissionOverride: Bool? = nil) {
        self.monitor = KeyEventMonitor(permissionOverride: permissionOverride)
    }

    /// Returns whether the listener is actually installed. A `false` result is
    /// the graceful-degradation path, not an error.
    @discardableResult
    func start(
        position: KeyDisplayPosition,
        duration: TimeInterval,
        enabled: Bool = true
    ) -> Bool {
        self.position = position
        self.displayDuration = min(max(duration, 0.5), 10)
        guard enabled else {
            stop()
            return false
        }
        monitor.isEnabled = true
        let installed = monitor.start { [weak self] descriptor in
            self?.show(descriptor)
        }
        DebugLog.log(
            "key display: start installed=\(installed) permission=\(monitor.permission.rawValue) "
            + "position=\(position.rawValue) duration=\(displayDuration)"
        )
        return installed
    }

    func stop() {
        monitor.stop()
        hideTask?.cancel()
        hideTask = nil
        hide()
        currentText = nil
    }

    func show(_ descriptor: KeyEventDescriptor) {
        let text = descriptor.displayText
        guard !text.isEmpty else { return }
        showText(text)
    }

    /// Show one string (also the test entry point for the pill itself).
    func showText(_ text: String) {
        currentText = text
        showGeneration += 1
        presentPanelIfNeeded(text: text)
        panel?.alphaValue = 1
        panel?.orderFrontRegardless()
        scheduleHide(generation: showGeneration)
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
        panel?.alphaValue = 1
    }

    // MARK: - Panel

    private func presentPanelIfNeeded(text: String) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size = KeyDisplayPlacement.panelSize(for: text)

        if let panel, let hud {
            panel.setFrame(CGRect(origin: panel.frame.origin, size: size), display: true)
            hud.text = text
            panel.setFrameOrigin(KeyDisplayPlacement.origin(
                panelSize: size,
                screenFrame: screen.frame,
                position: position
            ))
            return
        }

        let panel = KeyDisplayPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // One level above the capture overlay (also `.screenSaver`) so the
        // key pill stays visible while the dimming overlay is up.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true

        let hud = KeyDisplayHUDView(frame: CGRect(origin: .zero, size: size))
        hud.text = text
        panel.contentView = hud
        panel.setFrameOrigin(KeyDisplayPlacement.origin(
            panelSize: size,
            screenFrame: screen.frame,
            position: position
        ))
        panel.orderFrontRegardless()

        self.panel = panel
        self.hud = hud
    }

    private func scheduleHide(generation: Int) {
        hideTask?.cancel()
        let duration = displayDuration
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled, let self, let panel = self.panel,
                  generation == self.showGeneration else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, generation == self.showGeneration else { return }
                    self.panel?.orderOut(nil)
                    self.panel?.alphaValue = 1
                }
            }
        }
    }
}

private final class KeyDisplayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Dark pill with the shortcut text, centred.
@MainActor
private final class KeyDisplayHUDView: NSView {
    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            label.stringValue = text
            needsDisplay = true
        }
    }

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textColor = NSColor.white.withAlphaComponent(0.96)
        label.alignment = .center
        label.frame = bounds.insetBy(dx: 10, dy: 10)
        label.autoresizingMask = [.width, .height]
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.shouldAntialias = true
        let capsule = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: bounds.height / 2,
            yRadius: bounds.height / 2
        )
        NSColor.black.withAlphaComponent(0.78).setFill()
        capsule.fill()
        NSColor.white.withAlphaComponent(0.18).setStroke()
        capsule.lineWidth = 1
        capsule.stroke()
    }
}

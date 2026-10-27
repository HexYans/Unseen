import AppKit
import CoreGraphics

/// Pure countdown state machine for delayed screenshots.
///
/// Kept separate from the HUD so the self test can assert the exact
/// `3 → 2 → 1 → capture` sequence and cancellation without waiting three real
/// seconds or touching the window server.
struct DelayCountdown {
    enum Event: Equatable {
        case countdown(Int)
        case capture
        case cancelled
    }

    /// How many numbered steps the user sees, i.e. the configured delay.
    let seconds: Int
    private(set) var remaining: Int
    private(set) var isCancelled = false
    private(set) var hasFired = false

    init(seconds: Int) {
        // A configured zero/negative delay means "no waiting"; still show one
        // tick so the HUD has something to display instead of flashing.
        let clamped = min(max(seconds, 1), 60)
        self.seconds = clamped
        self.remaining = clamped
    }

    var displayText: String { "\(remaining)" }

    /// Advance one second. Once `.capture` has been returned it stays returned,
    /// so a timer that fires late cannot capture twice.
    mutating func tick() -> Event {
        if isCancelled { return .cancelled }
        if hasFired { return .capture }
        guard remaining > 1 else {
            hasFired = true
            remaining = 0
            return .capture
        }
        remaining -= 1
        return .countdown(remaining)
    }

    @discardableResult
    mutating func cancel() -> Event {
        guard !hasFired else { return .capture }
        isCancelled = true
        remaining = 0
        return .cancelled
    }
}

/// Floating label shown while a delayed screenshot counts down.
///
/// It is an ordinary non-activating panel: the user is arranging other windows,
/// so stealing key focus would defeat the point of the delay.
@MainActor
final class DelayCountdownController {
    private static let panelSize = CGSize(width: 176, height: 124)

    private var panel: NSPanel?
    private var hud: DelayHUDView?
    private var task: Task<Void, Never>?
    private var countdown: DelayCountdown
    private let screen: NSScreen?
    private var keyMonitor: Any?

    var onComplete: (() -> Void)?
    var onCancel: (() -> Void)?

    var isRunning: Bool { task != nil }

    init(seconds: Int, screen: NSScreen?) {
        countdown = DelayCountdown(seconds: seconds)
        self.screen = screen
    }

    func start() {
        guard task == nil else { return }
        presentPanel()
        installKeyMonitor()
        DebugLog.log("delay: countdown \(countdown.seconds)s")
        task = Task { @MainActor [weak self] in
            var current = DelayCountdown(seconds: self?.countdown.seconds ?? 3)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled, self.task != nil else { return }
                switch current.tick() {
                case .countdown(let value):
                    self.countdown = current
                    self.hud?.remaining = value
                    DebugLog.log("delay: \(value)")
                case .capture:
                    self.countdown = current
                    self.finish()
                    return
                case .cancelled:
                    return
                }
            }
        }
    }

    func cancel() {
        guard task != nil else { return }
        countdown.cancel()
        stop()
        onCancel?()
    }

    /// Hides the HUD, waits for the compositor to drop it, then reports ready.
    private func finish() {
        stop()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 160_000_000)
            self?.onComplete?()
        }
    }

    private func stop() {
        task?.cancel()
        task = nil
        removeKeyMonitor()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        hud = nil
    }

    private func presentPanel() {
        let screen = screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true

        let hud = DelayHUDView(frame: CGRect(origin: .zero, size: Self.panelSize))
        hud.remaining = countdown.remaining
        hud.total = countdown.seconds
        panel.contentView = hud

        let origin = CGPoint(
            x: screen.frame.midX - Self.panelSize.width / 2,
            y: screen.frame.maxY - Self.panelSize.height - 64
        )
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        self.panel = panel
        self.hud = hud
    }

    /// Escape cancels during the countdown. A local monitor is enough: the
    /// panel never becomes key, and the monitor exists only while counting.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.task != nil, event.keyCode == 53 else { return event }
            self.cancel()
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

/// Big number plus caption on a dark capsule.
private final class DelayHUDView: NSView {
    var remaining = 3 {
        didSet { needsDisplay = true }
    }
    var total = 3

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.shouldAntialias = true
        let card = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            xRadius: 18,
            yRadius: 18
        )
        NSColor.black.withAlphaComponent(0.74).setFill()
        card.fill()
        NSColor.white.withAlphaComponent(0.18).setStroke()
        card.lineWidth = 1
        card.stroke()

        let number = "\(remaining)" as NSString
        let numberAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 54, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let numberSize = number.size(withAttributes: numberAttributes)
        number.draw(
            at: CGPoint(
                x: (bounds.width - numberSize.width) / 2,
                y: bounds.height - numberSize.height - 14
            ),
            withAttributes: numberAttributes
        )

        let caption = "延时截图 · \(total) 秒" as NSString
        let captionAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.78)
        ]
        let captionSize = caption.size(withAttributes: captionAttributes)
        caption.draw(
            at: CGPoint(
                x: (bounds.width - captionSize.width) / 2,
                y: 12
            ),
            withAttributes: captionAttributes
        )
    }
}

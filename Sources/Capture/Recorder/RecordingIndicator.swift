import AppKit

/// Where the recording HUD sits. Extracted so the self test can assert the
/// bottom/top placement arithmetic without a window server.
enum RecordingIndicatorPlacement {
    static let panelSize = CGSize(width: 208, height: 40)
    /// Distance from the top of the screen, below the menu bar.
    static let topInset: CGFloat = 44

    static func origin(
        panelSize: CGSize = RecordingIndicatorPlacement.panelSize,
        screenFrame: CGRect
    ) -> CGPoint {
        CGPoint(
            x: (screenFrame.midX - panelSize.width / 2).rounded(),
            y: (screenFrame.maxY - panelSize.height - topInset).rounded()
        )
    }
}

/// Floating recording control: red dot, MM:SS, pause/resume and stop.
///
/// An ordinary non-activating panel, like the delay/scroll HUDs. It is ordered
/// on screen *before* the stream starts so the recorder's
/// `SCContentFilter(excludingWindows:)` can keep it out of the video.
@MainActor
final class RecordingIndicatorController {
    private(set) var panel: NSPanel?
    private(set) var indicatorView: RecordingIndicatorView?
    /// Exposed for the self test.
    private(set) var isVisible = false

    var onPauseToggle: (() -> Void)?
    var onStop: (() -> Void)?

    /// - Parameter origin: bottom-left AppKit point for the panel. The overlay
    ///   passes the frame of the capture toolbar it replaces, so the HUD lands
    ///   exactly where the screenshot toolbar was; `nil` keeps the historical
    ///   top-centre placement.
    func show(
        state: RecordingState,
        elapsedText: String = "00:00",
        origin: CGPoint? = nil
    ) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size = RecordingIndicatorPlacement.panelSize

        let panel = IndicatorPanel(
            contentRect: CGRect(origin: .zero, size: size),
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
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        panel.ignoresMouseEvents = false

        let view = RecordingIndicatorView(frame: CGRect(origin: .zero, size: size))
        view.update(state: state, elapsedText: elapsedText)
        view.onPauseToggle = { [weak self] in self?.onPauseToggle?() }
        view.onStop = { [weak self] in self?.onStop?() }
        panel.contentView = view

        panel.setFrameOrigin(
            origin ?? RecordingIndicatorPlacement.origin(
                panelSize: size,
                screenFrame: screen.frame
            )
        )
        panel.orderFrontRegardless()

        self.panel = panel
        self.indicatorView = view
        self.isVisible = true
        DebugLog.log(
            "recorder: indicator shown at \(NSStringFromPoint(panel.frame.origin)) state=\(state.rawValue)"
        )
    }

    func update(state: RecordingState, elapsedText: String) {
        guard let indicatorView else { return }
        indicatorView.update(state: state, elapsedText: elapsedText)
        if let panel {
            panel.ignoresMouseEvents = false
            // Re-assert above other windows; full-screen apps can otherwise
            // cover a panel that was ordered before they entered full screen.
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        indicatorView?.stopPulse()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        indicatorView = nil
        DebugLog.log("recorder: indicator hidden")
    }
}

/// Borderless panels must opt in to key status only when they need it; the HUD
/// never takes key focus from the app being recorded.
private final class IndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Capsule with a pulsing dot, the elapsed time and two borderless buttons.
@MainActor
final class RecordingIndicatorView: NSView {
    var onPauseToggle: (() -> Void)?
    var onStop: (() -> Void)?

    private let dot = RecordingDotView(frame: NSRect(x: 14, y: 15, width: 10, height: 10))
    private let timeLabel = NSTextField(labelWithString: "00:00")
    private let pauseButton = NSButton()
    private let stopButton = NSButton()

    private(set) var state: RecordingState = .idle
    /// Text currently drawn; exposed for the self test.
    private(set) var elapsedText = "00:00"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        timeLabel.textColor = NSColor.white.withAlphaComponent(0.95)
        timeLabel.alignment = .left
        timeLabel.frame = NSRect(x: 32, y: 11, width: 82, height: 18)
        addSubview(timeLabel)

        pauseButton.isBordered = false
        pauseButton.bezelStyle = .regularSquare
        pauseButton.contentTintColor = NSColor.white.withAlphaComponent(0.9)
        pauseButton.imagePosition = .imageOnly
        pauseButton.target = self
        pauseButton.action = #selector(pauseTapped)
        pauseButton.toolTip = "暂停 / 继续录制"
        pauseButton.frame = NSRect(x: 128, y: 6, width: 32, height: 28)
        addSubview(pauseButton)

        stopButton.isBordered = false
        stopButton.bezelStyle = .regularSquare
        stopButton.contentTintColor = NSColor.white.withAlphaComponent(0.9)
        stopButton.imagePosition = .imageOnly
        stopButton.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "停止录制")
        stopButton.target = self
        stopButton.action = #selector(stopTapped)
        stopButton.toolTip = "停止录制"
        stopButton.frame = NSRect(x: 166, y: 6, width: 32, height: 28)
        addSubview(stopButton)

        addSubview(dot)
        update(state: .recording, elapsedText: "00:00")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The pause button changes symbol with the state; the dot stops pulsing
    /// and turns orange while paused so "paused" is unmistakable.
    func update(state: RecordingState, elapsedText: String) {
        self.state = state
        self.elapsedText = elapsedText
        timeLabel.stringValue = elapsedText
        dot.state = state
        pauseButton.image = NSImage(
            systemSymbolName: state == .paused ? "play.fill" : "pause.fill",
            accessibilityDescription: state == .paused ? "继续录制" : "暂停录制"
        )
        if state.isActive {
            dot.startPulse()
        } else {
            dot.stopPulse()
        }
        needsDisplay = true
    }

    func stopPulse() { dot.stopPulse() }

    @objc private func pauseTapped() { onPauseToggle?() }
    @objc private func stopTapped() { onStop?() }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.shouldAntialias = true
        let capsule = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: bounds.height / 2,
            yRadius: bounds.height / 2
        )
        NSColor.black.withAlphaComponent(0.76).setFill()
        capsule.fill()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        capsule.lineWidth = 1
        capsule.stroke()
    }
}

/// The red dot. A timer flips its alpha (0.35 ↔ 1.0) so it reads as "live".
@MainActor
private final class RecordingDotView: NSView {
    private var timer: Timer?
    private var bright = true
    var state: RecordingState = .recording {
        didSet {
            if state.isActive {
                startPulse()
            } else {
                stopPulse()
            }
            needsDisplay = true
        }
    }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func startPulse() {
        guard timer == nil, state == .recording else { return }
        bright = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.bright.toggle()
                self.needsDisplay = true
            }
        }
    }

    func stopPulse() {
        timer?.invalidate()
        timer = nil
        bright = true
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopPulse() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor
        switch state {
        case .paused:
            color = .systemOrange
        case .recording:
            color = NSColor.systemRed.withAlphaComponent(bright ? 1 : 0.35)
        default:
            color = NSColor.systemRed
        }
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
    }
}

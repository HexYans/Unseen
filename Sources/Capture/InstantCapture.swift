import AppKit
import QuartzCore

/// The two zero-UI capture entries.
///
/// `CaptureMode.window` dispatches into `.window` here, so the mode and the
/// `⌃⌥⌘W` hot key share one pipeline: no selection surface, no confirmation.
/// `.fullScreen` keeps its own direct path in `CaptureCoordinator`.
enum InstantCaptureKind: String, CaseIterable, Equatable, Sendable {
    /// The front-most normal window under the pointer (fallback: its screen).
    case window
    /// The screen under the pointer.
    case fullScreen

    var title: String {
        switch self {
        case .window: "即时窗口"
        case .fullScreen: "即时全屏"
        }
    }

    var symbol: String {
        switch self {
        case .window: "macwindow"
        case .fullScreen: "rectangle.inset.filled"
        }
    }
}

/// What one instant capture produced. The self test awaits the task and reads
/// the pixels / file / failure from here; production code ignores the value.
struct InstantCaptureResult {
    let kind: InstantCaptureKind
    let shot: CapturedScreenshot?
    /// Set only when a window was actually captured (not on the screen
    /// fallback).
    let windowNumber: Int?
    let savedURL: URL?
    let error: Error?

    var succeeded: Bool { shot != nil && error == nil }

    var pixelSize: CGSize {
        guard let shot else { return .zero }
        return CGSize(width: shot.image.width, height: shot.image.height)
    }

    static func failure(
        _ kind: InstantCaptureKind,
        error: Error? = nil
    ) -> InstantCaptureResult {
        InstantCaptureResult(
            kind: kind,
            shot: nil,
            windowNumber: nil,
            savedURL: nil,
            error: error
        )
    }
}

/// A borderless, non-activating window that only draws the confirmation ring.
/// It is an `NSWindow`, not an `NSPanel`, so the "no panel was shown" invariant
/// of the instant path stays easy to assert.
final class InstantCaptureCueWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Draws the thin ring + centre dot for a full-screen shot, or the rounded
/// window outline iShot uses to confirm "that window is now in the clipboard".
/// No text, no controls, no hit testing.
private final class InstantCaptureCueView: NSView {
    private let accent = NSColor.controlAccentColor
    let windowShaped: Bool
    let cornerRadius: CGFloat

    init(frame: CGRect, windowShaped: Bool, cornerRadius: CGFloat) {
        self.windowShaped = windowShaped
        self.cornerRadius = cornerRadius
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if windowShaped {
            let rect = bounds.insetBy(dx: 2, dy: 2)
            guard rect.width > 0, rect.height > 0 else { return }
            let outline = NSBezierPath(
                roundedRect: rect,
                xRadius: cornerRadius,
                yRadius: cornerRadius
            )
            NSColor.black.withAlphaComponent(0.40).setStroke()
            outline.lineWidth = 5
            outline.stroke()
            accent.withAlphaComponent(0.95).setStroke()
            outline.lineWidth = 2
            outline.stroke()
            return
        }

        let ringRect = bounds.insetBy(dx: 2, dy: 2)
        guard ringRect.width > 0, ringRect.height > 0 else { return }

        // A dark halo below a light ring keeps the cue visible on both a white
        // document and a black terminal.
        let halo = NSBezierPath(ovalIn: ringRect)
        halo.lineWidth = 4
        NSColor.black.withAlphaComponent(0.45).setStroke()
        halo.stroke()

        let ring = NSBezierPath(ovalIn: ringRect)
        ring.lineWidth = 2
        NSColor.white.withAlphaComponent(0.95).setStroke()
        ring.stroke()

        let dotRect = CGRect(
            x: bounds.midX - 2,
            y: bounds.midY - 2,
            width: 4,
            height: 4
        )
        accent.withAlphaComponent(0.95).setFill()
        NSBezierPath(ovalIn: dotRect).fill()
    }
}

/// Owns the single, transient visual confirmation for an instant capture.
///
/// Properties that matter for the "unobtrusive" requirement:
/// - `ignoresMouseEvents = true`: clicks pass through to whatever is below;
/// - non-activating borderless window: the app never becomes active;
/// - `.screenSaver` + 1 level: above the overlay level, never lost behind
///   normal windows, and it cannot become key;
/// - fades over `duration` and closes itself, with a task backstop so it
///   disappears even if AppKit's animation is interrupted.
@MainActor
final class InstantCaptureCueController {
    /// Fade duration. The whole cue lives this long; the self test waits a
    /// little longer before asserting it is gone.
    static let duration: TimeInterval = 0.25
    /// Diameter of the ring, in points.
    static let ringSide: CGFloat = 56
    /// Corner radius of the window-shaped confirmation outline.
    static let windowCornerRadius: CGFloat = 10

    private(set) var window: InstantCaptureCueWindow?
    private var hideTask: Task<Void, Never>?

    var isPresenting: Bool { window != nil }

    /// Order the cue in around `point` (global AppKit points) on `screen`, or
    /// around `windowFrame` when the capture was a window. Never activates the
    /// app and never accepts events.
    func show(
        at point: CGPoint,
        on screen: NSScreen,
        windowFrame: CGRect? = nil
    ) {
        close()

        let limit = screen.frame
        let isWindow = windowFrame != nil
        let frame: CGRect
        let clamped: CGRect
        if let windowFrame {
            frame = windowFrame.insetBy(dx: -3, dy: -3)
            clamped = frame.intersection(limit)
        } else {
            let side = Self.ringSide
            let half = side / 2
            frame = CGRect(
                x: point.x - half,
                y: point.y - half,
                width: side,
                height: side
            )
            var value = frame
            value.origin.x = min(max(frame.minX, limit.minX + 2), limit.maxX - side - 2)
            value.origin.y = min(max(frame.minY, limit.minY + 2), limit.maxY - side - 2)
            clamped = value
        }

        let window = InstantCaptureCueWindow(
            contentRect: clamped,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        window.contentView = InstantCaptureCueView(
            frame: CGRect(origin: .zero, size: clamped.size),
            windowShaped: isWindow,
            cornerRadius: Self.windowCornerRadius
        )
        window.alphaValue = 1
        window.orderFrontRegardless()
        self.window = window

        // Fade, then close. The sleep is the authority: an interrupted
        // animation must not leave a transparent window on screen forever.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 0
        }
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.duration * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    func close() {
        hideTask?.cancel()
        hideTask = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
    }
}

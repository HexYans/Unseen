import AppKit

/// The dark veil over the screen with the selection punched out.
///
/// It owns exactly two things: the **material** — a flat black curtain — and
/// the **shape** of the hole. The hole is rounded (`holeCornerRadius`, 12 pt),
/// so the shaded sliver at each corner reads as a macOS window corner while the
/// border itself stays square.
///
/// The material is deliberately the plain translucent black it always was: no
/// backdrop, no blur, no tint over a material. The screen behind keeps its own
/// contrast, just darker — that is the point.
///
/// It is not interactive (`hitTest` returns nil), so the root view can route
/// drags to the border without the veil swallowing them.
final class DimmingView: NSView {
    /// Selection hole in this view's coordinates. Empty means "no hole".
    var selectionRect: CGRect = .zero {
        didSet {
            guard selectionRect != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Corner radius of the hole, in points. The border stays square; this is
    /// the shade that suggests an Apple window corner.
    var holeCornerRadius: CGFloat = DimmingView.defaultCornerRadius {
        didSet {
            guard holeCornerRadius != oldValue else { return }
            needsDisplay = true
        }
    }

    /// macOS 27 windows are ~12 pt; the exported image is clipped with the same
    /// radius (`CaptureCorner`), so what the user sees is what they get.
    nonisolated static let defaultCornerRadius: CGFloat = 12

    /// The original flat curtain: 38 % black over whatever is on screen.
    var dimAlpha: CGFloat = 0.38 {
        didSet {
            guard dimAlpha != oldValue else { return }
            needsDisplay = true
        }
    }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The area the veil covers: the whole view minus the rounded hole.
    /// Authored as two subpaths for an **even-odd** fill.
    private var veilPath: NSBezierPath {
        let path = NSBezierPath(rect: bounds)
        if let hole = roundedHole() {
            let radius = holeRadius(for: hole)
            path.append(
                NSBezierPath(roundedRect: hole, xRadius: radius, yRadius: radius)
            )
            path.windingRule = .evenOdd
        }
        return path
    }

    /// True when `point` is covered by the veil, i.e. outside the rounded
    /// selection hole. Exposed because "the corner is shaded, the edge is not"
    /// is a geometric claim the self test can make exactly instead of hunting
    /// for pixels under the white border.
    func covers(_ point: CGPoint) -> Bool {
        veilPath.contains(point)
    }

    private func roundedHole() -> CGRect? {
        guard selectionRect.width >= 1, selectionRect.height >= 1 else { return nil }
        return selectionRect
    }

    private func holeRadius(for rect: CGRect) -> CGFloat {
        max(0, min(holeCornerRadius, min(rect.width, rect.height) / 2))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(dimAlpha).setFill()
        veilPath.fill()
    }
}

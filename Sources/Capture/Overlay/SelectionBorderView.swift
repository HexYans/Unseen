import AppKit

/// The eight grab points of a selection, named by their position rather than
/// by an index — the previous implementation mixed these up, which is why
/// dragging one handle sometimes resized the opposite edge.
enum BorderHandle: CaseIterable, Hashable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var movesLeftEdge: Bool {
        switch self {
        case .topLeft, .left, .bottomLeft: true
        default: false
        }
    }

    var movesRightEdge: Bool {
        switch self {
        case .topRight, .right, .bottomRight: true
        default: false
        }
    }

    var movesBottomEdge: Bool {
        switch self {
        case .bottomLeft, .bottom, .bottomRight: true
        default: false
        }
    }

    var movesTopEdge: Bool {
        switch self {
        case .topLeft, .top, .topRight: true
        default: false
        }
    }
}

/// The one definition of what a committed selection's outline looks like:
/// a dark halo under a white border.
///
/// The region selection and the window highlight both read these values, so the
/// window pick cannot drift back to the accent colour and the two surfaces
/// cannot disagree about width or halo. The numbers are exactly the ones region
/// drawing used inline before, so the reference surface is pixel-identical.
enum SelectionBorderStyle {
    /// A dark halo keeps the white border readable over white documents.
    static let haloColor = NSColor.black.withAlphaComponent(0.35)
    static let haloWidth: CGFloat = 3
    static let haloInset: CGFloat = -0.5

    static let borderColor = NSColor.white
    static let borderWidth: CGFloat = 1.5

    /// Stroke the shared outline into the current graphics context.
    static func strokeOutline(_ rect: CGRect) {
        let halo = NSBezierPath(rect: rect.insetBy(dx: haloInset, dy: haloInset))
        haloColor.setStroke()
        halo.lineWidth = haloWidth
        halo.stroke()

        let border = NSBezierPath(rect: rect)
        borderColor.setStroke()
        border.lineWidth = borderWidth
        border.stroke()
    }
}

/// The selection itself: border, eight round handles, hit testing, and the
/// drag maths.
///
/// This view is intentionally *not* hit-testable (`hitTest` returns nil) and
/// does not capture mouse events itself. `CaptureOverlayView` is the event
/// router and forwards already-converted local points into the `begin` /
/// `continue` / `end` methods below. That split is what lets the toolbar be a
/// sibling view that receives its own clicks instead of being covered by the
/// border.
final class SelectionBorderView: NSView {
    enum Style {
        /// Normal region selection: border + eight handles.
        case selection
        /// Window-mode hover highlight: a tinted rectangle without handles.
        case highlight
    }

    static let minimumSide: CGFloat = 40
    static let handleRadius: CGFloat = 5
    static let handleHitRadius: CGFloat = 9

    var style: Style = .selection {
        didSet {
            guard style != oldValue else { return }
            needsDisplay = true
        }
    }

    private(set) var selectionRect: CGRect = .zero

    /// The handle currently being dragged, for cursor feedback and debugging.
    private(set) var activeHandle: BorderHandle?

    private enum DragMode {
        case idle
        case creating(anchor: CGPoint)
        case moving(start: CGPoint, original: CGRect)
        case resizing(handle: BorderHandle, original: CGRect)
    }

    private var dragMode: DragMode = .idle

    /// True only while the current drag is creating a brand-new box (as
    /// opposed to moving or resizing an existing one). The OCR entry point uses
    /// this to tell "user finished drawing a region" from "user nudged it".
    private(set) var isCreatingSelection = false

    /// Bounds the interaction is clamped to. Set on every `beginInteraction`.
    private var interactionBounds: CGRect = .zero

    override var isOpaque: Bool { false }

    // The overlay root owns event routing; see the type comment.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: - State

    func setSelection(_ rect: CGRect) {
        guard selectionRect != rect else { return }
        selectionRect = rect.standardized
        needsDisplay = true
    }

    func clearSelection() {
        setSelection(.zero)
        activeHandle = nil
        dragMode = .idle
        isCreatingSelection = false
    }

    /// Resize a selection to an explicit size, keeping its **centre** fixed.
    ///
    /// This is the geometry behind the editable size chip. iShot does not
    /// document an anchor, so centre anchoring is a product choice: the box the
    /// user framed stays where they framed it, and typing a number grows/shrinks
    /// symmetrically instead of dragging one edge across the content.
    ///
    /// Two clamps, in this order:
    /// 1. **size** — never below `minimumSide` (the same 40 pt the handles
    ///    enforce) and never larger than the screen, so `5000 × 5000` becomes a
    ///    full-screen selection instead of an impossible rectangle;
    /// 2. **position** — a grown box that would poke past an edge is shifted
    ///    back inside *without* shrinking. Only then does the centre move, which
    ///    is unavoidable when the requested box is already against the edge.
    static func centeredResize(_ rect: CGRect, to size: CGSize, within bounds: CGRect) -> CGRect {
        let maxWidth = max(minimumSide, bounds.width)
        let maxHeight = max(minimumSide, bounds.height)
        let width = min(max(size.width, minimumSide), maxWidth)
        let height = min(max(size.height, minimumSide), maxHeight)
        let centre = CGPoint(x: rect.midX, y: rect.midY)

        var result = CGRect(
            x: centre.x - width / 2,
            y: centre.y - height / 2,
            width: width,
            height: height
        )
        if result.maxX > bounds.maxX { result.origin.x = bounds.maxX - width }
        if result.maxY > bounds.maxY { result.origin.y = bounds.maxY - height }
        if result.minX < bounds.minX { result.origin.x = bounds.minX }
        if result.minY < bounds.minY { result.origin.y = bounds.minY }
        return result.standardized
    }

    var hasSelection: Bool {
        selectionRect.width >= 1 && selectionRect.height >= 1
    }

    // MARK: - Handle geometry

    /// The one place handle positions are computed. Everything else — drawing,
    /// hit testing, cursor feedback — reads this.
    func handleCentres(for rect: CGRect) -> [(handle: BorderHandle, point: CGPoint)] {
        BorderHandle.allCases.map { handle in
            (handle, centre(of: handle, in: rect))
        }
    }

    private func centre(of handle: BorderHandle, in rect: CGRect) -> CGPoint {
        let x: CGFloat
        switch handle {
        case .topLeft, .left, .bottomLeft: x = rect.minX
        case .top, .bottom: x = rect.midX
        case .topRight, .right, .bottomRight: x = rect.maxX
        }
        let y: CGFloat
        switch handle {
        case .topLeft, .top, .topRight: y = rect.maxY
        case .left, .right: y = rect.midY
        case .bottomLeft, .bottom, .bottomRight: y = rect.minY
        }
        return CGPoint(x: x, y: y)
    }

    /// Which handle, if any, is under `point`. Nearest wins so overlapping
    /// handles on a tiny selection behave predictably.
    func handle(at point: CGPoint) -> BorderHandle? {
        guard hasSelection else { return nil }
        var best: (handle: BorderHandle, distance: CGFloat)?
        for (handle, centre) in handleCentres(for: selectionRect) {
            let dx = point.x - centre.x
            let dy = point.y - centre.y
            let distance = dx * dx + dy * dy
            guard distance <= Self.handleHitRadius * Self.handleHitRadius else { continue }
            if best == nil || distance < best!.distance {
                best = (handle, distance)
            }
        }
        return best?.handle
    }

    // MARK: - Interaction

    /// Begin a drag at a point in this view's coordinates.
    ///
    /// Order matters: a handle wins over "inside", and "inside" wins over
    /// "outside = start a new selection". That ordering is what makes a corner
    /// drag resize instead of moving the whole rectangle.
    func beginInteraction(at point: CGPoint, screenBounds: CGRect) {
        interactionBounds = screenBounds
        activeHandle = nil
        isCreatingSelection = false

        guard style == .selection else {
            dragMode = .idle
            return
        }

        let clamped = clampToBounds(point)

        if hasSelection {
            if let handle = handle(at: point) {
                activeHandle = handle
                dragMode = .resizing(handle: handle, original: selectionRect)
                needsDisplay = true
                return
            }
            if selectionRect.contains(clamped) {
                dragMode = .moving(start: clamped, original: selectionRect)
                return
            }
        }

        // Outside the selection (or no selection yet) always means a new box,
        // even when a stale selection is still on screen.
        dragMode = .creating(anchor: clamped)
        isCreatingSelection = true
        setSelection(CGRect(origin: clamped, size: .zero))
    }

    func continueInteraction(to point: CGPoint) {
        let clamped = clampToBounds(point)

        switch dragMode {
        case .creating(let anchor):
            setSelection(creationRect(from: anchor, to: clamped))
        case .moving(let start, let original):
            setSelection(movedRect(original, from: start, to: clamped))
        case .resizing(let handle, let original):
            setSelection(resizedRect(original, handle: handle, to: clamped))
        case .idle:
            break
        }
    }

    func endInteraction(at point: CGPoint) {
        if case .creating(let anchor) = dragMode {
            // A click without a drag must not leave a 40×40 box behind.
            let dx = point.x - anchor.x
            let dy = point.y - anchor.y
            if (dx * dx + dy * dy).squareRoot() < 2 {
                setSelection(.zero)
                dragMode = .idle
                activeHandle = nil
                isCreatingSelection = false
                needsDisplay = true
                return
            }
        }
        continueInteraction(to: point)
        dragMode = .idle
        activeHandle = nil
        isCreatingSelection = false
        needsDisplay = true
    }

    /// Exposed for the synthetic-event self test: the whole gesture at once.
    func performDrag(from start: CGPoint, to end: CGPoint, in screenBounds: CGRect) {
        beginInteraction(at: start, screenBounds: screenBounds)
        continueInteraction(to: end)
        endInteraction(at: end)
    }

    // MARK: - Drag maths

    private func movedRect(_ original: CGRect, from start: CGPoint, to point: CGPoint) -> CGRect {
        var rect = original
        rect.origin.x += point.x - start.x
        rect.origin.y += point.y - start.y
        // Keep the *whole* rectangle on screen without changing its size.
        let maxX = max(interactionBounds.minX, interactionBounds.maxX - rect.width)
        let maxY = max(interactionBounds.minY, interactionBounds.maxY - rect.height)
        rect.origin.x = min(max(rect.origin.x, interactionBounds.minX), maxX)
        rect.origin.y = min(max(rect.origin.y, interactionBounds.minY), maxY)
        return rect
    }

    private func resizedRect(_ original: CGRect, handle: BorderHandle, to point: CGPoint) -> CGRect {
        var minX = original.minX
        var maxX = original.maxX
        var minY = original.minY
        var maxY = original.maxY

        // Edge handles only touch one axis. `min`/`max` clamp the moving edge
        // against the *opposite* edge, so overshooting stops at 40 pt instead
        // of swapping the two edges (the old "selection flips inside out" bug).
        if handle.movesLeftEdge {
            minX = max(interactionBounds.minX, min(point.x, maxX - Self.minimumSide))
        }
        if handle.movesRightEdge {
            maxX = min(interactionBounds.maxX, max(point.x, minX + Self.minimumSide))
        }
        if handle.movesBottomEdge {
            minY = max(interactionBounds.minY, min(point.y, maxY - Self.minimumSide))
        }
        if handle.movesTopEdge {
            maxY = min(interactionBounds.maxY, max(point.y, minY + Self.minimumSide))
        }

        return CGRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        ).standardized
    }

    private func creationRect(from anchor: CGPoint, to point: CGPoint) -> CGRect {
        var minX = min(anchor.x, point.x)
        var maxX = max(anchor.x, point.x)
        var minY = min(anchor.y, point.y)
        var maxY = max(anchor.y, point.y)

        // Enforce the minimum in the direction the user is dragging, so a tiny
        // drag grows away from the anchor instead of collapsing to a point.
        if maxX - minX < Self.minimumSide {
            if point.x >= anchor.x {
                maxX = anchor.x + Self.minimumSide
            } else {
                minX = anchor.x - Self.minimumSide
            }
        }
        if maxY - minY < Self.minimumSide {
            if point.y >= anchor.y {
                maxY = anchor.y + Self.minimumSide
            } else {
                minY = anchor.y - Self.minimumSide
            }
        }

        var rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        // Shift a box that grew past the edge back inside, preserving size.
        if rect.maxX > interactionBounds.maxX {
            rect.origin.x = interactionBounds.maxX - rect.width
        }
        if rect.maxY > interactionBounds.maxY {
            rect.origin.y = interactionBounds.maxY - rect.height
        }
        if rect.minX < interactionBounds.minX { rect.origin.x = interactionBounds.minX }
        if rect.minY < interactionBounds.minY { rect.origin.y = interactionBounds.minY }
        return rect
    }

    private func clampToBounds(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, interactionBounds.minX), interactionBounds.maxX),
            y: min(max(point.y, interactionBounds.minY), interactionBounds.maxY)
        )
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard hasSelection else { return }
        NSGraphicsContext.current?.shouldAntialias = true

        switch style {
        case .highlight:
            // Window-mode hover: a neutral wash plus the committed selection's
            // own outline. It used to paint the system accent, which made a
            // hovered window look nothing like a drawn region.
            NSColor.white.withAlphaComponent(0.08).setFill()
            NSBezierPath(rect: selectionRect).fill()
            SelectionBorderStyle.strokeOutline(selectionRect)

        case .selection:
            SelectionBorderStyle.strokeOutline(selectionRect)

            for (_, centre) in handleCentres(for: selectionRect) {
                let rect = CGRect(
                    x: centre.x - Self.handleRadius,
                    y: centre.y - Self.handleRadius,
                    width: Self.handleRadius * 2,
                    height: Self.handleRadius * 2
                )
                let circle = NSBezierPath(ovalIn: rect)
                NSColor.white.setFill()
                circle.fill()
                NSColor.controlAccentColor.setStroke()
                circle.lineWidth = 2
                circle.stroke()
            }
        }
    }
}

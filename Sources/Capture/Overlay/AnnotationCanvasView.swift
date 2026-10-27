import AppKit

/// Draws annotations for the overlay. It owns no gestures and no toolbar: the
/// overlay root routes already-converted local points into its `selectionRect`
/// / `annotations` / `draft` state.
///
/// The canvas is inserted **below** `SelectionBorderView` so the eight handles
/// always stay grabbable, and it is not hit-testable for the same reason the
/// veil is not — the root is the event router.
@MainActor
final class AnnotationCanvasView: NSView {
    /// Selection in this view's coordinates. Annotations are normalised to it,
    /// so changing the rect rescales them automatically.
    var selectionRect: CGRect = .zero {
        didSet {
            guard selectionRect != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Committed annotations.
    var annotations: [Annotation] = [] {
        didSet { needsDisplay = true }
    }

    /// The stroke currently being dragged, drawn on top of the committed ones.
    var draft: Annotation? {
        didSet { needsDisplay = true }
    }

    /// Full-screen snapshot taken when the overlay opened. Only `.mosaic`
    /// samples it; every other annotation is pure vector. `nil` means the
    /// snapshot failed, and the canvas draws the translucent placeholder.
    var mosaicBaseImage: CGImage? {
        didSet { needsDisplay = true }
    }

    /// Snapshot pixels per overlay point (`2×2` on Retina). Computed from the
    /// image and screen sizes, not assumed, because scaled displays can differ.
    var mosaicImageScale: CGSize = .zero {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: - Coordinate conversion (single source of truth)

    /// View point → normalised (0…1, top-left origin), clamped to the selection.
    static func normalized(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        guard rect.width > 0, rect.height > 0 else { return .zero }
        return CGPoint(
            x: min(max((point.x - rect.minX) / rect.width, 0), 1),
            y: min(max((rect.maxY - point.y) / rect.height, 0), 1)
        )
    }

    /// Normalised point → view point. The y flip lives here and nowhere else.
    static func viewPoint(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + point.x * rect.width,
            y: rect.maxY - point.y * rect.height
        )
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard selectionRect.width >= 1, selectionRect.height >= 1 else { return }
        let all = draft.map { annotations + [$0] } ?? annotations
        guard !all.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }

        // NSView is bottom-left origin. Move to the selection's top-left and
        // flip, which gives the renderer the y-down space it expects.
        context.saveGState()
        context.translateBy(x: selectionRect.minX, y: selectionRect.maxY)
        context.scaleBy(x: 1, y: -1)

        let mosaicSource = mosaicBaseImage.map { image in
            MosaicSource.overlay(
                image: image,
                viewSize: bounds.size,
                imageScale: mosaicImageScale,
                selection: selectionRect
            )
        }
        AnnotationRenderer.draw(
            all,
            in: context,
            renderSize: selectionRect.size,
            scale: 1,
            highlighterBlendMode: .normal,
            mosaic: mosaicSource
        )
        context.restoreGState()
    }
}

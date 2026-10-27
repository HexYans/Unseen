import AppKit
import CoreGraphics
import SwiftUI

/// The square magnifier that rides beside the pointer during region selection.
///
/// It is a **tracking** aid, on by default (设置 → 截图 → 显示放大镜): the
/// crosshair alone cannot show whether an edge has landed on one pixel or on
/// its neighbour, and that is exactly what the user needs while framing small
/// UI. While the cross is still following the pointer the loupe samples the
/// pre-overlay screen snapshot (`baseImage`, the same pixels `.mosaic` uses)
/// around the cursor and draws them at a fixed zoom. The moment the cross
/// freezes the loupe disappears: the selection is committed, and a magnifier
/// pinned to a pointer that no longer maps to it would be a lie.
///
/// It is deliberately a full-bounds sibling of `CrosshairView` (like it, a
/// `hitTest` no-op) rather than a small floating view:
///
/// * no frame churn per mouse-move — the card is just a rect inside one
///   `draw(_:)`, and AppKit clips to the dirty rect. That dirty rect is the
///   union of the old and new *painted* rects (card + shadow), so the old
///   position is erased completely without redrawing the screen;
/// * one zoom/corner-radius/inset definition, so the picture, the glass ring
///   and the border can never disagree about the square;
/// * the same view works for offscreen renders, where there is no window at
///   all, which is how the verification images are produced.
final class LoupeView: NSView {
    // MARK: - Metrics

    /// Edge length of the square, in points. 118 pt is small enough to stay out
    /// of the selection's way on a 1440-pt screen and large enough for the
    /// crosshair-style detail the owner asked for.
    static let side: CGFloat = 118
    /// Fixed magnification. 4× shows a 29.5 pt patch: one 13 pt glyph plus its
    /// neighbourhood, which is the scale at which "did I get the edge?" reads
    /// instantly. A variable zoom would need a second control and a second
    /// preference for no demonstrated gain.
    static let zoom: CGFloat = 4
    /// Distance between the pointer and the nearest edge of the card, so the
    /// cursor and its cross are never covered.
    static let gap: CGFloat = 18
    /// Side of the square, not a capsule: the owner asked for 方块.
    static let cornerRadius: CGFloat = 10
    /// No glass ring between the picture and the card's edge. The old card
    /// insetted the snapshot by 3 pt and filled that band with a translucent
    /// plate, which read as a white strip around the picture. The picture now
    /// reaches the edge; the glass is only the hairline below.
    static let inset: CGFloat = 0
    /// Drop shadow: blur radius and vertical offset, in points. Named because
    /// the repaint region has to account for them — see `shadowMargin`.
    static let shadowBlurRadius: CGFloat = 14
    static let shadowOffsetY: CGFloat = -3
    /// How far the drop shadow reaches past the card's edge, in points.
    ///
    /// Measured on an offscreen render of this exact card (same blur, offset,
    /// corner radius and stroke): the soft shadow reaches ~10 pt past the
    /// shadowed bottom edge and ~8 pt on the sides. 16 leaves headroom and is
    /// still tight enough that a move repaints only the band it travelled.
    static let shadowMargin: CGFloat = 16

    // MARK: - Input

    /// Pre-overlay screen snapshot, in device pixels. Nil means the capture
    /// snapshot failed, and then the loupe stays hidden rather than showing a
    /// checkerboard.
    var magnifiedImage: CGImage? {
        didSet {
            guard magnifiedImage !== oldValue else { return }
            needsDisplay = true
        }
    }

    /// Snapshot pixels per view point (2×2 on Retina, measured rather than
    /// assumed — scaled displays can differ).
    var imageScale: CGSize = .zero {
        didSet {
            guard imageScale != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Sampled point in this view's coordinates. Nil pauses/hides the card.
    var point: CGPoint? {
        didSet {
            guard point != oldValue else { return }
            // Invalidate both painted rects — the card *and its shadow* at the
            // old position have to be erased, and the same at the new one
            // drawn. A full-bounds `needsDisplay` on a screen-sized transparent
            // view would ask the compositor to redraw the whole overlay on every
            // mouse event; the union of the two painted rects is the smallest
            // region that cannot ghost.
            let rect = Self.invalidationRect(from: oldValue, to: point, in: bounds)
            lastInvalidationRectForTesting = rect
            if let rect { setNeedsDisplay(rect) }
        }
    }

    /// The rect the last `point` change asked AppKit to redraw, for the self
    /// test: it has to contain everything the old frame put on screen.
    private(set) var lastInvalidationRectForTesting: CGRect?

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: - Geometry

    /// The square's rect for one pointer position.
    ///
    /// Preferred placement is **right and below** the pointer (AppKit y is up,
    /// so "below" is `-y`): the two segments of the cross run right and down
    /// from the cursor, and putting the card in the opposite quadrant keeps the
    /// pointer's own neighbourhood visible. Near an edge it flips instead of
    /// sliding over the cursor: right → left when `x` would overflow, below →
    /// above when `y` would. A final clamp keeps the square on screen even at a
    /// corner where both flips still overflow.
    static func cardRect(for point: CGPoint, in bounds: CGRect) -> CGRect {
        var origin = CGPoint(
            x: point.x + gap,
            y: point.y - gap - side
        )
        if origin.x + side > bounds.maxX {
            origin.x = point.x - gap - side
        }
        if origin.y < bounds.minY {
            origin.y = point.y + gap
        }
        origin.x = min(
            max(origin.x, bounds.minX),
            max(bounds.minX, bounds.maxX - side)
        )
        origin.y = min(
            max(origin.y, bounds.minY),
            max(bounds.minY, bounds.maxY - side)
        )
        return CGRect(x: origin.x, y: origin.y, width: side, height: side)
    }

    /// Source rect in *snapshot pixel* space for one pointer position.
    ///
    /// The card is `side` points wide at `zoom`×, so it shows `side / zoom`
    /// points of screen around the cursor. The snapshot is top-left origin and
    /// this view is bottom-left, hence the y flip.
    func sourceRect(for point: CGPoint, in bounds: CGRect) -> CGRect {
        let shown = Self.side / Self.zoom
        let scaleX = max(imageScale.width, 0.0001)
        let scaleY = max(imageScale.height, 0.0001)
        let centreX = point.x * scaleX
        let centreY = (bounds.height - point.y) * scaleY
        return CGRect(
            x: centreX - shown * scaleX / 2,
            y: centreY - shown * scaleY / 2,
            width: shown * scaleX,
            height: shown * scaleY
        )
    }

    /// The rect the card's ink can occupy for one pointer position: the card
    /// itself plus the drop shadow that bleeds outside it.
    static func paintRect(for point: CGPoint, in bounds: CGRect) -> CGRect {
        cardRect(for: point, in: bounds).insetBy(
            dx: -shadowMargin,
            dy: -shadowMargin
        )
    }

    /// Everything a move from `old` to `new` has to repaint, in this view's
    /// coordinates.
    ///
    /// The union of the two **painted** rects, not of the two cards. The card
    /// is only part of what is on screen — the shadow reaches up to 9 pt further —
    /// so `cardRect(old).union(cardRect(new)).insetBy(-2)` erased the card but
    /// left a crescent of the previous frame's shadow behind on every move.
    /// That residue is the trail the owner saw. The union is still the smallest
    /// rect that covers it, so a move repaints only the band the card
    /// travelled, never the whole overlay.
    static func invalidationRect(
        from old: CGPoint?,
        to new: CGPoint?,
        in bounds: CGRect
    ) -> CGRect? {
        var union: CGRect?
        for point in [old, new].compactMap({ $0 }) {
            let painted = paintRect(for: point, in: bounds)
            union = union.map { $0.union(painted) } ?? painted
        }
        guard let union else { return nil }
        return union.intersection(bounds)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let point, let image = magnifiedImage, image.width > 0, image.height > 0
        else { return }
        let card = Self.cardRect(for: point, in: bounds)
        guard card.intersects(dirtyRect) else { return }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        NSGraphicsContext.current?.shouldAntialias = true

        // Everything is snapped to the *device* pixel grid so each snapshot
        // pixel becomes a whole block instead of a half-blended one.
        let deviceScale = max(1, abs(context.ctm.a))
        let picture = Self.aligned(card, to: deviceScale)

        // Soft drop shadow: the card floats over arbitrary content. The
        // picture itself is drawn on top, so the shadow only ever shows
        // outside the card's edge.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.50)
        shadow.shadowBlurRadius = Self.shadowBlurRadius
        shadow.shadowOffset = NSSize(width: 0, height: Self.shadowOffsetY)
        shadow.set()
        NSColor.black.withAlphaComponent(0.18).setFill()
        NSBezierPath(
            cgPath: RoundedRectangle(
                cornerRadius: Self.cornerRadius,
                style: .continuous
            ).path(in: picture).cgPath
        ).fill()
        NSGraphicsContext.restoreGraphicsState()

        // The picture, edge to edge. Nearest-neighbour on purpose: at 4× the
        // user is looking for pixel boundaries, and a smooth upscale turns
        // those into grey mush.
        let intended = sourceRect(for: point, in: bounds)
        let source = CGRect(
            x: intended.minX.rounded(),
            y: intended.minY.rounded(),
            width: max(1, intended.width.rounded()),
            height: max(1, intended.height.rounded())
        )
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clipped = source.intersection(imageBounds)
        if !clipped.isEmpty, let cropped = image.cropping(to: clipped) {
            let destination = Self.destination(
                for: clipped,
                inside: source,
                in: picture
            )
            let shape = NSBezierPath(
                cgPath: RoundedRectangle(
                    cornerRadius: Self.cornerRadius,
                    style: .continuous
                ).path(in: picture).cgPath
            )
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            context.interpolationQuality = .none
            context.setShouldAntialias(false)
            // `CGContext.draw` in AppKit's y-up drawing context already places
            // the image's first row at the rect's top. The usual
            // translate/scale flip belongs to flipped (iOS-style) contexts and
            // mirrored the magnified content vertically here — the
            // orientation is pinned by the loupe test instead of by a comment.
            context.draw(cropped, in: destination)
            context.setShouldAntialias(true)
            NSGraphicsContext.restoreGraphicsState()
        }

        // The glass: a hairline edge, not a frame. A light inner line over a
        // dark outer one reads as a glass surface on white and on black
        // documents without putting a visible band around the pixels.
        let shape = NSBezierPath(
            cgPath: RoundedRectangle(
                cornerRadius: Self.cornerRadius,
                style: .continuous
            ).path(in: picture).cgPath
        )
        NSColor.black.withAlphaComponent(0.22).setStroke()
        shape.lineWidth = 0.6
        shape.stroke()
        let innerGlow = NSBezierPath(
            cgPath: RoundedRectangle(
                cornerRadius: max(1, Self.cornerRadius - 0.5),
                style: .continuous
            ).path(in: picture.insetBy(dx: 0.4, dy: 0.4)).cgPath
        )
        NSColor.white.withAlphaComponent(0.16).setStroke()
        innerGlow.lineWidth = 0.5
        innerGlow.stroke()

        // Sample-point mark: the single pixel pair the card is centred on.
        // A loupe without it leaves the user guessing which of the 16 pixels
        // under the square is "the" coordinate.
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: picture.midX - 4, y: picture.midY))
        cross.line(to: CGPoint(x: picture.midX + 4, y: picture.midY))
        cross.move(to: CGPoint(x: picture.midX, y: picture.midY - 4))
        cross.line(to: CGPoint(x: picture.midX, y: picture.midY + 4))
        NSColor.black.withAlphaComponent(0.30).setStroke()
        cross.lineWidth = 2
        cross.stroke()
        NSColor.white.withAlphaComponent(0.85).setStroke()
        cross.lineWidth = 1
        cross.stroke()
    }

    /// `rect` snapped to whole device pixels.
    static func aligned(_ rect: CGRect, to scale: CGFloat) -> CGRect {
        let unit = max(1, scale)
        return CGRect(
            x: (rect.minX * unit).rounded() / unit,
            y: (rect.minY * unit).rounded() / unit,
            width: max(1, (rect.width * unit).rounded()) / unit,
            height: max(1, (rect.height * unit).rounded()) / unit
        )
    }

    /// Where a (possibly edge-clipped) patch goes inside the card.
    ///
    /// The patch keeps the same scale as an unclipped one, so a pointer near
    /// the screen edge shows fewer pixels instead of stretching the ones it
    /// has. `source` is in snapshot pixels with a top-left origin, `picture`
    /// in this view's bottom-left points.
    static func destination(
        for clipped: CGRect,
        inside source: CGRect,
        in picture: CGRect
    ) -> CGRect {
        guard source.width > 0, source.height > 0 else { return picture }
        let left = (clipped.minX - source.minX) / source.width
        let right = (clipped.maxX - source.minX) / source.width
        let top = (clipped.minY - source.minY) / source.height
        let bottom = (clipped.maxY - source.minY) / source.height
        return CGRect(
            x: picture.minX + left * picture.width,
            y: picture.maxY - bottom * picture.height,
            width: max(1, (right - left) * picture.width),
            height: max(1, (bottom - top) * picture.height)
        )
    }
}

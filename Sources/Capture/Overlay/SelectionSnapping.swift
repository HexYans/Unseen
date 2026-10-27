import CoreGraphics

/// iShot-style magnet: while a new box is being drawn, the moving corner snaps
/// to nearby window and screen edges. Pure geometry so the threshold is
/// verifiable without a window server.
///
/// Snapping is deliberately **corner-only**: the anchor stays where the user
/// pressed, which is what makes "drag roughly to the window edge" land exactly
/// on the edge without the whole gesture fighting the pointer.
enum SelectionSnapping {
    /// How close (in points) the pointer must be before an edge claims it.
    /// iShot uses a small magnet; 6 pt is large enough to feel sticky with a
    /// trackpad and small enough that a deliberate 10 pt inset is still
    /// possible.
    static let threshold: CGFloat = 6

    /// Snap one point to the nearest vertical and horizontal edge in `targets`.
    /// Each axis is independent, so a point can snap x to one window and y to
    /// another (a corner between two windows).
    static func snap(
        _ point: CGPoint,
        targets: [CGRect],
        threshold: CGFloat = threshold
    ) -> CGPoint {
        var bestX: (value: CGFloat, distance: CGFloat)?
        var bestY: (value: CGFloat, distance: CGFloat)?

        for rect in targets {
            guard rect.width >= 1, rect.height >= 1 else { continue }
            for candidate in [rect.minX, rect.maxX, rect.midX] {
                let distance = abs(point.x - candidate)
                guard distance <= threshold else { continue }
                if bestX == nil || distance < bestX!.distance {
                    bestX = (candidate, distance)
                }
            }
            for candidate in [rect.minY, rect.maxY, rect.midY] {
                let distance = abs(point.y - candidate)
                guard distance <= threshold else { continue }
                if bestY == nil || distance < bestY!.distance {
                    bestY = (candidate, distance)
                }
            }
        }

        return CGPoint(x: bestX?.value ?? point.x, y: bestY?.value ?? point.y)
    }
}

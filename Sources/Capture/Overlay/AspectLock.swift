import CoreGraphics

/// iShot's number-key aspect lock. The mapping is taken verbatim from iShot's
/// localized help text (0=Free, 1=1:1 … 9=4:3), and the maths is pure so the
/// ratio can be verified without a window server.
enum AspectLock {
    /// Width ÷ height for each digit.
    static let ratios: [Int: CGFloat] = [
        1: 1.0,          // 1:1
        2: 2.0 / 3.0,    // 2:3
        3: 3.0 / 4.0,    // 3:4
        4: 4.0 / 5.0,    // 4:5
        5: 5.0 / 7.0,    // 5:7
        6: 9.0 / 16.0,   // 9:16
        7: 16.0 / 9.0,   // 16:9
        8: 3.0 / 2.0,    // 3:2
        9: 4.0 / 3.0     // 4:3
    ]

    static func ratio(for digit: Int) -> CGFloat? {
        ratios[digit]
    }

    /// Adjust the moving corner of a new box so the rectangle has `ratio`
    /// (width ÷ height) while keeping the anchor fixed and the drag direction.
    static func adjust(
        anchor: CGPoint,
        point: CGPoint,
        ratio: CGFloat
    ) -> CGPoint {
        guard ratio > 0 else { return point }
        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        var width = abs(dx)
        var height = abs(dy)

        if width < 1, height < 1 { return point }
        if height < 1 {
            height = width / ratio
        } else if width < 1 {
            width = height * ratio
        } else if width / height > ratio {
            height = width / ratio
        } else {
            width = height * ratio
        }

        return CGPoint(
            x: anchor.x + (dx < 0 ? -width : width),
            y: anchor.y + (dy < 0 ? -height : height)
        )
    }

    /// Resize an existing rectangle to `ratio`, anchored at its top-left corner
    /// and clamped to `bounds` without flipping.
    static func fit(_ rect: CGRect, ratio: CGFloat, within bounds: CGRect) -> CGRect {
        guard ratio > 0, rect.width >= 1, rect.height >= 1 else { return rect }
        var width = rect.width
        var height = width / ratio
        if height < SelectionBorderView.minimumSide {
            height = SelectionBorderView.minimumSide
            width = height * ratio
        }
        if rect.minX + width > bounds.maxX {
            width = max(SelectionBorderView.minimumSide, bounds.maxX - rect.minX)
            height = width / ratio
        }
        if rect.minY + height > bounds.maxY {
            height = max(SelectionBorderView.minimumSide, bounds.maxY - rect.minY)
            width = height * ratio
        }
        width = min(width, bounds.width)
        height = min(height, bounds.height)
        return CGRect(
            x: rect.minX,
            y: rect.minY,
            width: max(SelectionBorderView.minimumSide, width),
            height: max(SelectionBorderView.minimumSide, height)
        )
    }
}

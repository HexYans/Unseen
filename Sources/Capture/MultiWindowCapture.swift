import AppKit
import CoreGraphics

/// A click-to-select set of windows, captured one by one and composited back
/// into a single image at the windows' real screen positions.
///
/// Composition is deliberately independent of ScreenCaptureKit: it takes already
/// captured images plus their AppKit (bottom-left, global) frames. That keeps
/// the coordinate mathematics testable, and means a future single-shot
/// `SCScreenshotManager` call could feed the same function.
enum MultiWindowComposer {
    struct Piece {
        let image: CGImage
        /// AppKit global frame, origin bottom-left.
        let frame: CGRect
    }

    /// Outer bounding rectangle of every frame, in the same coordinate space.
    /// Returns `nil` for an empty list or non-finite frames.
    static func boundingRect(of frames: [CGRect]) -> CGRect? {
        guard var union = frames.first, union.isNull == false, union.isInfinite == false else {
            return nil
        }
        for frame in frames.dropFirst() {
            guard frame.isNull == false, frame.isInfinite == false else { continue }
            union = union.union(frame)
        }
        guard union.width >= 1, union.height >= 1 else { return nil }
        return union
    }

    /// Composite every piece into one bitmap.
    ///
    /// Pieces are drawn in array order, so a later (more recently clicked)
    /// window lands on top of an earlier one where they overlap. The output is
    /// sized by the **point** union × `scale`; each piece is stretched to its
    /// frame × scale, which keeps geometry correct if two displays have
    /// different backing scales.
    static func compose(pieces: [Piece], scale: CGFloat) -> CGImage? {
        guard !pieces.isEmpty,
              let union = boundingRect(of: pieces.map(\.frame)) else { return nil }

        let safeScale = min(max(scale, 1), 4)
        let width = max(1, Int((union.width * safeScale).rounded()))
        let height = max(1, Int((union.height * safeScale).rounded()))
        guard width <= 32_768, height <= 32_768 else { return nil }

        // Keep the capture's own RGB space when possible; mixing Display P3
        // windows into a forced sRGB bitmap would shift their colours.
        let space = pieces.first?.image.colorSpace?.model == .rgb
            ? pieces.first!.image.colorSpace!
            : CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .none

        for piece in pieces {
            let image = piece.image
            guard image.width > 0, image.height > 0 else { continue }

            // Top-left offset from the union's top-left corner, in pixels.
            let left = (piece.frame.minX - union.minX) * safeScale
            let top = (union.maxY - piece.frame.maxY) * safeScale

            // A bottom-left CGContext draws an image's first row at the rect's
            // maxY, so placing the rect below `height - top` makes the image
            // start at that top-left offset.
            let pieceWidth = max(1, (piece.frame.width * safeScale).rounded())
            let pieceHeight = max(1, (piece.frame.height * safeScale).rounded())
            let rect = CGRect(
                x: left.rounded(),
                y: (CGFloat(height) - top - pieceHeight).rounded(),
                width: pieceWidth,
                height: pieceHeight
            )
            context.draw(image, in: rect)
        }

        return context.makeImage()
    }
}

/// Where the initial selection goes for the "preset size" mode.
///
/// Like every other rectangle in the capture pipeline these are AppKit points
/// (bottom-left origin), clamped so a preset larger than the display still
/// produces a valid selection instead of a negative origin.
enum PresetSelection {
    static let minimumSide: CGFloat = 40

    /// Centred `size` inside `screenFrame`, clamped to the screen and never
    /// below the 40 pt selection minimum.
    static func rect(for size: CGSize, on screenFrame: CGRect) -> CGRect {
        guard screenFrame.width >= 1, screenFrame.height >= 1 else {
            return CGRect(x: 0, y: 0, width: minimumSide, height: minimumSide)
        }

        let maxWidth = max(minimumSide, screenFrame.width)
        let maxHeight = max(minimumSide, screenFrame.height)
        let width = min(max(size.width.rounded(), minimumSide), maxWidth)
        let height = min(max(size.height.rounded(), minimumSide), maxHeight)

        let x = screenFrame.minX + ((screenFrame.width - width) / 2).rounded()
        let y = screenFrame.minY + ((screenFrame.height - height) / 2).rounded()
        return CGRect(x: x, y: y, width: width, height: height)
            .intersection(screenFrame)
            .integral
    }
}

/// Screen placement for the scroll-capture HUD.
///
/// The HUD must never sit inside the captured rectangle: the capture excludes
/// this app's own windows, but a fully transparent hole in the long image is
/// still worse than a panel parked outside the region.
enum ScrollPanelPlacement {
    static func origin(
        panelSize: CGSize,
        region: CGRect,
        screenFrame: CGRect,
        gap: CGFloat = 12,
        margin: CGFloat = 10
    ) -> CGPoint {
        func clamp(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: min(
                    max(point.x, screenFrame.minX + margin),
                    max(screenFrame.minX + margin, screenFrame.maxX - panelSize.width - margin)
                ),
                y: min(
                    max(point.y, screenFrame.minY + margin),
                    max(screenFrame.minY + margin, screenFrame.maxY - panelSize.height - margin)
                )
            )
        }

        // Above the region first: it keeps the panel visually attached to the
        // captured area without covering it.
        if region.maxY + gap + panelSize.height <= screenFrame.maxY {
            return clamp(CGPoint(
                x: region.midX - panelSize.width / 2,
                y: region.maxY + gap
            ))
        }
        if region.minY - gap - panelSize.height >= screenFrame.minY {
            return clamp(CGPoint(
                x: region.midX - panelSize.width / 2,
                y: region.minY - gap - panelSize.height
            ))
        }
        if region.maxX + gap + panelSize.width <= screenFrame.maxX {
            return clamp(CGPoint(
                x: region.maxX + gap,
                y: region.midY - panelSize.height / 2
            ))
        }
        if region.minX - gap - panelSize.width >= screenFrame.minX {
            return clamp(CGPoint(
                x: region.minX - gap - panelSize.width,
                y: region.midY - panelSize.height / 2
            ))
        }

        // Region all but fills the screen: top-left is the least useful content
        // area for reading, so the panel goes there.
        return clamp(CGPoint(
            x: screenFrame.minX + margin,
            y: screenFrame.maxY - panelSize.height - margin
        ))
    }
}

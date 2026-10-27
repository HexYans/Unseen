import AppKit
import CoreGraphics

/// The "display stand" for a screenshot: whitespace, rounded corners and a real
/// drop shadow, drawn entirely in code.
///
/// iShot ships photographs of phone and laptop shells. Those are copyrighted
/// assets we cannot ship, so this is the same idea reduced to its essence: the
/// screenshot is presented on a background rather than pasted flat. No external
/// images are read and no machine-specific hardware is implied.
///
/// All distances are **pixels** of the image handed to the renderer. Callers
/// that start from a Retina capture (2 px per point) multiply the slider values
/// by the capture's scale first — see `scaled(by:)`.
struct BeautifyOptions {
    /// Background behind the screenshot.
    enum Background {
        case solid(NSColor)
        case gradient(NSColor, NSColor)
        case transparent
    }

    /// Empty margin around the screenshot, in image pixels.
    var padding: CGFloat = 48
    /// Screenshot corner radius, in image pixels. Clamped to half the shorter
    /// side while rendering.
    var cornerRadius: CGFloat = 16
    /// Blur radius of the drop shadow, in image pixels.
    var shadowRadius: CGFloat = 24
    /// Colour behind the screenshot.
    ///
    /// The default gradient is deliberately quiet enough to read as a backdrop
    /// and not compete with the screenshot itself.
    var background: Background = .gradient(
        NSColor(srgbRed: 0.36, green: 0.40, blue: 0.95, alpha: 1),
        NSColor(srgbRed: 0.93, green: 0.45, blue: 0.62, alpha: 1)
    )
    /// Black alpha of the shadow. 0 disables it.
    var shadowOpacity: Double = 0.28

    init(
        padding: CGFloat = 48,
        cornerRadius: CGFloat = 16,
        shadowRadius: CGFloat = 24,
        background: Background = .gradient(
            NSColor(srgbRed: 0.36, green: 0.40, blue: 0.95, alpha: 1),
            NSColor(srgbRed: 0.93, green: 0.45, blue: 0.62, alpha: 1)
        ),
        shadowOpacity: Double = 0.28
    ) {
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadowRadius = shadowRadius
        self.background = background
        self.shadowOpacity = shadowOpacity
    }

    /// Convert point-space slider values to the image's pixel space, so a 2×
    /// capture gets the same *visual* 48 pt margin as a 1× capture.
    func scaled(by scale: CGFloat) -> BeautifyOptions {
        let safeScale = max(scale, 0.01)
        var copy = self
        copy.padding *= safeScale
        copy.cornerRadius *= safeScale
        copy.shadowRadius *= safeScale
        return copy
    }
}

/// Built-in background choices for the preview window. The colours are plain
/// values, not downloaded artwork.
enum BeautifyBackgroundPreset: Int, CaseIterable, Identifiable {
    case sunset
    case ocean
    case mint
    case white
    case paper
    case night
    case transparent

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .sunset: "渐变 · 落日"
        case .ocean: "渐变 · 海面"
        case .mint: "渐变 · 薄荷"
        case .white: "纯白"
        case .paper: "浅灰"
        case .night: "深色"
        case .transparent: "透明"
        }
    }

    var background: BeautifyOptions.Background {
        switch self {
        case .sunset:
            .gradient(
                NSColor(srgbRed: 0.36, green: 0.40, blue: 0.95, alpha: 1),
                NSColor(srgbRed: 0.93, green: 0.45, blue: 0.62, alpha: 1)
            )
        case .ocean:
            .gradient(
                NSColor(srgbRed: 0.06, green: 0.55, blue: 0.78, alpha: 1),
                NSColor(srgbRed: 0.10, green: 0.20, blue: 0.55, alpha: 1)
            )
        case .mint:
            .gradient(
                NSColor(srgbRed: 0.42, green: 0.91, blue: 0.72, alpha: 1),
                NSColor(srgbRed: 0.20, green: 0.45, blue: 0.92, alpha: 1)
            )
        case .white:
            .solid(NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        case .paper:
            .solid(NSColor(srgbRed: 0.95, green: 0.95, blue: 0.93, alpha: 1))
        case .night:
            .solid(NSColor(srgbRed: 0.10, green: 0.11, blue: 0.14, alpha: 1))
        case .transparent:
            .transparent
        }
    }
}

/// Pure, deterministic compositor. The self test feeds it a known bitmap and
/// asserts the exact output size and sampled pixels.
enum BeautifyRenderer {
    /// Output size in pixels.
    ///
    /// `output = image + 2 × padding`. The shadow is drawn **inside** the
    /// padding, not into an extra band: the default padding (48) is twice the
    /// default blur radius (24), which is enough for the soft edge to fade out
    /// before it reaches the output boundary. Keeping the margin out of the
    /// size formula makes "留白 48" mean exactly 48 px on every side, and the
    /// preview's size readout predict the exported file exactly.
    ///
    /// If a caller sets `shadowRadius > padding / 2`, the outer part of the
    /// shadow is clipped instead of silently enlarging the canvas; that is the
    /// deliberate trade-off for a stable, predictable size.
    static func outputSize(for image: CGImage, options: BeautifyOptions) -> CGSize {
        let padding = max(0, options.padding.rounded())
        return CGSize(
            width: CGFloat(image.width) + padding * 2,
            height: CGFloat(image.height) + padding * 2
        )
    }

    /// Compose `image` on a background with rounded corners and a drop shadow.
    ///
    /// Returns the original image if Core Graphics cannot allocate the bitmap,
    /// so callers never see a crash or an empty result from an extreme size.
    static func render(_ image: CGImage, options: BeautifyOptions) -> CGImage {
        let padding = max(0, options.padding.rounded())
        let width = image.width + Int(padding * 2)
        let height = image.height + Int(padding * 2)
        guard width > 0, height > 0, width <= 32_768, height <= 32_768 else {
            return image
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return image
        }

        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.interpolationQuality = .high

        drawBackground(
            options.background,
            in: context,
            size: CGSize(width: CGFloat(width), height: CGFloat(height)),
            colorSpace: colorSpace
        )

        let imageRect = CGRect(
            x: padding,
            y: padding,
            width: CGFloat(image.width),
            height: CGFloat(image.height)
        )
        let radius = max(
            0,
            min(options.cornerRadius, min(imageRect.width, imageRect.height) / 2)
        )
        let roundedPath = CGPath(
            roundedRect: imageRect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )

        drawShadow(
            around: roundedPath,
            options: options,
            in: context,
            colorSpace: colorSpace
        )

        context.saveGState()
        context.addPath(roundedPath)
        context.clip()
        context.draw(image, in: imageRect)
        context.restoreGState()

        return context.makeImage() ?? image
    }

    // MARK: - Internals

    private static func drawBackground(
        _ background: BeautifyOptions.Background,
        in context: CGContext,
        size: CGSize,
        colorSpace: CGColorSpace
    ) {
        switch background {
        case .solid(let color):
            context.setFillColor(color.cgColor)
            context.fill(CGRect(origin: .zero, size: size))

        case .gradient(let start, let end):
            let colors = [start.cgColor, end.cgColor] as CFArray
            guard let gradient = CGGradient(
                colorsSpace: colorSpace,
                colors: colors,
                locations: [0, 1]
            ) else { return }
            // Core Graphics is bottom-left; the gradient is authored
            // top-left → bottom-right as the user sees it.
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: size.height),
                end: CGPoint(x: size.width, y: 0),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )

        case .transparent:
            break
        }
    }

    private static func drawShadow(
        around path: CGPath,
        options: BeautifyOptions,
        in context: CGContext,
        colorSpace: CGColorSpace
    ) {
        let opacity = min(max(options.shadowOpacity, 0), 1)
        guard options.shadowRadius > 0, opacity > 0 else { return }

        context.saveGState()
        // A slight downward offset reads as a real object sitting on the
        // background instead of a halo painted around it.
        context.setShadow(
            offset: CGSize(width: 0, height: -(options.shadowRadius * 0.25)),
            blur: options.shadowRadius,
            color: CGColor(
                colorSpace: colorSpace,
                components: [0, 0, 0, CGFloat(opacity)]
            )
        )
        context.addPath(path)
        context.setFillColor(CGColor(colorSpace: colorSpace, components: [0, 0, 0, 1]) ?? NSColor.black.cgColor)
        context.fillPath()
        context.restoreGState()
    }
}

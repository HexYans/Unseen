import AppKit
import CoreGraphics

/// The corner radius + drop shadow applied to the **exported** screenshot.
///
/// This is iShot's `needFilletOfnotSingleWindow` / `sizeOfImageFillet` and
/// `needShadowOfnotSingleWindow` / `sizeOfShadow` pair, reimplemented from the
/// disassembly documented in `Docs/iShot-capability-map.md` §7:
///
/// * the fillet is a per-image corner radius in points;
/// * the shadow's `size` is a single number that both pads the canvas and
///   drives the blur (`blur = size × 1.1`, offset 0, black at 30 %).
///
/// It is deliberately separate from 套壳 / 美化 (`BeautifyRenderer`): that one
/// adds a *display stand* (whitespace + background), this one changes the
/// screenshot itself and never appears in the capture overlay's preview or in
/// the selection border. Delivery applies it; the live overlay does not.
struct ScreenshotDecoration: Equatable {
    /// Corner radius in **points**. 0 disables the fillet.
    var cornerRadius: CGFloat = 0
    /// Shadow size in **points**. 0 disables the shadow.
    var shadowSize: CGFloat = 0

    static let none = ScreenshotDecoration()

    var isActive: Bool { cornerRadius > 0 || shadowSize > 0 }
}

/// The window corner the **captured pixels themselves** carry.
///
/// The overlay shades the selection's four corners with `DimmingView`'s radius
/// (P6), but a shade is only a preview: the user asked for the picture to come
/// out with the corner, not just the mask. Delivery clips the same radius out of
/// the image, leaving transparent pixels — no fill — so a copied long shot and a
/// saved region shot both carry Apple's window corner.
///
/// It is deliberately separate from `ScreenshotDecoration`: that one is the
/// user's optional export fillet + drop shadow (it also pads the canvas); this
/// one is always on for region and scrolling captures and never changes the
/// image's size.
enum CaptureCorner {
    /// Same number the veil uses, so the preview and the file agree.
    static let radius: CGFloat = DimmingView.defaultCornerRadius

    /// Clip `image` to a rounded rectangle with **transparent** corners.
    ///
    /// - Parameter scale: pixels per point of the display the shot came from, so
    ///   a 12 pt corner is 24 px on Retina and the shape is the same size in
    ///   points in both.
    /// - Returns: the original image when there is nothing to do or Core
    ///   Graphics cannot allocate the bitmap.
    static func clipped(
        _ image: CGImage,
        radius: CGFloat = CaptureCorner.radius,
        scale: CGFloat
    ) -> CGImage {
        let pixelRadius = max(0, (radius * max(scale, 1)).rounded())
        guard pixelRadius >= 1, image.width > 2, image.height > 2 else { return image }
        let width = image.width
        let height = image.height
        // Keep the capture's own RGB space (many Macs capture in Display P3);
        // forcing sRGB here would shift every colour in the shot.
        let space = image.colorSpace?.model == .rgb
            ? image.colorSpace!
            : CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }

        let rect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        let limited = min(pixelRadius, min(rect.width, rect.height) / 2)
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.interpolationQuality = .high
        context.addPath(
            CGPath(
                roundedRect: rect,
                cornerWidth: limited,
                cornerHeight: limited,
                transform: nil
            )
        )
        context.clip()
        context.draw(image, in: rect)
        return context.makeImage() ?? image
    }
}

/// Pure Core Graphics renderer, so the self test can assert exact sizes and
/// pixels without a window server.
enum ScreenshotDecorator {
    /// iShot: `CGContextSetShadowWithColor(offset: 0, blur: size × 1.1)`. [0x10003f918]
    static let shadowBlurFactor: CGFloat = 1.1
    /// iShot: `[NSColor.shadowColor colorWithAlphaComponent:0.3]`. [0x10003f874]
    static let shadowOpacity: CGFloat = 0.30

    /// Padding added on each side when a shadow is on. iShot's
    /// `+[NSImage addShadow:withSize:]` grows the canvas by `2 × size` and
    /// draws the image at `(size, size)`, so the shadow has room to fade.
    static func padding(for decoration: ScreenshotDecoration, scale: CGFloat) -> CGFloat {
        guard decoration.shadowSize > 0 else { return 0 }
        return (decoration.shadowSize * max(scale, 1)).rounded()
    }

    /// Output size in pixels: the fillet never changes it, the shadow pads it.
    static func outputSize(
        for image: CGImage,
        scale: CGFloat,
        decoration: ScreenshotDecoration
    ) -> CGSize {
        let pad = padding(for: decoration, scale: scale)
        return CGSize(width: CGFloat(image.width) + pad * 2, height: CGFloat(image.height) + pad * 2)
    }

    /// Round the corners, then lay the shadow underneath.
    ///
    /// - Parameter background: fills the padded canvas before the shadow so a
    ///   JPEG export has a real colour behind it (JPEG has no alpha, and the
    ///   encoder would otherwise composite the corners onto black).
    /// - Returns: the original image when nothing is enabled or Core Graphics
    ///   cannot allocate the bitmap.
    static func render(
        _ image: CGImage,
        scale: CGFloat,
        decoration: ScreenshotDecoration,
        background: NSColor? = nil
    ) -> CGImage {
        guard decoration.isActive else { return image }
        let safeScale = max(scale, 1)
        let pad = padding(for: decoration, scale: safeScale)
        let width = image.width + Int(pad * 2)
        let height = image.height + Int(pad * 2)
        guard width > 0, height > 0, width <= 32_768, height <= 32_768 else { return image }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return image }

        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.interpolationQuality = .high

        let canvas = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        if let background {
            context.setFillColor(background.withAlphaComponent(1).cgColor)
            context.fill(canvas)
        }

        let imageRect = CGRect(
            x: pad,
            y: pad,
            width: CGFloat(image.width),
            height: CGFloat(image.height)
        )
        // A radius larger than half the shorter side is not a radius any more.
        let radius = max(
            0,
            min(decoration.cornerRadius * safeScale, min(imageRect.width, imageRect.height) / 2)
        )
        let clipPath = CGPath(
            roundedRect: imageRect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )

        if decoration.shadowSize > 0 {
            context.saveGState()
            context.setShadow(
                offset: .zero,
                blur: decoration.shadowSize * safeScale * shadowBlurFactor,
                color: CGColor(
                    colorSpace: colorSpace,
                    components: [0, 0, 0, shadowOpacity]
                )
            )
            context.addPath(clipPath)
            context.setFillColor(
                CGColor(colorSpace: colorSpace, components: [0, 0, 0, 1]) ?? NSColor.black.cgColor
            )
            context.fillPath()
            context.restoreGState()
        }

        context.saveGState()
        context.addPath(clipPath)
        context.clip()
        context.draw(image, in: imageRect)
        context.restoreGState()

        return context.makeImage() ?? image
    }
}

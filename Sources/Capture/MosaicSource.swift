import AppKit
import CoreGraphics

/// The pixels a `mosaic` annotation samples from.
///
/// Two mappings exist because the same annotation is rendered in two spaces:
///
/// * the **overlay** draws in screen points and samples the full-screen
///   snapshot taken when the overlay opened;
/// * the **flattened export** draws in captured pixels and samples the
///   captured image itself.
///
/// In both cases `pixelRect` translates an annotation rectangle (normalised to
/// the selection, 0…1, top-left origin) into a top-left-origin rectangle in
/// `image`'s pixel space. Block size is always expressed in *source pixels*, so
/// a 10 pt block looks the same on a 1× and a 2× screen.
struct MosaicSource {
    /// Visible block size in points. The capture side multiplies this by the
    /// backing scale, which yields ~20 px blocks on Retina.
    static let blockPoints: CGFloat = 10

    let image: CGImage
    let blockSizePixels: CGFloat
    let pixelRect: (CGRect) -> CGRect?

    /// Export mapping: normalised rectangle → image pixels, 1:1.
    static func flattening(image: CGImage, scale: CGFloat) -> MosaicSource {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        return MosaicSource(
            image: image,
            blockSizePixels: max(2, (blockPoints * max(scale, 1)).rounded()),
            pixelRect: { normalized in
                let rect = CGRect(
                    x: normalized.minX * width,
                    y: normalized.minY * height,
                    width: normalized.width * width,
                    height: normalized.height * height
                ).integral.intersection(bounds)
                return rect.isNull || rect.width < 1 || rect.height < 1 ? nil : rect
            }
        )
    }

    /// Overlay mapping: the snapshot covers `viewSize` points; `selection` is
    /// in the overlay's bottom-left point space and `imageScale` is pixels per
    /// point on both axes.
    static func overlay(
        image: CGImage,
        viewSize: CGSize,
        imageScale: CGSize,
        selection: CGRect
    ) -> MosaicSource {
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        return MosaicSource(
            image: image,
            blockSizePixels: max(2, (blockPoints * max(imageScale.width, 1)).rounded()),
            pixelRect: { normalized in
                guard selection.width >= 1, selection.height >= 1,
                      viewSize.width > 0, viewSize.height > 0 else { return nil }

                // Normalised (top-left inside the selection) → overlay points
                // (bottom-left) → snapshot pixels (top-left).
                let viewMinX = selection.minX + normalized.minX * selection.width
                let viewMaxY = selection.maxY - normalized.minY * selection.height
                let viewWidth = normalized.width * selection.width
                let viewHeight = normalized.height * selection.height

                let rect = CGRect(
                    x: viewMinX * imageScale.width,
                    y: (viewSize.height - viewMaxY) * imageScale.height,
                    width: viewWidth * imageScale.width,
                    height: viewHeight * imageScale.height
                ).integral.intersection(bounds)
                return rect.isNull || rect.width < 1 || rect.height < 1 ? nil : rect
            }
        )
    }
}

/// Block-average pixelation without Core Image.
///
/// It averages every block of source pixels explicitly, then upscales the small
/// image with nearest-neighbour. A CGContext's "high quality" downscale is not
/// usable here: its filter support is wider than one block, which smears all
/// blocks toward the same mean and produces a flat rectangle instead of visible
/// mosaic tiles. Explicit averaging is both correct and assertable pixel by
/// pixel by the self test.
enum Pixelator {
    static func pixelate(_ image: CGImage, blockSize: CGFloat) -> CGImage? {
        let block = max(1, Int(blockSize.rounded()))
        guard block > 1, image.width > block, image.height > block else { return image }

        let colorSpace = image.colorSpace?.model == .rgb
            ? image.colorSpace!
            : CGColorSpaceCreateDeviceRGB()

        let width = image.width
        let height = image.height

        // Normalise the source to premultiplied RGBA8 so the averaging loop
        // does not care about the capture's native layout.
        var source = [UInt8](repeating: 0, count: width * height * 4)
        let normalised = source.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard normalised else { return nil }

        let smallWidth = max(1, (width + block - 1) / block)
        let smallHeight = max(1, (height + block - 1) / block)
        var small = [UInt8](repeating: 0, count: smallWidth * smallHeight * 4)

        for smallY in 0..<smallHeight {
            let fromY = smallY * block
            let toY = min(height, fromY + block)
            for smallX in 0..<smallWidth {
                let fromX = smallX * block
                let toX = min(width, fromX + block)

                var red = 0
                var green = 0
                var blue = 0
                var alpha = 0
                var count = 0
                for y in fromY..<toY {
                    let row = y * width
                    for x in fromX..<toX {
                        let index = (row + x) * 4
                        red += Int(source[index])
                        green += Int(source[index + 1])
                        blue += Int(source[index + 2])
                        alpha += Int(source[index + 3])
                        count += 1
                    }
                }
                guard count > 0 else { continue }
                let index = (smallY * smallWidth + smallX) * 4
                small[index] = UInt8(red / count)
                small[index + 1] = UInt8(green / count)
                small[index + 2] = UInt8(blue / count)
                small[index + 3] = UInt8(alpha / count)
            }
        }

        guard let provider = CGDataProvider(data: Data(small) as CFData) else { return nil }
        guard let reduced = CGImage(
            width: smallWidth,
            height: smallHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: smallWidth * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }

        guard let output = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        output.interpolationQuality = .none
        output.draw(
            reduced,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        return output.makeImage()
    }
}

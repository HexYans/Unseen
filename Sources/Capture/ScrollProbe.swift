import CoreGraphics
import Foundation

/// A synthetic reproduction of the reported failure, runnable from the app
/// binary without a UI:
///
///     UNSEEN_STITCH_PROBE=1 /Applications/Unseen.app/Contents/MacOS/Unseen
///
/// It builds the shape the user described — a **window** selection with a title
/// bar on top, a **static sidebar on the left** and scrolling content on the
/// right — and feeds four frames through the real `ScrollAutoStitcher`, printing
/// what it decided for each one. That turns "长截图没变化" into a number instead
/// of a guess.
enum ScrollProbe {
    struct Frame {
        let offset: Int
        let image: CGImage
    }

    static func run() {
        let width = 1200
        let height = 900
        let titleBar = 56
        let sidebarWidth = 320
        let step = 140

        guard let page = makePage(width: width, height: 4000) else {
            print("probe: could not build the page")
            return
        }
        var stitcher = ScrollAutoStitcher()
        for index in 0..<5 {
            let offset = index * step
            guard let frame = makeFrame(
                from: page,
                offset: offset,
                width: width,
                height: height,
                titleBar: titleBar,
                sidebarWidth: sidebarWidth
            ) else {
                print("probe: could not build frame \(index)")
                return
            }
            let outcome = stitcher.consume(frame)
            print(
                "probe: frame \(index) offset=\(offset) outcome=\(outcome) "
                    + "stitchH=\(stitcher.height) grew=\(stitcher.grew) "
                    + "frames=\(stitcher.frameCount) overlap=\(stitcher.lastOverlap)"
            )
        }
        print("probe: final stitch height=\(stitcher.height) (expected \(height + 4 * step))")
    }

    /// A tall page: left 30 % is a flat sidebar strip that never moves, the rest
    /// is striped content with per-row detail.
    private static func makePage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let sidebarWidth = width * 3 / 10
        context.setFillColor(CGColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: sidebarWidth, height: height))
        for y in 0..<height {
            // Sidebar rows: a few text-like bars, repeated, so the strip looks
            // like a list rather than a flat colour.
            if y % 40 < 12 {
                context.setFillColor(CGColor(srgbRed: 0.72, green: 0.74, blue: 0.78, alpha: 1))
                context.fill(CGRect(
                    x: 24,
                    y: height - y - 1,
                    width: sidebarWidth - 60,
                    height: 6
                ))
            }
            // Content: unique per row, with a hard edge every 8 rows.
            let edge = y % 8 == 0
            context.setFillColor(CGColor(
                srgbRed: CGFloat((y * 5) % 256) / 255,
                green: CGFloat((y * 11) % 256) / 255,
                blue: edge ? 1 : CGFloat((y * 23) % 256) / 255,
                alpha: 1
            ))
            context.fill(CGRect(
                x: sidebarWidth,
                y: height - y - 1,
                width: width - sidebarWidth,
                height: 1
            ))
        }
        return context.makeImage()
    }

    /// One captured "screen": a fixed title bar, the page slice under it, and the
    /// sidebar redrawn at its fixed place.
    private static func makeFrame(
        from page: CGImage,
        offset: Int,
        width: Int,
        height: Int,
        titleBar: Int,
        sidebarWidth: Int
    ) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        let bodyHeight = height - titleBar
        let slice = page.cropping(to: CGRect(
            x: 0, y: offset, width: width, height: bodyHeight
        ))
        if let slice {
            context.draw(slice, in: CGRect(x: 0, y: 0, width: width, height: bodyHeight))
        }
        // Title bar: identical in every frame.
        context.setFillColor(CGColor(srgbRed: 0.16, green: 0.17, blue: 0.22, alpha: 1))
        context.fill(CGRect(x: 0, y: height - titleBar, width: width, height: titleBar))
        return context.makeImage()
    }
}

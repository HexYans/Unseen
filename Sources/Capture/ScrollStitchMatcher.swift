import CoreGraphics
import Foundation

/// The overlap test, ported from iShot's scroll-capture matcher.
///
/// iShot decides "these two frames overlap by N rows" with two functions, read
/// out of the shipped binary with REA (`+[Global sameArr:to:]` and
/// `+[Global sameArrColumn:to:]`):
///
/// * **row identity** — two rows are the same when, walking both byte buffers
///   four bytes at a time (RGBA), the **luminance** `0.11·R + 0.59·G + 0.30·B`
///   of every pixel differs by less than **6**. It skips a fixed margin at both
///   ends of the row, so rounded window corners and the scrollbar cannot veto a
///   match.
/// * **row signature** — the cheap pre-check compares per-column integer values
///   with a tolerance of **3**, and only then does the pixel pass run.
///
/// That is a far more forgiving test than "what fraction of sampled pixels
/// differ", and it is the reason iShot's long capture simply works on ordinary
/// pages: text antialiasing, a hover highlight, a blinking caret and a 1-pixel
/// subpixel scroll all still read as "same row", while a real move never does.
///
/// This file is a from-scratch implementation of that behaviour on the app's own
/// raster type; no iShot code is copied, only the two thresholds and the shape
/// of the comparison.
enum ScrollStitchMatcher {
    /// Per-pixel luminance tolerance, iShot's constant.
    static let luminanceTolerance = 6.0
    /// Per-column signature tolerance, iShot's constant.
    static let signatureTolerance = 3
    /// Smallest overlap worth calling a match.
    static let minimumOverlap = 8
    /// Pixels skipped at each end of a row, so window corners and scrollbars
    /// cannot decide the match. iShot's buffer margin is 80 bytes ≈ 20 pixels.
    static let edgeMargin = 20

    /// Luminance of one sampled pixel, 0…255.
    static func luminance(_ rgb: (Int, Int, Int)) -> Double {
        0.11 * Double(rgb.0) + 0.59 * Double(rgb.1) + 0.30 * Double(rgb.2)
    }

    /// One row's signature: the mean luminance of the sampled columns.
    ///
    /// iShot keeps a whole array of per-column values; a mean is the same test
    /// with one number, and the pixel pass below is what actually decides.
    static func rowSignature(_ raster: ScrollStitcher.SampledRaster, y: Int) -> Int {
        let columns = raster.columnCount
        guard columns > 0 else { return 0 }
        var total = 0.0
        var counted = 0
        for column in 0..<columns {
            guard isInsideMargin(column: column, of: raster) else { continue }
            total += luminance(raster.rgb(column: column, y: y))
            counted += 1
        }
        guard counted > 0 else { return 0 }
        return Int((total / Double(counted)).rounded())
    }

    private static func isInsideMargin(
        column: Int,
        of raster: ScrollStitcher.SampledRaster
    ) -> Bool {
        // The sampled columns are spread across the full width; the margin is a
        // share of the width, so it maps to a share of the column indices.
        let share = Double(edgeMargin) / Double(max(1, raster.width))
        let first = Int((Double(raster.columnCount) * share).rounded(.up))
        let last = raster.columnCount - first
        return column >= first && column < last
    }

    /// True when the two rows are "the same row" by iShot's rule.
    static func rowsMatch(
        _ a: ScrollStitcher.SampledRaster,
        _ aY: Int,
        _ b: ScrollStitcher.SampledRaster,
        _ bY: Int
    ) -> Bool {
        guard aY >= 0, aY < a.height, bY >= 0, bY < b.height else { return false }
        let columns = min(a.columnCount, b.columnCount)
        guard columns > 0 else { return false }
        var compared = 0
        for column in 0..<columns {
            guard isInsideMargin(column: column, of: a) else { continue }
            compared += 1
            let left = luminance(a.rgb(column: column, y: aY))
            let right = luminance(b.rgb(column: column, y: bY))
            if abs(left - right) > luminanceTolerance { return false }
        }
        return compared > 0
    }

    /// How many rows the two frames share, iShot's way.
    ///
    /// `next` is the freshly captured frame; `existing` is the stitch so far.
    /// The answer is the largest overlap whose every row passes the signature
    /// pre-check and then the pixel test — searched from the largest candidate
    /// down, so the first hit is the most conservative (least appended).
    ///
    /// Returns nil when nothing matches, which the caller treats as "no
    /// scroll" — the same conclusion iShot draws.
    static func overlap(
        existing: ScrollStitcher.SampledRaster,
        next: ScrollStitcher.SampledRaster
    ) -> Int? {
        let height = min(existing.height, next.height)
        guard height >= minimumOverlap else { return nil }
        let existingSignature = (0..<existing.height).map { rowSignature(existing, y: $0) }
        let nextSignature = (0..<next.height).map { rowSignature(next, y: $0) }

        var overlap = height
        while overlap >= minimumOverlap {
            let existingStart = existing.height - overlap
            guard existingStart >= 0 else { break }
            // Pre-check on signatures, then the pixel pass on the same rows.
            var signatureOK = true
            for offset in 0..<overlap {
                let delta = abs(nextSignature[offset] - existingSignature[existingStart + offset])
                if delta > signatureTolerance {
                    signatureOK = false
                    break
                }
            }
            if signatureOK {
                var pixelsOK = true
                for offset in 0..<overlap {
                    if !rowsMatch(
                        existing, existingStart + offset,
                        next, offset
                    ) {
                        pixelsOK = false
                        break
                    }
                }
                if pixelsOK { return overlap }
            }
            overlap -= 1
        }
        return nil
    }
}

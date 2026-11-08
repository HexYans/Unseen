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

    /// One row's signature: the mean luminance of the compared columns.
    ///
    /// iShot keeps a whole array of per-column values; a mean is the same test
    /// with one number, and the pixel pass below is what actually decides.
    /// How many buckets a row's signature is split into. One mean luminance is
    /// far too weak — a blank line, a paragraph and a heading all average to
    /// "paper" — so the row is described by a handful of horizontal slices, and
    /// every slice has to agree. Cheap enough to run on every candidate offset.
    static let signatureBuckets = 8

    static func rowSignature(
        _ raster: ScrollStitcher.SampledRaster,
        y: Int,
        margins: (left: Int, right: Int) = (0, 0)
    ) -> [Int] {
        let columnCount = raster.columnCount
        guard columnCount > 0 else { return [] }
        var sums = [Double](repeating: 0, count: signatureBuckets)
        var counts = [Int](repeating: 0, count: signatureBuckets)
        for column in 0..<columnCount {
            guard isInsideMargin(column: column, of: raster) else { continue }
            guard column >= margins.left,
                  column < columnCount - margins.right else { continue }
            let bucket = min(signatureBuckets - 1, column * signatureBuckets / columnCount)
            sums[bucket] += luminance(raster.rgb(column: column, y: y))
            counts[bucket] += 1
        }
        return (0..<signatureBuckets).map { bucket in
            guard counts[bucket] > 0 else { return -1 }
            return Int((sums[bucket] / Double(counts[bucket])).rounded())
        }
    }

    /// Signature agreement: every bucket within tolerance, skipping empty ones.
    static func signaturesMatch(_ a: [Int], _ b: [Int]) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        for index in 0..<a.count {
            if a[index] < 0 || b[index] < 0 { continue }
            if abs(a[index] - b[index]) > signatureTolerance { return false }
        }
        return true
    }

    /// Pixels skipped at each end of a row, so a rounded window corner or a
    /// scrollbar cannot decide a match. iShot's buffer margin is 80 bytes ≈ 20 px.
    private static func isInsideMargin(
        column: Int,
        of raster: ScrollStitcher.SampledRaster
    ) -> Bool {
        let share = Double(edgeMargin) / Double(max(1, raster.width))
        let first = Int((Double(raster.columnCount) * share).rounded(.up))
        return column >= first && column < raster.columnCount - first
    }

    /// iShot's left/right **static margins**, in sampled-column indices.
    ///
    /// Read out of `-[MXClipView screenShotsAtScrollScreenshots]`: for every
    /// column it keeps the whole column's luminance vector, compares column `i`
    /// of the previous frame with column `i` of the current one using
    /// `sameArrColumn:to:` (tolerance 3), and walks inward from both edges while
    /// they still match:
    ///
    ///     staticLeft  = leading columns that never changed
    ///     staticRight = trailing columns that never changed
    ///
    /// Those two numbers are then used as a **byte margin** by `sameArr:to:`,
    /// which compares two rows only inside `[staticLeft, width - staticRight)`.
    /// That is the whole trick behind scrolling a window with a fixed sidebar:
    /// the sidebar is the left margin, so row comparison never looks at it, while
    /// the appended picture still keeps the full width.
    static func staticMargins(
        _ a: ScrollStitcher.SampledRaster,
        _ b: ScrollStitcher.SampledRaster
    ) -> (left: Int, right: Int) {
        let height = min(a.height, b.height)
        let columns = min(a.columnCount, b.columnCount)
        guard height >= 2, columns >= 2 else { return (0, 0) }

        func columnMatches(_ column: Int) -> Bool {
            // iShot compares the whole column vector and requires every entry to
            // agree. A live window is not that clean — antialiasing, a caret, a
            // hover highlight — so a few disagreeing rows are tolerated; the
            // margin only has to be *mostly* static to be useful.
            let stride = max(1, height / 96)
            var sampled = 0
            var mismatched = 0
            var y = 0
            while y < height {
                sampled += 1
                let delta = abs(
                    luminance(a.rgb(column: column, y: y))
                        - luminance(b.rgb(column: column, y: y))
                )
                if delta > Double(signatureTolerance) { mismatched += 1 }
                y += stride
            }
            guard sampled > 0 else { return false }
            return Double(mismatched) <= Double(sampled) * 0.05
        }

        var left = 0
        while left < columns, columnMatches(left) { left += 1 }
        var right = 0
        while right < columns - left, columnMatches(columns - right - 1) { right += 1 }
        // A margin that swallows the whole row leaves nothing to compare; iShot
        // guards the same case by refusing to compare when the band is empty.
        guard left + right < columns else { return (0, 0) }
        return (left, right)
    }

    /// True when the two rows are "the same row" by iShot's rule.
    static func rowsMatch(
        _ a: ScrollStitcher.SampledRaster,
        _ aY: Int,
        _ b: ScrollStitcher.SampledRaster,
        _ bY: Int,
        margins: (left: Int, right: Int) = (0, 0)
    ) -> Bool {
        guard aY >= 0, aY < a.height, bY >= 0, bY < b.height else { return false }
        let columns = min(a.columnCount, b.columnCount)
        guard columns > 0 else { return false }
        var compared = 0
        for column in 0..<columns {
            guard isInsideMargin(column: column, of: a) else { continue }
            guard column >= margins.left, column < columns - margins.right else { continue }
            compared += 1
            let left = luminance(a.rgb(column: column, y: aY))
            let right = luminance(b.rgb(column: column, y: bY))
            if abs(left - right) > luminanceTolerance { return false }
        }
        return compared > 0
    }

    /// The overlap, measured inside iShot's static margins.
    ///
    /// Two attempts: the margins taken from the frame pair, then no margins at
    /// all (a page whose columns all changed — a video, a gradient — has no
    /// usable margin, and iShot's own guard refuses to compare in that case).
    static func overlapBest(
        existing: ScrollStitcher.SampledRaster,
        next: ScrollStitcher.SampledRaster,
        previous: ScrollStitcher.SampledRaster?
    ) -> (overlap: Int, band: String)? {
        if let previous {
            let margins = staticMargins(previous, next)
            if margins.left + margins.right < next.columnCount {
                if let overlap = overlap(
                    existing: existing,
                    next: next,
                    margins: margins
                ) {
                    return (overlap, "margins(\(margins.left),\(margins.right))")
                }
            }
        }
        if let overlap = overlap(existing: existing, next: next) {
            return (overlap, "whole")
        }
        return nil
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
        next: ScrollStitcher.SampledRaster,
        margins: (left: Int, right: Int) = (0, 0)
    ) -> Int? {
        let height = min(existing.height, next.height)
        guard height >= minimumOverlap else { return nil }
        let skipTop = 0
        let existingSignature = (0..<existing.height).map {
            rowSignature(existing, y: $0, margins: margins)
        }
        let nextSignature = (0..<next.height).map {
            rowSignature(next, y: $0, margins: margins)
        }

        var overlap = height
        while overlap >= minimumOverlap {
            let existingStart = existing.height - overlap
            guard existingStart >= 0 else { break }
            // Pre-check on signatures, then the pixel pass on the same rows.
            guard overlap - skipTop >= minimumOverlap else {
                overlap -= 1
                continue
            }
            var signatureOK = true
            for offset in skipTop..<overlap {
                if !signaturesMatch(
                    nextSignature[offset],
                    existingSignature[existingStart + offset]
                ) {
                    signatureOK = false
                    break
                }
            }
            if signatureOK {
                var pixelsOK = true
                for offset in skipTop..<overlap {
                    if !rowsMatch(
                        existing, existingStart + offset,
                        next, offset,
                        margins: margins
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

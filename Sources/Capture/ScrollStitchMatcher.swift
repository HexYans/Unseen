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
        columns: [Bool]? = nil
    ) -> [Int] {
        let columnCount = raster.columnCount
        guard columnCount > 0 else { return [] }
        var sums = [Double](repeating: 0, count: signatureBuckets)
        var counts = [Int](repeating: 0, count: signatureBuckets)
        for column in 0..<columnCount {
            guard isInsideMargin(column: column, of: raster) else { continue }
            if let columns, column < columns.count, !columns[column] { continue }
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

    /// Which sampled columns actually **scroll**.
    ///
    /// A window is not one surface: a browser has a tab bar above and often a
    /// sidebar on the left, and a file list has a column of labels that never
    /// moves. Comparing whole rows then never lines up — the sidebar pins the
    /// left third, the content disagrees, and the frame is declared unmatched,
    /// which is why a window with a fixed sidebar did not stitch at all.
    ///
    /// The fix is the one the user described: read the **scroll offset** from the
    /// part that moves, then append the whole row. The sidebar is carried along
    /// with that offset, so the long image keeps a continuous sidebar instead of
    /// being cropped to the content area.
    ///
    /// A column counts as moving when any sampled row differs between the two
    /// frames at the same y. Returns nil when *nothing* moves (a still page) or
    /// when everything does (an ordinary full-width page): both cases are what
    /// the whole-row test already handles correctly.
    static func movingColumns(
        _ a: ScrollStitcher.SampledRaster,
        _ b: ScrollStitcher.SampledRaster
    ) -> [Bool]? {
        let height = min(a.height, b.height)
        let columns = min(a.columnCount, b.columnCount)
        guard height >= 2, columns > 0 else { return nil }
        var moving = [Bool](repeating: false, count: columns)
        var movingCount = 0
        let rowStride = max(1, height / 64)
        for column in 0..<columns {
            var y = 0
            while y < height {
                let left = luminance(a.rgb(column: column, y: y))
                let right = luminance(b.rgb(column: column, y: y))
                if abs(left - right) > luminanceTolerance {
                    moving[column] = true
                    movingCount += 1
                    break
                }
                y += rowStride
            }
        }
        // Nothing moved, or everything did: no useful split.
        guard movingCount > 0, movingCount < columns else { return nil }
        return moving
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
        _ bY: Int,
        columns only: [Bool]? = nil
    ) -> Bool {
        guard aY >= 0, aY < a.height, bY >= 0, bY < b.height else { return false }
        let columns = min(a.columnCount, b.columnCount)
        guard columns > 0 else { return false }
        var compared = 0
        for column in 0..<columns {
            guard isInsideMargin(column: column, of: a) else { continue }
            if let only, column < only.count, !only[column] { continue }
            compared += 1
            let left = luminance(a.rgb(column: column, y: aY))
            let right = luminance(b.rgb(column: column, y: bY))
            if abs(left - right) > luminanceTolerance { return false }
        }
        return compared > 0
    }

    /// The overlap, trying the most informative column band first.
    ///
    /// Order matters. The moving columns are the truest signal; the right-hand
    /// 70 % is the "content is on the right, a sidebar is on the left" fallback
    /// for the frames where the moving-column detection says nothing useful
    /// (a hover highlight that touched the whole window, a gradient); the whole
    /// row is the last resort.
    static func overlapBest(
        existing: ScrollStitcher.SampledRaster,
        next: ScrollStitcher.SampledRaster,
        movingColumns: [Bool]?,
        skipTopRows: Int
    ) -> (overlap: Int, band: String)? {
        if let movingColumns,
           let overlap = overlap(
               existing: existing,
               next: next,
               columns: movingColumns,
               skipTopRows: skipTopRows
           ) {
            return (overlap, "moving")
        }
        // Right-hand 70 %: a static sidebar is nearly always on the left.
        let columnCount = min(existing.columnCount, next.columnCount)
        if columnCount >= 8 {
            let start = columnCount * 3 / 10
            var band = [Bool](repeating: false, count: columnCount)
            for column in start..<columnCount { band[column] = true }
            if let overlap = overlap(
                existing: existing,
                next: next,
                columns: band,
                skipTopRows: skipTopRows
            ) {
                return (overlap, "right70")
            }
        }
        if let overlap = overlap(
            existing: existing,
            next: next,
            columns: nil,
            skipTopRows: skipTopRows
        ) {
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
        columns only: [Bool]? = nil,
        skipTopRows: Int = 0
    ) -> Int? {
        let height = min(existing.height, next.height)
        guard height >= minimumOverlap else { return nil }
        // A window selection starts at the window's top edge, which is a title
        // bar: those rows are identical in every frame and can never take part in
        // a displacement. Skipping them is what lets a clicked window stitch at
        // all — a dragged region normally excludes the bar, which is why this only
        // showed up on the window path.
        let skipTop = min(max(0, skipTopRows), max(0, height - minimumOverlap))
        let existingSignature = (0..<existing.height).map {
            rowSignature(existing, y: $0, columns: only)
        }
        let nextSignature = (0..<next.height).map {
            rowSignature(next, y: $0, columns: only)
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
                        columns: only
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

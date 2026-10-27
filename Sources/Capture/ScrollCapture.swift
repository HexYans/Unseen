import CoreGraphics
import Foundation

/// Vertical stitching for scrolling screenshots.
///
/// The algorithm follows the iShot hint in `Docs/iShot-capability-map.md` §9:
/// the overlap between two frames is found by comparing **sampled pixel
/// columns** row by row, not by matching feature points. Two frames of a
/// scrolled page differ only in how far the content moved, so the bottom `k`
/// rows of the first frame are the top `k` rows of the second one. Trying every
/// plausible `k` and keeping the one with the smallest mean absolute difference
/// recovers that offset without any image-recognition dependency.
///
/// Everything here is a pure function over `CGImage`s so the self test can
/// assert exact offsets and output heights without a window server.
///
/// ## Why the *live* path does not use `overlap(existing:next:)`
///
/// That entry point turns each frame into a full-width RGBA raster and, for the
/// accumulated image, does it **again for the whole stitched image on every
/// sample**. Merging had the same shape: a new `CGContext` the size of the
/// whole result, with the old picture redrawn into it. Both costs grow with the
/// stitched length, which is exactly what made a 10 000-pt page stutter.
///
/// `ScrollStitchStore` keeps the same pixels — the same sampled columns, the
/// same search — but the sampled raster is **appended to**, and the picture is
/// kept as row pieces instead of being re-composed every frame. The full image
/// is only composed when someone asks for it (finish, self test), and the
/// viewfinder gets a small `ScrollPreviewFrame` band composed at display size.
enum ScrollStitcher {
    /// How many pixels of each sampled row take part in the comparison.
    ///
    /// A handful of columns is not enough: pages with repeated text (a table,
    /// a numbered list) can look identical at every offset when the only
    /// distinguishing pixels — a line number, a timestamp — sit outside the
    /// sampled strips. Sampling ~180 points across the full width makes a
    /// wrong offset differ by far more than `maximumDifferentFraction`, which
    /// is what stops the stitcher from skipping rows.
    static let sampleColumns = 180

    /// Rows compared per candidate offset. 24 rows × 180 points is enough to
    /// judge an overlap without touching every pixel.
    static let sampleRows = 24

    /// Rows sampled by the detail test. Twice `sampleRows` because detail
    /// pixels are sparse on a real page — a column lands on a glyph edge only
    /// now and then — and a handful of samples turns the mismatch into noise.
    /// Measured on a real Chrome page: 24 rows found 22 detail pixels in a
    /// 536-row overlap, which was too few to tell the true offset (mismatch
    /// 0.000) from a repeated one (0.264).
    static let detailSampleRows = 48

    /// Per-channel difference (0…255) that still counts as the same pixel.
    /// Antialiasing and sub-pixel scroll blending stay under this.
    static let differenceTolerance = 28

    /// Fraction of differing pixels a candidate may have and still count as
    /// the same content. 1.2 % tolerates a blinking caret or a fading
    /// scrollbar; a shifted row with a different line number is far higher.
    static let maximumDifferentFraction = 0.012

    /// Fewer matching rows than this is never accepted. A 10-row "match" is
    /// usually a repeated separator line, and treating it as a scroll offset
    /// would silently cut visible content out of the long image.
    static let minimumOverlap = 20

    /// Pixels that carry vertical detail — glyph edges, barcodes, rules — are
    /// the only ones that can tell one scroll offset from another. A page is
    /// mostly paper, so a fraction averaged over *every* sampled pixel is
    /// dominated by rows that agree at any offset: that is how a frame from a
    /// completely different part of the page (`+736 px`, measured) still
    /// scored 0.95 % and was appended. The detail sample below re-checks the
    /// winning offset against those pixels only.
    ///
    /// Fewer detail pixels than this means the frame has nothing to say (a
    /// white sheet, a full-bleed photo) and the plain fraction stays in charge.
    static let minimumInformativePixels = 12

    /// Fraction of those detail pixels a candidate may misplace. Measured on
    /// the shipping build: a real offset scores 0.000; repeated screens and
    /// coincidental paper matches score 0.26–0.84. The slack above 0 leaves
    /// room for a caret or a fading scrollbar without accepting a wrong offset.
    static let maximumInformativeMismatch = 0.060

    /// Candidates the frame-to-frame motion search evaluates at full detail.
    /// The coarse pass is cheap and ordered, so the real offset is at the top
    /// unless the page has no detail at all.
    static let motionCandidateLimit = 48

    /// How well two row-luminance profiles must line up before the motion is
    /// believed when the pixel test cannot decide.
    ///
    /// A smooth scroll draws the page at a fractional offset, so the *same*
    /// glyph lands on different pixels from one sample to the next: on a real
    /// Chrome page the true offset scored 18 % on the detail pixels while every
    /// other offset scored 30 %+ on the plain fraction. Row luminance averages
    /// that phase away, and a real move lines the two profiles up almost
    /// exactly.
    static let profileMatchNCC = 0.99

    /// How far ahead of every other shift (at least four rows away) the winner
    /// must be. A page whose rows repeat — a list of identical items, a paper
    /// with one rule per line — has several equally good peaks and must not be
    /// trusted to a single number.
    static let profilePeakMargin = 0.002

    /// Hard ceiling for one stitched image. Two hours of scrolling should not
    /// be able to allocate hundreds of megabytes in one `CGContext`.
    static let maximumOutputHeight = 60_000

    /// Rows shared by the bottom of `existing` and the top of `next`.
    ///
    /// Returns `0` when there is no trustworthy overlap, which means "append
    /// the whole next frame". `maxSearch` bounds the window; the result is
    /// additionally capped by both image heights.
    static func overlap(existing: CGImage, next: CGImage, maxSearch: Int) -> Int {
        findOverlap(
            existing: existing,
            next: next,
            maxSearch: maxSearch,
            minimumOverlap: minimumOverlap
        )
    }

    /// Stitch frames top to bottom.
    ///
    /// A frame that is entirely contained in the accumulated image contributes
    /// no new rows (overlap == frame height), which is what stops a stationary
    /// page from growing the result on every timer tick.
    static func stitch(frames: [CGImage]) -> CGImage {
        guard let first = frames.first else { return emptyImage() }
        guard first.width > 0, first.height > 0 else { return emptyImage() }

        var accumulated = first
        for next in frames.dropFirst() {
            guard next.width == accumulated.width,
                  next.width > 0,
                  next.height > 0 else { continue }

            // Search the full height of the incoming frame so a completely
            // unchanged frame is recognised as a duplicate (and skipped)
            // instead of appending one more copy.
            let rows = overlap(existing: accumulated, next: next, maxSearch: next.height)
            let newRows = next.height - rows
            guard newRows > 0 else { continue }
            guard accumulated.height + newRows <= maximumOutputHeight else { break }
            guard let appended = appending(accumulated, next, droppingTop: rows) else { continue }
            accumulated = appended
        }
        return accumulated
    }

    /// The self test and the controller both want to know how a candidate was
    /// judged; this variant exposes the two knobs without changing the public
    /// contract above.
    static func findOverlap(
        existing: CGImage,
        next: CGImage,
        maxSearch: Int,
        minimumOverlap: Int
    ) -> Int {
        guard let existingRaster = SampledRaster(existing),
              let nextRaster = SampledRaster(next) else { return 0 }
        return findOverlap(
            existing: existingRaster,
            next: nextRaster,
            maxSearch: maxSearch,
            minimumOverlap: minimumOverlap
        )
    }

    /// One accepted overlap plus how it was judged.
    ///
    /// The live session needs the counts, not just the rows: a match that only
    /// convinced the plain fraction is what duplicated a screen when the page
    /// was mostly paper. `difference` is the fraction over every sampled pixel,
    /// `informativeMismatch` the fraction over the pixels that carry detail.
    struct Match: Sendable, Equatable {
        let overlap: Int
        let difference: Double
        let informative: Int
        let informativeMismatch: Double
    }

    /// The overlap together with its evidence, or nil when no offset is
    /// trustworthy. `findOverlap` is this call without the details.
    static func findMatch(
        existing: SampledRaster,
        next: SampledRaster,
        maxSearch: Int,
        minimumOverlap: Int
    ) -> Match? {
        guard existing.width == next.width, existing.width > 0,
              existing.columnCount == next.columnCount else { return nil }

        let height = min(existing.height, next.height)
        guard height >= minimumOverlap else { return nil }

        // A frozen frame shares every row. Reporting the whole height (rather
        // than "no overlap") is what lets the caller count a still page as
        // "nothing new" instead of "unrecognised".
        if isFrozenFrame(existing: existing, next: next, height: height) {
            return Match(
                overlap: min(height, maxSearch),
                difference: 0,
                informative: 0,
                informativeMismatch: 0
            )
        }

        // A captured region frequently contains a band that does **not** move
        // with the page: a window title bar, a toolbar, a sticky table header,
        // a pinned footer. Those rows are identical between frames at the same
        // y, so no single displacement can satisfy the whole frame and a
        // whole-frame search rejects every candidate — the session then
        // concludes "this page does not scroll" and gives up on a page that
        // scrolls perfectly. Detect the bands first and search only the body
        // between them.
        let bandLimit = max(1, height / 3)
        let staticTop = staticRowsFromTop(existing: existing, next: next, limit: bandLimit)
        let staticBottom = staticRowsFromBottom(existing: existing, next: next, limit: bandLimit)
        let bodyStart = min(staticTop, height - minimumOverlap)
        let bodyEnd = max(bodyStart + minimumOverlap, height - staticBottom)
        guard bodyEnd - bodyStart >= minimumOverlap else { return nil }

        // Displacement search. `shift` is how far the body moved between the
        // two frames, so the shared part is `height - shift` rows; that keeps
        // the documented "rows of overlap" contract.
        // The shift is measured inside `existing`, which is the *accumulated*
        // image and is often much taller than `next`: the shared content sits
        // `existing.height - overlap` rows down, not `min(height) - overlap`.
        // Sizing the search by `height` capped the shift at the incoming
        // frame's height and made every frame after the second match a
        // repeated line instead of the real offset.
        let largestOverlap = min(maxSearch, existing.height, next.height)
        let smallestShift = max(1, existing.height - largestOverlap)
        let largestShift = existing.height - minimumOverlap
        guard smallestShift <= largestShift else { return nil }

        // Cheap first pass over every displacement, keeping the plausible ones.
        // Committing to the single best *paper* fraction and then throwing the
        // whole frame away when the detail pixels disagree is what made a
        // scrolling page stop recording: a repeated row can score 0.000 on the
        // plain fraction at the wrong offset, and the one real offset — with a
        // marginally worse fraction — was never examined.
        var coarse: [(fraction: Double, shift: Int)] = []
        var shift = smallestShift
        while shift <= largestShift {
            // Most displacements disagree on the first few rows, so the full
            // scan only runs for plausible ones.
            let fraction = shiftDifferentFraction(
                existing: existing,
                next: next,
                shift: shift,
                bodyStart: bodyStart,
                bodyEnd: bodyEnd,
                sampledRows: 6
            )
            if fraction <= 0.06 { coarse.append((fraction, shift)) }
            shift += 1
        }
        guard !coarse.isEmpty else { return nil }
        coarse.sort {
            $0.fraction == $1.fraction
                ? $0.shift < $1.shift
                : $0.fraction < $1.fraction
        }

        // Paper agreement is not content agreement. Every plausible offset is
        // judged on the pixels that carry detail; the one with the strongest
        // evidence wins, and an equal one prefers the larger overlap (the least
        // amount of unverified content appended).
        var best: Match?
        for candidate in coarse.prefix(motionCandidateLimit) {
            let overlap = existing.height - candidate.shift
            guard overlap >= minimumOverlap, overlap <= next.height else { continue }
            let fraction = shiftDifferentFraction(
                existing: existing,
                next: next,
                shift: candidate.shift,
                bodyStart: bodyStart,
                bodyEnd: bodyEnd,
                sampledRows: sampleRows
            )
            guard fraction <= maximumDifferentFraction else { continue }
            let detailRows = spacedRows(
                from: max(bodyStart, 0),
                to: min(bodyEnd, min(next.height, existing.height - candidate.shift)),
                count: detailSampleRows
            )
            let detail = informativeMismatch(
                existing: existing,
                next: next,
                shift: candidate.shift,
                rows: detailRows
            )
            guard detail.count >= minimumInformativePixels,
                  detail.mismatch <= maximumInformativeMismatch else { continue }
            let match = Match(
                overlap: overlap,
                difference: fraction,
                informative: detail.count,
                informativeMismatch: detail.mismatch
            )
            if let incumbent = best {
                if detail.mismatch < incumbent.informativeMismatch - 0.0005
                    || (abs(detail.mismatch - incumbent.informativeMismatch) <= 0.0005
                        && overlap > incumbent.overlap) {
                    best = match
                }
            } else {
                best = match
            }
        }
        return best
    }

    /// Overlap search over two pre-sampled rasters.
    ///
    /// The pixels and the arithmetic are exactly those of the CGImage variant;
    /// only the storage changed, so the live path can append to one raster
    /// instead of rebuilding it from the accumulated image on every sample.
    static func findOverlap(
        existing: SampledRaster,
        next: SampledRaster,
        maxSearch: Int,
        minimumOverlap: Int
    ) -> Int {
        findMatch(
            existing: existing,
            next: next,
            maxSearch: maxSearch,
            minimumOverlap: minimumOverlap
        )?.overlap ?? 0
    }

    /// Rows of `next` that are in range for `shift` and inside the body.
    private static func shiftRows(
        shift: Int,
        bodyStart: Int,
        bodyEnd: Int,
        existingHeight: Int,
        nextHeight: Int
    ) -> (start: Int, end: Int) {
        let end = min(bodyEnd, min(nextHeight, existingHeight - shift))
        return (bodyStart, max(bodyStart, end))
    }

    /// Fraction of sampled pixels that differ between `next`'s body rows and
    /// `existing`'s body rows displaced by `shift`.
    private static func shiftDifferentFraction(
        existing: SampledRaster,
        next: SampledRaster,
        shift: Int,
        bodyStart: Int,
        bodyEnd: Int,
        sampledRows: Int
    ) -> Double {
        let range = shiftRows(shift: shift, bodyStart: bodyStart, bodyEnd: bodyEnd,
                              existingHeight: existing.height, nextHeight: next.height)
        let span = range.end - range.start
        let columns = next.columnCount
        guard span > 0, columns > 0 else { return 1 }
        let rowCount = min(sampledRows, span)

        var different = 0
        var total = 0
        for index in 0..<rowCount {
            let y = range.start + (index * span) / rowCount
            for column in 0..<columns {
                let a = next.rgb(column: column, y: y)
                let b = existing.rgb(column: column, y: y + shift)
                let delta = max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2))
                if delta > differenceTolerance { different += 1 }
                total += 1
            }
        }
        guard total > 0 else { return 1 }
        return Double(different) / Double(total)
    }

    // MARK: - Motion and detail (scrolling direction)

    /// Evenly spaced rows in `[start, end)`. The count is capped by the span so
    /// a thin overlap still samples every row it has instead of repeating one.
    static func spacedRows(from start: Int, to end: Int, count: Int) -> [Int] {
        guard count > 0, end > start else { return [] }
        let span = end - start
        let sampled = min(count, span)
        return (0..<sampled).map { start + ($0 * span) / sampled }
    }

    /// Rows of `next` that take part in a comparison at `shift`, clamped to the
    /// body and to both rasters. Unlike the forward-only `shiftRows` this is
    /// also correct for a *negative* shift, where the comparison starts below
    /// the top of `next`.
    private static func alignedRows(
        shift: Int,
        bodyStart: Int,
        bodyEnd: Int,
        existingHeight: Int,
        nextHeight: Int
    ) -> Range<Int> {
        let start = max(bodyStart, -shift)
        let end = min(bodyEnd, min(nextHeight, existingHeight - shift))
        return start..<max(start, end)
    }

    /// Mean absolute per-channel difference test over an explicit row/column
    /// set, with the alignment clamped for negative shifts.
    private static func plainDifference(
        existing: SampledRaster,
        next: SampledRaster,
        shift: Int,
        rows: [Int],
        columns: [Int]?
    ) -> Double {
        var different = 0
        var total = 0
        for y in rows {
            let aligned = y + shift
            guard aligned >= 0, aligned < existing.height else { continue }
            if let columns {
                for column in columns {
                    if existing.difference(from: next, column: column, y: aligned, otherY: y)
                        > differenceTolerance {
                        different += 1
                    }
                    total += 1
                }
            } else {
                for column in 0..<next.columnCount {
                    if existing.difference(from: next, column: column, y: aligned, otherY: y)
                        > differenceTolerance {
                        different += 1
                    }
                    total += 1
                }
            }
        }
        guard total > 0 else { return 1 }
        return Double(different) / Double(total)
    }

    /// True when row `y` of `raster` carries vertical detail: it differs from
    /// the row above or below it. Paper, gradients and the seams between them
    /// are not detail — they match at every offset, which is why they cannot
    /// decide where a frame belongs.
    private static func isDetailed(_ raster: SampledRaster, column: Int, y: Int) -> Bool {
        guard y >= 0, y < raster.height else { return false }
        for neighbour in [y - 1, y + 1] where neighbour >= 0 && neighbour < raster.height {
            if raster.difference(from: raster, column: column, y: y, otherY: neighbour)
                > differenceTolerance {
                return true
            }
        }
        return false
    }

    /// Whether the frame has enough detail for the informative test to say
    /// anything at all. A white sheet does not.
    private static func hasDetail(_ raster: SampledRaster) -> Bool {
        guard raster.height > 2, raster.columnCount > 0 else { return false }
        var found = 0
        for y in spacedRows(from: 1, to: raster.height - 1, count: 8) {
            for column in 0..<raster.columnCount where isDetailed(raster, column: column, y: y) {
                found += 1
                if found >= minimumInformativePixels / 2 { return true }
            }
        }
        return false
    }

    /// Mismatch over the pixels that carry detail, with one row of vertical
    /// slack for sub-pixel scroll offsets and antialiasing.
    private static func informativeMismatch(
        existing: SampledRaster,
        next: SampledRaster,
        shift: Int,
        rows: [Int]
    ) -> (mismatch: Double, count: Int) {
        var informative = 0
        var mismatched = 0
        for y in rows {
            let aligned = y + shift
            guard aligned >= 0, aligned < existing.height else { continue }
            for column in 0..<next.columnCount {
                guard isDetailed(next, column: column, y: y) else { continue }
                informative += 1
                var matched = false
                for slack in -1...1 {
                    let probe = aligned + slack
                    guard probe >= 0, probe < existing.height else { continue }
                    if existing.difference(from: next, column: column, y: probe, otherY: y)
                        <= differenceTolerance {
                        matched = true
                        break
                    }
                }
                if !matched { mismatched += 1 }
            }
        }
        guard informative > 0 else { return (1, 0) }
        return (Double(mismatched) / Double(informative), informative)
    }

    // MARK: - Row profiles (sub-pixel tolerant motion)

    /// Mean luminance of each row in `[start, end)`, over the sampled columns.
    ///
    /// The profile survives what the pixel comparison cannot: a page drawn at a
    /// fractional scroll offset has different antialiasing on every glyph edge,
    /// but the same *amount of ink* per row.
    static func rowProfile(
        _ raster: SampledRaster,
        from start: Int,
        to end: Int
    ) -> [Double] {
        guard end > start, raster.columnCount > 0 else { return [] }
        var profile = [Double](repeating: 0, count: end - start)
        for y in start..<end {
            var sum = 0
            for column in 0..<raster.columnCount {
                let pixel = raster.rgb(column: column, y: y)
                sum += (pixel.0 * 299 + pixel.1 * 587 + pixel.2 * 114) / 1000
            }
            profile[y - start] = Double(sum) / Double(raster.columnCount)
        }
        return profile
    }

    /// Pearson correlation of `a[shift + lo ..< shift + hi]` with `b[lo ..< hi]`.
    private static func correlation(
        _ a: [Double],
        _ b: [Double],
        shift: Int,
        from lo: Int,
        to hi: Int
    ) -> Double {
        let count = hi - lo
        guard count > 0 else { return -2 }
        var sumA = 0.0
        var sumB = 0.0
        for index in lo..<hi {
            sumA += a[shift + index]
            sumB += b[index]
        }
        let meanA = sumA / Double(count)
        let meanB = sumB / Double(count)
        var numerator = 0.0, varianceA = 0.0, varianceB = 0.0
        for index in lo..<hi {
            let left = a[shift + index] - meanA
            let right = b[index] - meanB
            numerator += left * right
            varianceA += left * left
            varianceB += right * right
        }
        let denominator = (varianceA * varianceB).squareRoot()
        return denominator > 1e-9 ? numerator / denominator : -2
    }

    /// Row-profile alignment of two consecutive frames, with the pinned bands
    /// left out. `nil` unless one shift wins clearly.
    static func profileShift(
        previous: SampledRaster,
        next: SampledRaster
    ) -> Int? {
        guard previous.width == next.width, previous.width > 0,
              previous.columnCount == next.columnCount else { return nil }
        let height = min(previous.height, next.height)
        guard height >= minimumOverlap * 2 else { return nil }
        let bandLimit = max(1, height / 3)
        let staticTop = staticRowsFromTop(existing: previous, next: next, limit: bandLimit)
        let staticBottom = staticRowsFromBottom(existing: previous, next: next, limit: bandLimit)
        let start = min(staticTop, height - minimumOverlap)
        let end = max(start + minimumOverlap, height - staticBottom)
        guard end - start >= minimumOverlap else { return nil }

        let left = rowProfile(previous, from: start, to: end)
        let right = rowProfile(next, from: start, to: end)
        let limit = min(left.count, right.count) - minimumOverlap
        guard limit >= 1 else { return nil }

        var results: [(ncc: Double, shift: Int)] = []
        for shift in (-limit)...limit {
            let lo = max(0, -shift)
            let hi = min(right.count, left.count - shift)
            guard hi - lo >= minimumOverlap else { continue }
            results.append((
                correlation(left, right, shift: shift, from: lo, to: hi),
                shift
            ))
        }
        guard let best = results.max(by: { $0.ncc < $1.ncc }) else { return nil }
        guard best.ncc >= profileMatchNCC else { return nil }
        let runnerUp = results
            .filter { abs($0.shift - best.shift) > 4 }
            .map(\.ncc)
            .max() ?? -2
        guard best.ncc - runnerUp >= profilePeakMargin else { return nil }
        return best.shift
    }

    /// Row profiles of the first `rows` rows of `next` against `existing` at
    /// `top`. The second witness for a frame that overlaps the stitch only
    /// partly, when the pixel test cannot decide because of the sub-pixel phase.
    static func profileMatches(
        existing: SampledRaster,
        next: SampledRaster,
        top: Int,
        rows: Int,
        skipTop: Int
    ) -> Bool {
        let start = max(0, skipTop)
        guard top >= 0, rows - start >= minimumOverlap,
              top + rows <= existing.height, rows <= next.height,
              existing.width == next.width,
              existing.columnCount == next.columnCount else { return false }
        let left = rowProfile(existing, from: top + start, to: top + rows)
        let right = rowProfile(next, from: start, to: rows)
        guard left.count == right.count, left.count >= minimumOverlap else { return false }
        let ncc = correlation(left, right, shift: 0, from: 0, to: left.count)
        return ncc >= profileMatchNCC
    }

    /// Signed vertical displacement of the content between two consecutive
    /// frames, in pixels, or nil when the frames have no trustworthy overlap.
    ///
    /// Positive means the page scrolled **down** by that many rows:
    /// `next[y] == previous[y + shift]`. Negative means it scrolled **up** —
    /// the user is looking at rows this session already captured (or at rows
    /// above the first one it ever captured, which an append-only stitch can
    /// never represent). The sign is what stops a repeated screen from being
    /// appended a second time.
    ///
    /// A fraction over *all* sampled pixels cannot answer that question: paper
    /// dominates, so a frame from a completely different part of the page can
    /// score just under `maximumDifferentFraction` (measured: 0.95 %). The
    /// decision therefore comes from the pixels that carry detail, which only
    /// agree at the real offset (measured: 0.000 real vs 0.036 repeated).
    static func frameDisplacement(
        previous: SampledRaster,
        next: SampledRaster
    ) -> Int? {
        guard previous.width == next.width, previous.width > 0,
              previous.columnCount == next.columnCount else { return nil }
        let height = min(previous.height, next.height)
        guard height >= minimumOverlap * 2, hasDetail(next) else { return nil }
        // A still page is exactly the same picture. This has to be checked
        // before the displacement search: with one row of slack for
        // antialiasing, a frozen frame "matches" at ±1, and reporting that as
        // a move would keep resetting the stillness streak — the session would
        // never notice it had reached the bottom.
        if isFrozenFrame(existing: previous, next: next, height: height) { return nil }

        let bandLimit = max(1, height / 3)
        let staticTop = staticRowsFromTop(existing: previous, next: next, limit: bandLimit)
        let staticBottom = staticRowsFromBottom(existing: previous, next: next, limit: bandLimit)
        let bodyStart = min(staticTop, height - minimumOverlap)
        let bodyEnd = max(bodyStart + minimumOverlap, height - staticBottom)
        guard bodyEnd - bodyStart >= minimumOverlap else { return nil }

        let limit = height - minimumOverlap
        let coarseColumns = stride(from: 0, to: next.columnCount, by: 4).map { $0 }
        var coarse: [(fraction: Double, shift: Int)] = []
        var shift = -limit
        while shift <= limit {
            // One row (0.5 pt) is below the append threshold and inside the
            // antialiasing slack; it is not a direction.
            if abs(shift) >= 2 {
                let range = alignedRows(
                    shift: shift,
                    bodyStart: bodyStart,
                    bodyEnd: bodyEnd,
                    existingHeight: previous.height,
                    nextHeight: next.height
                )
                if range.count >= minimumOverlap {
                    let rows = spacedRows(from: range.lowerBound, to: range.upperBound, count: 6)
                    let fraction = plainDifference(
                        existing: previous,
                        next: next,
                        shift: shift,
                        rows: rows,
                        columns: coarseColumns
                    )
                    if fraction <= 0.06 { coarse.append((fraction, shift)) }
                }
            }
            shift += 1
        }
        guard !coarse.isEmpty else {
            // Nothing agrees on every pixel — a smooth scroll's sub-pixel
            // phase. The row profile is the fallback witness.
            return profileShift(previous: previous, next: next)
        }
        coarse.sort {
            $0.fraction == $1.fraction
                ? abs($0.shift) < abs($1.shift)
                : $0.fraction < $1.fraction
        }

        var best: (mismatch: Double, shift: Int)?
        for candidate in coarse.prefix(motionCandidateLimit) {
            let range = alignedRows(
                shift: candidate.shift,
                bodyStart: bodyStart,
                bodyEnd: bodyEnd,
                existingHeight: previous.height,
                nextHeight: next.height
            )
            guard range.count >= minimumOverlap else { continue }
            let rows = spacedRows(from: range.lowerBound, to: range.upperBound, count: sampleRows)
            let fraction = plainDifference(
                existing: previous,
                next: next,
                shift: candidate.shift,
                rows: rows,
                columns: nil
            )
            guard fraction <= maximumDifferentFraction else { continue }
            let detailRows = spacedRows(
                from: range.lowerBound,
                to: range.upperBound,
                count: detailSampleRows
            )
            let detail = informativeMismatch(
                existing: previous,
                next: next,
                shift: candidate.shift,
                rows: detailRows
            )
            guard detail.count >= minimumInformativePixels,
                  detail.mismatch <= maximumInformativeMismatch else { continue }
            // Lowest detail mismatch wins; equal evidence prefers the smaller
            // movement, so a one-row nudge cannot be reported as a screen.
            if best == nil
                || detail.mismatch < best!.mismatch - 0.0005
                || (abs(detail.mismatch - best!.mismatch) <= 0.0005
                    && abs(candidate.shift) < abs(best!.shift)) {
                best = (detail.mismatch, candidate.shift)
            }
        }
        if let best { return best.shift }
        // A smooth scroll renders the same glyph at a different sub-pixel
        // phase on every sample, which the detail pixels cannot forgive. The
        // row profile can, and it refuses to answer when the page repeats.
        return profileShift(previous: previous, next: next)
    }

    /// True when `next` already exists inside `existing` with its first row at
    /// `top`. Used for "the user scrolled back into content we already have":
    /// that frame must not be appended again.
    static func frameMatches(
        existing: SampledRaster,
        next: SampledRaster,
        top: Int
    ) -> Bool {
        frameMatches(existing: existing, next: next, top: top, rows: next.height)
    }

    /// The first `rows` rows of `next` place at `top` in `existing`, judged on
    /// the pixels that carry detail.
    ///
    /// Used when only the top of a frame overlaps the stitch: the page moved on
    /// between two samples, the frame starts a few hundred rows above the
    /// stitched bottom, and the rows below the bottom are exactly what has to be
    /// appended. The overlap is verified first, so a coincidence cannot be
    /// appended twice.
    ///
    /// `skipTop` leaves the screen-pinned band at the top of the frame (a
    /// sticky header) out of the comparison: those rows are not page content
    /// and cannot be found at `top` in the stitch.
    static func frameMatches(
        existing: SampledRaster,
        next: SampledRaster,
        top: Int,
        rows: Int,
        skipTop: Int = 0
    ) -> Bool {
        guard top >= 0, rows >= minimumOverlap,
              rows <= next.height,
              top + rows <= existing.height,
              existing.width == next.width,
              existing.columnCount == next.columnCount else { return false }
        let start = min(max(0, skipTop), rows - minimumOverlap)
        guard rows - start >= minimumOverlap else { return false }
        let sampledRows = spacedRows(from: start, to: rows, count: detailSampleRows)
        let detail = informativeMismatch(
            existing: existing,
            next: next,
            shift: top,
            rows: sampledRows
        )
        if detail.count >= minimumInformativePixels,
           detail.mismatch <= maximumInformativeMismatch {
            return true
        }
        // Same picture, different sub-pixel phase: fall back to the row
        // profile, which only agrees when the content really is there.
        return profileMatches(
            existing: existing,
            next: next,
            top: top,
            rows: rows,
            skipTop: start
        )
    }

    /// Rows pinned to the screen at the top of `next`: identical at the same y
    /// in two consecutive frames, i.e. a sticky header rather than page rows.
    ///
    /// The live session passes this to `frameMatches` so a sticky band cannot
    /// make a perfectly aligned frame look like a mismatch.
    static func pinnedTopRows(previous: SampledRaster, next: SampledRaster) -> Int {
        let height = min(previous.height, next.height)
        guard height >= minimumOverlap * 2,
              previous.width == next.width,
              previous.columnCount == next.columnCount else { return 0 }
        let limit = max(1, height / 3)
        return min(
            staticRowsFromTop(existing: previous, next: next, limit: limit),
            max(0, height - minimumOverlap)
        )
    }

    /// `existing`'s row that lines up with `next`'s row 0 when nothing moved.
    ///
    /// The caller keeps one *accumulated* image, so `existing` is normally
    /// taller than `next`; comparing both at the same literal y would compare
    /// the top of the long image against the top of the incoming frame.
    private static func frozenBase(existing: SampledRaster, next: SampledRaster) -> Int {
        max(0, existing.height - min(existing.height, next.height))
    }

    /// True when `next` is the same picture as the bottom of `existing`, i.e.
    /// the page did not move at all.
    private static func isFrozenFrame(
        existing: SampledRaster,
        next: SampledRaster,
        height: Int
    ) -> Bool {
        let base = frozenBase(existing: existing, next: next)
        let columns = next.columnCount
        for y in 0..<height {
            guard base + y < existing.height else { return false }
            for column in 0..<columns {
                let a = existing.rgb(column: column, y: base + y)
                let b = next.rgb(column: column, y: y)
                if max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2)) > differenceTolerance {
                    return false
                }
            }
        }
        return true
    }

    /// True when row `y` is pinned to the *screen* rather than to the page: it
    /// is the same in the accumulated image and in the incoming frame at the
    /// very same y, which is what a window title bar, a toolbar or a sticky
    /// table header look like. Those rows are never part of the scroll and must
    /// stay out of the displacement comparison.
    private static func isScreenPinnedRow(
        existing: SampledRaster,
        next: SampledRaster,
        y: Int
    ) -> Bool {
        guard y >= 0, y < next.height, y < existing.height else { return false }
        let columns = next.columnCount
        for column in 0..<columns {
            let a = existing.rgb(column: column, y: y)
            let b = next.rgb(column: column, y: y)
            if max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2)) > differenceTolerance {
                return false
            }
        }
        return true
    }

    /// Leading rows that did not move, capped at `limit`.
    private static func staticRowsFromTop(
        existing: SampledRaster,
        next: SampledRaster,
        limit: Int
    ) -> Int {
        let height = min(existing.height, next.height)
        var count = 0
        while count < min(limit, height),
              isScreenPinnedRow(existing: existing, next: next, y: count) {
            count += 1
        }
        return count
    }

    /// Trailing rows that did not move, capped at `limit`.
    private static func staticRowsFromBottom(
        existing: SampledRaster,
        next: SampledRaster,
        limit: Int
    ) -> Int {
        let height = min(existing.height, next.height)
        var count = 0
        while count < min(limit, height),
              isScreenPinnedRow(existing: existing, next: next, y: height - count - 1) {
            count += 1
        }
        return count
    }

    /// Evenly spaced x positions, skipping the outermost pixels. The edges of a
    /// capture often carry a scrollbar or rounded window corner that differs
    /// between frames even when the text does not.
    private static func columnOffsets(width: Int, count: Int) -> [Int] {
        guard width > 0 else { return [] }
        let usable = max(1, count)
        let margin = min(24, max(0, width / 20))
        let span = width - margin * 2
        guard span > 0 else { return [width / 2] }
        return (1...usable).map { index in
            margin + (span * index) / (usable + 1)
        }
    }

    // MARK: - Sampled raster

    /// The only pixels the matcher ever reads: `sampleColumns` evenly spaced
    /// columns, stored contiguously.
    ///
    /// Storing 180 columns instead of the full width makes the accumulated
    /// raster ~9 % of a full RGBA image at 2000 px wide, keeps the search's
    /// random access inside a cache-friendly buffer, and — most importantly —
    /// lets a new frame be **appended** instead of re-sampling the whole
    /// stitched image.
    struct SampledRaster: Equatable {
        let width: Int
        let columns: [Int]
        private(set) var height: Int
        private var bytes: [UInt8]

        var columnCount: Int { columns.count }

        init(width: Int, columns: [Int], height: Int = 0, bytes: [UInt8] = []) {
            self.width = width
            self.columns = columns
            self.height = height
            self.bytes = bytes
        }

        /// Sample one whole image. Only used for the first frame and for the
        /// incoming frame of each sample.
        init?(_ image: CGImage) {
            let width = image.width
            let height = image.height
            guard width > 0, height > 0 else { return nil }
            let columns = ScrollStitcher.columnOffsets(
                width: width,
                count: ScrollStitcher.sampleColumns
            )
            guard !columns.isEmpty, let raster = Raster(image) else { return nil }
            var bytes = [UInt8](repeating: 0, count: height * columns.count * 4)
            bytes.withUnsafeMutableBytes { raw in
                guard let out = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                raster.bytes.withUnsafeBufferPointer { source in
                    guard let input = source.baseAddress else { return }
                    var destination = 0
                    for y in 0..<height {
                        let row = y * width
                        for x in columns {
                            let index = (row + x) * 4
                            out[destination] = input[index]
                            out[destination + 1] = input[index + 1]
                            out[destination + 2] = input[index + 2]
                            out[destination + 3] = input[index + 3]
                            destination += 4
                        }
                    }
                }
            }
            self.init(width: width, columns: columns, height: height, bytes: bytes)
        }

        /// Append the rows of `image` below `droppingTop`, exactly as the
        /// accumulated image would show them.
        mutating func append(_ image: CGImage, droppingTop rows: Int) -> Bool {
            guard image.width == width,
                  let source = Raster(image),
                  rows >= 0, rows < source.height else { return false }
            let newRows = source.height - rows
            guard newRows > 0 else { return true }
            let columns = self.columns
            let width = self.width
            let start = bytes.count
            bytes.append(contentsOf: repeatElement(0, count: newRows * columns.count * 4))
            bytes.withUnsafeMutableBytes { raw in
                guard let out = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                source.bytes.withUnsafeBufferPointer { input in
                    guard let source = input.baseAddress else { return }
                    var destination = start
                    for y in rows..<(rows + newRows) {
                        let row = y * width
                        for x in columns {
                            let index = (row + x) * 4
                            out[destination] = source[index]
                            out[destination + 1] = source[index + 1]
                            out[destination + 2] = source[index + 2]
                            out[destination + 3] = source[index + 3]
                            destination += 4
                        }
                    }
                }
            }
            height += newRows
            return true
        }

        func rgb(column: Int, y: Int) -> (Int, Int, Int) {
            let index = (y * columns.count + column) * 4
            return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
        }

        /// Largest per-channel difference between `(column, y)` here and
        /// `(column, otherY)` in `other`, 0…255. Byte-level on purpose: the
        /// motion and detail passes call this millions of times per second and
        /// a tuple per pixel was measurable.
        func difference(
            from other: SampledRaster,
            column: Int,
            y: Int,
            otherY: Int
        ) -> Int {
            let index = (y * columns.count + column) * 4
            let otherIndex = (otherY * other.columns.count + column) * 4
            let red = abs(Int(bytes[index]) - Int(other.bytes[otherIndex]))
            let green = abs(Int(bytes[index + 1]) - Int(other.bytes[otherIndex + 1]))
            let blue = abs(Int(bytes[index + 2]) - Int(other.bytes[otherIndex + 2]))
            return max(red, max(green, blue))
        }
    }

    // MARK: - Appending

    /// Draw `base` on top and the new lower rows of `next` underneath it.
    ///
    /// The append is done with a clip and a normalised `CGContext` draw rather
    /// than `CGImage.cropping(to:)`, so the source-row orientation is explicit:
    /// in a bottom-left context the image's first row lands on the rect's top
    /// edge, therefore clipping `0…newRows` keeps exactly rows
    /// `droppingTop…next.height-1`.
    /// Append the rows below `rows` from `next` underneath `base`.
    ///
    /// Exposed to `ScrollAutoStitcher`, which keeps one accumulated image and
    /// grows it frame by frame instead of re-stitching the whole list.
    static func appending(_ base: CGImage, _ next: CGImage, droppingTop rows: Int) -> CGImage? {
        let width = base.width
        let added = next.height - rows
        guard width > 0, added > 0, next.width == width else { return nil }
        let height = base.height + added
        guard height <= maximumOutputHeight else { return nil }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colourSpace(for: base),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .none
        context.draw(
            base,
            in: CGRect(x: 0, y: added, width: width, height: base.height)
        )

        context.saveGState()
        context.clip(to: CGRect(x: 0, y: 0, width: width, height: added))
        context.draw(
            next,
            in: CGRect(x: 0, y: 0, width: next.width, height: next.height)
        )
        context.restoreGState()

        return context.makeImage()
    }

    /// Copy the rows below `droppingTop` of `next` into a standalone image.
    ///
    /// The live store keeps one of these per appended frame instead of one
    /// ever-growing context: a piece is exactly the pixels that were added, so
    /// appending costs the new rows only. It has to be materialised (rather
    /// than `cropping`, which keeps the whole source frame alive) or a long
    /// session would pin one full frame per sample in memory.
    static func piece(_ next: CGImage, droppingTop rows: Int) -> (image: CGImage, rows: Int)? {
        let width = next.width
        let added = next.height - rows
        guard width > 0, next.height > 0, added > 0, added <= next.height else { return nil }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: added,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colourSpace(for: next),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        context.draw(
            next,
            in: CGRect(x: 0, y: 0, width: width, height: next.height)
        )
        return (context.makeImage() ?? next, added)
    }

    static func colourSpace(for image: CGImage) -> CGColorSpace {
        image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpaceCreateDeviceRGB()
    }

    static func emptyImage() -> CGImage {
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let context, let image = context.makeImage() else {
            // A 1×1 CGImage cannot fail on a supported macOS version; this is
            // only a type-level fallback.
            return CGImage(
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: CGDataProvider(data: Data([0, 0, 0, 0]) as CFData)!,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )!
        }
        return image
    }

    /// Premultiplied RGBA8 copy of one image, with top-left row indexing.
    ///
    /// Used to sample one incoming frame. The live path never builds this for
    /// the accumulated image.
    struct Raster {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        init?(_ image: CGImage) {
            let width = image.width
            let height = image.height
            guard width > 0, height > 0 else { return nil }
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let drew = bytes.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(
                    data: raw.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: image.colorSpace?.model == .rgb
                        ? image.colorSpace!
                        : CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drew else { return nil }
            self.width = width
            self.height = height
            self.bytes = bytes
        }

        /// RGB at a top-left-origin coordinate.
        func rgb(x: Int, y: Int) -> (Int, Int, Int) {
            let index = (y * width + x) * 4
            return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
        }
    }
}

/// One viewfinder update: the bottom band of the stitch, already composed at
/// the size the viewfinder draws it.
///
/// The old path handed the viewfinder the whole stitched image and let it crop
/// and resample the bottom on every draw. At a 30 %-wide card the well shows
/// ~10× its own height in source rows, so that crop was a 10 000-row
/// resampling job running at the sampling rate. The band is composed once, off
/// the main thread, and drawn 1:1 afterwards.
struct ScrollPreviewFrame {
    /// The band itself, `width` = the requested display width.
    let image: CGImage
    /// Height of the **whole** stitch at the band's scale. Equal to
    /// `image.height` until the page is longer than the band.
    let contentHeight: CGFloat

    /// Band size in points (the pod draws at its natural size).
    var size: CGSize { CGSize(width: CGFloat(image.width), height: CGFloat(image.height)) }

    /// Compose a band from one already-stitched image. The self test and the
    /// probe use this; the live path asks `ScrollStitchStore` directly.
    static func make(from image: CGImage, size: CGSize) -> ScrollPreviewFrame? {
        guard image.width > 0, image.height > 0, size.width >= 1, size.height >= 1 else {
            return nil
        }
        let scale = size.width / CGFloat(image.width)
        let content = CGFloat(image.height) * scale
        let bandHeight = max(1, min(size.height, content))
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(bandHeight.rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: ScrollStitcher.colourSpace(for: image),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        let rows = min(CGFloat(image.height), ceil(bandHeight / scale) + 1)
        let crop = image.cropping(to: CGRect(
            x: 0,
            y: CGFloat(image.height) - rows,
            width: CGFloat(image.width),
            height: rows
        ).integral)
        guard let crop else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: CGFloat(width),
                                      height: rows * scale))
        guard let band = context.makeImage() else { return nil }
        return ScrollPreviewFrame(image: band, contentHeight: content)
    }
}

/// Append-only accumulation for a live session.
///
/// Two representations of the same pixels, both updated with the new rows only:
///
/// * `sampled` — the 180 sampled columns the matcher reads. Appended, never
///   rebuilt, so the overlap search stays the same cost at 60 000 px as at
///   1 000 px.
/// * `pieces` — one materialised image per contributed frame. The picture is
///   only composed when someone asks for it: the viewfinder gets a small band
///   at display size, and the finished long image is composed once.
///
/// The store is handed between the serial stitch worker and the main actor. It
/// is never touched by two threads at the same time (the worker owns it while
/// it runs, the actor owns it in between), which is what the unchecked
/// conformance records.
final class ScrollStitchStore: @unchecked Sendable {
    let width: Int
    private(set) var height: Int
    private(set) var sampled: ScrollStitcher.SampledRaster
    /// Rows the session started with. `height > firstFrameHeight` is what makes
    /// a page "grown"; a still page must never finish the session.
    let firstFrameHeight: Int

    private var pieces: [(image: CGImage, rows: Int)]
    private var cachedComposed: CGImage?

    var grew: Bool { height > firstFrameHeight }

    init?(_ first: CGImage) {
        guard first.width > 0, first.height > 0,
              let sampled = ScrollStitcher.SampledRaster(first),
              let piece = ScrollStitcher.piece(first, droppingTop: 0) else { return nil }
        self.width = first.width
        self.height = first.height
        self.firstFrameHeight = first.height
        self.sampled = sampled
        self.pieces = [piece]
    }

    /// Append the rows of `next` below `droppingTop`. Returns how many rows
    /// were added, or `nil` when the image would exceed the height ceiling.
    @discardableResult
    func append(_ next: CGImage, droppingTop rows: Int) -> Int? {
        guard next.width == width, rows >= 0, rows < next.height else { return nil }
        let added = next.height - rows
        guard added > 0, height + added <= ScrollStitcher.maximumOutputHeight else { return nil }
        guard let piece = ScrollStitcher.piece(next, droppingTop: rows),
              sampled.append(next, droppingTop: rows) else { return nil }
        pieces.append(piece)
        height += added
        cachedComposed = nil
        return added
    }

    /// The whole stitch. O(total pixels) — finish, self test, never the live
    /// preview.
    func composed() -> CGImage? {
        if let cachedComposed { return cachedComposed }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: ScrollStitcher.colourSpace(for: pieces[0].image),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        var y = 0
        for piece in pieces.reversed() {
            context.draw(
                piece.image,
                in: CGRect(x: 0, y: y, width: width, height: piece.rows)
            )
            y += piece.rows
        }
        cachedComposed = context.makeImage()
        return cachedComposed
    }

    /// The bottom band of the stitch, composed at `size` (points).
    ///
    /// Only the pieces that can reach into the band are drawn, so the cost is
    /// the band's own pixel count — a few hundred thousand pixels — no matter
    /// how long the page has become.
    func makePreviewFrame(size: CGSize) -> ScrollPreviewFrame? {
        guard width > 0, height > 0, size.width >= 1, size.height >= 1 else { return nil }
        let scale = size.width / CGFloat(width)
        let content = CGFloat(height) * scale
        let bandHeight = max(1, min(size.height, content))
        let pixelWidth = max(1, Int(size.width.rounded()))
        let pixelHeight = max(1, Int(bandHeight.rounded()))
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: ScrollStitcher.colourSpace(for: pieces[0].image),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        var drawn = 0.0
        for piece in pieces.reversed() {
            let pieceHeight = CGFloat(piece.rows) * scale
            let bottom = bandHeight - drawn - pieceHeight
            drawn += pieceHeight
            if bottom + pieceHeight <= 0 { break }
            context.draw(
                piece.image,
                in: CGRect(x: 0, y: bottom, width: CGFloat(pixelWidth), height: pieceHeight)
            )
            if drawn >= bandHeight { break }
        }
        guard let band = context.makeImage() else { return nil }
        return ScrollPreviewFrame(image: band, contentHeight: content)
    }

    /// Test seam: how many row pieces are retained.
    var pieceCount: Int { pieces.count }
}

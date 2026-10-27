import AppKit
import ApplicationServices
import CoreGraphics

/// Incremental stitcher used by a live session.
///
/// The pure `ScrollStitcher` still owns the pixel matching; this state machine
/// adds the three things a *running* capture needs and that are worth testing
/// without a window server:
///
/// * feed one frame at a time and keep the accumulated image,
/// * count frames that contributed no new rows (the page stopped moving),
/// * report growth so the caller can decide when the page is finished.
/// Opt-in per-frame timing for a live scrolling capture.
///
///     UNSEEN_SCROLL_PERF=1
///
/// One line per sample plus one per viewfinder draw; used to compare builds on
/// the same page instead of guessing where the frame time goes.
enum ScrollPerf {
    nonisolated static let enabled =
        ProcessInfo.processInfo.environment["UNSEEN_SCROLL_PERF"] == "1"

    nonisolated static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        print("scroll-perf: \(message())")
    }
}

struct ScrollAutoStitcher {
    /// Consecutive no-growth frames observed before a growing page counts as
    /// finished. The controller additionally requires that this be sustained
    /// for `stillnessLimit`, so a fast sampling rate cannot end a session on a
    /// single slow repaint.
    nonisolated static let noGrowthLimit = 3
    /// A 1-row difference is antialiasing, not content. Anything below this is
    /// treated as "nothing new".
    nonisolated static let minimumNewRows = 2

    /// The append-only accumulator. Nil until the first frame arrives.
    private(set) var store: ScrollStitchStore?
    private(set) var frameCount = 0
    private(set) var noGrowthStreak = 0
    private(set) var lastOverlap = 0
    /// The frame before the current one, kept only for the motion test.
    ///
    /// 180 sampled columns of one screen — the same raster the store appends —
    /// so the direction of the move can be read without touching the stitched
    /// image. It is replaced on every accepted sample.
    private var previousSampled: ScrollStitcher.SampledRaster?
    /// Row of the stitch where the *previous* sample's first row sits.
    ///
    /// Negative while the user is looking at rows above the first one this
    /// session captured: an append-only stitch cannot represent them, and they
    /// must never be appended below what is already there. The value is what
    /// makes "did this frame land in content we already have?" a comparison
    /// instead of a search.
    ///
    /// It is advanced on **every** sample that has a measurable move, not only
    /// on the ones that appended. A frame can be refused while the page keeps
    /// moving (a repeated row, a frame that arrived mid-repaint); leaving the
    /// position behind made the next frame's move land in the wrong place, so
    /// the rest of a perfectly ordinary scroll was refused one frame after
    /// another and the viewfinder stopped growing.
    private(set) var frameTop = 0

    var height: Int { store?.height ?? 0 }
    /// True once at least one frame contributed new rows. A session that never
    /// grew is a page that has not scrolled yet — which is *not* the same thing
    /// as a page that cannot scroll, so it must never end a session on its own.
    var grew: Bool { store?.grew ?? false }

    /// The whole stitch, composed on demand. O(total pixels): the finish path
    /// and the self test use this, the live preview does not.
    var image: CGImage? { store?.composed() }

    enum Outcome: Equatable {
        case first
        case appended(rows: Int)
        case stationary
        /// The frame is content the session already has: the page went back up,
        /// or it came down inside the rows that were already stitched. Nothing
        /// was appended, and — unlike `.stationary` — this is not evidence that
        /// the page stopped moving.
        case retraced
        case rejected
    }

    /// Add one sampled frame.
    ///
    /// `.stationary`/`.retraced`/`.rejected` all mean "no new rows"; they
    /// differ in *why*. `.retraced` is deliberately separate because the page
    /// is moving: counting it as stillness would let a slow scroll back up end
    /// the session as if the page had reached its bottom.
    mutating func consume(_ frame: CGImage) -> Outcome {
        frameCount += 1
        guard let store else {
            guard let created = ScrollStitchStore(frame),
                  let sampled = ScrollStitcher.SampledRaster(frame) else {
                noGrowthStreak += 1
                return .rejected
            }
            self.store = created
            previousSampled = sampled
            frameTop = 0
            noGrowthStreak = 0
            return .first
        }
        guard frame.width == store.width, frame.width > 0, frame.height > 0,
              let sampled = ScrollStitcher.SampledRaster(frame) else {
            noGrowthStreak += 1
            return .rejected
        }

        let previous = previousSampled
        previousSampled = sampled
        // Where the previous sample sat. `frameTop` is the previous sample's
        // position even when that sample was refused, so the next measured move
        // is added to the right row instead of to a stale one.
        let previousTop = frameTop
        // The match against the accumulated image, with its evidence.
        let match = ScrollStitcher.findMatch(
            existing: store.sampled,
            next: sampled,
            maxSearch: min(frame.height, store.height),
            minimumOverlap: ScrollStitcher.minimumOverlap
        )
        let rows = match?.overlap ?? 0
        let newRows = frame.height - rows
        let forward = rows >= ScrollStitcher.minimumOverlap
            && newRows >= Self.minimumNewRows
            && store.height + newRows <= ScrollStitcher.maximumOutputHeight

        // A big append means the page moved most of a screen between two
        // samples, which is exactly where a repeated screen used to slip in:
        // paper matched paper and 700 duplicated rows were appended. Confirm
        // those, and every frame that did *not* match, with the frame-to-frame
        // motion, which is independent of the stitch.
        let needsMotionCheck = !forward || newRows > frame.height / 2
        let displacement = needsMotionCheck
            ? previous.flatMap { ScrollStitcher.frameDisplacement(previous: $0, next: sampled) }
            : nil
        // A sticky header is on every frame at the same y, so it is not page
        // content and must not be compared against the stitch.
        let pinnedTop = previous.map {
            ScrollStitcher.pinnedTopRows(previous: $0, next: sampled)
        } ?? 0
        if needsMotionCheck, let displacement {
            let expectedTop = previousTop + displacement
            if displacement < 0 {
                // The page went up: these rows are above the current bottom.
                frameTop = expectedTop
                noGrowthStreak = 0
                return .retraced
            }
            if expectedTop < 0 {
                // Still above the first row this session captured.
                frameTop = expectedTop
                noGrowthStreak = 0
                return .retraced
            }
            if expectedTop + frame.height <= store.height,
               ScrollStitcher.frameMatches(
                   existing: store.sampled,
                   next: sampled,
                   top: expectedTop,
                   rows: frame.height,
                   skipTop: pinnedTop
               ) {
                // Scrolling back down through rows that are already stitched.
                frameTop = expectedTop
                noGrowthStreak = 0
                return .retraced
            }
            // The stitch's overlap and the measured move must agree before an
            // append is trusted. When they disagree, the move is the better
            // witness — it compares two adjacent screens, while the stitch
            // search can be fooled by a repeated row — so the frame is placed
            // from the move and only the rows below the stitched bottom are
            // appended, after its overlap with the stitch has been verified.
            let impliedTop = store.height - rows
            let agrees = forward
                && abs(impliedTop - expectedTop) <= max(8, frame.height / 8)
            if !agrees {
                let drop = store.height - expectedTop
                let verified = drop >= ScrollStitcher.minimumOverlap
                    && drop < frame.height
                    && ScrollStitcher.frameMatches(
                        existing: store.sampled,
                        next: sampled,
                        top: expectedTop,
                        rows: drop,
                        skipTop: pinnedTop
                    )
                if verified, let appended = store.append(frame, droppingTop: drop) {
                    lastOverlap = drop
                    frameTop = expectedTop
                    noGrowthStreak = 0
                    return .appended(rows: appended)
                }
                DebugLog.log(
                    "scroll: refused a move of \(displacement) rows "
                        + "top=\(expectedTop) stitch=\(store.height) "
                        + "overlap=\(rows) drop=\(drop) verified=\(verified)"
                )
                frameTop = expectedTop
                noGrowthStreak += 1
                return .stationary
            }
        } else if needsMotionCheck, forward, newRows > frame.height / 2 {
            // A big append with no measurable move between the two frames is a
            // contradiction: content that really overlapped the stitch was on
            // screen one sample earlier, so the move would have been visible.
            // The "overlap" is coincidental paper — ignore it.
            DebugLog.log(
                "scroll: refused a \(newRows)-row append with no measurable motion "
                    + "(overlap=\(rows))"
            )
            frameTop = previousTop
            noGrowthStreak += 1
            return .stationary
        }

        guard forward,
              let appended = store.append(frame, droppingTop: rows) else {
            frameTop = previousTop
            noGrowthStreak += 1
            return .stationary
        }
        lastOverlap = rows
        frameTop = store.height - frame.height
        noGrowthStreak = 0
        return .appended(rows: appended)
    }

    /// The viewfinder band for the current picture.
    func makePreview(size: CGSize) -> ScrollPreviewFrame? {
        store?.makePreviewFrame(size: size)
    }
}

extension ScrollAutoStitcher: @unchecked Sendable {}

/// Serial, off-main executor for one live session's pixel work.
///
/// Sampling every 0.1 s while the page is being scrolled means the stitcher
/// runs while the compositor is busy. Doing it on the main actor — as the
/// first implementation did — turns every sample into a 5–60 ms stall that
/// grows with the stitched length. Everything heavy (frame rasterisation,
/// overlap search, band composition, the final full compose) happens here, on
/// one serial queue, and only the finished `ScrollPreviewFrame` crosses back.
final class ScrollStitchWorker: @unchecked Sendable {
    struct Step: Sendable {
        let outcome: ScrollAutoStitcher.Outcome
        let frame: ScrollPreviewFrame?
        let height: Int
        let grew: Bool
        let frameCount: Int
        let lastOverlap: Int
        /// Time spent inside the overlap search + append, milliseconds.
        let stitchMilliseconds: Double
        /// Time spent composing the viewfinder band, milliseconds.
        let bandMilliseconds: Double
    }

    private let queue = DispatchQueue(
        label: "com.hexyans.unseen.scroll-stitch",
        qos: .userInitiated
    )
    private var stitcher = ScrollAutoStitcher()
    private var bandSize = CGSize(width: 240, height: 1200)

    func setBandSize(_ size: CGSize) {
        queue.sync { bandSize = size }
    }

    func reset() {
        queue.sync { stitcher = ScrollAutoStitcher() }
    }

    var currentBandSize: CGSize { queue.sync { bandSize } }

    func process(_ image: CGImage) async -> Step {
        await withCheckedContinuation { continuation in
            queue.async {
                let stitchStart = Date()
                let outcome = self.stitcher.consume(image)
                let stitchEnd = Date()
                let frame = self.stitcher.makePreview(size: self.bandSize)
                let bandEnd = Date()
                continuation.resume(returning: Step(
                    outcome: outcome,
                    frame: frame,
                    height: self.stitcher.height,
                    grew: self.stitcher.grew,
                    frameCount: self.stitcher.frameCount,
                    lastOverlap: self.stitcher.lastOverlap,
                    stitchMilliseconds: stitchEnd.timeIntervalSince(stitchStart) * 1000,
                    bandMilliseconds: bandEnd.timeIntervalSince(stitchEnd) * 1000
                ))
            }
        }
    }

    func composedImage() async -> CGImage? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.stitcher.image) }
        }
    }
}

/// Owns one scrolling-capture session.
///
/// The page moves because the *user* scrolls it (iShot's default), or because
/// the opt-in Auto Scroll posts wheel events at the region's centre. The
/// session samples the region continuously, stitches each new frame into the
/// accumulated image, and reports every sample through `onUpdate`; the overlay
/// owns the viewfinder and the controls, so this class never creates a window.
///
/// The region overlay stays on screen for the whole session (that is the point
/// of this design: the user must be able to see and adjust the box). Two
/// consequences are handled here:
///
/// * the overlay is the key window, so a wheel event posted with
///   `cghidEventTap` would land on it instead of the page — every synthetic
///   wheel is posted to the PID of the window under the region instead;
/// * the same is true of the user's own trackpad events, which the overlay
///   forwards with `forwardWheel(_:)`.
///
/// The session ends when
/// * the page has grown, then stopped moving for the stillness window that
///   matches how it is being driven (`manualStillnessLimit` /
///   `autoStillnessLimit`), *and* at least two appended frames prove it moved,
/// * a frame/height ceiling is hit,
/// * or the user asks for it (停止, Return, Escape, or the global shortcut).
///
/// A finished session is not a dead end: `resume()` restarts sampling on the
/// same stitch, so "I stopped, the page had more below" costs one click instead
/// of a fresh selection.
@MainActor
final class ScrollCaptureController {
    /// Upper bound on retained frames (≈40 s at the default interval). Beyond
    /// that the session finishes automatically rather than growing without
    /// limit.
    nonisolated static let maximumFrames = 400
    /// Sampling interval. A fast trackpad flick moves the page by ~1500 pt/s,
    /// so anything slower than ~0.15 s can move more than one screen between
    /// samples and lose the overlap the stitcher needs.
    nonisolated static let defaultInterval: TimeInterval = 0.1
    /// A **manually** scrolled page that has not moved for this long is
    /// finished. Three seconds, not one: the user reads, thinks and re-aims
    /// between flicks, and ending the session during a normal pause is what
    /// kept "长截图滑不动" alive after the event-routing fix. Two seconds is a
    /// common pause; three is deliberate.
    nonisolated static let manualStillnessLimit: TimeInterval = 3.0
    /// Auto Scroll posts a wheel every tick, so a page that stops moving is a
    /// page that has reached its end. There is no user pause to protect, so the
    /// short window stays.
    nonisolated static let autoStillnessLimit: TimeInterval = 0.9
    /// Consecutive **unchanged** frames required on top of the time window. The
    /// clock can run while nothing is being sampled; three samples of a
    /// pixel-identical page are what makes "still" an observation rather than
    /// an absence. (Rejected frames do not count — see `captureFrame`.)
    nonisolated static let stillnessFrames = 3
    /// Points scrolled per tick for the opt-in auto scroll. iShot ramps 1 px to
    /// 5 px per 16 ms; sampling a whole region needs a larger step, so the step
    /// is proportional to the region height and clamped.
    nonisolated static let minimumStep: Int32 = 60
    nonisolated static let maximumStep: Int32 = 180

    /// The sampled rectangle in global AppKit points. Mutable: the overlay's
    /// handles stay live, and a resize restarts the stitch for the new box.
    private(set) var region: CGRect
    let screen: NSScreen
    let interval: TimeInterval
    let includeCursor: Bool
    /// 设置 → 滚图 → 自动结束. Bounded below so one tick cannot produce an
    /// accidental one-frame session.
    let maxFrames: Int
    /// 辅助功能权限 is required to post wheel events for the opt-in auto scroll
    /// and to forward the user's own wheel while the overlay covers the page.
    let canAutoScroll: Bool

    var frameCount: Int { sampledFrameCount }
    private(set) var isRunning = false
    /// Final stitched image, kept for the self test and for the preview.
    private(set) var stitchedImage: CGImage?
    /// Whether the opt-in auto scroll is currently posting wheel events.
    private(set) var isAutoScrolling = false
    /// True while the stopped session is composing its final image.
    ///
    /// Sampling is already over (`isRunning == false`) but no image exists yet,
    /// so a Return / 完成 pressed in this window must wait for the compose
    /// instead of concluding that there is nothing to deliver.
    private(set) var isComposing = false
    /// The application that owns the window under the region's centre. Every
    /// wheel event is posted to it, because the overlay is the key window.
    private(set) var targetPID: pid_t?
    /// Windows pinned in front of the page that overlap the region (translate
    /// bubbles, floating cards). They are left out of every sample so they
    /// cannot defeat the overlap search.
    private(set) var auxiliaryWindowIDs: [CGWindowID] = []

    var onFinish: ((CGImage, CGFloat, Int) -> Void)?
    var onCancel: ((String?) -> Void)?
    /// One report per sample: the viewfinder band (nil before the first
    /// frame), whether the page has grown, and whether Auto Scroll is on.
    var onUpdate: ((ScrollPreviewFrame?, Bool, Bool) -> Void)?
    /// Ask the overlay to become mouse-transparent (or interactive again).
    /// While it is transparent the wheel reaches the page; the viewfinder has
    /// its own window and remains clickable.
    var onPassthrough: ((Bool) -> Void)?
    /// Every sampled frame, exactly as captured, together with what the
    /// stitcher decided about it. Used by the probe that diffs two builds; the
    /// shipping path leaves it nil.
    var onFrame: ((CGImage, ScrollAutoStitcher.Outcome, Int) -> Void)?

    /// All pixel work lives here; the main actor only receives finished bands.
    private let worker = ScrollStitchWorker()
    /// Size (points) the viewfinder wants its band composed at. The overlay
    /// sets this from the pod's well + spill; the default keeps a headless
    /// session (the probe) useful.
    private var previewBandSize = CGSize(width: 240, height: 1200)
    private var sampledFrameCount = 0
    /// Accumulated length of the stitch, in pixels. Readable so a run can be
    /// compared frame by frame (probe ledger) instead of only at the end.
    private(set) var stitchedHeight = 0
    private var pageGrew = false
    /// Frames that contributed new rows, for the stop policy. Readable so a
    /// probe ledger can show "it really did append more" after a pause.
    private(set) var appendedFrameCount = 0
    /// Consecutive samples that were pixel-identical to what was already
    /// stitched. A rejected frame (size mismatch, capture hiccup) resets it:
    /// it is not evidence that the page stopped.
    private(set) var stationaryStreak = 0
    /// Last band, so Auto Scroll toggles can re-report without a new sample.
    private var lastFrame: ScrollPreviewFrame?
    private var task: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var stopReason: StopReason?
    private var lastGrowthAt = Date()

    enum StopReason: Equatable {
        case user
        case bottomReached
        case frameLimit
        case heightLimit
    }

    init(
        region: CGRect,
        screen: NSScreen,
        interval: TimeInterval = ScrollCaptureController.defaultInterval,
        includeCursor: Bool = false,
        maxFrames: Int = ScrollCaptureController.maximumFrames,
        canAutoScroll: Bool = AXIsProcessTrusted()
    ) {
        self.region = region
        self.screen = screen
        self.interval = max(0.05, interval)
        self.includeCursor = includeCursor
        self.maxFrames = max(20, maxFrames)
        self.canAutoScroll = canAutoScroll
    }

    // MARK: - Stop policy (pure, testable)

    /// How the page is moving, which decides how long "still" has to last.
    enum ScrollDrive: Equatable {
        /// The user's own trackpad. Pauses are normal: reading, thinking,
        /// re-aiming. Ending here is what ate the rest of a long page.
        case manual
        /// The opt-in Auto Scroll. It posts a wheel every tick, so a page that
        /// stops moving has reached its end.
        case auto
    }

    nonisolated static func stillnessLimit(for drive: ScrollDrive) -> TimeInterval {
        switch drive {
        case .manual: return manualStillnessLimit
        case .auto: return autoStillnessLimit
        }
    }

    /// Frames that must have been *appended* before a still page counts as the
    /// bottom. A page that never moved is not a page that reached its end — it
    /// is a page that has not scrolled yet, and the user gets the "不可滚动"
    /// message instead of a silent one-screen result. Manual mode asks for two
    /// because a single append can be one settling repaint; Auto Scroll asks
    /// for one because every tick is a wheel and one append is real movement.
    nonisolated static func minimumAppendedFrames(for drive: ScrollDrive) -> Int {
        switch drive {
        case .manual: return 2
        case .auto: return 1
        }
    }

    /// The whole "the page has reached its bottom" decision.
    ///
    /// All three conditions are required:
    ///
    /// * **enough appended frames** — the session has to have demonstrably
    ///   scrolled before stillness can mean "the end";
    /// * **`stillnessFrames` consecutive unchanged samples** — stillness is
    ///   observed, not merely elapsed;
    /// * **the drive's stillness window** — three seconds for a hand scroll,
    ///   under one for Auto Scroll.
    nonisolated static func shouldAutoFinish(
        appendedFrames: Int,
        stationaryFrames: Int,
        drive: ScrollDrive,
        secondsSinceGrowth: TimeInterval
    ) -> Bool {
        guard appendedFrames >= minimumAppendedFrames(for: drive) else { return false }
        guard stationaryFrames >= stillnessFrames else { return false }
        return secondsSinceGrowth >= stillnessLimit(for: drive)
    }

    // MARK: - Event recipe (pure, testable)

    /// Wheel distance for one auto-scroll tick: ~16 % of the region height,
    /// clamped.
    nonisolated static func autoScrollStep(forRegionHeight height: CGFloat) -> Int32 {
        let raw = Int32((max(0, height) * 0.16).rounded())
        return min(max(raw, minimumStep), maximumStep)
    }

    /// AppKit's global bottom-left point → Quartz's top-left point. The scroll
    /// event must carry the region centre, otherwise the preview pod's own
    /// position would receive the wheel.
    nonisolated static func pointerPoint(region: CGRect, primaryScreenMaxY: CGFloat) -> CGPoint {
        CGPoint(x: region.midX, y: primaryScreenMaxY - region.midY)
    }

    /// The wheel event shape iShot posts: pixel units, one axis, negative =
    /// content scrolls down.
    nonisolated static func wheelEvent(step: Int32, at point: CGPoint) -> CGEvent? {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: -step,
            wheel2: 0,
            wheel3: 0
        ) else { return nil }
        event.location = point
        return event
    }

    /// The topmost normal window under a Quartz point: its owner and its id.
    nonisolated static func targetWindow(
        in windowInfo: [[String: Any]],
        point: CGPoint,
        ownPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> (pid: pid_t, windowID: CGWindowID)? {
        for info in windowInfo {
            guard
                let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                layer == 0,
                let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                owner != ownPID,
                let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                bounds.contains(point)
            else { continue }
            let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
            return (owner, number)
        }
        return nil
    }

    /// Pick the application that owns the topmost normal window under the
    /// region's centre. The capture overlay itself is a normal window of our
    /// own process, so it is skipped by PID.
    nonisolated static func targetPID(
        in windowInfo: [[String: Any]],
        point: CGPoint,
        ownPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> pid_t? {
        targetWindow(in: windowInfo, point: point, ownPID: ownPID)?.pid
    }

    /// Windows that sit **in front of** the page and overlap the region.
    ///
    /// A page can keep auxiliary windows pinned above itself — a translate
    /// bubble, a floating "what's new" card, a detached toolbar. They do not
    /// scroll with the page, so every candidate overlap disagrees on their rows
    /// and the session concludes the window does not scroll. Leaving them out
    /// of the capture removes the problem at the source, without touching the
    /// matcher.
    ///
    /// `windowInfo` is the front-to-back list from the window server and
    /// `region` is the Quartz (top-left) rectangle being captured.
    nonisolated static func auxiliaryWindows(
        in windowInfo: [[String: Any]],
        above pageWindowID: CGWindowID,
        region: CGRect,
        ownPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> [CGWindowID] {
        var result: [CGWindowID] = []
        for info in windowInfo {
            guard
                let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                layer == 0,
                let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
            else { continue }
            if number == pageWindowID { break }
            // Our own panels are excluded wholesale already.
            guard owner != ownPID else { continue }
            if bounds.intersects(region) { result.append(number) }
        }
        return result
    }

    /// Live window-server lookup for `targetPID(in:point:ownPID:)`.
    nonisolated static func resolveTargetPID(
        region: CGRect,
        primaryScreenMaxY: CGFloat,
        ownPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> pid_t? {
        resolveTarget(region: region, primaryScreenMaxY: primaryScreenMaxY, ownPID: ownPID)?.pid
    }

    /// The live page window plus the auxiliary windows in front of it.
    nonisolated static func resolveTarget(
        region: CGRect,
        primaryScreenMaxY: CGFloat,
        ownPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> (pid: pid_t, windowID: CGWindowID, auxiliary: [CGWindowID])? {
        let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        let point = pointerPoint(region: region, primaryScreenMaxY: primaryScreenMaxY)
        guard let target = targetWindow(in: raw, point: point, ownPID: ownPID) else {
            return nil
        }
        // Quartz top-left rectangle for the window-server bounds test.
        let quartzRegion = CGRect(
            x: region.minX,
            y: primaryScreenMaxY - region.maxY,
            width: region.width,
            height: region.height
        )
        let auxiliary = auxiliaryWindows(
            in: raw,
            above: target.windowID,
            region: quartzRegion,
            ownPID: ownPID
        )
        return (target.pid, target.windowID, auxiliary)
    }

    private func primaryScreenMaxY() -> CGFloat {
        NSScreen.screens.first?.frame.maxY
            ?? NSScreen.main?.frame.maxY
            ?? screen.frame.maxY
    }

    private func resolveTarget() {
        let target = Self.resolveTarget(
            region: region,
            primaryScreenMaxY: primaryScreenMaxY()
        )
        targetPID = target?.pid
        auxiliaryWindowIDs = target?.auxiliary ?? []
        DebugLog.log(
            "scroll: target pid=\(targetPID.map(String.init) ?? "nil") "
                + "aux=\(auxiliaryWindowIDs) region=\(NSStringFromRect(region))"
        )
    }

    /// Post one wheel event at the HID tap. The overlay is made
    /// mouse-transparent first, so the event is routed to the window under the
    /// pointer — the page — instead of being swallowed by the capture panel.
    private func post(_ event: CGEvent) {
        event.post(tap: .cghidEventTap)
    }

    /// A wheel that somehow still landed on the overlay.
    ///
    /// The session turns the panels click-through for its whole life (see
    /// `start()`), so in the shipping path nothing here should ever run. It is
    /// kept as a repair, not as the mechanism: re-assert transparency and let
    /// the *next* wheel through.
    ///
    /// The previous implementation re-posted the event at the HID tap here.
    /// That re-post is delivered to the same key window it came from, so every
    /// forwarded event produced another one 20 ms later — a self-sustaining
    /// loop (measured: 799 wheel deliveries for 16 physical ones) in which the
    /// page received almost nothing.
    func forwardWheel(_ event: NSEvent) {
        guard isRunning else { return }
        onPassthrough?(true)
        DebugLog.log(
            "scroll: wheel still hit the overlay (delta=\(event.scrollingDeltaY)) "
                + "— re-asserting click-through"
        )
    }

    private func postScrollStep() {
        guard canAutoScroll, isRunning else { return }
        let point = Self.pointerPoint(
            region: region,
            primaryScreenMaxY: primaryScreenMaxY()
        )
        let step = Self.autoScrollStep(forRegionHeight: region.height)
        guard let event = Self.wheelEvent(step: step, at: point) else { return }
        post(event)
    }

    // MARK: - Lifecycle

    /// The whole stitch, composed on the stitch queue. Used by 拷贝, which is
    /// a one-off action rather than a per-sample update.
    func snapshot() async -> CGImage? {
        await worker.composedImage()
    }

    /// Tell the session how large the viewfinder's band should be, in points.
    /// Called when the pod is placed (and again if the box is resized).
    func setPreviewBandSize(_ size: CGSize) {
        guard size.width >= 16, size.height >= 16, size != previewBandSize else { return }
        previewBandSize = size
        worker.setBandSize(size)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        worker.reset()
        worker.setBandSize(previewBandSize)
        sampledFrameCount = 0
        stitchedHeight = 0
        pageGrew = false
        appendedFrameCount = 0
        stationaryStreak = 0
        lastFrame = nil
        consecutiveFailures = 0
        stopReason = nil
        isAutoScrolling = false
        isComposing = false
        lastGrowthAt = Date()
        resolveTarget()
        // The overlay is click-through for the **whole** session, iShot's
        // `setIgnoresMouseEvents:YES`. The page underneath and the user's own
        // trackpad are then two parties that never involve us: every wheel is
        // routed straight to the window under the cursor, which is the page.
        //
        // Toggling this around individual events does not work. A panel that is
        // key re-captures the next wheel, and a re-posted copy lands back on the
        // same window, so the session ends up feeding itself instead of the
        // page. Controls live in the viewfinder's own window, so nothing the
        // user needs to click is behind the transparent panel.
        onPassthrough?(true)
        onUpdate?(nil, false, false)
        DebugLog.log(
            "scroll: start region=\(NSStringFromRect(region)) interval=\(interval) "
                + "autoScrollAvailable=\(canAutoScroll) "
                + "step=\(Self.autoScrollStep(forRegionHeight: region.height)) "
                + "manualStill=\(Self.manualStillnessLimit)s "
                + "autoStill=\(Self.autoStillnessLimit)s"
        )
        startSamplingLoop()
    }

    /// Whether a finished session can pick the page up again. The two ceilings
    /// are terminal: there is no room left to append, so offering 继续 would be
    /// a button that cannot keep its promise.
    var canResume: Bool {
        guard !isRunning, pageGrew else { return false }
        guard let stopReason else { return false }
        switch stopReason {
        case .user, .bottomReached:
            return sampledFrameCount < maxFrames
                && stitchedHeight < ScrollStitcher.maximumOutputHeight
        case .frameLimit, .heightLimit:
            return false
        }
    }

    /// Continue the same stitch after the session ended — the "I stopped too
    /// early" case.
    ///
    /// The accumulated rows are kept. The first resumed sample is matched
    /// against them exactly like any other sample: a page that has not moved
    /// resolves to a full overlap, and a page that was scrolled while the card
    /// was finished still overlaps as long as it moved less than one screen.
    /// The stop clock restarts, so a resume is never immediately finished by the
    /// stillness it just reset.
    func resume() {
        guard canResume else { return }
        isRunning = true
        stopReason = nil
        consecutiveFailures = 0
        stationaryStreak = 0
        isAutoScrolling = false
        isComposing = false
        lastGrowthAt = Date()
        resolveTarget()
        // Click-through and activation travel together again: resuming without
        // handing the wheel back to the page would restart the capture on a
        // page that cannot move (the original "滑不动").
        onPassthrough?(true)
        onUpdate?(lastFrame, pageGrew, false)
        DebugLog.log(
            "scroll: resume frames=\(sampledFrameCount) height=\(stitchedHeight) "
                + "appended=\(appendedFrameCount) target="
                + "\(targetPID.map(String.init) ?? "nil")"
        )
        startSamplingLoop()
    }

    private func startSamplingLoop() {
        task = Task { @MainActor [weak self] in
            // Give the compositor a moment before the first sample.
            try? await Task.sleep(nanoseconds: 180_000_000)
            while !Task.isCancelled {
                guard let self, self.isRunning else { return }
                let started = Date()
                await self.captureFrame()
                guard self.isRunning else { return }

                if self.sampledFrameCount >= self.maxFrames {
                    self.finish(reason: .frameLimit)
                    return
                }
                if self.stitchedHeight >= ScrollStitcher.maximumOutputHeight {
                    self.finish(reason: .heightLimit)
                    return
                }
                let still = Date().timeIntervalSince(self.lastGrowthAt)
                let drive: ScrollCaptureController.ScrollDrive =
                    self.isAutoScrolling ? .auto : .manual
                if Self.shouldAutoFinish(
                    appendedFrames: self.appendedFrameCount,
                    stationaryFrames: self.stationaryStreak,
                    drive: drive,
                    secondsSinceGrowth: still
                ) {
                    DebugLog.log(
                        String(
                            format: "scroll: still %.2fs over %d frame(s) after %d appended "
                                + "→ bottom reached (%@)",
                            still,
                            self.stationaryStreak,
                            self.appendedFrameCount,
                            drive == .auto ? "auto" : "manual"
                        )
                    )
                    self.finish(reason: .bottomReached)
                    return
                }
                if self.isAutoScrolling {
                    self.postScrollStep()
                }
                // Sampling must keep up with a fast flick: subtract the time the
                // capture itself took instead of adding the interval on top.
                let spent = Date().timeIntervalSince(started)
                let remaining = max(0.01, self.interval - spent)
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
        }
    }

    /// The overlay's handles moved or resized the box. The old rows were
    /// captured at a different origin/width, so keeping them would produce a
    /// seam; the stitch starts over while the session keeps running.
    func updateRegion(_ rect: CGRect) {
        guard rect != region, rect.width >= 1, rect.height >= 1 else { return }
        region = rect
        resolveTarget()
        worker.reset()
        sampledFrameCount = 0
        stitchedHeight = 0
        pageGrew = false
        appendedFrameCount = 0
        stationaryStreak = 0
        lastFrame = nil
        consecutiveFailures = 0
        lastGrowthAt = Date()
        onUpdate?(nil, false, isAutoScrolling)
        DebugLog.log("scroll: region changed → \(NSStringFromRect(rect)), stitch restarted")
    }

    /// Start posting wheel events for the page, iShot's "Auto Scroll".
    func startAutoScroll() {
        guard isRunning, canAutoScroll else { return }
        isAutoScrolling = true
        lastGrowthAt = Date()
        // Already transparent since `start()`. Re-asserted so a caller that
        // began a run from a non-standard path still ends up click-through.
        onPassthrough?(true)
        onUpdate?(lastFrame, pageGrew, true)
        DebugLog.log("scroll: auto scroll engaged target=\(targetPID.map(String.init) ?? "nil")")
    }

    func stopAutoScroll() {
        guard isAutoScrolling else { return }
        isAutoScrolling = false
        // Transparency belongs to the session, not to Auto Scroll: handing it
        // back here would eat the manual scroll the user reaches for next.
        onUpdate?(lastFrame, pageGrew, false)
        DebugLog.log("scroll: auto scroll released")
    }

    /// Stop sampling and stitch. Called by the 停止 button, Return, the bottom
    /// detector, or a second press of the global scroll hotkey.
    ///
    /// The full image is composed on the stitch queue, so a 20 000-pt page does
    /// not freeze the UI for the compose; `onFinish` still lands on the main
    /// actor.
    func finish(reason: StopReason = .user) {
        guard isRunning else { return }
        stopReason = reason
        isRunning = false
        isAutoScrolling = false
        onPassthrough?(false)
        task?.cancel()
        task = nil
        let count = sampledFrameCount
        DebugLog.log(
            "scroll: finish reason=\(reason) frames=\(count) "
                + "appended=\(appendedFrameCount) height=\(stitchedHeight) "
                + "resumable=\(canResume)"
        )

        guard count > 0 else {
            onCancel?("没有抓到任何画面，请再试一次。")
            return
        }
        // A page that never moved would otherwise produce a one-screen
        // "long" image and look like nothing happened.
        guard pageGrew else {
            onCancel?("没有检测到滚动：这个窗口可能不可滚动，或滚动方向不对。")
            return
        }
        isComposing = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let composed = await self.worker.composedImage()
            self.isComposing = false
            guard let image = composed else {
                self.onCancel?("拼接结果为空，请再试一次。")
                return
            }
            // A resume during the compose owns the result now; delivering this
            // image would freeze the card on a picture the session has already
            // grown past.
            guard !self.isRunning else { return }
            self.stitchedImage = image
            DebugLog.log(
                "scroll: delivered frames=\(count) "
                    + "output=\(image.width)×\(image.height) reason=\(reason)"
            )
            self.onFinish?(image, self.screen.backingScaleFactor, count)
        }
    }

    /// Discard the session. The reason is user-facing when non-nil.
    func cancel(_ reason: String? = nil) {
        guard isRunning else { return }
        let count = sampledFrameCount
        isRunning = false
        isAutoScrolling = false
        onPassthrough?(false)
        task?.cancel()
        task = nil
        DebugLog.log("scroll: cancelled after \(count) frame(s) reason=\(reason ?? "-")")
        onCancel?(reason)
    }

    /// Stop the loop without reporting anything. Used when the user closes the
    /// overlay (which already reports its own cancel) or draws a fresh box.
    func abandon() {
        guard isRunning else { return }
        isRunning = false
        isAutoScrolling = false
        onPassthrough?(false)
        task?.cancel()
        task = nil
        DebugLog.log("scroll: abandoned after \(sampledFrameCount) frame(s)")
    }

    // MARK: - Sampling

    /// Fold one stitcher result into the session's state.
    ///
    /// Split out of `captureFrame` so the stop policy can be driven with
    /// synthetic frames by the self test — the decision is about *what the
    /// stitcher saw*, and that is exactly what this function consumes.
    func record(_ step: ScrollStitchWorker.Step) {
        sampledFrameCount = step.frameCount
        stitchedHeight = step.height
        pageGrew = step.grew
        lastFrame = step.frame
        // Fed by what the stitcher actually decided, not by the clock alone: a
        // `rejected` sample (size mismatch, capture hiccup) is not evidence
        // that the page stopped, so it resets the stillness streak instead of
        // extending it.
        switch step.outcome {
        case .appended:
            appendedFrameCount += 1
            stationaryStreak = 0
            lastGrowthAt = Date()
        case .first:
            stationaryStreak = 0
            lastGrowthAt = Date()
        case .stationary:
            stationaryStreak += 1
        case .retraced:
            // The frame is content we already have — the page is moving back up
            // (or down through captured rows). Not growth, but not stillness
            // either: a session that counted it would end three seconds after
            // the user looked back up at something.
            stationaryStreak = 0
        case .rejected:
            stationaryStreak = 0
        }
    }

    private func captureFrame() async {
        guard isRunning else { return }
        do {
            let captureStart = Date()
            let shot = try await ScreenCapture.captureArea(
                region,
                on: screen,
                includeCursor: includeCursor,
                excludingOwnWindows: true,
                excludingWindowIDs: Set(auxiliaryWindowIDs)
            )
            guard isRunning else { return }
            let capturedAt = Date()
            consecutiveFailures = 0
            let step = await worker.process(shot.image)
            guard isRunning else { return }
            let mainEnd = Date()
            ScrollPerf.log(String(
                format: "frame=%d capture=%.2f stitch=%.2f band=%.2f main=%.2f rows=%d",
                step.frameCount,
                capturedAt.timeIntervalSince(captureStart) * 1000,
                step.stitchMilliseconds,
                step.bandMilliseconds,
                mainEnd.timeIntervalSince(capturedAt) * 1000,
                step.height
            ))
            record(step)
            onFrame?(shot.image, step.outcome, step.lastOverlap)
            onUpdate?(step.frame, step.grew, isAutoScrolling)
        } catch {
            consecutiveFailures += 1
            // A failed capture is a missing observation, not a still page.
            stationaryStreak = 0
            DebugLog.log(
                "scroll: capture failed (\(consecutiveFailures)): \(error.localizedDescription)"
            )
            // Transient failures happen while the page is animating; only give
            // up when nothing has worked yet.
            if sampledFrameCount == 0, consecutiveFailures >= 3 {
                let message = error.localizedDescription
                cancel("连续 3 次抓取失败：\(message)")
            }
        }
    }
}

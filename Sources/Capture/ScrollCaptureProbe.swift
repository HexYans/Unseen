import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Support hook: run one *real* scrolling capture against a rectangle of the
/// live screen.
///
///     UNSEEN_SCROLL_PROBE="x,y,w,h"      # AppKit global points
///     UNSEEN_SCROLL_PROBE_STOP=8         # seconds before 停止
///     UNSEEN_SCROLL_PROBE_AUTO=0         # do not press Auto Scroll
///     UNSEEN_SCROLL_PROBE_UI=1           # present the real overlay
///     UNSEEN_SCROLL_PROBE_OCR=1          # OCR the stitched result
///     UNSEEN_TEST_OUT=/tmp/scroll        # PNG output directory
///
/// Writes, into `UNSEEN_TEST_OUT`:
///
/// * `scroll-frame-NN.png`   — one file per sampled frame, exactly as captured,
/// * `scroll-result.png`     — the stitched image,
/// * `scroll-ui-live-N.png`  — a real screen grab of the scrolling UI
///   (veil, selection, toolbar, viewfinder) while the page moves,
/// * `scroll-ui-final.png`   — the stopped state.
///
/// and prints a one-line ledger per frame so a run can be diffed without
/// looking at the images.
/// Main-thread responsiveness probe: a 120 Hz timer that should fire every
/// 8 ms. A blocked main thread delays the tick, so the biggest gap between
/// ticks *is* the worst dropped-frame window.
@MainActor
final class MainThreadStallMonitor {
    private var timer: DispatchSourceTimer?
    private var last = Date()
    private(set) var gaps: [Double] = []
    private(set) var maxGap: Double = 0

    func start() {
        last = Date()
        gaps.removeAll()
        maxGap = 0
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(0))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date()
            let gap = now.timeIntervalSince(self.last)
            self.last = now
            self.gaps.append(gap)
            if gap > self.maxGap { self.maxGap = gap }
        }
        source.resume()
        timer = source
    }

    func stop() -> (count: Int, over20: Int, over33: Int, maxMs: Double, avgMs: Double) {
        timer?.cancel()
        timer = nil
        let values = gaps.dropFirst(2)
        let over20 = values.filter { $0 > 0.020 }.count
        let over33 = values.filter { $0 > 0.033 }.count
        let avg = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        return (values.count, over20, over33, maxGap * 1000, avg * 1000)
    }
}

enum ScrollCaptureProbe {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["UNSEEN_SCROLL_PROBE"] != nil
    }

    private static var outputDirectory: URL? {
        guard let raw = ProcessInfo.processInfo.environment["UNSEEN_TEST_OUT"],
              !raw.isEmpty else { return nil }
        let url = URL(fileURLWithPath: raw, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `x,y,w,h` in AppKit global coordinates, or `pointer` for a 400×400
    /// square centred on the pointer.
    private static func region(from raw: String) -> CGRect? {
        if raw.isEmpty || raw == "pointer" {
            let point = NSEvent.mouseLocation
            return CGRect(x: point.x - 200, y: point.y - 200, width: 400, height: 400)
        }
        let parts = raw.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    private static func writePNG(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    /// A full-screen grab **including this process's own windows**, which is
    /// exactly what the user sees (the viewfinder is meant to be seen, and the
    /// stitch excludes it separately).
    @MainActor
    private static func captureUIShot(
        screen: NSScreen,
        to out: URL?,
        name: String
    ) async {
        guard let out else { return }
        do {
            let shot = try await ScreenCapture.captureArea(
                screen.frame,
                on: screen,
                includeCursor: false,
                excludingOwnWindows: false
            )
            writePNG(shot.image, to: out.appendingPathComponent("\(name).png"))
            print("scroll-probe: ui shot \(name) \(shot.image.width)×\(shot.image.height)")
        } catch {
            print("scroll-probe: ui shot \(name) failed: \(error.localizedDescription)")
        }
    }

    static func run() -> Never {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["UNSEEN_SCROLL_PROBE"],
              let region = region(from: raw) else {
            print("scroll-probe: unreadable region; expected 'pointer' or 'x,y,w,h'")
            exit(2)
        }
        let stopAfter = Double(environment["UNSEEN_SCROLL_PROBE_STOP"] ?? "") ?? 8
        let probeInterval = Double(
            environment["UNSEEN_SCROLL_PROBE_INTERVAL"] ?? ""
        ) ?? ScrollCaptureController.defaultInterval
        let wantsUI = environment["UNSEEN_SCROLL_PROBE_UI"] == "1"
        let wantsOCR = environment["UNSEEN_SCROLL_PROBE_OCR"] == "1"
        let out = outputDirectory

        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(region) })
                ?? NSScreen.main else {
                print("scroll-probe: no screen contains \(NSStringFromRect(region))")
                exit(2)
            }
            let scale = max(screen.backingScaleFactor, 1)

            // Optionally present the *real* scrolling interface with the
            // region prefilled, so the screen shots show the actual pod.
            var overlay: CaptureOverlayController?
            var view: CaptureOverlayView?
            if wantsUI {
                let controller = CaptureOverlayController(
                    mode: .region,
                    prefilledSelection: region,
                    showCrosshair: false,
                    preferredScreen: screen,
                    includeCursor: false,
                    settings: nil,
                    autoConfirmAsScroll: true,
                    windowPickEnabled: false
                )
                controller.presentPanelsForTesting(on: screen)
                if let first = controller.overlayViewsForTesting.first {
                    first.revealToolbarForTesting()
                    first.beginScrollSessionForTesting()
                }
                controller.presentScrollPreview(for: region, on: screen)
                overlay = controller
                view = controller.overlayViewsForTesting.first
                print("scroll-probe: overlay presented panels=\(controller.overlayViewsForTesting.count)")
            }

            let controller = ScrollCaptureController(
                region: region,
                screen: screen,
                interval: probeInterval,
                includeCursor: false,
                maxFrames: 200
            )
            let stalls = MainThreadStallMonitor()
            // The probe drives the same pod callbacks the coordinator wires in
            // the shipping path, so the 停止 button can be clicked for real.
            overlay?.onScrollStop = { [weak controller] in controller?.finish() }
            overlay?.onScrollToggleAuto = { [weak controller] in
                guard let controller else { return }
                if controller.isAutoScrolling {
                    controller.stopAutoScroll()
                } else {
                    controller.startAutoScroll()
                }
            }
            // The user's own wheel reaches the overlay first; the shipping
            // path forwards it after making the panel transparent.
            overlay?.onScrollWheel = { [weak controller] event in
                controller?.forwardWheel(event)
            }
            // Same wiring as the coordinator: 继续 (or a wheel over the finished
            // card) restarts sampling on the existing stitch.
            overlay?.onScrollResume = { [weak controller] in controller?.resume() }
            print("scroll-probe: region=\(NSStringFromRect(region)) "
                + "screen=\(NSStringFromRect(screen.frame)) scale=\(scale) "
                + "autoScroll=\(controller.canAutoScroll) stop=\(stopAfter)s "
                + "ui=\(wantsUI) pid=\(getpid())")

            var frameIndex = 0
            var liveIndex = 0
            controller.onFrame = { image, outcome, overlap in
                let size = "\(image.width)×\(image.height)"
                // `height` is the accumulated stitch, so a ledger can show the
                // picture *growing* across a pause instead of only at the end.
                print("scroll-probe: frame \(frameIndex) \(size) "
                    + "outcome=\(outcome) overlap=\(overlap) "
                    + "height=\(controller.stitchedHeight) "
                    + "appended=\(controller.appendedFrameCount) "
                    + "targetPID=\(controller.targetPID.map(String.init) ?? "nil")")
                if let out {
                    writePNG(image, to: out.appendingPathComponent(
                        String(format: "scroll-frame-%02d.png", frameIndex)))
                }
                frameIndex += 1
            }
            controller.onPassthrough = { enabled in
                // The activation handoff is part of the session: without the
                // page's pid a click-through panel is skipped, and the wheel is
                // discarded. The probe mirrors the shipping wiring exactly.
                overlay?.setScrollPassthrough(enabled, targetPID: controller.targetPID)
            }
            if let view {
                controller.setPreviewBandSize(view.scrollBandSize)
                view.onScrollPreviewSizeChanged = { [weak controller] size in
                    controller?.setPreviewBandSize(size)
                }
            }
            controller.onUpdate = { preview, grew, auto in
                overlay?.updateScrollPreview(
                    preview: preview,
                    phase: .capturing,
                    autoScrolling: auto
                )
                _ = grew
            }
            // `..._KEEP=1` leaves the finished card on screen instead of
            // exiting, so an external driver can wheel over it and exercise the
            // 继续 (resume) path end to end; the second finish still exits.
            let keepAfterFinish = environment["UNSEEN_SCROLL_PROBE_KEEP"] == "1"
            var finishCount = 0
            controller.onFinish = { image, _, frameCount in
                finishCount += 1
                let report = stalls.stop()
                print("scroll-perf: main-thread gaps n=\(report.count) "
                    + "over20ms=\(report.over20) over33ms=\(report.over33) "
                    + "max=\(String(format: "%.1f", report.maxMs))ms "
                    + "avg=\(String(format: "%.2f", report.avgMs))ms")
                print("scroll-probe: finish #\(finishCount) frames=\(frameCount) "
                    + "result=\(image.width)×\(image.height)px "
                    + "=\(Int(CGFloat(image.width) / scale))×\(Int(CGFloat(image.height) / scale))pt "
                    + "resumable=\(controller.canResume)")
                if let out {
                    writePNG(image, to: out.appendingPathComponent(
                        String(format: "scroll-result-%d.png", finishCount)))
                }
                overlay?.presentScrollResult(image, resumable: controller.canResume)
                if wantsOCR {
                    let items = TextRecognition.recognize(in: image)
                    print("scroll-probe: ocr items=\(items.count)")
                    for item in items {
                        print("scroll-probe: ocr \(item.kind) \(item.text)")
                    }
                }
                if keepAfterFinish, finishCount == 1 {
                    print("scroll-probe: kept open after the first finish (resume test)")
                    return
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    await captureUIShot(
                        screen: screen,
                        to: out,
                        name: finishCount > 1 ? "scroll-ui-final-\(finishCount)" : "scroll-ui-final"
                    )
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    exit(0)
                }
            }
            controller.onCancel = { reason in
                print("scroll-probe: cancelled frames=\(frameIndex) "
                    + "reason=\(reason ?? "-")")
                overlay?.presentScrollResult(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(3) }
            }

            if ProcessInfo.processInfo.environment["UNSEEN_SCROLL_PERF"] == "1" {
                stalls.start()
            }
            controller.start()

            // Screen grabs of the live UI at three points of the run: the
            // empty/settling state, mid-stitch (visible spill), and late.
            if wantsUI {
                for (index, delay) in [0.6, 2.0, 4.5].enumerated() {
                    Task { @MainActor in
                        try? await Task.sleep(
                            nanoseconds: UInt64(delay * 1_000_000_000)
                        )
                        if controller.isRunning {
                            liveIndex += 1
                            await captureUIShot(
                                screen: screen,
                                to: out,
                                name: "scroll-ui-live-\(liveIndex)"
                            )
                        }
                    }
                }
            }

            if let clickAfter = Double(
                environment["UNSEEN_SCROLL_PROBE_CLICK_STOP"] ?? ""
            ) {
                let placement = ScrollPreviewPlacement.make(
                    region: region,
                    screen: screen.frame
                )
                // Stop button centre: card origin + footer row (8 pt) +
                // the right-hand button, using the real card width so the
                // probe keeps hitting it when the card is wider than 200 pt.
                let card = placement.card
                let buttonWidth =
                    (card.width - ScrollPreviewPod.padding * 2 - 6) / 2
                let stopPoint = CGPoint(
                    x: card.minX + ScrollPreviewPod.padding + buttonWidth + 6
                        + buttonWidth / 2,
                    y: card.minY + ScrollPreviewPod.padding
                        + ScrollPreviewPod.footerHeight / 2
                )
                let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
                let quartz = CGPoint(x: stopPoint.x, y: primaryMaxY - stopPoint.y)
                DispatchQueue.main.asyncAfter(deadline: .now() + clickAfter) {
                    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                        if let event = CGEvent(
                            mouseEventSource: nil,
                            mouseType: type,
                            mouseCursorPosition: quartz,
                            mouseButton: .left
                        ) {
                            event.post(tap: .cghidEventTap)
                        }
                    }
                    print("scroll-probe: clicked stop at \(NSStringFromPoint(stopPoint)) "
                        + "(quartz \(NSStringFromPoint(quartz)))")
                }
            }

            // Manual-mode run: the wheel is posted at the HID tap, i.e. it
            // lands on the overlay exactly like a trackpad event would, and
            // the view's forwarder has to push it to the page.
            if environment["UNSEEN_SCROLL_PROBE_MANUAL"] == "1" {
                let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
                let point = ScrollCaptureController.pointerPoint(
                    region: region,
                    primaryScreenMaxY: primaryMaxY
                )
                Task { @MainActor in
                    for index in 0..<14 {
                        try? await Task.sleep(nanoseconds: 180_000_000)
                        guard controller.isRunning else { return }
                        guard let event = ScrollCaptureController.wheelEvent(
                            step: 122,
                            at: point
                        ) else { return }
                        // A synthetic HID event posted by this process is not
                        // delivered back to our own window, so drive the view's
                        // real `scrollWheel` path with the same CGEvent. That
                        // is exactly what a trackpad event does on arrival.
                        if let view, let nsEvent = NSEvent(cgEvent: event) {
                            view.scrollWheel(with: nsEvent)
                        } else {
                            event.post(tap: .cghidEventTap)
                        }
                        if index == 0 {
                            print("scroll-probe: manual wheel delivered at \(NSStringFromPoint(point))")
                        }
                    }
                    print("scroll-probe: manual wheel run done")
                }
            }

            let pressAuto = (environment["UNSEEN_SCROLL_PROBE_AUTO"] ?? "1") != "0"
                && environment["UNSEEN_SCROLL_PROBE_MANUAL"] != "1"
            if pressAuto {
                controller.startAutoScroll()
                print("scroll-probe: auto scroll pressed")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + stopAfter) {
                if controller.isRunning {
                    print("scroll-probe: stop timer fired")
                    controller.finish(reason: .user)
                }
            }
            _ = overlay
        }
        RunLoop.main.run()
        exit(0)
    }
}

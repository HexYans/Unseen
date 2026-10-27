import AVFoundation
import AppKit
import Carbon.HIToolbox
import CoreImage
import CoreText
import QuartzCore
import SwiftUI

/// Offscreen verification for the overlay, enabled only with
/// `UNSEEN_OVERLAY_TEST=1`.
///
/// Independent groups:
/// 1. Render six selections (middle / bottom / top-left / annotated / P1b-1
///    tools / degraded mosaic) to PNG with `cacheDisplay(in:to:)`, so the mask hole, handles,
///    toolbar placement, indicator avoidance, the six P1a shapes and the
///    mosaic/text/note rendering can be inspected without the window server.
/// 2. Drive `CaptureOverlayView` with synthetic `NSEvent`s and assert the
///    resulting `(origin, size)` at every step (the P0 handle state machine).
/// 3. Drive annotation painting with synthetic events: one drag per drawing
///    tool, selection-unchanged assertions, and the "handle beats paint" /
///    "outside starts a new box" branches.
/// 4. Undo / redo, including empty stacks and redo invalidation.
/// 5. Flatten one arrow onto a known 600×400 bitmap and verify the pixels land
///    at Retina (2×) coordinates, not 1× points.
/// 6. P1b-1: inline text/note input, the toolbar actions, copy-and-keep
///    leaving the overlay intact, and a mosaic/text/note flatten whose pixels
///    are asserted (block uniformity, red glyphs, yellow bubble).
/// 7. P1b-2: counter numbering across undo, the sticker catalog and its picker
///    geometry, the note bubble's in-selection clamp, the text/field baseline
///    alignment (including a click that forces the field to be clamped), and a
///    counter + sticker + bottom-right note + text flatten whose pixels are
///    asserted (red badge with white digits, colour emoji, unclipped yellow
///    bubble).
/// 8. P3-1: recording (state machine, naming, real `SCStream` sessions at
///    full-screen and region sizes, and pause semantics read back with
///    `AVURLAsset`), the colour picker (known-colour sampling, global-point
///    mapping, off-screen clamping, clipboard formats) and the key display
///    (formatting, placement, permission degradation).
/// 9. P2-1: Vision OCR (English + Chinese), QR/barcode decoding, the empty-image
///    path, the result window's data source / read-only selectable text view /
///    400×500 cap, the save-as file-writing half (PNG bytes, dimensions, sips),
///    and the OCR toolbar action / auto-confirm entry point.
///
/// The harness lives in the product target (an AppKit view tree needs the real
/// app process), but is unreachable unless the environment variable is set.
@MainActor
enum OverlaySelfTest {
    private static let environment = ProcessInfo.processInfo.environment
    private static let canvasSize = CGSize(width: 1440, height: 900)

    private static var failures = 0
    private static var checks = 0

    static var isRequested: Bool {
        environment["UNSEEN_OVERLAY_TEST"] == "1"
    }

    @discardableResult
    static func run() async -> Int32 {
        let outputDirectory = URL(
            fileURLWithPath: environment["UNSEEN_TEST_OUT"]
                ?? "/tmp/unseen-overlay",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        print("[overlay-test] output: \(outputDirectory.path)")
        print("[overlay-test] canvas: \(Int(canvasSize.width)) × \(Int(canvasSize.height)) pt")

        // A previous run that crashed may have left suite plists behind.
        removeLeftoverTestSuites()

        // The user's own preferences must not change the harness expectations.
        AnnotationDefaults.reset()
        TextRecognitionRuntime.languages = TextRecognition.recognitionLanguages
        TextRecognitionRuntime.detectsBarcodes = true
        AppearanceRuntime.backgroundStyle = .solid

        renderScenarios(into: outputDirectory)
        runHandleTests()
        runAnnotationInteractionTests()
        runArmedWindowAnnotationTests()
        runLoupeTests(into: outputDirectory)
        runAnnotationToolShortcutTests(into: outputDirectory)
        runAnnotationHistoryTests()
        runFlattenTest(into: outputDirectory)
        runTextInputTests()
        runCopyKeepingTest()
        runFlattenToolsTest(into: outputDirectory)
        runCounterTests()
        runStickerTests()
        runNoteClampTests()
        runTextBaselineTests()
        runFlattenP1b2Test(into: outputDirectory)
        runOCRGroup(into: outputDirectory)
        runScrollStitchTests(into: outputDirectory)
        runScrollPreviewTests(into: outputDirectory)
        runScrollPreviewHeightTests(into: outputDirectory)
        runScrollShortContentTests(into: outputDirectory)
        await runScrollEscapeTests()
        runScrollToolbarClickTests()
        runPolishTests(into: outputDirectory)
        runDelayCountdownTests()
        runMultiWindowTests(into: outputDirectory)
        await runWindowPickTests(into: outputDirectory)
        runWindowHighlightStyleTests(into: outputDirectory)
        runCaptureToolbarLayoutTests(into: outputDirectory)
        runSizeChipTests(into: outputDirectory)
        runAnnotationStyleTests(into: outputDirectory)
        runWindowChromeTests()
        runSettingsArchitectureTests(into: outputDirectory)
        await runHotKeyClearEntryTests(into: outputDirectory)
        runStatusMenuShortcutTests(into: outputDirectory)
        runHotKeyListTests(into: outputDirectory)
        runHistoryHeaderWidthTests(into: outputDirectory)
        runPanelPinTests()
        runPinToolbarTests()
        runPinScrollInversionTests()
        runPinScrollZoomTests()
        runPinCommandScrollOpacityTests()
        runPanelCapsuleTests(into: outputDirectory)
        runHoverHighlightTests(into: outputDirectory)
        runPreviewPlateTests(into: outputDirectory)
        runAppearanceTopicTests()
        runGlassSurfaceTests(into: outputDirectory)
        runDarkAppearanceAudit(into: outputDirectory)
        runPresetSizeTests()
        runBeautifyTests(into: outputDirectory)
        runExportDecorationTests(into: outputDirectory)
        runCameraOverlayTests()
        runCrosshairVisibilityTests()
        runFeatureWiringTests(into: outputDirectory)
        runRecordingStateMachineTests()
        runRecordingSelectionTests(into: outputDirectory)
        runColorPickerTests(into: outputDirectory)
        runKeyDisplayTests()
        await runInstantCaptureTests(into: outputDirectory)
        await runOwnWindowCaptureTests(into: outputDirectory)
        await runRecordingGroup(into: outputDirectory)
        // Last: these two groups activate the app and move the real pointer,
        // which no earlier group may observe. The legibility probe goes second
        // so the hover group's own pointer bookkeeping is not disturbed by it.
        await runPinHoverHighlightTests(into: outputDirectory)
        await runPinPlateLegibilityTests(into: outputDirectory)

        removeLeftoverTestSuites()

        print("[overlay-test] checks=\(checks) failures=\(failures)")
        print(failures == 0 ? "[overlay-test] RESULT: PASS" : "[overlay-test] RESULT: FAIL")
        return failures == 0 ? 0 : 1
    }

    /// Sweep the preference suites this harness creates.
    ///
    /// Every scenario suite is a per-run UUID. Most tests clear their own with
    /// `removePersistentDomain`, but a few groups return early, and macOS keeps
    /// the (now empty) plist file behind even after the domain is removed — so
    /// a run would otherwise leave a handful of plists in `~/Library/Preferences`
    /// that pile up over time. The prefixes are harness-only: the app's real
    /// domain is `com.hexyans.unseen`, which matches neither.
    ///
    /// Called at the start (clears debris from a crashed earlier run) and at the
    /// end (clears this run's debris).
    private static func removeLeftoverTestSuites() {
        let preferences = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Preferences", isDirectory: true)
        guard let directory = preferences,
              let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return }
        let suffix = ".plist"
        for file in files where file.hasSuffix(suffix) {
            let domain = String(file.dropLast(suffix.count))
            guard domain.hasPrefix("Unseen") || domain.hasPrefix("unseen.selftest.") else { continue }
            UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent(file, isDirectory: false)
            )
        }
    }


    // MARK: - A. Offscreen renders

    private struct RenderScenario {
        let name: String
        let selection: CGRect
        let annotations: [Annotation]
        /// Full-screen snapshot for `.mosaic` previews. `nil` on the P0/P1a
        /// scenes, which have no mosaic.
        var baseImage: CGImage? = nil
        var imageScale: CGSize = .zero
    }

    private static func renderScenarios(into directory: URL) {
        let snapshot = makeSnapshotImage(
            width: Int(canvasSize.width) * 2,
            height: Int(canvasSize.height) * 2
        )
        let scenarios = [
            RenderScenario(
                name: "01-selection-middle",
                selection: CGRect(x: 520, y: 350, width: 400, height: 220),
                annotations: []
            ),
            RenderScenario(
                name: "02-selection-bottom",
                selection: CGRect(x: 520, y: 0, width: 400, height: 220),
                annotations: []
            ),
            RenderScenario(
                name: "03-selection-top-left",
                selection: CGRect(x: 0, y: 700, width: 360, height: 200),
                annotations: []
            ),
            RenderScenario(
                name: "04-annotations",
                selection: CGRect(x: 360, y: 220, width: 720, height: 460),
                annotations: annotationSamples
            ),
            RenderScenario(
                name: "05-tools",
                selection: CGRect(x: 360, y: 220, width: 720, height: 460),
                annotations: toolSamples,
                baseImage: snapshot,
                imageScale: CGSize(width: 2, height: 2)
            ),
            // Snapshot failure path: no base image, so the mosaic must draw the
            // translucent placeholder instead of disappearing or crashing.
            RenderScenario(
                name: "05b-mosaic-placeholder",
                selection: CGRect(x: 360, y: 220, width: 720, height: 460),
                annotations: [toolSamples[0]]
            ),
            // P1b-2: three counters and two colour emoji. Same selection as
            // 04/05 so the three renders line up pixel for pixel.
            RenderScenario(
                name: "06-counter-sticker",
                selection: CGRect(x: 360, y: 220, width: 720, height: 460),
                annotations: counterStickerSamples
            ),
            // P2-1: the OCR entry scene. "HELLO 123" sits inside the selection
            // and the toolbar must show the new OCR action next to pin.
            RenderScenario(
                name: "07-ocr",
                selection: CGRect(x: 360, y: 220, width: 720, height: 460),
                annotations: [
                    Annotation(
                        tool: .text,
                        points: [CGPoint(x: 0.10, y: 0.55), CGPoint(x: 0.10, y: 0.55)],
                        color: AnnotationTool.text.defaultColor,
                        lineWidth: 1,
                        text: "HELLO 123"
                    )
                ]
            )
        ]

        for scenario in scenarios {
            let canvas = TestCanvasView(frame: CGRect(origin: .zero, size: canvasSize))
            let overlay = CaptureOverlayView(
                frame: canvas.bounds,
                mode: .region,
                prefilledSelection: nil,
                showCrosshair: false,
                rendersOffscreen: true,
                baseImage: scenario.baseImage,
                baseImageScale: scenario.imageScale
            )
            canvas.addSubview(overlay)

            for annotation in scenario.annotations {
                overlay.addAnnotationForTesting(annotation)
            }
            overlay.applySelectionForTesting(scenario.selection)

            let selection = overlay.selectionRectForTesting
            let toolbarFrame = overlay.toolbarFrameForTesting
            let indicatorFrame = overlay.indicatorFrameForTesting
            let toolbarVisible = overlay.isToolbarVisibleForTesting
            let indicatorVisible = overlay.isIndicatorVisibleForTesting

            print("""
            [render] scenario=\(scenario.name) \
            selection=\(format(selection)) \
            toolbar=\(format(toolbarFrame)) visible=\(toolbarVisible) \
            indicator=\(format(indicatorFrame)) visible=\(indicatorVisible) \
            annotations=\(overlay.annotationCountForTesting)
            """)

            check("\(scenario.name): toolbar visible", toolbarVisible)
            check("\(scenario.name): indicator visible", indicatorVisible)
            check(
                "\(scenario.name): annotation canvas visible",
                overlay.isAnnotationCanvasVisibleForTesting
            )

            if scenario.name == "04-annotations" {
                verifyAnnotationScenario(scenario.name, overlay: overlay)
            } else if scenario.name == "05-tools" {
                verifyToolsScenario(scenario.name, overlay: overlay)
            } else if scenario.name == "06-counter-sticker" {
                verifyCounterStickerScenario(scenario.name, overlay: overlay)
            } else if scenario.name == "07-ocr" {
                verifyOCRScenario(scenario.name, overlay: overlay)
            } else if scenario.name == "05b-mosaic-placeholder" {
                check(
                    "\(scenario.name): no snapshot reaches the overlay",
                    overlay.mosaicBaseImageForTesting == nil
                )
                check(
                    "\(scenario.name): degraded mosaic annotation is stored",
                    overlay.annotationCountForTesting == 1
                        && overlay.annotationsForTesting.first?.tool == .mosaic
                )
            }

            switch scenario.name {
            case "01-selection-middle":
                check(
                    "\(scenario.name): toolbar sits below selection",
                    toolbarFrame.maxY <= selection.minY,
                    "toolbar.maxY=\(toolbarFrame.maxY) selection.minY=\(selection.minY)"
                )
            case "02-selection-bottom":
                check(
                    "\(scenario.name): toolbar flips above selection",
                    toolbarFrame.minY >= selection.maxY,
                    "toolbar.minY=\(toolbarFrame.minY) selection.maxY=\(selection.maxY)"
                )
            case "03-selection-top-left":
                check(
                    "\(scenario.name): toolbar stays below selection",
                    toolbarFrame.maxY <= selection.minY
                )
                check(
                    "\(scenario.name): size chip rides in the toolbar's left group",
                    overlay.toolbarFrameForTesting.contains(indicatorFrame)
                        && overlay.isAuxRowVisibleForTesting,
                    "indicator=\(format(indicatorFrame)) "
                        + "toolbar=\(format(overlay.toolbarFrameForTesting))"
                )
                check(
                    "\(scenario.name): indicator inside screen",
                    canvas.bounds.contains(indicatorFrame)
                )
            default:
                break
            }

            check(
                "\(scenario.name): toolbar inside screen",
                canvas.bounds.contains(toolbarFrame),
                "toolbar=\(format(toolbarFrame))"
            )

            guard let representation = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
                check("\(scenario.name): render bitmap", false)
                continue
            }
            canvas.cacheDisplay(in: canvas.bounds, to: representation)
            guard let png = representation.representation(using: .png, properties: [:]) else {
                check("\(scenario.name): encode PNG", false)
                continue
            }
            let url = directory.appendingPathComponent("\(scenario.name).png")
            do {
                try png.write(to: url)
                print(
                    "[render] wrote \(url.path) "
                    + "(\(representation.pixelsWide)×\(representation.pixelsHigh) px)"
                )
                if scenario.name.hasPrefix("04-") {
                    copyToVerification(png, named: "overlay-04-annotations.png")
                } else if scenario.name.hasPrefix("05-") {
                    copyToVerification(png, named: "overlay-05-tools.png")
                } else if scenario.name.hasPrefix("05b-") {
                    copyToVerification(png, named: "overlay-05b-placeholder.png")
                } else if scenario.name.hasPrefix("06-") {
                    copyToVerification(png, named: "overlay-06-counter-sticker.png")
                } else if scenario.name.hasPrefix("07-") {
                    copyToVerification(png, named: "overlay-07-ocr.png")
                }
            } catch {
                check("\(scenario.name): write PNG", false, error.localizedDescription)
            }
        }
    }

    /// The six programmatic samples for `04-annotations`. Distinct colours and
    /// widths so the render makes each shape obvious at a glance.
    private static var annotationSamples: [Annotation] {
        [
            Annotation(
                tool: .arrow,
                points: [CGPoint(x: 0.06, y: 0.10), CGPoint(x: 0.30, y: 0.30)],
                color: NSColor(srgbRed: 0.93, green: 0.20, blue: 0.22, alpha: 1),
                lineWidth: 3
            ),
            Annotation(
                tool: .rectangle,
                points: [CGPoint(x: 0.36, y: 0.08), CGPoint(x: 0.60, y: 0.28)],
                color: NSColor(srgbRed: 0.13, green: 0.70, blue: 0.38, alpha: 1),
                lineWidth: 3
            ),
            Annotation(
                tool: .ellipse,
                points: [CGPoint(x: 0.66, y: 0.08), CGPoint(x: 0.92, y: 0.30)],
                color: NSColor(srgbRed: 0.16, green: 0.47, blue: 0.96, alpha: 1),
                lineWidth: 3
            ),
            Annotation(
                tool: .line,
                points: [CGPoint(x: 0.07, y: 0.46), CGPoint(x: 0.40, y: 0.58)],
                color: NSColor(srgbRed: 0.98, green: 0.62, blue: 0.10, alpha: 1),
                lineWidth: 3
            ),
            Annotation(
                tool: .pencil,
                points: [
                    CGPoint(x: 0.48, y: 0.44),
                    CGPoint(x: 0.53, y: 0.54),
                    CGPoint(x: 0.58, y: 0.42),
                    CGPoint(x: 0.63, y: 0.56),
                    CGPoint(x: 0.68, y: 0.44),
                    CGPoint(x: 0.73, y: 0.54)
                ],
                color: NSColor(srgbRed: 0.85, green: 0.20, blue: 0.75, alpha: 1),
                lineWidth: 2.5
            ),
            Annotation(
                tool: .highlighter,
                points: [
                    CGPoint(x: 0.08, y: 0.73),
                    CGPoint(x: 0.30, y: 0.76),
                    CGPoint(x: 0.55, y: 0.80),
                    CGPoint(x: 0.80, y: 0.83),
                    CGPoint(x: 0.93, y: 0.86)
                ],
                color: NSColor(srgbRed: 1.00, green: 0.90, blue: 0.15, alpha: 1),
                lineWidth: 2.5
            )
        ]
    }

    /// P1b-1 samples: one mosaic over the snapshot, one text, one note. The
    /// selection is the same 720×460 box as `04`, so the two renders can be
    /// compared side by side.
    private static var toolSamples: [Annotation] {
        [
            Annotation(
                tool: .mosaic,
                points: [CGPoint(x: 0.08, y: 0.54), CGPoint(x: 0.42, y: 0.86)],
                color: AnnotationTool.mosaic.defaultColor,
                lineWidth: 0
            ),
            Annotation(
                tool: .text,
                points: [CGPoint(x: 0.52, y: 0.10), CGPoint(x: 0.52, y: 0.10)],
                color: AnnotationTool.text.defaultColor,
                lineWidth: 1,
                text: "马赛克 + 文字 Text"
            ),
            Annotation(
                tool: .note,
                points: [CGPoint(x: 0.52, y: 0.50), CGPoint(x: 0.52, y: 0.50)],
                color: AnnotationTool.note.defaultColor,
                lineWidth: 1,
                text: "便签：这里是备注"
            )
        ]
    }

    private static func verifyToolsScenario(_ name: String, overlay: CaptureOverlayView) {
        check(
            "\(name): three P1b-1 annotations stored",
            overlay.annotationCountForTesting == 3,
            "count=\(overlay.annotationCountForTesting)"
        )
        let tools = Set(overlay.annotationsForTesting.map(\.tool))
        check(
            "\(name): mosaic, text and note present",
            tools == [.mosaic, .text, .note],
            "tools=\(tools.map(\.rawValue).sorted())"
        )
        check(
            "\(name): snapshot reached the overlay",
            overlay.mosaicBaseImageForTesting != nil
        )
        check(
            "\(name): snapshot scale is 2×",
            abs(overlay.mosaicImageScaleForTesting.width - 2) < 0.01
                && abs(overlay.mosaicImageScaleForTesting.height - 2) < 0.01,
            "scale=\(overlay.mosaicImageScaleForTesting)"
        )

        let mosaic = overlay.annotationsForTesting.first { $0.tool == .mosaic }
        check(
            "\(name): mosaic has a two-corner rectangle",
            mosaic?.points.count == 2,
            "points=\(mosaic?.points.count ?? 0)"
        )
        if let mosaic {
            let box = mosaic.boundingRectNormalized
            check(
                "\(name): mosaic box is non-empty and inside 0…1",
                box.width > 0.1 && box.height > 0.1
                    && box.minX >= 0 && box.maxX <= 1
                    && box.minY >= 0 && box.maxY <= 1,
                "box=\(format(box))"
            )
        }

        let text = overlay.annotationsForTesting.first { $0.tool == .text }
        check(
            "\(name): text payload stored",
            text?.text == "马赛克 + 文字 Text",
            "text=\(text?.text ?? "nil")"
        )
        let note = overlay.annotationsForTesting.first { $0.tool == .note }
        check(
            "\(name): note payload stored",
            note?.text == "便签：这里是备注",
            "text=\(note?.text ?? "nil")"
        )
        check(
            "\(name): note uses the dark sticky-note ink",
            note?.color == AnnotationTool.note.defaultColor
        )
    }

    /// P1b-2 samples: badges 1/2/3 in a row plus two different colour emoji.
    /// The emoji are far enough apart (and from the badges) that the render is
    /// unambiguous at a glance.
    private static var counterStickerSamples: [Annotation] {
        let badge = { (number: Int, x: CGFloat) in
            Annotation(
                tool: .counter,
                points: [CGPoint(x: x, y: 0.16), CGPoint(x: x, y: 0.16)],
                color: AnnotationTool.counter.defaultColor,
                lineWidth: 0,
                text: String(number)
            )
        }
        return [
            badge(1, 0.10),
            badge(2, 0.24),
            badge(3, 0.38),
            Annotation(
                tool: .sticker,
                points: [CGPoint(x: 0.63, y: 0.22), CGPoint(x: 0.63, y: 0.22)],
                color: AnnotationTool.sticker.defaultColor,
                lineWidth: 0,
                text: "😀"
            ),
            Annotation(
                tool: .sticker,
                points: [CGPoint(x: 0.85, y: 0.44), CGPoint(x: 0.85, y: 0.44)],
                color: AnnotationTool.sticker.defaultColor,
                lineWidth: 0,
                text: "🌈"
            )
        ]
    }

    private static func verifyCounterStickerScenario(
        _ name: String,
        overlay: CaptureOverlayView
    ) {
        let stored = overlay.annotationsForTesting
        check(
            "\(name): five annotations stored",
            stored.count == 5,
            "count=\(stored.count)"
        )
        let counters = stored.filter { $0.tool == .counter }
        let stickers = stored.filter { $0.tool == .sticker }
        check(
            "\(name): three counters and two stickers",
            counters.count == 3 && stickers.count == 2,
            "counters=\(counters.count) stickers=\(stickers.count)"
        )
        check(
            "\(name): counter numbers are 1 / 2 / 3",
            counters.compactMap(\.counterValue) == [1, 2, 3],
            "values=\(counters.compactMap(\.counterValue))"
        )
        check(
            "\(name): sticker payloads are two different emoji",
            Set(stickers.compactMap(\.text)) == Set(["😀", "🌈"]),
            "texts=\(stickers.compactMap(\.text))"
        )

        let renderSize = overlay.selectionRectForTesting.size
        for counter in counters {
            guard let anchor = AnnotationRenderer.anchorPoint(counter, renderSize: renderSize) else {
                check("\(name): counter anchor resolves", false)
                continue
            }
            let badge = AnnotationRenderer.counterRect(anchor: anchor, renderSize: renderSize)
            check(
                "\(name): counter \(counter.counterValue ?? -1) badge is 26 pt",
                abs(badge.width - AnnotationRenderer.counterDiameter) < 0.01
                    && abs(badge.height - AnnotationRenderer.counterDiameter) < 0.01,
                "badge=\(format(badge))"
            )
            check(
                "\(name): counter \(counter.counterValue ?? -1) badge is inside the selection",
                inside(badge, renderSize),
                "badge=\(format(badge)) render=\(renderSize)"
            )
        }
        for sticker in stickers {
            guard let rect = AnnotationRenderer.stickerRect(
                sticker,
                renderSize: renderSize
            ) else {
                check("\(name): sticker rect resolves", false)
                continue
            }
            check(
                "\(name): sticker \(sticker.text ?? "?") is inside the selection",
                inside(rect, renderSize),
                "rect=\(format(rect)) render=\(renderSize)"
            )
        }
    }

    /// P2-1 scene: a text annotation inside the selection plus the OCR action
    /// in the toolbar. Recognition itself is covered by `runOCRGroup`.
    private static func verifyOCRScenario(_ name: String, overlay: CaptureOverlayView) {
        let annotations = overlay.annotationsForTesting
        check(
            "\(name): HELLO 123 text annotation stored",
            annotations.count == 1
                && annotations[0].tool == .text
                && annotations[0].text?.contains("HELLO") == true,
            "annotations=\(annotations.map { "\($0.tool.rawValue):\($0.text ?? "-")" })"
        )

        let actionFrames = overlay.toolbarButtonFramesForTesting()
        check(
            "\(name): toolbar exposes the OCR action",
            actionFrames.contains { $0.action == .ocr },
            "actions=\(actionFrames.map(\.action.rawValue))"
        )
        guard let ocrFrame = actionFrames.first(where: { $0.action == .ocr })?.frame else {
            check("\(name): OCR button frame resolves", false)
            return
        }
        let hit = overlay.hitTest(CGPoint(x: ocrFrame.midX, y: ocrFrame.midY))
        check(
            "\(name): OCR button receives its own clicks",
            (hit as? CaptureToolbarButton)?.toolbarAction == .ocr,
            "hit=\(String(describing: hit.map { type(of: $0) }))"
        )
        check(
            "\(name): OCR sits after pin and before cancel",
            CaptureToolbarAction.allCases == [
                .copyKeeping, .copyClosing, .save, .saveAs, .pin, .ocr, .cancel, .record
            ],
            "order=\(CaptureToolbarAction.allCases.map(\.rawValue))"
        )
        check(
            "\(name): twelve tools / two history / six glyph actions",
            overlay.toolbarToolFramesForTesting().count == 12
                && overlay.toolbarHistoryFramesForTesting().count == 2
                && actionFrames.count == 6,
            "tools=\(overlay.toolbarToolFramesForTesting().count) "
                + "history=\(overlay.toolbarHistoryFramesForTesting().count) "
                + "actions=\(actionFrames.count)"
        )
        check(
            "\(name): 另存为 moved into the ⋯ menu",
            overlay.toolbarMoreMenuTitlesForTesting.contains("另存为…")
                && !actionFrames.contains { $0.action == .saveAs },
            "menu=\(overlay.toolbarMoreMenuTitlesForTesting) "
                + "actions=\(actionFrames.map(\.action.rawValue))"
        )
    }

    private static func verifyAnnotationScenario(_ name: String, overlay: CaptureOverlayView) {
        check(
            "\(name): six annotations stored",
            overlay.annotationCountForTesting == 6,
            "count=\(overlay.annotationCountForTesting)"
        )
        let tools = Set(overlay.annotationsForTesting.map(\.tool))
        let expected: Set<AnnotationTool> = [
            .arrow, .rectangle, .ellipse, .line, .pencil, .highlighter
        ]
        check(
            "\(name): every P1a drawing tool present",
            tools == expected,
            "tools=\(tools.map(\.rawValue).sorted())"
        )
        check(
            "\(name): annotation canvas matches overlay bounds",
            overlay.annotationCanvasFrameForTesting.size == canvasSize,
            "frame=\(format(overlay.annotationCanvasFrameForTesting))"
        )
        check(
            "\(name): annotations stay inside 0…1",
            overlay.annotationsForTesting.allSatisfy { annotation in
                annotation.points.allSatisfy {
                    $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1
                }
            }
        )

        if let highlighter = overlay.annotationsForTesting.first(where: { $0.tool == .highlighter }),
           let pencil = overlay.annotationsForTesting.first(where: { $0.tool == .pencil }) {
            check(
                "\(name): highlighter is 4× pencil width",
                abs(highlighter.effectiveLineWidth - pencil.effectiveLineWidth * 4) < 0.01,
                "highlighter=\(highlighter.effectiveLineWidth) pencil=\(pencil.effectiveLineWidth)"
            )
            check(
                "\(name): highlighter translucent",
                highlighter.effectiveAlpha > 0 && highlighter.effectiveAlpha <= 0.5,
                "alpha=\(highlighter.effectiveAlpha)"
            )
        } else {
            check("\(name): highlighter and pencil present", false)
        }

        // Selecting a tool must not disturb the stored annotations.
        overlay.selectToolForTesting(.highlighter)
        check(
            "\(name): tool row highlights the active tool",
            overlay.currentToolForTesting == .highlighter,
            "tool=\(overlay.currentToolForTesting.rawValue)"
        )
        check(
            "\(name): selecting a tool keeps annotations",
            overlay.annotationCountForTesting == 6
        )
    }

    // MARK: - B. Synthetic handle events (P0 regression)

    private static func runHandleTests() {
        let bounds = CGRect(origin: .zero, size: canvasSize)
        let overlay = CaptureOverlayView(
            frame: bounds,
            mode: .region,
            prefilledSelection: nil,
            showCrosshair: false,
            rendersOffscreen: true
        )

        func drag(from start: CGPoint, to end: CGPoint) {
            overlay.mouseDown(with: event(.leftMouseDown, at: start))
            overlay.mouseDragged(with: event(.leftMouseDragged, at: end))
            overlay.mouseUp(with: event(.leftMouseUp, at: end))
        }

        // 1. Fresh selection.
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 300))
        expect(
            "create (100,100)->(400,300)",
            overlay.selectionRectForTesting,
            CGRect(x: 100, y: 100, width: 300, height: 200)
        )

        // 2. Bottom-right corner: both axes grow, origin stays.
        drag(from: CGPoint(x: 400, y: 300), to: CGPoint(x: 500, y: 400))
        expect(
            "bottom-right handle ->(500,400)",
            overlay.selectionRectForTesting,
            CGRect(x: 100, y: 100, width: 400, height: 300)
        )

        // 3. Left edge midpoint: only x / width move.
        drag(from: CGPoint(x: 100, y: 250), to: CGPoint(x: 200, y: 260))
        expect(
            "left-middle handle ->(200,260)",
            overlay.selectionRectForTesting,
            CGRect(x: 200, y: 100, width: 300, height: 300)
        )

        // 4. Inside: translate without resizing.
        drag(from: CGPoint(x: 300, y: 250), to: CGPoint(x: 350, y: 280))
        expect(
            "move inside by (50,30)",
            overlay.selectionRectForTesting,
            CGRect(x: 250, y: 130, width: 300, height: 300)
        )

        // 5. Shrink below the minimum: clamp at 40×40, never flip.
        drag(from: CGPoint(x: 550, y: 430), to: CGPoint(x: 251, y: 131))
        expect(
            "top-right shrink clamps",
            overlay.selectionRectForTesting,
            CGRect(x: 250, y: 130, width: 40, height: 40)
        )

        // 6. New box past the screen edge is clamped inside.
        drag(from: CGPoint(x: 1200, y: 800), to: CGPoint(x: 1600, y: 1000))
        expect(
            "new box clamped to screen",
            overlay.selectionRectForTesting,
            CGRect(x: 1200, y: 800, width: 240, height: 100)
        )

        // 7. Toolbar clicks must land on a toolbar button, not the overlay
        //    root — otherwise a toolbar click would start a new selection.
        overlay.applySelectionForTesting(CGRect(x: 520, y: 350, width: 400, height: 220))
        guard let copyFrame = overlay.toolbarButtonFramesForTesting()
            .first(where: { $0.action == .copyClosing })?.frame
        else {
            check("toolbar copy-close button exists", false)
            return
        }
        let buttonPoint = CGPoint(x: copyFrame.midX, y: copyFrame.midY)
        let hit = overlay.hitTest(buttonPoint)
        check(
            "toolbar click hit-tests to the copy-close button",
            (hit as? CaptureToolbarButton)?.toolbarAction == .copyClosing,
            "hit=\(String(describing: hit.map { type(of: $0) }))"
        )

        // Every one of the seven actions must claim its own rect and report its
        // own id; the earlier bug had the last subview swallowing all four.
        let actionFrames = overlay.toolbarButtonFramesForTesting()
        check(
            "toolbar exposes six action glyphs plus the ⋯ menu",
            actionFrames.count == 6
                && overlay.toolbarMoreMenuTitlesForTesting.contains("另存为…"),
            "count=\(actionFrames.count) menu=\(overlay.toolbarMoreMenuTitlesForTesting)"
        )
        let expectedActions = Set(CaptureToolbarAction.allCases)
            .subtracting([.saveAs, .record])
        check(
            "toolbar action ids are copy-keep / copy-close / save / OCR / pin / cancel",
            Set(actionFrames.map(\.action)) == expectedActions,
            "actions=\(actionFrames.map(\.action.rawValue))"
        )
        check(
            "toolbar action order ends in the pinned tail: pin then cancel",
            actionFrames.map(\.action) == [
                .copyKeeping, .copyClosing, .save, .ocr, .pin, .cancel
            ],
            "order=\(actionFrames.map(\.action.rawValue))"
        )
        for item in actionFrames {
            let point = CGPoint(x: item.frame.midX, y: item.frame.midY)
            let target = overlay.hitTest(point) as? CaptureToolbarButton
            check(
                "toolbar action hit \(item.action.rawValue)",
                target?.toolbarAction == item.action,
                "expected=\(item.action.rawValue) "
                + "got=\(target.map { $0.toolbarAction.rawValue } ?? "nil")"
            )
        }

        // The strip got two groups wider; it must still fit the screen.
        check(
            "toolbar width fits the render canvas",
            CaptureToolbarView.width <= canvasSize.width - 16,
            "width=\(number(CaptureToolbarView.width)) canvas=\(number(canvasSize.width))"
        )

        // The twelve tool buttons and the two history buttons must be present,
        // non-overlapping, and hit-test to themselves.
        let toolFrames = overlay.toolbarToolFramesForTesting()
        check("toolbar exposes twelve tools", toolFrames.count == 12, "count=\(toolFrames.count)")
        check(
            "toolbar tool ids include mosaic / text / note / counter / sticker",
            Set(toolFrames.map(\.tool)).isSuperset(
                of: [.mosaic, .text, .note, .counter, .sticker]
            ),
            "tools=\(toolFrames.map(\.tool.rawValue))"
        )
        check(
            "toolbar puts counter after note and sticker after counter",
            toolFrames.map(\.tool) == AnnotationTool.allCases,
            "order=\(toolFrames.map(\.tool.rawValue))"
        )
        for item in toolFrames {
            let point = CGPoint(x: item.frame.midX, y: item.frame.midY)
            let target = overlay.hitTest(point) as? CaptureToolbarToolButton
            check(
                "toolbar tool hit \(item.tool.rawValue)",
                target?.tool == item.tool,
                "expected=\(item.tool.rawValue) got=\(target.map { $0.tool.rawValue } ?? "nil")"
            )
        }
        let historyFrames = overlay.toolbarHistoryFramesForTesting()
        check("toolbar exposes undo and redo", historyFrames.count == 2)
        for item in historyFrames {
            let point = CGPoint(x: item.frame.midX, y: item.frame.midY)
            let target = overlay.hitTest(point) as? CaptureToolbarHistoryButton
            check(
                "toolbar history \(item.isRedo ? "redo" : "undo") disabled while empty",
                target == nil,
                "hit=\(String(describing: target.map { $0.isRedo ? "redo" : "undo" }))"
            )
        }

        // Default tool is move, with both history buttons disabled.
        check(
            "default tool is move",
            overlay.currentToolForTesting == .move,
            "tool=\(overlay.currentToolForTesting.rawValue)"
        )
        check("default undo disabled", !overlay.isUndoEnabledForTesting)
        check("default redo disabled", !overlay.isRedoEnabledForTesting)
    }

    // MARK: - C2. Annotation tool shortcuts (overlay-local, settings-driven)

    /// The twelve 设置 → 快捷键 → 标注工具 rows are matched by the overlay's
    /// own `keyDown`, never by Carbon. These checks drive the real view with
    /// synthetic events and prove both halves of the contract:
    ///
    /// * the shipped ⌘2 selects 箭头;
    /// * a bare `1` still reaches the aspect-ratio lock (the tool layer does
    ///   not steal the digits);
    /// * rebinding 铅笔 to ⌥P makes ⌥P select it;
    /// * clearing the slot removes the shortcut while leaving the current tool
    ///   alone.
    private static func runAnnotationToolShortcutTests(into directory: URL) {
        let suiteName = "UnseenToolHotKey-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            check("tool hotkey: isolated defaults", false)
            return
        }
        let settings = AppSettings(defaults: defaults)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let overlay = makeOverlay(settings: settings)
        overlay.applySelectionForTesting(CGRect(x: 200, y: 200, width: 400, height: 300))

        overlay.keyDown(with: keyEvent(
            keyCode: UInt16(kVK_ANSI_2),
            modifiers: .command,
            characters: "2"
        ))
        check(
            "tool hotkey: the shipped ⌘2 selects 箭头",
            overlay.currentToolForTesting == .arrow,
            "tool=\(overlay.currentToolForTesting.rawValue)"
        )

        // The tool layer must not consume the bare digit: it is the aspect lock.
        overlay.keyDown(with: digitEvent(1))
        check(
            "tool hotkey: bare 1 still locks 1:1 (the tools use ⌘1…⌘=)",
            overlay.lockedAspectForTesting == 1
                && overlay.currentToolForTesting == .arrow,
            "ratio=\(String(describing: overlay.lockedAspectForTesting)) "
                + "tool=\(overlay.currentToolForTesting.rawValue)"
        )

        // Rebind 铅笔 to ⌥P and drive that combination.
        settings.setAnnotationToolConfiguration(
            HotKeyConfiguration(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(optionKey)),
            for: .pencil
        )
        overlay.keyDown(with: keyEvent(keyCode: UInt16(kVK_ANSI_P), modifiers: .option))
        check(
            "tool hotkey: a rebound ⌥P selects 铅笔",
            overlay.currentToolForTesting == .pencil,
            "tool=\(overlay.currentToolForTesting.rawValue)"
        )

        // Clearing the slot removes the shortcut; the current tool stays put.
        settings.setAnnotationToolConfiguration(.unbound, for: .pencil)
        overlay.keyDown(with: keyEvent(
            keyCode: UInt16(kVK_ANSI_2),
            modifiers: .command,
            characters: "2"
        ))
        overlay.keyDown(with: keyEvent(keyCode: UInt16(kVK_ANSI_P), modifiers: .option))
        check(
            "tool hotkey: a cleared slot no longer switches tools",
            overlay.currentToolForTesting == .arrow,
            "tool=\(overlay.currentToolForTesting.rawValue)"
        )

        // Re-adding the shipped default through the 默认 path reads back.
        settings.resetAnnotationToolHotKeys()
        overlay.keyDown(with: keyEvent(
            keyCode: UInt16(kVK_ANSI_6),
            modifiers: .command,
            characters: "6"
        ))
        check(
            "tool hotkey: 默认 restores ⌘6 for 铅笔",
            overlay.currentToolForTesting == .pencil
                && settings.annotationToolConfiguration(.pencil)
                    == HotKeyConfiguration.annotationTool(.pencil),
            "tool=\(overlay.currentToolForTesting.rawValue) "
                + "config=\(settings.annotationToolConfiguration(.pencil).displayString)"
        )

        // Visual proof: a real overlay whose tool row has 箭头 selected after
        // the synthetic ⌘2 above. The toolbar's selection chip is the state the
        // user sees, not just the private `currentTool`.
        let shot = makeOverlay(settings: settings)
        shot.applySelectionForTesting(CGRect(x: 360, y: 240, width: 720, height: 440))
        shot.keyDown(with: keyEvent(
            keyCode: UInt16(kVK_ANSI_2),
            modifiers: .command,
            characters: "2"
        ))
        let canvas = TestCanvasView(frame: CGRect(origin: .zero, size: canvasSize))
        canvas.addSubview(shot)
        shot.layoutSubtreeIfNeeded()
        shot.displayIfNeeded()
        if let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) {
            canvas.cacheDisplay(in: canvas.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                let url = directory.appendingPathComponent("annotation-tool-hotkey-arrow.png")
                try? png.write(to: url)
                print("[tool-hotkey] wrote \(url.path)")
                check(
                    "tool hotkey: the overlay renders with 箭头 selected",
                    png.count > 10_000 && shot.currentToolForTesting == .arrow,
                    "bytes=\(png.count) tool=\(shot.currentToolForTesting.rawValue)"
                )
            }
        }
    }

    // MARK: - C2. Drawing on a single-click (armed) window

    /// A single click on a window arms it: the window's rect becomes the
    /// selection (veil hole, border, size chip and the complete annotation
    /// toolbar), and a second click captures it.
    ///
    /// Painting on that state used to be silently impossible. `mouseDragged`
    /// dropped `armedWindowPick` before it looked at `isPainting`, and that
    /// pick was the *only* source of `committedRect` here — so the stroke's
    /// every tick failed its `guard let rect = committedRect`, and mouse-up
    /// had nothing to commit. From the user's side: pick 矩形, drag, nothing.
    private static func runArmedWindowAnnotationTests() {
        print("[armed-anno] --- painting on a single-click window selection ---")
        let canvas = TestCanvasView(frame: CGRect(origin: .zero, size: canvasSize))
        let overlay = CaptureOverlayView(
            frame: canvas.bounds,
            mode: .region,
            prefilledSelection: nil,
            showCrosshair: true,
            rendersOffscreen: true
        )
        canvas.addSubview(overlay)
        let windowRect = CGRect(x: 300, y: 300, width: 600, height: 400)
        overlay.setWindowPickCandidatesForTesting([
            WindowCandidate(
                windowNumber: 5150,
                bounds: windowRect,
                layer: 0,
                ownerPID: 1,
                ownerName: "Fixture",
                windowName: "Fixture",
                isOwnedBySelf: false
            )
        ])

        click(overlay, at: CGPoint(x: windowRect.midX, y: windowRect.midY))
        check(
            "armed-anno: one click arms the window as the selection",
            overlay.armedWindowIDForTesting == 5150
                && overlay.committedRectForTesting == windowRect,
            "armed=\(String(describing: overlay.armedWindowIDForTesting)) "
                + "committed=\(String(describing: overlay.committedRectForTesting))"
        )

        overlay.selectToolForTesting(.rectangle)
        stroke(overlay, points: [
            CGPoint(x: 400, y: 420),
            CGPoint(x: 700, y: 620)
        ])
        check(
            "armed-anno: a drawing tool paints on the armed window",
            overlay.annotationCountForTesting == 1
                && overlay.annotationsForTesting.last?.tool == .rectangle,
            "count=\(overlay.annotationCountForTesting) "
                + "tool=\(overlay.annotationsForTesting.last?.tool.rawValue ?? "nil")"
        )
        check(
            "armed-anno: painting keeps the window armed and its rect committed",
            overlay.armedWindowIDForTesting == 5150
                && overlay.committedRectForTesting == windowRect,
            "armed=\(String(describing: overlay.armedWindowIDForTesting)) "
                + "committed=\(String(describing: overlay.committedRectForTesting))"
        )

        var confirmed: (rect: CGRect, annotations: [Annotation], action: CaptureToolbarAction)?
        overlay.onConfirm = { rect, annotations, action in
            confirmed = (rect, annotations, action)
        }
        overlay.keyDown(with: keyEvent(
            keyCode: UInt16(kVK_Return),
            modifiers: [],
            characters: "\r"
        ))
        check(
            "armed-anno: Return captures the window with the drawing included",
            confirmed?.rect == windowRect
                && confirmed?.annotations.count == 1
                && confirmed?.action == .copyClosing,
            "rect=\(String(describing: confirmed?.rect)) "
                + "annotations=\(confirmed?.annotations.count ?? -1) "
                + "action=\(String(describing: confirmed?.action))"
        )
    }

    // MARK: - C3. The loupe

    /// The magnifier is a tracking aid: while the crosshair follows the pointer
    /// it samples the pre-overlay snapshot at 4×, and it disappears as soon as
    /// the cross freezes. These checks pin the geometry (offset right/below,
    /// flip at the edges, never over the cursor), the mapping from view point to
    /// snapshot pixel, and the visibility rules.
    private static func runLoupeTests(into directory: URL) {
        print("[loupe] --- the magnifier beside the pointer ---")
        let bounds = CGRect(origin: .zero, size: canvasSize)
        // The confetti frame is the harness's stand-in for a dense screenshot:
        // tiny 2–8 px marks. At 4× the card's blocks are visibly four times the
        // background's, which is exactly what a loupe is for.
        guard let snapshot = makeConfettiImage(
            width: Int(canvasSize.width) * 2,
            height: Int(canvasSize.height) * 2
        ) else {
            check("loupe: build the snapshot", false)
            return
        }
        let scale = CGSize(width: 2, height: 2)

        let canvas = TestCanvasView(frame: bounds)
        let overlay = CaptureOverlayView(
            frame: bounds,
            mode: .region,
            prefilledSelection: nil,
            showCrosshair: true,
            rendersOffscreen: true,
            baseImage: snapshot,
            baseImageScale: scale
        )
        canvas.addSubview(overlay)
        // No real window stack in this group: an empty injected list keeps the
        // hover highlight (and its hint capsule) out of the loupe's render.
        overlay.setWindowPickCandidatesForTesting([])
        overlay.setLoupeImageForTesting(snapshot, scale: scale)

        check(
            "loupe: on by default",
            overlay.isLoupeEnabledForTesting,
            "enabled=\(overlay.isLoupeEnabledForTesting)"
        )

        let point = CGPoint(x: 620, y: 430)
        overlay.mouseMoved(with: event(.mouseMoved, at: point))
        overlay.layoutSubtreeIfNeeded()
        let card = overlay.loupeFrameForTesting
        check(
            "loupe: a square card follows the pointer",
            overlay.isLoupeVisibleForTesting
                && overlay.loupePointForTesting == point
                && card.width == LoupeView.side
                && card.height == LoupeView.side
                && card.width == card.height,
            "visible=\(overlay.isLoupeVisibleForTesting) card=\(format(card)) point="
                + "\(String(describing: overlay.loupePointForTesting))"
        )
        check(
            "loupe: it sits beside the cursor without covering it",
            card.minX > point.x
                && card.maxY < point.y
                && !card.contains(point)
                && bounds.contains(card),
            "card=\(format(card)) point=\(number(point.x)),\(number(point.y))"
        )
        // 4× means the card shows side/zoom points around the cursor, centred
        // on the pointer in snapshot pixels.
        let source = overlay.loupeSourceRectForTesting
        let expectedSource = CGRect(
            x: point.x * 2 - (LoupeView.side / LoupeView.zoom),
            y: (bounds.height - point.y) * 2 - (LoupeView.side / LoupeView.zoom),
            width: (LoupeView.side / LoupeView.zoom) * 2,
            height: (LoupeView.side / LoupeView.zoom) * 2
        )
        check(
            "loupe: the source rect is centred on the pointer at 4×",
            abs(source.midX - expectedSource.midX) < 0.5
                && abs(source.midY - expectedSource.midY) < 0.5
                && abs(source.width - expectedSource.width) < 0.5,
            "source=\(format(source)) expected=\(format(expectedSource))"
        )

        // Edge flipping: near the right edge the card goes left, near the
        // bottom it goes above — and it never leaves the screen.
        let rightEdge = CGPoint(x: bounds.maxX - 4, y: 500)
        let rightCard = LoupeView.cardRect(for: rightEdge, in: bounds)
        check(
            "loupe: the card flips to the left at the right edge",
            rightCard.maxX < rightEdge.x && bounds.contains(rightCard),
            "card=\(format(rightCard)) point=\(number(rightEdge.x))"
        )
        let bottomEdge = CGPoint(x: 600, y: 6)
        let bottomCard = LoupeView.cardRect(for: bottomEdge, in: bounds)
        check(
            "loupe: the card flips above at the bottom edge",
            bottomCard.minY > bottomEdge.y && bounds.contains(bottomCard),
            "card=\(format(bottomCard)) point=\(number(bottomEdge.y))"
        )

        // Chrome: the toolbar is a click target, so the card steps aside.
        overlay.applySelectionForTesting(CGRect(x: 500, y: 300, width: 400, height: 300))
        overlay.revealToolbarForTesting()
        overlay.layoutSubtreeIfNeeded()
        let toolbarPoint = CGPoint(
            x: overlay.toolbarFrameForTesting.midX,
            y: overlay.toolbarFrameForTesting.midY
        )
        overlay.mouseMoved(with: event(.mouseMoved, at: toolbarPoint))
        check(
            "loupe: the card does not cover the toolbar",
            !overlay.isLoupeVisibleForTesting,
            "visible=\(overlay.isLoupeVisibleForTesting) "
                + "toolbar=\(format(overlay.toolbarFrameForTesting))"
        )

        // Committed selection: the cross freezes, the loupe withdraws.
        drag(overlay, from: CGPoint(x: 200, y: 220), to: CGPoint(x: 700, y: 620))
        overlay.mouseMoved(with: event(.mouseMoved, at: CGPoint(x: 900, y: 800)))
        check(
            "loupe: a frozen cross takes the magnifier away",
            overlay.isCrosshairFrozenForTesting && !overlay.isLoupeVisibleForTesting,
            "frozen=\(overlay.isCrosshairFrozenForTesting) "
                + "visible=\(overlay.isLoupeVisibleForTesting)"
        )
        // …and cancelling the box brings it back over the empty veil.
        click(overlay, at: CGPoint(x: 60, y: 60))
        overlay.mouseMoved(with: event(.mouseMoved, at: CGPoint(x: 600, y: 500)))
        check(
            "loupe: cancelling the box brings the magnifier back",
            !overlay.isCrosshairFrozenForTesting && overlay.isLoupeVisibleForTesting,
            "frozen=\(overlay.isCrosshairFrozenForTesting) "
                + "visible=\(overlay.isLoupeVisibleForTesting)"
        )

        // Visual proof: the document's text, magnified beside the cursor.
        let shotPoint = CGPoint(x: 700, y: 470)
        overlay.mouseMoved(with: event(.mouseMoved, at: shotPoint))
        overlay.layoutSubtreeIfNeeded()
        if let image = renderImage(of: canvas) {
            writePNG(image, to: directory.appendingPathComponent("61-loupe.png"))
            print("[loupe] wrote 61-loupe.png")
        } else {
            check("loupe: render the card", false)
        }

        // Pixel proof: the square draws the snapshot's own pixels, not an empty
        // plate. A flat synthetic frame makes the sampled colour unambiguous
        // (text antialiasing would make an exact match meaningless).
        func solidFrame(_ color: NSColor) -> CGImage? {
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(canvasSize.width) * 2,
                pixelsHigh: Int(canvasSize.height) * 2,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            color.setFill()
            CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh).fill()
            NSGraphicsContext.restoreGraphicsState()
            return rep.cgImage
        }
        // Orientation: the snapshot's top-left must land at the card's
        // top-left. A red top-left / blue bottom-right frame makes a vertical
        // mirror (the bug the first implementation had) unmistakable.
        func cornerFrame() -> CGImage? {
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(canvasSize.width) * 2,
                pixelsHigh: Int(canvasSize.height) * 2,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor.white.setFill()
            CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh).fill()
            // Two full-width bands: the card's 29 pt window straddles their
            // seam, so a vertical mirror swaps red and blue outright.
            NSColor.red.setFill()
            CGRect(
                x: 0,
                y: CGFloat(rep.pixelsHigh) - 60,
                width: CGFloat(rep.pixelsWide),
                height: 60
            ).fill()
            NSColor.blue.setFill()
            CGRect(
                x: 0,
                y: CGFloat(rep.pixelsHigh) - 120,
                width: CGFloat(rep.pixelsWide),
                height: 60
            ).fill()
            NSGraphicsContext.restoreGraphicsState()
            return rep.cgImage
        }
        if let corners = cornerFrame() {
            // Cursor a little inside the red corner so the card shows both.
            let cornerPoint = CGPoint(x: 30, y: 900 - 30)
            overlay.setLoupeImageForTesting(corners, scale: scale)
            overlay.mouseMoved(with: event(.mouseMoved, at: cornerPoint))
            overlay.layoutSubtreeIfNeeded()
            if let image = renderImage(of: canvas) {
                let renderScale = CGFloat(image.width) / bounds.width
                let shownCard = LoupeView.cardRect(for: cornerPoint, in: bounds)
                let inner = shownCard.insetBy(dx: 14, dy: 14)
                func sample(_ point: CGPoint) -> (r: Int, g: Int, b: Int, a: Int)? {
                    pixel(
                        image,
                        x: Int((point.x * renderScale).rounded()),
                        y: Int(((bounds.height - point.y) * renderScale).rounded())
                    )
                }
                let topLeft = sample(CGPoint(x: inner.minX + 4, y: inner.maxY - 4))
                let bottomRight = sample(CGPoint(x: inner.maxX - 4, y: inner.minY + 4))
                check(
                    "loupe: the picture is not mirrored (top-left stays top-left)",
                    topLeft != nil && bottomRight != nil
                        && topLeft!.r > 150 && topLeft!.b < 100
                        && bottomRight!.b > 150 && bottomRight!.r < 100,
                    "topLeft=\(String(describing: topLeft)) "
                        + "bottomRight=\(String(describing: bottomRight))"
                )
            } else {
                check("loupe: the picture is not mirrored (top-left stays top-left)", false)
            }
        } else {
            check("loupe: the picture is not mirrored (top-left stays top-left)", false)
        }

        let probeColor = NSColor(srgbRed: 0.16, green: 0.62, blue: 0.34, alpha: 1)
        if let solid = solidFrame(probeColor) {
            overlay.setLoupeImageForTesting(solid, scale: scale)
            overlay.mouseMoved(with: event(.mouseMoved, at: shotPoint))
            overlay.layoutSubtreeIfNeeded()
            if let image = renderImage(of: canvas) {
                let renderScale = CGFloat(image.width) / bounds.width
                let shownCard = LoupeView.cardRect(for: shotPoint, in: bounds)
                // 18 pt right of the centre: clears the sample mark, still deep
                // inside the magnified picture.
                let probe = CGPoint(x: shownCard.midX + 18, y: shownCard.midY)
                let sample = pixel(
                    image,
                    x: Int((probe.x * renderScale).rounded()),
                    y: Int(((bounds.height - probe.y) * renderScale).rounded())
                )
                let veil = pixel(
                    image,
                    x: Int((probe.x * renderScale).rounded()),
                    y: Int((40 * renderScale).rounded())
                )
                check(
                    "loupe: the square shows the snapshot pixels under the cursor",
                    sample != nil && sample!.g > sample!.r + 60
                        && sample!.g > sample!.b + 40
                        && (veil == nil || abs(sample!.g - veil!.g) > 40),
                    "card=\(String(describing: sample)) veil=\(String(describing: veil))"
                )
            } else {
                check("loupe: render the pixel probe", false)
            }
        } else {
            check("loupe: build the pixel probe frame", false)
        }

        // The owner's two complaints about the card itself: the glass ring left
        // a blank strip between the picture and the edge, and the 4× upscale was
        // smooth, so pixel boundaries turned into blur. Both are checked on the
        // rendered pixels rather than on the drawing code.
        if let solid = solidFrame(probeColor) {
            overlay.setLoupeImageForTesting(solid, scale: scale)
            overlay.mouseMoved(with: event(.mouseMoved, at: shotPoint))
            overlay.layoutSubtreeIfNeeded()
            if let image = renderImage(of: canvas) {
                let renderScale = CGFloat(image.width) / bounds.width
                let shownCard = LoupeView.cardRect(for: shotPoint, in: bounds)
                func samplePixel(_ point: CGPoint) -> (r: Int, g: Int, b: Int, a: Int)? {
                    pixel(
                        image,
                        x: Int((point.x * renderScale).rounded()),
                        y: Int(((bounds.height - point.y) * renderScale).rounded())
                    )
                }
                // One picture colour, so "is this still the picture?" is just
                // "is this still the same colour?". Away from the cross mark.
                let reference = samplePixel(
                    CGPoint(x: shownCard.midX, y: shownCard.midY - 30)
                )
                var edgeDetail: [String] = []
                var edgeIsPicture = reference != nil
                let edgeProbes: [(CGFloat, CGFloat, String)] = [
                    (shownCard.minX + 1.0, shownCard.midY, "left 1pt"),
                    (shownCard.maxX - 1.0, shownCard.midY, "right 1pt"),
                    (shownCard.midX, shownCard.minY + 1.0, "bottom 1pt"),
                    (shownCard.midX, shownCard.maxY - 1.0, "top 1pt"),
                    (shownCard.minX + 3.0, shownCard.midY, "left 3pt"),
                    (shownCard.maxX - 3.0, shownCard.midY, "right 3pt")
                ]
                for (x, y, label) in edgeProbes {
                    guard let probe = samplePixel(CGPoint(x: x, y: y)),
                          let reference else {
                        edgeIsPicture = false
                        edgeDetail.append("\(label)=nil")
                        continue
                    }
                    let delta = max(
                        abs(probe.r - reference.r),
                        max(abs(probe.g - reference.g), abs(probe.b - reference.b))
                    )
                    if delta > 20 {
                        edgeIsPicture = false
                        edgeDetail.append("\(label)=Δ\(delta)")
                    }
                }
                check(
                    "loupe: the picture reaches the card's edge, with no blank strip",
                    edgeIsPicture,
                    edgeDetail.isEmpty ? "edge=picture" : edgeDetail.joined(separator: " ")
                )
            } else {
                check("loupe: the picture reaches the card's edge, with no blank strip", false)
            }
        } else {
            check("loupe: the picture reaches the card's edge, with no blank strip", false)
        }

        // Nearest-neighbour proof: a one-pixel checkerboard on the snapshot
        // must come out as whole 4-px blocks (zoom 4 at the 2× render), with no
        // grey fringe anywhere — interpolation would produce exactly that.
        func checkerFrame() -> CGImage? {
            makePixelImage(
                width: Int(canvasSize.width) * 2,
                height: Int(canvasSize.height) * 2
            ) { x, y in
                (x + y) % 2 == 0 ? (255, 255, 255) : (0, 0, 0)
            }
        }
        if let checker = checkerFrame() {
            overlay.setLoupeImageForTesting(checker, scale: scale)
            overlay.mouseMoved(with: event(.mouseMoved, at: shotPoint))
            overlay.layoutSubtreeIfNeeded()
            if let image = renderImage(of: canvas) {
                let renderScale = CGFloat(image.width) / bounds.width
                let shownCard = LoupeView.cardRect(for: shotPoint, in: bounds)
                let rowY = Int(
                    ((bounds.height - (shownCard.midY - 30)) * renderScale).rounded()
                )
                let startX = Int(((shownCard.minX + 12) * renderScale).rounded())
                let endX = Int(((shownCard.maxX - 12) * renderScale).rounded())
                var runs: [Int] = []
                var greys = 0
                var current: Bool?
                var run = 0
                if startX < endX {
                    for x in startX...endX {
                        guard let p = pixel(image, x: x, y: rowY) else { continue }
                        let luminance = (p.r + p.g + p.b) / 3
                        if luminance > 60 && luminance < 195 { greys += 1 }
                        let isWhite = luminance >= 195
                        if isWhite == current {
                            run += 1
                        } else {
                            if current != nil { runs.append(run) }
                            current = isWhite
                            run = 1
                        }
                    }
                    runs.append(run)
                }
                // Drop the two runs the scan clipped at its ends.
                let interior = runs.count > 3 ? Array(runs.dropFirst().dropLast()) : []
                let blocksWhole = !interior.isEmpty && interior.allSatisfy { (3...5).contains($0) }
                check(
                    "loupe: a one-pixel pattern comes out as whole 4-px blocks",
                    greys == 0 && blocksWhole,
                    "greys=\(greys) runs=\(runs.prefix(12))"
                )
            } else {
                check("loupe: a one-pixel pattern comes out as whole 4-px blocks", false)
            }
        } else {
            check("loupe: a one-pixel pattern comes out as whole 4-px blocks", false)
        }

        // The switch: off means nothing is drawn, whatever the pointer does.
        let off = CaptureOverlayView(
            frame: bounds,
            mode: .region,
            prefilledSelection: nil,
            showCrosshair: true,
            rendersOffscreen: true,
            baseImage: snapshot,
            baseImageScale: scale,
            showLoupe: false
        )
        canvas.addSubview(off)
        off.setLoupeImageForTesting(snapshot, scale: scale)
        off.mouseMoved(with: event(.mouseMoved, at: CGPoint(x: 620, y: 430)))
        check(
            "loupe: 设置 → 显示放大镜 off hides it",
            !off.isLoupeEnabledForTesting && !off.isLoupeVisibleForTesting,
            "enabled=\(off.isLoupeEnabledForTesting) "
                + "visible=\(off.isLoupeVisibleForTesting)"
        )
        off.removeFromSuperview()

        runLoupeInvalidationTests(into: directory, snapshot: snapshot, scale: scale)
    }

    /// The magnifier's repaint contract, checked at pixel level.
    ///
    /// The owner saw a stuttering ghost trail behind the card while moving the
    /// magnifier. The cause was the dirty rect: `cardRect(old)` ∪
    /// `cardRect(new)` inset by 2 pt erases the card, but the drop shadow
    /// reaches up to 9 pt past it, so a crescent of the previous frame's shadow
    /// survived every move. These checks model a window backing store — erase
    /// exactly the invalidated rect, redraw exactly that rect — and diff it
    /// against a clean single-frame render. Every differing pixel is a ghost.
    private static func runLoupeInvalidationTests(
        into directory: URL,
        snapshot: CGImage,
        scale: CGSize
    ) {
        print("[loupe] --- the magnifier's repaint region ---")
        let bounds = CGRect(x: 0, y: 0, width: 640, height: 420)
        let loupe = LoupeView(frame: bounds)
        loupe.magnifiedImage = snapshot
        loupe.imageScale = scale
        let ground = NSColor(srgbRed: 0.16, green: 0.22, blue: 0.31, alpha: 1)
        // A sweep with a fast jump every tenth move: slow moves expose a
        // surviving shadow crescent, fast ones a whole stale card.
        let points: [CGPoint] = (0..<40).map { index in
            let jump: CGFloat = index % 10 == 9 ? 80 : 0
            return CGPoint(
                x: 70 + CGFloat(index % 15) * 28,
                y: 200 + CGFloat((index * 11) % 120) + jump
            )
        }

        func makeStore(scale s: Int) -> (rep: NSBitmapImageRep, context: NSGraphicsContext)? {
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(bounds.width) * s,
                pixelsHigh: Int(bounds.height) * s,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { return nil }
            // Set the point size before building the context: it derives the
            // backing scale from it.
            rep.size = bounds.size
            guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
            return (rep, context)
        }

        /// The pre-fix policy: both cards plus a 2 pt fringe, which is smaller
        /// than the shadow's spread.
        func oldPolicy(_ old: CGPoint?, _ new: CGPoint?) -> CGRect? {
            var union: CGRect?
            for point in [old, new].compactMap({ $0 }) {
                let card = LoupeView.cardRect(for: point, in: bounds)
                    .insetBy(dx: -2, dy: -2)
                union = union.map { $0.union(card) } ?? card
            }
            return union?.intersection(bounds)
        }
        func fixedPolicy(_ old: CGPoint?, _ new: CGPoint?) -> CGRect? {
            LoupeView.invalidationRect(from: old, to: new, in: bounds)
        }

        /// Replay the moves against a persistent store, then diff against the
        /// same final frame rendered from scratch.
        func composite(
            dirtyRect: (CGPoint?, CGPoint?) -> CGRect?
        ) -> (ghosts: Int, image: CGImage?) {
            guard let (store, context) = makeStore(scale: 1) else { return (-1, nil) }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            ground.setFill()
            bounds.fill()
            var previous: CGPoint?
            for point in points {
                let dirty = dirtyRect(previous, point) ?? bounds
                context.cgContext.saveGState()
                context.cgContext.clip(to: dirty)
                ground.setFill()
                dirty.fill()
                loupe.point = point
                loupe.draw(dirty)
                context.cgContext.restoreGState()
                previous = point
            }
            NSGraphicsContext.restoreGraphicsState()

            guard let (reference, referenceContext) = makeStore(scale: 1) else {
                return (-1, nil)
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = referenceContext
            ground.setFill()
            bounds.fill()
            loupe.point = points.last
            loupe.draw(bounds)
            NSGraphicsContext.restoreGraphicsState()

            guard let bytes = store.bitmapData, let referenceBytes = reference.bitmapData else {
                return (-1, nil)
            }
            let count = store.bytesPerRow * store.pixelsHigh
            var ghosts = 0
            for index in stride(from: 0, to: count, by: 4) {
                let delta = abs(Int(bytes[index]) - Int(referenceBytes[index]))
                    + abs(Int(bytes[index + 1]) - Int(referenceBytes[index + 1]))
                    + abs(Int(bytes[index + 2]) - Int(referenceBytes[index + 2]))
                if delta > 6 { ghosts += 1 }
            }
            return (ghosts, store.cgImage)
        }

        let before = composite(dirtyRect: oldPolicy)
        let after = composite(dirtyRect: fixedPolicy)
        print(
            "[loupe] ghost pixels after 40 moves: old 2 pt fringe = \(before.ghosts), "
                + "fixed painted-rect union = \(after.ghosts)"
        )
        check(
            "loupe: the old 2 pt dirty rect leaves a shadow trail",
            before.ghosts > 0,
            "ghosts=\(before.ghosts) px"
        )
        check(
            "loupe: the painted-rect union leaves no ghost at all",
            after.ghosts == 0,
            "ghosts=\(after.ghosts) px"
        )
        if let image = before.image {
            writePNG(image, to: directory.appendingPathComponent("62-loupe-ghost-before.png"))
            print("[loupe] wrote 62-loupe-ghost-before.png")
        }
        if let image = after.image {
            writePNG(image, to: directory.appendingPathComponent("63-loupe-ghost-fixed.png"))
            print("[loupe] wrote 63-loupe-ghost-fixed.png")
        }

        // How far the card's ink really reaches: the numbers `shadowMargin`
        // exists for, measured on a transparent store.
        loupe.point = CGPoint(x: 240, y: 240)
        let card = LoupeView.cardRect(for: CGPoint(x: 240, y: 240), in: bounds)
        if let (probe, probeContext) = makeStore(scale: 1),
           let probeBytes = probe.bitmapData {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = probeContext
            loupe.draw(bounds)
            NSGraphicsContext.restoreGraphicsState()
            var minX = probe.pixelsWide
            var maxX = -1
            var minY = probe.pixelsHigh
            var maxY = -1
            for y in 0..<probe.pixelsHigh {
                for x in 0..<probe.pixelsWide {
                    let alpha = probeBytes[y * probe.bytesPerRow + x * 4 + 3]
                    guard alpha > 8 else { continue }
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
            // Rows are top-left, the view is bottom-left.
            let ink = CGRect(
                x: CGFloat(minX),
                y: CGFloat(probe.pixelsHigh - 1 - maxY),
                width: CGFloat(maxX - minX + 1),
                height: CGFloat(maxY - minY + 1)
            )
            let painted = LoupeView.paintRect(for: loupe.point ?? .zero, in: bounds)
            print(
                "[loupe] ink reaches L=\(number(card.minX - ink.minX)) "
                    + "R=\(number(ink.maxX - card.maxX)) "
                    + "T=\(number(ink.maxY - card.maxY)) "
                    + "B=\(number(card.minY - ink.minY)) pt past the card; "
                    + "paintRect margin=\(number(LoupeView.shadowMargin)) pt"
            )
            check(
                "loupe: the paint rect covers the card and every shadow pixel",
                painted.contains(ink) && ink.contains(card),
                "ink=\(format(ink)) paint=\(format(painted)) card=\(format(card))"
            )
            check(
                "loupe: a 2 pt fringe would not have covered that ink",
                !card.insetBy(dx: -2, dy: -2).contains(ink),
                "ink=\(format(ink)) fringe=\(format(card.insetBy(dx: -2, dy: -2)))"
            )
        }

        // The rect a move asks AppKit for: both painted rects, clamped to the
        // view, and much smaller than the overlay.
        let from = CGPoint(x: 200, y: 260)
        let to = CGPoint(x: 260, y: 310)
        loupe.point = from
        loupe.point = to
        let expected = LoupeView.invalidationRect(from: from, to: to, in: bounds)
        let reported = loupe.lastInvalidationRectForTesting
        check(
            "loupe: a move invalidates the old and the new painted rect",
            expected.map { sameRect(reported ?? .zero, $0) } == true
                && expected.map {
                    $0.contains(LoupeView.paintRect(for: from, in: bounds))
                        && $0.contains(LoupeView.paintRect(for: to, in: bounds))
                        && $0.width * $0.height < bounds.width * bounds.height * 0.3
                } == true,
            "invalidated=\(reported.map(format) ?? "nil") "
                + "expected=\(expected.map(format) ?? "nil")"
        )

        // Cost of one incremental repaint, old policy vs new, at 2×: the fix
        // must not trade the trail for a full-screen redraw.
        func timeRepaints(
            dirtyRect: (CGPoint?, CGPoint?) -> CGRect?
        ) -> (average: Double, worst: Double, area: CGFloat) {
            guard let (_, context) = makeStore(scale: 2) else { return (-1, -1, 0) }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            ground.setFill()
            bounds.fill()
            var previous: CGPoint?
            var total = 0.0
            var worst = 0.0
            var area: CGFloat = 0
            for point in points {
                let dirty = dirtyRect(previous, point) ?? bounds
                let startedAt = CFAbsoluteTimeGetCurrent()
                context.cgContext.saveGState()
                context.cgContext.clip(to: dirty)
                ground.setFill()
                dirty.fill()
                loupe.point = point
                loupe.draw(dirty)
                context.cgContext.restoreGState()
                let elapsed = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
                total += elapsed
                worst = max(worst, elapsed)
                area += dirty.width * dirty.height
                previous = point
            }
            NSGraphicsContext.restoreGraphicsState()
            let count = Double(points.count)
            return (total / count, worst, area / CGFloat(points.count))
        }
        let oldCost = timeRepaints(dirtyRect: oldPolicy)
        let newCost = timeRepaints(dirtyRect: fixedPolicy)
        print(
            String(
                format: "[loupe] repaint @2× over %d moves: old %.2f ms avg (max %.2f, "
                    + "%.0f pt²) → fixed %.2f ms avg (max %.2f, %.0f pt²)",
                points.count,
                oldCost.average,
                oldCost.worst,
                oldCost.area,
                newCost.average,
                newCost.worst,
                newCost.area
            )
        )
        check(
            "loupe: the bigger dirty rect does not cost a frame",
            newCost.average < 8
                && newCost.average <= oldCost.average * 2.5 + 0.5,
            String(
                format: "avg %.2f ms (old %.2f ms) max %.2f ms",
                newCost.average,
                oldCost.average,
                newCost.worst
            )
        )
    }

    // MARK: - C. Annotation painting interaction

    private static func runAnnotationInteractionTests() {
        let overlay = makeOverlay()

        // Move tool creates the selection exactly like P0.
        drag(overlay, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 800, y: 700))
        expect(
            "annotations: baseline selection",
            overlay.selectionRectForTesting,
            CGRect(x: 200, y: 200, width: 600, height: 500)
        )
        check("annotations: starts on move", overlay.currentToolForTesting == .move)

        // One gesture per drawing tool, all inside the selection.
        let gestures: [(tool: AnnotationTool, points: [CGPoint])] = [
            (.arrow, [CGPoint(x: 300, y: 300), CGPoint(x: 600, y: 500)]),
            (.rectangle, [CGPoint(x: 650, y: 350), CGPoint(x: 780, y: 450)]),
            (.ellipse, [CGPoint(x: 250, y: 550), CGPoint(x: 400, y: 680)]),
            (.pencil, [
                CGPoint(x: 450, y: 300), CGPoint(x: 480, y: 350),
                CGPoint(x: 520, y: 320), CGPoint(x: 560, y: 380)
            ]),
            (.highlighter, [
                CGPoint(x: 250, y: 620), CGPoint(x: 400, y: 650), CGPoint(x: 650, y: 630)
            ]),
            (.line, [CGPoint(x: 600, y: 600), CGPoint(x: 750, y: 680)])
        ]

        for (index, gesture) in gestures.enumerated() {
            overlay.selectToolForTesting(gesture.tool)
            stroke(overlay, points: gesture.points)
            let expected = index + 1
            check(
                "annotations: \(gesture.tool.rawValue) drag adds one",
                overlay.annotationCountForTesting == expected,
                "count=\(overlay.annotationCountForTesting) expected=\(expected)"
            )
            check(
                "annotations: \(gesture.tool.rawValue) tool is stored",
                overlay.annotationsForTesting.last?.tool == gesture.tool,
                "got=\(overlay.annotationsForTesting.last?.tool.rawValue ?? "nil")"
            )
            check(
                "annotations: \(gesture.tool.rawValue) keeps the selection",
                overlay.selectionRectForTesting == CGRect(x: 200, y: 200, width: 600, height: 500),
                "selection=\(format(overlay.selectionRectForTesting))"
            )
        }

        check(
            "annotations: six annotations after six gestures",
            overlay.annotationCountForTesting == 6,
            "count=\(overlay.annotationCountForTesting)"
        )
        check(
            "annotations: tool stays selected after painting",
            overlay.currentToolForTesting == .line,
            "tool=\(overlay.currentToolForTesting.rawValue)"
        )
        if let pencil = overlay.annotationsForTesting.first(where: { $0.tool == .pencil }) {
            check(
                "annotations: pencil kept the whole polyline",
                pencil.points.count == 4,
                "points=\(pencil.points.count)"
            )
        } else {
            check("annotations: pencil kept the whole polyline", false)
        }
        if let highlighter = overlay.annotationsForTesting.first(where: { $0.tool == .highlighter }) {
            check(
                "annotations: highlighter kept the whole polyline",
                highlighter.points.count == 3,
                "points=\(highlighter.points.count)"
            )
        } else {
            check("annotations: highlighter kept the whole polyline", false)
        }

        // A handle still resizes even while a drawing tool is active.
        overlay.selectToolForTesting(.arrow)
        stroke(overlay, points: [CGPoint(x: 800, y: 700), CGPoint(x: 860, y: 760)])
        expect(
            "annotations: handle drag resizes with a drawing tool",
            overlay.selectionRectForTesting,
            CGRect(x: 200, y: 200, width: 660, height: 560)
        )
        check(
            "annotations: handle drag does not add an annotation",
            overlay.annotationCountForTesting == 6,
            "count=\(overlay.annotationCountForTesting)"
        )

        // The first arrow was drawn with the selection at (200,200,600,500),
        // from view (300,300). Its normalised point must be unchanged, and the
        // canvas must resolve it against the *new* rect — that is what keeps
        // annotations glued to the selection while a handle moves.
        if let arrow = overlay.annotationsForTesting.first(where: { $0.tool == .arrow }) {
            let scaled = AnnotationCanvasView.viewPoint(
                arrow.points[0],
                in: overlay.selectionRectForTesting
            )
            let expected = CGPoint(x: 310, y: 312)
            check(
                "annotations: handle resize rescales the geometry",
                abs(scaled.x - expected.x) < 0.5 && abs(scaled.y - expected.y) < 0.5,
                "scaled=(\(number(scaled.x)),\(number(scaled.y))) "
                + "expected=(\(number(expected.x)),\(number(expected.y)))"
            )
            check(
                "annotations: normalised points survive the resize",
                abs(arrow.points[0].x - 1.0 / 6.0) < 0.001
                    && abs(arrow.points[0].y - 0.8) < 0.001,
                "point=(\(arrow.points[0].x),\(arrow.points[0].y))"
            )
        } else {
            check("annotations: handle resize rescales the geometry", false)
        }

        // A drag outside starts a new box and paints nothing.
        stroke(overlay, points: [CGPoint(x: 50, y: 50), CGPoint(x: 150, y: 150)])
        expect(
            "annotations: outside drag starts a new box",
            overlay.selectionRectForTesting,
            CGRect(x: 50, y: 50, width: 100, height: 100)
        )
        check(
            "annotations: outside drag paints nothing",
            overlay.annotationCountForTesting == 6,
            "count=\(overlay.annotationCountForTesting)"
        )

        // Move tool still pans the selection and never paints.
        overlay.selectToolForTesting(.move)
        drag(overlay, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 150))
        expect(
            "annotations: move tool still pans",
            overlay.selectionRectForTesting,
            CGRect(x: 150, y: 100, width: 100, height: 100)
        )
        check(
            "annotations: move tool does not paint",
            overlay.annotationCountForTesting == 6,
            "count=\(overlay.annotationCountForTesting)"
        )

        // A click without a drag must not leave a dot behind.
        overlay.selectToolForTesting(.arrow)
        let before = overlay.selectionRectForTesting
        click(overlay, at: CGPoint(x: 200, y: 150))
        check(
            "annotations: click without drag adds nothing",
            overlay.annotationCountForTesting == 6,
            "count=\(overlay.annotationCountForTesting)"
        )
        check(
            "annotations: click without drag keeps the selection",
            overlay.selectionRectForTesting == before,
            "selection=\(format(overlay.selectionRectForTesting))"
        )
    }

    // MARK: - D. Undo / redo

    private static func runAnnotationHistoryTests() {
        let overlay = makeOverlay()
        overlay.applySelectionForTesting(CGRect(x: 300, y: 300, width: 600, height: 400))
        overlay.selectToolForTesting(.line)

        let strokes: [[CGPoint]] = [
            [CGPoint(x: 350, y: 350), CGPoint(x: 450, y: 400)],
            [CGPoint(x: 500, y: 450), CGPoint(x: 600, y: 500)],
            [CGPoint(x: 650, y: 550), CGPoint(x: 750, y: 600)]
        ]
        for points in strokes { stroke(overlay, points: points) }

        check("history: three annotations", overlay.annotationCountForTesting == 3)
        check("history: undo enabled after painting", overlay.isUndoEnabledForTesting)
        check("history: redo disabled after painting", !overlay.isRedoEnabledForTesting)

        // Enabled/disabled is also a hit-testing property: a dimmed undo must
        // not swallow a click, an enabled one must claim its own rect.
        if let undoFrame = overlay.toolbarHistoryFramesForTesting()
            .first(where: { !$0.isRedo })?.frame {
            let hit = overlay.hitTest(CGPoint(x: undoFrame.midX, y: undoFrame.midY))
            check(
                "history: enabled undo hit-tests",
                (hit as? CaptureToolbarHistoryButton)?.isRedo == false,
                "hit=\(String(describing: hit.map { type(of: $0) }))"
            )
        }
        if let redoFrame = overlay.toolbarHistoryFramesForTesting()
            .first(where: { $0.isRedo })?.frame {
            let hit = overlay.hitTest(CGPoint(x: redoFrame.midX, y: redoFrame.midY))
            check(
                "history: disabled redo does not hit-test",
                (hit as? CaptureToolbarHistoryButton) == nil,
                "hit=\(String(describing: hit.map { type(of: $0) }))"
            )
        }

        check("history: undo #1 returns true", overlay.undoForTesting())
        check("history: undo #2 returns true", overlay.undoForTesting())
        check(
            "history: two undos leave one",
            overlay.annotationCountForTesting == 1,
            "count=\(overlay.annotationCountForTesting)"
        )
        check("history: redo enabled after undo", overlay.isRedoEnabledForTesting)
        check("history: undo still enabled", overlay.isUndoEnabledForTesting)

        check("history: redo returns true", overlay.redoForTesting())
        check(
            "history: one redo returns to two",
            overlay.annotationCountForTesting == 2,
            "count=\(overlay.annotationCountForTesting)"
        )
        check(
            "history: redo lands the right tool",
            overlay.annotationsForTesting.last?.tool == .line,
            "tool=\(overlay.annotationsForTesting.last?.tool.rawValue ?? "nil")"
        )

        // Drain the stack, then make sure an empty undo is a no-op, not a crash.
        overlay.undoForTesting()
        check("history: undo back to one", overlay.annotationCountForTesting == 1)
        overlay.undoForTesting()
        check("history: undo back to zero", overlay.annotationCountForTesting == 0)
        check("history: undo disabled when empty", !overlay.isUndoEnabledForTesting)
        check("history: empty undo returns false", !overlay.undoForTesting())
        check("history: empty undo keeps zero", overlay.annotationCountForTesting == 0)

        check("history: redo returns true", overlay.redoForTesting())
        overlay.redoForTesting()
        overlay.redoForTesting()
        check(
            "history: redo restores all three",
            overlay.annotationCountForTesting == 3,
            "count=\(overlay.annotationCountForTesting)"
        )
        check("history: redo disabled when drained", !overlay.isRedoEnabledForTesting)
        check("history: empty redo returns false", !overlay.redoForTesting())
        check("history: empty redo keeps three", overlay.annotationCountForTesting == 3)

        // A new annotation invalidates redo.
        overlay.undoForTesting()
        check("history: undo before new stroke", overlay.annotationCountForTesting == 2)
        check("history: redo armed before new stroke", overlay.isRedoEnabledForTesting)
        stroke(overlay, points: [CGPoint(x: 400, y: 620), CGPoint(x: 500, y: 660)])
        check(
            "history: new annotation clears redo",
            !overlay.isRedoEnabledForTesting,
            "redoEnabled=\(overlay.isRedoEnabledForTesting)"
        )
        check(
            "history: new annotation appends",
            overlay.annotationCountForTesting == 3,
            "count=\(overlay.annotationCountForTesting)"
        )
        check("history: redo after new stroke returns false", !overlay.redoForTesting())

        // The keyboard path uses the same store as the buttons.
        let beforeKeyboard = overlay.annotationCountForTesting
        overlay.keyDown(with: keyEvent(keyCode: 6, modifiers: .command))
        check(
            "history: ⌘Z undoes one",
            overlay.annotationCountForTesting == beforeKeyboard - 1,
            "count=\(overlay.annotationCountForTesting)"
        )
        overlay.keyDown(with: keyEvent(keyCode: 6, modifiers: [.command, .shift]))
        check(
            "history: ⇧⌘Z redoes one",
            overlay.annotationCountForTesting == beforeKeyboard,
            "count=\(overlay.annotationCountForTesting)"
        )
    }

    // MARK: - E. Flatten (export) at Retina scale

    private static func runFlattenTest(into directory: URL) {
        guard let base = makeBaseImage(width: 600, height: 400) else {
            check("flatten: base image", false)
            return
        }
        // 600×400 px for a 300×200 pt selection = 2× Retina.
        let referencePointSize = CGSize(width: 300, height: 200)
        let arrow = Annotation(
            tool: .arrow,
            points: [CGPoint(x: 0.10, y: 0.25), CGPoint(x: 0.90, y: 0.75)],
            color: NSColor(srgbRed: 1.0, green: 0.12, blue: 0.12, alpha: 1),
            lineWidth: 3
        )

        guard let flattened = AnnotationRenderer.flattened(
            base: base,
            annotations: [arrow],
            referencePointSize: referencePointSize
        ) else {
            check("flatten: render succeeds", false)
            return
        }

        check(
            "flatten: pixel size stays the selection's pixel size",
            flattened.width == 600 && flattened.height == 400,
            "size=\(flattened.width)×\(flattened.height)"
        )

        // Normalised (0.5, 0.5) must land on *pixel* (300, 200), not point
        // (150, 100). The arrow is diagonal, so the shaft crosses that pixel.
        if let shaft = pixel(flattened, x: 300, y: 200) {
            check(
                "flatten: arrow lands at 2× pixel coordinates",
                shaft.r > 150 && shaft.r > shaft.g + 60 && shaft.r > shaft.b + 60,
                "rgba=(\(shaft.r),\(shaft.g),\(shaft.b),\(shaft.a))"
            )
        } else {
            check("flatten: arrow lands at 2× pixel coordinates", false, "pixel read failed")
        }

        // The 1× position (150, 100) / (150, 150) must stay background.
        if let wrong = pixel(flattened, x: 150, y: 150) {
            let isRed = wrong.r > 120 && wrong.r > wrong.g + 60
            check(
                "flatten: no arrow at 1× point coordinates",
                !isRed,
                "rgba=(\(wrong.r),\(wrong.g),\(wrong.b),\(wrong.a))"
            )
        } else {
            check("flatten: no arrow at 1× point coordinates", false, "pixel read failed")
        }

        // The delivery wrapper keeps the logical size while baking pixels.
        let screenshot = CapturedScreenshot(image: base, scale: 2)
        check(
            "flatten: base point size is 300×200",
            screenshot.pointSize == CGSize(width: 300, height: 200),
            "pointSize=\(screenshot.pointSize)"
        )
        let baked = screenshot.flattened(annotations: [arrow])
        check(
            "flatten: baked pixels stay 600×400",
            baked.image.width == 600 && baked.image.height == 400,
            "size=\(baked.image.width)×\(baked.image.height)"
        )
        check(
            "flatten: baked logical size stays 300×200",
            baked.pointSize == CGSize(width: 300, height: 200),
            "pointSize=\(baked.pointSize)"
        )

        // No annotations: the original image must be handed back untouched.
        let untouched = screenshot.flattened(annotations: [])
        check(
            "flatten: empty annotations keep the original image",
            untouched.image === base
        )

        // A highlighter must stay translucent in the export.
        let highlighter = Annotation(
            tool: .highlighter,
            points: [CGPoint(x: 0.10, y: 0.90), CGPoint(x: 0.90, y: 0.90)],
            color: NSColor(srgbRed: 1.0, green: 0.90, blue: 0.15, alpha: 1),
            lineWidth: 4
        )
        if let marked = AnnotationRenderer.flattened(
            base: base,
            annotations: [highlighter],
            referencePointSize: referencePointSize
        ), let sample = pixel(marked, x: 300, y: 360),
           let original = pixel(base, x: 300, y: 360) {
            // 35 % yellow multiplied over the blue band: the result must stay
            // darker than the saturated marker colour (255, 230, 38) and must
            // visibly darken the blue channel. That is the translucent-marker
            // signature; an opaque stroke would clip r to ~255.
            check(
                "flatten: highlighter is translucent",
                sample.r < 200 && sample.b < original.b && sample.g > 40,
                "marked=(\(sample.r),\(sample.g),\(sample.b)) "
                + "base=(\(original.r),\(original.g),\(original.b))"
            )
        } else {
            check("flatten: highlighter is translucent", false)
        }

        guard let representation = NSBitmapImageRep(cgImage: flattened)
            .representation(using: .png, properties: [:]) else {
            check("flatten: encode PNG", false)
            return
        }
        let url = directory.appendingPathComponent("04-flatten-arrow.png")
        do {
            try representation.write(to: url)
            print(
                "[flatten] wrote \(url.path) "
                + "(\(flattened.width)×\(flattened.height) px)"
            )
            copyToVerification(representation, named: "annotation-flatten.png")
        } catch {
            check("flatten: write PNG", false, error.localizedDescription)
        }
    }

    // MARK: - F. Inline text / note input

    private static func runTextInputTests() {
        let overlay = makeOverlay()
        let selection = CGRect(x: 200, y: 200, width: 600, height: 400)
        overlay.applySelectionForTesting(selection)

        // A click inside the selection with the text tool opens a field.
        overlay.selectToolForTesting(.text)
        click(overlay, at: CGPoint(x: 300, y: 300))
        guard let field = overlay.textInputFieldForTesting else {
            check("text: click inside opens a field", false)
            return
        }
        check("text: click inside opens a field", true)
        check(
            "text: field is inside the selection",
            selection.contains(field.frame),
            "field=\(format(field.frame))"
        )
        check(
            "text: field font is 20 pt",
            abs((field.font?.pointSize ?? 0) - AnnotationRenderer.textFontSize) < 0.01,
            "font=\(field.font?.pointSize ?? 0)"
        )
        check(
            "text: field ink is the red default",
            field.textColor == AnnotationTool.text.defaultColor,
            "color=\(String(describing: field.textColor))"
        )
        check(
            "text: anchor is the click point",
            overlay.textInputAnchorForTesting == CGPoint(x: 300, y: 300),
            "anchor=\(String(describing: overlay.textInputAnchorForTesting))"
        )

        // Enter commits through the real delegate path.
        overlay.setTextInputValueForTesting("你好 Text")
        let handledEnter = overlay.handleTextCommandForTesting(
            #selector(NSResponder.insertNewline(_:))
        )
        check("text: Enter is handled by the field delegate", handledEnter)
        check(
            "text: Enter adds exactly one annotation",
            overlay.annotationCountForTesting == 1,
            "count=\(overlay.annotationCountForTesting)"
        )
        guard let committed = overlay.annotationsForTesting.last else {
            check("text: committed annotation exists", false)
            return
        }
        check("text: stored tool is text", committed.tool == .text,
              "tool=\(committed.tool.rawValue)")
        check("text: stored text matches the field", committed.text == "你好 Text",
              "text=\(committed.text ?? "nil")")
        check(
            "text: anchor is normalised to the selection",
            committed.points.count == 2
                && abs(committed.points[0].x - 1.0 / 6.0) < 0.001
                && abs(committed.points[0].y - 0.75) < 0.001,
            "points=\(committed.points)"
        )
        check("text: field removed after commit", overlay.textInputFieldForTesting == nil)

        // Note shares the flow but keeps a different ink/tool.
        overlay.selectToolForTesting(.note)
        click(overlay, at: CGPoint(x: 450, y: 350))
        guard let noteField = overlay.textInputFieldForTesting else {
            check("note: click inside opens a field", false)
            return
        }
        check("note: click inside opens a field", true)
        check(
            "note: field ink is the dark note colour",
            noteField.textColor == AnnotationTool.note.defaultColor,
            "color=\(String(describing: noteField.textColor))"
        )
        check(
            "note: field has the pale sticky background",
            noteField.drawsBackground && noteField.backgroundColor != .clear,
            "background=\(String(describing: noteField.backgroundColor))"
        )
        overlay.setTextInputValueForTesting("便签 Note")
        check(
            "note: Enter is handled",
            overlay.handleTextCommandForTesting(#selector(NSResponder.insertNewline(_:)))
        )
        check(
            "note: Enter adds a second annotation",
            overlay.annotationCountForTesting == 2,
            "count=\(overlay.annotationCountForTesting)"
        )
        check(
            "note: stored tool is note",
            overlay.annotationsForTesting.last?.tool == .note,
            "tool=\(overlay.annotationsForTesting.last?.tool.rawValue ?? "nil")"
        )
        check(
            "note: stored text matches",
            overlay.annotationsForTesting.last?.text == "便签 Note",
            "text=\(overlay.annotationsForTesting.last?.text ?? "nil")"
        )

        // Escape discards: no annotation, field gone.
        overlay.selectToolForTesting(.text)
        click(overlay, at: CGPoint(x: 500, y: 300))
        check("text: second click opens another field", overlay.textInputFieldForTesting != nil)
        overlay.setTextInputValueForTesting("丢弃这段")
        let handledEscape = overlay.handleTextCommandForTesting(
            #selector(NSResponder.cancelOperation(_:))
        )
        check("text: Escape is handled by the field delegate", handledEscape)
        check(
            "text: Escape adds nothing",
            overlay.annotationCountForTesting == 2,
            "count=\(overlay.annotationCountForTesting)"
        )
        check("text: field removed after Escape", overlay.textInputFieldForTesting == nil)

        // Empty text is discarded, just like a zero-length stroke.
        click(overlay, at: CGPoint(x: 520, y: 320))
        check("text: empty click opens a field", overlay.textInputFieldForTesting != nil)
        check(
            "text: empty Enter is handled",
            overlay.handleTextCommandForTesting(#selector(NSResponder.insertNewline(_:)))
        )
        check(
            "text: empty Enter adds nothing",
            overlay.annotationCountForTesting == 2,
            "count=\(overlay.annotationCountForTesting)"
        )
    }

    // MARK: - G. Seven actions / copy and keep

    private static func runCopyKeepingTest() {
        let overlay = makeOverlay()
        let selection = CGRect(x: 300, y: 300, width: 400, height: 300)
        overlay.applySelectionForTesting(selection)

        let arrow = Annotation(
            tool: .arrow,
            points: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.7, y: 0.6)],
            color: AnnotationTool.arrow.defaultColor,
            lineWidth: 3
        )
        let text = Annotation(
            tool: .text,
            points: [CGPoint(x: 0.2, y: 0.7), CGPoint(x: 0.2, y: 0.7)],
            color: AnnotationTool.text.defaultColor,
            lineWidth: 1,
            text: "保留"
        )
        overlay.addAnnotationForTesting(arrow)
        overlay.addAnnotationForTesting(text)
        check("copy-keeping: two annotations staged", overlay.annotationCountForTesting == 2)

        var payload: (rect: CGRect, annotations: [Annotation])?
        var keepCount = 0
        overlay.onCopyKeeping = { rect, annotations in
            keepCount += 1
            payload = (rect, annotations)
        }
        var confirmed: (rect: CGRect, action: CaptureToolbarAction)?
        overlay.onConfirm = { rect, _, action in
            confirmed = (rect, action)
        }

        overlay.performToolbarActionForTesting(.copyKeeping)

        check("copy-keeping: callback fired once", keepCount == 1, "count=\(keepCount)")
        check(
            "copy-keeping: payload carries the selection",
            payload?.rect == selection,
            "rect=\(String(describing: payload?.rect))"
        )
        check(
            "copy-keeping: payload carries both annotations",
            payload?.annotations.count == 2,
            "count=\(payload?.annotations.count ?? -1)"
        )
        check(
            "copy-keeping: overlay is still visible",
            !overlay.isHidden,
            "hidden=\(overlay.isHidden)"
        )
        check(
            "copy-keeping: annotations are retained",
            overlay.annotationCountForTesting == 2,
            "count=\(overlay.annotationCountForTesting)"
        )
        check(
            "copy-keeping: toolbar is still visible",
            overlay.isToolbarVisibleForTesting
        )
        check(
            "copy-keeping: selection is unchanged",
            overlay.selectionRectForTesting == selection,
            "selection=\(format(overlay.selectionRectForTesting))"
        )
        check("copy-keeping: no terminal confirm was sent", confirmed == nil)

        // The five terminal actions still route through onConfirm with their
        // own id (only copy-keeping stays open).
        for action in [CaptureToolbarAction.copyClosing, .save, .saveAs, .pin, .ocr] {
            confirmed = nil
            overlay.performToolbarActionForTesting(action)
            check(
                "actions: \(action.rawValue) reaches onConfirm",
                confirmed?.action == action,
                "got=\(confirmed.map { $0.action.rawValue } ?? "nil")"
            )
        }

        // Cancel never reaches onConfirm.
        var cancelled = false
        overlay.onCancel = { cancelled = true }
        confirmed = nil
        overlay.performToolbarActionForTesting(.cancel)
        check("actions: cancel reaches onCancel", cancelled)
        check("actions: cancel does not confirm", confirmed == nil)
    }

    // MARK: - H. Flatten mosaic + text + note at Retina scale

    private static func runFlattenToolsTest(into directory: URL) {
        // 360×240 pt selection, 720×480 px base = 2× Retina.
        let pixelWidth = 720
        let pixelHeight = 480
        guard let base = makeDetailedBaseImage(width: pixelWidth, height: pixelHeight) else {
            check("tools flatten: base image", false)
            return
        }
        let reference = CGSize(width: 360, height: 240)

        let mosaic = Annotation(
            tool: .mosaic,
            points: [CGPoint(x: 0.05, y: 0.10), CGPoint(x: 0.45, y: 0.45)],
            color: AnnotationTool.mosaic.defaultColor,
            lineWidth: 0
        )
        let text = Annotation(
            tool: .text,
            points: [CGPoint(x: 0.55, y: 0.10), CGPoint(x: 0.55, y: 0.10)],
            color: AnnotationTool.text.defaultColor,
            lineWidth: 1,
            text: "马赛克文字"
        )
        let note = Annotation(
            tool: .note,
            points: [CGPoint(x: 0.55, y: 0.50), CGPoint(x: 0.55, y: 0.50)],
            color: AnnotationTool.note.defaultColor,
            lineWidth: 1,
            text: "便签 Note"
        )

        guard let flattened = AnnotationRenderer.flattened(
            base: base,
            annotations: [mosaic, text, note],
            referencePointSize: reference
        ) else {
            check("tools flatten: render succeeds", false)
            return
        }
        check(
            "tools flatten: pixels are the selection's 2× size",
            flattened.width == pixelWidth && flattened.height == pixelHeight,
            "size=\(flattened.width)×\(flattened.height) expected=720×480"
        )

        guard let flat = pixelBuffer(flattened), let raw = pixelBuffer(base) else {
            check("tools flatten: pixel buffers", false)
            return
        }

        // Mosaic: normalised (0.05…0.45, 0.10…0.45) → x 36…324, y 48…216.
        func equalNeighbourRatio(_ buffer: PixelBuffer, y: Int, from: Int, to: Int) -> Double {
            var equal = 0
            var total = 0
            for x in from..<to {
                let a = buffer.rgb(x: x, y: y)
                let b = buffer.rgb(x: x + 1, y: y)
                total += 1
                if a.0 == b.0 && a.1 == b.1 && a.2 == b.2 { equal += 1 }
            }
            return total == 0 ? 0 : Double(equal) / Double(total)
        }

        let mosaicRow = 120
        let flatRatio = equalNeighbourRatio(flat, y: mosaicRow, from: 40, to: 316)

        func transitions(in buffer: PixelBuffer, y: Int, from: Int, to: Int) -> Int {
            var count = 0
            for x in from..<to {
                let a = buffer.rgb(x: x, y: y)
                let b = buffer.rgb(x: x + 1, y: y)
                if a.0 != b.0 || a.1 != b.1 || a.2 != b.2 { count += 1 }
            }
            return count
        }

        let sampleRows = [70, 100, 130, 160, 190]
        let rawTransitions = sampleRows.reduce(0) {
            $0 + transitions(in: raw, y: $1, from: 40, to: 316)
        }
        check(
            "tools flatten: mosaic blocks are flat (≥80% equal neighbours)",
            flatRatio >= 0.80,
            "ratio=\(String(format: "%.2f", flatRatio))"
        )
        check(
            "tools flatten: the source region was detailed",
            rawTransitions > 150,
            "transitions=\(rawTransitions) across \(sampleRows.count) rows"
        )

        let blockBoundaries = transitions(in: flat, y: mosaicRow, from: 40, to: 316)
        check(
            "tools flatten: mosaic is visibly blocked (≥3 block boundaries)",
            blockBoundaries >= 3,
            "transitions=\(blockBoundaries)"
        )

        // Text: red glyph pixels in the text's band.
        var redPixels = 0
        for y in 45..<130 {
            for x in 380..<710 {
                let (r, g, b) = flat.rgb(x: x, y: y)
                if r > 150 && r > g + 40 && r > b + 40 { redPixels += 1 }
            }
        }
        check(
            "tools flatten: red text pixels are present",
            redPixels > 200,
            "redPixels=\(redPixels)"
        )

        // Note: pale-yellow bubble pixels (the text inside is dark).
        var yellowPixels = 0
        for y in 225..<380 {
            for x in 380..<710 {
                let (r, g, b) = flat.rgb(x: x, y: y)
                if r > 230 && g > 205 && b > 100 && b < 225 && r > b + 30 {
                    yellowPixels += 1
                }
            }
        }
        check(
            "tools flatten: note bubble is pale yellow",
            yellowPixels > 3000,
            "yellowPixels=\(yellowPixels)"
        )

        guard let representation = NSBitmapImageRep(cgImage: flattened)
            .representation(using: .png, properties: [:]) else {
            check("tools flatten: encode PNG", false)
            return
        }
        let url = directory.appendingPathComponent("05-flatten-tools.png")
        do {
            try representation.write(to: url)
            print(
                "[flatten] wrote \(url.path) "
                + "(\(flattened.width)×\(flattened.height) px) "
                + "mosaicFlat=\(String(format: "%.2f", flatRatio)) "
                + "rawTransitions=\(rawTransitions) "
                + "blockBoundaries=\(blockBoundaries) "
                + "red=\(redPixels) yellow=\(yellowPixels)"
            )
            copyToVerification(representation, named: "tools-flatten.png")
        } catch {
            check("tools flatten: write PNG", false, error.localizedDescription)
        }
    }

    // MARK: - I. Counter numbering

    private static func runCounterTests() {
        let overlay = makeOverlay()
        let selection = CGRect(x: 200, y: 200, width: 600, height: 400)
        overlay.applySelectionForTesting(selection)
        overlay.selectToolForTesting(.counter)
        check(
            "counter: the first badge is 1",
            overlay.nextCounterValueForTesting == 1,
            "next=\(overlay.nextCounterValueForTesting)"
        )

        click(overlay, at: CGPoint(x: 260, y: 300))
        check(
            "counter: the first click adds one badge",
            overlay.annotationCountForTesting == 1,
            "count=\(overlay.annotationCountForTesting)"
        )
        check(
            "counter: the first badge is 1",
            overlay.annotationsForTesting.last?.counterValue == 1,
            "value=\(String(describing: overlay.annotationsForTesting.last?.counterValue))"
        )
        check(
            "counter: the payload is the decimal string",
            overlay.annotationsForTesting.last?.text == "1",
            "text=\(overlay.annotationsForTesting.last?.text ?? "nil")"
        )
        check(
            "counter: the anchor is normalised to the selection",
            overlay.annotationsForTesting.last?.points.first.map {
                abs($0.x - 0.1) < 0.001 && abs($0.y - 0.75) < 0.001
            } ?? false,
            "point=\(String(describing: overlay.annotationsForTesting.last?.points.first))"
        )
        check("counter: the click does not open a text field", overlay.textInputFieldForTesting == nil)
        check(
            "counter: the click keeps the selection",
            overlay.selectionRectForTesting == selection,
            "selection=\(format(overlay.selectionRectForTesting))"
        )
        check(
            "counter: the tool stays selected",
            overlay.currentToolForTesting == .counter,
            "tool=\(overlay.currentToolForTesting.rawValue)"
        )

        click(overlay, at: CGPoint(x: 340, y: 300))
        check(
            "counter: the second click adds one badge",
            overlay.annotationCountForTesting == 2,
            "count=\(overlay.annotationCountForTesting)"
        )
        check(
            "counter: the second badge is 2",
            overlay.annotationsForTesting.last?.counterValue == 2,
            "value=\(String(describing: overlay.annotationsForTesting.last?.counterValue))"
        )
        check(
            "counter: the next badge would be 3",
            overlay.nextCounterValueForTesting == 3,
            "next=\(overlay.nextCounterValueForTesting)"
        )

        // Undo the "2" and paint again. Count-based numbering would produce 2
        // again; the high-water rule must produce 3 so a number is never reused.
        check("counter: undo returns true", overlay.undoForTesting())
        check(
            "counter: undo leaves one badge",
            overlay.annotationCountForTesting == 1,
            "count=\(overlay.annotationCountForTesting)"
        )
        check(
            "counter: undo does not rewind the numbering",
            overlay.nextCounterValueForTesting == 3,
            "next=\(overlay.nextCounterValueForTesting) "
            + "highWater=\(overlay.counterHighWaterForTesting)"
        )
        click(overlay, at: CGPoint(x: 420, y: 300))
        check(
            "counter: after undo the new badge is 3, not 2",
            overlay.annotationsForTesting.last?.counterValue == 3,
            "value=\(String(describing: overlay.annotationsForTesting.last?.counterValue))"
        )
        let values = overlay.annotationsForTesting.compactMap(\.counterValue)
        check(
            "counter: live numbering is 1 and 3",
            values == [1, 3],
            "values=\(values)"
        )
        check(
            "counter: no number appears twice",
            Set(values).count == values.count,
            "values=\(values)"
        )

        // Redo restores the 3 without lowering the mark; the next badge is 4.
        check("counter: undo again returns true", overlay.undoForTesting())
        check(
            "counter: redo restores the 3",
            overlay.redoForTesting()
                && overlay.annotationsForTesting.last?.counterValue == 3,
            "value=\(String(describing: overlay.annotationsForTesting.last?.counterValue))"
        )
        check(
            "counter: the next badge is 4",
            overlay.nextCounterValueForTesting == 4,
            "next=\(overlay.nextCounterValueForTesting)"
        )

        // A click outside the selection and a click on a resize handle both
        // place nothing (the P0 handle precedence still wins).
        overlay.applySelectionForTesting(selection)
        overlay.selectToolForTesting(.counter)
        let beforeOutside = overlay.annotationCountForTesting
        click(overlay, at: CGPoint(x: 60, y: 60))
        check(
            "counter: a click outside the selection places nothing",
            overlay.annotationCountForTesting == beforeOutside,
            "count=\(overlay.annotationCountForTesting)"
        )
        overlay.applySelectionForTesting(selection)
        let beforeHandle = overlay.annotationCountForTesting
        click(overlay, at: CGPoint(x: selection.minX, y: selection.maxY))
        check(
            "counter: a click on a handle places nothing",
            overlay.annotationCountForTesting == beforeHandle,
            "count=\(overlay.annotationCountForTesting)"
        )
    }

    // MARK: - J. Sticker catalog and picker

    private static func runStickerTests() {
        let overlay = makeOverlay()
        let selection = CGRect(x: 200, y: 200, width: 600, height: 400)
        overlay.applySelectionForTesting(selection)
        overlay.selectToolForTesting(.sticker)

        let firstClick = CGPoint(x: 500, y: 350)
        click(overlay, at: firstClick)
        check(
            "sticker: the click requests the picker at the click point",
            overlay.pendingStickerAnchorForTesting == firstClick,
            "anchor=\(String(describing: overlay.pendingStickerAnchorForTesting))"
        )
        check(
            "sticker: nothing is placed before an emoji is picked",
            overlay.annotationCountForTesting == 0,
            "count=\(overlay.annotationCountForTesting)"
        )
        check("sticker: the click does not open a text field", overlay.textInputFieldForTesting == nil)

        check("sticker: picking commits an annotation", overlay.pickStickerForTesting("😀"))
        check(
            "sticker: the stored tool is sticker",
            overlay.annotationsForTesting.last?.tool == .sticker,
            "tool=\(overlay.annotationsForTesting.last?.tool.rawValue ?? "nil")"
        )
        check(
            "sticker: the payload is the emoji",
            overlay.annotationsForTesting.last?.text == "😀",
            "text=\(overlay.annotationsForTesting.last?.text ?? "nil")"
        )
        check(
            "sticker: the anchor is normalised to the selection",
            overlay.annotationsForTesting.last?.points.first.map {
                abs($0.x - 0.5) < 0.001 && abs($0.y - 0.625) < 0.001
            } ?? false,
            "point=\(String(describing: overlay.annotationsForTesting.last?.points.first))"
        )
        check("sticker: the pending anchor is cleared", overlay.pendingStickerAnchorForTesting == nil)
        check(
            "sticker: the pick keeps the selection",
            overlay.selectionRectForTesting == selection,
            "selection=\(format(overlay.selectionRectForTesting))"
        )

        click(overlay, at: CGPoint(x: 640, y: 260))
        check("sticker: a second pick commits a second annotation", overlay.pickStickerForTesting("🌈"))
        check(
            "sticker: two different emoji are stored",
            overlay.annotationsForTesting.compactMap(\.text) == ["😀", "🌈"],
            "texts=\(overlay.annotationsForTesting.compactMap(\.text))"
        )

        // The catalog itself: 20–30 entries, unique, and all real emoji.
        let catalog = StickerCatalog.emojis
        check(
            "sticker: the catalog offers 20…30 emoji",
            (20...30).contains(catalog.count),
            "count=\(catalog.count)"
        )
        check(
            "sticker: the catalog has no duplicates",
            Set(catalog).count == catalog.count,
            "unique=\(Set(catalog).count) total=\(catalog.count)"
        )
        check(
            "sticker: every entry contains an emoji scalar",
            catalog.allSatisfy { emoji in
                emoji.unicodeScalars.contains { $0.properties.isEmoji }
            },
            "entries=\(catalog.count)"
        )

        // Picker geometry, exercised without a window server.
        let picker = StickerPickerView()
        picker.frame = CGRect(origin: .zero, size: picker.intrinsicContentSize)
        check(
            "sticker: the picker lays out all six columns",
            picker.intrinsicContentSize.width == StickerPickerView.padding * 2
                + CGFloat(StickerPickerView.columns) * StickerPickerView.cellSize,
            "width=\(picker.intrinsicContentSize.width)"
        )
        let firstCell = picker.cellFrame(at: 0)
        check(
            "sticker: the picker maps the first cell to the first emoji",
            picker.emoji(at: CGPoint(x: firstCell.midX, y: firstCell.midY)) == catalog[0],
            "hit=\(String(describing: picker.emoji(at: CGPoint(x: firstCell.midX, y: firstCell.midY))))"
        )
        let lastIndex = catalog.count - 1
        let lastCell = picker.cellFrame(at: lastIndex)
        check(
            "sticker: the picker maps the last cell to the last emoji",
            picker.emoji(at: CGPoint(x: lastCell.midX, y: lastCell.midY)) == catalog[lastIndex],
            "hit=\(String(describing: picker.emoji(at: CGPoint(x: lastCell.midX, y: lastCell.midY))))"
        )
        check(
            "sticker: the picker ignores its padding",
            picker.emoji(at: CGPoint(x: 1, y: 1)) == nil,
            "hit=\(String(describing: picker.emoji(at: CGPoint(x: 1, y: 1))))"
        )
        check(
            "sticker: picker cells do not overlap",
            (0..<catalog.count).allSatisfy { index in
                let frame = picker.cellFrame(at: index)
                return (0..<catalog.count).allSatisfy { other in
                    other == index || !frame.intersects(picker.cellFrame(at: other))
                }
            }
        )
    }

    // MARK: - K. Note bubble clamp

    private static func runNoteClampTests() {
        // A deliberately small selection: 240 × 120 pt, so a bottom-right note
        // has to be pushed back and a long one has to shrink.
        let renderSize = CGSize(width: 240, height: 120)
        let anchor = CGPoint(x: 0.97, y: 0.94)
        let short = Annotation(
            tool: .note,
            points: [anchor, anchor],
            color: AnnotationTool.note.defaultColor,
            lineWidth: 1,
            text: "右下角便签"
        )
        guard let bubble = AnnotationRenderer.noteBubbleRect(short, renderSize: renderSize) else {
            check("note clamp: the bubble rect resolves", false)
            return
        }
        check(
            "note clamp: a bottom-right bubble stays inside the selection",
            inside(bubble, renderSize),
            "bubble=\(format(bubble)) render=\(renderSize)"
        )
        check(
            "note clamp: the bubble is pushed back to the right edge",
            abs(bubble.maxX - renderSize.width) < 0.5
                && bubble.minX < anchor.x * renderSize.width,
            "bubble=\(format(bubble)) anchorX=\(number(anchor.x * renderSize.width))"
        )
        check(
            "note clamp: the bubble is pushed back to the bottom edge",
            abs(bubble.maxY - renderSize.height) < 0.5,
            "bubble=\(format(bubble)) anchorY=\(number(anchor.y * renderSize.height))"
        )
        check(
            "note clamp: a bubble that fits was not shrunk",
            bubble.width <= renderSize.width,
            "width=\(number(bubble.width))"
        )

        // A note wider than the selection must shrink to the selection width.
        let long = Annotation(
            tool: .note,
            points: [anchor, anchor],
            color: AnnotationTool.note.defaultColor,
            lineWidth: 1,
            text: String(repeating: "很长的备注", count: 12)
        )
        guard let longBubble = AnnotationRenderer.noteBubbleRect(long, renderSize: renderSize) else {
            check("note clamp: the long bubble rect resolves", false)
            return
        }
        check(
            "note clamp: an oversized bubble shrinks to the selection width",
            abs(longBubble.width - renderSize.width) < 0.5,
            "width=\(number(longBubble.width)) renderWidth=\(number(renderSize.width))"
        )
        check(
            "note clamp: a shrunk bubble starts at the left edge",
            abs(longBubble.minX) < 0.5,
            "minX=\(number(longBubble.minX))"
        )
        check(
            "note clamp: a shrunk bubble stays inside the selection",
            inside(longBubble, renderSize),
            "bubble=\(format(longBubble))"
        )

        // A note that fits keeps its anchor: the clamp only moves what would
        // have been clipped.
        let centred = Annotation(
            tool: .note,
            points: [CGPoint(x: 0.25, y: 0.30), CGPoint(x: 0.25, y: 0.30)],
            color: AnnotationTool.note.defaultColor,
            lineWidth: 1,
            text: "便签"
        )
        if let centredBubble = AnnotationRenderer.noteBubbleRect(
            centred,
            renderSize: renderSize
        ) {
            check(
                "note clamp: a bubble that fits keeps its anchor",
                abs(centredBubble.minX - 0.25 * renderSize.width) < 0.5
                    && abs(centredBubble.minY - 0.30 * renderSize.height) < 0.5,
                "bubble=\(format(centredBubble))"
            )
        } else {
            check("note clamp: a bubble that fits keeps its anchor", false)
        }

        // The text line must follow the clamped bubble, not the raw anchor.
        if let line = AnnotationRenderer.textLineRect(short, renderSize: renderSize) {
            check(
                "note clamp: the text line follows the clamped bubble",
                line.minX >= bubble.minX + AnnotationRenderer.notePadding - 0.01
                    && line.maxX <= bubble.maxX - AnnotationRenderer.notePadding + 0.01
                    && line.minY >= bubble.minY + AnnotationRenderer.notePadding - 0.01,
                "line=\(format(line)) bubble=\(format(bubble))"
            )
        } else {
            check("note clamp: the text line follows the clamped bubble", false)
        }
    }

    // MARK: - L. Text / input-field baseline

    private static func runTextBaselineTests() {
        let overlay = makeOverlay()
        let selection = CGRect(x: 150, y: 150, width: 600, height: 450)
        overlay.applySelectionForTesting(selection)
        overlay.selectToolForTesting(.text)

        let clickPoint = CGPoint(x: 300, y: 500)
        click(overlay, at: clickPoint)
        guard let field = overlay.textInputFieldForTesting else {
            check("text baseline: a click opens the field", false)
            return
        }
        check(
            "text baseline: an interior click puts the field top on the click",
            abs(field.frame.maxY - clickPoint.y) < 0.01,
            "field=\(format(field.frame)) click=\(number(clickPoint.y))"
        )

        overlay.setTextInputValueForTesting("Hello 文字")
        check(
            "text baseline: Enter commits the line",
            overlay.handleTextCommandForTesting(#selector(NSResponder.insertNewline(_:)))
        )
        guard let committed = overlay.annotationsForTesting.last,
              let line = AnnotationRenderer.textLineRect(
                  committed,
                  renderSize: selection.size
              ) else {
            check("text baseline: the committed line has a rendered rect", false)
            return
        }
        let fieldTop = selection.maxY - field.frame.maxY
        let fieldLeft = field.frame.minX - selection.minX
        check(
            "text baseline: the rendered top matches the field top (<4 pt)",
            abs(line.minY - fieldTop) < 4,
            "lineTop=\(number(line.minY)) fieldTop=\(number(fieldTop)) "
            + "delta=\(number(line.minY - fieldTop))"
        )
        check(
            "text baseline: the rendered left matches the field left (<4 pt)",
            abs(line.minX - fieldLeft) < 4,
            "lineLeft=\(number(line.minX)) fieldLeft=\(number(fieldLeft)) "
            + "delta=\(number(line.minX - fieldLeft))"
        )

        // The regression: near the screen's right edge the field is pushed back
        // inside the screen. The text must follow the moved box; committing the
        // raw click used to leave it ~170 pt to the right of its own field.
        let edge = makeOverlay()
        let edgeSelection = CGRect(x: 900, y: 300, width: 500, height: 400)
        edge.applySelectionForTesting(edgeSelection)
        edge.selectToolForTesting(.text)
        let edgeClick = CGPoint(x: 1390, y: 500)
        click(edge, at: edgeClick)
        guard let edgeField = edge.textInputFieldForTesting else {
            check("text baseline: the edge click opens the field", false)
            return
        }
        check(
            "text baseline: an edge click clamps the field inside the screen",
            edgeField.frame.minX < edgeClick.x - 20,
            "fieldX=\(number(edgeField.frame.minX)) clickX=\(number(edgeClick.x))"
        )

        edge.setTextInputValueForTesting("A much longer caption")
        let edgeFieldX = edgeField.frame.minX
        let edgeFieldTop = edgeField.frame.maxY
        check(
            "text baseline: Enter commits the clamped line",
            edge.handleTextCommandForTesting(#selector(NSResponder.insertNewline(_:)))
        )
        guard let clamped = edge.annotationsForTesting.last,
              let clampedLine = AnnotationRenderer.textLineRect(
                  clamped,
                  renderSize: edgeSelection.size
              ) else {
            check("text baseline: the clamped line has a rendered rect", false)
            return
        }
        check(
            "text baseline: clamped text follows the box horizontally (<4 pt)",
            abs(clampedLine.minX - (edgeFieldX - edgeSelection.minX)) < 4,
            "lineLeft=\(number(clampedLine.minX)) boxLeft=\(number(edgeFieldX - edgeSelection.minX))"
        )
        check(
            "text baseline: clamped text follows the box vertically (<4 pt)",
            abs(clampedLine.minY - (edgeSelection.maxY - edgeFieldTop)) < 4,
            "lineTop=\(number(clampedLine.minY)) boxTop=\(number(edgeSelection.maxY - edgeFieldTop))"
        )
        check(
            "text baseline: the raw click no longer wins over the box",
            abs(clampedLine.minX - (edgeClick.x - edgeSelection.minX)) > 40,
            "lineLeft=\(number(clampedLine.minX)) rawClickLeft=\(number(edgeClick.x - edgeSelection.minX))"
        )
    }

    // MARK: - M. Flatten counter + sticker + note + text

    private static func runFlattenP1b2Test(into directory: URL) {
        // 360×240 pt selection, 720×480 px base = 2× Retina.
        let pixelWidth = 720
        let pixelHeight = 480
        guard let base = makeBaseImage(width: pixelWidth, height: pixelHeight) else {
            check("p1b2 flatten: base image", false)
            return
        }
        let reference = CGSize(width: 360, height: 240)
        let renderSize = CGSize(width: pixelWidth, height: pixelHeight)

        let counters = (1...3).map { number -> Annotation in
            let x = 0.08 + CGFloat(number - 1) * 0.14
            return Annotation(
                tool: .counter,
                points: [CGPoint(x: x, y: 0.14), CGPoint(x: x, y: 0.14)],
                color: AnnotationTool.counter.defaultColor,
                lineWidth: 0,
                text: String(number)
            )
        }
        let smile = Annotation(
            tool: .sticker,
            points: [CGPoint(x: 0.66, y: 0.20), CGPoint(x: 0.66, y: 0.20)],
            color: AnnotationTool.sticker.defaultColor,
            lineWidth: 0,
            text: "😀"
        )
        let rainbow = Annotation(
            tool: .sticker,
            points: [CGPoint(x: 0.86, y: 0.44), CGPoint(x: 0.86, y: 0.44)],
            color: AnnotationTool.sticker.defaultColor,
            lineWidth: 0,
            text: "🌈"
        )
        // Bottom-right corner: the bubble has to be pushed back inside.
        let note = Annotation(
            tool: .note,
            points: [CGPoint(x: 0.97, y: 0.95), CGPoint(x: 0.97, y: 0.95)],
            color: AnnotationTool.note.defaultColor,
            lineWidth: 1,
            text: "右下角的便签不能超出选区"
        )
        let text = Annotation(
            tool: .text,
            points: [CGPoint(x: 0.06, y: 0.62), CGPoint(x: 0.06, y: 0.62)],
            color: AnnotationTool.text.defaultColor,
            lineWidth: 1,
            text: "文字 Text"
        )
        let annotations = counters + [smile, rainbow, note, text]

        guard let flattened = AnnotationRenderer.flattened(
            base: base,
            annotations: annotations,
            referencePointSize: reference
        ) else {
            check("p1b2 flatten: render succeeds", false)
            return
        }
        check(
            "p1b2 flatten: pixels are the selection's 2× size",
            flattened.width == pixelWidth && flattened.height == pixelHeight,
            "size=\(flattened.width)×\(flattened.height) expected=720×480"
        )
        guard let flat = pixelBuffer(flattened) else {
            check("p1b2 flatten: pixel buffer", false)
            return
        }

        // --- Counter badges: solid red with white digits -------------------
        var redTotal = 0
        var digitTotal = 0
        for (offset, counter) in counters.enumerated() {
            guard let anchor = AnnotationRenderer.anchorPoint(
                counter,
                renderSize: renderSize
            ) else { continue }
            let badge = AnnotationRenderer.counterRect(
                anchor: anchor,
                renderSize: renderSize,
                scale: 2
            )
            var red = 0
            var white = 0
            for y in Int(badge.minY)..<Int(badge.maxY) {
                for x in Int(badge.minX)..<Int(badge.maxX) {
                    let (r, g, b) = flat.rgb(x: x, y: y)
                    if r > 150 && r > g + 50 && r > b + 50 { red += 1 }
                    if r > 225 && g > 225 && b > 225 { white += 1 }
                }
            }
            redTotal += red
            digitTotal += white
            let number = offset + 1
            check(
                "p1b2 flatten: badge \(number) is solid red",
                red > 400,
                "redPixels=\(red)"
            )
            check(
                "p1b2 flatten: badge \(number) carries white digits",
                white > 30,
                "whitePixels=\(white)"
            )
        }

        // --- Stickers: colour glyphs, not tinted text ----------------------
        var stickerBuckets: [String: Int] = [:]
        for sticker in [smile, rainbow] {
            guard let rect = AnnotationRenderer.stickerRect(
                sticker,
                renderSize: renderSize,
                scale: 2
            ) else { continue }
            let buckets = colourBuckets(in: rect, buffer: flat)
            stickerBuckets[sticker.text ?? "?"] = buckets.count
            check(
                "p1b2 flatten: sticker \(sticker.text ?? "?") renders in colour",
                buckets.count >= 3,
                "colourBuckets=\(buckets.count) rect=\(format(rect))"
            )
        }

        // --- Note: clamped inside the selection, never clipped -------------
        guard let bubble = AnnotationRenderer.noteBubbleRect(
            note,
            renderSize: renderSize,
            scale: 2
        ) else {
            check("p1b2 flatten: the note bubble rect resolves", false)
            return
        }
        check(
            "p1b2 flatten: the note bubble is inside the selection",
            inside(bubble, renderSize),
            "bubble=\(format(bubble))"
        )
        // Only scan the note's band: the 😀 face is yellow too, so a
        // whole-image scan would mix the sticker into the bubble assertion.
        var yellow = 0
        var yellowMinX = Int.max, yellowMinY = Int.max
        var yellowMaxX = -1, yellowMaxY = -1
        let scanFromY = max(0, Int(bubble.minY) - 20)
        for y in scanFromY..<pixelHeight {
            for x in 0..<pixelWidth {
                let (r, g, b) = flat.rgb(x: x, y: y)
                if r > 230 && g > 205 && b > 100 && b < 225 && r > b + 30 {
                    yellow += 1
                    yellowMinX = min(yellowMinX, x)
                    yellowMaxX = max(yellowMaxX, x)
                    yellowMinY = min(yellowMinY, y)
                    yellowMaxY = max(yellowMaxY, y)
                }
            }
        }
        check(
            "p1b2 flatten: the sticky note is pale yellow",
            yellow > 3000,
            "yellowPixels=\(yellow)"
        )
        check(
            "p1b2 flatten: every yellow pixel is inside the clamped bubble",
            yellow > 0
                && CGFloat(yellowMinX) >= bubble.minX - 2
                && CGFloat(yellowMaxX) <= bubble.maxX + 2
                && CGFloat(yellowMinY) >= bubble.minY - 2
                && CGFloat(yellowMaxY) <= bubble.maxY + 2,
            "yellowBBox=(\(yellowMinX),\(yellowMinY))-(\(yellowMaxX),\(yellowMaxY)) "
            + "bubble=\(format(bubble))"
        )
        check(
            "p1b2 flatten: the note bubble reaches the right/bottom edge",
            abs(bubble.maxX - renderSize.width) < 0.5
                && abs(bubble.maxY - renderSize.height) < 0.5,
            "bubble=\(format(bubble))"
        )
        check(
            "p1b2 flatten: the clamped bubble is not cut off by the image edge",
            yellowMaxX >= Int(bubble.maxX) - 8
                && yellowMaxY >= Int(bubble.maxY) - 8
                && yellowMaxX < pixelWidth
                && yellowMaxY < pixelHeight,
            "yellowMax=(\(yellowMaxX),\(yellowMaxY)) "
            + "bubble=\(format(bubble)) image=\(pixelWidth)×\(pixelHeight)"
        )

        // --- Text: red ink exactly where the line box is -------------------
        guard let textRect = AnnotationRenderer.textLineRect(
            text,
            renderSize: renderSize,
            scale: 2
        ) else {
            check("p1b2 flatten: the text line rect resolves", false)
            return
        }
        var textRed = 0
        for y in max(0, Int(textRect.minY) - 2)..<min(pixelHeight, Int(textRect.maxY) + 2) {
            for x in max(0, Int(textRect.minX) - 2)..<min(pixelWidth, Int(textRect.maxX) + 2) {
                let (r, g, b) = flat.rgb(x: x, y: y)
                if r > 150 && r > g + 40 && r > b + 40 { textRed += 1 }
            }
        }
        check(
            "p1b2 flatten: red text pixels land inside the line box",
            textRed > 200,
            "redPixels=\(textRed) line=\(format(textRect))"
        )

        guard let representation = NSBitmapImageRep(cgImage: flattened)
            .representation(using: .png, properties: [:]) else {
            check("p1b2 flatten: encode PNG", false)
            return
        }
        let url = directory.appendingPathComponent("06-flatten-p1b2.png")
        do {
            try representation.write(to: url)
            print(
                "[flatten] wrote \(url.path) "
                + "(\(flattened.width)×\(flattened.height) px) "
                + "counterRed=\(redTotal) counterDigits=\(digitTotal) "
                + "stickerBuckets=\(stickerBuckets) "
                + "yellow=\(yellow) textRed=\(textRed)"
            )
            copyToVerification(representation, named: "p1b2-flatten.png")
        } catch {
            check("p1b2 flatten: write PNG", false, error.localizedDescription)
        }
    }

    // MARK: - K. OCR / barcodes / save-as writing

    /// Deterministic Vision checks plus the two wiring seams that cannot be
    /// driven through the UI: the result window's data source and the save-as
    /// file-writing half.
    private static func runOCRGroup(into directory: URL) {
        runTextRecognitionTests(into: directory)
        runBarcodeRecognitionTests(into: directory)
        runEmptyRecognitionTest(into: directory)
        runOCRWiringTests(into: directory)
        runSaveAsWriteTest(into: directory)
    }

    private static func runTextRecognitionTests(into directory: URL) {
        // 1. English + digits, black on white, rendered large enough that
        //    Vision's accurate model has no excuse.
        if let image = makeTextImage(
            text: "HELLO 123",
            pixelWidth: 1000,
            pixelHeight: 320,
            fontSize: 130,
            fontName: "Helvetica-Bold"
        ) {
            writePNG(image, to: directory.appendingPathComponent("ocr-01-text.png"))
            let nsImage = NSImage(
                cgImage: image,
                size: NSSize(width: image.width, height: image.height)
            )
            let items = TextRecognition.recognize(in: nsImage)
            let joined = items.map(\.text).joined(separator: " ")
            print("[ocr] HELLO image items=\(describe(items))")
            check("ocr text: HELLO image returns text", !items.isEmpty, "count=\(items.count)")
            check(
                "ocr text: HELLO recognised (case-insensitive)",
                joined.lowercased().contains("hello"),
                "text=\"\(joined)\""
            )
            check("ocr text: 123 recognised", joined.contains("123"), "text=\"\(joined)\"")
            check(
                "ocr text: result kind is .text",
                items.contains { $0.kind == .text },
                "kinds=\(items.map { String(describing: $0.kind) })"
            )
            check(
                "ocr text: confidence is in (0, 1]",
                items.allSatisfy { $0.confidence > 0 && $0.confidence <= 1 },
                "confidences=\(items.map { String(format: "%.2f", $0.confidence) })"
            )
        } else {
            check("ocr text: render HELLO image", false)
        }

        // 2. Chinese. PingFang is the system CJK face; CoreText substitutes it
        //    if the named face is unavailable.
        if let image = makeTextImage(
            text: "你好世界",
            pixelWidth: 1000,
            pixelHeight: 360,
            fontSize: 150,
            fontName: "PingFangSC-Semibold"
        ) {
            writePNG(image, to: directory.appendingPathComponent("ocr-02-chinese.png"))
            let nsImage = NSImage(
                cgImage: image,
                size: NSSize(width: image.width, height: image.height)
            )
            let items = TextRecognition.recognize(in: nsImage)
            let joined = items.map(\.text).joined(separator: " ")
            print("[ocr] Chinese image items=\(describe(items))")
            check(
                "ocr text: Chinese image returns text",
                !items.isEmpty,
                "count=\(items.count)"
            )
            check(
                "ocr text: 你好 recognised",
                joined.contains("你好"),
                "text=\"\(joined)\""
            )
        } else {
            check("ocr text: render Chinese image", false)
        }
    }

    private static func runBarcodeRecognitionTests(into directory: URL) {
        let payload = "https://example.com/p2"
        guard let image = makeQRCodeImage(payload: payload, side: 600) else {
            check("ocr barcode: generate QR image", false)
            return
        }
        writePNG(image, to: directory.appendingPathComponent("ocr-03-qr.png"))

        let nsImage = NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
        let items = TextRecognition.recognize(in: nsImage)
        print("[ocr] QR image items=\(describe(items))")

        check(
            "ocr barcode: QR image returns a barcode",
            items.contains { $0.kind == .barcode },
            "kinds=\(items.map { String(describing: $0.kind) })"
        )
        let barcode = items.first { $0.kind == .barcode }
        check(
            "ocr barcode: payload equals the encoded URL",
            barcode?.text == payload,
            "text=\"\(barcode?.text ?? "-")\""
        )
        check(
            "ocr barcode: barcode sorts before text",
            items.first?.kind == .barcode,
            "first=\(items.first.map { String(describing: $0.kind) } ?? "nil")"
        )
        check(
            "ocr barcode: confidence is in (0, 1]",
            barcode.map { $0.confidence > 0 && $0.confidence <= 1 } ?? false,
            "confidence=\(barcode.map { String(format: "%.2f", $0.confidence) } ?? "-")"
        )

        // Same image, both request types: text must survive and barcodes must
        // still sort first.
        if let mixed = makeMixedRecognitionImage(payload: payload, text: "HELLO 123") {
            writePNG(mixed, to: directory.appendingPathComponent("ocr-06-mixed.png"))
            let mixedItems = TextRecognition.recognize(in: NSImage(
                cgImage: mixed,
                size: NSSize(width: mixed.width, height: mixed.height)
            ))
            print("[ocr] mixed image items=\(describe(mixedItems))")
            check(
                "ocr mixed: recognises both text and barcode",
                mixedItems.contains { $0.kind == .barcode }
                    && mixedItems.contains { $0.kind == .text },
                "items=\(describe(mixedItems))"
            )
            check(
                "ocr mixed: barcode comes before text",
                mixedItems.first?.kind == .barcode,
                "first=\(mixedItems.first.map { String(describing: $0.kind) } ?? "nil")"
            )
            check(
                "ocr mixed: text is kept after the barcode",
                mixedItems.filter { $0.kind == .text }
                    .map(\.text).joined(separator: " ")
                    .lowercased()
                    .contains("hello"),
                "items=\(describe(mixedItems))"
            )
        } else {
            check("ocr mixed: render mixed image", false)
        }
    }

    private static func runEmptyRecognitionTest(into directory: URL) {
        guard let image = makeSolidImage(
            color: NSColor(srgbRed: 0.72, green: 0.76, blue: 0.82, alpha: 1),
            width: 480,
            height: 320
        ) else {
            check("ocr empty: render solid image", false)
            return
        }
        writePNG(image, to: directory.appendingPathComponent("ocr-04-empty.png"))
        let nsImage = NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
        let items = TextRecognition.recognize(in: nsImage)
        print("[ocr] solid image items=\(describe(items))")
        check("ocr empty: returns no items", items.isEmpty, "count=\(items.count)")
    }

    /// Toolbar action order, the automatic-confirm OCR entry, the result
    /// window's data source / text view / size cap, and the persisted hotkey
    /// defaults.
    private static func runOCRWiringTests(into directory: URL) {
        check(
            "ocr wiring: toolbar has eight actions in order",
            CaptureToolbarAction.allCases == [
                .copyKeeping, .copyClosing, .save, .saveAs, .pin, .ocr, .cancel, .record
            ],
            "order=\(CaptureToolbarAction.allCases.map(\.rawValue))"
        )
        check(
            "ocr wiring: OCR action symbol and label",
            CaptureToolbarAction.ocr.symbol == "text.viewfinder"
                && CaptureToolbarAction.ocr.label == "OCR"
        )

        // OCR entry point: drawing a new box confirms with .ocr; nudging an
        // existing box must not.
        let overlay = CaptureOverlayView(
            frame: CGRect(origin: .zero, size: canvasSize),
            mode: .region,
            prefilledSelection: nil,
            showCrosshair: false,
            rendersOffscreen: true,
            autoConfirmOnSelectionEnd: true
        )
        var confirmed: CaptureToolbarAction?
        overlay.onConfirm = { _, _, action in confirmed = action }
        drag(overlay, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 700, y: 600))
        check(
            "ocr wiring: finishing a new box auto-confirms with .ocr",
            confirmed == .ocr,
            "action=\(confirmed?.rawValue ?? "nil")"
        )
        confirmed = nil
        drag(overlay, from: CGPoint(x: 400, y: 380), to: CGPoint(x: 430, y: 400))
        check(
            "ocr wiring: moving an existing selection does not auto-confirm",
            confirmed == nil,
            "action=\(confirmed?.rawValue ?? "nil")"
        )
        check(
            "ocr wiring: auto-confirm keeps the selection",
            overlay.selectionRectForTesting.width >= SelectionBorderView.minimumSide,
            "selection=\(format(overlay.selectionRectForTesting))"
        )

        // Result window data source + selectable read-only text view.
        let items = [
            RecognizedItem(kind: .barcode, text: "https://example.com/p2", confidence: 0.99),
            RecognizedItem(kind: .text, text: "第一行", confidence: 0.93),
            RecognizedItem(kind: .text, text: "第二行", confidence: 0.88)
        ]
        let controller = OCRResultWindowController(items: items)
        controller.prepareContentForTesting()
        let expected = "https://example.com/p2\n第一行\n第二行"
        check(
            "ocr window: content has three lines",
            controller.contentLineCountForTesting == 3,
            "lines=\(controller.contentLineCountForTesting)"
        )
        check(
            "ocr window: copy text joins all lines",
            controller.contentTextForTesting == expected,
            "text=\"\(controller.contentTextForTesting)\""
        )
        check(
            "ocr window: actual text view matches the data source",
            controller.textView.string == expected
        )
        check("ocr window: text view is read-only", !controller.textView.isEditable)
        check("ocr window: text view is selectable", controller.textView.isSelectable)
        check(
            "ocr window: text view was laid out inside the card",
            controller.textView.frame.width > 0 && controller.textView.frame.height > 0,
            "frame=\(NSStringFromRect(controller.textView.frame))"
        )

        let size = controller.window?.frame.size ?? .zero
        check(
            "ocr window: size is within 400×500",
            size.width > 0 && size.width <= OCRResultWindowController.maximumSize.width
                && size.height <= OCRResultWindowController.maximumSize.height,
            "size=\(number(size.width))×\(number(size.height))"
        )
        check(
            "ocr window: size respects the minimum",
            size.width >= OCRResultWindowController.minimumSize.width
                && size.height >= OCRResultWindowController.minimumSize.height,
            "size=\(number(size.width))×\(number(size.height))"
        )
        let longLine = String(repeating: "很长的识别结果", count: 40)
        let longText = ([longLine] + Array(repeating: "多行结果", count: 39))
            .joined(separator: "\n")
        let clampedSize = OCRResultWindowController.preferredSize(for: longText)
        check(
            "ocr window: long content clamps to 400×500",
            clampedSize == OCRResultWindowController.maximumSize,
            "size=\(NSStringFromSize(clampedSize))"
        )
        if let window = controller.window, let view = window.contentView {
            // The offscreen renderer has no glass backdrop, so a dark-mode
            // window would draw white text on transparency and the PNG would
            // look empty. Render this one verification image in light mode,
            // where the selectable NSTextView is legible on white.
            window.appearance = NSAppearance(named: .aqua)
            controller.prepareContentForTesting()
            if let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: representation)
                if let png = representation.representation(using: .png, properties: [:]) {
                    let url = directory.appendingPathComponent("ocr-05-result-window.png")
                    try? png.write(to: url)
                    copyToVerification(png, named: "ocr-05-result-window.png")
                }
            }
            window.appearance = nil
        }

        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("Unseen.OCRResultSelfTest")
        )
        defer { pasteboard.releaseGlobally() }
        check("ocr window: copy writes the pasteboard", controller.copy(to: pasteboard))
        check(
            "ocr window: pasteboard text matches",
            pasteboard.string(forType: .string) == expected,
            "text=\"\(pasteboard.string(forType: .string) ?? "-")\""
        )
        controller.copyAndClose(to: pasteboard)
        check(
            "ocr window: copy and close orders the panel out",
            controller.window?.isVisible != true
        )

        // Multiple barcodes render as multiple lines, not one joined blob.
        let multiBarcode = OCRResultWindowController(items: [
            RecognizedItem(kind: .barcode, text: "https://example.com/a", confidence: 1),
            RecognizedItem(kind: .barcode, text: "https://example.com/b", confidence: 1)
        ])
        check(
            "ocr window: two barcodes produce two lines",
            multiBarcode.contentLineCountForTesting == 2
                && multiBarcode.contentTextForTesting
                    == "https://example.com/a\nhttps://example.com/b",
            "text=\"\(multiBarcode.contentTextForTesting)\""
        )
        multiBarcode.close()

        // Persisted OCR hotkey: same shape as the screenshot hotkey.
        check(
            "ocr hotkey: ships unbound like the preference file has it",
            !HotKeyConfiguration.ocr.isBound
                && HotKeyConfiguration.ocr == .unbound
                && HotKeyConfiguration.ocr.displayString == KeyCodeFormatter.keySymbol(0),
            "display=\(HotKeyConfiguration.ocr.displayString) bound=\(HotKeyConfiguration.ocr.isBound)"
        )
        check(
            "ocr hotkey: the unbound quartet is OCR / 取色 / 按键显示 / 套壳",
            HotKeyConfiguration.ocr == .colorPicker
                && HotKeyConfiguration.ocr == .beautify
                && HotKeyConfiguration.ocr == .unbound
                && HotKeyConfiguration.screenshot.isBound
                && HotKeyConfiguration.scroll.isBound
                && HotKeyConfiguration.record.isBound,
            "screenshot=\(HotKeyConfiguration.screenshot.displayString) "
                + "scroll=\(HotKeyConfiguration.scroll.displayString)"
        )
        check(
            "ocr hotkey: action raw value is 4",
            HotKeyAction.ocr.rawValue == 4
        )
        check(
            "ocr hotkey: settings keys are exported (backup / reset)",
            AppSettings.exportedKeys.contains(AppSettings.Key.ocrHotKeyEnabled)
                && AppSettings.exportedKeys.contains(AppSettings.Key.ocrHotKeyKeyCode)
                && AppSettings.exportedKeys.contains(AppSettings.Key.ocrHotKeyModifiers)
        )
    }

    /// The real file-writing half of "保存至…". No `NSSavePanel`.
    private static func runSaveAsWriteTest(into directory: URL) {
        guard let image = makeBaseImage(width: 600, height: 400) else {
            check("save-as: base image", false)
            return
        }
        let shot = CapturedScreenshot(image: image, scale: 2)
        check(
            "save-as: shot is a 300×200 pt / 2× selection",
            shot.pointSize == CGSize(width: 300, height: 200)
                && image.width == 600 && image.height == 400,
            "points=\(NSStringFromSize(shot.pointSize)) pixels=\(image.width)×\(image.height)"
        )

        let url = directory.appendingPathComponent("ocr-saveas-selection.png")
        try? FileManager.default.removeItem(at: url)
        do {
            try CaptureCoordinator.writeScreenshot(shot, to: url, format: "png")
        } catch {
            check("save-as: write file", false, error.localizedDescription)
            return
        }

        check(
            "save-as: file exists on disk",
            FileManager.default.fileExists(atPath: url.path),
            "path=\(url.path)"
        )
        guard let data = try? Data(contentsOf: url) else {
            check("save-as: read back bytes", false)
            return
        }
        check("save-as: file is not empty", data.count > 0, "bytes=\(data.count)")
        check(
            "save-as: bytes are a PNG",
            data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
            "magic=\(data.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " "))"
        )
        let representation = NSBitmapImageRep(data: data)
        check(
            "save-as: pixels are 600×400 (selection × 2)",
            representation?.pixelsWide == 600 && representation?.pixelsHigh == 400,
            "pixels=\(representation?.pixelsWide ?? -1)×\(representation?.pixelsHigh ?? -1)"
        )

        let sips = sipsDimensions(url)
        check(
            "save-as: sips reads pixelWidth 600",
            sips.width == 600,
            "output=\(sips.output.replacingOccurrences(of: "\n", with: " | "))"
        )
        check(
            "save-as: sips reads pixelHeight 400",
            sips.height == 400,
            "output=\(sips.output.replacingOccurrences(of: "\n", with: " | "))"
        )
        copyToVerification(data, named: "ocr-saveas-selection.png")

        // The JPEG branch of the same writer, so the format switch is covered
        // rather than only the PNG default.
        let jpegURL = directory.appendingPathComponent("ocr-saveas-selection.jpg")
        try? FileManager.default.removeItem(at: jpegURL)
        do {
            try CaptureCoordinator.writeScreenshot(shot, to: jpegURL, format: "jpg")
            let jpeg = try Data(contentsOf: jpegURL)
            check(
                "save-as: jpg branch writes a JPEG",
                jpeg.starts(with: [0xFF, 0xD8, 0xFF]),
                "bytes=\(jpeg.count)"
            )
        } catch {
            check("save-as: jpg branch writes a JPEG", false, error.localizedDescription)
        }
    }

    // MARK: - N. Scrolling capture stitching

    /// Deterministic "long page" texture: every row has its own colour, with
    /// periodic darker blocks that look like lines of text. No two rows repeat
    /// within the test's 1300-row page, which is what makes an accidental
    /// 100-row match essentially impossible.
    private static func scrollPagePixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
        var r = (y * 37 + y * y * 11 + 13) % 251
        var g = (y * 61 + y * y * 7 + 29) % 241
        var b = (y * 89 + y * y * 3 + 47) % 239
        if ((x / 19) + (y / 11)) % 7 == 0 {
            r = (r + 97) % 251
            g = (g + 53) % 241
            b = (b + 31) % 239
        }
        return (UInt8(r), UInt8(g), UInt8(b))
    }

    /// A page shaped like a document, for the scrolling-direction checks: white
    /// paper, one 2-row rule per line, and a short dark mark whose horizontal
    /// position is unique to the line. Paper is 90 % of the pixels, so a
    /// difference fraction averaged over everything can be fooled by it; the
    /// mark is the only thing that tells two lines apart.
    private static func paperPagePixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
        let line = y / 50
        let inside = y % 50
        if inside < 2 { return (205, 205, 205) }
        let start = 20 + (line * 37) % 320
        if (12...30).contains(inside), x >= start, x < start + 24 {
            return (24, 24, 24)
        }
        return (255, 255, 255)
    }

    /// The whole paper page as one image (the fixture for `paperPagePixel`).
    private static func makePaperPage(width: Int, height: Int) -> CGImage? {
        makePixelImage(width: width, height: height) { x, y in
            paperPagePixel(x: x, y: y)
        }
    }

    /// Build a CGImage directly from RGBA bytes, so image row 0 is the page row
    /// passed to the closure. Going through a drawing context would make the
    /// top/bottom orientation depend on another layer of coordinates.
    private static func makePixelImage(        width: Int,
        height: Int,
        pixel: (Int, Int) -> (UInt8, UInt8, UInt8)
    ) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                let index = (y * width + x) * 4
                bytes[index] = r
                bytes[index + 1] = g
                bytes[index + 2] = b
                bytes[index + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Drive a session with one frozen frame. Returns whether the stitcher saw
    /// enough consecutive frames without growth to call the page stationary.
    private static func runStationarySession(frame: CGImage, repeats: Int) -> Bool {
        var session = ScrollAutoStitcher()
        for _ in 0..<repeats {
            _ = session.consume(frame)
        }
        return session.noGrowthStreak >= ScrollAutoStitcher.noGrowthLimit
    }

    private static func makeScrollPage(width: Int, height: Int) -> CGImage? {
        makePixelImage(width: width, height: height) { x, y in
            scrollPagePixel(x: x, y: y)
        }
    }

    /// A tall stitched image with one numbered band per captured screen. Used
    /// for the viewfinder renders so "the newest rows are at the bottom" and
    /// "the rows above the slot have slid out" are visible at a glance.
    /// The band the pod receives for one complete stitched image, composed at
    /// the pod's own display size (the same call the session makes).
    private static func previewFrame(
        _ image: CGImage?,
        for pod: ScrollPreviewPod
    ) -> ScrollPreviewFrame? {
        guard let image else { return nil }
        // The session composes its band at the size the card draws: the box
        // while the card grows, the scaled-down card once the page is longer
        // than the selection.
        return ScrollPreviewFrame.make(
            from: image,
            size: ScrollPreviewPod.bandSize(forCardSize: pod.bandCardSize)
        )
    }

    /// A page-shaped test image: white paper, a coloured masthead, headings and
    /// body lines. The coloured-block stitch fixture is great for measuring
    /// seams, but useless for judging what a *page* looks like inside the
    /// viewfinder — this one reads as a document at 10 % scale.
    private static func makeDocumentImage(width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0,
              let rep = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: width,
                  pixelsHigh: height,
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        NSColor.white.setFill()
        canvas.fill()
        let scale = CGFloat(width) / 760
        // Masthead, pinned at the top of the page.
        NSColor(srgbRed: 0.10, green: 0.22, blue: 0.42, alpha: 1).setFill()
        CGRect(x: 0, y: CGFloat(height) - 92 * scale, width: CGFloat(width), height: 92 * scale).fill()
        let title = "Unseen — scrolling capture"
        title.draw(
            at: CGPoint(x: 32 * scale, y: CGFloat(height) - 62 * scale),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 26 * scale, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
        )
        var y = CGFloat(height) - 130 * scale
        var line = 0
        while y > 20 * scale {
            if line % 14 == 0 {
                "Section \(line / 14 + 1)".draw(
                    at: CGPoint(x: 40 * scale, y: y - 22 * scale),
                    withAttributes: [
                        .font: NSFont.systemFont(ofSize: 20 * scale, weight: .bold),
                        .foregroundColor: NSColor(srgbRed: 0.12, green: 0.20, blue: 0.34, alpha: 1)
                    ]
                )
                y -= 52 * scale
            } else if line % 11 == 0 {
                NSColor(srgbRed: 0.92, green: 0.95, blue: 0.99, alpha: 1).setFill()
                CGRect(x: 40 * scale, y: y - 34 * scale, width: CGFloat(width) - 80 * scale,
                       height: 44 * scale).fill()
                NSColor(srgbRed: 0.22, green: 0.45, blue: 0.78, alpha: 1).setFill()
                CGRect(x: 40 * scale, y: y - 34 * scale, width: 5 * scale, height: 44 * scale).fill()
                y -= 64 * scale
            } else {
                let widthShare = CGFloat((line * 37) % 46 + 40) / 100
                NSColor(calibratedWhite: 0.30, alpha: 1).setFill()
                CGRect(x: 48 * scale, y: y, width: (CGFloat(width) - 96 * scale) * widthShare,
                       height: 9 * scale).fill()
                y -= 30 * scale
            }
            line += 1
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    private static func makeScrollStitchImage(
        width: Int,
        segmentHeight: Int,
        segments: Int
    ) -> CGImage? {
        let height = segmentHeight * segments
        guard width > 0, height > 0, segments > 0,
              let rep = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: width,
                  pixelsHigh: height,
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let palette: [NSColor] = [
            NSColor(srgbRed: 0.16, green: 0.36, blue: 0.72, alpha: 1),
            NSColor(srgbRed: 0.10, green: 0.55, blue: 0.48, alpha: 1),
            NSColor(srgbRed: 0.72, green: 0.36, blue: 0.16, alpha: 1),
            NSColor(srgbRed: 0.48, green: 0.22, blue: 0.62, alpha: 1),
            NSColor(srgbRed: 0.20, green: 0.50, blue: 0.24, alpha: 1),
            NSColor(srgbRed: 0.66, green: 0.16, blue: 0.30, alpha: 1)
        ]
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        for index in 0..<segments {
            // Non-flipped bitmap: segment 0 is the top of the page.
            let top = height - index * segmentHeight
            let band = CGRect(
                x: 0,
                y: CGFloat(top - segmentHeight),
                width: CGFloat(width),
                height: CGFloat(segmentHeight)
            )
            palette[index % palette.count].setFill()
            band.fill()
            NSColor.black.withAlphaComponent(0.30).setFill()
            CGRect(x: 0, y: band.maxY - 96, width: CGFloat(width), height: 96).fill()
            NSColor.black.withAlphaComponent(0.45).setFill()
            CGRect(x: 0, y: band.minY, width: CGFloat(width), height: 3).fill()

            let label = String(format: "SEG %02d", index + 1)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 52, weight: .bold),
                .foregroundColor: NSColor.white
            ]
            (label as NSString).draw(
                at: NSPoint(x: 28, y: band.maxY - 80),
                withAttributes: attributes
            )
            let row = String(format: "%05d", index * segmentHeight)
            let rowAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 20, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.8)
            ]
            (row as NSString).draw(
                at: NSPoint(x: 30, y: band.minY + 22),
                withAttributes: rowAttributes
            )
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    /// One viewport-sized frame cut out of the long page at `offset` page rows.
    private static func makeScrollFrame(
        width: Int,
        height: Int,
        offset: Int
    ) -> CGImage? {
        makePixelImage(width: width, height: height) { x, y in
            scrollPagePixel(x: x, y: offset + y)
        }
    }

    private static func pixelMatches(
        _ image: CGImage,
        x: Int,
        y: Int,
        expected: (UInt8, UInt8, UInt8),
        tolerance: Int = 2
    ) -> (Bool, String) {
        guard let actual = pixel(image, x: x, y: y) else {
            return (false, "unreadable pixel")
        }
        let matches = abs(actual.r - Int(expected.0)) <= tolerance
            && abs(actual.g - Int(expected.1)) <= tolerance
            && abs(actual.b - Int(expected.2)) <= tolerance
        return (
            matches,
            "got=(\(actual.r),\(actual.g),\(actual.b)) "
            + "want=(\(expected.0),\(expected.1),\(expected.2))"
        )
    }

    /// The centrepiece: exact overlap detection, stitching, no-overlap refusal,
    /// minimum-band refusal, search-limit refusal, and flat-content growth.
    private static func runScrollStitchTests(into directory: URL) {
        let width = 400
        let frameHeight = 500

        // 400×1300 page, three 400×500 frames at page offsets 0 / 400 / 800.
        // Adjacent overlap = 100 rows, so the stitched height must be 1300.
        guard let page = makeScrollPage(width: width, height: 1300),
              let first = makeScrollFrame(width: width, height: frameHeight, offset: 0),
              let second = makeScrollFrame(width: width, height: frameHeight, offset: 400),
              let third = makeScrollFrame(width: width, height: frameHeight, offset: 800),
              let noOverlapFrame = makeScrollFrame(width: width, height: frameHeight, offset: 600)
        else {
            check("scroll: build deterministic page and frames", false)
            return
        }

        let overlapAB = ScrollStitcher.overlap(existing: first, next: second, maxSearch: 500)
        check(
            "scroll: adjacent frames detect 100-row overlap",
            abs(overlapAB - 100) <= 2,
            "overlap=\(overlapAB) expected=100±2"
        )

        let stitched = ScrollStitcher.stitch(frames: [first, second, third])
        check(
            "scroll: three frames stitch to the 1300-row page height",
            abs(stitched.height - page.height) <= 4,
            "height=\(stitched.height) page=\(page.height) expected=1300±4"
        )
        check(
            "scroll: stitched width is unchanged",
            stitched.width == width,
            "width=\(stitched.width)"
        )

        // A captured region often contains a band that does not scroll with the
        // page — a window title bar, a toolbar, a sticky table header. Those
        // rows are identical between frames at the same y, so *no* single
        // displacement can satisfy the whole frame: a whole-frame search
        // rejects every candidate and the session reports "this page does not
        // scroll" on a page that scrolls perfectly. The band has to be found
        // and excluded before the displacement is measured.
        func withStaticHeader(_ image: CGImage, rows: Int) -> CGImage? {
            let width = image.width
            let height = image.height
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            // Bottom-left context: the image's first row is the rect's top edge.
            for row in 0..<rows {
                let shade = row % 2 == 0 ? 0.15 : 0.85
                context.setFillColor(red: shade, green: 0.2, blue: 0.6, alpha: 1)
                context.fill(CGRect(x: 0, y: height - row - 1, width: width, height: 1))
            }
            return context.makeImage()
        }
        let headerRows = 80
        if let h1 = withStaticHeader(first, rows: headerRows),
           let h2 = withStaticHeader(second, rows: headerRows),
           let h3 = withStaticHeader(third, rows: headerRows) {
            let headerOverlap = ScrollStitcher.overlap(existing: h1, next: h2, maxSearch: 500)
            check(
                "scroll: a static header band does not defeat overlap detection",
                abs(headerOverlap - 100) <= 2,
                "overlap=\(headerOverlap) expected=100±2 (0 means the band was not excluded)"
            )
            let headerStitch = ScrollStitcher.stitch(frames: [h1, h2, h3])
            check(
                "scroll: static-header frames stitch to the same page height",
                abs(headerStitch.height - stitched.height) <= 4,
                "height=\(headerStitch.height) plain=\(stitched.height)"
            )
        } else {
            check("scroll: build static-header frames", false)
        }

        // Content, not just dimensions: the seam rows must come from the right
        // page rows (frame 2 row 0 is page row 100).
        let seamChecks: [(Int, Int, String)] = [
            (10, 0, "top row 0"),
            (10, 499, "frame 1 bottom row 499"),
            (10, 500, "first appended row = page row 500"),
            (10, 899, "page row 899"),
            (10, 1299, "page row 1299")
        ]
        for (x, y, label) in seamChecks {
            let (matches, detail) = pixelMatches(
                stitched,
                x: x,
                y: y,
                expected: scrollPagePixel(x: x, y: y)
            )
            check("scroll: stitched pixel at \(label) matches the page", matches, detail)
        }

        // The user's requested "long page 1200 tall" case. With 500 pt frames,
        // 3 frames covering 1200 rows necessarily overlap by 150, not 100:
        // 3 × 500 − 2 × 150 = 1200. Kept as a second, independent assertion so
        // the output-height property is proven for 1200 as well.
        guard let page1200 = makeScrollPage(width: width, height: 1200),
              let a1200 = makeScrollFrame(width: width, height: frameHeight, offset: 0),
              let b1200 = makeScrollFrame(width: width, height: frameHeight, offset: 350),
              let c1200 = makeScrollFrame(width: width, height: frameHeight, offset: 700)
        else {
            check("scroll: build 1200-row page", false)
            return
        }
        let overlap1200 = ScrollStitcher.overlap(existing: a1200, next: b1200, maxSearch: 500)
        check(
            "scroll: 1200-row page frames detect 150-row overlap",
            abs(overlap1200 - 150) <= 2,
            "overlap=\(overlap1200) expected=150±2 (3×500−2×150=1200)"
        )
        let stitched1200 = ScrollStitcher.stitch(frames: [a1200, b1200, c1200])
        check(
            "scroll: 1200-row page stitches to 1200",
            abs(stitched1200.height - page1200.height) <= 4,
            "height=\(stitched1200.height) page=\(page1200.height) expected=1200±4"
        )

        // Disjoint content must not be stitched by force.
        let disjoint = ScrollStitcher.overlap(
            existing: first,
            next: noOverlapFrame,
            maxSearch: 500
        )
        check(
            "scroll: disjoint frames report no overlap",
            disjoint == 0,
            "overlap=\(disjoint)"
        )
        let disjointStitch = ScrollStitcher.stitch(frames: [first, noOverlapFrame])
        check(
            "scroll: disjoint frames append without trimming",
            disjointStitch.height == 1000,
            "height=\(disjointStitch.height) expected=1000"
        )

        // A 10-row match is below the acceptance band.
        guard let shortA = makeScrollFrame(width: width, height: frameHeight, offset: 0),
              let shortB = makeScrollFrame(width: width, height: frameHeight, offset: 490)
        else {
            check("scroll: build near-miss frames", false)
            return
        }
        let belowMinimum = ScrollStitcher.overlap(
            existing: shortA,
            next: shortB,
            maxSearch: 500
        )
        check(
            "scroll: 10-row near match is rejected (minimum 20)",
            belowMinimum == 0,
            "overlap=\(belowMinimum)"
        )

        // The caller's search window is honoured.
        let limited = ScrollStitcher.overlap(
            existing: first,
            next: second,
            maxSearch: 50
        )
        check(
            "scroll: overlap search respects maxSearch",
            limited == 0,
            "overlap=\(limited) with maxSearch=50"
        )

        // Flat/identical content: every offset scores 0. The tie-break takes
        // the largest overlap, which turns a frozen page into a no-op instead
        // of appending a duplicate frame forever.
        guard let flat = makeSolidImage(
            color: NSColor(srgbRed: 0.51, green: 0.52, blue: 0.53, alpha: 1),
            width: width,
            height: frameHeight
        ) else {
            check("scroll: build flat frame", false)
            return
        }
        let flatFull = ScrollStitcher.overlap(existing: flat, next: flat, maxSearch: frameHeight)
        check(
            "scroll: identical flat frames resolve to a full overlap",
            flatFull == frameHeight,
            "overlap=\(flatFull)"
        )
        let flatCapped = ScrollStitcher.overlap(existing: flat, next: flat, maxSearch: 200)
        check(
            "scroll: flat-frame overlap is bounded by maxSearch",
            flatCapped == 200,
            "overlap=\(flatCapped) with maxSearch=200"
        )
        let flatStitch = ScrollStitcher.stitch(frames: [flat, flat, flat, flat])
        check(
            "scroll: repeated flat frames do not grow the image",
            flatStitch.height <= frameHeight + 1,
            "height=\(flatStitch.height) input=\(frameHeight)"
        )

        // MARK: Live session
        //
        // The controller samples the region continuously, stitches each frame
        // into the accumulated image and redraws the preview after every sample.
        // Those decisions are pure and must stay testable without a window
        // server. The page is scrolled by the user (iShot's default); "Auto
        // Scroll" is a separate opt-in.
        var session = ScrollAutoStitcher()
        let firstOutcome = session.consume(first)
        let secondOutcome = session.consume(second)
        let thirdOutcome = session.consume(third)
        check(
            "scroll: the live session appends frames incrementally",
            firstOutcome == .first
                && secondOutcome == .appended(rows: 400)
                && thirdOutcome == .appended(rows: 400)
                && abs((session.image?.height ?? 0) - page.height) <= 4
                && session.grew
                && session.frameCount == 3,
            "outcomes=\(firstOutcome)/\(secondOutcome)/\(thirdOutcome) "
                + "height=\(session.image?.height ?? 0) "
                + "lastOverlap=\(session.lastOverlap)"
        )
        check(
            "scroll: a frozen page produces no growth",
            runStationarySession(frame: first, repeats: 5) == true
                && runStationarySession(frame: first, repeats: 2) == false
                && {
                    var frozen = ScrollAutoStitcher()
                    for _ in 0..<5 { _ = frozen.consume(first) }
                    return frozen.grew == false
                }(),
            "noGrowthLimit=\(ScrollAutoStitcher.noGrowthLimit)"
        )

        // MARK: Scrolling back up
        //
        // The owner's report: "my mouse sliding up and down stitched the same
        // photo again". A page that keeps going down grows; a frame from above
        // what was already captured must add nothing — it is either content
        // that is already in the stitch or content above its first row, and an
        // append-only stitch can never represent either.
        guard let longPage = makeScrollPage(width: width, height: 2400),
              let down0 = makeScrollFrame(width: width, height: frameHeight, offset: 0),
              let down1 = makeScrollFrame(width: width, height: frameHeight, offset: 400),
              let down2 = makeScrollFrame(width: width, height: frameHeight, offset: 800),
              let down3 = makeScrollFrame(width: width, height: frameHeight, offset: 1200)
        else {
            check("scroll: build the long page for the direction checks", false)
            return
        }
        var direction = ScrollAutoStitcher()
        _ = direction.consume(down0)
        _ = direction.consume(down1)
        _ = direction.consume(down2)
        let heightAfterDown = direction.height
        let upOutcome = direction.consume(down1)
        let heightAfterUp = direction.height
        let downAgainOutcome = direction.consume(down2)
        let heightAfterDownAgain = direction.height
        let downPastOutcome = direction.consume(down3)
        check(
            "scroll: a frame from above the captured rows appends nothing",
            upOutcome == .retraced
                && heightAfterUp == heightAfterDown
                && heightAfterDown == 1300,
            "outcome=\(upOutcome) height=\(heightAfterUp) before=\(heightAfterDown)"
        )
        check(
            "scroll: coming back down through captured rows appends nothing",
            downAgainOutcome == .retraced && heightAfterDownAgain == heightAfterUp,
            "outcome=\(downAgainOutcome) height=\(heightAfterDownAgain)"
        )
        check(
            "scroll: scrolling past the captured bottom appends again",
            downPastOutcome == .appended(rows: 400)
                && direction.height == 1700,
            "outcome=\(downPastOutcome) height=\(direction.height)"
        )
        // The proof that nothing was stitched twice: the composed image must be
        // the page itself, row for row, at every seam the round trip crossed.
        if let composed = direction.image {
            let seams = [0, 499, 500, 899, 900, 1299, 1300, 1699]
            var allMatch = composed.height == 1700
            for y in seams {
                let (matches, _) = pixelMatches(
                    composed,
                    x: 10,
                    y: y,
                    expected: scrollPagePixel(x: 10, y: y)
                )
                allMatch = allMatch && matches
            }
            check(
                "scroll: a down-up-down round trip leaves every row of the page once",
                allMatch,
                "height=\(composed.height) expected=1700"
            )
        } else {
            check("scroll: a down-up-down round trip leaves every row of the page once", false)
        }
        // Same round trip, but starting half-way down the page: the first rows
        // the user sees are *above* the stitch's first row, which the append
        // cannot represent. They must be skipped instead of being appended.
        var middle = ScrollAutoStitcher()
        _ = middle.consume(down2)
        let aboveOne = middle.consume(down1)
        let aboveTwo = middle.consume(down0)
        let aboveHeight = middle.height
        let returningOne = middle.consume(down1)
        let returningTwo = middle.consume(down2)
        let returningThree = middle.consume(down3)
        check(
            "scroll: scrolling up above the first captured row appends nothing",
            aboveOne == .retraced && aboveTwo == .retraced && aboveHeight == 500,
            "outcomes=\(aboveOne)/\(aboveTwo) height=\(aboveHeight)"
        )
        check(
            "scroll: returning down through the first captured row appends nothing",
            returningOne == .retraced && returningTwo == .retraced && middle.height == 900
                && returningThree == .appended(rows: 400),
            "outcomes=\(returningOne)/\(returningTwo)/\(returningThree) "
                + "height=\(middle.height)"
        )
        if let composed = middle.image {
            let (matches, _) = pixelMatches(
                composed,
                x: 10,
                y: 0,
                expected: scrollPagePixel(x: 10, y: 800)
            )
            check(
                "scroll: the round trip starts at the row the session started on",
                composed.height == 900 && matches,
                "height=\(composed.height) firstRow=\(matches)"
            )
        } else {
            check("scroll: the round trip starts at the row the session started on", false)
        }

        // A paper-shaped page is the case that used to break: white body, one
        // rule per line, so a fraction averaged over every pixel can be fooled
        // by paper. The per-line mark is the only thing that tells lines apart.
        if let paperPage = makePaperPage(width: width, height: 1600) {
            func paperFrame(_ offset: Int) -> CGImage? {
                makePixelImage(width: width, height: frameHeight) { x, y in
                    paperPagePixel(x: x, y: offset + y)
                }
            }
            if let top = paperFrame(0), let lower = paperFrame(260),
               let bottom = paperFrame(500) {
                var paperSession = ScrollAutoStitcher()
                _ = paperSession.consume(top)
                let grown = paperSession.height
                _ = paperSession.consume(lower)
                let grownHeight = paperSession.height
                let upward = paperSession.consume(top)
                check(
                    "scroll: a paper page scrolled back up adds no rows",
                    upward == .retraced && paperSession.height == grownHeight
                        && grownHeight > grown,
                    "outcome=\(upward) height=\(paperSession.height) grown=\(grownHeight)"
                )
                // A whole screen back up: the two frames share nothing the
                // matcher can measure, and the stitch's paper happens to line
                // up at a few offsets. That coincidence must not be appended.
                var jump = ScrollAutoStitcher()
                _ = jump.consume(bottom)
                let jumpHeight = jump.height
                let jumped = jump.consume(top)
                check(
                    "scroll: a full screen back up a paper page adds no rows",
                    jump.height == jumpHeight && jumpHeight == 500,
                    "outcome=\(jumped) height=\(jump.height) before=\(jumpHeight)"
                )
                // A still page is *stillness*, not a retrace. Reporting a
                // one-row move here reset the stillness streak, and a session
                // that never collects stationary frames never reaches the
                // bottom detector.
                var stilled = ScrollAutoStitcher()
                _ = stilled.consume(lower)
                let still1 = stilled.consume(lower)
                let still2 = stilled.consume(lower)
                let still3 = stilled.consume(lower)
                check(
                    "scroll: a still paper page reads as stillness, not as a retrace",
                    still1 == .stationary && still2 == .stationary && still3 == .stationary
                        && stilled.noGrowthStreak >= 3,
                    "outcomes=\(still1)/\(still2)/\(still3) "
                        + "streak=\(stilled.noGrowthStreak)"
                )
            } else {
                check("scroll: a paper page scrolled back up adds no rows", false)
                check("scroll: a full screen back up a paper page adds no rows", false)
            }
            _ = paperPage
        } else {
            check("scroll: a paper page scrolled back up adds no rows", false)
            check("scroll: a full screen back up a paper page adds no rows", false)
        }
        // A smooth-scrolled page is drawn at a *fractional* offset, so the same
        // glyph lands on different pixels from one sample to the next. Measured
        // on a real Chrome page: the true offset scored 18 % on the detail
        // pixels while every wrong offset scored 30 %+ on the plain fraction, so
        // the pixel matcher refused the frame and the viewfinder stopped growing
        // mid-scroll — the picture lost its last screen and the session never
        // reached "finished". The row profile averages that phase away.
        //
        // These frames keep the row *luminance* (the profile) and change every
        // pixel (the detail): exactly that situation, in a deterministic form.
        func phasePageRow(_ pageRow: Int) -> Int {
            var hash = UInt64(bitPattern: Int64(pageRow)) &* 0x9E3779B97F4A7C15
            hash ^= hash >> 30
            hash &*= 0xBF58476D1CE4E5B9
            hash ^= hash >> 27
            return Int(hash % 200) + 20
        }
        func phaseFrame(offset: Int, phase: Int) -> CGImage? {
            makePixelImage(width: 400, height: 500) { x, y in
                // Ten vertical bands, five of them lighter. The *rotation* of
                // the bands changes between samples, so every sampled pixel
                // differs while the row's mean luminance stays put.
                let base = phasePageRow(offset + y)
                let band = (x / 40 + phase) % 2
                let value = UInt8(max(0, min(255, base + band * 40 + (y % 2))))
                return (value, value, value)
            }
        }
        let phaseTop = phaseFrame(offset: 0, phase: 1)
        let phaseLower = phaseFrame(offset: 400, phase: 2)
        let phaseTopRaster = phaseTop.flatMap { ScrollStitcher.SampledRaster($0) }
        let phaseLowerRaster = phaseLower.flatMap { ScrollStitcher.SampledRaster($0) }
        if let phaseTop, let phaseLower,
           let phaseTopRaster, let phaseLowerRaster {
            let measured = ScrollStitcher.profileShift(
                previous: phaseTopRaster,
                next: phaseLowerRaster
            )
            check(
                "scroll: a sub-pixel phase change still reads as the same page moving",
                measured == 400,
                "shift=\(String(describing: measured))"
            )
            var phased = ScrollAutoStitcher()
            _ = phased.consume(phaseTop)
            let phasedBefore = phased.height
            let phasedOutcome = phased.consume(phaseLower)
            check(
                "scroll: a frame the detail pixels cannot place is appended from its row profile",
                phasedOutcome == .appended(rows: 400) && phased.height == phasedBefore + 400,
                "outcome=\(phasedOutcome) height=\(phased.height) before=\(phasedBefore)"
            )
        } else {
            check("scroll: a sub-pixel phase change still reads as the same page moving", false)
            check("scroll: a frame the detail pixels cannot place is appended from its row profile", false)
        }
        // The profile only decides when one shift wins clearly. A page whose
        // rows repeat every 400 px has several equally good peaks, and picking
        // one of them would append the same rows twice.
        func repeatingFrame(offset: Int, phase: Int) -> CGImage? {
            makePixelImage(width: 400, height: 500) { x, y in
                let line = ((offset + y) / 50) % 8
                let noise = Int((UInt64(x &* 7919 &+ y &* 104729 &+ phase &* 65537)) % 41) - 20
                let value = UInt8(max(0, min(255, 60 + line * 22 + noise)))
                return (value, value, value)
            }
        }
        let repeatA = repeatingFrame(offset: 0, phase: 3)
        let repeatB = repeatingFrame(offset: 50, phase: 4)
        if let repeatA, let repeatB,
           let repeatARaster = ScrollStitcher.SampledRaster(repeatA),
           let repeatBRaster = ScrollStitcher.SampledRaster(repeatB) {
            let measured = ScrollStitcher.profileShift(
                previous: repeatARaster,
                next: repeatBRaster
            )
            check(
                "scroll: a page of repeated rows does not invent a motion from its profile",
                measured == nil,
                "shift=\(String(describing: measured))"
            )
        } else {
            check("scroll: a page of repeated rows does not invent a motion from its profile", false)
        }

        // Ending the session on stillness is only safe *after* the page has
        // grown, and only after a pause that is long enough to be deliberate.
        // A session that ends because the user has not scrolled yet is exactly
        // the "no reaction" bug the recording rules out; a session that ends
        // because the user paused for a second is the "长截图滑不动" one.
        check(
            "scroll: stillness never ends a session that has not grown",
            ScrollCaptureController.shouldAutoFinish(
                appendedFrames: 0,
                stationaryFrames: 0,
                drive: .manual,
                secondsSinceGrowth: 0
            ) == false
                && ScrollCaptureController.shouldAutoFinish(
                    appendedFrames: 0,
                    stationaryFrames: 30,
                    drive: .manual,
                    secondsSinceGrowth: 30
                ) == false,
            "manual limit=\(ScrollCaptureController.manualStillnessLimit)"
        )
        check(
            "scroll: one appended frame is not enough for the manual bottom detector",
            ScrollCaptureController.shouldAutoFinish(
                appendedFrames: 1,
                stationaryFrames: 30,
                drive: .manual,
                secondsSinceGrowth: 30
            ) == false,
            "minimum=\(ScrollCaptureController.minimumAppendedFrames(for: .manual))"
        )
        check(
            "scroll: a grown page finishes after the stillness window",
            ScrollCaptureController.shouldAutoFinish(
                appendedFrames: 3,
                stationaryFrames: 4,
                drive: .manual,
                secondsSinceGrowth: 0.5
            ) == false
                && ScrollCaptureController.shouldAutoFinish(
                    appendedFrames: 3,
                    stationaryFrames: 4,
                    drive: .manual,
                    secondsSinceGrowth: ScrollCaptureController.manualStillnessLimit
                ) == true,
            "limit=\(ScrollCaptureController.manualStillnessLimit)"
        )
        // The user's exact complaint: "滚一段 → 停 2 秒 → 再滚". A two-second
        // pause is a normal read, not the end of the page.
        check(
            "scroll: a two second pause in a manual scroll does not end the session",
            ScrollCaptureController.shouldAutoFinish(
                appendedFrames: 6,
                stationaryFrames: 20,
                drive: .manual,
                secondsSinceGrowth: 2.0
            ) == false
                && ScrollCaptureController.manualStillnessLimit >= 3.0,
            "limit=\(ScrollCaptureController.manualStillnessLimit)"
        )
        // Stillness has to be *observed*: the clock alone can run while no
        // frame is being sampled.
        check(
            "scroll: elapsed time alone does not finish without unchanged frames",
            ScrollCaptureController.shouldAutoFinish(
                appendedFrames: 5,
                stationaryFrames: ScrollCaptureController.stillnessFrames - 1,
                drive: .manual,
                secondsSinceGrowth: 30
            ) == false
                && ScrollCaptureController.shouldAutoFinish(
                    appendedFrames: 5,
                    stationaryFrames: ScrollCaptureController.stillnessFrames,
                    drive: .manual,
                    secondsSinceGrowth: 30
                ) == true,
            "frames=\(ScrollCaptureController.stillnessFrames)"
        )
        // Auto Scroll keeps the short window: it posts a wheel every tick, so a
        // page that stops moving really has reached its end.
        check(
            "scroll: Auto Scroll keeps the short stillness window",
            ScrollCaptureController.stillnessLimit(for: .auto)
                == ScrollCaptureController.autoStillnessLimit
                && ScrollCaptureController.autoStillnessLimit < ScrollCaptureController.manualStillnessLimit
                && ScrollCaptureController.shouldAutoFinish(
                    appendedFrames: 1,
                    stationaryFrames: 4,
                    drive: .auto,
                    secondsSinceGrowth: 1.5
                ) == true
                && ScrollCaptureController.shouldAutoFinish(
                    appendedFrames: 1,
                    stationaryFrames: 4,
                    drive: .manual,
                    secondsSinceGrowth: 1.5
                ) == false,
            "auto=\(ScrollCaptureController.autoStillnessLimit) "
                + "manual=\(ScrollCaptureController.manualStillnessLimit)"
        )
        // Sampling has to outrun the page: at iShot's observed ~1500 pt/s a
        // 0.35 s interval moves more than one screen and the overlap is gone.
        check(
            "scroll: sampling is fast enough for a fast flick",
            ScrollCaptureController.defaultInterval <= 0.15
                && ScrollCaptureController.defaultInterval >= 0.05,
            "interval=\(ScrollCaptureController.defaultInterval)"
        )

        // MARK: Click-through for the whole session
        //
        // The overlay is a full-screen window sitting on top of the page. While
        // it is interactive the wheel is addressed to it, not to the page, and
        // the page never moves — the user's "长截图滑不动". Transparency is
        // therefore a property of the *session*, not of Auto Scroll: it is
        // asked for when sampling starts and handed back only when the session
        // ends. Releasing it for Auto Scroll would eat the manual scroll the
        // user reaches for next.
        if let sessionScreen = NSScreen.screens.first {
            var passthrough: [Bool] = []
            let live = ScrollCaptureController(
                region: CGRect(x: 0, y: 0, width: 320, height: 240),
                screen: sessionScreen,
                interval: 0.35,
                includeCursor: false,
                maxFrames: 20,
                canAutoScroll: true
            )
            live.onPassthrough = { passthrough.append($0) }
            live.start()
            check(
                "scroll: the session is click-through from the first sample",
                passthrough == [true],
                "events=\(passthrough)"
            )
            // A wheel that still lands on the overlay must not start a
            // re-post loop; it only re-asserts transparency.
            live.forwardWheel(scrollEvent(deltaY: -40))
            check(
                "scroll: a stray wheel re-asserts click-through instead of re-posting",
                passthrough == [true, true],
                "events=\(passthrough)"
            )
            live.startAutoScroll()
            live.stopAutoScroll()
            check(
                "scroll: releasing Auto Scroll keeps the session click-through",
                passthrough == [true, true, true],
                "events=\(passthrough)"
            )
            live.finish()
            check(
                "scroll: stopping the session makes the overlay interactive again",
                passthrough.last == false && passthrough.filter { $0 }.count == 3,
                "events=\(passthrough)"
            )

            // A finished session is not a dead end. 继续 restarts sampling on
            // the same stitch, and — the part that matters — hands the wheel
            // back to the page: resuming without click-through would restart
            // the capture on a page that cannot move, i.e. the original bug.
            func step(
                _ outcome: ScrollAutoStitcher.Outcome,
                height: Int,
                grew: Bool
            ) -> ScrollStitchWorker.Step {
                ScrollStitchWorker.Step(
                    outcome: outcome,
                    frame: nil,
                    height: height,
                    grew: grew,
                    frameCount: 2,
                    lastOverlap: 1200,
                    stitchMilliseconds: 0,
                    bandMilliseconds: 0
                )
            }
            var resumePassthrough: [Bool] = []
            let resumed = ScrollCaptureController(
                region: CGRect(x: 0, y: 0, width: 320, height: 240),
                screen: sessionScreen,
                interval: 0.35,
                includeCursor: false,
                maxFrames: 20,
                canAutoScroll: true
            )
            resumed.onPassthrough = { resumePassthrough.append($0) }
            resumed.start()
            resumed.record(step(.appended(rows: 60), height: 1200, grew: true))
            resumed.record(step(.stationary, height: 1200, grew: true))
            resumed.finish(reason: .bottomReached)
            check(
                "scroll: a session that stopped on its own offers 继续",
                resumed.canResume,
                "stop=pending height=\(resumed.stitchedHeight)"
            )
            resumed.resume()
            check(
                "scroll: resume keeps the stitch and hands the wheel back",
                resumed.isRunning
                    && resumePassthrough.last == true
                    && resumed.stitchedHeight == 1200
                    && resumed.frameCount == 2,
                "running=\(resumed.isRunning) events=\(resumePassthrough) "
                    + "height=\(resumed.stitchedHeight) frames=\(resumed.frameCount)"
            )
            resumed.abandon()

            // No room left to append = no 继续. The button would be a promise
            // the session cannot keep.
            let capped = ScrollCaptureController(
                region: CGRect(x: 0, y: 0, width: 320, height: 240),
                screen: sessionScreen,
                interval: 0.35,
                includeCursor: false,
                maxFrames: 20,
                canAutoScroll: true
            )
            capped.start()
            capped.record(step(.appended(rows: 60), height: 1200, grew: true))
            capped.finish(reason: .frameLimit)
            check(
                "scroll: a session stopped by the frame ceiling offers only 完成",
                capped.canResume == false,
                "resumable=\(capped.canResume)"
            )
        }

        // MARK: A floating window in front of the page
        //
        // Pages keep auxiliary windows pinned above themselves — a translate
        // bubble, a floating card, a detached toolbar. Those windows do not
        // scroll with the page, so every candidate overlap disagrees on their
        // rows and the session reports "this window does not scroll" while the
        // user scrolls perfectly well. The capture leaves them out instead of
        // teaching the matcher to distrust pixels.
        let ownPID: pid_t = 900_001
        let pageID: CGWindowID = 4242
        let bubbleID: CGWindowID = 5151
        let hiddenBubbleID: CGWindowID = 6161
        let pagePoint = CGPoint(x: 640, y: 527)
        let pageRegion = CGRect(x: 210, y: 177, width: 860, height: 700)
        func windowInfo(
            _ id: CGWindowID,
            _ pid: pid_t,
            _ rect: CGRect,
            layer: Int = 0
        ) -> [String: Any] {
            [
                kCGWindowNumber as String: id,
                kCGWindowLayer as String: layer,
                kCGWindowOwnerPID as String: pid,
                kCGWindowBounds as String: [
                    "X": rect.minX, "Y": rect.minY,
                    "Width": rect.width, "Height": rect.height
                ]
            ]
        }
        let stackedWindows: [[String: Any]] = [
            // Above the page but far away from the captured rectangle.
            windowInfo(hiddenBubbleID, 777, CGRect(x: 20, y: 20, width: 120, height: 60)),
            // Above the page and over the region: a floating bubble.
            windowInfo(bubbleID, 777, CGRect(x: 574, y: 160, width: 358, height: 87)),
            // Our own overlay is never a target and never an auxiliary window.
            windowInfo(999, ownPID, CGRect(x: 0, y: 0, width: 1728, height: 1117)),
            // The page itself.
            windowInfo(pageID, 777, CGRect(x: 200, y: 80, width: 900, height: 820)),
            // Behind the page.
            windowInfo(7171, 777, CGRect(x: 100, y: 100, width: 500, height: 400)),
            // A panel level window is never part of the page stack.
            windowInfo(8181, 777, CGRect(x: 300, y: 300, width: 200, height: 200), layer: 3)
        ]
        let target = ScrollCaptureController.targetWindow(
            in: stackedWindows,
            point: pagePoint,
            ownPID: ownPID
        )
        check(
            "scroll: the page window is the topmost normal window at the region centre",
            target?.pid == 777 && target?.windowID == pageID,
            "target=\(String(describing: target))"
        )
        let auxiliary = ScrollCaptureController.auxiliaryWindows(
            in: stackedWindows,
            above: pageID,
            region: pageRegion,
            ownPID: ownPID
        )
        check(
            "scroll: only windows in front of the page and over the region are excluded",
            auxiliary == [bubbleID],
            "aux=\(auxiliary) expected=[\(bubbleID)]"
        )
        check(
            "scroll: the page, our overlay and windows behind it stay in the capture",
            !auxiliary.contains(pageID)
                && !auxiliary.contains(7171)
                && !auxiliary.contains(999),
            "aux=\(auxiliary)"
        )

        // MARK: Preview geometry
        // MARK: Preview geometry
        //
        // Position and width are a pure function of the selection, never of the
        // stitched length. The card freezes at the selection's height; its
        // frame is the card, with no reserved strip.
        let refScreen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let refRegion = CGRect(x: 612, y: 445, width: 807, height: 445)
        let placement = ScrollPreviewPlacement.make(region: refRegion, screen: refScreen)
        check(
            "scroll: the card freezes at exactly the selection's height",
            abs(placement.card.height - refRegion.height) < 0.01
                && abs(placement.cardSize.height - refRegion.height) < 0.01
                && placement.frame == placement.card,
            "card=\(format(placement.card)) region=\(format(refRegion))"
        )
        check(
            "scroll: the frame is the card, with no reserved strip",
            abs(placement.frame.height - placement.card.height) < 0.01
                && abs(placement.frame.width - placement.card.width) < 0.01,
            "frame=\(format(placement.frame))"
        )
        check(
            "scroll: the card takes a share of the width and stays narrower",
            placement.card.width >= ScrollPreviewPod.cardWidthRange.lowerBound - 0.01
                && placement.card.width <= ScrollPreviewPod.cardWidthRange.upperBound + 0.01
                && placement.card.width < refRegion.width,
            "cardWidth=\(placement.card.width) regionWidth=\(refRegion.width)"
        )
        check(
            "scroll: the viewfinder hangs off the selection's left, bottom-aligned",
            placement.onLeft
                && abs(placement.card.maxX - (refRegion.minX - ScrollPreviewPod.gap)) < 0.01
                && abs(placement.card.minY - refRegion.minY) < 0.01,
            "frame=\(format(placement.frame)) region=\(format(refRegion))"
        )
        check(
            "scroll: the viewfinder is fully outside the captured region",
            !placement.frame.intersects(refRegion)
                && ScrollPreviewPod.screenInset >= 0,
            "frame=\(format(placement.frame))"
        )
        check(
            "scroll: placement cannot depend on the stitched length",
            placement == ScrollPreviewPlacement.make(region: refRegion, screen: refScreen)
                && placement.card.height == refRegion.height,
            "frame=\(format(placement.frame))"
        )
        let tallRegion = CGRect(x: 300, y: 60, width: 760, height: 900)
        let tall = ScrollPreviewPlacement.make(region: tallRegion, screen: refScreen)
        check(
            "scroll: a tall selection keeps the equal height",
            abs(tall.card.height - tallRegion.height) < 0.01
                && tall.frame.maxY <= refScreen.maxY - ScrollPreviewPod.screenInset + 0.01,
            "card=\(format(tall.card)) frame=\(format(tall.frame))"
        )
        let usableHeight = refScreen.height - ScrollPreviewPod.screenInset * 2
        let screenHigh = CGRect(x: 300, y: 0, width: 760, height: usableHeight)
        let screenHighPlacement = ScrollPreviewPlacement.make(
            region: screenHigh,
            screen: refScreen
        )
        check(
            "scroll: a screen-tall selection keeps the equal height",
            abs(screenHighPlacement.card.height - usableHeight) < 0.01
                && screenHighPlacement.frame == screenHighPlacement.card,
            "card=\(format(screenHighPlacement.card)) "
                + "frame=\(format(screenHighPlacement.frame))"
        )
        let overTall = CGRect(x: 300, y: 0, width: 760, height: refScreen.height)
        let clamped = ScrollPreviewPlacement.make(region: overTall, screen: refScreen)
        check(
            "scroll: only a selection taller than the screen clamps the card",
            clamped.card.height < overTall.height
                && abs(clamped.card.height - usableHeight) < 0.01
                && clamped.frame.maxY
                    <= refScreen.maxY - ScrollPreviewPod.screenInset + 0.01,
            "card=\(format(clamped.card)) frame=\(format(clamped.frame))"
        )
        let leftRegion = CGRect(x: 60, y: 300, width: 600, height: 400)
        let rightSide = ScrollPreviewPlacement.make(region: leftRegion, screen: refScreen)
        check(
            "scroll: a left-hand selection puts the viewfinder on its right",
            rightSide.onLeft == false
                && abs(rightSide.card.minX - (leftRegion.maxX + ScrollPreviewPod.gap)) < 0.01
                && !rightSide.frame.intersects(leftRegion)
                && abs(rightSide.card.height - leftRegion.height) < 0.01,
            "frame=\(format(rightSide.frame))"
        )
        let fullWidth = CGRect(x: 0, y: 300, width: 1728, height: 300)
        let fallback = ScrollPreviewPlacement.make(region: fullWidth, screen: refScreen)
        check(
            "scroll: a full-width selection falls back above the region",
            !fallback.overlapsRegion && fallback.card.minY >= fullWidth.maxY
                && abs(fallback.card.height - fullWidth.height) < 0.01,
            "frame=\(format(fallback.frame)) overlaps=\(fallback.overlapsRegion)"
        )
        let fullWidthTall = CGRect(x: 0, y: 200, width: 1728, height: 600)
        let overfull = ScrollPreviewPlacement.make(region: fullWidthTall, screen: refScreen)
        check(
            "scroll: a screen-filling selection keeps the equal height even overlapping",
            overfull.overlapsRegion
                && abs(overfull.card.height - fullWidthTall.height) < 0.01,
            "frame=\(format(overfull.frame)) overlaps=\(overfull.overlapsRegion)"
        )

        // MARK: The card grows, then freezes
        let growthPod = ScrollPreviewPod()
        growthPod.configure(
            cardSize: placement.cardSize,
            innerEdgeOnRight: placement.onLeft
        )
        check(
            "scroll: a configured pod starts short, under its final height",
            abs(growthPod.cardSize.height - refRegion.height) < 0.01
                && growthPod.visibleCardHeight < growthPod.cardSize.height - 1
                && growthPod.isFrozen == false,
            "visible=\(growthPod.visibleCardHeight) final=\(growthPod.cardSize.height)"
        )
        // The band is always composed at the final well size, so "content" is
        // measured on that scale; the visible card must be content + chrome.
        // The card freezes when the *content* is exactly one well high. With a
        // 220 pt box and 8 pt padding that is a 204 pt-wide well, so the page
        // height that lands on the boundary is wellHeight × imageWidth / wellWidth.
        let freezePixels = Int(
            ((placement.cardSize.height - ScrollPreviewPod.chromeHeight)
                * 1520 / (placement.cardSize.width - ScrollPreviewPod.padding * 2))
                .rounded()
        )
        guard let oneScreen = makeDocumentImage(width: 1520, height: 840),
              let threeScreens = makeDocumentImage(width: 1520, height: 2520),
              let atFullHeight = makeDocumentImage(width: 1520, height: freezePixels),
              let nineScreens = makeDocumentImage(width: 1520, height: freezePixels * 3)
        else {
            check("scroll: build growing page images", false)
            return
        }
        func feed(_ image: CGImage, into pod: ScrollPreviewPod) {
            pod.update(preview: previewFrame(image, for: pod), phase: .capturing, autoScrolling: false)
        }
        feed(oneScreen, into: growthPod)
        let firstCard = growthPod.cardRect
        let firstContent = growthPod.contentHeight
        check(
            "scroll: the first screen makes a short, sharp card — not an empty well",
            growthPod.visibleCardHeight < growthPod.cardSize.height - 1
                && abs(growthPod.wellRect.height - firstContent) < 1.5
                && abs(growthPod.visibleCardHeight
                    - (ScrollPreviewPod.chromeHeight + firstContent)) < 1.5,
            "visible=\(growthPod.visibleCardHeight) content=\(firstContent) "
                + "well=\(growthPod.wellRect.height)"
        )
        check(
            "scroll: the growing card keeps its bottom edge and its width",
            abs(firstCard.minY) < 0.01
                && abs(firstCard.width - growthPod.cardSize.width) < 0.01,
            "card=\(format(firstCard)) finalWidth=\(growthPod.cardSize.width)"
        )
        feed(threeScreens, into: growthPod)
        let midCard = growthPod.cardRect
        check(
            "scroll: three screens make the card taller, still under the selection",
            midCard.height > firstCard.height + 1
                && midCard.height < growthPod.cardSize.height - 1
                && growthPod.visibleCardHeight < refRegion.height - 1,
            "first=\(firstCard.height) mid=\(midCard.height) "
                + "final=\(growthPod.cardSize.height)"
        )
        check(
            "scroll: the mid card's well is still exactly its content",
            abs(growthPod.wellRect.height - growthPod.contentHeight) < 1.5,
            "well=\(growthPod.wellRect.height) content=\(growthPod.contentHeight)"
        )
        feed(atFullHeight, into: growthPod)
        let frozenCard = growthPod.cardRect
        let frozenContent = growthPod.contentHeight
        check(
            "scroll: the card reaches exactly the selection's height, then freezes",
            abs(frozenCard.height - growthPod.cardSize.height) < 1
                && growthPod.isFrozen
                && growthPod.scale == 1
                && abs(frozenCard.height - refRegion.height) < 1,
            "card=\(format(frozenCard)) scale=\(growthPod.scale) "
                + "selectionHeight=\(refRegion.height)"
        )
        check(
            "scroll: at the freeze point the well is the box's well",
            abs(growthPod.wellRect.height - growthPod.fullWellRect.height) < 1.5
                && abs(growthPod.wellRect.width - growthPod.fullWellRect.width) < 0.01,
            "well=\(format(growthPod.wellRect)) full=\(format(growthPod.fullWellRect))"
        )

        // P1 supplement: past the selection's height the card does **not** keep
        // growing. It scales the whole card down, anchored on the corner nearest
        // the selection, so the gap and the bottom edge never move.
        feed(nineScreens, into: growthPod)
        let shrunkCard = growthPod.cardRect
        let shrunkContent = growthPod.contentHeight
        check(
            "scroll: a longer page scales the whole card down instead of growing it",
            growthPod.scale < 1
                && shrunkCard.height < frozenCard.height - 1
                && shrunkCard.width < frozenCard.width - 1
                && growthPod.isFrozen,
            "card=\(format(shrunkCard)) frozen=\(format(frozenCard)) "
                + "scale=\(growthPod.scale)"
        )
        let anchoredEdgeHolds = growthPod.innerEdgeOnRight
            ? abs(shrunkCard.maxX - growthPod.cardSize.width) < 0.01
            : abs(shrunkCard.minX) < 0.01
        check(
            "scroll: shrinking keeps the bottom edge and the selection-side edge",
            abs(shrunkCard.minY) < 0.01 && anchoredEdgeHolds,
            "card=\(format(shrunkCard)) boxWidth=\(growthPod.cardSize.width) "
                + "innerRight=\(growthPod.innerEdgeOnRight)"
        )
        check(
            "scroll: the shrunk card keeps a legible floor",
            shrunkCard.width >= ScrollPreviewPod.minimumCardWidth - 0.01
                && shrunkCard.height
                    >= ScrollPreviewPod.chromeHeight + ScrollPreviewPod.minimumWellHeight - 0.01,
            "card=\(format(shrunkCard))"
        )
        check(
            "scroll: the well keeps showing newer rows than the box's height",
            growthPod.contentHeight > frozenContent + 1 && shrunkContent > 0,
            "content=\(growthPod.contentHeight) was=\(frozenContent)"
        )
        let bandBottom = growthPod.preview.flatMap {
            pixel($0.image, x: $0.image.width / 2, y: $0.image.height - 1)
        }
        let sourceBottom = pixel(
            nineScreens,
            x: nineScreens.width / 2,
            y: nineScreens.height - 1
        )
        check(
            "scroll: the well still shows the newest rows at the bottom",
            bandBottom != nil && sourceBottom != nil
                && abs(bandBottom!.r - sourceBottom!.r) <= 6
                && abs(bandBottom!.g - sourceBottom!.g) <= 6
                && abs(bandBottom!.b - sourceBottom!.b) <= 6,
            "band=\(String(describing: bandBottom)) source=\(String(describing: sourceBottom))"
        )
        feed(nineScreens, into: growthPod)
        growthPod.update(
            preview: previewFrame(nineScreens, for: growthPod),
            phase: .capturing,
            autoScrolling: true
        )
        check(
            "scroll: the footer offers Auto Scroll / Stop while capturing",
            growthPod.visibleButtonTitlesForTesting == ["停止滚动", "停止"],
            "titles=\(growthPod.visibleButtonTitlesForTesting)"
        )
        growthPod.update(preview: nil, phase: .finished, autoScrolling: false)
        check(
            "scroll: a finished session offers one 完成 button",
            growthPod.visibleButtonTitlesForTesting == ["完成"],
            "titles=\(growthPod.visibleButtonTitlesForTesting)"
        )
        // The "I stopped, there was more below" case is the one that used to be
        // a dead end: the card froze and the wheel went nowhere. A finished
        // session the controller can pick up again offers 继续 next to 完成.
        growthPod.isResumable = true
        check(
            "scroll: a resumable session offers 继续 next to 完成",
            growthPod.visibleButtonTitlesForTesting == ["继续", "完成"],
            "titles=\(growthPod.visibleButtonTitlesForTesting)"
        )
        growthPod.isResumable = false
        check(
            "scroll: dropping resumability leaves only 完成",
            growthPod.visibleButtonTitlesForTesting == ["完成"],
            "titles=\(growthPod.visibleButtonTitlesForTesting)"
        )
        growthPod.reset()
        check(
            "scroll: the empty viewfinder shrinks back and offers Auto Scroll / Stop",
            growthPod.visibleCardHeight < growthPod.cardSize.height - 1
                && growthPod.visibleButtonTitlesForTesting == ["自动滚动", "停止"],
            "visible=\(growthPod.visibleCardHeight) "
                + "titles=\(growthPod.visibleButtonTitlesForTesting)"
        )

        // The page is scrolled by a wheel event posted to the application that
        // owns the window under the region. The overlay is a normal layer-0
        // window of our own process, so the first own-PID match must be skipped
        // and the layered menu bar must never be a target.
        let own: pid_t = 900_001
        let windowInfo: [[String: Any]] = [
            [
                kCGWindowLayer as String: 0,
                kCGWindowOwnerPID as String: own,
                kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": 1728, "Height": 1117]
            ],
            [
                kCGWindowLayer as String: 0,
                kCGWindowOwnerPID as String: 4242,
                kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": 1728, "Height": 1117]
            ],
            [
                kCGWindowLayer as String: 0,
                kCGWindowOwnerPID as String: 777,
                kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": 1728, "Height": 1117]
            ]
        ]
        check(
            "scroll: the wheel target skips our overlay and picks the page owner",
            ScrollCaptureController.targetPID(
                in: windowInfo,
                point: CGPoint(x: 500, y: 300),
                ownPID: own
            ) == 4242,
            "pid=\(String(describing: ScrollCaptureController.targetPID(in: windowInfo, point: CGPoint(x: 500, y: 300), ownPID: own)))"
        )
        check(
            "scroll: a point outside the window stack has no target",
            ScrollCaptureController.targetPID(
                in: windowInfo,
                point: CGPoint(x: 5000, y: 5000),
                ownPID: own
            ) == nil
        )

        // iShot's wheel recipe for the opt-in auto scroll: pixel units,
        // negative delta, posted at the region centre rather than at the panel.
        check(
            "scroll: the synthetic wheel is sized from the region",
            ScrollCaptureController.autoScrollStep(forRegionHeight: 700) == 112
                && ScrollCaptureController.autoScrollStep(forRegionHeight: 10) == 60
                && ScrollCaptureController.autoScrollStep(forRegionHeight: 5000) == 180,
            "steps=\(ScrollCaptureController.autoScrollStep(forRegionHeight: 700))/"
                + "\(ScrollCaptureController.autoScrollStep(forRegionHeight: 10))/"
                + "\(ScrollCaptureController.autoScrollStep(forRegionHeight: 5000))"
        )
        let pointer = ScrollCaptureController.pointerPoint(
            region: CGRect(x: 200, y: 217, width: 680, height: 700),
            primaryScreenMaxY: 1117
        )
        check(
            "scroll: the wheel targets the region centre in Quartz coordinates",
            pointer == CGPoint(x: 540, y: 550),
            "point=\(pointer)"
        )
        let wheel = ScrollCaptureController.wheelEvent(step: 112, at: pointer)
        check(
            "scroll: the wheel event carries a negative pixel delta at that point",
            wheel != nil
                && wheel?.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -112
                && wheel?.location == pointer,
            "delta=\(wheel?.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) ?? 0) "
                + "location=\(String(describing: wheel?.location))"
        )

        // The HUD placement helper keeps the progress panel out of the region.
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let region = CGRect(x: 100, y: 100, width: 600, height: 300)
        let origin = ScrollPanelPlacement.origin(
            panelSize: CGSize(width: 372, height: 88),
            region: region,
            screenFrame: screen
        )
        check(
            "scroll: HUD sits above the captured region",
            origin.y >= region.maxY,
            "origin=\(format(CGRect(origin: origin, size: CGSize(width: 372, height: 88))))"
        )
        check(
            "scroll: HUD stays inside the screen",
            screen.contains(CGRect(origin: origin, size: CGSize(width: 372, height: 88)))
        )

        // Leave the result in the output folder for eyeballing.
        if let data = NSBitmapImageRep(cgImage: stitched).representation(using: .png, properties: [:]) {
            let url = directory.appendingPathComponent("scroll-stitched-400x1300.png")
            try? data.write(to: url)
            print("[scroll] wrote \(url.path) (\(data.count) bytes)")
        }
    }

    // MARK: - Scroll preview UI (fixed viewfinder)

    /// Offscreen renders of the scrolling interface at the four moments that
    /// matter, plus the geometry and pixel assertions that make them meaningful:
    ///
    /// * `24-scroll-ui-initial.png` — selection + full region toolbar + the
    ///   empty viewfinder (frame at its final height, card at its smallest);
    /// * `40-scroll-grow-initial.png` — the first screen: a short, sharp card
    ///   showing the selected region, far below the selection's height;
    /// * `41-scroll-grow-mid.png` — three screens: taller, still below;
    /// * `42-scroll-grow-full.png` — just reached the selection's height;
    /// * `43-scroll-grow-frozen.png` — more frames later: identical geometry;
    /// * `27-scroll-ui-finished.png` — stopped, footer offers 完成.
    private static func runScrollPreviewTests(into directory: URL) {
        print("[scroll-ui] --- growing viewfinder + full region UI ---")
        let bounds = CGRect(origin: .zero, size: canvasSize)
        let selection = CGRect(x: 300, y: 260, width: 760, height: 420)
        let box = ScrollPreviewPlacement.make(region: selection, screen: bounds).cardSize
        // The page height whose content lands exactly on the box's well: that is
        // the instant the card freezes at the selection's height.
        let freezePixels = Int(
            ((box.height - ScrollPreviewPod.chromeHeight)
                * 1520 / (box.width - ScrollPreviewPod.padding * 2)).rounded()
        )

        guard
            let firstScreen = makeDocumentImage(width: 1520, height: 840),
            let threeScreens = makeDocumentImage(width: 1520, height: 2520),
            let atFullHeight = makeDocumentImage(width: 1520, height: freezePixels),
            let longPage = makeDocumentImage(width: 1520, height: Int(Double(freezePixels) * 2.6)),
            let finishedImage = makeScrollStitchImage(
                width: 1520,
                segmentHeight: 840,
                segments: 8
            )
        else {
            check("scroll-ui: build images", false)
            return
        }

        let canvas = TestCanvasView(frame: bounds)
        let overlay = CaptureOverlayView(
            frame: bounds,
            mode: .region,
            prefilledSelection: nil,
            showCrosshair: false,
            rendersOffscreen: true,
            scrollMode: true,
            scrollPreviewEnabled: true
        )
        canvas.addSubview(overlay)
        overlay.applySelectionForTesting(selection)
        overlay.revealToolbarForTesting()
        overlay.beginScrollSessionForTesting()
        overlay.layoutSubtreeIfNeeded()

        // 1. Everything a region capture offers is still here, and the box is
        //    exactly where the user drew it.
        check(
            "scroll-ui: entering the mode keeps the selection exactly as drawn",
            overlay.selectionRectForTesting == selection,
            "selection=\(format(overlay.selectionRectForTesting))"
        )
        check(
            "scroll-ui: the full capture toolbar is visible immediately",
            overlay.isToolbarVisibleForTesting && overlay.isAuxRowVisibleForTesting,
            "toolbar=\(format(overlay.toolbarFrameForTesting)) "
                + "aux=\(overlay.isAuxRowVisibleForTesting)"
        )
        check(
            "scroll-ui: all twelve annotation tools remain on the bar",
            overlay.toolbarToolFramesForTesting().count == AnnotationToolbarLayout.visibleTools.count,
            "tools=\(overlay.toolbarToolFramesForTesting().count)"
        )
        check(
            "scroll-ui: every capture action remains on the bar",
            overlay.toolbarButtonFramesForTesting().count
                == CaptureToolbarAction.stripActions.count
                    + CaptureToolbarAction.tailActions.count,
            "actions=\(overlay.toolbarButtonFramesForTesting().map(\.action.rawValue))"
        )
        check(
            "scroll-ui: the size chip and eight handles remain",
            overlay.isIndicatorVisibleForTesting
                && overlay.selectionHandleCentresForTesting.count == 8,
            "chip=\(overlay.indicatorFrameForTesting) "
                + "handles=\(overlay.selectionHandleCentresForTesting.count)"
        )
        check(
            "scroll-ui: the viewfinder starts empty, visible and short",
            overlay.scrollPreviewVisibleForTesting
                && overlay.scrollPhaseForTesting == .empty
                && overlay.scrollPodForTesting.preview == nil
                && overlay.scrollPodForTesting.isFrozen == false,
            "phase=\(overlay.scrollPhaseForTesting) "
                + "visible=\(overlay.scrollPodForTesting.visibleCardHeight)"
        )
        let emptyFrame = overlay.scrollPodFrameForTesting
        let emptyCard = CGRect(
            origin: emptyFrame.origin,
            size: overlay.scrollPodForTesting.cardRect.size
        )
        check(
            "scroll-ui: the viewfinder's frame sits outside the selection",
            !emptyFrame.intersects(selection)
                && bounds.contains(emptyFrame)
                && abs(emptyFrame.minY - selection.minY) < 0.01,
            "pod=\(format(emptyFrame)) selection=\(format(selection))"
        )
        check(
            "scroll-ui: the frame is as tall as the selection, the card starts short",
            abs(emptyFrame.height - selection.height) < 0.01
                && overlay.scrollPodForTesting.cardRect.height < selection.height - 1,
            "frame=\(format(emptyFrame)) card=\(format(emptyCard))"
        )
        check(
            "scroll-ui: the toolbar does not cover the viewfinder",
            !overlay.toolbarFrameForTesting.intersects(emptyFrame),
            "toolbar=\(format(overlay.toolbarFrameForTesting)) pod=\(format(emptyFrame))"
        )
        renderScrollUI(name: "24-scroll-ui-initial", canvas: canvas, into: directory)

        // 2. Annotation tools stay usable while the session is live.
        overlay.selectToolForTesting(.rectangle)
        stroke(overlay, points: [
            CGPoint(x: selection.minX + 80, y: selection.minY + 90),
            CGPoint(x: selection.minX + 260, y: selection.minY + 210)
        ])
        check(
            "scroll-ui: a drawing tool paints inside the live selection",
            overlay.annotationCountForTesting == 1
                && overlay.annotationsForTesting.first?.tool == .rectangle,
            "annotations=\(overlay.annotationCountForTesting)"
        )

        // 3. The first screen: a small card showing the region itself.
        overlay.updateScrollPreview(
            preview: previewFrame(firstScreen, for: overlay.scrollPodForTesting),
            phase: .capturing,
            autoScrolling: false
        )
        overlay.layoutSubtreeIfNeeded()
        let pod = overlay.scrollPodForTesting
        let firstCard = pod.cardRect
        check(
            "scroll-ui: the first screen grows the card, still below the selection",
            firstCard.height > ScrollPreviewPod.minimumCardHeight - 0.01
                && firstCard.height < selection.height - 1
                && overlay.scrollPodFrameForTesting == emptyFrame,
            "card=\(format(firstCard)) frame=\(format(overlay.scrollPodFrameForTesting))"
        )
        check(
            "scroll-ui: the card's well is exactly the first screen — no empty space",
            abs(pod.wellRect.height - pod.contentHeight) < 1.5
                && abs(firstCard.minY) < 0.01
                && abs(firstCard.maxY - firstCard.height) < 0.01,
            "well=\(pod.wellRect.height) content=\(pod.contentHeight)"
        )
        check(
            "scroll-ui: the selection chrome survives the first stitched frame",
            overlay.isToolbarVisibleForTesting
                && overlay.isIndicatorVisibleForTesting
                && overlay.selectionRectForTesting == selection,
            "selection=\(format(overlay.selectionRectForTesting))"
        )
        renderScrollUI(name: "40-scroll-grow-initial", canvas: canvas, into: directory)

        // 4. Three screens: the card is visibly taller, still under the box.
        overlay.updateScrollPreview(
            preview: previewFrame(threeScreens, for: overlay.scrollPodForTesting),
            phase: .capturing,
            autoScrolling: true
        )
        overlay.layoutSubtreeIfNeeded()
        let midCard = pod.cardRect
        check(
            "scroll-ui: the third screen makes the card taller but not full",
            midCard.height > firstCard.height + 1
                && midCard.height < selection.height - 1
                && overlay.scrollPodFrameForTesting == emptyFrame,
            "first=\(firstCard.height) mid=\(midCard.height) selection=\(selection.height)"
        )
        check(
            "scroll-ui: the mid card still shows only its own content",
            abs(pod.wellRect.height - pod.contentHeight) < 1.5,
            "well=\(pod.wellRect.height) content=\(pod.contentHeight)"
        )
        check(
            "scroll-ui: Auto Scroll is reflected in the footer",
            pod.visibleButtonTitlesForTesting == ["停止滚动", "停止"],
            "titles=\(pod.visibleButtonTitlesForTesting)"
        )
        renderScrollUI(name: "41-scroll-grow-mid", canvas: canvas, into: directory)

        // 5. One box of content: exactly the selection's height, and it freezes.
        overlay.updateScrollPreview(
            preview: previewFrame(atFullHeight, for: overlay.scrollPodForTesting),
            phase: .capturing,
            autoScrolling: true
        )
        overlay.layoutSubtreeIfNeeded()
        let fullCard = pod.cardRect
        let fullContent = pod.contentHeight
        check(
            "scroll-ui: the card reaches exactly the selection's height",
            abs(fullCard.height - selection.height) < 1
                && pod.isFrozen
                && pod.scale == 1
                && overlay.scrollPodFrameForTesting == emptyFrame,
            "card=\(format(fullCard)) scale=\(pod.scale) selection=\(format(selection))"
        )
        check(
            "scroll-ui: the frozen well is the box's well",
            abs(pod.wellRect.height - pod.fullWellRect.height) < 1.5
                && fullContent > pod.wellRect.height,
            "well=\(pod.wellRect.height) full=\(pod.fullWellRect.height) "
                + "content=\(fullContent)"
        )
        renderScrollUI(name: "42-scroll-grow-full", canvas: canvas, into: directory)

        // 6. P1 supplement: past the selection's height the *whole card* scales
        //    down, anchored on the corner nearest the selection, so the window
        //    never grows again and the gap is untouched.
        overlay.updateScrollPreview(
            preview: previewFrame(longPage, for: overlay.scrollPodForTesting),
            phase: .capturing,
            autoScrolling: true
        )
        overlay.layoutSubtreeIfNeeded()
        let shrunkCard = pod.cardRect
        check(
            "scroll-ui: a longer page shrinks the card instead of growing it",
            pod.scale < 1
                && shrunkCard.height < fullCard.height - 1
                && shrunkCard.width < fullCard.width - 1
                && pod.isFrozen
                && overlay.scrollPodFrameForTesting == emptyFrame,
            "card=\(format(shrunkCard)) full=\(format(fullCard)) scale=\(pod.scale)"
        )
        let anchoredEdgeOK = pod.innerEdgeOnRight
            ? abs(shrunkCard.maxX - emptyFrame.width) < 0.01
            : abs(shrunkCard.minX) < 0.01
        check(
            "scroll-ui: the shrink is anchored on the selection-side bottom corner",
            abs(shrunkCard.minY) < 0.01 && anchoredEdgeOK,
            "card=\(format(shrunkCard)) podWidth=\(emptyFrame.width) "
                + "innerRight=\(pod.innerEdgeOnRight)"
        )
        check(
            "scroll-ui: the shrink keeps the card above its legible floor",
            shrunkCard.width >= ScrollPreviewPod.minimumCardWidth - 0.01
                && pod.contentHeight > fullContent + 1,
            "width=\(shrunkCard.width) content=\(pod.contentHeight) was=\(fullContent)"
        )
        renderScrollUI(name: "43-scroll-grow-frozen", canvas: canvas, into: directory)

        // 7. Stopped: one 完成 button, geometry unchanged.
        overlay.updateScrollPreview(
            preview: previewFrame(longPage, for: overlay.scrollPodForTesting),
            phase: .finished,
            autoScrolling: false
        )
        overlay.layoutSubtreeIfNeeded()
        check(
            "scroll-ui: stopping changes the footer, never the geometry",
            overlay.scrollPodFrameForTesting == emptyFrame
                && pod.cardRect == shrunkCard
                && pod.visibleButtonTitlesForTesting == ["完成"],
            "frame=\(format(overlay.scrollPodFrameForTesting)) "
                + "titles=\(pod.visibleButtonTitlesForTesting)"
        )
        // The finished card is not a dead end: a session that stopped on 停止 or
        // on the bottom detector can be resumed, so 继续 sits next to 完成. The
        // geometry must not move for it — the button lives in the footer row
        // that is already there.
        pod.isResumable = true
        check(
            "scroll-ui: a resumable result offers 继续 next to 完成",
            pod.visibleButtonTitlesForTesting == ["继续", "完成"]
                && pod.cardRect == shrunkCard
                && overlay.scrollPodFrameForTesting == emptyFrame,
            "titles=\(pod.visibleButtonTitlesForTesting) card=\(format(pod.cardRect))"
        )
        // The other half of "不要让它静默不动": a wheel that arrives while the
        // card is finished used to be swallowed by an interactive overlay. It
        // now asks for a resume, which is the only thing the user can mean.
        var resumeRequests = 0
        overlay.onScrollResume = { resumeRequests += 1 }
        overlay.scrollWheel(with: scrollEvent(deltaY: -40))
        check(
            "scroll-ui: a wheel on the finished card asks to resume",
            resumeRequests == 1 && overlay.scrollPhaseForTesting == .finished,
            "resumeRequests=\(resumeRequests) phase=\(overlay.scrollPhaseForTesting)"
        )
        let notResumableRequests = resumeRequests
        pod.isResumable = false
        overlay.scrollWheel(with: scrollEvent(deltaY: -40))
        check(
            "scroll-ui: a terminal result does not promise a resume it cannot keep",
            resumeRequests == notResumableRequests,
            "resumeRequests=\(resumeRequests)"
        )
        pod.isResumable = true
        _ = finishedImage
        renderScrollUI(name: "27-scroll-ui-finished", canvas: canvas, into: directory)
    }

    // MARK: - Scroll Esc

    /// Esc in **every** phase of a scrolling capture.
    ///
    /// While a session samples, the overlay is click-through and the page owns
    /// the keyboard, so Esc can never arrive through `keyDown`. The controller
    /// therefore owns a bare-Esc Carbon hot key for exactly that window and
    /// funnels it into `handleScrollEscape()` — the same decision `keyDown`
    /// uses. These checks cover the decision table, the Return branch that
    /// shares the method, the registration lifetime, and the controller-level
    /// exit through the ordinary cancel path.
    private static func runScrollEscapeTests() async {
        print("[scroll-esc] --- Esc in every scrolling phase ---")
        let bounds = CGRect(origin: .zero, size: canvasSize)
        let selection = CGRect(x: 220, y: 160, width: 720, height: 520)

        func makeScrollOverlay() -> CaptureOverlayView {
            let overlay = CaptureOverlayView(
                frame: bounds,
                mode: .region,
                prefilledSelection: nil,
                showCrosshair: false,
                rendersOffscreen: true,
                scrollMode: true,
                scrollPreviewEnabled: true
            )
            overlay.applySelectionForTesting(selection)
            overlay.revealToolbarForTesting()
            overlay.beginScrollSessionForTesting()
            return overlay
        }

        // 1. Sampling (and the .empty phase before the first frame) cancels.
        let running = makeScrollOverlay()
        var runningCancels = 0
        var runningCloses = 0
        running.onCancel = { runningCancels += 1 }
        running.onScrollClose = { runningCloses += 1 }
        running.handleScrollEscape()
        check(
            "scroll-esc: Esc while sampling cancels the session",
            runningCancels == 1 && runningCloses == 0,
            "cancels=\(runningCancels) closes=\(runningCloses) phase=\(running.scrollPhaseForTesting)"
        )

        // 2. `keyDown`'s scroll branch is the same method, so a real key event
        //    in the phases where the overlay is key behaves identically.
        let keyed = makeScrollOverlay()
        var keyedCancels = 0
        keyed.onCancel = { keyedCancels += 1 }
        let handledEscape = keyed.handleScrollKey(53)
        check(
            "scroll-esc: keyDown's Esc branch routes into the same cancel",
            handledEscape && keyedCancels == 1,
            "handled=\(handledEscape) cancels=\(keyedCancels)"
        )

        // 3. Return keeps its meaning: stop while sampling, confirm when the
        //    long image waits for a decision. The Escape work must not swallow
        //    or re-route it.
        let returner = makeScrollOverlay()
        var stops = 0
        var confirms = 0
        returner.onScrollStop = { stops += 1 }
        returner.onScrollConfirm = { confirms += 1 }
        let handledReturn = returner.handleScrollKey(36)
        returner.updateScrollPreview(preview: nil, phase: .finished, autoScrolling: false)
        let handledFinishedReturn = returner.handleScrollKey(76)
        check(
            "scroll-esc: Return still stops, then confirms",
            handledReturn && stops == 1 && handledFinishedReturn && confirms == 1,
            "stops=\(stops) confirms=\(confirms)"
        )

        // 4. Awaiting confirmation: Esc throws the pending long image away
        //    through the same `onScrollClose` a region shot uses to discard.
        let finished = makeScrollOverlay()
        var finishedCancels = 0
        var finishedCloses = 0
        finished.onCancel = { finishedCancels += 1 }
        finished.onScrollClose = { finishedCloses += 1 }
        finished.updateScrollPreview(preview: nil, phase: .finished, autoScrolling: false)
        finished.handleScrollEscape()
        check(
            "scroll-esc: Esc on the awaiting-confirmation result discards it",
            finishedCloses == 1 && finishedCancels == 0,
            "cancels=\(finishedCancels) closes=\(finishedCloses) phase=\(finished.scrollPhaseForTesting)"
        )

        // 5. A region overlay that is not scrolling must not claim Esc: the
        //    helper reports false so `keyDown` reaches its ordinary branch.
        let plain = CaptureOverlayView(
            frame: bounds,
            mode: .region,
            prefilledSelection: nil,
            showCrosshair: false,
            rendersOffscreen: true,
            scrollMode: false,
            scrollPreviewEnabled: false
        )
        plain.applySelectionForTesting(selection)
        var plainCancels = 0
        plain.onCancel = { plainCancels += 1 }
        check(
            "scroll-esc: an inactive scroll session leaves Esc to the normal path",
            !plain.handleScrollKey(53) && plainCancels == 0,
            "cancels=\(plainCancels)"
        )

        // 6. Controller lifetime: Esc is ours only while the page owns the
        //    keyboard. It is idempotent while click-through, released the
        //    moment the overlay is interactive again, and the hotkey handler
        //    cancels through the ordinary controller path.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            check("scroll-esc: a screen exists for the controller", false)
            return
        }
        func makeController() -> CaptureOverlayController {
            let controller = CaptureOverlayController(
                mode: .region,
                prefilledSelection: selection,
                showCrosshair: false,
                autoConfirmAsScroll: true,
                windowPickEnabled: false
            )
            controller.presentPanelsForTesting(on: screen)
            controller.overlayViewsForTesting.first?.beginScrollSessionForTesting()
            return controller
        }

        let controller = makeController()
        // Deterministic pointer: the click-through policy is applied per pointer
        // position, so park it on the page (not on the toolbar) or the verdict
        // would depend on where the user's mouse happens to be during the run.
        controller.scrollPointerLocationOverride = CGPoint(
            x: selection.midX,
            y: selection.midY
        )
        controller.setScrollPassthrough(true)
        let installedFirst = controller.isScrollEscapeHotKeyInstalledForTesting
        let passthroughWhileScrolling = controller.panelPassthroughForTesting
        controller.setScrollPassthrough(true)
        let installedSecond = controller.isScrollEscapeHotKeyInstalledForTesting
        controller.setScrollPassthrough(false)
        let installedAfterInteractive = controller.isScrollEscapeHotKeyInstalledForTesting
        let passthroughAfterInteractive = controller.panelPassthroughForTesting
        check(
            "scroll-esc: the Esc hotkey lives exactly while click-through is on",
            installedFirst && installedSecond && !installedAfterInteractive
                && controller.hasPanelsForTesting,
            "first=\(installedFirst) second=\(installedSecond) "
                + "afterInteractive=\(installedAfterInteractive)"
        )
        check(
            "scroll-esc: mouse transparency is restored when the session ends",
            passthroughWhileScrolling == [true] && passthroughAfterInteractive == [false],
            "during=\(passthroughWhileScrolling) after=\(passthroughAfterInteractive)"
        )

        // 7. A confirmation that arrives while the stopped session is still
        //    composing its image must not look like "there is nothing to
        //    deliver". The controller reports that window so the coordinator
        //    can queue the Return / 完成 instead of closing the overlay and
        //    throwing the picture away.
        let composing = ScrollCaptureController(
            region: CGRect(x: 0, y: 0, width: 320, height: 240),
            screen: screen,
            interval: 0.35,
            includeCursor: false,
            maxFrames: 20,
            canAutoScroll: false
        )
        composing.start()
        composing.record(ScrollStitchWorker.Step(
            outcome: .appended(rows: 60),
            frame: nil,
            height: 1200,
            grew: true,
            frameCount: 2,
            lastOverlap: 1200,
            stitchMilliseconds: 0,
            bandMilliseconds: 0
        ))
        composing.finish()
        let composingImmediately = composing.isComposing
        try? await Task.sleep(nanoseconds: 400_000_000)
        check(
            "scroll: a stopped session reports the window where its image is still composing",
            composingImmediately && !composing.isComposing && !composing.isRunning,
            "during=\(composingImmediately) after=\(composing.isComposing) "
                + "running=\(composing.isRunning)"
        )
        composing.abandon()

        var controllerCancels = 0
        controller.onCancelled = { controllerCancels += 1 }
        controller.setScrollPassthrough(true)
        // Same Carbon event the window server posts for a real hot key.
        GlobalHotKeyCenter.postSyntheticHotKeyForDebugging(.scrollEscape)
        try? await Task.sleep(nanoseconds: 150_000_000)
        check(
            "scroll-esc: the click-through Esc cancels and closes every window",
            controllerCancels == 1
                && !controller.hasPanelsForTesting
                && !controller.isScrollEscapeHotKeyInstalledForTesting,
            "cancels=\(controllerCancels) panels=\(controller.hasPanelsForTesting) "
                + "hotkey=\(controller.isScrollEscapeHotKeyInstalledForTesting)"
        )
    }

    // MARK: - Scroll toolbar clickability

    /// The scrolling session runs click-through so the page keeps the wheel, and
    /// the capture toolbar lives in that same panel. The panel therefore has to
    /// become an interactive window exactly while the pointer is on the plate —
    /// otherwise ✕ is drawn but never receives the click (the reported bug).
    ///
    /// These checks drive the real controller and panels: the click-through
    /// verdict as the pointer moves, the wheel that lands on the chrome, and a
    /// real mouse event dispatched through the panel onto the ✕, which must end
    /// the session through the ordinary cancel path.
    private static func runScrollToolbarClickTests() {
        print("[scroll-toolbar] --- the toolbar stays clickable while the page scrolls ---")
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            check("scroll-toolbar: a screen exists for the controller", false)
            return
        }
        let selection = CGRect(x: 260, y: 220, width: 700, height: 480)
        let controller = CaptureOverlayController(
            mode: .region,
            prefilledSelection: selection,
            showCrosshair: false,
            preferredScreen: screen,
            autoConfirmAsScroll: true,
            windowPickEnabled: false
        )
        controller.presentPanelsForTesting(on: screen)
        guard let view = controller.overlayViewsForTesting.first else {
            check("scroll-toolbar: the scrolling toolbar and its ✕ are on screen", false)
            return
        }
        view.beginScrollSessionForTesting()
        guard let panel = controller.panelsForTesting.first,
              let toolbarFrame = view.scrollToolbarScreenFrameForTesting,
              let cancelFrame = view.scrollCancelButtonScreenFrameForTesting else {
            check(
                "scroll-toolbar: the scrolling toolbar and its ✕ are on screen",
                false,
                "panels=\(controller.panelsForTesting.count) "
                    + "hotZone=\(String(describing: controller.overlayViewsForTesting.first?.scrollToolbarScreenFrameForTesting))"
            )
            controller.close()
            return
        }
        check(
            "scroll-toolbar: the scrolling toolbar and its ✕ are on screen",
            toolbarFrame.width > 0 && toolbarFrame.height > 0
                && cancelFrame.width > 0 && cancelFrame.height > 0
                && toolbarFrame.contains(CGPoint(x: cancelFrame.midX, y: cancelFrame.midY)),
            "toolbar=\(NSStringFromRect(toolbarFrame)) cancel=\(NSStringFromRect(cancelFrame))"
        )

        // 1. Pointer over the page: the panel is click-through, so the wheel
        //    reaches the page natively. This is the state that made ✕ dead.
        controller.scrollPointerLocationOverride = CGPoint(
            x: selection.midX,
            y: selection.midY
        )
        controller.setScrollPassthrough(true)
        let pagePassthrough = controller.panelPassthroughForTesting
        let pageHot = view.scrollPointerIsOverToolbarForTesting
        check(
            "scroll-toolbar: away from the toolbar the panel is click-through",
            pagePassthrough == [true] && !pageHot
                && controller.isScrollPointerTrackingForTesting,
            "passthrough=\(pagePassthrough) hot=\(pageHot) "
                + "tracking=\(controller.isScrollPointerTrackingForTesting)"
        )

        // 2. Pointer on the ✕: the panel is a real window again, so the click has
        //    somewhere to land.
        controller.scrollPointerLocationOverride = CGPoint(
            x: cancelFrame.midX,
            y: cancelFrame.midY
        )
        controller.applyScrollPassthroughPolicyForTesting()
        let chromePassthrough = controller.panelPassthroughForTesting
        let chromeHot = view.scrollPointerIsOverToolbarForTesting
        check(
            "scroll-toolbar: on the toolbar the panel is interactive",
            chromePassthrough == [false] && chromeHot,
            "passthrough=\(chromePassthrough) hot=\(chromeHot)"
        )

        // 3. A wheel that arrives in that state belongs to the chrome: it must be
        //    consumed, not forwarded (forwarding would also re-assert the
        //    click-through flag from under the pointer and make the plate dead
        //    again — the historical "one scroll becomes endless" family).
        var forwardedWheels = 0
        view.onScrollWheel = { _ in forwardedWheels += 1 }
        view.scrollWheel(with: scrollEvent(deltaY: -40))
        check(
            "scroll-toolbar: a wheel over the toolbar is consumed, not forwarded",
            forwardedWheels == 0,
            "forwarded=\(forwardedWheels)"
        )

        // 4. A real click at the ✕'s own point, dispatched through the panel like
        //    the window server does, ends the session through the ordinary
        //    cancel path — and leaves no panel, Esc hot key or pointer poller
        //    behind.
        var cancels = 0
        controller.onCancelled = { cancels += 1 }
        let windowPoint = panel.convertPoint(
            fromScreen: CGPoint(x: cancelFrame.midX, y: cancelFrame.midY)
        )
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: windowPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ) else { continue }
            panel.sendEvent(event)
        }
        check(
            "scroll-toolbar: a click on the ✕ cancels the session",
            cancels == 1
                && !controller.hasPanelsForTesting
                && !controller.isScrollEscapeHotKeyInstalledForTesting
                && !controller.isScrollPointerTrackingForTesting,
            "cancels=\(cancels) panels=\(controller.hasPanelsForTesting) "
                + "hotkey=\(controller.isScrollEscapeHotKeyInstalledForTesting) "
                + "tracking=\(controller.isScrollPointerTrackingForTesting)"
        )
    }

    // MARK: - Polish: rectangle glass card, captured boundary, frozen crosshair,
    //          flat veil, window corner in the delivered pixels.

    /// P2/P3/P4/P5/P6 in one place, because they are one picture: the user sees
    /// the viewfinder, the boundary and the crosshair over the *same* veiled
    /// desktop, and the corner they see is the corner the file gets.
    private static func runPolishTests(into directory: URL) {
        print("[polish] --- rectangle glass card / boundary / frozen cross / flat veil ---")
        let bounds = CGRect(origin: .zero, size: canvasSize)

        // MARK: P2 — the card is a rectangle, its inside is glass, the rest is empty
        check(
            "polish: the viewfinder card is a rectangle",
            ScrollPreviewPod.cardCornerRadius == 0
                && ScrollPreviewPod.wellCornerRadius == 0,
            "card=\(ScrollPreviewPod.cardCornerRadius) well=\(ScrollPreviewPod.wellCornerRadius)"
        )
        check(
            "polish: the card is glass, from the one plate recipe the toolbar uses",
            GlassSurfaceFactory.liquidGlassTint().alphaComponent > 0.1
                && GlassSurfaceFactory.liquidGlassTint().alphaComponent < 0.5,
            "tintAlpha=\(GlassSurfaceFactory.liquidGlassTint().alphaComponent)"
        )

        guard let shortPage = makeDocumentImage(width: 1520, height: 190) else {
            check("polish: build the short page", false)
            return
        }

        /// One pod on a flat ground, at the geometry the placement gives it.
        /// `preview` is deliberately shorter than the well so the un-captured
        /// part is visible: that is the state the user asked to leave empty.
        func makePodView(ground: NSColor) -> (container: NSView, pod: ScrollPreviewPod) {
            let container = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 520))
            container.wantsLayer = true
            let flat = FlatGroundView(frame: container.bounds)
            flat.color = ground
            container.addSubview(flat)
            let pod = ScrollPreviewPod()
            pod.isHidden = false
            pod.configure(cardSize: CGSize(width: 220, height: 460), innerEdgeOnRight: false)
            pod.frame = CGRect(x: 40, y: 30, width: 220, height: 460)
            container.addSubview(pod)
            pod.update(
                preview: ScrollPreviewFrame.make(
                    from: shortPage,
                    size: ScrollPreviewPod.bandSize(forCardSize: pod.drawnCardSize)
                ),
                phase: .finished,
                autoScrolling: false
            )
            container.layoutSubtreeIfNeeded()
            return (container, pod)
        }

        let onWhite = makePodView(ground: .white)
        let onNavy = makePodView(ground: NSColor(srgbRed: 0.06, green: 0.09, blue: 0.18, alpha: 1))
        guard let whiteImage = renderImage(of: onWhite.container),
              let navyImage = renderImage(of: onNavy.container) else {
            check("polish: render the pod over both grounds", false)
            return
        }
        let pod = onWhite.pod
        let card = pod.cardRect.offsetBy(dx: pod.frame.minX, dy: pod.frame.minY)
        let well = pod.wellRect.offsetBy(dx: pod.frame.minX, dy: pod.frame.minY)
        // Two probes in the well: one in the empty top, one on the picture.
        let emptyY = well.maxY - 6
        let pictureY = well.minY + 4
        let probeScale = CGFloat(whiteImage.width) / onWhite.container.bounds.width
        let probeX = Int((card.midX * probeScale).rounded())
        func probe(_ image: CGImage, _ view: NSView, _ y: CGFloat) -> (r: Int, g: Int, b: Int, a: Int)? {
            pixel(
                image,
                x: probeX,
                y: Int(((view.bounds.height - y) * probeScale).rounded())
            )
        }
        let emptyOnWhite = probe(whiteImage, onWhite.container, emptyY)
        let emptyOnNavy = probe(navyImage, onNavy.container, emptyY)
        let pictureOnWhite = probe(whiteImage, onWhite.container, pictureY)
        let pictureOnNavy = probe(navyImage, onNavy.container, pictureY)
        check(
            "polish: the un-captured part of the well is glass, not a fill",
            emptyOnWhite != nil && emptyOnNavy != nil
                && abs(emptyOnWhite!.r - emptyOnNavy!.r) >= 10,
            "white=\(String(describing: emptyOnWhite)) navy=\(String(describing: emptyOnNavy))"
        )
        check(
            "polish: the captured part is the page itself, identical over both grounds",
            pictureOnWhite != nil && pictureOnNavy != nil
                && abs(pictureOnWhite!.r - pictureOnNavy!.r) <= 2
                && abs(pictureOnWhite!.g - pictureOnNavy!.g) <= 2
                && abs(pictureOnWhite!.r - (emptyOnWhite?.r ?? -1)) >= 4,
            "white=\(String(describing: pictureOnWhite)) navy=\(String(describing: pictureOnNavy)) "
                + "empty=\(String(describing: emptyOnWhite))"
        )
        // The empty part must be the card's own material: compare it with the
        // padding strip beside the well at the same height. A leftover well fill
        // would separate them.
        let paddingX = Int(((card.minX + 6) * probeScale).rounded())
        let paddingY = Int(((onWhite.container.bounds.height - emptyY) * probeScale).rounded())
        let paddingPixel = pixel(whiteImage, x: paddingX, y: paddingY)
        let emptyPixel = probe(whiteImage, onWhite.container, emptyY)
        check(
            "polish: the empty well and the card's padding are the same material",
            paddingPixel != nil && emptyPixel != nil
                && abs(paddingPixel!.r - emptyPixel!.r) <= 6
                && abs(paddingPixel!.g - emptyPixel!.g) <= 6
                && abs(paddingPixel!.b - emptyPixel!.b) <= 6,
            "padding=\(String(describing: paddingPixel)) empty=\(String(describing: emptyPixel))"
        )
        check(
            "polish: the picture sits on the card's bottom edge, glass above it",
            abs(pod.wellRect.minY - ScrollPreviewPod.chromeHeight) < 0.01
                && pod.wellRect.width == pod.cardRect.width - ScrollPreviewPod.padding * 2
                && pod.contentHeight < pod.wellRect.height - 10,
            "well=\(format(pod.wellRect)) content=\(pod.contentHeight)"
        )
        writePNG(whiteImage, to: directory.appendingPathComponent("50-preview-rect-glass.png"))
        print("[polish] wrote 50-preview-rect-glass.png")

        // MARK: P5 + P6 — the flat curtain, with a rounded hole
        let canvas = TestCanvasView(frame: bounds)
        // What the canvas draws behind the overlay; the veiled render is compared
        // against it pixel for pixel.
        guard let canvasImage = renderImage(of: canvas) else {
            check("polish: render the canvas behind the veil", false)
            return
        }
        let selection = CGRect(x: 420, y: 300, width: 620, height: 380)
        let overlay = CaptureOverlayView(
            frame: bounds,
            mode: .region,
            prefilledSelection: nil,
            showCrosshair: true,
            rendersOffscreen: true,
            scrollMode: true,
            scrollPreviewEnabled: true
        )
        canvas.addSubview(overlay)
        overlay.applySelectionForTesting(selection)
        overlay.revealToolbarForTesting()
        overlay.layoutSubtreeIfNeeded()
        check(
            "polish: the veil is the flat 38 % curtain with a 12 pt hole",
            overlay.dimmingHoleCornerRadiusForTesting == 12
                && abs(overlay.dimmingDimAlphaForTesting - 0.38) < 0.0001,
            "radius=\(overlay.dimmingHoleCornerRadiusForTesting) "
                + "alpha=\(overlay.dimmingDimAlphaForTesting)"
        )
        guard let veiled = renderImage(of: canvas) else {
            check("polish: render the veiled overlay", false)
            return
        }
        /// View point (bottom-left) → top-left pixel of the 2× render.
        func renderPixel(_ image: CGImage, _ point: CGPoint) -> (r: Int, g: Int, b: Int, a: Int)? {
            let scale = CGFloat(image.width) / bounds.width
            return pixel(
                image,
                x: Int((point.x * scale).rounded()),
                y: Int(((bounds.height - point.y) * scale).rounded())
            )
        }
        let holeCentre = CGPoint(x: selection.midX, y: selection.midY)
        let centreVeiled = renderPixel(veiled, holeCentre)
        let centreRaw = renderPixel(canvasImage, holeCentre)
        check(
            "polish: the selection stays completely sharp inside the veil",
            centreVeiled != nil && centreRaw != nil
                && abs(centreVeiled!.r - centreRaw!.r) <= 2
                && abs(centreVeiled!.g - centreRaw!.g) <= 2
                && abs(centreVeiled!.b - centreRaw!.b) <= 2,
            "veiled=\(String(describing: centreVeiled)) raw=\(String(describing: centreRaw))"
        )
        let veilProbe = CGPoint(x: 60, y: 700)
        let veilVeiled = renderPixel(veiled, veilProbe)
        let veilRaw = renderPixel(canvasImage, veilProbe)
        check(
            "polish: the unselected area is a veil, not the raw desktop",
            veilVeiled != nil && veilRaw != nil
                && abs(veilVeiled!.r - veilRaw!.r) >= 5,
            "veiled=\(String(describing: veilVeiled)) raw=\(String(describing: veilRaw))"
        )
        // Behind a fake window panel (x 120…640, y 480…740) vs the empty desktop:
        // a 38 % curtain keeps the contours, it does not fog them out.
        // Same row of the canvas's vertical gradient: one point inside a fake
        // window panel, one on the bare desktop, both outside the selection.
        let onPanel = renderPixel(veiled, CGPoint(x: 200, y: 600))
        let offPanel = renderPixel(veiled, CGPoint(x: 1300, y: 600))
        check(
            "polish: window contours stay visible through the veil",
            onPanel != nil && offPanel != nil
                && abs(onPanel!.r - offPanel!.r) >= 8,
            "panel=\(String(describing: onPanel)) desktop=\(String(describing: offPanel))"
        )
        // Dim proof: outside the selection the pixels are the screen with a fixed
        // black film on top — `raw × (1 − 0.38)`, no material, no sampling.
        let flatProbe = CGPoint(x: 1310, y: 607)
        let flatVeiled = renderPixel(veiled, flatProbe)
        let flatRaw = renderPixel(canvasImage, flatProbe)
        if let flatVeiled, let flatRaw {
            let expectedR = Int((Double(flatRaw.r) * 0.62).rounded())
            let expectedG = Int((Double(flatRaw.g) * 0.62).rounded())
            let expectedB = Int((Double(flatRaw.b) * 0.62).rounded())
            check(
                "polish: outside the selection the pixels are the screen × a fixed dim",
                abs(flatVeiled.r - expectedR) <= 4
                    && abs(flatVeiled.g - expectedG) <= 4
                    && abs(flatVeiled.b - expectedB) <= 4,
                "raw=\(flatRaw) veiled=\(flatVeiled) "
                    + "expected=(\(expectedR),\(expectedG),\(expectedB))"
            )
        } else {
            check("polish: outside the selection the pixels are the screen × a fixed dim", false)
        }
        // Sharpness proof: the canvas's panel edge at x = 120 is 1 px sharp; a
        // flat curtain keeps it sharp across the 8 pt gap, where a blur would
        // spread it into a gradient.
        let edgeOut8 = renderPixel(veiled, CGPoint(x: 112, y: 600))
        let edgeOut16 = renderPixel(veiled, CGPoint(x: 104, y: 600))
        let rawOut8 = renderPixel(canvasImage, CGPoint(x: 112, y: 600))
        let rawOut16 = renderPixel(canvasImage, CGPoint(x: 104, y: 600))
        check(
            "polish: the veil does not blur — the sharp edge stays sharp",
            edgeOut8 != nil && edgeOut16 != nil && rawOut8 != nil && rawOut16 != nil
                && abs(rawOut8!.r - rawOut16!.r) <= 1
                && abs(edgeOut8!.r - edgeOut16!.r) <= 1,
            "raw=\(rawOut8!.r)→\(rawOut16!.r) veiled=\(edgeOut8!.r)→\(edgeOut16!.r)"
        )
        // P6: the four corners are shaded by the same veil; the edges and the
        // middle are not. That is the "rounded window corner" without rounding
        // the border. Geometry is checked exactly (a 12 pt radius leaves a
        // ~3.5 pt sliver at the diagonal) and the *sharpness* of the interior is
        // checked on pixels, away from the handles and the white border.
        let cornerSliver = CGPoint(x: selection.minX + 1.5, y: selection.minY + 1.5)
        let cornerInsideArc = CGPoint(x: selection.minX + 14, y: selection.minY + 14)
        let bottomEdge = CGPoint(x: selection.midX, y: selection.minY + 1)
        check(
            "polish: the selection's corners are shaded by the rounded hole",
            overlay.dimmingCoversForTesting(cornerSliver)
                && !overlay.dimmingCoversForTesting(cornerInsideArc)
                && !overlay.dimmingCoversForTesting(holeCentre)
                && !overlay.dimmingCoversForTesting(bottomEdge),
            "sliver=\(overlay.dimmingCoversForTesting(cornerSliver)) "
                + "insideArc=\(overlay.dimmingCoversForTesting(cornerInsideArc)) "
                + "centre=\(overlay.dimmingCoversForTesting(holeCentre)) "
                + "edge=\(overlay.dimmingCoversForTesting(bottomEdge))"
        )
        // The edge midpoint stays sharp: sample a quarter along the bottom edge,
        // clear of the handles (midX) and of the corner arc.
        let edgePoint = CGPoint(
            x: selection.minX + selection.width * 0.28,
            y: selection.minY + 6
        )
        let edgeVeiled = renderPixel(veiled, edgePoint)
        let edgeRaw = renderPixel(canvasImage, edgePoint)
        check(
            "polish: the selection's edge stays sharp — the border is square",
            edgeVeiled != nil && edgeRaw != nil
                && abs(edgeVeiled!.r - edgeRaw!.r) <= 2
                && abs(edgeVeiled!.g - edgeRaw!.g) <= 2,
            "veiled=\(String(describing: edgeVeiled)) raw=\(String(describing: edgeRaw))"
        )
        check(
            "polish: the delivered corner radius is the veil's radius",
            CaptureCorner.radius == DimmingView.defaultCornerRadius,
            "export=\(CaptureCorner.radius) veil=\(DimmingView.defaultCornerRadius)"
        )
        // The shape on its own: no border, no handles, no toolbar over it, so the
        // four rounded corners of the curtain are visible. 2 pt inside a square
        // corner is the shaded sliver; 14 pt in is the clear hole.
        let cornerCanvas = TestCanvasView(frame: bounds)
        let bareVeil = DimmingView(frame: bounds)
        bareVeil.selectionRect = selection
        cornerCanvas.addSubview(bareVeil)
        guard let cornerImage = renderImage(of: cornerCanvas) else {
            check("polish: render the bare veil", false)
            return
        }
        let cornerSlivers = [
            CGPoint(x: selection.minX + 2, y: selection.minY + 2),
            CGPoint(x: selection.maxX - 2, y: selection.minY + 2),
            CGPoint(x: selection.minX + 2, y: selection.maxY - 2),
            CGPoint(x: selection.maxX - 2, y: selection.maxY - 2)
        ]
        let cornerClear = CGPoint(x: selection.minX + 14, y: selection.minY + 14)
        let clearBare = renderPixel(cornerImage, cornerClear)
        let clearRaw = renderPixel(canvasImage, cornerClear)
        let sliversShaded = cornerSlivers.allSatisfy { point in
            guard let veiled = renderPixel(cornerImage, point),
                  let raw = renderPixel(canvasImage, point),
                  let clearBare, let clearRaw else { return false }
            return veiled.r <= raw.r - 6
                && veiled.r <= clearBare.r - 6
                && abs(clearBare.r - clearRaw.r) <= 2
        }
        check(
            "polish: all four corners are shaded by the rounded hole",
            sliversShaded
                && cornerSlivers.allSatisfy { overlay.dimmingCoversForTesting($0) }
                && !overlay.dimmingCoversForTesting(cornerClear),
            "slivers=\(cornerSlivers.map { renderPixel(cornerImage, $0)?.r ?? -1 }) "
                + "clear=\(String(describing: clearBare)) "
                + "covered=\(cornerSlivers.map { overlay.dimmingCoversForTesting($0) })"
        )
        writePNG(cornerImage, to: directory.appendingPathComponent("55-veil-flat-corners.png"))
        print("[polish] wrote 55-veil-flat-corners.png")

        // MARK: P4 — the crosshair freezes on release
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )!
        }
        // Start outside the existing box and drag down-right: the release point
        // then lands on the new box's right/bottom corner.
        let dragStart = CGPoint(x: 200, y: 700)
        let dragEnd = CGPoint(x: 980, y: 300)
        overlay.mouseDown(with: mouse(.leftMouseDown, dragStart))
        overlay.mouseDragged(with: mouse(.leftMouseDragged, dragEnd))
        overlay.mouseUp(with: mouse(.leftMouseUp, dragEnd))
        overlay.layoutSubtreeIfNeeded()
        let frozenRect = overlay.selectionRectForTesting
        check(
            "polish: releasing the drag freezes the crosshair",
            overlay.isCrosshairFrozenForTesting
                && overlay.isCrosshairVisibleForTesting,
            "frozen=\(overlay.isCrosshairFrozenForTesting) "
                + "visible=\(overlay.isCrosshairVisibleForTesting)"
        )
        check(
            "polish: it freezes on the selection's corner, not at the raw pointer",
            overlay.crosshairPointForTesting == CGPoint(
                x: frozenRect.maxX,
                y: frozenRect.minY
            ),
            "point=\(String(describing: overlay.crosshairPointForTesting)) "
                + "rect=\(format(frozenRect))"
        )
        // The frozen cross is the selection's coordinate readout: two *full*
        // lines through the release corner, one on each selection edge. The
        // old shape stopped at the corner and only drew the outward arms, which
        // is why the owner saw the cross "缺了一部分".
        let arms = overlay.crosshairArmsForTesting
        let verticalLine = arms.first { abs($0.0.x - $0.1.x) < 0.5 }
        let horizontalLine = arms.first { abs($0.0.y - $0.1.y) < 0.5 }
        check(
            "polish: the frozen cross is two full-screen lines through the corner",
            arms.count == 2
                && verticalLine.map {
                    $0.0.x == frozenRect.maxX && $0.1.x == frozenRect.maxX
                        && Set([$0.0.y, $0.1.y]) == Set([bounds.minY, bounds.maxY])
                } == true
                && horizontalLine.map {
                    $0.0.y == frozenRect.minY && $0.1.y == frozenRect.minY
                        && Set([$0.0.x, $0.1.x]) == Set([bounds.minX, bounds.maxX])
                } == true,
            "arms=\(arms.map { "\($0.0)->\($0.1)" })#\(arms.count)"
        )
        check(
            "polish: those lines lie on the selection's edges and cross its inside",
            verticalLine.map {
                min($0.0.y, $0.1.y) <= frozenRect.minY
                    && max($0.0.y, $0.1.y) >= frozenRect.maxY
            } == true
                && horizontalLine.map {
                    min($0.0.x, $0.1.x) <= frozenRect.minX
                        && max($0.0.x, $0.1.x) >= frozenRect.maxX
                } == true,
            "rect=\(format(frozenRect)) arms=\(arms.map { "\($0.0)->\($0.1)" })"
        )
        check(
            "polish: the frozen line is 1.0–1.2 pt over a 2.5–3 pt dark halo",
            (1.0...1.2).contains(CrosshairView.coreWidth)
                && (2.5...3.0).contains(CrosshairView.haloWidth)
                && CrosshairView.haloWidth > CrosshairView.coreWidth,
            "core=\(CrosshairView.coreWidth) halo=\(CrosshairView.haloWidth)"
        )
        // …and the width in points has to survive the trip to pixels. The
        // stroke is drawn into an explicit 2× bitmap over a black ground (the
        // white core reads) and over a white ground (the dark halo reads), then
        // counted across the line. A retina screenshot is what the owner sees;
        // "1.2 pt" alone would not catch a stroke that rounded up to 4 px.
        let strokeProbe = CrosshairView(frame: CGRect(x: 0, y: 0, width: 160, height: 160))
        strokeProbe.point = CGPoint(x: 80, y: 80)
        strokeProbe.frozenRect = CGRect(x: 40, y: 40, width: 40, height: 40)
        /// `y` is bottom-left (view space); bitmap rows are top-left. `bright`
        /// counts the white core over a black ground; otherwise the whole ink
        /// band is counted over a white ground (the core included — it is what
        /// the dark shoulders are shouldering).
        func countInk(
            _ rendered: (image: CGImage, bytes: [UInt8], width: Int, height: Int),
            scale: Int,
            y: CGFloat,
            bright: Bool
        ) -> (count: Int, profile: String) {
            let row = Int(((160 - y) * CGFloat(scale)).rounded())
            var count = 0
            var bar = ""
            for x in 0..<rendered.width {
                let lum = luminance(rendered.bytes, width: rendered.width, x: x, y: row)
                let on = bright ? lum > 128 : lum < 250
                if on { count += 1 }
                let centre = 80 * scale
                if x >= centre - 6, x <= centre + 6 { bar += on ? "█" : "·" }
            }
            return (count, bar)
        }
        if let core2x = renderInk(strokeProbe, scale: 2, ground: .black),
           let halo2x = renderInk(strokeProbe, scale: 2, ground: .white),
           let core1x = renderInk(strokeProbe, scale: 1, ground: .black) {
            // 40 pt above the frozen rect: only the vertical line crosses this row.
            let core = countInk(core2x, scale: 2, y: 120, bright: true)
            let halo = countInk(halo2x, scale: 2, y: 120, bright: false)
            let coreSmall = countInk(core1x, scale: 1, y: 120, bright: true)
            print(
                "[crosshair] core \(CrosshairView.coreWidth) pt → \(core.count) px @2× "
                    + "\(core.profile) · halo \(CrosshairView.haloWidth) pt → "
                    + "\(halo.count) px \(halo.profile) · core @1× → \(coreSmall.count) px "
                    + "\(coreSmall.profile)"
            )
            check(
                "crosshair: the 1.2 pt core is 2–3 device pixels at 2×",
                (2...3).contains(core.count) && (1...3).contains(coreSmall.count),
                "2×=\(core.count)px 1×=\(coreSmall.count)px " + core.profile
            )
            check(
                "crosshair: the 2.8 pt halo keeps the ink band to 5–7 px at 2×",
                (5...7).contains(halo.count) && halo.count > core.count,
                "ink=\(halo.count)px core=\(core.count)px " + halo.profile
            )
        } else {
            check("crosshair: the 1.2 pt core is 2–3 device pixels at 2×", false)
            check("crosshair: the 2.8 pt halo keeps the ink band to 5–7 px at 2×", false)
        }

        // MARK: P4b — the crosshair must not cut the selection's handles
        //
        // The owner reported the line lying *on top* of the blue grab points.
        // It used to be the last-but-two subview, i.e. above `selectionBorder`.
        // AppKit paints later subviews on top, so moving it under the border is
        // the whole fix — assert the stack order on the real overlay, then the
        // pixels on a bare stack with the same geometry (no toolbar or size
        // chip can mask the answer there).
        check(
            "polish: the crosshair sits under the selection border and handles",
            overlay.isCrosshairBelowSelectionHandlesForTesting,
            "order=\(overlay.subviewOrderForTesting.joined(separator: " < "))"
        )
        let handleStack = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let handleGround = FlatGroundView(frame: handleStack.bounds)
        handleGround.color = NSColor(srgbRed: 0.10, green: 0.13, blue: 0.20, alpha: 1)
        handleStack.addSubview(handleGround)
        let handleBox = CGRect(x: 100, y: 100, width: 200, height: 200)
        // Freeze through the bottom-right corner, so both lines cross that
        // handle's ring.
        let handleCross = CrosshairView(frame: handleStack.bounds)
        handleCross.point = CGPoint(x: handleBox.maxX, y: handleBox.minY)
        handleCross.frozenRect = handleBox
        handleStack.addSubview(handleCross)
        let handleBorder = SelectionBorderView(frame: handleStack.bounds)
        handleBorder.setSelection(handleBox)
        handleStack.addSubview(handleBorder)
        if let image = renderImage(of: handleStack) {
            let handleScale = CGFloat(image.width) / handleStack.bounds.width
            func sample(_ point: CGPoint) -> (r: Int, g: Int, b: Int, a: Int)? {
                pixel(
                    image,
                    x: Int((point.x * handleScale).rounded()),
                    y: Int(((handleStack.bounds.height - point.y) * handleScale).rounded())
                )
            }
            // The ring is a 2 pt accent stroke at radius 5: sample exactly where
            // each frozen line crosses it.
            let ringPoints = [
                CGPoint(x: 300, y: 95), CGPoint(x: 300, y: 105),
                CGPoint(x: 295, y: 100), CGPoint(x: 305, y: 100)
            ]
            let ringPixels = ringPoints.map(sample)
            let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)
                ?? NSColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 1)
            let accentRGB = (
                r: Int((accent.redComponent * 255).rounded()),
                g: Int((accent.greenComponent * 255).rounded()),
                b: Int((accent.blueComponent * 255).rounded())
            )
            let ringIsAccent = ringPixels.allSatisfy { value in
                guard let value else { return false }
                return colourDistance(value, accentRGB) < 90
                    && colourDistance(value, (255, 255, 255)) > 90
            }
            let lineAway = sample(CGPoint(x: handleBox.maxX, y: 40))
            check(
                "polish: the handle ring stays whole where the lines cross it",
                ringIsAccent,
                "ring=" + ringPixels.map {
                    "\($0?.r ?? -1),\($0?.g ?? -1),\($0?.b ?? -1)"
                }.joined(separator: " ") + " accent=\(accentRGB)"
            )
            check(
                "polish: the frozen line is still drawn away from the handles",
                lineAway != nil
                    && lineAway!.r > 200 && lineAway!.g > 200 && lineAway!.b > 200,
                "line=\(String(describing: lineAway))"
            )
            writePNG(
                image,
                to: directory.appendingPathComponent("64-crosshair-handle-z-order.png")
            )
            print("[polish] wrote 64-crosshair-handle-z-order.png")
        } else {
            check("polish: the handle ring stays whole where the lines cross it", false)
            check("polish: the frozen line is still drawn away from the handles", false)
        }
        // Control: the pre-fix order (crosshair added *last*, i.e. above the
        // border) must fail the same probe. Without this the check above could
        // be passing for a reason that has nothing to do with z-order.
        let regressionStack = NSView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 400)
        )
        let regressionGround = FlatGroundView(frame: regressionStack.bounds)
        regressionGround.color = NSColor(srgbRed: 0.10, green: 0.13, blue: 0.20, alpha: 1)
        regressionStack.addSubview(regressionGround)
        let regressionBorder = SelectionBorderView(frame: regressionStack.bounds)
        regressionBorder.setSelection(handleBox)
        regressionStack.addSubview(regressionBorder)
        let regressionCross = CrosshairView(frame: regressionStack.bounds)
        regressionCross.point = CGPoint(x: handleBox.maxX, y: handleBox.minY)
        regressionCross.frozenRect = handleBox
        regressionStack.addSubview(regressionCross)
        if let image = renderImage(of: regressionStack) {
            let regressionScale = CGFloat(image.width) / regressionStack.bounds.width
            let regressionPixels = [
                CGPoint(x: 300, y: 95), CGPoint(x: 300, y: 105),
                CGPoint(x: 295, y: 100), CGPoint(x: 305, y: 100)
            ].map { point in
                pixel(
                    image,
                    x: Int((point.x * regressionScale).rounded()),
                    y: Int(((regressionStack.bounds.height - point.y) * regressionScale).rounded())
                )
            }
            let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)
                ?? NSColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 1)
            let accentRGB = (
                r: Int((accent.redComponent * 255).rounded()),
                g: Int((accent.greenComponent * 255).rounded()),
                b: Int((accent.blueComponent * 255).rounded())
            )
            let cut = regressionPixels.contains { value in
                guard let value else { return true }
                return colourDistance(value, accentRGB) >= 90
                    || colourDistance(value, (255, 255, 255)) <= 90
            }
            check(
                "polish: the pre-fix order does cut the handle (control)",
                cut,
                "ring=" + regressionPixels.map {
                    "\($0?.r ?? -1),\($0?.g ?? -1),\($0?.b ?? -1)"
                }.joined(separator: " ")
            )
            writePNG(
                image,
                to: directory.appendingPathComponent("65-crosshair-handle-before.png")
            )
            print("[polish] wrote 65-crosshair-handle-before.png")
        } else {
            check("polish: the pre-fix order does cut the handle (control)", false)
        }
        check(
            "polish: the frozen cross excludes the toolbar and the size chip",
            overlay.crosshairExclusionRectsForTesting.contains {
                sameRect($0, overlay.toolbarFrameForTesting)
            } && overlay.crosshairExclusionRectsForTesting.contains {
                sameRect($0, overlay.indicatorFrameForTesting)
            },
            "exclusions=\(overlay.crosshairExclusionRectsForTesting.map(format)) "
                + "toolbar=\(format(overlay.toolbarFrameForTesting)) "
                + "chip=\(format(overlay.indicatorFrameForTesting))"
        )

        // The clip itself, on a bare crosshair so no chrome colour can confuse
        // the probe: a chrome rect over one part of the vertical line must leave
        // that part unpainted while the rest of the line stays white.
        let clipView = CrosshairView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        clipView.point = CGPoint(x: 100, y: 100)
        clipView.frozenRect = CGRect(x: 60, y: 60, width: 80, height: 80)
        // Frozen corner (140, 60); the exclusion covers x 125…155, y 0…100.
        clipView.exclusionRects = [CGRect(x: 125, y: 0, width: 30, height: 100)]
        if let clipImage = renderImage(of: clipView) {
            let clipScale = CGFloat(clipImage.width) / 200
            let clipped = pixel(
                clipImage,
                x: Int((140 * clipScale).rounded()),
                y: Int(((200 - 40) * clipScale).rounded())
            )
            let painted = pixel(
                clipImage,
                x: Int((140 * clipScale).rounded()),
                y: Int(((200 - 150) * clipScale).rounded())
            )
            check(
                "polish: chrome rects clip the crosshair stroke",
                clipped != nil && painted != nil
                    && clipped!.a < 16
                    && painted!.a > 200
                    && painted!.r > 180 && painted!.g > 180 && painted!.b > 180,
                "clipped=\(String(describing: clipped)) painted=\(String(describing: painted))"
            )
        } else {
            check("polish: chrome rects clip the crosshair stroke", false)
        }

        // The readout must follow the box while it is nudged: the cross names
        // coordinates, and a nudge changes them.
        let beforeNudge = overlay.crosshairPointForTesting
        overlay.nudgeSelectionForTesting(dx: -12, dy: 7)
        overlay.layoutSubtreeIfNeeded()
        let nudgedRect = overlay.selectionRectForTesting
        check(
            "polish: a nudged box carries its frozen cross along",
            overlay.isCrosshairFrozenForTesting
                && overlay.crosshairPointForTesting == CGPoint(
                    x: nudgedRect.maxX,
                    y: nudgedRect.minY
                )
                && overlay.crosshairPointForTesting != beforeNudge,
            "point=\(String(describing: overlay.crosshairPointForTesting)) "
                + "rect=\(format(nudgedRect))"
        )
        let nudgedLines = overlay.crosshairArmsForTesting
        check(
            "polish: the nudged cross still lies on the new edges",
            nudgedLines.count == 2
                && nudgedLines.contains {
                    abs($0.0.x - nudgedRect.maxX) < 0.01 && abs($0.1.x - nudgedRect.maxX) < 0.01
                }
                && nudgedLines.contains {
                    abs($0.0.y - nudgedRect.minY) < 0.01 && abs($0.1.y - nudgedRect.minY) < 0.01
                },
            "lines=\(nudgedLines.map { "\($0.0)->\($0.1)" })"
        )
        let frozenPoint = overlay.crosshairPointForTesting
        overlay.mouseMoved(with: mouse(.mouseMoved, CGPoint(x: 200, y: 200)))
        check(
            "polish: roaming the canvas does not move the frozen cross",
            overlay.isCrosshairFrozenForTesting
                && overlay.crosshairPointForTesting == frozenPoint,
            "point=\(String(describing: overlay.crosshairPointForTesting))"
        )
        if let frozenImage = renderImage(of: canvas) {
            writePNG(
                frozenImage,
                to: directory.appendingPathComponent("52-crosshair-frozen.png")
            )
            print("[polish] wrote 52-crosshair-frozen.png")
        }
        // Painting inside a committed box must not touch the readout either.
        // `mouseDown` used to assign `crosshair.point` unconditionally, so the
        // first press of a stroke dragged the frozen cross to the pointer (and
        // the arms then re-derived their corner from that raw point) — the user
        // saw the cross jump off the selection edge the moment they annotated.
        let paintRect = overlay.selectionRectForTesting
        let paintPoint = CGPoint(x: paintRect.midX, y: paintRect.midY)
        let armsBeforePaint = overlay.crosshairArmsForTesting.map { "\($0.0)->\($0.1)" }
        let crossBeforePaint = overlay.crosshairPointForTesting
        overlay.selectToolForTesting(.rectangle)
        overlay.mouseDown(with: mouse(.leftMouseDown, paintPoint))
        check(
            "polish: starting a paint stroke does not move the frozen cross",
            overlay.isCrosshairFrozenForTesting
                && overlay.crosshairPointForTesting == crossBeforePaint
                && overlay.crosshairArmsForTesting.map { "\($0.0)->\($0.1)" } == armsBeforePaint,
            "point=\(String(describing: overlay.crosshairPointForTesting)) "
                + "expected=\(String(describing: crossBeforePaint))"
        )
        overlay.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: paintPoint.x + 120, y: paintPoint.y + 70)))
        overlay.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: paintPoint.x + 120, y: paintPoint.y + 70)))
        check(
            "polish: the stroke lands and the cross is still pinned",
            overlay.annotationCountForTesting == 1
                && overlay.isCrosshairFrozenForTesting
                && overlay.crosshairPointForTesting == crossBeforePaint
                && overlay.crosshairArmsForTesting.map { "\($0.0)->\($0.1)" } == armsBeforePaint,
            "count=\(overlay.annotationCountForTesting) "
                + "point=\(String(describing: overlay.crosshairPointForTesting))"
        )
        overlay.selectToolForTesting(.move)

        // Dragging the box releases the freeze, releasing again re-freezes.
        overlay.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: frozenRect.midX, y: frozenRect.midY)))
        check(
            "polish: grabbing the selection releases the freeze",
            !overlay.isCrosshairFrozenForTesting,
            "frozen=\(overlay.isCrosshairFrozenForTesting)"
        )
        overlay.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: frozenRect.midX + 40, y: frozenRect.midY + 30)))
        overlay.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: frozenRect.midX + 40, y: frozenRect.midY + 30)))
        check(
            "polish: the moved selection freezes again on the new corner",
            overlay.isCrosshairFrozenForTesting,
            "frozen=\(overlay.isCrosshairFrozenForTesting)"
        )
        // Reaching for the toolbar must NOT release it. Pinning means pinned:
        // the cross stays on the corner the mouse was released on, through the
        // toolbar and through the size chip, and the toolbar stays clickable.
        // The old behaviour unfroze so the cross followed the pointer onto the
        // chrome — that is the regression the user reported.
        guard let pinnedPoint = overlay.crosshairPointForTesting else {
            check("polish: the moved selection left a frozen cross to test", false)
            return
        }
        let pinnedArmList = overlay.crosshairArmsForTesting
        let pinnedArms = pinnedArmList.map { "\($0.0)->\($0.1)" }
        let toolbarCentre = CGPoint(
            x: overlay.toolbarFrameForTesting.midX,
            y: overlay.toolbarFrameForTesting.midY
        )
        overlay.mouseMoved(with: mouse(.mouseMoved, toolbarCentre))
        check(
            "polish: hovering the toolbar keeps the cross pinned to the release point",
            overlay.isCrosshairFrozenForTesting
                && overlay.crosshairPointForTesting == pinnedPoint
                && overlay.crosshairArmsForTesting.map { "\($0.0)->\($0.1)" } == pinnedArms,
            "frozen=\(overlay.isCrosshairFrozenForTesting) "
                + "point=\(String(describing: overlay.crosshairPointForTesting)) "
                + "expected=\(String(describing: pinnedPoint))"
        )
        // Offscreen proof: the pointer sits on the toolbar, the cross is still
        // on the release corner.
        let toolbarHoverImage = renderImage(of: canvas)
        if let toolbarHoverImage {
            writePNG(
                toolbarHoverImage,
                to: directory.appendingPathComponent("56-crosshair-frozen-over-toolbar.png")
            )
            print("[polish] wrote 56-crosshair-frozen-over-toolbar.png")
            if let data = NSBitmapImageRep(cgImage: toolbarHoverImage)
                .representation(using: .png, properties: [:]) {
                copyToVerification(data, named: "fix2-56-crosshair-frozen-over-toolbar.png")
            }
        } else {
            check("polish: render the frozen cross over the toolbar", false)
        }

        // The size chip is chrome too: hovering it must not thaw the cross.
        let chipCentre = CGPoint(
            x: overlay.indicatorFrameForTesting.midX,
            y: overlay.indicatorFrameForTesting.midY
        )
        overlay.mouseMoved(with: mouse(.mouseMoved, chipCentre))
        check(
            "polish: hovering the size chip keeps the cross pinned too",
            overlay.isCrosshairFrozenForTesting
                && overlay.isIndicatorVisibleForTesting
                && overlay.crosshairPointForTesting == pinnedPoint,
            "frozen=\(overlay.isCrosshairFrozenForTesting) "
                + "indicator=\(overlay.isIndicatorVisibleForTesting) "
                + "point=\(String(describing: overlay.crosshairPointForTesting))"
        )

        // A pinned cross does not take the toolbar's clicks away.
        if let action = overlay.toolbarButtonFramesForTesting().first {
            let hit = overlay.hitTest(CGPoint(x: action.frame.midX, y: action.frame.midY))
            check(
                "polish: a pinned cross still leaves the toolbar clickable",
                (hit as? CaptureToolbarButton)?.toolbarAction == action.action,
                "expected=\(action.action.rawValue) "
                    + "got=\((hit as? CaptureToolbarButton).map(\.toolbarAction.rawValue) ?? "nil")"
            )
        } else {
            check("polish: toolbar action frames resolve", false)
        }

        // Leaving the chrome does not move it either: the two renders must put
        // the frozen arms on the same pixels.
        overlay.mouseMoved(with: mouse(.mouseMoved, CGPoint(x: 200, y: 200)))
        check(
            "polish: leaving the toolbar does not move the pinned cross",
            overlay.isCrosshairFrozenForTesting
                && overlay.crosshairPointForTesting == pinnedPoint,
            "point=\(String(describing: overlay.crosshairPointForTesting))"
        )
        if let awayImage = renderImage(of: canvas) {
            writePNG(
                awayImage,
                to: directory.appendingPathComponent("57-crosshair-frozen-away-from-toolbar.png")
            )
            print("[polish] wrote 57-crosshair-frozen-away-from-toolbar.png")
            if let data = NSBitmapImageRep(cgImage: awayImage)
                .representation(using: .png, properties: [:]) {
                copyToVerification(data, named: "fix2-57-crosshair-frozen-away-from-toolbar.png")
            }
            if let toolbarHoverImage {
                // Three probes: the corner itself and one midpoint per arm.
                var probes: [CGPoint] = [pinnedPoint]
                if let horizontal = pinnedArmList.first(where: { abs($0.0.y - $0.1.y) < 0.5 }) {
                    probes.append(
                        CGPoint(x: (horizontal.0.x + horizontal.1.x) / 2, y: horizontal.0.y)
                    )
                }
                if let vertical = pinnedArmList.first(where: { abs($0.0.x - $0.1.x) < 0.5 }) {
                    probes.append(
                        CGPoint(x: vertical.0.x, y: (vertical.0.y + vertical.1.y) / 2)
                    )
                }
                let scale = CGFloat(toolbarHoverImage.width) / bounds.width
                var mismatches: [String] = []
                for probe in probes {
                    let sampleA = pixel(
                        toolbarHoverImage,
                        x: Int((probe.x * scale).rounded()),
                        y: Int(((bounds.height - probe.y) * scale).rounded())
                    )
                    let sampleB = pixel(
                        awayImage,
                        x: Int((probe.x * scale).rounded()),
                        y: Int(((bounds.height - probe.y) * scale).rounded())
                    )
                    if sampleA == nil || sampleB == nil
                        || abs(sampleA!.r - sampleB!.r) > 1
                        || abs(sampleA!.g - sampleB!.g) > 1
                        || abs(sampleA!.b - sampleB!.b) > 1 {
                        mismatches.append(
                            "\(number(probe.x)),\(number(probe.y)): "
                                + "\(String(describing: sampleA)) vs \(String(describing: sampleB))"
                        )
                    }
                }
                check(
                    "polish: the frozen cross paints the same pixels with the pointer on the toolbar",
                    mismatches.isEmpty,
                    mismatches.joined(separator: " | ")
                )
            }
        } else {
            check("polish: render the frozen cross off the toolbar", false)
        }
        // Drawing a new box outside the selection also releases it.
        overlay.mouseDown(with: mouse(.leftMouseDown, dragStart))
        overlay.mouseDragged(with: mouse(.leftMouseDragged, dragEnd))
        overlay.mouseUp(with: mouse(.leftMouseUp, dragEnd))
        let freshRect = overlay.selectionRectForTesting
        check(
            "polish: a new box freezes on its own corner",
            overlay.isCrosshairFrozenForTesting
                && overlay.crosshairPointForTesting == CGPoint(
                    x: freshRect.maxX,
                    y: freshRect.minY
                ),
            "point=\(String(describing: overlay.crosshairPointForTesting)) "
                + "rect=\(format(freshRect))"
        )

        // MARK: P0 — click outside cancels, drag outside re-frames
        //
        // A window sits under the blank area so the *old* behaviour is
        // observable: a plain click outside used to fall through to the
        // window picker, which armed (or captured) whatever was under the
        // pointer instead of dismissing the box the user was done with.
        overlay.setWindowPickCandidatesForTesting([
            WindowCandidate(
                windowNumber: 4242,
                bounds: CGRect(x: 0, y: 0, width: 500, height: 300),
                layer: 0,
                ownerPID: 1,
                ownerName: "Fixture",
                windowName: "Fixture",
                isOwnedBySelf: false
            )
        ])
        let outside = CGPoint(x: 40, y: 40)
        click(overlay, at: outside)
        check(
            "outside: a click outside the box cancels the whole selection",
            overlay.selectionRectForTesting.width < 1
                && overlay.selectionRectForTesting.height < 1
                && overlay.committedRectForTesting == nil,
            "selection=\(format(overlay.selectionRectForTesting)) "
                + "committed=\(String(describing: overlay.committedRectForTesting))"
        )
        check(
            "outside: that click does not arm (or capture) the window behind it",
            overlay.armedWindowIDForTesting == nil
                && !overlay.isWindowHighlightVisibleForTesting,
            "armed=\(String(describing: overlay.armedWindowIDForTesting)) "
                + "highlight=\(overlay.isWindowHighlightVisibleForTesting)"
        )
        check(
            "outside: cancelling brings the tracking crosshair back",
            !overlay.isCrosshairFrozenForTesting
                && overlay.isCrosshairVisibleForTesting
                && overlay.crosshairArmsForTesting.count == 4,
            "frozen=\(overlay.isCrosshairFrozenForTesting) "
                + "arms=\(overlay.crosshairArmsForTesting.count)"
        )
        // Once there is no selection, the same click is a window pick again:
        // dismissing must not disable the feature for the next click.
        click(overlay, at: outside)
        check(
            "outside: with no box, the next click picks the window again",
            overlay.armedWindowIDForTesting == 4242,
            "armed=\(String(describing: overlay.armedWindowIDForTesting))"
        )
        // Drag outside: the armed window gives way and a brand-new box is
        // framed from the drag's own origin.
        drag(overlay, from: CGPoint(x: 60, y: 60), to: CGPoint(x: 360, y: 260))
        check(
            "outside: a drag outside re-frames from scratch",
            overlay.selectionRectForTesting == CGRect(x: 60, y: 60, width: 300, height: 200)
                && overlay.armedWindowIDForTesting == nil,
            "selection=\(format(overlay.selectionRectForTesting)) "
                + "armed=\(String(describing: overlay.armedWindowIDForTesting))"
        )
        check(
            "outside: the new box freezes the cross on its own corner",
            overlay.isCrosshairFrozenForTesting
                && overlay.crosshairPointForTesting == CGPoint(
                    x: overlay.selectionRectForTesting.maxX,
                    y: overlay.selectionRectForTesting.maxY
                ),
            "point=\(String(describing: overlay.crosshairPointForTesting)) "
                + "rect=\(format(overlay.selectionRectForTesting))"
        )
        // A click *inside* the box is not a cancel: the move tool keeps it.
        let keptRect = overlay.selectionRectForTesting
        click(overlay, at: CGPoint(x: keptRect.midX, y: keptRect.midY))
        check(
            "outside: a click inside the box keeps it",
            overlay.selectionRectForTesting == keptRect,
            "selection=\(format(overlay.selectionRectForTesting)) "
                + "expected=\(format(keptRect))"
        )

        // The switch off means no crosshair at all, frozen or not.
        let noCrosshair = CaptureOverlayView(
            frame: bounds,
            mode: .region,
            prefilledSelection: nil,
            showCrosshair: false,
            rendersOffscreen: true
        )
        canvas.addSubview(noCrosshair)
        noCrosshair.mouseDown(with: mouse(.leftMouseDown, dragStart))
        noCrosshair.mouseDragged(with: mouse(.leftMouseDragged, dragEnd))
        noCrosshair.mouseUp(with: mouse(.leftMouseUp, dragEnd))
        check(
            "polish: with the crosshair switch off nothing freezes or draws",
            !noCrosshair.isCrosshairFrozenForTesting
                && !noCrosshair.isCrosshairVisibleForTesting,
            "frozen=\(noCrosshair.isCrosshairFrozenForTesting) "
                + "visible=\(noCrosshair.isCrosshairVisibleForTesting)"
        )
        noCrosshair.removeFromSuperview()

        // MARK: P3 — a live scrolling session adds no chrome to the selection
        //
        // The owner asked for the white boundary line, its end ticks, the
        // "已截取 1.4 屏" pill and the 4.5 % "captured" lift to be removed: the
        // selection must stay exactly the pixels the user drew, with only the
        // selection border, handles, size chip, toolbar and the separate
        // preview card around it. These checks render a live session on a
        // clean canvas and compare the selection's interior against the
        // untouched background.
        let sessionCanvas = TestCanvasView(frame: bounds)
        let session = CaptureOverlayView(
            frame: bounds,
            mode: .region,
            prefilledSelection: nil,
            showCrosshair: false,
            rendersOffscreen: true,
            scrollMode: true,
            scrollPreviewEnabled: true
        )
        sessionCanvas.addSubview(session)
        session.applySelectionForTesting(selection)
        session.revealToolbarForTesting()
        session.beginScrollSessionForTesting()
        check(
            "polish: the scrolling session is live",
            session.isScrollActiveForTesting,
            "active=\(session.isScrollActiveForTesting)"
        )
        session.layoutSubtreeIfNeeded()
        // The page is 1260 px of the 1520 px-wide capture, so the stitch is this
        // many selection-heights tall.
        let expectedRatio = 1260 * selection.width / 1520 / selection.height
        guard let partialPage = makeDocumentImage(width: 1520, height: 1260) else {
            check("polish: build the partial page", false)
            return
        }
        session.updateScrollPreview(
            preview: ScrollPreviewFrame.make(
                from: partialPage,
                size: ScrollPreviewPod.bandSize(forCardSize: session.scrollPodDrawnSizeForTesting)
            ),
            phase: .capturing,
            autoScrolling: false
        )
        session.layoutSubtreeIfNeeded()
        let ratio = session.scrollProgressRatioForTesting
        check(
            "polish: the captured length still tracks the stitched page",
            abs(ratio - expectedRatio) < 0.02 && ratio > 1.3,
            "ratio=\(ratio) expected=\(expectedRatio)"
        )
        guard let progressImage = renderImage(of: sessionCanvas) else {
            check("polish: render the live scrolling selection", false)
            return
        }
        // Probe the whole interior on a grid: every sample must equal the raw
        // canvas. The old captured lift (white at 4.5 %) failed this on the
        // captured band, and any boundary line / ticks / pill failed it too.
        var chromeProbes: [String] = []
        var x = selection.minX + 30
        while x <= selection.maxX - 30 {
            var y = selection.minY + 30
            while y <= selection.maxY - 30 {
                let point = CGPoint(x: x, y: y)
                let drawn = renderPixel(progressImage, point)
                let raw = renderPixel(canvasImage, point)
                if drawn == nil || raw == nil
                    || abs(drawn!.r - raw!.r) > 2
                    || abs(drawn!.g - raw!.g) > 2
                    || abs(drawn!.b - raw!.b) > 2 {
                    chromeProbes.append(
                        "\(number(x)),\(number(y)): \(String(describing: drawn)) "
                            + "vs \(String(describing: raw))"
                    )
                }
                y += 40
            }
            x += 40
        }
        check(
            "polish: the selection carries no long-capture chrome (no lift, no line, no pill)",
            chromeProbes.isEmpty,
            chromeProbes.prefix(4).joined(separator: " | ")
        )
        // The exact place the old boundary line would sit: it must be the raw
        // canvas too, not a bright stroke.
        let formerBoundaryY = selection.maxY
            - min(1, max(0, ratio - 1)) * selection.height
        let onFormerLine = renderPixel(
            progressImage,
            CGPoint(x: selection.maxX - 60, y: formerBoundaryY)
        )
        let rawOnFormerLine = renderPixel(
            canvasImage,
            CGPoint(x: selection.maxX - 60, y: formerBoundaryY)
        )
        check(
            "polish: no boundary line or progress pill is drawn across the selection",
            onFormerLine != nil && rawOnFormerLine != nil
                && abs(onFormerLine!.r - rawOnFormerLine!.r) <= 2
                && abs(onFormerLine!.g - rawOnFormerLine!.g) <= 2
                && abs(onFormerLine!.b - rawOnFormerLine!.b) <= 2,
            "drawn=\(String(describing: onFormerLine)) "
                + "raw=\(String(describing: rawOnFormerLine))"
        )
        writePNG(
            progressImage,
            to: directory.appendingPathComponent("51-scroll-selection-clean.png")
        )
        print("[polish] wrote 51-scroll-selection-clean.png")

        // MARK: P2/P5 evidence without the scroll chrome
        let plainCanvas = TestCanvasView(frame: bounds)
        let plainOverlay = CaptureOverlayView(
            frame: bounds,
            mode: .region,
            prefilledSelection: nil,
            showCrosshair: false,
            rendersOffscreen: true
        )
        plainCanvas.addSubview(plainOverlay)
        plainOverlay.applySelectionForTesting(CGRect(x: 420, y: 300, width: 620, height: 380))
        plainOverlay.revealToolbarForTesting()
        plainOverlay.layoutSubtreeIfNeeded()
        if let plainImage = renderImage(of: plainCanvas) {
            writePNG(plainImage, to: directory.appendingPathComponent("53-veil-flat-rounded.png"))
            print("[polish] wrote 53-veil-flat-rounded.png")
        }

        // MARK: P6 — the window corner really reaches the delivered pixels
        guard let white = solidImage(width: 200, height: 150, color: .white) else {
            check("polish: build the corner probe image", false)
            return
        }
        let clipped = CaptureCorner.clipped(white, radius: 12, scale: 2)
        check(
            "polish: clipping keeps the image's size",
            clipped.width == 200 && clipped.height == 150,
            "=\(clipped.width)×\(clipped.height)"
        )
        let topLeft = pixel(clipped, x: 0, y: 0)
        let bottomRight = pixel(clipped, x: 199, y: 149)
        let centre = pixel(clipped, x: 100, y: 75)
        let edgeMid = pixel(clipped, x: 100, y: 0)
        let insideCorner = pixel(clipped, x: 40, y: 40)
        check(
            "polish: the delivered image's corners are transparent",
            topLeft?.a == 0 && bottomRight?.a == 0,
            "tl=\(String(describing: topLeft)) br=\(String(describing: bottomRight))"
        )
        check(
            "polish: the window corner does not eat the edges or the middle",
            centre?.a == 255 && edgeMid?.a == 255 && insideCorner?.a == 255,
            "centre=\(String(describing: centre)) edge=\(String(describing: edgeMid)) "
                + "inner=\(String(describing: insideCorner))"
        )
        // The radius in pixels: 12 pt × 2 = 24 px. A quarter of it in from the
        // corner is still outside the rounded shape, a full radius in is inside.
        let justInCorner = pixel(clipped, x: 4, y: 4)
        let pastCorner = pixel(clipped, x: 26, y: 26)
        check(
            "polish: the transparent corner is the size of a macOS window corner",
            justInCorner?.a == 0 && pastCorner?.a == 255,
            "4px=\(String(describing: justInCorner)) 26px=\(String(describing: pastCorner))"
        )
        if let evidence = cornerEvidenceImage(clipped) {
            writePNG(evidence, to: directory.appendingPathComponent("54-export-corner-alpha.png"))
            print("[polish] wrote 54-export-corner-alpha.png")
        }
    }

    /// The clipped shot over a checkerboard, at 3×, so transparency reads as a
    /// rounded corner instead of a black pixel in the evidence PNG.
    private static func cornerEvidenceImage(_ image: CGImage) -> CGImage? {
        let scale = 3
        let width = image.width * scale
        let height = image.height * scale
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let cell = 12
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let light = ((x / cell) + (y / cell)).isMultiple(of: 2)
                let level: CGFloat = light ? 0.82 : 0.55
                context.setFillColor(
                    CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [level, level, level, 1])
                        ?? NSColor.black.cgColor
                )
                context.fill(CGRect(x: x, y: y, width: cell, height: cell))
                x += cell
            }
            y += cell
        }
        context.interpolationQuality = .none
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        )
        return context.makeImage()
    }

    /// A frame of the whole view, for pixel probes.
    private static func bitmapRep(of view: NSView) -> NSBitmapImageRep? {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// The moment the box is committed used to show one screen of content
    /// under a card as tall as the selection — an empty well with a thin strip
    /// of picture at the bottom. The card now *is* the content: it starts at
    /// the first screen, sharp and flush with the bottom, and grows until it is
    /// as tall as the selection.
    private static func runScrollShortContentTests(into directory: URL) {
        print("[scroll-short] --- the card grows from the region's own pixels ---")
        let bounds = CGRect(origin: .zero, size: canvasSize)
        let selection = CGRect(x: 300, y: 150, width: 760, height: 620)
        guard let page = makeDocumentImage(width: 1520, height: 1240),
              let three = makeDocumentImage(width: 1520, height: 3720),
              let long = makeDocumentImage(width: 1520, height: 9920) else {
            check("[scroll-short]: build document pages", false)
            return
        }

        let canvas = TestCanvasView(frame: bounds)
        let overlay = CaptureOverlayView(
            frame: bounds,
            mode: .region,
            prefilledSelection: nil,
            showCrosshair: false,
            rendersOffscreen: true,
            scrollMode: true,
            scrollPreviewEnabled: true
        )
        canvas.addSubview(overlay)
        overlay.applySelectionForTesting(selection)
        overlay.revealToolbarForTesting()
        overlay.beginScrollSessionForTesting()
        overlay.layoutSubtreeIfNeeded()
        overlay.updateScrollPreview(
            preview: previewFrame(page, for: overlay.scrollPodForTesting),
            phase: .capturing,
            autoScrolling: false
        )
        overlay.layoutSubtreeIfNeeded()

        let pod = overlay.scrollPodForTesting
        check(
            "[scroll-short]: the first screen is shorter than the selection",
            pod.visibleCardHeight < selection.height - 1,
            "card=\(pod.visibleCardHeight) selection=\(selection.height)"
        )
        check(
            "[scroll-short]: the well is exactly the content, no padding by blur",
            abs(pod.wellRect.height - pod.contentHeight) < 1.5,
            "well=\(pod.wellRect.height) content=\(pod.contentHeight)"
        )
        // The top of the well must be the page's own pixels, at full strength:
        // the band is drawn 1:1 into the well, so what the well shows at its top
        // edge is the band's top edge, not a blurred copy.
        let bandTop = pod.preview.flatMap {
            pixel($0.image, x: $0.image.width / 2, y: 0)
        }
        var renderedTop: (r: Int, g: Int, b: Int, a: Int)?
        if let rep = bitmapRep(of: canvas), let image = rep.cgImage {
            let scale = CGFloat(rep.pixelsWide) / bounds.width
            let well = pod.wellRect.offsetBy(dx: pod.frame.minX, dy: pod.frame.minY)
            renderedTop = pixel(
                image,
                x: Int((well.midX * scale).rounded()),
                y: Int(((bounds.height - (well.maxY - 3)) * scale).rounded())
            )
        }
        check(
            "[scroll-short]: the top of the well is the page, not a blank surface",
            bandTop != nil && renderedTop != nil
                && abs(bandTop!.r - renderedTop!.r) <= 20
                && abs(bandTop!.g - renderedTop!.g) <= 20
                && abs(bandTop!.b - renderedTop!.b) <= 20,
            "band=\(String(describing: bandTop)) rendered=\(String(describing: renderedTop))"
        )
        renderScrollUI(name: "31-scroll-first-screen", canvas: canvas, into: directory)

        overlay.updateScrollPreview(
            preview: previewFrame(three, for: pod),
            phase: .capturing,
            autoScrolling: false
        )
        overlay.layoutSubtreeIfNeeded()
        let grown = pod.visibleCardHeight
        check(
            "[scroll-short]: three screens make the card taller, still under the box",
            grown > ScrollPreviewPod.minimumCardHeight
                && grown < selection.height - 1,
            "card=\(grown) selection=\(selection.height)"
        )
        renderScrollUI(name: "32-scroll-third-frame", canvas: canvas, into: directory)

        overlay.updateScrollPreview(
            preview: previewFrame(long, for: pod),
            phase: .capturing,
            autoScrolling: false
        )
        overlay.layoutSubtreeIfNeeded()
        check(
            "[scroll-short]: a long page freezes the card, then scales it down",
            pod.isFrozen
                && pod.scale < 1
                && pod.visibleCardHeight < selection.height - 1
                && pod.contentHeight > pod.wellRect.height,
            "card=\(pod.visibleCardHeight) scale=\(pod.scale) "
                + "content=\(pod.contentHeight) well=\(pod.wellRect.height)"
        )
        renderScrollUI(name: "33-scroll-long", canvas: canvas, into: directory)
    }

    /// Three selections of very different heights (400 / 765 / 820 pt on the
    /// 900-pt canvas) prove the *frame* follows the selection, that the card
    /// grows inside it, and that a longer stitch never moves or resizes either
    /// once the card has reached the selection's height.
    private static func runScrollPreviewHeightTests(into directory: URL) {
        print("[scroll-preview] --- the frame follows the selection, the card grows ---")
        let bounds = CGRect(origin: .zero, size: canvasSize)
        let cases: [(name: String, selection: CGRect)] = [
            ("28-scroll-preview-height-400", CGRect(x: 300, y: 260, width: 760, height: 400)),
            ("29-scroll-preview-height-765", CGRect(x: 300, y: 60, width: 760, height: 765)),
            ("30-scroll-preview-height-820", CGRect(x: 300, y: 24, width: 760, height: 820))
        ]
        guard let firstScreen = makeDocumentImage(width: 1520, height: 840) else {
            check("scroll-preview: build stitch images", false)
            return
        }

        for item in cases {
            let canvas = TestCanvasView(frame: bounds)
            let overlay = CaptureOverlayView(
                frame: bounds,
                mode: .region,
                prefilledSelection: nil,
                showCrosshair: false,
                rendersOffscreen: true,
                scrollMode: true,
                scrollPreviewEnabled: true
            )
            canvas.addSubview(overlay)
            overlay.applySelectionForTesting(item.selection)
            overlay.revealToolbarForTesting()
            overlay.beginScrollSessionForTesting()
            overlay.layoutSubtreeIfNeeded()
            overlay.updateScrollPreview(
                preview: previewFrame(firstScreen, for: overlay.scrollPodForTesting),
                phase: .capturing,
                autoScrolling: true
            )
            overlay.layoutSubtreeIfNeeded()

            let pod = overlay.scrollPodForTesting
            let frame = overlay.scrollPodFrameForTesting
            let shortCard = pod.cardRect
            check(
                "\(item.name): the frame is the selection's height, the card is shorter",
                abs(frame.height - item.selection.height) < 0.01
                    && shortCard.height < item.selection.height - 1
                    && abs(shortCard.minY) < 0.01,
                "frame=\(format(frame)) card=\(format(shortCard)) "
                    + "selection=\(format(item.selection))"
            )
            check(
                "\(item.name): the card is narrower than the selection, outside it, on screen",
                pod.cardSize.width > 0
                    && pod.cardSize.width < item.selection.width
                    && !frame.intersects(item.selection)
                    && bounds.contains(frame),
                "card=\(format(frame)) selection=\(format(item.selection))"
            )
            renderScrollUI(name: item.name, canvas: canvas, into: directory)

            // The page whose content lands exactly on the box's well: at that
            // instant the card is the selection's height and freezes.
            let freezePixels = Int(
                ((pod.cardSize.height - ScrollPreviewPod.chromeHeight)
                    * 1520 / (pod.cardSize.width - ScrollPreviewPod.padding * 2)).rounded()
            )
            guard let atFull = makeDocumentImage(width: 1520, height: freezePixels),
                  let longPage = makeDocumentImage(
                      width: 1520,
                      height: Int(Double(freezePixels) * 2.6)
                  ) else {
                check("\(item.name): build freeze images", false)
                return
            }
            overlay.updateScrollPreview(
                preview: previewFrame(atFull, for: pod),
                phase: .capturing,
                autoScrolling: true
            )
            overlay.layoutSubtreeIfNeeded()
            let fullCard = pod.cardRect
            check(
                "\(item.name): one box of content freezes the card at the selection's height",
                abs(fullCard.height - item.selection.height) < 1
                    && pod.isFrozen
                    && pod.scale == 1
                    && overlay.scrollPodFrameForTesting == frame,
                "card=\(format(fullCard)) frame=\(format(overlay.scrollPodFrameForTesting))"
            )
            let before = pod.cardRect
            let beforeContent = pod.contentHeight
            overlay.updateScrollPreview(
                preview: previewFrame(atFull, for: pod),
                phase: .capturing,
                autoScrolling: true
            )
            check(
                "\(item.name): the same frame again changes no geometry",
                pod.cardRect == before
                    && pod.contentHeight == beforeContent
                    && overlay.scrollPodFrameForTesting == frame,
                "card=\(format(pod.cardRect)) content=\(pod.contentHeight)"
            )
            // P1 supplement: a longer page scales the card down, anchored.
            overlay.updateScrollPreview(
                preview: previewFrame(longPage, for: pod),
                phase: .capturing,
                autoScrolling: true
            )
            overlay.layoutSubtreeIfNeeded()
            check(
                "\(item.name): a longer page scales the card down, anchored on the corner",
                pod.scale < 1
                    && pod.cardRect.height < before.height - 1
                    && pod.cardRect.width < before.width - 1
                    && abs(pod.cardRect.minY) < 0.01
                    && overlay.scrollPodFrameForTesting == frame,
                "card=\(format(pod.cardRect)) before=\(format(before)) "
                    + "scale=\(pod.scale)"
            )

            // The visible object is the external panel, not the in-view copy
            // used for renders: prove it adopts the same frame and final card.
            let panelController = ScrollPreviewPanelController()
            panelController.present(placement: ScrollPreviewPlacement.make(
                region: item.selection,
                screen: bounds
            ))
            // AppKit rounds a window frame to whole points, so allow that
            // sub-point difference; the card itself is exact.
            let panelFrame = panelController.panel.frame
            check(
                "\(item.name): the external panel adopts the placement",
                abs(panelFrame.minX - frame.minX) < 1.01
                    && abs(panelFrame.minY - frame.minY) < 1.01
                    && abs(panelFrame.width - frame.width) < 1.01
                    && abs(panelFrame.height - frame.height) < 1.01
                    && abs(panelController.pod.cardSize.height - item.selection.height) < 0.01
                    && abs(panelController.pod.cardSize.width - pod.cardSize.width) < 0.01,
                "panel=\(format(panelFrame)) "
                    + "pod=\(format(panelController.pod.frame)) "
                    + "card=\(format(panelController.pod.cardRect))"
            )
            panelController.close()
        }
    }

    /// Render a view tree to an image, the same way every offscreen probe does.
    private static func renderImage(of view: NSView) -> CGImage? {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    /// Render one view at an explicit device scale over a known ground.
    ///
    /// `cacheDisplay` uses the backing scale of the window a view is in, which
    /// offscreen is 1×. A stroke width in points is not evidence of what the
    /// user sees on a Retina screen, so the stroke probes draw the view into a
    /// `scale`× bitmap themselves and count device pixels.
    private static func renderInk(
        _ view: NSView,
        scale: Int,
        ground: NSColor
    ) -> (image: CGImage, bytes: [UInt8], width: Int, height: Int)? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width) * scale,
            pixelsHigh: Int(view.bounds.height) * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        // The logical size has to be in points *before* the context is built:
        // the context takes its scale from it, and the view draws in points.
        rep.size = view.bounds.size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        ground.setFill()
        CGRect(origin: .zero, size: view.bounds.size).fill()
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData, let image = rep.cgImage else { return nil }
        let count = rep.bytesPerRow * rep.pixelsHigh
        return (
            image,
            Array(UnsafeBufferPointer(start: data, count: count)),
            rep.pixelsWide,
            rep.pixelsHigh
        )
    }

    /// Luminance of one pixel in a top-left-origin RGBA buffer.
    private static func luminance(
        _ bytes: [UInt8],
        width: Int,
        x: Int,
        y: Int
    ) -> Int {
        let index = (y * width + x) * 4
        return (Int(bytes[index]) + Int(bytes[index + 1]) + Int(bytes[index + 2])) / 3
    }

    /// One flat colour, for the "is this surface translucent?" probes.
    private static func solidImage(width: Int, height: Int, color: NSColor) -> CGImage? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        color.setFill()
        CGRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    private static func renderScrollUI(name: String, canvas: NSView, into directory: URL) {
        canvas.layoutSubtreeIfNeeded()
        guard let representation = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
            check("\(name): render bitmap", false)
            return
        }
        canvas.cacheDisplay(in: canvas.bounds, to: representation)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            check("\(name): encode PNG", false)
            return
        }
        let url = directory.appendingPathComponent("\(name).png")
        do {
            try png.write(to: url)
            print(
                "[scroll-ui] wrote \(url.path) "
                    + "(\(representation.pixelsWide)×\(representation.pixelsHigh) px)"
            )
            copyToVerification(png, named: "\(name).png")
            check("\(name): the render has real pixels", png.count > 8_000, "bytes=\(png.count)")
        } catch {
            check("\(name): write PNG", false, error.localizedDescription)
        }
    }

    // MARK: - O. Delay countdown state machine

    private static func runDelayCountdownTests() {
        var countdown = DelayCountdown(seconds: 3)
        check("delay: starts at 3", countdown.remaining == 3 && countdown.displayText == "3")
        let events = [countdown.tick(), countdown.tick(), countdown.tick()]
        check(
            "delay: ticks 3 → 2 → 1 → capture",
            events == [.countdown(2), .countdown(1), .capture],
            "events=\(events)"
        )
        check("delay: remaining is 0 after capture", countdown.remaining == 0)
        check("delay: capture is idempotent", countdown.tick() == .capture)
        check(
            "delay: cannot cancel after capture fired",
            countdown.cancel() == .capture && !countdown.isCancelled
        )

        var cancelled = DelayCountdown(seconds: 5)
        check("delay: 5-second countdown starts at 5", cancelled.remaining == 5)
        check("delay: first tick is 4", cancelled.tick() == .countdown(4))
        check("delay: cancel returns cancelled", cancelled.cancel() == .cancelled)
        check(
            "delay: cancelled clock never fires",
            cancelled.tick() == .cancelled && cancelled.isCancelled
        )

        let clampedLow = DelayCountdown(seconds: 0)
        check("delay: zero delay clamps to one second", clampedLow.seconds == 1 && clampedLow.remaining == 1)
        let clampedHigh = DelayCountdown(seconds: 500)
        check("delay: delay clamps to 60 seconds", clampedHigh.seconds == 60)
        check(
            "delay: settings options are 3 / 5 / 10",
            AppSettings.delayOptions == [3, 5, 10]
        )
    }

    // MARK: - P. Multi-window composition

    private static func runMultiWindowTests(into directory: URL) {
        guard let red = makeSolidImage(
                  color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
                  width: 200,
                  height: 160
              ),
              let blue = makeSolidImage(
                  color: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1),
                  width: 120,
                  height: 80
              )
        else {
            check("multi-window: build pieces", false)
            return
        }

        // AppKit global frames (bottom-left origin), as they arrive from the
        // overlay. The images are already at 2× pixel size.
        let frameA = CGRect(x: 100, y: 100, width: 100, height: 80)
        let frameB = CGRect(x: 300, y: 50, width: 60, height: 40)

        let union = MultiWindowComposer.boundingRect(of: [frameA, frameB])
        check(
            "multi-window: union is the outer bounding rect",
            union == CGRect(x: 100, y: 50, width: 260, height: 130),
            "union=\(format(union ?? .zero))"
        )
        check(
            "multi-window: empty selection has no bounding rect",
            MultiWindowComposer.boundingRect(of: []) == nil
        )
        check(
            "multi-window: a single frame is its own bounding rect",
            MultiWindowComposer.boundingRect(of: [frameA]) == frameA
        )

        guard let composed = MultiWindowComposer.compose(
            pieces: [
                MultiWindowComposer.Piece(image: red, frame: frameA),
                MultiWindowComposer.Piece(image: blue, frame: frameB)
            ],
            scale: 2
        ) else {
            check("multi-window: compose pieces", false)
            return
        }
        check(
            "multi-window: composite is the union × scale",
            composed.width == 520 && composed.height == 260,
            "size=\(composed.width)×\(composed.height) expected=520×260"
        )

        // A starts at the composite's top-left: 200×160 px.
        let redChecks = [
            (10, 10),
            (190, 150)
        ]
        for (x, y) in redChecks {
            let (matches, detail) = pixelMatches(composed, x: x, y: y, expected: (255, 0, 0))
            check("multi-window: window A red at (\(x),\(y))", matches, detail)
        }

        // B's top-left is (300−100)×2 = 400 px right, (180−90)×2 = 180 px down.
        let blueChecks = [
            (410, 190),
            (510, 250)
        ]
        for (x, y) in blueChecks {
            let (matches, detail) = pixelMatches(composed, x: x, y: y, expected: (0, 0, 255))
            check("multi-window: window B blue at (\(x),\(y))", matches, detail)
        }

        // The gap between the two windows stays transparent, and A does not
        // smear below its own 160 px height.
        for (x, y, label) in [(250, 100, "between the windows"), (10, 170, "below window A")] {
            let actual = pixel(composed, x: x, y: y)
            check(
                "multi-window: \(label) is transparent",
                actual?.a == 0,
                "pixel=\(String(describing: actual))"
            )
        }

        if let data = NSBitmapImageRep(cgImage: composed).representation(using: .png, properties: [:]) {
            let url = directory.appendingPathComponent("multi-window-composite.png")
            try? data.write(to: url)
            print("[multi-window] wrote \(url.path) (\(data.count) bytes)")
        }
    }

    // MARK: - S. Single click → window + the three-mode entry

    /// Two independent behaviours:
    /// 1. a single click (< 4 pt, no existing selection) in the region overlay
    ///    resolves the window under the pointer and captures it immediately;
    ///    a drag and a click on empty desktop are untouched;
    /// 2. `CaptureMode.window` is the zero-UI instant path, not an overlay.
    private static func runWindowPickTests(into directory: URL) async {
        let canvas = CGRect(origin: .zero, size: canvasSize)

        // MARK: Threshold (pure)

        print("[single-tap] --- threshold (pure) ---")
        let origin = CGPoint(x: 400, y: 300)
        check(
            "single-tap: 0 pt is a tap",
            CaptureOverlayView.isSingleTap(from: origin, to: origin, hadSelection: false)
        )
        check(
            "single-tap: 3.9 pt is a tap",
            CaptureOverlayView.isSingleTap(
                from: origin,
                to: CGPoint(x: 403.9, y: 300),
                hadSelection: false
            )
        )
        check(
            "single-tap: exactly 4 pt is not a tap",
            !CaptureOverlayView.isSingleTap(
                from: origin,
                to: CGPoint(x: 404, y: 300),
                hadSelection: false
            )
        )
        check(
            "single-tap: 4.1 pt is not a tap",
            !CaptureOverlayView.isSingleTap(
                from: origin,
                to: CGPoint(x: 404.1, y: 300),
                hadSelection: false
            )
        )
        check(
            "single-tap: 50 pt is not a tap",
            !CaptureOverlayView.isSingleTap(
                from: origin,
                to: CGPoint(x: 450, y: 350),
                hadSelection: false
            )
        )
        check(
            "single-tap: a tap over an existing selection is not a window pick",
            !CaptureOverlayView.isSingleTap(from: origin, to: origin, hadSelection: true)
        )

        // MARK: Synthetic mouse events

        print("[single-tap] --- synthetic mouse events ---")
        let front = WindowCandidate(
            windowNumber: 501,
            bounds: CGRect(x: 760, y: 520, width: 460, height: 220),
            layer: 0,
            ownerPID: 900,
            ownerName: "Front",
            isOwnedBySelf: false
        )
        let back = WindowCandidate(
            windowNumber: 502,
            bounds: CGRect(x: 120, y: 480, width: 520, height: 260),
            layer: 0,
            ownerPID: 902,
            ownerName: "Back",
            isOwnedBySelf: false
        )
        let everywhere = WindowCandidate(
            windowNumber: 900,
            bounds: canvas,
            layer: 0,
            ownerPID: 903,
            ownerName: "Desktop",
            isOwnedBySelf: false
        )
        let windows = [front, back]

        func makeOverlay(showCrosshair: Bool = false) -> CaptureOverlayView {
            let overlay = CaptureOverlayView(
                frame: canvas,
                mode: .region,
                prefilledSelection: nil,
                showCrosshair: showCrosshair,
                rendersOffscreen: true
            )
            overlay.setWindowPickCandidatesForTesting(windows)
            return overlay
        }

        // 1. A first click with zero movement selects (arms) the window; a
        //    second click on that same window is what captures it.
        let tapOverlay = makeOverlay()
        var pickedIDs: [CGWindowID] = []
        var pickedFrames: [CGRect] = []
        tapOverlay.onWindowPicked = { id, frame in
            pickedIDs.append(id)
            pickedFrames.append(frame)
        }
        let tapPoint = CGPoint(x: 900, y: 600)
        tapOverlay.mouseDown(with: event(.leftMouseDown, at: tapPoint))
        tapOverlay.mouseUp(with: event(.leftMouseUp, at: tapPoint))
        check(
            "single-tap: one click selects the window but does not capture it",
            pickedIDs.isEmpty && tapOverlay.armedWindowIDForTesting == 501,
            "ids=\(pickedIDs.map(String.init).joined(separator: ",")) "
                + "armed=\(tapOverlay.armedWindowIDForTesting.map(String.init) ?? "-")"
        )
        check(
            "single-tap: the selected window is highlighted with 再次单击 and no window name",
            tapOverlay.windowHoverFramesForTesting == [front.bounds]
                && tapOverlay.windowHoverHintForTesting.contains("再次单击")
                && !tapOverlay.windowHoverHintForTesting.contains("Front"),
            "frames=\(tapOverlay.windowHoverFramesForTesting.map(format)) "
                + "hint=\(tapOverlay.windowHoverHintForTesting)"
        )
        check(
            "single-tap: the committed window exposes one selection rectangle",
            tapOverlay.committedRectForTesting == front.bounds
                && tapOverlay.selectionRectForTesting == .zero,
            "committed=\(tapOverlay.committedRectForTesting.map(format) ?? "-") "
                + "selection=\(format(tapOverlay.selectionRectForTesting))"
        )
        check(
            "single-tap: the armed window shows the normal toolbar and size chip",
            tapOverlay.isToolbarVisibleForTesting
                && tapOverlay.isIndicatorVisibleForTesting,
            "toolbar=\(tapOverlay.isToolbarVisibleForTesting) "
                + "indicator=\(tapOverlay.isIndicatorVisibleForTesting)"
        )
        check(
            "single-tap: the toolbar sits below the armed window",
            tapOverlay.toolbarFrameForTesting.maxY <= front.bounds.minY
                && tapOverlay.toolbarFrameForTesting.minY >= 0,
            "toolbar=\(format(tapOverlay.toolbarFrameForTesting)) "
                + "window=\(format(front.bounds))"
        )

        // The press itself must not blink. The old overlay dropped the hovered
        // window's punched-out highlight on mouse-down and rebuilt it on
        // mouse-up, which read as "click once, the window pops in a moment
        // later". These checks pin the replacement: the preview survives the
        // whole press, and mouse-up promotes the very same window instead of
        // re-picking.
        let pressOverlay = makeOverlay()
        pressOverlay.mouseMoved(with: event(.mouseMoved, at: tapPoint))
        check(
            "single-tap: hovering punches the window out before any click",
            pressOverlay.windowHoverFramesForTesting == [front.bounds]
                && pressOverlay.armedWindowIDForTesting == nil,
            "frames=\(pressOverlay.windowHoverFramesForTesting.map(format)) "
                + "armed=\(pressOverlay.armedWindowIDForTesting.map(String.init) ?? "-")"
        )
        pressOverlay.mouseDown(with: event(.leftMouseDown, at: tapPoint))
        check(
            "single-tap: the press keeps the hovered window punched out",
            pressOverlay.windowHoverFramesForTesting == [front.bounds],
            "frames=\(pressOverlay.windowHoverFramesForTesting.map(format))"
        )
        check(
            "single-tap: nothing is armed until the button is released",
            pressOverlay.armedWindowIDForTesting == nil
        )
        pressOverlay.mouseUp(with: event(.leftMouseUp, at: tapPoint))
        check(
            "single-tap: mouse-up promotes the preview already on screen",
            pressOverlay.armedWindowIDForTesting == 501
                && pressOverlay.armedWindowFrameForTesting == front.bounds,
            "armed=\(pressOverlay.armedWindowIDForTesting.map(String.init) ?? "-") "
                + "frame=\(pressOverlay.armedWindowFrameForTesting.map(format) ?? "-")"
        )

        // The preview is dropped the moment the press becomes a drag, so a
        // rectangle still previews normally.
        let previewDragOverlay = makeOverlay()
        previewDragOverlay.mouseMoved(with: event(.mouseMoved, at: tapPoint))
        previewDragOverlay.mouseDown(with: event(.leftMouseDown, at: tapPoint))
        previewDragOverlay.mouseDragged(
            with: event(.leftMouseDragged, at: CGPoint(x: tapPoint.x + 60, y: tapPoint.y + 40))
        )
        check(
            "single-tap: a drag drops the preview and starts a rectangle",
            previewDragOverlay.armedWindowIDForTesting == nil
                && previewDragOverlay.windowHoverFramesForTesting.isEmpty
                && previewDragOverlay.selectionRectForTesting.width > 10,
            "armed=\(previewDragOverlay.armedWindowIDForTesting.map(String.init) ?? "-") "
                + "hover=\(previewDragOverlay.windowHoverFramesForTesting.count) "
                + "box=\(format(previewDragOverlay.selectionRectForTesting))"
        )

        // The preference is on, so this proves the *armed* state hides the
        // crosshair rather than the setting being off in the fixture.
        let crosshairOverlay = makeOverlay(showCrosshair: true)
        crosshairOverlay.mouseDown(with: event(.leftMouseDown, at: tapPoint))
        crosshairOverlay.mouseUp(with: event(.leftMouseUp, at: tapPoint))
        check(
            "single-tap: arming hides the crosshair even when the preference is on",
            crosshairOverlay.armedWindowIDForTesting == 501
                && !crosshairOverlay.isCrosshairVisibleForTesting,
            "armed=\(crosshairOverlay.armedWindowIDForTesting.map(String.init) ?? "-") "
                + "crosshair=\(crosshairOverlay.isCrosshairVisibleForTesting)"
        )

        // Leaving the committed window (and its chrome) drops the arm, and the
        // crosshair comes back. Moving onto the toolbar must *not* drop it,
        // otherwise the buttons would be unreachable.
        let toolbarCentre = CGPoint(
            x: tapOverlay.toolbarFrameForTesting.midX,
            y: tapOverlay.toolbarFrameForTesting.midY
        )
        crosshairOverlay.mouseMoved(with: event(.mouseMoved, at: toolbarCentre))
        check(
            "single-tap: moving onto the armed toolbar keeps the selection",
            crosshairOverlay.armedWindowIDForTesting == 501
                && !crosshairOverlay.isCrosshairVisibleForTesting,
            "armed=\(crosshairOverlay.armedWindowIDForTesting.map(String.init) ?? "-") "
                + "point=\(format(CGRect(origin: toolbarCentre, size: .zero)))"
        )
        crosshairOverlay.mouseMoved(with: event(.mouseMoved, at: CGPoint(x: 200, y: 200)))
        check(
            "single-tap: leaving the committed window cancels it and restores the crosshair",
            crosshairOverlay.armedWindowIDForTesting == nil
                && crosshairOverlay.committedRectForTesting == nil
                && crosshairOverlay.isCrosshairVisibleForTesting
                && !crosshairOverlay.isToolbarVisibleForTesting,
            "armed=\(crosshairOverlay.armedWindowIDForTesting.map(String.init) ?? "-") "
                + "crosshair=\(crosshairOverlay.isCrosshairVisibleForTesting)"
        )
        tapOverlay.mouseDown(with: event(.leftMouseDown, at: tapPoint))
        tapOverlay.mouseUp(with: event(.leftMouseUp, at: tapPoint))
        check(
            "single-tap: a second click on the same window reports it",
            pickedIDs == [501],
            "ids=\(pickedIDs.map(String.init).joined(separator: ","))"
        )
        check(
            "single-tap: the reported frame is that window's",
            pickedFrames == [front.bounds],
            "frames=\(pickedFrames.map(format).joined(separator: " | "))"
        )
        check(
            "single-tap: confirming clears the armed state and leaves no box",
            tapOverlay.armedWindowIDForTesting == nil
                && tapOverlay.selectionRectForTesting == .zero
                && !tapOverlay.isToolbarVisibleForTesting,
            "armed=\(tapOverlay.armedWindowIDForTesting.map(String.init) ?? "-") "
                + "selection=\(format(tapOverlay.selectionRectForTesting))"
        )

        // 1b. "Click anywhere twice" must never capture: a click on a different
        //     window cancels the armed state instead of confirming it.
        let dismissOverlay = makeOverlay()
        var dismissPicks: [CGWindowID] = []
        dismissOverlay.onWindowPicked = { id, _ in dismissPicks.append(id) }
        for _ in 0..<2 {
            dismissOverlay.mouseDown(with: event(.leftMouseDown, at: tapPoint))
            dismissOverlay.mouseUp(with: event(.leftMouseUp, at: tapPoint))
        }
        check(
            "single-tap: the second tap armed 501 / 502 — setup",
            dismissPicks == [501],
            "picks=\(dismissPicks.map(String.init).joined(separator: ","))"
        )
        dismissOverlay.mouseDown(with: event(.leftMouseDown, at: tapPoint))
        dismissOverlay.mouseUp(with: event(.leftMouseUp, at: tapPoint))
        check(
            "single-tap: re-arming after a capture starts a fresh first click",
            dismissPicks == [501] && dismissOverlay.armedWindowIDForTesting == 501,
            "picks=\(dismissPicks) armed=\(dismissOverlay.armedWindowIDForTesting.map(String.init) ?? "-")"
        )
        let elsewhere = CGPoint(x: 300, y: 600)
        dismissOverlay.mouseDown(with: event(.leftMouseDown, at: elsewhere))
        dismissOverlay.mouseUp(with: event(.leftMouseUp, at: elsewhere))
        check(
            "single-tap: a click on another window cancels instead of confirming",
            dismissPicks == [501]
                && dismissOverlay.armedWindowIDForTesting == nil
                && dismissOverlay.selectionRectForTesting == .zero,
            "picks=\(dismissPicks) armed=\(dismissOverlay.armedWindowIDForTesting.map(String.init) ?? "-")"
        )
        dismissOverlay.mouseDown(with: event(.leftMouseDown, at: elsewhere))
        dismissOverlay.mouseUp(with: event(.leftMouseUp, at: elsewhere))
        check(
            "single-tap: after cancelling, a new first click selects the new window",
            dismissPicks == [501] && dismissOverlay.armedWindowIDForTesting == 502,
            "picks=\(dismissPicks) armed=\(dismissOverlay.armedWindowIDForTesting.map(String.init) ?? "-")"
        )

        // 1b2. The armed window is a committed selection: Return and every
        //      toolbar action operate on its rectangle, never on a window-ID
        //      side channel. This is the product deviation in §15.
        let returnOverlay = makeOverlay()
        var returnConfirms: [(rect: CGRect, action: CaptureToolbarAction)] = []
        var returnPicks: [CGWindowID] = []
        var returnKeeps: [CGRect] = []
        returnOverlay.onConfirm = { rect, _, action in
            returnConfirms.append((rect, action))
        }
        returnOverlay.onCopyKeeping = { rect, _ in returnKeeps.append(rect) }
        returnOverlay.onWindowPicked = { id, _ in returnPicks.append(id) }
        returnOverlay.mouseDown(with: event(.leftMouseDown, at: tapPoint))
        returnOverlay.mouseUp(with: event(.leftMouseUp, at: tapPoint))
        returnOverlay.keyDown(with: keyEvent(keyCode: 36, modifiers: []))
        check(
            "armed: Return confirms the window rectangle as copy-and-close",
            returnConfirms.count == 1
                && returnConfirms.first?.rect == front.bounds
                && returnConfirms.first?.action == .copyClosing,
            "confirms=\(returnConfirms.map { "\(format($0.rect)) \($0.action.rawValue)" })"
        )
        check(
            "armed: Return does not fall back to the window-ID capture path",
            returnPicks.isEmpty,
            "picks=\(returnPicks.map(String.init).joined(separator: ","))"
        )

        let keypadOverlay = makeOverlay()
        var keypadConfirms: [CaptureToolbarAction] = []
        keypadOverlay.onConfirm = { _, _, action in keypadConfirms.append(action) }
        keypadOverlay.mouseDown(with: event(.leftMouseDown, at: tapPoint))
        keypadOverlay.mouseUp(with: event(.leftMouseUp, at: tapPoint))
        keypadOverlay.keyDown(with: keyEvent(keyCode: 76, modifiers: []))
        check(
            "armed: keypad Enter behaves like Return",
            keypadConfirms == [.copyClosing],
            "actions=\(keypadConfirms.map(\.rawValue))"
        )

        let actionOverlay = makeOverlay()
        var actionConfirms: [(rect: CGRect, action: CaptureToolbarAction)] = []
        var actionKeeps: [CGRect] = []
        actionOverlay.onConfirm = { rect, _, action in
            actionConfirms.append((rect, action))
        }
        actionOverlay.onCopyKeeping = { rect, _ in actionKeeps.append(rect) }
        actionOverlay.mouseDown(with: event(.leftMouseDown, at: tapPoint))
        actionOverlay.mouseUp(with: event(.leftMouseUp, at: tapPoint))
        actionOverlay.performToolbarActionForTesting(.save)
        actionOverlay.performToolbarActionForTesting(.ocr)
        check(
            "armed: 保存 / OCR act on the committed window rectangle",
            actionConfirms.map(\.action) == [.save, .ocr]
                && actionConfirms.allSatisfy { $0.rect == front.bounds },
            "actions=\(actionConfirms.map { "\($0.action.rawValue) \(format($0.rect))" })"
        )
        actionOverlay.performToolbarActionForTesting(.copyKeeping)
        check(
            "armed: 拷贝 (keep) uses the window rectangle and stays armed",
            actionKeeps == [front.bounds]
                && actionOverlay.armedWindowIDForTesting == 501
                && actionOverlay.isToolbarVisibleForTesting,
            "keeps=\(actionKeeps.map(format)) "
                + "armed=\(actionOverlay.armedWindowIDForTesting.map(String.init) ?? "-")"
        )
        if let saveFrame = actionOverlay.toolbarButtonFramesForTesting()
            .first(where: { $0.action == .save })?.frame {
            let saveHit = actionOverlay.hitTest(
                CGPoint(x: saveFrame.midX, y: saveFrame.midY)
            )
            check(
                "armed: the toolbar buttons are hittable, not swallowed by the overlay",
                (saveHit as? CaptureToolbarButton)?.toolbarAction == .save,
                "hit=\(String(describing: saveHit.map { type(of: $0) }))"
            )
        } else {
            check("armed: the save button has a frame", false)
        }

        // Annotating an armed window and then confirming with the second click
        // must keep the drawing. The window-ID path has no annotation channel,
        // so that branch must fall through to the committed-rect region path.
        let annotatedOverlay = makeOverlay()
        var annotatedConfirms: [(rect: CGRect, count: Int)] = []
        var annotatedPicks: [CGWindowID] = []
        annotatedOverlay.onConfirm = { rect, annotations, _ in
            annotatedConfirms.append((rect, annotations.count))
        }
        annotatedOverlay.onWindowPicked = { id, _ in annotatedPicks.append(id) }
        annotatedOverlay.mouseDown(with: event(.leftMouseDown, at: tapPoint))
        annotatedOverlay.mouseUp(with: event(.leftMouseUp, at: tapPoint))
        annotatedOverlay.addAnnotationForTesting(
            Annotation(
                tool: .arrow,
                points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.9)],
                color: AnnotationTool.arrow.defaultColor,
                lineWidth: 4
            )
        )
        annotatedOverlay.mouseDown(with: event(.leftMouseDown, at: tapPoint))
        annotatedOverlay.mouseUp(with: event(.leftMouseUp, at: tapPoint))
        check(
            "armed: a second click on an annotated window keeps the drawing",
            annotatedConfirms.count == 1
                && annotatedConfirms.first?.rect == front.bounds
                && annotatedConfirms.first?.count == 1
                && annotatedPicks.isEmpty,
            "confirms=\(annotatedConfirms.map { "\(format($0.rect)) n=\($0.count)" }) "
                + "picks=\(annotatedPicks.map(String.init))"
        )

        // 1b3. A window touching the bottom edge flips the toolbar above it.
        let bottomWindow = WindowCandidate(
            windowNumber: 601,
            bounds: CGRect(x: 700, y: 24, width: 420, height: 220),
            layer: 0,
            ownerPID: 901,
            ownerName: "Bottom",
            isOwnedBySelf: false
        )
        let bottomOverlay = CaptureOverlayView(
            frame: canvas,
            mode: .region,
            prefilledSelection: nil,
            showCrosshair: true,
            rendersOffscreen: true
        )
        bottomOverlay.setWindowPickCandidatesForTesting([bottomWindow])
        bottomOverlay.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 900, y: 120)))
        bottomOverlay.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 900, y: 120)))
        check(
            "armed: a bottom window flips the toolbar above itself",
            bottomOverlay.armedWindowIDForTesting == 601
                && bottomOverlay.toolbarFrameForTesting.minY >= bottomWindow.bounds.maxY
                && bottomOverlay.toolbarFrameForTesting.maxY <= canvas.maxY,
            "toolbar=\(format(bottomOverlay.toolbarFrameForTesting)) "
                + "window=\(format(bottomWindow.bounds))"
        )

        let armDragOverlay = makeOverlay()
        var armDragPicks: [CGWindowID] = []
        armDragOverlay.onWindowPicked = { id, _ in armDragPicks.append(id) }
        armDragOverlay.mouseDown(with: event(.leftMouseDown, at: tapPoint))
        armDragOverlay.mouseUp(with: event(.leftMouseUp, at: tapPoint))
        armDragOverlay.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 600, y: 300)))
        armDragOverlay.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 700, y: 400)))
        armDragOverlay.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 700, y: 400)))
        check(
            "single-tap: a drag after arming draws a region and captures nothing",
            armDragPicks.isEmpty
                && armDragOverlay.armedWindowIDForTesting == nil
                && armDragOverlay.selectionRectForTesting
                    == CGRect(x: 600, y: 300, width: 100, height: 100),
            "picks=\(armDragPicks) selection=\(format(armDragOverlay.selectionRectForTesting))"
        )

        // 1d. Esc dismisses the armed window without closing the overlay.
        let escArmOverlay = makeOverlay()
        var escArmCancels = 0
        escArmOverlay.onCancel = { escArmCancels += 1 }
        escArmOverlay.mouseDown(with: event(.leftMouseDown, at: tapPoint))
        escArmOverlay.mouseUp(with: event(.leftMouseUp, at: tapPoint))
        escArmOverlay.keyDown(with: keyEvent(keyCode: 53, modifiers: []))
        check(
            "single-tap: Esc clears the armed window and keeps the overlay open",
            escArmOverlay.armedWindowIDForTesting == nil && escArmCancels == 0,
            "armed=\(escArmOverlay.armedWindowIDForTesting.map(String.init) ?? "-") "
                + "cancels=\(escArmCancels)"
        )
        escArmOverlay.keyDown(with: keyEvent(keyCode: 53, modifiers: []))
        check("single-tap: a second Esc closes the overlay", escArmCancels == 1)

        // 2. A real drag: no window pick, normal region selection.
        let dragOverlay = makeOverlay()
        var dragPicks = 0
        dragOverlay.onWindowPicked = { _, _ in dragPicks += 1 }
        dragOverlay.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 400, y: 300)))
        dragOverlay.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 450, y: 350)))
        dragOverlay.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 450, y: 350)))
        check(
            "single-tap: a 50 pt drag never picks a window",
            dragPicks == 0,
            "picks=\(dragPicks)"
        )
        check(
            "single-tap: the drag still creates the region",
            dragOverlay.selectionRectForTesting == CGRect(x: 400, y: 300, width: 50, height: 50),
            "selection=\(format(dragOverlay.selectionRectForTesting))"
        )
        check(
            "single-tap: the drag keeps the toolbar visible",
            dragOverlay.isToolbarVisibleForTesting
        )

        // 3. Empty desktop: no pick, no selection, overlay stays open.
        let emptyOverlay = makeOverlay()
        var emptyPicks = 0
        var cancels = 0
        emptyOverlay.onWindowPicked = { _, _ in emptyPicks += 1 }
        emptyOverlay.onCancel = { cancels += 1 }
        emptyOverlay.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 1400, y: 100)))
        emptyOverlay.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 1400, y: 100)))
        check(
            "single-tap: empty desktop reports no capture",
            emptyPicks == 0 && cancels == 0,
            "picks=\(emptyPicks) cancels=\(cancels)"
        )
        check(
            "single-tap: empty desktop leaves the overlay state untouched",
            emptyOverlay.selectionRectForTesting == .zero
                && !emptyOverlay.isToolbarVisibleForTesting,
            "selection=\(format(emptyOverlay.selectionRectForTesting))"
        )

        // 4. 3.9 pt is still a tap and clears the border's minimum-size box.
        let wobbleOverlay = makeOverlay()
        wobbleOverlay.setWindowPickCandidatesForTesting([everywhere])
        var wobblePicks: [CGWindowID] = []
        wobbleOverlay.onWindowPicked = { id, _ in wobblePicks.append(id) }
        for _ in 0..<2 {
            wobbleOverlay.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 300, y: 300)))
            wobbleOverlay.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 303.9, y: 300)))
            wobbleOverlay.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 303.9, y: 300)))
        }
        check(
            "single-tap: a 3.9 pt wobble is still a tap (two taps confirm)",
            wobblePicks == [900],
            "ids=\(wobblePicks.map(String.init).joined(separator: ","))"
        )
        check(
            "single-tap: the wobble leaves no 40×40 box behind",
            wobbleOverlay.selectionRectForTesting == .zero,
            "selection=\(format(wobbleOverlay.selectionRectForTesting))"
        )

        // 5. 4.1 pt is a drag, not a tap.
        let beyondOverlay = makeOverlay()
        var beyondPicks = 0
        beyondOverlay.onWindowPicked = { _, _ in beyondPicks += 1 }
        beyondOverlay.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 300, y: 300)))
        beyondOverlay.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 304.1, y: 300)))
        beyondOverlay.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 304.1, y: 300)))
        check(
            "single-tap: 4.1 pt is a drag and does not pick",
            beyondPicks == 0,
            "picks=\(beyondPicks)"
        )
        check(
            "single-tap: 4.1 pt creates the border's 40 pt minimum box",
            beyondOverlay.selectionRectForTesting.width == 40
                && beyondOverlay.selectionRectForTesting.height == 40,
            "selection=\(format(beyondOverlay.selectionRectForTesting))"
        )

        // 6. A click outside an existing selection **cancels that selection**.
        //
        //    The owner asked for this explicitly: 「我再点选择区域外的阴影区域时
        //    应该是默认取消」. A window is under the pointer, but the click's
        //    meaning in that moment is "dismiss my box", not "capture that
        //    window" — arming it made a cancel look like a selection.
        //
        //    Once the box is gone, the very same click is a window pick again:
        //    cancelling must not disable single-click window capture.
        let existingOverlay = makeOverlay()
        existingOverlay.applySelectionForTesting(CGRect(x: 500, y: 400, width: 200, height: 150))
        var existingPicks: [CGWindowID] = []
        existingOverlay.onWindowPicked = { id, _ in existingPicks.append(id) }
        existingOverlay.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 200, y: 500)))
        existingOverlay.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 200, y: 500)))
        check(
            "single-tap: a click outside an existing selection cancels it",
            existingPicks.isEmpty
                && existingOverlay.armedWindowIDForTesting == nil
                && existingOverlay.selectionRectForTesting == .zero,
            "picks=\(existingPicks.map(String.init).joined(separator: ",")) "
                + "armed=\(existingOverlay.armedWindowIDForTesting.map(String.init) ?? "-") "
                + "selection=\(format(existingOverlay.selectionRectForTesting))"
        )
        check(
            "single-tap: cancelling thaws the crosshair instead of pinning the window",
            !existingOverlay.isCrosshairFrozenForTesting
                && existingOverlay.crosshairArmsForTesting.count == 4,
            "frozen=\(existingOverlay.isCrosshairFrozenForTesting) "
                + "arms=\(existingOverlay.crosshairArmsForTesting.count)"
        )
        existingOverlay.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 200, y: 500)))
        existingOverlay.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 200, y: 500)))
        check(
            "single-tap: with no box, that click selects the window again",
            existingPicks.isEmpty && existingOverlay.armedWindowIDForTesting == 502,
            "picks=\(existingPicks.map(String.init).joined(separator: ",")) "
                + "armed=\(existingOverlay.armedWindowIDForTesting.map(String.init) ?? "-")"
        )
        existingOverlay.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 200, y: 500)))
        existingOverlay.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 200, y: 500)))
        check(
            "single-tap: the second click on it shoots the window",
            existingPicks == [502],
            "picks=\(existingPicks.map(String.init).joined(separator: ","))"
        )
        check(
            "single-tap: that shot clears the old box first",
            existingOverlay.selectionRectForTesting == .zero,
            "selection=\(format(existingOverlay.selectionRectForTesting))"
        )
        // A short drag outside it still starts a new box (border semantics).
        existingOverlay.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 100, y: 100)))
        existingOverlay.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 106, y: 100)))
        existingOverlay.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 106, y: 100)))
        check(
            "single-tap: a drag outside an existing selection starts a new minimum box",
            existingOverlay.selectionRectForTesting.width == 40
                && existingOverlay.selectionRectForTesting.height == 40,
            "selection=\(format(existingOverlay.selectionRectForTesting))"
        )
        check(
            "single-tap: that drag is still not a window shot",
            existingPicks == [502],
            "picks=\(existingPicks.map(String.init).joined(separator: ","))"
        )

        // MARK: Real controller: the tap closes the panels

        print("[single-tap] --- controller lifecycle (real panels) ---")
        let tapController = CaptureOverlayController(
            mode: .region,
            prefilledSelection: nil,
            showCrosshair: false
        )
        var controllerPicks: [CGWindowID] = []
        tapController.onWindowPicked = { id, _ in controllerPicks.append(id) }
        if let screen = NSScreen.main {
            tapController.presentPanelsForTesting(on: screen)
        }
        check(
            "single-tap: the controller ordered its real panels in",
            tapController.hasPanelsForTesting,
            "presenting=\(tapController.isPresenting)"
        )
        if let view = tapController.overlayViewsForTesting.first {
            view.setWindowPickCandidatesForTesting(windows)
            view.mouseDown(with: event(.leftMouseDown, at: tapPoint))
            view.mouseUp(with: event(.leftMouseUp, at: tapPoint))
            check(
                "single-tap: the first click does not close the controller",
                controllerPicks.isEmpty && tapController.isPresenting,
                "picks=\(controllerPicks) presenting=\(tapController.isPresenting)"
            )
            view.mouseDown(with: event(.leftMouseDown, at: tapPoint))
            view.mouseUp(with: event(.leftMouseUp, at: tapPoint))
            check(
                "single-tap: the pick reports the window to the controller",
                controllerPicks == [501],
                "ids=\(controllerPicks.map(String.init).joined(separator: ","))"
            )
            check(
                "single-tap: the controller closes every panel",
                !tapController.hasPanelsForTesting && !tapController.isPresenting,
                "panels=\(tapController.hasPanelsForTesting) presenting=\(tapController.isPresenting)"
            )
        } else {
            check("single-tap: the controller exposes its view", false)
        }
        tapController.close()

        // Empty desktop through the real controller: still presenting.
        let emptyController = CaptureOverlayController(
            mode: .region,
            prefilledSelection: nil,
            showCrosshair: false
        )
        if let screen = NSScreen.main {
            emptyController.presentPanelsForTesting(on: screen)
        }
        if let view = emptyController.overlayViewsForTesting.first {
            view.setWindowPickCandidatesForTesting([])
            view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 1400, y: 100)))
            view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 1400, y: 100)))
            check(
                "single-tap: empty desktop keeps the overlay visible",
                emptyController.isPresenting && emptyController.hasPanelsForTesting,
                "presenting=\(emptyController.isPresenting) panels=\(emptyController.hasPanelsForTesting)"
            )
            check(
                "single-tap: empty desktop leaves the view without a selection",
                view.selectionRectForTesting == .zero,
                "selection=\(format(view.selectionRectForTesting))"
            )
        } else {
            check("single-tap: the controller exposes its view", false)
        }
        emptyController.close()

        // MARK: iShot-style hover, magnet, nudge, toolbar toggle

        print("[ishot] --- hover highlight ---")
        let hoverOverlay = makeOverlay()
        hoverOverlay.mouseMoved(with: event(.mouseMoved, at: tapPoint))
        check(
            "ishot hover: the window under the pointer is highlighted",
            hoverOverlay.hoveredWindowIDForTesting == 501
                && hoverOverlay.windowHoverFramesForTesting == [front.bounds],
            "id=\(hoverOverlay.hoveredWindowIDForTesting.map(String.init) ?? "-")"
        )
        check(
            "ishot hover: the veil is punched out at the window",
            hoverOverlay.dimmingSelectionRectForTesting == front.bounds,
            "hole=\(format(hoverOverlay.dimmingSelectionRectForTesting))"
        )
        check(
            "ishot hover: the hint shows the size, never the window/app name",
            !hoverOverlay.windowHoverHintForTesting.contains("Front")
                && !hoverOverlay.windowHoverHintForTesting.contains("Back")
                && hoverOverlay.windowHoverHintForTesting.contains("460×220")
                && hoverOverlay.windowHoverHintForTesting.contains("单击"),
            "hint=\(hoverOverlay.windowHoverHintForTesting)"
        )
        check(
            "ishot hover: the highlight view is visible and the toolbar is not",
            hoverOverlay.isWindowHighlightVisibleForTesting
                && !hoverOverlay.isToolbarVisibleForTesting
        )

        hoverOverlay.mouseMoved(with: event(.mouseMoved, at: CGPoint(x: 1400, y: 100)))
        check(
            "ishot hover: moving to empty desktop clears the highlight",
            hoverOverlay.hoveredWindowIDForTesting == nil
                && !hoverOverlay.isWindowHighlightVisibleForTesting
                && hoverOverlay.windowHoverHintForTesting.isEmpty
        )

        hoverOverlay.applySelectionForTesting(CGRect(x: 100, y: 100, width: 200, height: 150))
        hoverOverlay.mouseMoved(with: event(.mouseMoved, at: tapPoint))
        check(
            "ishot hover: no highlight once a selection exists",
            hoverOverlay.hoveredWindowIDForTesting == nil,
            "id=\(hoverOverlay.hoveredWindowIDForTesting.map(String.init) ?? "-")"
        )

        // Clicking a hovered window follows the same two-step rule: the first
        // click selects it, the second captures it. The hint never blocks the
        // click path.
        let hoverClickOverlay = makeOverlay()
        var hoverClickIDs: [CGWindowID] = []
        hoverClickOverlay.onWindowPicked = { id, _ in hoverClickIDs.append(id) }
        hoverClickOverlay.mouseMoved(with: event(.mouseMoved, at: tapPoint))
        hoverClickOverlay.mouseDown(with: event(.leftMouseDown, at: tapPoint))
        hoverClickOverlay.mouseUp(with: event(.leftMouseUp, at: tapPoint))
        check(
            "ishot hover: one click selects the hovered window",
            hoverClickIDs.isEmpty && hoverClickOverlay.armedWindowIDForTesting == 501,
            "ids=\(hoverClickIDs.map(String.init).joined(separator: ","))"
        )
        hoverClickOverlay.mouseDown(with: event(.leftMouseDown, at: tapPoint))
        hoverClickOverlay.mouseUp(with: event(.leftMouseUp, at: tapPoint))
        check(
            "ishot hover: the second click captures the hovered window",
            hoverClickIDs == [501],
            "ids=\(hoverClickIDs.map(String.init).joined(separator: ","))"
        )

        // Offscreen proof of the hover state: bright window hole, blue outline,
        // hint capsule near the pointer. The render is the visual half; the
        // assertions above are the behavioural half.
        let hoverCanvas = TestCanvasView(frame: canvas)
        let hoverRenderOverlay = CaptureOverlayView(
            frame: hoverCanvas.bounds,
            mode: .region,
            prefilledSelection: nil,
            showCrosshair: false,
            rendersOffscreen: true
        )
        hoverCanvas.addSubview(hoverRenderOverlay)
        hoverRenderOverlay.setWindowPickCandidatesForTesting(windows)
        let hoverRenderPoint = CGPoint(x: 380, y: 610)
        hoverRenderOverlay.mouseMoved(with: event(.mouseMoved, at: hoverRenderPoint))
        check(
            "10-window-hover: the back window is highlighted under the pointer",
            hoverRenderOverlay.hoveredWindowIDForTesting == 502,
            "id=\(hoverRenderOverlay.hoveredWindowIDForTesting.map(String.init) ?? "-")"
        )
        if let representation = hoverCanvas.bitmapImageRepForCachingDisplay(
            in: hoverCanvas.bounds
        ) {
            hoverCanvas.cacheDisplay(in: hoverCanvas.bounds, to: representation)
            if let png = representation.representation(using: .png, properties: [:]) {
                let url = directory.appendingPathComponent("10-window-hover.png")
                do {
                    try png.write(to: url)
                    print(
                        "[ishot] wrote \(url.path) "
                        + "(\(representation.pixelsWide)×\(representation.pixelsHigh) px)"
                    )
                    copyToVerification(png, named: "overlay-10-window-hover.png")
                    if let hoverImage = representation.cgImage {
                        let scale = CGFloat(hoverImage.width) / hoverCanvas.bounds.width
                        let probe = CGPoint(
                            x: back.bounds.minX + back.bounds.width * 0.3,
                            y: back.bounds.maxY
                        )
                        let sample = pixel(
                            hoverImage,
                            x: Int((probe.x * scale).rounded()),
                            y: Int(((hoverCanvas.bounds.height - probe.y) * scale).rounded())
                        )
                        check(
                            "10-window-hover: the outline is the neutral selection border, not accent blue",
                            sample.map { $0.r >= 235 && $0.g >= 235 && $0.b >= 235 } == true,
                            "pixel=\(String(describing: sample))"
                        )
                    }
                } catch {
                    check("10-window-hover: write PNG", false, error.localizedDescription)
                }
            } else {
                check("10-window-hover: encode PNG", false)
            }
        } else {
            check("10-window-hover: render bitmap", false)
        }

        print("[ishot] --- magnet ---")
        let magnet = CGRect(x: 100, y: 100, width: 300, height: 200)
        check(
            "ishot snap: a point 3 pt from the left/bottom edge snaps to it",
            SelectionSnapping.snap(CGPoint(x: 103, y: 297), targets: [magnet])
                == CGPoint(x: 100, y: 300)
        )
        check(
            "ishot snap: a point 10 pt away is left untouched",
            SelectionSnapping.snap(CGPoint(x: 110, y: 150), targets: [magnet])
                == CGPoint(x: 110, y: 150)
        )
        check(
            "ishot snap: the mid-edge is a magnet too",
            SelectionSnapping.snap(CGPoint(x: 248, y: 150), targets: [magnet])
                == CGPoint(x: 250, y: 150)
        )
        check(
            "ishot snap: 6.1 pt is outside the threshold",
            SelectionSnapping.snap(CGPoint(x: 106.1, y: 150), targets: [magnet])
                == CGPoint(x: 106.1, y: 150)
        )

        let dragSnapOverlay = makeOverlay()
        dragSnapOverlay.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 200, y: 200)))
        dragSnapOverlay.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 762, y: 600)))
        dragSnapOverlay.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 762, y: 600)))
        check(
            "ishot snap: a drag near a window edge lands exactly on it",
            dragSnapOverlay.selectionRectForTesting.maxX == 760,
            "selection=\(format(dragSnapOverlay.selectionRectForTesting))"
        )

        print("[ishot] --- keyboard ---")
        let nudgeOverlay = makeOverlay()
        nudgeOverlay.applySelectionForTesting(CGRect(x: 100, y: 100, width: 200, height: 150))
        nudgeOverlay.keyDown(with: keyEvent(keyCode: 123, modifiers: []))
        check(
            "ishot nudge: left arrow moves one point",
            nudgeOverlay.selectionRectForTesting.minX == 99,
            "selection=\(format(nudgeOverlay.selectionRectForTesting))"
        )
        nudgeOverlay.keyDown(with: keyEvent(keyCode: 124, modifiers: [.shift]))
        check(
            "ishot nudge: Shift-right moves ten points",
            nudgeOverlay.selectionRectForTesting.minX == 109,
            "selection=\(format(nudgeOverlay.selectionRectForTesting))"
        )
        nudgeOverlay.keyDown(with: keyEvent(keyCode: 125, modifiers: []))
        check(
            "ishot nudge: down arrow moves one point",
            nudgeOverlay.selectionRectForTesting.minY == 99,
            "selection=\(format(nudgeOverlay.selectionRectForTesting))"
        )

        check(
            "ishot toolbar: the production reveal delay is iShot's 0.5 s",
            CaptureOverlayView.toolbarRevealDelay == 0.5
        )

        let toolbarToggle = makeOverlay()
        toolbarToggle.applySelectionForTesting(CGRect(x: 300, y: 300, width: 200, height: 150))
        check(
            "ishot toolbar: visible after a selection",
            toolbarToggle.isToolbarVisibleForTesting
        )
        toolbarToggle.flagsChanged(with: flagsEvent([.control]))
        check(
            "ishot toolbar: tapping Control hides it",
            toolbarToggle.isToolbarSuppressedForTesting
                && !toolbarToggle.isToolbarVisibleForTesting
        )
        toolbarToggle.flagsChanged(with: flagsEvent([]))
        toolbarToggle.flagsChanged(with: flagsEvent([.control]))
        check(
            "ishot toolbar: a second tap shows it again",
            !toolbarToggle.isToolbarSuppressedForTesting
                && toolbarToggle.isToolbarVisibleForTesting
        )

        print("[ishot] --- shift multi-window / F / ratios / scroll ---")
        let multi = makeOverlay()
        var toggles: [(CGWindowID, Bool)] = []
        var confirmedSets: [[(CGWindowID, CGRect)]] = []
        var multiCancels = 0
        multi.onWindowToggled = { id, _, selected in toggles.append((id, selected)) }
        multi.onWindowsConfirmed = { confirmedSets.append($0) }
        multi.onCancel = { multiCancels += 1 }

        func shiftClick(_ overlay: CaptureOverlayView, _ point: CGPoint) {
            overlay.mouseMoved(with: event(.mouseMoved, at: point))
            overlay.mouseDown(with: event(.leftMouseDown, at: point, modifiers: [.shift]))
            overlay.mouseUp(with: event(.leftMouseUp, at: point, modifiers: [.shift]))
        }

        shiftClick(multi, CGPoint(x: 900, y: 600))
        shiftClick(multi, CGPoint(x: 300, y: 600))
        check(
            "ishot multi: Shift-click adds two windows",
            multi.selectedWindowIDsForTesting == [501, 502]
                && toggles.count == 2,
            "ids=\(multi.selectedWindowIDsForTesting) toggles=\(toggles.count)"
        )
        check(
            "ishot multi: the set is highlighted with a count hint",
            multi.windowHoverFramesForTesting.count == 2
                && multi.windowHoverHintForTesting.contains("已选 2 个窗口"),
            "hint=\(multi.windowHoverHintForTesting)"
        )
        check(
            "ishot multi: the overlay is still open (no capture yet)",
            confirmedSets.isEmpty && multi.selectionRectForTesting == .zero,
            "confirmed=\(confirmedSets.count)"
        )
        multi.keyDown(with: keyEvent(keyCode: 36, modifiers: []))
        check(
            "ishot multi: Return composites both windows",
            confirmedSets.count == 1
                && confirmedSets.first?.map(\.0) == [501, 502],
            "sets=\(confirmedSets.count) ids=\(confirmedSets.first?.map(\.0) ?? [])"
        )

        // Esc clears the set first, then cancels on the second press.
        let escMulti = makeOverlay()
        var escMultiCancels = 0
        escMulti.onCancel = { escMultiCancels += 1 }
        shiftClick(escMulti, CGPoint(x: 900, y: 600))
        escMulti.keyDown(with: keyEvent(keyCode: 53, modifiers: []))
        check(
            "ishot multi: first Esc clears the set without closing",
            escMulti.selectedWindowIDsForTesting.isEmpty && escMultiCancels == 0,
            "ids=\(escMulti.selectedWindowIDsForTesting) cancels=\(escMultiCancels)"
        )
        escMulti.keyDown(with: keyEvent(keyCode: 53, modifiers: []))
        check("ishot multi: second Esc closes the overlay", escMultiCancels == 1)
        _ = multiCancels

        // A plain click clears the set and captures that window.
        let plainOverlay = makeOverlay()
        var plainPicks: [CGWindowID] = []
        plainOverlay.onWindowPicked = { id, _ in plainPicks.append(id) }
        shiftClick(plainOverlay, CGPoint(x: 900, y: 600))
        plainOverlay.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 900, y: 600)))
        plainOverlay.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 900, y: 600)))
        check(
            "ishot multi: a plain click clears the set and selects one window",
            plainOverlay.selectedWindowIDsForTesting.isEmpty
                && plainOverlay.armedWindowIDForTesting == 501,
            "ids=\(plainOverlay.selectedWindowIDsForTesting) "
                + "armed=\(plainOverlay.armedWindowIDForTesting.map(String.init) ?? "-")"
        )
        plainOverlay.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 900, y: 600)))
        plainOverlay.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 900, y: 600)))
        check(
            "ishot multi: the second plain click captures that window",
            plainOverlay.selectedWindowIDsForTesting.isEmpty && plainPicks == [501],
            "ids=\(plainOverlay.selectedWindowIDsForTesting) picks=\(plainPicks)"
        )

        // F = select the full screen.
        let fullOverlay = makeOverlay()
        fullOverlay.keyDown(with: keyEvent(keyCode: 3, modifiers: []))
        check(
            "ishot F: F selects the whole screen",
            fullOverlay.selectionRectForTesting == canvas,
            "selection=\(format(fullOverlay.selectionRectForTesting))"
        )
        check(
            "ishot F: the toolbar appears for the full-screen box",
            fullOverlay.isToolbarVisibleForTesting
        )

        // Number keys lock width:height (0 = free).
        let aspectOverlay = makeOverlay()
        aspectOverlay.applySelectionForTesting(CGRect(x: 100, y: 100, width: 200, height: 150))
        aspectOverlay.keyDown(with: digitEvent(1))
        check(
            "ishot ratio: 1 locks 1:1 and resizes the selection",
            aspectOverlay.lockedAspectForTesting == 1
                && abs(aspectOverlay.selectionRectForTesting.width
                    - aspectOverlay.selectionRectForTesting.height) < 0.5,
            "selection=\(format(aspectOverlay.selectionRectForTesting))"
        )
        aspectOverlay.keyDown(with: digitEvent(0))
        check(
            "ishot ratio: 0 unlocks",
            aspectOverlay.lockedAspectForTesting == nil
        )

        let dragAspect = makeOverlay()
        dragAspect.keyDown(with: digitEvent(7))
        dragAspect.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 200, y: 200)))
        dragAspect.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 400, y: 250)))
        dragAspect.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 400, y: 250)))
        let ratioRect = dragAspect.selectionRectForTesting
        check(
            "ishot ratio: a drag under 16:9 keeps the ratio",
            abs(ratioRect.width / max(1, ratioRect.height) - 16.0 / 9.0) < 0.02,
            "selection=\(format(ratioRect)) ratio=\(ratioRect.width / max(1, ratioRect.height))"
        )

        // Scroll wheel adjusts the highlighter opacity for new strokes.
        let highlightOverlay = makeOverlay()
        highlightOverlay.selectToolForTesting(.highlighter)
        highlightOverlay.applySelectionForTesting(CGRect(x: 300, y: 300, width: 300, height: 200))
        highlightOverlay.scrollWheel(with: scrollEvent(deltaY: -10))
        let opacity = highlightOverlay.highlighterOpacityForTesting
        check(
            "ishot scroll: the wheel lowers highlighter opacity",
            opacity < 1 && opacity >= 0.15,
            "opacity=\(opacity)"
        )
        highlightOverlay.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 350, y: 350)))
        highlightOverlay.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 450, y: 350)))
        highlightOverlay.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 450, y: 350)))
        check(
            "ishot scroll: the next highlighter stroke uses that opacity",
            abs((highlightOverlay.lastAnnotationColorForTesting?.alphaComponent ?? -1)
                - opacity) < 0.01,
            "alpha=\(highlightOverlay.lastAnnotationColorForTesting?.alphaComponent ?? -1) "
                + "opacity=\(opacity)"
        )

        print("[ishot] --- system overlay filter ---")
        let systemOverlay = WindowCandidate(
            windowNumber: 9_001,
            bounds: canvas,
            layer: 0,
            ownerPID: 1,
            ownerName: "Window Server",
            isOwnedBySelf: false
        )
        let cursorMirror = WindowCandidate(
            windowNumber: 9_002,
            bounds: canvas,
            layer: 0,
            ownerPID: 1,
            ownerName: "Window Server",
            windowName: "Cursor",
            isOwnedBySelf: false
        )
        check(
            "ishot filter: the Window Server cursor mirror is skipped by name",
            WindowPicker.window(
                under: tapPoint,
                candidates: [cursorMirror, front],
                ownPID: 0
            )?.windowNumber == 501
        )
        check(
            "ishot filter: a plain Window Server window is not silently skipped",
            WindowPicker.window(
                under: tapPoint,
                candidates: [systemOverlay, front],
                ownPID: 0
            )?.windowNumber == 9_001,
            "got=\(WindowPicker.window(under: tapPoint, candidates: [systemOverlay, front], ownPID: 0)?.windowNumber ?? -1)"
        )
        check(
            "ishot filter: HazeOver / TencentMeeting helpers are skipped",
            WindowPicker.isSystemOverlay(ownerName: "HazeOver")
                && WindowPicker.isSystemOverlay(ownerName: "TencentMeeting")
                && WindowPicker.isSystemOverlay(ownerName: "Cursor")
                && !WindowPicker.isSystemOverlay(ownerName: "Safari")
        )

        print("[ishot] --- window cue ---")
        if let screen = NSScreen.main {
            let cue = InstantCaptureCueController()
            cue.show(at: tapPoint, on: screen, windowFrame: front.bounds)
            if let cueWindow = cue.window {
                check(
                    "ishot cue: a window shot gets a window-shaped outline",
                    abs(cueWindow.frame.width - (front.bounds.width + 6)) < 1
                        && abs(cueWindow.frame.height - (front.bounds.height + 6)) < 1,
                    "frame=\(NSStringFromRect(cueWindow.frame))"
                )
                check(
                    "ishot cue: the window outline is click-through",
                    cueWindow.ignoresMouseEvents && !cueWindow.canBecomeKey
                )
            } else {
                check("ishot cue: a window outline window is created", false)
            }
            cue.close()
        }

        // MARK: CaptureMode.window = instant path

        print("[mode] --- three modes and the zero-UI window entry ---")
        let suiteName = "UnseenWindowMode-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            check("mode: create isolated defaults", false)
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.instantCaptureSound = false
        settings.instantCaptureVisualCue = false
        settings.instantCaptureAlsoSave = false

        check(
            "mode: CaptureMode has exactly 3 modes",
            CaptureMode.allCases.count == 3,
            "count=\(CaptureMode.allCases.count)"
        )
        check(
            "mode: the modes are region / window / full screen",
            CaptureMode.allCases.map(\.rawValue) == ["region", "window", "fullScreen"],
            "modes=\(CaptureMode.allCases.map(\.rawValue).joined(separator: " | "))"
        )
        check(
            "mode: .window is 窗口截图 with the confirmation-overlay copy",
            CaptureMode.window.title == "窗口截图"
                && CaptureMode.window.symbol == "macwindow.on.rectangle"
                && CaptureMode.window.detail.contains("单击即截图")
                && CaptureMode.window.shortDetail == "截图光标下的窗口",
            "title=\(CaptureMode.window.title) detail=\(CaptureMode.window.detail)"
        )
        check(
            "mode: .fullScreen still captures directly (same interaction model)",
            CaptureMode.fullScreen.detail.contains("不显示覆盖层")
        )

        // Routing is pure, so this never starts a ScreenCaptureKit capture.
        // Two window entries share one picker but not one surface: `窗口截图`
        // opens the confirmation overlay, `⌃⌥⌘W` stays zero-UI.
        check(
            "mode: .window routes to the window confirmation overlay",
            CaptureCoordinator.entry(for: .window) == .windowOverlay,
            "entry=\(CaptureCoordinator.entry(for: .window))"
        )
        check(
            "mode: .window is not the region drag surface",
            CaptureCoordinator.entry(for: .window) != .regionOverlay
        )
        check(
            "instant: ⌃⌥⌘W stays on the zero-UI window capture",
            CaptureCoordinator.entry(for: .region) == .regionOverlay
                && InstantCaptureKind.window.title == "即时窗口"
        )
        check(
            "mode: .region routes to the region overlay",
            CaptureCoordinator.entry(for: .region) == .regionOverlay,
            "entry=\(CaptureCoordinator.entry(for: .region))"
        )
        check(
            "mode: .fullScreen routes to a direct screen shot (same model as .window)",
            CaptureCoordinator.entry(for: .fullScreen) == .directScreen,
            "entry=\(CaptureCoordinator.entry(for: .fullScreen))"
        )
        // `.window` confirmation behaviour: hover, click, no rectangle drag.
        let confirmOverlay = CaptureOverlayView(
            frame: canvas,
            mode: .region,
            prefilledSelection: nil,
            showCrosshair: false,
            rendersOffscreen: true,
            startsInWindowPick: true
        )
        confirmOverlay.setWindowPickCandidatesForTesting(windows)
        var confirmPicks: [CGWindowID] = []
        confirmOverlay.onWindowPicked = { id, _ in confirmPicks.append(id) }
        check(
            "window confirm: the overlay starts in window-only mode",
            confirmOverlay.isWindowConfirmationModeForTesting
        )
        confirmOverlay.mouseMoved(with: event(.mouseMoved, at: tapPoint))
        check(
            "window confirm: hovering highlights the window and says 单击确认, no name",
            confirmOverlay.hoveredWindowIDForTesting == 501
                && confirmOverlay.windowHoverHintForTesting.contains("单击确认")
                && !confirmOverlay.windowHoverHintForTesting.contains("Front"),
            "hint=\(confirmOverlay.windowHoverHintForTesting)"
        )

        confirmOverlay.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 200, y: 200)))
        confirmOverlay.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 400, y: 300)))
        confirmOverlay.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 400, y: 300)))
        check(
            "window confirm: dragging never creates a region or captures",
            confirmPicks.isEmpty && confirmOverlay.selectionRectForTesting == .zero,
            "picks=\(confirmPicks) selection=\(format(confirmOverlay.selectionRectForTesting))"
        )

        confirmOverlay.mouseDown(with: event(.leftMouseDown, at: tapPoint))
        confirmOverlay.mouseUp(with: event(.leftMouseUp, at: tapPoint))
        check(
            "window confirm: one click confirms the hovered window",
            confirmPicks == [501],
            "ids=\(confirmPicks.map(String.init).joined(separator: ","))"
        )

        confirmOverlay.mouseMoved(with: event(.mouseMoved, at: CGPoint(x: 1400, y: 100)))
        confirmOverlay.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 1400, y: 100)))
        confirmOverlay.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 1400, y: 100)))
        check(
            "window confirm: empty desktop does not capture",
            confirmPicks == [501],
            "ids=\(confirmPicks.map(String.init).joined(separator: ","))"
        )

        // Offscreen proof of the confirmation surface itself: the hovered window
        // is punched out of the veil, outlined, and captioned with its size —
        // never with the window's title or owner name. This is what `窗口截图`
        // now opens (and what `⌃⌥⌘W` skips).
        let confirmCanvas = TestCanvasView(frame: canvas)
        let confirmRender = CaptureOverlayView(
            frame: confirmCanvas.bounds,
            mode: .region,
            prefilledSelection: nil,
            showCrosshair: false,
            rendersOffscreen: true,
            startsInWindowPick: true
        )
        confirmCanvas.addSubview(confirmRender)
        confirmRender.setWindowPickCandidatesForTesting(windows)
        confirmRender.mouseMoved(with: event(.mouseMoved, at: tapPoint))
        check(
            "window confirm: the render highlights the hovered window",
            confirmRender.hoveredWindowIDForTesting == 501,
            "id=\(confirmRender.hoveredWindowIDForTesting.map(String.init) ?? "-")"
        )
        if let representation = confirmCanvas.bitmapImageRepForCachingDisplay(
            in: confirmCanvas.bounds
        ) {
            confirmCanvas.cacheDisplay(in: confirmCanvas.bounds, to: representation)
            if let png = representation.representation(using: .png, properties: [:]) {
                let url = directory.appendingPathComponent("09-window-confirm.png")
                do {
                    try png.write(to: url)
                    print(
                        "[ishot] wrote \(url.path) "
                        + "(\(representation.pixelsWide)×\(representation.pixelsHigh) px)"
                    )
                    copyToVerification(png, named: "overlay-09-window-confirm.png")
                } catch {
                    check("09-window-confirm: write PNG", false, error.localizedDescription)
                }
            } else {
                check("09-window-confirm: encode PNG", false)
            }
        } else {
            check("09-window-confirm: render bitmap", false)
        }

        confirmOverlay.mouseMoved(with: event(.mouseMoved, at: tapPoint))
        confirmOverlay.keyDown(with: keyEvent(keyCode: 36, modifiers: []))
        check(
            "window confirm: Return confirms the hovered window",
            confirmPicks == [501, 501],
            "ids=\(confirmPicks.map(String.init).joined(separator: ","))"
        )

        if let screen = NSScreen.main {
            let confirmController = CaptureOverlayController(
                mode: .region,
                prefilledSelection: nil,
                showCrosshair: false,
                startsInWindowPick: true
            )
            var controllerPicks: [CGWindowID] = []
            confirmController.onWindowPicked = { id, _ in controllerPicks.append(id) }
            confirmController.presentPanelsForTesting(on: screen)
            if let view = confirmController.overlayViewsForTesting.first {
                check(
                    "window confirm: the controller passes the window-only flag",
                    view.isWindowConfirmationModeForTesting
                )
                view.setWindowPickCandidatesForTesting(windows)
                view.mouseMoved(with: event(.mouseMoved, at: tapPoint))
                view.mouseDown(with: event(.leftMouseDown, at: tapPoint))
                view.mouseUp(with: event(.leftMouseUp, at: tapPoint))
                check(
                    "window confirm: confirming closes the overlay and reports the id",
                    controllerPicks == [501] && !confirmController.isPresenting,
                    "ids=\(controllerPicks) presenting=\(confirmController.isPresenting)"
                )
            } else {
                check("window confirm: the controller exposes its view", false)
            }
            confirmController.close()
        }

        let coordinator = CaptureCoordinator(settings: settings)
        check(
            "mode: a fresh coordinator has no overlay before any mode starts",
            !coordinator.isOverlayPresenting
        )

        // Menu: the new mode entry exists, carries no local key equivalent,
        // and the old interactive title is gone.
        let menuDelegate = AppDelegate()
        AppMenuBuilder.install(
            appName: "Unseen Window Mode Self Test",
            delegate: menuDelegate
        )
        let captureMenu = NSApp.mainMenu?.items.first {
            $0.title == "截图" || $0.submenu?.title == "截图"
        }?.submenu
        let titles = captureMenu?.items.map(\.title) ?? []
        let windowItem = captureMenu?.items.first { $0.title == "截图光标下的窗口" }
        check(
            "mode: the 截图 menu contains 截图光标下的窗口",
            windowItem != nil,
            "titles=\(titles.joined(separator: " | "))"
        )
        check(
            "mode: the 窗口截图 menu item has no local key equivalent",
            windowItem?.keyEquivalent.isEmpty == true,
            "key=\(windowItem?.keyEquivalent ?? "-")"
        )
        check(
            "mode: the instant window menu entry is still present",
            titles.contains("即时窗口"),
            "titles=\(titles.joined(separator: " | "))"
        )
        check(
            "mode: the window capture mode is listed",
            titles.contains("截图光标下的窗口"),
            "titles=\(titles.joined(separator: " | "))"
        )

        // MARK: Offscreen render: the three-mode state

        print("[mode] --- offscreen render ---")
        let previewSize = CGSize(width: 440, height: 340)
        let hosting = NSHostingView(
            rootView: CaptureModesPreview(selected: .window)
        )
        hosting.frame = CGRect(origin: .zero, size: previewSize)
        hosting.appearance = NSAppearance(named: .aqua)
        let previewCanvas = TestCanvasView(frame: hosting.frame)
        previewCanvas.addSubview(hosting)
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        check(
            "08-window-mode: the preview lists all three modes",
            CaptureMode.allCases.count == 3
        )
        if let representation = previewCanvas.bitmapImageRepForCachingDisplay(
            in: previewCanvas.bounds
        ) {
            previewCanvas.cacheDisplay(in: previewCanvas.bounds, to: representation)
            if let png = representation.representation(using: .png, properties: [:]) {
                let url = directory.appendingPathComponent("08-window-mode.png")
                do {
                    try png.write(to: url)
                    print(
                        "[mode] wrote \(url.path) "
                        + "(\(representation.pixelsWide)×\(representation.pixelsHigh) px)"
                    )
                    copyToVerification(png, named: "overlay-08-window-mode.png")
                    check(
                        "08-window-mode: the render has real pixels",
                        png.count > 2_000,
                        "bytes=\(png.count)"
                    )
                } catch {
                    check("08-window-mode: write PNG", false, error.localizedDescription)
                }
            } else {
                check("08-window-mode: encode PNG", false)
            }
        } else {
            check("08-window-mode: render bitmap", false)
        }

        // MARK: Offscreen renders: the armed window is a committed selection

        print("[armed] --- offscreen renders ---")
        let armedCanvas = TestCanvasView(frame: canvas)
        let armedRender = makeOverlay(showCrosshair: true)
        armedCanvas.addSubview(armedRender)
        armedRender.mouseDown(with: event(.leftMouseDown, at: tapPoint))
        armedRender.mouseUp(with: event(.leftMouseUp, at: tapPoint))
        check(
            "10-armed-window: no crosshair, toolbar visible, window highlighted",
            armedRender.armedWindowIDForTesting == 501
                && !armedRender.isCrosshairVisibleForTesting
                && armedRender.isToolbarVisibleForTesting
                && armedRender.isWindowHighlightVisibleForTesting
                && armedRender.windowHoverFramesForTesting == [front.bounds],
            "armed=\(armedRender.armedWindowIDForTesting.map(String.init) ?? "-") "
                + "crosshair=\(armedRender.isCrosshairVisibleForTesting) "
                + "toolbar=\(armedRender.isToolbarVisibleForTesting) "
                + "frames=\(armedRender.windowHoverFramesForTesting.map(format))"
        )
        check(
            "10-armed-window: the toolbar sits below the window",
            armedRender.toolbarFrameForTesting.maxY <= front.bounds.minY,
            "toolbar=\(format(armedRender.toolbarFrameForTesting))"
        )
        if let representation = armedCanvas.bitmapImageRepForCachingDisplay(in: armedCanvas.bounds) {
            armedCanvas.cacheDisplay(in: armedCanvas.bounds, to: representation)
            if let png = representation.representation(using: .png, properties: [:]) {
                let url = directory.appendingPathComponent("10-armed-window.png")
                do {
                    try png.write(to: url)
                    print(
                        "[armed] wrote \(url.path) "
                        + "(\(representation.pixelsWide)×\(representation.pixelsHigh) px)"
                    )
                    copyToVerification(png, named: "overlay-10-armed-window.png")
                    check("10-armed-window: the render has real pixels", png.count > 2_000)
                    // The window highlight reuses the region selection's white
                    // border, not the system accent.
                    if let armedImage = representation.cgImage {
                        let scale = CGFloat(armedImage.width) / armedCanvas.bounds.width
                        let probe = CGPoint(
                            x: front.bounds.minX + front.bounds.width * 0.3,
                            y: front.bounds.maxY
                        )
                        let sample = pixel(
                            armedImage,
                            x: Int((probe.x * scale).rounded()),
                            y: Int(((armedCanvas.bounds.height - probe.y) * scale).rounded())
                        )
                        check(
                            "10-armed-window: the outline is the neutral selection border, not accent blue",
                            sample.map { $0.r >= 235 && $0.g >= 235 && $0.b >= 235 } == true,
                            "pixel=\(String(describing: sample))"
                        )
                    }
                } catch {
                    check("10-armed-window: write PNG", false, error.localizedDescription)
                }
            } else {
                check("10-armed-window: encode PNG", false)
            }
        } else {
            check("10-armed-window: render bitmap", false)
        }

        let bottomCanvas = TestCanvasView(frame: canvas)
        bottomOverlay.frame = canvas
        bottomCanvas.addSubview(bottomOverlay)
        check(
            "11-armed-window-toolbar-above: toolbar and window do not overlap",
            !bottomOverlay.toolbarFrameForTesting.intersects(bottomWindow.bounds),
            "toolbar=\(format(bottomOverlay.toolbarFrameForTesting)) "
                + "window=\(format(bottomWindow.bounds))"
        )
        if let representation = bottomCanvas.bitmapImageRepForCachingDisplay(in: bottomCanvas.bounds) {
            bottomCanvas.cacheDisplay(in: bottomCanvas.bounds, to: representation)
            if let png = representation.representation(using: .png, properties: [:]) {
                let url = directory.appendingPathComponent("11-armed-window-toolbar-above.png")
                do {
                    try png.write(to: url)
                    print(
                        "[armed] wrote \(url.path) "
                        + "(\(representation.pixelsWide)×\(representation.pixelsHigh) px)"
                    )
                    copyToVerification(png, named: "overlay-11-armed-window-toolbar-above.png")
                    check("11-armed-window-toolbar-above: the render has real pixels", png.count > 2_000)
                } catch {
                    check("11-armed-window-toolbar-above: write PNG", false, error.localizedDescription)
                }
            } else {
                check("11-armed-window-toolbar-above: encode PNG", false)
            }
        } else {
            check("11-armed-window-toolbar-above: render bitmap", false)
        }

        // MARK: Synthetic end-to-end: click → Return → clipboard pixels

        // The overlay reports the committed rectangle; the capture half below
        // is the exact `ScreenCapture.captureArea` call the coordinator makes
        // for a region. If screen recording is denied, the run logs and stays
        // green (the deterministic checks above already proved the rect path).
        if let screen = NSScreen.main {
            print("[armed-e2e] --- click → Return → pasteboard ---")
            let controller = CaptureOverlayController(
                mode: .region,
                prefilledSelection: nil,
                showCrosshair: true
            )
            let fixture = WindowCandidate(
                windowNumber: 701,
                bounds: CGRect(x: 120, y: 120, width: 320, height: 200),
                layer: 0,
                ownerPID: 7701,
                ownerName: "ClipboardFixture",
                windowName: "ClipboardFixture",
                isOwnedBySelf: false
            )
            let expectedGlobal = CaptureOverlayController.globalRect(
                fixture.bounds,
                on: screen
            )
            var confirmedRect: CGRect?
            var confirmedAction: CaptureToolbarAction?
            var clipboardImage: NSImage?
            var clipboardPixelSize: CGSize?
            var captureFailure: String?

            let beforeChange = NSPasteboard.general.changeCount
            controller.onRegionConfirmed = { rect, _, action in
                confirmedRect = rect
                confirmedAction = action
                Task { @MainActor in
                    do {
                        // The panel needs one frame to leave the compositor.
                        try await Task.sleep(nanoseconds: 160_000_000)
                        let shot = try await ScreenCapture.captureArea(
                            rect,
                            on: screen,
                            includeCursor: false
                        )
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.writeObjects([shot.nsImage])
                        clipboardImage = shot.nsImage
                        clipboardPixelSize = CGSize(
                            width: shot.image.width,
                            height: shot.image.height
                        )
                        DebugLog.log(
                            "armed-e2e: pasteboard image "
                            + "\(shot.image.width)×\(shot.image.height) px, "
                            + "rect=\(NSStringFromRect(rect))"
                        )
                    } catch {
                        captureFailure = error.localizedDescription
                        DebugLog.log("armed-e2e: capture failed: \(error.localizedDescription)")
                    }
                }
            }

            controller.presentPanelsForTesting(on: screen)
            if let view = controller.overlayViewsForTesting.first {
                view.setWindowPickCandidatesForTesting([fixture])
                let fixturePoint = CGPoint(
                    x: fixture.bounds.midX,
                    y: fixture.bounds.midY
                )
                view.mouseDown(with: event(.leftMouseDown, at: fixturePoint))
                view.mouseUp(with: event(.leftMouseUp, at: fixturePoint))
                check(
                    "armed-e2e: the click armed the fixture window",
                    view.armedWindowIDForTesting == 701,
                    "armed=\(view.armedWindowIDForTesting.map(String.init) ?? "-")"
                )
                view.keyDown(with: keyEvent(keyCode: 36, modifiers: []))
            } else {
                check("armed-e2e: the controller exposes its overlay view", false)
            }

            // Wait for the async capture/write, up to 4 s.
            var waited = 0
            while waited < 40, NSPasteboard.general.changeCount == beforeChange {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }

            check(
                "armed-e2e: Return committed the fixture rectangle",
                confirmedRect == expectedGlobal && confirmedAction == .copyClosing,
                "rect=\(confirmedRect.map(format) ?? "-") "
                    + "expected=\(format(expectedGlobal)) "
                    + "action=\(confirmedAction?.rawValue ?? "-")"
            )

            if let clipboardImage, let clipboardPixelSize {
                let pointSize = clipboardImage.size
                check(
                    "armed-e2e: the pasteboard holds an image of the window size",
                    abs(pointSize.width - fixture.bounds.width) <= 1.5
                        && abs(pointSize.height - fixture.bounds.height) <= 1.5,
                    "points=\(number(pointSize.width))×\(number(pointSize.height)) "
                        + "window=\(number(fixture.bounds.width))×\(number(fixture.bounds.height)) "
                        + "pixels=\(number(clipboardPixelSize.width))×\(number(clipboardPixelSize.height))"
                )
                if let tiff = clipboardImage.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    let url = directory.appendingPathComponent("12-return-clipboard.png")
                    try? png.write(to: url)
                    copyToVerification(png, named: "overlay-12-return-clipboard.png")
                    print(
                        "[armed-e2e] wrote \(url.path) "
                        + "(\(rep.pixelsWide)×\(rep.pixelsHigh) px)"
                    )
                }
            } else {
                // No assertion: a denied Screen Recording grant is an
                // environment limitation, not a regression of the rect path.
                print(
                    "[armed-e2e] SKIPPED clipboard pixel check: "
                    + (captureFailure ?? "no pasteboard change observed")
                )
            }
            controller.close()
        } else {
            print("[armed-e2e] SKIPPED: no NSScreen.main in this process")
        }
    }

    // MARK: - The window highlight is the region selection's outline

    /// The window pick used to paint the system accent. It must instead be the
    /// region selection's own outline: the same dark halo and white border,
    /// from the same `SelectionBorderStyle` constants. Two independent proofs:
    /// the palette `draw` reads, and a pixel-for-pixel render comparison.
    private static func runWindowHighlightStyleTests(into directory: URL) {
        print("[highlight] --- window highlight vs region selection ---")

        // 1. The drawing decision itself.
        for (label, selected, hovered) in [
            ("selected", true, false),
            ("hovered", false, true),
            ("armed (selected + hovered)", true, true)
        ] {
            let style = WindowHighlightView.outlineStyle(selected: selected, hovered: hovered)
            check(
                "highlight: the \(label) outline is the region selection's",
                style.isMatchedToSelection
                    && style.color == SelectionBorderStyle.borderColor
                    && style.width == SelectionBorderStyle.borderWidth,
                "matched=\(style.isMatchedToSelection) color=\(style.color) "
                    + "width=\(style.width) "
                    + "region=\(SelectionBorderStyle.borderColor)/\(SelectionBorderStyle.borderWidth)"
            )
        }
        check(
            "highlight: neither the outline nor the halo is the system accent",
            SelectionBorderStyle.borderColor != NSColor.controlAccentColor
                && SelectionBorderStyle.haloColor != NSColor.controlAccentColor,
            "border=\(SelectionBorderStyle.borderColor) "
                + "halo=\(SelectionBorderStyle.haloColor) "
                + "accent=\(NSColor.controlAccentColor)"
        )

        // 2. One rectangle, two renderers, identical ground and geometry.
        let ground = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let rect = CGRect(x: 260, y: 220, width: 480, height: 300)
        let grey = NSColor(calibratedWhite: 0.55, alpha: 1)

        let regionGround = FlatGroundView(frame: ground)
        regionGround.color = grey
        let regionBorder = SelectionBorderView(frame: ground)
        regionGround.addSubview(regionBorder)
        regionBorder.setSelection(rect)

        let windowGround = FlatGroundView(frame: ground)
        windowGround.color = grey
        let windowHighlight = WindowHighlightView(frame: ground)
        windowHighlight.entries = [
            WindowHighlightView.Entry(frame: rect, selected: true, hovered: true)
        ]
        windowGround.addSubview(windowHighlight)

        guard let regionImage = renderImage(of: regionGround),
              let windowImage = renderImage(of: windowGround) else {
            check("highlight: render the region/window comparison pair", false)
            return
        }

        func sample(_ image: CGImage, _ point: CGPoint) -> (r: Int, g: Int, b: Int, a: Int)? {
            let scale = CGFloat(image.width) / ground.width
            return pixel(
                image,
                x: Int((point.x * scale).rounded()),
                y: Int(((ground.height - point.y) * scale).rounded())
            )
        }

        // 30 % along the top edge: clear of the region's eight handles (corners
        // and edge midpoints) and of the window order badge.
        let edgeX = rect.minX + rect.width * 0.3
        let edgePoint = CGPoint(x: edgeX, y: rect.maxY)
        let haloPoint = CGPoint(x: edgeX, y: rect.maxY + 1.5)
        let groundPoint = CGPoint(x: edgeX, y: rect.maxY + 7)

        let regionEdge = sample(regionImage, edgePoint)
        let windowEdge = sample(windowImage, edgePoint)
        let regionHalo = sample(regionImage, haloPoint)
        let windowHalo = sample(windowImage, haloPoint)
        let plainGround = sample(regionImage, groundPoint)

        check(
            "highlight: both outlines are the same white border",
            regionEdge != nil && windowEdge != nil
                && regionEdge!.r >= 235 && regionEdge!.g >= 235 && regionEdge!.b >= 235
                && windowEdge!.r >= 235 && windowEdge!.g >= 235 && windowEdge!.b >= 235
                && abs(regionEdge!.r - windowEdge!.r) <= 2
                && abs(regionEdge!.g - windowEdge!.g) <= 2
                && abs(regionEdge!.b - windowEdge!.b) <= 2,
            "region=\(String(describing: regionEdge)) window=\(String(describing: windowEdge))"
        )
        check(
            "highlight: both outlines are neutral, never accent blue",
            regionEdge != nil && windowEdge != nil
                && windowEdge!.b <= windowEdge!.r + 2
                && regionEdge!.b <= regionEdge!.r + 2,
            "region=\(String(describing: regionEdge)) window=\(String(describing: windowEdge))"
        )
        check(
            "highlight: both outlines carry the same dark halo",
            regionHalo != nil && windowHalo != nil && plainGround != nil
                && abs(regionHalo!.r - windowHalo!.r) <= 2
                && abs(regionHalo!.g - windowHalo!.g) <= 2
                && abs(regionHalo!.b - windowHalo!.b) <= 2
                && windowHalo!.r < plainGround!.r - 20,
            "region=\(String(describing: regionHalo)) window=\(String(describing: windowHalo)) "
                + "ground=\(String(describing: plainGround))"
        )

        // Whole-image neutrality: every colour this view can paint (ground,
        // white wash, white border, black halo, badge chrome) is grey, so any
        // blue (or any tint at all) is a regression.
        var maxChannelSpread = 0
        var offPixels = 0
        if let buffer = pixelBuffer(windowImage) {
            for y in 0..<buffer.height {
                for x in 0..<buffer.width {
                    let (r, g, b) = buffer.rgb(x: x, y: y)
                    let spread = max(r, g, b) - min(r, g, b)
                    if spread > 3 {
                        offPixels += 1
                        maxChannelSpread = max(maxChannelSpread, spread)
                    }
                }
            }
            check(
                "highlight: the whole window highlight render is neutral (no accent anywhere)",
                offPixels == 0,
                "tintedPixels=\(offPixels) maxSpread=\(maxChannelSpread)"
            )
        } else {
            check("highlight: read the window highlight pixels", false)
        }

        // 3. PNGs: each surface alone, then side by side.
        writePNG(
            regionImage,
            to: directory.appendingPathComponent("58-region-selection-reference.png")
        )
        writePNG(
            windowImage,
            to: directory.appendingPathComponent("59-window-highlight-neutral.png")
        )
        print("[highlight] wrote 58-region-selection-reference.png / 59-window-highlight-neutral.png")

        if let composed = composeSideBySide([regionImage, windowImage]) {
            writePNG(
                composed,
                to: directory.appendingPathComponent("60-window-highlight-vs-region.png")
            )
            print("[highlight] wrote 60-window-highlight-vs-region.png")
            if let data = NSBitmapImageRep(cgImage: composed)
                .representation(using: .png, properties: [:]) {
                copyToVerification(data, named: "fix2-60-window-highlight-vs-region.png")
            }
            check(
                "highlight: the comparison image is real pixels",
                composed.width == regionImage.width + windowImage.width + 4
                    && composed.height == max(regionImage.height, windowImage.height),
                "size=\(composed.width)×\(composed.height) "
                    + "panes=\(regionImage.width)+\(windowImage.width)"
                    + "+4 gutter, heights \(regionImage.height)/\(windowImage.height)"
            )
        } else {
            check("highlight: compose the side-by-side comparison", false)
        }
    }

    /// Two renders with a 4 pt dark gutter between them, for visual review.
    private static func composeSideBySide(_ images: [CGImage]) -> CGImage? {
        guard !images.isEmpty else { return nil }
        let gap = 4
        let width = images.reduce(0) { $0 + $1.width } + gap * (images.count - 1)
        let height = images.map(\.height).max() ?? 0
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var x = 0
        for image in images {
            context.draw(image, in: CGRect(x: x, y: 0, width: image.width, height: image.height))
            x += image.width + gap
        }
        return context.makeImage()
    }

    // MARK: - Style panel + app background + liquid-glass toolbar

    private static func runAnnotationStyleTests(into directory: URL) {
        print("[style] --- annotation style model ---")
        let base = AnnotationStyle.defaultStyle(for: .arrow)
        var wild = base
        wild.lineWidth = 99
        wild.fontSize = 5
        wild.opacity = 0
        let clamped = wild.clamped(for: .arrow)
        check(
            "style: line width clamps to 1…24",
            clamped.lineWidth == AnnotationStyle.lineWidthRange.upperBound
                && base.clamped(for: .arrow).lineWidth >= 1
        )
        check(
            "style: font size clamps to 10…72",
            clamped.fontSize == AnnotationStyle.fontSizeRange.lowerBound
        )
        check(
            "style: highlighter opacity clamps to 0.15…1",
            clamped.opacity == AnnotationStyle.opacityRange.lowerBound
        )
        check(
            "style: the default text size is the renderer's 20 pt",
            AnnotationStyle.defaultStyle(for: .text).fontSize == 20
        )

        print("[style] --- stroke + text application ---")
        let canvas = CGRect(origin: .zero, size: canvasSize)
        let overlay = CaptureOverlayView(
            frame: canvas,
            mode: .region,
            prefilledSelection: nil,
            showCrosshair: false,
            rendersOffscreen: true
        )
        overlay.applySelectionForTesting(CGRect(x: 200, y: 200, width: 600, height: 400))
        overlay.selectToolForTesting(.arrow)
        var style = AnnotationStyle.defaultStyle(for: .arrow)
        style.color = .systemPink
        style.lineWidth = 9
        overlay.setStyleForTesting(style, for: .arrow)
        overlay.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 300, y: 300)))
        overlay.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 450, y: 360)))
        overlay.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 450, y: 360)))
        check(
            "style: a stroke uses the panel colour and line width",
            overlay.lastAnnotationColorForTesting?.isEqual(NSColor.systemPink) == true
                && overlay.lastAnnotationLineWidthForTesting == 9,
            "color=\(overlay.lastAnnotationColorForTesting.map { "\($0)" } ?? "-") "
                + "width=\(overlay.lastAnnotationLineWidthForTesting ?? -1)"
        )

        overlay.selectToolForTesting(.text)
        var textStyle = AnnotationStyle.defaultStyle(for: .text)
        textStyle.fontSize = 36
        textStyle.color = .systemGreen
        overlay.setStyleForTesting(textStyle, for: .text)
        overlay.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 350, y: 350)))
        overlay.setTextInputValueForTesting("Styled")
        overlay.commitTextInputForTesting()
        check(
            "style: text commits the panel font size and colour",
            overlay.lastAnnotationFontSizeForTesting == 36
                && overlay.lastAnnotationColorForTesting?.isEqual(NSColor.systemGreen) == true,
            "font=\(overlay.lastAnnotationFontSizeForTesting ?? -1) "
                + "color=\(overlay.lastAnnotationColorForTesting.map { "\($0)" } ?? "-")"
        )

        print("[style] --- toolbar style button + liquid glass ---")
        let toolbar = CaptureToolbarView(offscreen: false)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = toolbar
        toolbar.frame = CGRect(x: 0, y: 0, width: 1200, height: 80)
        toolbar.layoutSubtreeIfNeeded()
        window.orderFrontRegardless()
        toolbar.layoutSubtreeIfNeeded()
        check(
            "style: the toolbar exposes a palette button",
            toolbar.styleButtonFrame != nil,
            "frame=\(toolbar.styleButtonFrame.map(format) ?? "nil")"
        )
        // The approved recipe (f00e22f) paints small chips with a flat 20 %
        // tint from GlassSurfaceFactory's .liquidGlass branch instead of a
        // second NSGlassEffectView; the toolbar still must install a backdrop.
        check(
            "style: the toolbar keeps the approved flat-tint glass backdrop",
            toolbar.backdropViewClassNameForTesting == "NSView",
            "class=\(toolbar.backdropViewClassNameForTesting ?? "-")"
        )
        check(
            "style: the glass plate clips to the same 12 pt corner",
            toolbar.backdropCornerRadiusForTesting == 12,
            "radius=\(String(describing: toolbar.backdropCornerRadiusForTesting))"
        )
        check(
            "style: the single plate keeps the fixed 12 pt rounded rectangle",
            CaptureToolbarView.cornerRadius == 12
                && abs(toolbar.rowOneFrameForTesting.height
                    - CaptureToolbarView.rowHeight) < 0.01
                && abs(toolbar.rowOneFrameForTesting.width
                    - toolbar.bounds.width) < 0.01,
            "radius=\(CaptureToolbarView.cornerRadius) "
                + "plate=\(format(toolbar.rowOneFrameForTesting)) "
                + "bounds=\(format(toolbar.bounds))"
        )
        window.orderOut(nil)
        window.close()

        // Offscreen proof of the panel itself. The palette is six fixed
        // standards (no system colour panel), so the snapshot selects one of
        // them and the palette itself is a cheap structural check.
        check(
            "style: the annotation palette is the six fixed standards",
            AnnotationPalette.swatches.map(\.hex) == [
                "FF3B30", "FF9500", "FFCC00", "34C759", "007AFF", "AF52DE"
            ],
            "swatches=\(AnnotationPalette.swatches.map(\.hex))"
        )
        var panelStyle = AnnotationStyle.defaultStyle(for: .arrow)
        panelStyle.color = AnnotationPalette.swatches[0].color
        panelStyle.lineWidth = 7
        let hosting = NSHostingView(
            rootView: AnnotationStylePanel(tool: .arrow, style: panelStyle) { _ in }
        )
        hosting.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        hosting.appearance = NSAppearance(named: .aqua)
        let panelCanvas = TestCanvasView(frame: hosting.frame)
        panelCanvas.addSubview(hosting)
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        if let rep = panelCanvas.bitmapImageRepForCachingDisplay(in: panelCanvas.bounds) {
            panelCanvas.cacheDisplay(in: panelCanvas.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                let url = directory.appendingPathComponent("12-annotation-style.png")
                do {
                    try png.write(to: url)
                    print("[style] wrote \(url.path) (\(rep.pixelsWide)×\(rep.pixelsHigh) px)")
                    copyToVerification(png, named: "overlay-12-annotation-style.png")
                    check("style: the panel renders real pixels", png.count > 2_000,
                          "bytes=\(png.count)")
                } catch {
                    check("style: write panel PNG", false, error.localizedDescription)
                }
            } else {
                check("style: encode panel PNG", false)
            }
        } else {
            check("style: render panel bitmap", false)
        }

        print("[style] --- settings background ---")
        check(
            "style: three window backgrounds are offered",
            AppBackgroundStyle.allCases.count == 3
                && AppBackgroundStyle.allCases.map(\.rawValue)
                    == ["solid", "translucent", "liquidGlass"],
            "cases=\(AppBackgroundStyle.allCases.map(\.rawValue))"
        )
        let suiteName = "UnseenStyle-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            check("style: create isolated defaults", false)
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        check(
            "style: the background defaults to 液态玻璃",
            settings.backgroundStyle == "liquidGlass"
                && settings.backgroundStyleValue == .liquidGlass
        )
        settings.backgroundStyle = "solid"
        check(
            "style: the background round-trips through UserDefaults",
            defaults.string(forKey: AppSettings.Key.backgroundStyle) == "solid"
                && settings.backgroundStyleValue == .solid
        )
        settings.resetAll()
        check(
            "style: resetAll restores 液态玻璃",
            settings.backgroundStyle == "liquidGlass"
        )
    }

    // MARK: - P4. Main-window chrome (background tiers, corners, selection)

    /// The main window's shell: which background style makes the window
    /// opaque, the four-corner mask, and the translucent selection that
    /// replaced the accent-blue slab.
    private static func runWindowChromeTests() {
        print("[chrome] --- window background tiers ---")
        check(
            "chrome: 纯色 is the only opaque window background",
            MainWindowChrome.isOpaqueBackground(.solid)
                && !MainWindowChrome.isOpaqueBackground(.translucent)
                && !MainWindowChrome.isOpaqueBackground(.liquidGlass),
            "solid=\(MainWindowChrome.isOpaqueBackground(.solid)) "
                + "translucent=\(MainWindowChrome.isOpaqueBackground(.translucent)) "
                + "glass=\(MainWindowChrome.isOpaqueBackground(.liquidGlass))"
        )
        check(
            "chrome: 纯色 paints the window-background colour, the others stay clear",
            MainWindowChrome.windowBackgroundColor(for: .solid) == .windowBackgroundColor
                && MainWindowChrome.windowBackgroundColor(for: .translucent) == .clear
                && MainWindowChrome.windowBackgroundColor(for: .liquidGlass) == .clear
        )
        check(
            "chrome: 半透明 resolves to the NSVisualEffectView blur",
            AppBackgroundStyle.translucent.backdropKind == .visualEffect
                && VisualEffectBackdrop.makeBackdrop().material == .underWindowBackground
        )

        // A real window shell, but no MainView (which would open the user's
        // database). This exercises the same code the controller uses.
        let window = MainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = content

        window.applyBackgroundStyle(.solid)
        check(
            "chrome: solid → the window itself is opaque",
            window.isOpaque && window.backgroundColor == .windowBackgroundColor,
            "opaque=\(window.isOpaque) bg=\(window.backgroundColor.description)"
        )
        window.applyBackgroundStyle(.translucent)
        check(
            "chrome: translucent → non-opaque window + clear background",
            !window.isOpaque && window.backgroundColor == .clear,
            "opaque=\(window.isOpaque) bg=\(window.backgroundColor.description)"
        )
        window.applyBackgroundStyle(.liquidGlass)
        check(
            "chrome: glass → non-opaque window + clear background",
            !window.isOpaque && window.backgroundColor == .clear,
            "opaque=\(window.isOpaque) bg=\(window.backgroundColor.description)"
        )

        let layer = content.layer
        check(
            "chrome: all four corners share the system radius",
            layer?.cornerRadius == MainWindowChrome.cornerRadius
                && (layer?.cornerRadius ?? 0) > 0,
            "radius=\(layer?.cornerRadius ?? -1) expected=\(MainWindowChrome.cornerRadius)"
        )
        check(
            "chrome: the corner curve is continuous",
            layer?.cornerCurve == .continuous,
            "curve=\(String(describing: layer?.cornerCurve))"
        )
        check(
            "chrome: masksToBounds clips the rounded window",
            layer?.masksToBounds == true
        )

        window.applyChrome(fullScreen: true)
        check(
            "chrome: full screen removes the rounding instead of squaring it",
            layer?.cornerRadius == 0 && layer?.masksToBounds == false,
            "radius=\(layer?.cornerRadius ?? -1) masks=\(String(describing: layer?.masksToBounds))"
        )
        window.applyChrome(fullScreen: false)
        check(
            "chrome: leaving full screen restores the rounding",
            layer?.cornerRadius == MainWindowChrome.cornerRadius
                && layer?.masksToBounds == true
        )

        print("[chrome] --- liquid glass composition ---")
        switch AppBackgroundStyle.liquidGlass.backdropKind {
        case .glass:
            if #available(macOS 26.0, *) {
                let backdrop = GlassBackdropView.makeBackdrop()
                // macOS 27's NSGlassEffectView carries internal content
                // holders, so assert the class itself rather than one subview.
                let glass = backdrop as? NSGlassEffectView
                check(
                    "chrome: the glass backdrop is an NSGlassEffectView",
                    glass != nil,
                    "class=\(String(describing: type(of: backdrop)))"
                )
                check(
                    "chrome: the glass backdrop uses the default .regular style",
                    glass?.style == .regular,
                    "style=\(String(describing: glass?.style))"
                )
                check(
                    "chrome: the glass backdrop has no custom gradient layer",
                    !containsGradientLayer(in: backdrop)
                )
            } else {
                check("chrome: the glass backdrop requires macOS 26", false)
            }
        case .visualEffect:
            let backdrop = GlassBackdropView.makeBackdrop()
            check(
                "chrome: liquid glass falls back to NSVisualEffectView below macOS 26",
                backdrop is NSVisualEffectView
            )
        case .none:
            check("chrome: liquid glass never resolves to no backdrop", false)
        }

        print("[chrome] --- selection treatment ---")
        check(
            "chrome: the selection fill is translucent by construction",
            SelectionStyle.fillOpacity > 0 && SelectionStyle.fillOpacity < 1,
            "alpha=\(SelectionStyle.fillOpacity)"
        )
        check(
            "chrome: hover is fainter than selection",
            SelectionStyle.hoverOpacity < SelectionStyle.fillOpacity,
            "hover=\(SelectionStyle.hoverOpacity) selected=\(SelectionStyle.fillOpacity)"
        )
        let light = SelectionStyle.resolvedFill(for: NSAppearance(named: .aqua)!)
        let dark = SelectionStyle.resolvedFill(for: NSAppearance(named: .darkAqua)!)
        check(
            "chrome: the selection alpha is < 1 in light and dark",
            light.alphaComponent < 1 && dark.alphaComponent < 1
                && light.alphaComponent > 0 && dark.alphaComponent > 0,
            "light=\(light.alphaComponent) dark=\(dark.alphaComponent)"
        )
        check(
            "chrome: the selection is neutral, not a solid accent blue",
            isNeutral(light) && isNeutral(dark),
            "light=\(components(light)) dark=\(components(dark))"
        )
        // ARC owns `window`; letting `close()` perform the legacy
        // `isReleasedWhenClosed` release would over-release it and corrupt the
        // autorelease pool a few checks later.
        window.isReleasedWhenClosed = false
        window.orderOut(nil)
        window.close()
    }

    private static func containsGradientLayer(in view: NSView) -> Bool {
        if view.layer is CAGradientLayer { return true }
        return view.subviews.contains { containsGradientLayer(in: $0) }
    }

    private static func containsVisualEffect(in view: NSView) -> Bool {
        if view is NSVisualEffectView { return true }
        return view.subviews.contains { containsVisualEffect(in: $0) }
    }

    private static func isNeutral(_ color: NSColor) -> Bool {
        // macOS 27 hands back generic-grey colours from withAlphaComponent;
        // `redComponent` raises unless the colour is in an RGB space first.
        let color = color.usingColorSpace(.sRGB) ?? color
        let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
        return max(r, max(g, b)) - min(r, min(g, b)) <= 0.05
    }

    private static func components(_ color: NSColor) -> String {
        let color = color.usingColorSpace(.sRGB) ?? color
        return String(
            format: "r=%.2f g=%.2f b=%.2f a=%.2f",
            color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent
        )
    }

    // MARK: - Settings information architecture (2026-10)

    /// The left column's new grouping, the middle-column page groups, and the
    /// fact that every settings page really draws a `GroupSlab`.
    private static func runSettingsArchitectureTests(into directory: URL) {
        print("[settings] --- left column grouping ---")
        let groups = Dictionary(uniqueKeysWithValues: NavItem.groups)
        let screenshot = groups["截图"] ?? []
        let tools = groups["工具"] ?? []
        let system = groups["系统"] ?? []
        let expectedScreenshot: [NavItem] = [.capture, .scrollCapture, .recording]
        check(
            "settings: the 截图 section lists 截图 / 长截图 / 录屏 in this order",
            screenshot == expectedScreenshot,
            "items=\(screenshot.map(\.rawValue))"
        )
        let expectedTools: [NavItem] = [.ocr, .colorPicker, .keyDisplay, .camera, .annotation]
        check(
            "settings: the 工具 section lists the five tools, 标注 last",
            tools == expectedTools,
            "items=\(tools.map(\.rawValue))"
        )
        let listedRows = NavItem.groups.flatMap(\.1)
        check(
            "settings: no left-column row is listed twice",
            Set(listedRows).count == listedRows.count,
            "rows=\(listedRows.map(\.rawValue))"
        )
        check(
            "settings: the four capture modes are no longer left-column rows",
            !listedRows.contains(.regionCapture)
                && !listedRows.contains(.windowCapture)
                && !listedRows.contains(.fixedSizeCapture)
                && !listedRows.contains(.fullScreenCapture),
            "rows=\(listedRows.map(\.rawValue))"
        )
        check(
            "settings: 截图 is the first row in the left column",
            NavItem.groups.first?.0 == "截图" && NavItem.groups.first?.1.first == .capture,
            "first=\(NavItem.groups.first?.0 ?? "-") "
                + "rows=\(NavItem.groups.first?.1.map(\.rawValue) ?? [])"
        )
        check(
            "settings: the four groups keep the order 截图 / 工具 / 系统 / 资料库",
            NavItem.groups.map(\.0) == ["截图", "工具", "系统", "资料库"],
            "order=\(NavItem.groups.map(\.0))"
        )
        check(
            "settings: the renamed entry now reads 截图",
            NavItem.capture.title == "截图",
            "title=\(NavItem.capture.title)"
        )
        check(
            "settings: the 系统 section reads 通用 / 快捷键 / 外观 / 用量 / 隐私 / 存储",
            system == [.general, .hotkeys, .appearance, .usage, .privacy, .storage],
            "items=\(system.map(\.rawValue))"
        )
        // 2026-10: 快捷键 was promoted from a group inside 通用 to a
        // first-level page, immediately after 通用 and before 外观.
        check(
            "settings: 快捷键 sits between 通用 and 外观 in the left column",
            system.firstIndex(of: .hotkeys) == 1
                && system.first == .general
                && system.count > 2
                && system[2] == .appearance
                && NavItem.hotkeys.title == "快捷键"
                && NavItem.hotkeys.settingsSection == .hotkeys,
            "system=\(system.map(\.rawValue)) title=\(NavItem.hotkeys.title)"
        )
        check(
            "settings: UNSEEN_OPEN=hotkeys resolves to the new page",
            SettingsSection(rawValue: "hotkeys") == .hotkeys
                && NavItem(rawValue: "hotkeys") == .hotkeys,
            "section=\(String(describing: SettingsSection(rawValue: "hotkeys")))"
        )
        check(
            "settings: 用量 / 隐私 / 存储 remain in the system section",
            system.contains(.usage) && system.contains(.privacy) && system.contains(.storage)
        )
        check(
            "settings: 通用 / 外观 remain in the system section",
            system.contains(.general) && system.contains(.appearance)
        )
        check(
            "settings: the 工具 and 资料库 entries are still reachable",
            groups["工具"] == expectedTools
                && groups["资料库"] == [.history, .pins],
            "tools=\(groups["工具"]?.map(\.rawValue) ?? []) "
                + "library=\(groups["资料库"]?.map(\.rawValue) ?? [])"
        )
        let capturePages = Array(screenshot.dropFirst()) + tools
        check(
            "settings: every non-mode capture page maps to its own SettingsSection",
            capturePages.allSatisfy { $0.settingsSection != nil }
                && Set(capturePages.compactMap { $0.settingsSection }).count == 7
        )

        print("[settings] --- 截图: one entry, four modes ---")
        check(
            "settings: 截图 leads the group and the old 工具-only entry is gone",
            screenshot.first == .capture && !tools.contains(.capture),
            "screenshot=\(screenshot.map(\.rawValue)) tools=\(tools.map(\.rawValue))"
        )
        check(
            "settings: 截图 lists the four modes in this order",
            CaptureToolMode.allCases.map(\.settingsSection) == [
                .regionCapture, .windowCapture, .fixedSizeCapture, .fullScreenCapture
            ],
            "modes=\(CaptureToolMode.allCases.map(\.rawValue))"
        )
        // The row is icon + title only. 2026-10-24 removed the one-line
        // description the four mode rows used to carry, so the row model has no
        // subtitle left to draw and matches a settings group row exactly.
        check(
            "settings: each mode row reads exactly like its settings page (icon + title, no subtitle)",
            CaptureToolMode.allCases.allSatisfy {
                $0.title == $0.settingsSection.title
                    && $0.symbol == $0.settingsSection.symbol
            } && Set(CaptureToolMode.allCases.map(\.title)).count == CaptureToolMode.allCases.count,
            "rows=\(CaptureToolMode.allCases.map { "\($0.title)/\($0.symbol)" })"
        )
        check(
            "settings: the four mode pages are reachable only through 截图",
            Set(CaptureToolMode.allCases.map(\.settingsSection))
                .isDisjoint(with: Set(listedRows.compactMap(\.settingsSection))),
            "leftRows=\(listedRows.compactMap(\.settingsSection?.rawValue))"
        )
        check(
            "settings: every old UNSEEN_OPEN name still resolves",
            CaptureToolMode.legacyOpenNames.count == 5
                && CaptureToolMode.legacyOpenNames["screenshot"] == .region
                && CaptureToolMode.legacyOpenNames["regionCapture"] == .region
                && CaptureToolMode.legacyOpenNames["windowCapture"] == .window
                && CaptureToolMode.legacyOpenNames["fixedSizeCapture"] == .fixedSize
                && CaptureToolMode.legacyOpenNames["fullScreenCapture"] == .fullScreen
        )
        check(
            "settings: 默认模式 seeds 截图's row",
            NavigationDefaults.captureTool == .region
                && CaptureToolMode(settingsSection: .fixedSizeCapture) == .fixedSize
                && CaptureToolMode(settingsSection: .general) == nil
        )
        // The invariant behind "设置里只有一个地方能进截图模式的设置": every
        // settings page has exactly one way in — a sidebar row or a 截图 mode
        // row, never both, and none left over.
        let sidebarPages = Set(listedRows.compactMap(\.settingsSection))
        let modePages = Set(CaptureToolMode.allCases.map(\.settingsSection))
        check(
            "settings: every settings page has exactly one entry",
            sidebarPages.union(modePages) == Set(SettingsSection.allCases)
                && sidebarPages.isDisjoint(with: modePages),
            "sidebar=\(sidebarPages.count) modes=\(modePages.count) "
                + "all=\(SettingsSection.allCases.count)"
        )

        print("[settings] --- middle-column page groups ---")
        check(
            "settings: there are seventeen settings pages",
            SettingsSection.allCases.count == 17,
            "count=\(SettingsSection.allCases.count)"
        )
        check(
            "settings: every page declares at least one group",
            SettingsSection.allCases.allSatisfy { !$0.pageGroups.isEmpty },
            "empty=\(SettingsSection.allCases.filter { $0.pageGroups.isEmpty }.map(\.rawValue))"
        )
        check(
            "settings: every page group has a non-empty title and symbol",
            SettingsSection.allCases.allSatisfy { section in
                section.pageGroups.allSatisfy {
                    !$0.title.isEmpty && !$0.symbol.isEmpty && !$0.id.isEmpty
                }
            }
        )
        check(
            "settings: group ids are unique within each page",
            SettingsSection.allCases.allSatisfy { section in
                Set(section.pageGroups.map(\.id)).count == section.pageGroups.count
            }
        )
        var allGroupIDs: [String] = []
        for section in SettingsSection.allCases {
            allGroupIDs.append(contentsOf: section.pageGroups.map(\.id))
        }
        check(
            "settings: group ids are unique across the whole app",
            Set(allGroupIDs).count == allGroupIDs.count,
            "ids=\(allGroupIDs.count) unique=\(Set(allGroupIDs).count)"
        )
        check(
            "settings: every page's first group is a valid jump target",
            SettingsSection.allCases.allSatisfy { section in
                let first = section.pageGroups.first?.id ?? ""
                return !first.isEmpty && first != PageGroupID.none
            }
        )

        // The old 通用 page must not keep carrying capture groups; each one now
        // has a dedicated page. This is the concrete "nothing moved twice" check.
        let oldCaptureIDs: Set<String> = [
            "capture", "instant-capture", "saving", "recording",
            "color-picker", "camera-overlay", "key-display"
        ]
        check(
            "settings: 通用 no longer carries the capture groups",
            !SettingsSection.general.pageGroups.contains { oldCaptureIDs.contains($0.id) },
            "groups=\(SettingsSection.general.pageGroups.map(\.id))"
        )
        check(
            "settings: 通用 keeps startup / menu bar / behaviour / pin / backup",
            Set(SettingsSection.general.pageGroups.map(\.id)) == [
                PageGroupID.startup, PageGroupID.menuBar, PageGroupID.generalBehavior,
                PageGroupID.pin, PageGroupID.backup
            ],
            "groups=\(SettingsSection.general.pageGroups.map(\.id))"
        )
        // 通用 no longer lists a 快捷键 group. The page itself is one card
        // per block, so its middle column lists those four blocks; every
        // bindable action belongs to exactly one of them.
        check(
            "settings: 快捷键 is one card per block, in four blocks",
            SettingsSection.hotkeys.pageGroups.map(\.id)
                == HotKeyGroup.allCases.map { PageGroupID.hotKeyGroup($0) }
                && SettingsSection.hotkeys.pageGroups.map(\.title)
                    == ["标注工具", "截图", "工具", "应用"],
            "groups=\(SettingsSection.hotkeys.pageGroups.map(\.id))"
        )
        // 2026-10-24 width pass, part two: every page now shares ONE middle
        // column. 历史记录/钉图 (292) and 截图 (272) used to differ from the
        // settings pages (260); the three cards visibly changed width when the
        // owner switched sections. The sidebar is frozen at 182 pt (the
        // owner's standing requirement) and the right pane is the flexible
        // remainder, so 182 / 260 / 538 at the owner's saved 1020 pt window is
        // the same on 通用, 快捷键, 截图 and 历史记录.
        let paneWidthAt1020: (CGFloat) -> CGFloat = { middle in
            1020 - 2 * MainColumnMetrics.outerPadding
                - MainColumnMetrics.navigation
                - 2 * MainColumnMetrics.gutter
                - middle
        }
        check(
            "settings: every page uses one 260 pt middle column (182 / 260 / 538)",
            MainColumnMetrics.navigation == 182
                && MainColumnMetrics.middle == 260
                && paneWidthAt1020(332) == 466
                && paneWidthAt1020(MainColumnMetrics.middle) == 538,
            "nav=\(MainColumnMetrics.navigation) middle=\(MainColumnMetrics.middle) "
                + "was=\(paneWidthAt1020(332)) now=\(paneWidthAt1020(MainColumnMetrics.middle))"
        )
        check(
            "settings: every bindable action sits in exactly one table block",
            HotKeyGroup.allCases.flatMap(\.members).count == HotKeyBindingID.allCases.count
                && Set(HotKeyGroup.allCases.flatMap(\.members)) == Set(HotKeyBindingID.allCases)
                && HotKeyBindingID.allCases.allSatisfy {
                    HotKeyGroup.group(of: $0).members.contains($0)
                },
            "members=" + HotKeyGroup.allCases
                .map { "\($0.rawValue):\($0.members.map(\.rawValue))" }
                .joined(separator: " ")
        )
        check(
            "settings: 通用 no longer carries a 快捷键 group",
            !SettingsSection.general.pageGroups.contains {
                $0.id == "hot-keys" || $0.title == "快捷键"
            },
            "groups=\(SettingsSection.general.pageGroups.map(\.id))"
        )
        let modePageGroups: [SettingsSection: Set<String>] = [
            .regionCapture: [
                PageGroupID.captureDefault, PageGroupID.regionHotKey,
                PageGroupID.regionBehavior, PageGroupID.screenshotOutput,
                PageGroupID.beautifyCapture
            ],
            .windowCapture: [PageGroupID.windowHotKey],
            .fixedSizeCapture: [PageGroupID.fixedSizePreset],
            .fullScreenCapture: [
                PageGroupID.fullScreenHotKey, PageGroupID.instantFeedback,
                PageGroupID.fullScreenDelay
            ]
        ]
        check(
            "settings: each capture mode page groups only its own settings",
            modePageGroups.allSatisfy { section, ids in
                Set(section.pageGroups.map(\.id)) == ids
            },
            "groups=\(modePageGroups.keys.map { "\($0.rawValue)=\($0.pageGroups.map(\.id))" })"
        )

        print("[settings] --- each page renders a GroupSlab ---")
        // Render every page offscreen with an isolated database home so the
        // harness never touches the user's history. The marker is a custom
        // NSView inside GroupSlab, so it is countable through SwiftUI's opaque
        // hosting hierarchy.
        let tempHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("unseen-settings-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        let previousHome = ProcessInfo.processInfo.environment["UNSEEN_HOME"]
        setenv("UNSEEN_HOME", tempHome.path, 1)
        let suiteName = "UnseenSettings-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            check("settings: create isolated defaults", false)
            return
        }
        let settings = AppSettings(defaults: defaults)
        let model = AppModel(settings: settings)
        model.stopMonitoring()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            if let previousHome {
                setenv("UNSEEN_HOME", previousHome, 1)
            } else {
                unsetenv("UNSEEN_HOME")
            }
            try? FileManager.default.removeItem(at: tempHome)
        }

        var totalSlabs = 0
        for section in SettingsSection.allCases {
            guard let firstGroup = section.pageGroups.first else { continue }
            let root = SettingsView(model: model, section: section, groupID: firstGroup.id)
            let hosting = NSHostingView(rootView: root)
            hosting.frame = CGRect(x: 0, y: 0, width: 760, height: 620)
            hosting.appearance = NSAppearance(named: .darkAqua)
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            let slabs = countSubviews(of: GroupSlabMarkerView.self, in: hosting)
            totalSlabs += slabs
            if section == .hotkeys {
                // 快捷键 is a card page now, exactly like the other fifteen: the
                // middle column selects one block, the right pane draws its
                // GroupSlab and the block's two anchors per row.
                let anchors = countSubviews(of: HotKeyListColumnMarkerView.self, in: hosting)
                let rows = HotKeyGroup.annotationTools.members.count
                check(
                    "settings: 快捷键 draws the selected block as one GroupSlab card",
                    slabs == 1 && anchors == rows * 2,
                    "slabs=\(slabs) anchors=\(anchors) expected=\(rows * 2)"
                )
                continue
            }
            check(
                "settings: \(section.rawValue) page draws at least one GroupSlab",
                slabs >= 1,
                "group=\(firstGroup.id) slabs=\(slabs)"
            )
        }
        check(
            "settings: every settings page draws group slabs",
            totalSlabs >= SettingsSection.allCases.count,
            "slabs=\(totalSlabs) pages=\(SettingsSection.allCases.count)"
        )

        // 截图 → 截图 draws the selected mode's page *in full*: no group
        // filter, so every group of that page is on the right. This is the
        // "click a mode, see its own settings page" requirement, measured.
        for tool in CaptureToolMode.allCases {
            let full = SettingsView(
                model: model,
                section: tool.settingsSection,
                groupID: PageGroupID.none,
                action: SettingsPageAction(title: "开始截图", symbol: "camera.viewfinder") {}
            )
            let hosting = NSHostingView(rootView: full)
            hosting.frame = CGRect(x: 0, y: 0, width: 760, height: 900)
            hosting.appearance = NSAppearance(named: .darkAqua)
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            let slabs = countSubviews(of: GroupSlabMarkerView.self, in: hosting)
            check(
                "settings: 截图 → \(tool.title) draws all of its groups",
                slabs >= tool.settingsSection.pageGroups.count,
                "groups=\(tool.settingsSection.pageGroups.count) slabs=\(slabs)"
            )
        }

        // A page snapshot goes next to the other verification images.
        let snapshot = NSHostingView(
            rootView: SettingsView(
                model: model,
                section: .regionCapture,
                groupID: PageGroupID.screenshotOutput
            )
        )
        snapshot.frame = CGRect(x: 0, y: 0, width: 760, height: 620)
        snapshot.appearance = NSAppearance(named: .darkAqua)
        let canvas = TestCanvasView(frame: snapshot.frame)
        canvas.addSubview(snapshot)
        snapshot.layoutSubtreeIfNeeded()
        snapshot.displayIfNeeded()
        if let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) {
            canvas.cacheDisplay(in: canvas.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                let url = directory.appendingPathComponent("settings-screenshot-output.png")
                try? png.write(to: url)
                print("[settings] wrote \(url.path) (\(rep.pixelsWide)×\(rep.pixelsHigh) px)")
                check("settings: the 区域截图 page renders real pixels", png.count > 4_000,
                      "bytes=\(png.count)")
            }
        }

        // MARK: 菜单栏内容可自定义
        //
        // The status menu is now data: an ordered list of rows plus a hidden
        // set. These checks pin the default order, the pinned tail (设置 /
        // 退出), the sanitising that survives a hand-edited plist, and the
        // actual NSMenu the status item installs.
        print("[settings] --- status menu contents ---")
        check(
            "menu bar: the fourteen configurable rows keep a stable default order",
            MenuBarEntry.defaultOrder.count == 14
                && MenuBarEntry.defaultOrder == MenuBarEntry.allCases,
            "count=\(MenuBarEntry.defaultOrder.count)"
        )
        check(
            "menu bar: the four capture modes are rows, in region/window/preset/full order",
            MenuBarEntry.captureEntries.map(\.title)
                == ["区域截图", "窗口截图", "固定大小截图", "全屏截图"]
                && MenuBarEntry.allCases.contains(.captureRegion)
                && MenuBarEntry(rawValue: MenuBarEntry.legacyCaptureRawValue) == nil,
            "capture=\(MenuBarEntry.captureEntries.map(\.rawValue))"
        )
        check(
            "menu bar: a stored legacy capture row expands in place",
            Array(AppSettings.normalizedMenuBarOrder(["ocr", "capture", "scroll"]).prefix(6)) == [
                .ocr, .captureRegion, .captureWindow, .capturePreset,
                .captureFullScreen, .scroll
            ]
                && AppSettings.normalizedMenuBarOrder(["ocr", "capture", "scroll"]).count
                    == MenuBarEntry.allCases.count,
            "order=\(AppSettings.normalizedMenuBarOrder(["ocr", "capture", "scroll"]).map(\.rawValue))"
        )
        check(
            "menu bar: a stored legacy capture hidden row hides all four modes",
            AppSettings.normalizedMenuBarHidden(["capture", "camera"])
                == MenuBarEntry.captureEntries.map(\.rawValue) + ["camera"],
            "hidden=\(AppSettings.normalizedMenuBarHidden(["capture", "camera"]))"
        )
        check(
            "menu bar: 设置 and 退出 are the pinned tail",
            MenuBarEntry.pinned == [.settings, .quit]
                && MenuBarEntry.pinned.allSatisfy(\.isPinned),
            "pinned=\(MenuBarEntry.pinned.map(\.rawValue))"
        )
        check(
            "menu bar: no row title carries an ellipsis",
            MenuBarEntry.allCases.allSatisfy { !$0.title.contains("…") },
            "titles=\(MenuBarEntry.allCases.map(\.title))"
        )
        let scrambled = ["quit", "camera", "bogus", "camera", "settings"]
        let normalized = AppSettings.normalizedMenuBarOrder(scrambled)
        check(
            "menu bar: a scrambled stored order is filled, deduped and pinned",
            normalized.count == MenuBarEntry.allCases.count
                && normalized.first == .camera
                && Array(normalized.suffix(2)) == [.settings, .quit]
                && Set(normalized).count == normalized.count,
            "order=\(normalized.map(\.rawValue))"
        )
        let filteredHidden = AppSettings.normalizedMenuBarHidden(
            ["camera", "quit", "settings", "camera", "bogus"]
        )
        check(
            "menu bar: pinned rows survive a hand-edited hidden list",
            filteredHidden == ["camera"],
            "hidden=\(filteredHidden)"
        )

        // The arrow buttons and the drag handle share one implementation, so
        // the ordering rules are testable without synthesising a drag.
        settings.menuBarItemOrder = MenuBarEntry.defaultOrder.map(\.rawValue)
        settings.moveMenuBarEntry(.camera, offset: -1)
        check(
            "menu bar: the arrow buttons swap two adjacent rows",
            Array(settings.menuBarOrderValue.prefix(11)) == [
                .openClipboard, .captureRegion, .captureWindow, .capturePreset,
                .captureFullScreen, .ocr, .scroll, .recording, .colorPicker,
                .camera, .keyDisplay
            ],
            "order=\(settings.menuBarOrderValue.map(\.rawValue))"
        )
        settings.menuBarItemOrder = MenuBarEntry.defaultOrder.map(\.rawValue)
        settings.moveMenuBarEntry(.recording, before: .ocr)
        check(
            "menu bar: dragging a row before another moves it there",
            Array(settings.menuBarOrderValue.prefix(7)) == [
                .openClipboard, .captureRegion, .captureWindow, .capturePreset,
                .captureFullScreen, .recording, .ocr
            ],
            "order=\(settings.menuBarOrderValue.map(\.rawValue))"
        )
        let beforePinnedAttempt = settings.menuBarOrderValue
        settings.moveMenuBarEntry(.settings, offset: -1)
        settings.moveMenuBarEntry(.camera, before: .quit)
        check(
            "menu bar: pinned rows and the pinned tail cannot be moved",
            settings.menuBarOrderValue == beforePinnedAttempt
                && Array(settings.menuBarOrderValue.suffix(2)) == [.settings, .quit],
            "order=\(settings.menuBarOrderValue.map(\.rawValue))"
        )

        // The stored order deliberately still carries the legacy `capture`
        // token, so this also proves the upgrade path end to end: the four mode
        // rows appear at that exact position and nothing is a submenu.
        settings.menuBarItemOrder = [
            "recording", "openClipboard", "capture", "ocr", "scroll",
            "colorPicker", "keyDisplay", "camera", "about", "settings", "quit"
        ]
        settings.menuBarHiddenItems = ["camera", "colorPicker", "keyDisplay", "about"]
        let statusMenu = AppMenuBuilder.statusMenu(settings: settings, target: NSApp)
        let statusTitles = statusMenu.items.map(\.title)
        check(
            "menu bar: the status menu follows the stored order",
            statusTitles.first == "开始 / 停止录屏",
            "titles=\(statusTitles)"
        )
        check(
            "menu bar: the legacy capture row expands to four flat items",
            Array(statusTitles.dropFirst(2).prefix(4))
                == ["区域截图", "窗口截图", "固定大小截图", "全屏截图"]
                && statusMenu.items.allSatisfy { $0.submenu == nil }
                && !statusTitles.contains("截图"),
            "titles=\(statusTitles)"
        )
        check(
            "menu bar: hidden rows are absent from the status menu",
            !statusTitles.contains("取色") && !statusTitles.contains("按键显示")
                && !statusTitles.contains("摄像头画中画") && !statusTitles.contains("关于"),
            "titles=\(statusTitles)"
        )
        check(
            "menu bar: 设置 and 退出 stay visible at the tail",
            statusTitles.contains("设置") && statusTitles.last == "退出",
            "titles=\(statusTitles)"
        )

        let settingsTitleIndex = statusMenu.items.firstIndex { $0.title == "设置" }
        check(
            "menu bar: one divider separates the feature rows from the utility tail",
            statusMenu.items.filter(\.isSeparatorItem).count == 1
                && settingsTitleIndex.map {
                    $0 > 0 && statusMenu.items[$0 - 1].isSeparatorItem
                } == true,
            "titles=\(statusTitles)"
        )
        check(
            "menu bar: no status item title carries an ellipsis",
            statusTitles.allSatisfy { !$0.contains("…") },
            "titles=\(statusTitles)"
        )

        let menuBarExport = settings.exportPreferences()
        check(
            "menu bar: the configuration is part of the preference backup",
            menuBarExport[AppSettings.Key.menuBarItemOrder] != nil
                && menuBarExport[AppSettings.Key.menuBarHiddenItems] != nil,
            "keys=\(menuBarExport.keys.sorted())"
        )

        // MARK: 菜单栏行可重命名
        //
        // A custom label is a *status-menu* label only. It is stored beside the
        // order/hidden list, trimmed, and blank falls back to the canonical
        // title, so the settings rows stay recognisable while the menu reads
        // whatever the user typed.
        print("[settings] --- status menu custom names ---")
        settings.setMenuBarTitle("  我的截图  ", for: .captureRegion)
        settings.setMenuBarTitle("工作台", for: .settings)
        settings.setMenuBarTitle("收工", for: .quit)
        settings.setMenuBarTitle("   ", for: .ocr)
        check(
            "menu bar: custom names are trimmed and blanks mean default",
            settings.menuBarTitle(for: .captureRegion) == "我的截图"
                && settings.menuBarTitle(for: .settings) == "工作台"
                && settings.menuBarTitle(for: .quit) == "收工"
                && settings.menuBarTitle(for: .ocr) == MenuBarEntry.ocr.title
                && settings.menuBarCustomTitles["ocr"] == nil,
            "custom=\(settings.menuBarCustomTitles) "
                + "region=\(settings.menuBarTitle(for: .captureRegion)) "
                + "ocr=\(settings.menuBarTitle(for: .ocr))"
        )
        check(
            "menu bar: renaming leaves the settings row titles canonical",
            MenuBarEntry.captureRegion.title == "区域截图"
                && MenuBarEntry.captureWindow.title == "窗口截图"
                && MenuBarEntry.capturePreset.title == "固定大小截图"
                && MenuBarEntry.captureFullScreen.title == "全屏截图"
                && MenuBarEntry.settings.title == "设置"
                && MenuBarEntry.quit.title == "退出"
                && settings.menuBarTitle(for: .captureRegion) != MenuBarEntry.captureRegion.title,
            "rows=\(MenuBarEntry.allCases.map(\.title))"
        )
        let renamedMenu = AppMenuBuilder.statusMenu(settings: settings, target: NSApp)
        let renamedTitles = renamedMenu.items.map(\.title)
        check(
            "menu bar: custom names reach the status menu including pinned rows",
            renamedTitles.contains("我的截图")
                && renamedTitles.contains("工作台")
                && renamedTitles.last == "收工"
                && renamedTitles.contains(MenuBarEntry.quit.title) == false,
            "titles=\(renamedTitles)"
        )
        // 设置 / 退出 cannot be hidden, but they can be renamed: the row is
        // still the recovery entry even when its label changed.
        check(
            "menu bar: renamed pinned rows stay visible and last",
            settings.isMenuBarEntryHidden(.settings) == false
                && settings.menuBarOrderValue.suffix(2) == [.settings, .quit]
                && renamedTitles.last == "收工",
            "titles=\(renamedTitles) order=\(settings.menuBarOrderValue.map(\.rawValue))"
        )
        let reloadedSettings = AppSettings(defaults: defaults)
        check(
            "menu bar: custom names persist with the preferences",
            reloadedSettings.menuBarTitle(for: .captureRegion) == "我的截图"
                && reloadedSettings.menuBarTitle(for: .quit) == "收工",
            "custom=\(reloadedSettings.menuBarCustomTitles)"
        )
        let namedExport = settings.exportPreferences()
        check(
            "menu bar: custom names are part of the preference backup",
            (namedExport[AppSettings.Key.menuBarCustomTitles] as? [String: Any])?["captureRegion"]
                as? String == "我的截图",
            "value=\(String(describing: namedExport[AppSettings.Key.menuBarCustomTitles]))"
        )
        check(
            "menu bar: unknown or blank custom names are dropped",
            AppSettings.normalizedMenuBarCustomTitles([
                "captureRegion": " 我的截图 ",
                "bogus": "x",
                "ocr": "   "
            ]) == ["captureRegion": "我的截图"]
        )
        check(
            "menu bar: a legacy capture rename is dropped, not copied to four rows",
            AppSettings.normalizedMenuBarCustomTitles(["capture": "我的截图"]).isEmpty
                && AppSettings.normalizedMenuBarCustomTitles(["captureRegion": "区域"]).count == 1
        )

        settings.resetAll()
        check(
            "menu bar: reset restores every row, ships no custom names, and hides none",
            settings.menuBarOrderValue == MenuBarEntry.defaultOrder
                && settings.menuBarHiddenSet.isEmpty
                && settings.menuBarCustomTitles
                    == AppSettings.defaultMenuBarCustomTitles
                && settings.menuBarCustomTitles.isEmpty
                && settings.menuBarTitle(for: .ocr) == MenuBarEntry.ocr.title
                && settings.menuBarTitle(for: .openClipboard) == MenuBarEntry.openClipboard.title,
            "order=\(settings.menuBarOrderValue.map(\.rawValue)) "
                + "hidden=\(settings.menuBarHiddenItems) "
                + "names=\(settings.menuBarCustomTitles)"
        )

        // MARK: 统一的快捷键位
        //
        // One recorder component serves every bindable row. Its four states are
        // expressible because an unbound slot is a meaningful value, and two
        // enabled rows sharing a combination are detectable before Carbon
        // registration even runs.
        print("[settings] --- unified hotkey slots ---")
        check(
            "hotkeys: all thirty bindable actions are enumerated",
            HotKeyBindingID.allCases.count == 30,
            "count=\(HotKeyBindingID.allCases.count)"
        )
        check(
            "hotkeys: the overview titles match the requested rows",
            HotKeyBindingID.allCases.map(\.title) == [
                "移动", "箭头", "矩形", "椭圆", "直线", "铅笔",
                "荧光笔", "马赛克", "文字", "便签", "序号", "贴纸",
                "区域截图", "窗口截图", "固定大小截图", "全屏截图",
                "即时窗口", "即时全屏", "长截图", "套壳·美化",
                "OCR", "取色", "按键显示", "录屏",
                "打开面板", "钉图", "延时截图", "多窗口截图",
                "摄像头画中画", "打开设置"
            ],
            "titles=\(HotKeyBindingID.allCases.map(\.title))"
        )
        check(
            "hotkeys: every slot id is stable and unique",
            Set(HotKeyBindingID.allCases.map(\.rawValue)).count == 30,
            "ids=\(HotKeyBindingID.allCases.map(\.rawValue))"
        )
        check(
            "hotkeys: an empty modifier mask is still the unbound placeholder",
            !HotKeyConfiguration.unbound.isBound
                && HotKeyConfiguration.ocr == .unbound
                && HotKeyConfiguration.unbound == HotKeyConfiguration(keyCode: 0, modifiers: 0),
            "unbound=\(HotKeyConfiguration.unbound)"
        )
        // 2026-10-23: the shipped defaults are the owner's exported preference
        // file (`Unseen-Preferences.plist`), so a fresh preference
        // domain opens with nine bound slots and the same four unbound ones.
        // Reading them back through the isolated `AppSettings` proves the
        // registration defaults, not just the named constants.
        let shippedSlots: [(String, Bool, HotKeyConfiguration, HotKeyConfiguration)] =
            HotKeyBindingID.allCases.map { id in
                let state = settings.hotKeyState(id)
                let expected: HotKeyConfiguration
                if let tool = id.annotationTool {
                    expected = .annotationTool(tool)
                } else {
                    switch id {
                    case .openPanel: expected = .default
                    case .pin: expected = .pinLastImage
                    case .region: expected = .screenshot
                    case .window: expected = .windowCapture
                    case .capturePreset: expected = .capturePreset
                    case .fullScreen: expected = .fullScreenCapture
                    case .instantWindow: expected = .instantWindow
                    case .instantFullScreen: expected = .instantFullScreen
                    case .scroll: expected = .scroll
                    case .beautify: expected = .beautify
                    case .ocr: expected = .ocr
                    case .colorPicker: expected = .colorPicker
                    case .keyDisplay: expected = .unbound
                    case .record: expected = .record
                    case .delayCapture: expected = .delayCapture
                    case .multiWindow: expected = .multiWindowCapture
                    case .camera: expected = .cameraOverlay
                    case .openSettings: expected = .openSettings
                    case .toolMove, .toolArrow, .toolRectangle, .toolEllipse,
                         .toolLine, .toolPencil, .toolHighlighter, .toolMosaic,
                         .toolText, .toolNote, .toolCounter, .toolSticker:
                        preconditionFailure("annotation tools handled above")
                    }
                }
                return (id.title, state.enabled, state.configuration, expected)
            }
        check(
            "hotkeys: a fresh preference domain ships nine globals plus twelve tool keys",
            shippedSlots.allSatisfy { $0.1 && $0.2 == $0.3 }
                && shippedSlots.filter { $0.2.isBound }.count == 24
                && shippedSlots.filter { !$0.2.isBound }.count == 6,
            "slots=\(shippedSlots.map { "\($0.0)=\($0.2.isBound ? $0.2.displayString : "-")" })"
        )
        let shippedBindings = shippedSlots.map {
            HotKeyBinding(id: $0.0, title: $0.0, configuration: $0.2, isEnabled: $0.1)
        }
        check(
            "hotkeys: the shipped bindings never collide with each other",
            HotKeyConflicts.conflictingIDs(in: shippedBindings).isEmpty,
            "conflicts=\(HotKeyConflicts.conflictingIDs(in: shippedBindings).sorted())"
        )
        let boundProbe = HotKeyConfiguration(
            keyCode: UInt32(kVK_ANSI_P),
            modifiers: UInt32(optionKey | cmdKey)
        )
        check(
            "hotkeys: unbound and disabled configurations never reach Carbon",
            AppSettings.registeredConfiguration(
                enabled: true,
                HotKeyConfiguration.unbound
            ) == nil
                && AppSettings.registeredConfiguration(
                    enabled: false,
                    boundProbe
                ) == nil
                && AppSettings.registeredConfiguration(
                    enabled: true,
                    boundProbe
                ) == boundProbe,
            "unbound=\(String(describing: AppSettings.registeredConfiguration(enabled: true, HotKeyConfiguration.unbound)))"
        )

        // Duplicate detection: region and beautify share a combo (both warn);
        // scroll is disabled so it must not collide with record; pin is unbound.
        // The probe binds explicit combinations so it does not depend on the
        // shipped preference values.
        let duplicate = HotKeyConfiguration(keyCode: 12, modifiers: UInt32(optionKey | cmdKey))
        let unique = HotKeyConfiguration(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(optionKey | cmdKey))
        let conflictBindings = [
            HotKeyBinding(id: "region", title: "区域截图", configuration: duplicate, isEnabled: true),
            HotKeyBinding(id: "beautify", title: "套壳·美化", configuration: duplicate, isEnabled: true),
            HotKeyBinding(id: "scroll", title: "长截图", configuration: unique, isEnabled: false),
            HotKeyBinding(id: "record", title: "录屏", configuration: unique, isEnabled: true),
            HotKeyBinding(id: "pin", title: "钉图", configuration: .unbound, isEnabled: true)
        ]
        check(
            "hotkeys: only the two enabled duplicates are marked as conflicts",
            HotKeyConflicts.conflictingIDs(in: conflictBindings) == ["region", "beautify"],
            "ids=\(HotKeyConflicts.conflictingIDs(in: conflictBindings).sorted())"
        )
        check(
            "hotkeys: the conflict label names the other row",
            HotKeyConflicts.duplicateLabel(for: "region", among: conflictBindings)
                == "与「套壳·美化」重复",
            "label=\(HotKeyConflicts.duplicateLabel(for: "region", among: conflictBindings) ?? "nil")"
        )
        check(
            "hotkeys: a disabled duplicate and an unbound row are not conflicts",
            HotKeyConflicts.duplicateLabel(for: "scroll", among: conflictBindings) == nil
                && HotKeyConflicts.duplicateLabel(for: "pin", among: conflictBindings) == nil
                && HotKeyConflicts.duplicateLabel(for: "record", among: conflictBindings) == nil,
            "scroll=\(HotKeyConflicts.duplicateLabel(for: "scroll", among: conflictBindings) ?? "nil") "
                + "pin=\(HotKeyConflicts.duplicateLabel(for: "pin", among: conflictBindings) ?? "nil")"
        )

        let hotKeyExport = settings.exportPreferences()
        check(
            "hotkeys: the new bindings are part of the preference backup",
            hotKeyExport[AppSettings.Key.windowHotKeyEnabled] != nil
                && hotKeyExport[AppSettings.Key.windowHotKeyModifiers] != nil
                && hotKeyExport[AppSettings.Key.fullScreenHotKeyKeyCode] != nil
                && hotKeyExport[AppSettings.Key.keyDisplayHotKeyModifiers] != nil
                && hotKeyExport[AppSettings.Key.annotationToolHotKeys] != nil
                && hotKeyExport[AppSettings.Key.capturePresetHotKeyKeyCode] != nil
                && hotKeyExport[AppSettings.Key.delayCaptureHotKeyKeyCode] != nil
                && hotKeyExport[AppSettings.Key.multiWindowHotKeyKeyCode] != nil
                && hotKeyExport[AppSettings.Key.cameraHotKeyModifiers] != nil
                && hotKeyExport[AppSettings.Key.openSettingsHotKeyKeyCode] != nil,
            "keys=\(hotKeyExport.keys.sorted())"
        )

        // 标注工具键位 must travel with the same 导出 / 导入 / 重置 paths as
        // every other preference.
        let toolBackupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("unseen-tool-keys-\(UUID().uuidString).plist")
        do {
            settings.setAnnotationToolConfiguration(.unbound, for: .arrow)
            try settings.writePreferences(to: toolBackupURL)
            settings.setAnnotationToolConfiguration(
                HotKeyConfiguration.annotationTool(.arrow),
                for: .arrow
            )
            try settings.readPreferences(from: toolBackupURL)
        } catch {
            check("hotkeys: 标注工具 导出 / 导入 round trip", false, "\(error)")
            try? FileManager.default.removeItem(at: toolBackupURL)
            return
        }
        check(
            "hotkeys: 标注工具 导出 / 导入 carries an unbound tool slot",
            !settings.annotationToolConfiguration(.arrow).isBound,
            "config=\(settings.annotationToolConfiguration(.arrow).displayString)"
        )
        try? FileManager.default.removeItem(at: toolBackupURL)

        settings.resetAll()
        check(
            "hotkeys: 重置全部设置 restores every 标注工具 default",
            settings.annotationToolConfiguration(.arrow)
                == HotKeyConfiguration.annotationTool(.arrow)
                && settings.annotationToolConfiguration(.sticker)
                    == HotKeyConfiguration.annotationTool(.sticker)
                && settings.capturePresetHotKeyConfiguration == .capturePreset
                && settings.cameraHotKeyConfiguration == .cameraOverlay,
            "arrow=\(settings.annotationToolConfiguration(.arrow).displayString) "
                + "sticker=\(settings.annotationToolConfiguration(.sticker).displayString)"
        )

        // 系统 → 快捷键 draws the middle column's *selection* as one card,
        // even though the same bindings also live on their feature pages. The
        // page keeps the three-column shape, so a group id really narrows the
        // right pane instead of being ignored.
        func hotKeyAnchors(for group: HotKeyGroup?) -> Int {
            let hosting = NSHostingView(
                rootView: SettingsView(
                    model: model,
                    section: .hotkeys,
                    groupID: group.map(PageGroupID.hotKeyGroup) ?? PageGroupID.none
                )
            )
            hosting.frame = CGRect(x: 0, y: 0, width: 760, height: 900)
            hosting.appearance = NSAppearance(named: .darkAqua)
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            return countSubviews(of: HotKeyListColumnMarkerView.self, in: hosting)
        }
        let captureAnchors = hotKeyAnchors(for: .capture)
        check(
            "hotkeys: 系统 → 快捷键 draws the selected block, not the whole page",
            captureAnchors == HotKeyGroup.capture.members.count * 2,
            "anchors=\(captureAnchors) expected=\(HotKeyGroup.capture.members.count * 2)"
        )
        let toolsAnchors = hotKeyAnchors(for: .tools)
        check(
            "hotkeys: switching the middle column swaps the right pane's block",
            toolsAnchors == HotKeyGroup.tools.members.count * 2
                && toolsAnchors != captureAnchors,
            "tools=\(toolsAnchors) capture=\(captureAnchors)"
        )
        let allAnchors = hotKeyAnchors(for: nil)
        check(
            "hotkeys: with no selection the page still draws all thirty rows",
            allAnchors == HotKeyBindingID.allCases.count * 2,
            "anchors=\(allAnchors) expected=\(HotKeyBindingID.allCases.count * 2)"
        )
    }

    // MARK: - Hover feedback for interactive rows

    /// The settings page used to answer only clicks: the left column, the
    /// middle column's page groups and the settings slab had no pointer
    /// feedback at all. This group proves the shared `HoverHighlight` modifier
    /// really paints a wash, that the wash is fainter than selection, that a
    /// selected row does not stack it, and that a disabled row never shows it.
    ///
    /// The proof is a render, not a constant: the same probe row is drawn with
    /// the hover state pinned off and on, and the pixels are diffed.
    // MARK: - 面板：钉住

    /// 钉住面板 is transient state on the model, not a preference: it must be
    /// off on a fresh model and reset every time the panel opens. The resign-key
    /// rule itself is a pure function so no window is needed here.
    private static func runPanelPinTests() {
        let tempHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("unseen-pin-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        let previousHome = ProcessInfo.processInfo.environment["UNSEEN_HOME"]
        setenv("UNSEEN_HOME", tempHome.path, 1)
        let suiteName = "UnseenPin-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            check("panel-pin: create isolated defaults", false)
            return
        }
        let settings = AppSettings(defaults: defaults)
        let model = AppModel(settings: settings)
        model.stopMonitoring()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            if let previousHome {
                setenv("UNSEEN_HOME", previousHome, 1)
            } else {
                unsetenv("UNSEEN_HOME")
            }
            try? FileManager.default.removeItem(at: tempHome)
        }

        check("panel-pin: a fresh session is not pinned", !model.panelPinned)
        check(
            "panel-pin: losing key focus closes an unpinned panel",
            PanelController.hidesOnResignKey(panelPinned: false)
        )
        check(
            "panel-pin: losing key focus keeps a pinned panel",
            !PanelController.hidesOnResignKey(panelPinned: true)
        )
        model.panelPinned = true
        check("panel-pin: the toggle latches on the model", model.panelPinned)
        model.prepareForPresentation()
        check(
            "panel-pin: every presentation starts unpinned",
            !model.panelPinned,
            "pinned=\(model.panelPinned)"
        )
        // The reason it is not persisted: a reset must not write a preference.
        check(
            "panel-pin: the state is not written to UserDefaults",
            defaults.object(forKey: "panelPinned") == nil,
            "stored=\(String(describing: defaults.object(forKey: "panelPinned")))"
        )
    }

    private static func runPinToolbarTests() {
        print("[pin-toolbar] --- one plate, bare glyphs, hover feedback only ---")
        check(
            "pin-toolbar: every glyph is bare at rest",
            PinToolbarSurface.restingFill == 0 && PinToolbarSurface.restingStroke == 0,
            "fill=\(PinToolbarSurface.restingFill) stroke=\(PinToolbarSurface.restingStroke)"
        )
        // The `%` chips and the glyphs are literally the same hover layer
        // (`PinHoverHighlight`, 11 pt corner), so there is only one
        // resting/hover tier left to pin — the chips have no private ink.
        check(
            "pin-toolbar: the % chips draw nothing at rest too",
            PinToolbarSurface.restingFill == 0
                && PinToolbarSurface.restingStroke == 0
                && PinToolbarSurface.hoverCornerRadius == 11,
            "fill=\(PinToolbarSurface.restingFill) "
                + "stroke=\(PinToolbarSurface.restingStroke) "
                + "radius=\(PinToolbarSurface.hoverCornerRadius)"
        )
        // 2026-10-25 (third pass, and the reason for the numbers below): the
        // owner rejected the original hover twice. `Color.primary.opacity(0.20)`
        // is *black* in 浅色, so it subtracted light and read as a grey shadow —
        // that is the "好丑". The system's clear glass that replaced it still
        // stacked a second material and rim light on this small plate — the
        // "有点丑". `.primary` was the wrong channel all along: a highlight has
        // to **add** light. White does that in both appearances, and this is the
        // recipe.
        check(
            "pin-toolbar: hover is a white lift, not the primary ink",
            PinToolbarSurface.hoverIsWhite
                && !PinToolbarSurface.hoverUsesInk
                && PinToolbarSurface.hoverFill >= 0.20
                && PinToolbarSurface.hoverFill <= 0.28
                && PinToolbarSurface.hoverStroke >= 0.10
                && PinToolbarSurface.hoverStroke <= 0.15
                && PinToolbarSurface.hoverCornerRadius == 11
                && !PinToolbarSurface.hoverHasShadow,
            "fill=\(PinToolbarSurface.hoverFill) stroke=\(PinToolbarSurface.hoverStroke) "
                + "radius=\(PinToolbarSurface.hoverCornerRadius) "
                + "white=\(PinToolbarSurface.hoverIsWhite) "
                + "shadow=\(PinToolbarSurface.hoverHasShadow)"
        )

        // Rendered proof, without a window server: the real `PinHoverHighlight`
        // over the plate colours measured on the live pin (浅色 139, 深色 116 —
        // 0.55 / 0.45 grey). Three things are asserted off the same two frames:
        //
        // * the chip makes the region **brighter** (the shadow bug cannot pass);
        // * all three channels rise by the same amount (a white lift, not a tint);
        // * nothing outside the chip changes (no shadow, and a 1 pt hairline, not
        //   a glow).
        func renderPinHoverProbe(scheme: ColorScheme, plateGrey: Double) -> CGImage? {
            let probeSize = CGSize(width: 64, height: 40)
            let root = ZStack {
                Color(white: plateGrey)
                PinHoverHighlight()
                    .frame(width: 22, height: 22)
            }
            .frame(width: probeSize.width, height: probeSize.height)
            .environment(\.colorScheme, scheme)
            let hosting = NSHostingView(rootView: root)
            hosting.frame = CGRect(origin: .zero, size: probeSize)
            hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
            else { return nil }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            return rep.cgImage
        }
        /// The plate alone, so the lift is a difference of two real renders.
        func renderPinPlateOnly(scheme: ColorScheme, plateGrey: Double) -> CGImage? {
            let plateRoot = ZStack { Color(white: plateGrey) }
                .frame(width: 64, height: 40)
                .environment(\.colorScheme, scheme)
            let hosting = NSHostingView(rootView: plateRoot)
            hosting.frame = CGRect(origin: .zero, size: CGSize(width: 64, height: 40))
            hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
            else { return nil }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            return rep.cgImage
        }
        /// Brightest pixel inside the chip's 22 pt box: the white hairline.
        ///
        /// The capture is Retina (2×), so the 22 pt chip is 44 px wide and the
        /// box has to be expressed in capture pixels.
        func brightestPixel(_ image: CGImage) -> (r: Int, g: Int, b: Int)? {
            guard let buffer = pixelBuffer(image) else { return nil }
            let scale = Double(buffer.width) / 64
            var best = (r: 0, g: 0, b: 0)
            var bestLuma = -1.0
            let box = CGRect(
                x: (32 - 11) * scale,
                y: (20 - 11) * scale,
                width: 22 * scale,
                height: 22 * scale
            )
            for y in Int(box.minY)..<Int(box.maxY) {
                for x in Int(box.minX)..<Int(box.maxX) {
                    let pixel = buffer.rgb(x: x, y: y)
                    let luma = 0.2126 * Double(pixel.0)
                        + 0.7152 * Double(pixel.1)
                        + 0.0722 * Double(pixel.2)
                    if luma > bestLuma {
                        bestLuma = luma
                        best = (pixel.0, pixel.1, pixel.2)
                    }
                }
            }
            return best
        }
        let hoverProbes: [(label: String, scheme: ColorScheme, plate: Double)] = [
            ("light", .light, 0.55),
            ("dark", .dark, 0.45),
        ]
        for probe in hoverProbes {
            let plain = renderPinPlateOnly(scheme: probe.scheme, plateGrey: probe.plate)
            let lit = renderPinHoverProbe(scheme: probe.scheme, plateGrey: probe.plate)
            guard let plain, let lit,
                  let plainBuffer = pixelBuffer(plain),
                  let litBuffer = pixelBuffer(lit)
            else {
                check("pin-toolbar (\(probe.label)): the hover probe renders", false)
                continue
            }
            let centre = (x: plainBuffer.width / 2, y: plainBuffer.height / 2)
            let rest = plainBuffer.rgb(x: centre.x, y: centre.y)
            let hover = litBuffer.rgb(x: centre.x, y: centre.y)
            let lift = (
                r: Double(hover.0 - rest.0),
                g: Double(hover.1 - rest.1),
                b: Double(hover.2 - rest.2)
            )
            // The channel spread is what separates a white lift from a tinted
            // one: an equal lift on R, G and B cannot come from `.primary`
            // (which is grey) or from a wash with any hue.
            check(
                "pin-toolbar (\(probe.label)): hover lifts every channel, white and even",
                lift.r >= 20 && lift.r <= 40
                    && lift.g >= 20 && lift.g <= 40
                    && lift.b >= 20 && lift.b <= 40
                    && abs(lift.r - lift.g) <= 2
                    && abs(lift.g - lift.b) <= 2,
                "rest=(\(rest.0),\(rest.1),\(rest.2)) "
                    + "hover=(\(hover.0),\(hover.1),\(hover.2)) "
                    + "lift=(\(Int(lift.r)),\(Int(lift.g)),\(Int(lift.b)))"
            )
            // Requirement 4, as a number: the hovered region is brighter than
            // the resting one. A shadow would fail here with a negative lift.
            check(
                "pin-toolbar (\(probe.label)): hover is brighter, never a shadow",
                lift.r > 0 && lift.g > 0 && lift.b > 0,
                "lift=(\(Int(lift.r)),\(Int(lift.g)),\(Int(lift.b)))"
            )
            // No shadow and no blur: 4 pt outside the chip the plate must be
            // byte-identical. The only edge treatment is the 1 pt white
            // hairline, and that is inside the chip. 15 pt from the centre is
            // 4 pt clear of the chip's 11 pt radius.
            let outside = (x: centre.x - Int((15 * Double(plainBuffer.width) / 64).rounded()), y: centre.y)
            let plainOutside = plainBuffer.rgb(x: outside.x, y: outside.y)
            let litOutside = litBuffer.rgb(x: outside.x, y: outside.y)
            check(
                "pin-toolbar (\(probe.label)): nothing spills outside the chip",
                abs(litOutside.0 - plainOutside.0) <= 1
                    && abs(litOutside.1 - plainOutside.1) <= 1
                    && abs(litOutside.2 - plainOutside.2) <= 1,
                "outside rest=(\(plainOutside.0),\(plainOutside.1),\(plainOutside.2)) "
                    + "hover=(\(litOutside.0),\(litOutside.1),\(litOutside.2))"
            )
            // The hairline really is painted, and it is *brighter* than the
            // fill: the brightest pixel in the chip's box must clear the centre.
            if let rim = brightestPixel(lit) {
                check(
                    "pin-toolbar (\(probe.label)): the white hairline edges the chip",
                    rim.r > hover.0 && rim.g > hover.1 && rim.b > hover.2,
                    "centre=(\(hover.0),\(hover.1),\(hover.2)) "
                        + "rim=(\(rim.r),\(rim.g),\(rim.b))"
                )
            } else {
                check("pin-toolbar (\(probe.label)): the white hairline edges the chip", false)
            }
        }
        check(
            "pin-toolbar: hover is still the only state that draws a shape",
            PinToolbarSurface.restingFill == 0
                && PinToolbarSurface.restingStroke == 0
                && PinToolbarSurface.hoverCornerRadius > 0,
            "resting=\(PinToolbarSurface.restingFill)/\(PinToolbarSurface.restingStroke)"
        )
        // The plate is the app's shared 液态玻璃 surface (`GlassStyle.swift`),
        // never a private fill. Two things have to stay true or the picture
        // stops showing through:
        //
        // * the tint is `liquidGlassTint`'s 20 % — the same wash as every other
        //   small glass surface, which is what makes this plate and the
        //   capture toolbar read as one material;
        // * the sampling mode is `.withinWindow`. The pin's picture is drawn
        //   inside the pin's own (transparent) panel, so `.behindWindow` blurs
        //   the desktop behind the panel and the picture never appears under
        //   the plate — the "glass over nothing" look that once drove this
        //   toolbar back to a solid slab.
        check(
            "pin-toolbar: the plate is the shared liquid-glass recipe",
            abs(PinToolbarSurface.plateAlpha - 0.20) < 0.0001
                && PinToolbarSurface.plateCornerRadius == 11,
            "alpha=\(PinToolbarSurface.plateAlpha) "
                + "radius=\(PinToolbarSurface.plateCornerRadius)"
        )
        check(
            "pin-toolbar: the plate samples inside the window, not the desktop",
            PinToolbarSurface.plateBlending == .withinWindow,
            "blending=\(PinToolbarSurface.plateBlending.rawValue)"
        )
        check(
            "pin-toolbar: the plate blurs with the app's own material",
            PinToolbarSurface.plateMaterial == .underWindowBackground,
            "material=\(PinToolbarSurface.plateMaterial.rawValue)"
        )
        // Factory proof, without a window server: the exact plate the view
        // installs really samples in-window content, carries the same 20 %
        // `liquidGlassTint` wash and — for the official glass only — the
        // legibility floor measured in `GlassWash.plateFloor`.
        let aqua = NSAppearance(named: .aqua) ?? NSAppearance(named: .darkAqua)!
        func makePinPlate(_ appearance: NSAppearance) -> NSView {
            GlassSurfaceFactory.makeBackdrop(
                cornerRadius: PinToolbarSurface.plateCornerRadius,
                style: .surface,
                plateAlpha: PinToolbarSurface.plateAlpha,
                offscreen: false,
                appearance: appearance,
                backgroundStyle: .liquidGlass,
                blending: PinToolbarSurface.plateBlending,
                material: PinToolbarSurface.plateMaterial
            )
        }
        let pinPlate = makePinPlate(aqua)
        if #available(macOS 26.0, *) {
            let glass = pinPlate.subviews.first as? NSGlassEffectView
            check(
                "pin-toolbar: the live plate is the app's own clear Liquid Glass",
                glass != nil
                    && glass?.style == .clear
                    && glass?.cornerRadius == PinToolbarSurface.plateCornerRadius,
                "class=\(pinPlate.subviews.first.map { String(describing: type(of: $0)) } ?? "nil") "
                    + "style=\(String(describing: glass?.style)) "
                    + "radius=\(String(describing: glass?.cornerRadius))"
            )
        } else {
            let blur = findSubview(NSVisualEffectView.self, in: pinPlate)
            check(
                "pin-toolbar: below macOS 26 the plate is the within-window material",
                pinPlate.subviews.first is NSVisualEffectView
                    && blur?.blendingMode == .withinWindow
                    && blur?.material == .underWindowBackground
                    && blur?.state == .active,
                "blending=\(blur?.blendingMode.rawValue ?? -1) "
                    + "material=\(blur?.material.rawValue ?? -1)"
            )
        }
        let pinWashAlphas = pinPlate.subviews.compactMap { $0.layer?.backgroundColor?.alpha }
        check(
            "pin-toolbar: the shared 20 % wash rides on the glass",
            pinWashAlphas.contains { abs($0 - PinToolbarSurface.plateAlpha) < 0.001 },
            "alphas=\(pinWashAlphas) subviews=\(pinPlate.subviews.count)"
        )
        check(
            "pin-toolbar: the legibility floor follows the appearance",
            abs(GlassWash.plateFloor(dark: false) - 0.42) < 0.0001
                && abs(GlassWash.plateFloor(dark: true) - 0.59) < 0.0001,
            "light=\(GlassWash.plateFloor(dark: false)) dark=\(GlassWash.plateFloor(dark: true))"
        )
        if #available(macOS 26.0, *) {
            // 浅色 gets the 0.42 white floor, 深色 the 0.59 near-black one, so
            // `.primary` ink stays readable over any picture.
            let lightAlphas = pinWashAlphas
            let darkAlphas = makePinPlate(NSAppearance(named: .darkAqua)!)
                .subviews.compactMap { $0.layer?.backgroundColor?.alpha }
            check(
                "pin-toolbar: the floor really is the appearance's window background",
                lightAlphas.contains { abs($0 - 0.42) < 0.001 }
                    && darkAlphas.contains { abs($0 - 0.59) < 0.001 },
                "light=\(lightAlphas) dark=\(darkAlphas)"
            )
        }
        // The flat recipe every other small surface uses must stay a single
        // layer: no glass, no floor, unchanged 20 % tint.
        let flatPlate = GlassSurfaceFactory.makeBackdrop(
            cornerRadius: PinToolbarSurface.plateCornerRadius,
            style: .surface,
            plateAlpha: PinToolbarSurface.plateAlpha,
            offscreen: false,
            appearance: aqua,
            backgroundStyle: .liquidGlass
        )
        check(
            "pin-toolbar: the flat in-window recipe is untouched",
            flatPlate.subviews.isEmpty
                && abs((flatPlate.layer?.backgroundColor?.alpha ?? -1) - 0.20) < 0.001,
            "subviews=\(flatPlate.subviews.count) "
                + "alpha=\(flatPlate.layer?.backgroundColor?.alpha ?? -1)"
        )
        // Rendered proof of the ink rule: with the resting ink at zero only the
        // plate shows, and hover adds exactly one disc. Rendered over the opaque
        // card the offscreen fallback paints (a material with no window server
        // composites black); the glyph ink is what this measures.
        let plateSize = CGSize(width: 64, height: 40)
        /// The plate with a glyph on top. `fill` / `stroke` are the only thing
        /// that changes between "bare" and "resting".
        ///
        /// The "hovered" variant lives in `runPinToolbarTests`' own probe (the
        /// white lift is plain SwiftUI, so it renders offscreen exactly as it
        /// ships); `runPinHoverHighlightTests` then proves it on a real window
        /// with a real pointer.
        func renderPinProbe(fill: Double?, stroke: Double?) -> CGImage? {
            let root = ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                if let fill, let stroke {
                    Circle()
                        .fill(Color.primary.opacity(fill))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(stroke), lineWidth: 1))
                        .frame(width: 22, height: 22)
                }
            }
            .frame(width: plateSize.width, height: plateSize.height)
            .environment(\.colorScheme, .dark)
            let hosting = NSHostingView(rootView: root)
            hosting.frame = CGRect(origin: .zero, size: plateSize)
            hosting.appearance = NSAppearance(named: .darkAqua)
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
            else { return nil }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            return rep.cgImage
        }
        func centre(_ image: CGImage?) -> (r: Int, g: Int, b: Int, a: Int)? {
            image.flatMap { pixel($0, x: $0.width / 2, y: $0.height / 2) }
        }
        guard let plateOnly = centre(renderPinProbe(fill: nil, stroke: nil)),
              let rested = centre(renderPinProbe(
                  fill: PinToolbarSurface.restingFill,
                  stroke: PinToolbarSurface.restingStroke
              ))
        else {
            check("pin-toolbar: the plate probe renders", false)
            return
        }
        check(
            "pin-toolbar: a rested glyph draws nothing at all over the plate",
            abs(rested.r - plateOnly.r) <= 1
                && abs(rested.g - plateOnly.g) <= 1
                && abs(rested.b - plateOnly.b) <= 1,
            "plate=(\(plateOnly.r),\(plateOnly.g),\(plateOnly.b)) "
                + "rested=(\(rested.r),\(rested.g),\(rested.b))"
        )
    }

    // MARK: - The pin toolbar's hover, photographed with a real pointer

    /// One probe picture: a gradient with a faint grid on top.
    ///
    /// A flat fill cannot answer "does the hover layer sample the picture?", and
    /// an untextured gradient hides refraction at the layer's edge. `light` is a
    /// warm cream→orange picture, `dark` a near-black→deep-blue one: the two
    /// ends of what a user actually pins.
    private static func pinHoverProbePicture(light: Bool) -> NSImage? {
        let width = 720
        let height = 480
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let left = light
            ? NSColor(srgbRed: 0.98, green: 0.94, blue: 0.87, alpha: 1)
            : NSColor(srgbRed: 0.04, green: 0.05, blue: 0.08, alpha: 1)
        let right = light
            ? NSColor(srgbRed: 0.93, green: 0.53, blue: 0.26, alpha: 1)
            : NSColor(srgbRed: 0.08, green: 0.27, blue: 0.45, alpha: 1)
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [left.cgColor, right.cgColor] as CFArray,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: width, y: height),
                options: []
            )
        }
        context.setStrokeColor(
            NSColor(white: 1, alpha: light ? 0.55 : 0.12).cgColor
        )
        context.setLineWidth(1)
        for x in stride(from: 0, through: width, by: 24) {
            context.move(to: CGPoint(x: CGFloat(x) + 0.5, y: 0))
            context.addLine(to: CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(height)))
        }
        for y in stride(from: 0, through: height, by: 24) {
            context.move(to: CGPoint(x: 0, y: CGFloat(y) + 0.5))
            context.addLine(to: CGPoint(x: CGFloat(width), y: CGFloat(y) + 0.5))
        }
        context.strokePath()
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }

    // MARK: - The pin plate's legibility floor, measured over black and white

    /// What one legibility probe photographed: the plate's own colour and the
    /// brightest/darkest glyph pixel drawn on it.
    private struct PinPlateProbe {
        let plate: (r: Double, g: Double, b: Double)
        let ink: (r: Double, g: Double, b: Double)
    }

    /// A flat picture at one grey level, sized 3:2 like the probe panel so
    /// `.fit` leaves no letterbox for the desktop to show through.
    ///
    /// The hover probe's gradient cannot answer this question: its toolbar sits
    /// over the *orange* end, not the darkness the floor exists for. A black
    /// picture and a white one are the two extremes `GlassWash.plateFloor` is
    /// tuned against — and they are also the worst case for each ink colour, so
    /// a contrast measured here is a lower bound for every real picture.
    private static func pinPlateProbePicture(white: Double) -> NSImage? {
        let width = 750
        let height = 500
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(
            NSColor(srgbRed: white, green: white, blue: white, alpha: 1).cgColor
        )
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }

    /// WCAG 2.x relative luminance of an sRGB triple in 0…255.
    private static func wcagLuminance(_ colour: (r: Double, g: Double, b: Double)) -> Double {
        func channel(_ value: Double) -> Double {
            let s = min(1, max(0, value / 255))
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(colour.r) + 0.7152 * channel(colour.g) + 0.0722 * channel(colour.b)
    }

    /// WCAG contrast ratio between two sRGB colours — the number the owner's
    /// 4.5:1 requirement is expressed in.
    private static func wcagContrast(
        _ first: (r: Double, g: Double, b: Double),
        _ second: (r: Double, g: Double, b: Double)
    ) -> Double {
        let a = wcagLuminance(first)
        let b = wcagLuminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Median per channel over a capture-pixel rectangle.
    ///
    /// Median, not mean: the plate is asked for its *background* colour while
    /// six glyphs and two chips sit on it. Ink is a small minority of the plate,
    /// so it cannot move the median, while a mean would read a few levels dark
    /// in 浅色 and bright in 深色 exactly where the answer matters most.
    private static func medianColour(
        in buffer: PixelBuffer,
        rect: CGRect
    ) -> (r: Double, g: Double, b: Double)? {
        let x0 = max(0, Int(rect.minX.rounded(.down)))
        let y0 = max(0, Int(rect.minY.rounded(.down)))
        let x1 = min(buffer.width, Int(rect.maxX.rounded(.up)))
        let y1 = min(buffer.height, Int(rect.maxY.rounded(.up)))
        guard x1 > x0, y1 > y0 else { return nil }
        var red = [Int]()
        var green = [Int]()
        var blue = [Int]()
        red.reserveCapacity((x1 - x0) * (y1 - y0))
        green.reserveCapacity((x1 - x0) * (y1 - y0))
        blue.reserveCapacity((x1 - x0) * (y1 - y0))
        for y in y0..<y1 {
            for x in x0..<x1 {
                let pixel = buffer.rgb(x: x, y: y)
                red.append(pixel.0)
                green.append(pixel.1)
                blue.append(pixel.2)
            }
        }
        return (
            Double(red.sorted()[red.count / 2]),
            Double(green.sorted()[green.count / 2]),
            Double(blue.sorted()[blue.count / 2])
        )
    }

    /// The darkest (or brightest) pixel inside a capture-pixel rectangle: the
    /// glyph's rendered ink, antialiasing and resting opacity included.
    private static func inkExtreme(
        in buffer: PixelBuffer,
        rect: CGRect,
        brightest: Bool
    ) -> (r: Double, g: Double, b: Double)? {
        let x0 = max(0, Int(rect.minX.rounded(.down)))
        let y0 = max(0, Int(rect.minY.rounded(.down)))
        let x1 = min(buffer.width, Int(rect.maxX.rounded(.up)))
        let y1 = min(buffer.height, Int(rect.maxY.rounded(.up)))
        guard x1 > x0, y1 > y0 else { return nil }
        var best = brightest ? -1.0 : 256.0
        var colour: (r: Double, g: Double, b: Double)?
        for y in y0..<y1 {
            for x in x0..<x1 {
                let pixel = buffer.rgb(x: x, y: y)
                let luma = pinHoverLuma((
                    Double(pixel.0),
                    Double(pixel.1),
                    Double(pixel.2)
                ))
                if brightest ? luma > best : luma < best {
                    best = luma
                    colour = (Double(pixel.0), Double(pixel.1), Double(pixel.2))
                }
            }
        }
        return colour
    }

    /// The legibility floor, measured on the real plate over a black and a white
    /// picture in both appearances.
    ///
    /// The floor exists for one reason: `.primary` ink has to stay readable over
    /// *any* pinned picture, and the owner asked for a brighter plate. Those two
    /// pull in opposite directions, so the floor may only be lowered to the point
    /// where the worst case is still 4.5:1 — the numbers below are that boundary,
    /// not an opinion. The ink used for the ratio is `.primary` itself (black in
    /// 浅色, white in 深色), matching the 6.0 / 5.0 the previous values were
    /// justified with; the rendered glyph pixel is printed beside it so the
    /// 0.85 resting opacity cannot hide inside the claim.
    private static func runPinPlateLegibilityTests(into directory: URL) async {
        print("[pin-plate] --- the floor over a black and a white picture ---")
        guard ScreenCapture.hasScreenRecordingPermission else {
            print("[pin-plate] SKIP: no screen-recording permission")
            return
        }

        let savedAppearance = NSApp.appearance
        let savedPointer = NSEvent.mouseLocation
        NSApp.activate(ignoringOtherApps: true)
        defer {
            NSApp.appearance = savedAppearance
            pinHoverMovePointer(to: savedPointer)
        }

        let panelSize = CGSize(width: 375, height: 250)
        let platePadding: CGFloat = 4
        let glyphSide: CGFloat = 22
        let glyphGap: CGFloat = 3
        let glyphTwoInset = platePadding + glyphSide + glyphGap + glyphSide / 2

        func makePanel(
            white: Double,
            appearance: NSAppearance.Name
        ) -> (PinnedImagePanel, NSHostingView<PinnedImageView>)? {
            guard let image = pinPlateProbePicture(white: white) else { return nil }
            let visible = NSScreen.main?.visibleFrame
                ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            let origin = CGPoint(
                x: visible.midX - panelSize.width / 2,
                y: visible.midY - panelSize.height / 2
            )
            let panel = PinnedImagePanel(
                contentRect: CGRect(origin: origin, size: panelSize),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.animationBehavior = .none
            panel.appearance = NSAppearance(named: appearance)
            let state = PinPanelState(displaySize: panelSize, opacity: 1)
            panel.pinState = state
            let hosting = NSHostingView(rootView: PinnedImageView(
                image: image,
                state: state,
                onClose: {},
                onCopy: {},
                onSave: {},
                onOpacity: { _ in },
                onFitToActualSize: {}
            ))
            hosting.frame = CGRect(origin: .zero, size: panelSize)
            hosting.appearance = NSAppearance(named: appearance)
            panel.contentView = hosting
            panel.orderFrontRegardless()
            panel.makeKey()
            return (panel, hosting)
        }

        func probe(
            white: Double,
            appearance: NSAppearance.Name,
            label: String
        ) async -> PinPlateProbe? {
            // Park the pointer outside every probe window first: consecutive
            // probes open their panels at the same origin, and a pointer that is
            // already inside the new panel never generates the move its
            // tracking area needs to show the toolbar.
            pinHoverMovePointer(to: CGPoint(x: 40, y: 40))
            guard let (panel, hosting) = makePanel(white: white, appearance: appearance)
            else { return nil }
            defer {
                pinHoverMovePointer(to: CGPoint(x: 40, y: 40))
                panel.orderOut(nil)
                panel.close()
            }
            // The toolbar exists only while the image itself is hovered; the
            // pointer goes to the middle so no control is hovered and the plate
            // is photographed at rest.
            pinHoverMovePointer(to: CGPoint(x: panel.frame.midX, y: panel.frame.midY))
            try? await Task.sleep(nanoseconds: 900_000_000)
            hosting.layoutSubtreeIfNeeded()
            guard let plateView = findSubview(GlassSurfaceContainer.self, in: hosting)
            else { return nil }
            let plate = plateView.convert(plateView.bounds, to: nil)
            guard plate.width > 100, plate.height > 20 else { return nil }
            // Two captures: the first frame after `orderFrontRegardless` can be
            // composited before the SwiftUI content is in it (a white page once
            // came back as an entirely empty white window), so the second frame
            // is the one that is measured.
            _ = try? await ScreenCapture.captureWindow(CGWindowID(panel.windowNumber))
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let shot = try? await ScreenCapture.captureWindow(
                CGWindowID(panel.windowNumber)
            ), let buffer = pixelBuffer(shot.image) else { return nil }

            let scale = shot.scale
            func captureRect(_ rect: CGRect) -> CGRect {
                CGRect(
                    x: rect.minX * scale,
                    y: (panelSize.height - rect.maxY) * scale,
                    width: rect.width * scale,
                    height: rect.height * scale
                )
            }

            // 3.5 pt in: past the plate's 1 pt hairline and its rim light.
            let interior = plate.insetBy(dx: 3.5, dy: 3.5)
            guard let plateColour = medianColour(in: buffer, rect: captureRect(interior))
            else { return nil }
            // The second glyph (存储为…), 4 pt in from the plate's top and
            // inside the glyph's own 22 pt box.
            let glyphCentre = NSPoint(
                x: plate.minX + glyphTwoInset,
                y: plate.maxY - platePadding - glyphSide / 2
            )
            let glyphBox = CGRect(
                x: glyphCentre.x - glyphSide / 2 + 3,
                y: glyphCentre.y - glyphSide / 2 + 3,
                width: glyphSide - 6,
                height: glyphSide - 6
            )
            guard let ink = inkExtreme(
                in: buffer,
                rect: captureRect(glyphBox),
                brightest: appearance == .darkAqua
            ) else { return nil }

            _ = writeProbePNG(shot.image, named: "pin-plate-\(label)-window.png", into: directory)
            let plateBox = captureRect(plate.insetBy(dx: -10, dy: -10))
                .intersection(CGRect(x: 0, y: 0, width: shot.image.width, height: shot.image.height))
            if let crop = shot.image.cropping(to: plateBox.integral),
               let big = magnify(crop, by: 2) {
                _ = writeProbePNG(big, named: "pin-plate-\(label)-plate.png", into: directory)
            }
            return PinPlateProbe(plate: plateColour, ink: ink)
        }

        for (appearanceName, appearanceLabel) in [
            (NSAppearance.Name.aqua, "light"),
            (NSAppearance.Name.darkAqua, "dark"),
        ] {
            NSApp.appearance = NSAppearance(named: appearanceName)
            let whiteInk = appearanceName == .darkAqua
            for (pictureLabel, white) in [("black", 0.0), ("white", 1.0)] {
                let label = "\(appearanceLabel)-\(pictureLabel)"
                guard let result = await probe(
                    white: white,
                    appearance: appearanceName,
                    label: label
                ) else {
                    check("pin-plate (\(label)): the plate is photographed", false)
                    continue
                }
                // `.primary` ink as the owner's 6.0 / 5.0 were computed: pure
                // black in 浅色, pure white in 深色.
                let primary: (r: Double, g: Double, b: Double) = whiteInk
                    ? (255, 255, 255)
                    : (0, 0, 0)
                let floorContrast = wcagContrast(result.plate, primary)
                let renderedContrast = wcagContrast(result.plate, result.ink)
                print(
                    "[pin-plate] \(label): floor=\(number(CGFloat(GlassWash.plateFloor(dark: whiteInk)))) "
                        + "plate=(\(number(CGFloat(result.plate.r))),\(number(CGFloat(result.plate.g))),"
                        + "\(number(CGFloat(result.plate.b)))) "
                        + "luma=\(number(CGFloat(pinHoverLuma(result.plate)))) "
                        + "ink=(\(number(CGFloat(result.ink.r))),\(number(CGFloat(result.ink.g))),"
                        + "\(number(CGFloat(result.ink.b)))) "
                        + "contrast=\(String(format: "%.2f", floorContrast)) "
                        + "rendered=\(String(format: "%.2f", renderedContrast))"
                )
                check(
                    "pin-plate (\(label)): .primary ink keeps 4.5:1 on the plate",
                    floorContrast >= 4.5,
                    "plate luma \(number(CGFloat(pinHoverLuma(result.plate)))) "
                        + "contrast \(String(format: "%.2f", floorContrast)):1 "
                        + "(rendered glyph \(String(format: "%.2f", renderedContrast)):1)"
                )
            }
        }
    }

    /// Post one real HID mouse move.
    ///
    /// `.cghidEventTap` is the only tap that reaches the window server's
    /// tracking areas, i.e. the only way `.onHover` fires; it needs the app's
    /// Accessibility grant, which the shipped bundle has (it already posts ⌘V).
    /// The caller re-reads `NSEvent.mouseLocation` and checks the pointer
    /// actually arrived, so a denied post cannot be mistaken for "no hover".
    ///
    /// `NSEvent`/`NSScreen` global coordinates have their origin at the
    /// **bottom-left** of the primary display; `CGEvent` positions count from
    /// its **top-left**. The one conversion lives here.
    private static func pinHoverMovePointer(to screenPoint: NSPoint) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: screenPoint.x, y: primaryHeight - screenPoint.y),
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
    }

    /// Mean RGB of twelve 3×3 blocks on a circle of `radius` pixels around
    /// `centre`, in a capture-pixel buffer.
    ///
    /// The ring sits inside the highlight but outside the glyph ink, so the
    /// numbers describe the highlight layer alone and not the icon that is
    /// drawn on top of it.
    private static func ringColour(
        in buffer: PixelBuffer,
        centre: (x: Int, y: Int),
        radius: Int
    ) -> (r: Double, g: Double, b: Double)? {
        var sum = (r: 0.0, g: 0.0, b: 0.0)
        var count = 0
        for step in 0..<12 {
            let angle = Double(step) / 12 * 2 * .pi
            let x = centre.x + Int((cos(angle) * Double(radius)).rounded())
            let y = centre.y + Int((sin(angle) * Double(radius)).rounded())
            var block = (r: 0, g: 0, b: 0)
            var hits = 0
            for dy in -1...1 {
                for dx in -1...1 {
                    guard x + dx >= 0, y + dy >= 0,
                          x + dx < buffer.width, y + dy < buffer.height else { continue }
                    let (r, g, b) = buffer.rgb(x: x + dx, y: y + dy)
                    block.r += r
                    block.g += g
                    block.b += b
                    hits += 1
                }
            }
            guard hits > 0 else { continue }
            sum.r += Double(block.r) / Double(hits)
            sum.g += Double(block.g) / Double(hits)
            sum.b += Double(block.b) / Double(hits)
            count += 1
        }
        guard count > 0 else { return nil }
        return (sum.r / Double(count), sum.g / Double(count), sum.b / Double(count))
    }

    /// Bounding box of the pixels that differ between two captures by more
    /// than `threshold` in any channel, searched inside `region` (capture
    /// pixels). `nil` when nothing differs.
    ///
    /// Used to prove the *shape* of a hover layer without knowing the control's
    /// frame: whatever lights up defines its own box.
    private static func changedBounds(
        _ before: PixelBuffer,
        _ after: PixelBuffer,
        threshold: Int,
        within region: CGRect
    ) -> CGRect? {
        guard before.width == after.width, before.height == after.height else { return nil }
        let x0 = max(0, Int(region.minX))
        let y0 = max(0, Int(region.minY))
        let x1 = min(before.width, Int(region.maxX))
        let y1 = min(before.height, Int(region.maxY))
        guard x1 > x0, y1 > y0 else { return nil }
        var minX = x1
        var minY = y1
        var maxX = x0 - 1
        var maxY = y0 - 1
        for y in y0..<y1 {
            for x in x0..<x1 {
                let a = before.rgb(x: x, y: y)
                let b = after.rgb(x: x, y: y)
                guard abs(a.0 - b.0) > threshold
                    || abs(a.1 - b.1) > threshold
                    || abs(a.2 - b.2) > threshold else { continue }
                if x < minX { minX = x }
                if y < minY { minY = y }
                if x > maxX { maxX = x }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private static func pinHoverLuma(_ colour: (r: Double, g: Double, b: Double)) -> Double {
        0.2126 * colour.r + 0.7152 * colour.g + 0.0722 * colour.b
    }

    /// Nearest-neighbour magnification, so a 22 pt control can be inspected
    /// without inventing pixels.
    private static func magnify(_ image: CGImage, by factor: Int) -> CGImage? {
        let width = image.width * factor
        let height = image.height * factor
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
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func writeProbePNG(
        _ image: CGImage,
        named name: String,
        into directory: URL
    ) -> Int {
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:])
        else { return 0 }
        try? data.write(to: directory.appendingPathComponent(name))
        return data.count
    }

    /// What one probe run photographed, plus the geometry the pixel maths needs.
    private struct PinHoverProbe {
        let label: String
        let idle: CGImage
        let hovered: CGImage
        /// The same window with the opacity `%` chip hovered instead, when the
        /// probe was asked for it.
        let chip: CGImage?
        let scale: CGFloat
        let windowHeight: CGFloat
        /// The glass plate in window coordinates (bottom-left origin).
        let plate: CGRect
        /// Centre of the second glyph (存储为…) in window coordinates.
        let glyph: NSPoint
    }

    /// The hover highlight, photographed the only way it can be proven.
    ///
    /// `.onHover` is driven by the window server's tracking areas, so no
    /// offscreen render can show it. This group therefore opens a real
    /// borderless panel holding the real `PinnedImageView`, drives the **real
    /// pointer** onto one glyph with a synthetic HID move, and captures the
    /// window twice: toolbar up but idle, then that one glyph hovered. It then
    /// does the same for a `%` chip, to prove the capsule.
    ///
    /// The numbers below come from the same two frames. Every highlight is
    /// "some colour + alpha" over the plate, so both are described by
    /// `hovered = α · idle + β` solved across two different pictures:
    ///
    /// * the original `Color.primary.opacity(0.20)` in 浅色 gave `α ≈ 0.8`,
    ///   `β ≈ 0` — it only *subtracted* backdrop, i.e. a shadow;
    /// * the system glass that replaced it gave `α ≈ 1`, `β ≈ +41` — it added
    ///   light, but from a material rather than from ink;
    /// * the white lift here must give `α ≈ 0.76`, `β ≈ +61` (`0.24 · 255`), and
    ///   a **positive lift on both pictures**. `α`/`β` are printed for every
    ///   combination, and asserted, so a later edit that turns the chip back
    ///   into a shadow shows up as a number, not as an opinion.
    private static func runPinHoverHighlightTests(into directory: URL) async {
        print("[pin-hover] --- a real pointer on one glyph, light and dark pictures ---")
        guard ScreenCapture.hasScreenRecordingPermission else {
            print("[pin-hover] SKIP: no screen-recording permission")
            return
        }

        let savedAppearance = NSApp.appearance
        let savedPointer = NSEvent.mouseLocation
        NSApp.activate(ignoringOtherApps: true)
        defer {
            NSApp.appearance = savedAppearance
            // The harness must not leave the user's pointer on a probe window.
            pinHoverMovePointer(to: savedPointer)
        }

        // The second glyph (存储为…): `plate.minX + 4 pt padding + 22 pt glyph
        // + 3 pt gap + half a glyph`. Plain arithmetic — unlike the two `%`
        // chips, whose widths follow their labels.
        let glyphTwoInset: CGFloat = 4 + 22 + 3 + 11
        let glyphPitch: CGFloat = 22 + 3
        let padding: CGFloat = 4
        let glyphSide: CGFloat = 22

        func makePanel(
            picture light: Bool,
            appearance: NSAppearance.Name
        ) async -> (PinnedImagePanel, NSHostingView<PinnedImageView>, CGSize)? {
            guard let image = pinHoverProbePicture(light: light) else { return nil }
            let size = CGSize(width: 380, height: 260)
            let visible = NSScreen.main?.visibleFrame
                ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            let origin = CGPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2
            )
            let panel = PinnedImagePanel(
                contentRect: CGRect(origin: origin, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            // The drop shadow is a captured artefact of the window, not of the
            // toolbar; the capture already asks for it to be ignored.
            panel.hasShadow = false
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.animationBehavior = .none
            panel.appearance = NSAppearance(named: appearance)
            let state = PinPanelState(displaySize: size, opacity: 1)
            panel.pinState = state
            let hosting = NSHostingView(rootView: PinnedImageView(
                image: image,
                state: state,
                onClose: {},
                onCopy: {},
                onSave: {},
                onOpacity: { _ in },
                onFitToActualSize: {}
            ))
            hosting.frame = CGRect(origin: .zero, size: size)
            hosting.appearance = NSAppearance(named: appearance)
            panel.contentView = hosting
            panel.orderFrontRegardless()
            panel.makeKey()
            return (panel, hosting, size)
        }

        func probe(
            picture light: Bool,
            label: String,
            appearance: NSAppearance.Name,
            chip: Bool = false
        ) async -> PinHoverProbe? {
            guard let (panel, hosting, size) = await makePanel(picture: light, appearance: appearance)
            else { return nil }
            defer { panel.orderOut(nil); panel.close() }

            // The toolbar only exists while the image itself is hovered, so the
            // pointer has to come inside the panel first and the spring
            // insertion has to finish before the plate can be measured.
            let centroid = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
            pinHoverMovePointer(to: centroid)
            try? await Task.sleep(nanoseconds: 750_000_000)
            hosting.layoutSubtreeIfNeeded()

            // The plate is the app's own glass container — the same view the
            // plate checks introspect — so its frame is measured, not guessed.
            guard let plateView = findSubview(GlassSurfaceContainer.self, in: hosting)
            else { return nil }
            let plate = plateView.convert(plateView.bounds, to: nil)
            guard plate.width > 100, plate.height > 20 else { return nil }
            let glyph = NSPoint(
                x: plate.minX + glyphTwoInset,
                y: plate.maxY - padding - glyphSide / 2
            )

            guard let idle = try? await ScreenCapture.captureWindow(
                CGWindowID(panel.windowNumber)
            ) else { return nil }

            pinHoverMovePointer(to: panel.convertPoint(toScreen: glyph))
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let hovered = try? await ScreenCapture.captureWindow(
                CGWindowID(panel.windowNumber)
            ) else { return nil }

            // The opacity `%` chip, when asked for: its left cap starts right
            // after the third glyph and the third gap, so 5 pt inside that edge
            // is inside the capsule without having to know the label's width.
            var chipShot: CGImage?
            if chip {
                let chipPoint = NSPoint(
                    x: plate.minX + padding + glyphSide * 3 + 3 * 3 + 5,
                    y: glyph.y
                )
                pinHoverMovePointer(to: panel.convertPoint(toScreen: chipPoint))
                try? await Task.sleep(nanoseconds: 450_000_000)
                chipShot = (try? await ScreenCapture.captureWindow(
                    CGWindowID(panel.windowNumber)
                ))?.image
            }

            return PinHoverProbe(
                label: label,
                idle: idle.image,
                hovered: hovered.image,
                chip: chipShot,
                scale: hovered.scale,
                windowHeight: size.height,
                plate: plate,
                glyph: glyph
            )
        }

        /// Window point → capture pixel. The capture's row 0 is the window's top.
        func pixel(_ point: NSPoint, in probe: PinHoverProbe) -> (x: Int, y: Int) {
            (
                Int((point.x * probe.scale).rounded()),
                Int(((probe.windowHeight - point.y) * probe.scale).rounded())
            )
        }

        var measured: [String: (idle: Double, hovered: Double)] = [:]

        for (appearanceName, appearanceLabel) in [
            (NSAppearance.Name.darkAqua, "dark"),
            (NSAppearance.Name.aqua, "light"),
        ] {
            NSApp.appearance = NSAppearance(named: appearanceName)
            for (pictureLabel, light) in [("light", true), ("dark", false)] {
                let name = "\(appearanceLabel)-\(pictureLabel)"
                guard let probe = await probe(
                    picture: light,
                    label: name,
                    appearance: appearanceName,
                    // The capsule shape is proven once: the glyph already
                    // proves the material, and a `%` chip is the same layer at
                    // the same 11 pt radius.
                    chip: name == "dark-light"
                ) else {
                    check("pin-hover: the \(name) probe photographs a real pin", false)
                    continue
                }
                guard let idleBuffer = pixelBuffer(probe.idle),
                      let hoveredBuffer = pixelBuffer(probe.hovered)
                else {
                    check("pin-hover: the \(name) captures decode to pixels", false)
                    continue
                }
                let centre = pixel(probe.glyph, in: probe)
                let radius = max(4, Int((9.25 * probe.scale).rounded()))
                // A second, inner ring, printed beside the outer one so the
                // numbers stay comparable with the glass build that preceded
                // this one (its rim light made the two differ). The
                // pass/fail assertions use the axis samples below, because a
                // ring passes through glyph ink and those samples do not.
                let innerRadius = max(2, Int((5.5 * probe.scale).rounded()))
                guard let idleRing = ringColour(in: idleBuffer, centre: centre, radius: radius),
                      let hoveredRing = ringColour(in: hoveredBuffer, centre: centre, radius: radius)
                else {
                    check("pin-hover: the \(name) glyph ring samples", false)
                    continue
                }
                let idleInner = ringColour(in: idleBuffer, centre: centre, radius: innerRadius)
                let hoveredInner = ringColour(in: hoveredBuffer, centre: centre, radius: innerRadius)

                // The chip's own fill is sampled **off the glyph**: four 3×3
                // blocks on the horizontal/vertical axes at 9.25 pt from the
                // centre. That is inside the 22 pt chip (radius 11) and clear
                // of both the glyph's strokes (the 11 pt symbol is ≈15 pt wide,
                // so its half-extent is ≈7.5 pt) and of the 1 pt hairline at
                // the rim. Both a box median and a full 12-point ring include
                // glyph pixels — the ink darkens from 0.85 to 1.0 on hover,
                // which turned a +9 lift into +1.3 in 浅色 before this.
                func capturePixel(_ point: NSPoint) -> (x: Int, y: Int) {
                    pixel(point, in: probe)
                }
                func axisFill(_ buffer: PixelBuffer, around point: NSPoint) -> (r: Double, g: Double, b: Double)? {
                    var sum = (r: 0.0, g: 0.0, b: 0.0)
                    var hits = 0
                    for angle in [0.0, 0.5, 1.0, 1.5].map({ $0 * .pi }) {
                        let spot = capturePixel(NSPoint(
                            x: point.x + cos(angle) * 9.25,
                            y: point.y + sin(angle) * 9.25
                        ))
                        var block = (r: 0, g: 0, b: 0)
                        var count = 0
                        for dy in -1...1 {
                            for dx in -1...1 {
                                guard spot.x + dx >= 0, spot.y + dy >= 0,
                                      spot.x + dx < buffer.width,
                                      spot.y + dy < buffer.height else { continue }
                                let rgb = buffer.rgb(x: spot.x + dx, y: spot.y + dy)
                                block.r += rgb.0
                                block.g += rgb.1
                                block.b += rgb.2
                                count += 1
                            }
                        }
                        guard count > 0 else { continue }
                        sum.r += Double(block.r) / Double(count)
                        sum.g += Double(block.g) / Double(count)
                        sum.b += Double(block.b) / Double(count)
                        hits += 1
                    }
                    guard hits == 4 else { return nil }
                    return (sum.r / 4, sum.g / 4, sum.b / 4)
                }
                guard let idleFill = axisFill(idleBuffer, around: probe.glyph),
                      let litFill = axisFill(hoveredBuffer, around: probe.glyph)
                else {
                    check("pin-hover: the \(name) chip fill samples", false)
                    continue
                }
                let fillLift = (
                    r: litFill.r - idleFill.r,
                    g: litFill.g - idleFill.g,
                    b: litFill.b - idleFill.b
                )
                /// What a 24 % white lift over that exact plate must add, per
                /// channel. The plate is the only thing between the picture and
                /// the chip, so this is an identity, not a taste: `lift_c =
                /// 0.24 · (255 − plate_c)`.
                let expectedLift = (
                    r: PinToolbarSurface.hoverFill * (255 - idleFill.r),
                    g: PinToolbarSurface.hoverFill * (255 - idleFill.g),
                    b: PinToolbarSurface.hoverFill * (255 - idleFill.b)
                )
                check(
                    "pin-hover (\(name)): the chip is exactly a \(Int(PinToolbarSurface.hoverFill * 100)) % white lift",
                    abs(fillLift.r - expectedLift.r) <= 6
                        && abs(fillLift.g - expectedLift.g) <= 6
                        && abs(fillLift.b - expectedLift.b) <= 6,
                    "plate=(\(number(idleFill.r)),\(number(idleFill.g)),\(number(idleFill.b))) "
                        + "lift=(\(number(fillLift.r)),\(number(fillLift.g)),\(number(fillLift.b))) "
                        + "expected=(\(number(expectedLift.r)),\(number(expectedLift.g)),"
                        + "\(number(expectedLift.b)))"
                )
                // Requirement: the hover must be a **lift**. This is the check
                // that fails if anyone brings back a `.primary` wash (which
                // darkens the region in 浅色 — the "grey shadow" the owner saw).
                // Only a downward bound is asserted: how far a white lift can
                // raise a pixel is capped by headroom, `255 − plate`, so a bright
                // plate *cannot* move as far as a dark one.
                check(
                    "pin-hover (\(name)): hover is brighter than idle, never a shadow",
                    fillLift.r > 0 && fillLift.g > 0 && fillLift.b > 0,
                    "lift=(\(number(fillLift.r)),\(number(fillLift.g)),\(number(fillLift.b))) "
                        + "sum=\(number(fillLift.r + fillLift.g + fillLift.b))"
                )

                // …and only that one. Compared **inside each frame**: the
                // hovered control against a control that is not hovered, with
                // the same axis statistic. A difference of differences cancels
                // the plate's own horizontal gradient (it samples a gradient
                // picture) and says nothing about *where* the highlight is.
                let leftNeighbour = NSPoint(
                    x: probe.plate.minX + padding + glyphSide / 2,
                    y: probe.glyph.y
                )
                let rightNeighbour = NSPoint(x: probe.glyph.x + glyphPitch, y: probe.glyph.y)
                func boxLift(around point: NSPoint) -> (r: Double, g: Double, b: Double)? {
                    guard let rest = axisFill(idleBuffer, around: point),
                          let lit = axisFill(hoveredBuffer, around: point)
                    else { return nil }
                    return (lit.r - rest.r, lit.g - rest.g, lit.b - rest.b)
                }
                var neighbourLifts: [(r: Double, g: Double, b: Double)] = []
                for neighbour in [leftNeighbour, rightNeighbour] {
                    if let lift = boxLift(around: neighbour) { neighbourLifts.append(lift) }
                }
                check(
                    "pin-hover (\(name)): only the control under the pointer is lit",
                    neighbourLifts.count == 2
                        && neighbourLifts.allSatisfy {
                            abs($0.r) <= 2 && abs($0.g) <= 2 && abs($0.b) <= 2
                        }
                        && fillLift.r + fillLift.g + fillLift.b
                            - neighbourLifts.map { $0.r + $0.g + $0.b }.max()! >= 8,
                    "chipSum=\(number(fillLift.r + fillLift.g + fillLift.b)) neighbours="
                        + neighbourLifts.map {
                            "(\(number($0.r)),\(number($0.g)),\(number($0.b)))"
                        }.joined(separator: ", ")
                )

                // The zoomed crop the owner judges: 48×48 pt around the glyph.
                let box = CGRect(
                    x: probe.glyph.x - 12,
                    y: probe.glyph.y - 12,
                    width: 48,
                    height: 48
                )
                func crop(_ image: CGImage, _ rect: CGRect) -> CGImage? {
                    let pixelRect = CGRect(
                        x: rect.minX * probe.scale,
                        y: (probe.windowHeight - rect.maxY) * probe.scale,
                        width: rect.width * probe.scale,
                        height: rect.height * probe.scale
                    ).integral
                    return image.cropping(to: pixelRect)
                }
                if let idleCrop = crop(probe.idle, box),
                   let hoveredCrop = crop(probe.hovered, box),
                   let bigIdle = magnify(idleCrop, by: 3),
                   let bigHovered = magnify(hoveredCrop, by: 3) {
                    let a = writeProbePNG(bigIdle, named: "pin-hover-\(name)-idle.png", into: directory)
                    let b = writeProbePNG(bigHovered, named: "pin-hover-\(name)-hovered.png", into: directory)
                    check(
                        "pin-hover (\(name)): the 3× glyph crops are real pixels",
                        a > 200 && b > 200,
                        "idle=\(a)B hovered=\(b)B"
                    )
                }
                let plateMargin: CGFloat = 10
                let plateBox = probe.plate.insetBy(dx: -plateMargin, dy: -plateMargin)
                if let plateIdle = crop(probe.idle, plateBox),
                   let plateHovered = crop(probe.hovered, plateBox),
                   let bigIdlePlate = magnify(plateIdle, by: 2),
                   let bigHoveredPlate = magnify(plateHovered, by: 2) {
                    _ = writeProbePNG(
                        bigIdlePlate,
                        named: "pin-hover-\(name)-plate-idle.png",
                        into: directory
                    )
                    _ = writeProbePNG(
                        bigHoveredPlate,
                        named: "pin-hover-\(name)-plate.png",
                        into: directory
                    )
                }

                measured[name] = (
                    pinHoverLuma(idleFill),
                    pinHoverLuma(litFill)
                )
                let rim = number(pinHoverLuma(hoveredRing) - pinHoverLuma(idleRing))
                let middle = idleInner.flatMap { before in
                    hoveredInner.map { after in
                        number(pinHoverLuma(after) - pinHoverLuma(before))
                    }
                } ?? "n/a"
                print(
                    "[pin-hover] \(name): scale=\(number(probe.scale)) "
                        + "plate=\(format(probe.plate)) glyph=(\(number(probe.glyph.x)),"
                        + "\(number(probe.glyph.y))) "
                        + "chipLift=\(number(pinHoverLuma(litFill) - pinHoverLuma(idleFill))) "
                        + "chipLiftRGB=(\(number(fillLift.r)),\(number(fillLift.g)),"
                        + "\(number(fillLift.b))) "
                        + "rimLift=\(rim) middleLift=\(middle) "
                        + "idleRing=(\(number(idleRing.r)),\(number(idleRing.g)),"
                        + "\(number(idleRing.b))) "
                        + "hoveredRing=(\(number(hoveredRing.r)),\(number(hoveredRing.g)),"
                        + "\(number(hoveredRing.b)))"
                )

                // The `%` chip, when the probe took it. The changed *shape* is
                // what matters: the highlight has to be the chip's capsule
                // (much wider than the 22 pt glyph circle), not a circle that
                // happens to sit under the text. The search is confined to the
                // plate and the threshold is well above the couple of levels
                // the whole plate can shift by when the window recomposites,
                // so only the highlight itself can define the box.
                if let chipShot = probe.chip, let chipBuffer = pixelBuffer(chipShot) {
                    let region = CGRect(
                        x: probe.plate.minX * probe.scale,
                        y: (probe.windowHeight - probe.plate.maxY) * probe.scale,
                        width: probe.plate.width * probe.scale,
                        height: probe.plate.height * probe.scale
                    ).integral
                    if let bounds = changedBounds(
                        idleBuffer,
                        chipBuffer,
                        threshold: 6,
                        within: region
                    ) {
                        let width = Double(bounds.width) / Double(probe.scale)
                        let height = Double(bounds.height) / Double(probe.scale)
                        // The box is the highlight *including* the rim's soft
                        // glow, so it is a few points larger than the 22 pt
                        // control. What distinguishes a capsule from the glyph
                        // disc is the ratio: the disc can never be much wider
                        // than it is tall.
                        check(
                            "pin-hover (\(name)): the % chip gets the same white chip, capsule-shaped",
                            width <= 80 && height <= 34 && width - height >= 15,
                            "changed=\(number(width))×\(number(height)) pt "
                                + "ratio=\(number(width / height)) "
                                + "(a glyph disc is ≈1:1, this chip's capsule is ≈2:1)"
                        )
                        let chipWindowRect = CGRect(
                            x: Double(bounds.minX) / Double(probe.scale),
                            y: probe.windowHeight
                                - Double(bounds.maxY) / Double(probe.scale),
                            width: width,
                            height: height
                        ).insetBy(dx: -6, dy: -6)
                        if let chipCrop = crop(chipShot, chipWindowRect),
                           let bigChip = magnify(chipCrop, by: 3) {
                            _ = writeProbePNG(
                                bigChip,
                                named: "pin-hover-\(name)-chip.png",
                                into: directory
                            )
                        }
                    } else {
                        check(
                            "pin-hover (\(name)): the % chip gets the same white chip, capsule-shaped",
                            false,
                            "no highlight where the chip's left cap is"
                        )
                    }
                }
            }
        }

        // `hovered = α · idle + β` over two different pictures solves the layer:
        // subtracting the two equations leaves α, and β follows. A white lift
        // has α < 1 and a **positive** β (0.24 white solves to 0.76 · idle + 61);
        // a dark ink wash would have the same α but β ≤ 0.
        for appearanceLabel in ["dark", "light"] {
            guard let lightEnd = measured["\(appearanceLabel)-light"],
                  let darkEnd = measured["\(appearanceLabel)-dark"]
            else { continue }
            let slope = lightEnd.idle - darkEnd.idle
            guard abs(slope) > 4 else {
                print("[pin-hover] \(appearanceLabel): idle contrast \(number(slope)) "
                    + "too small to solve the layer")
                continue
            }
            let liftLight = lightEnd.hovered - lightEnd.idle
            let liftDark = darkEnd.hovered - darkEnd.idle
            let alpha = 1 + (liftLight - liftDark) / slope
            let beta = liftLight - (alpha - 1) * lightEnd.idle
            print(
                "[pin-hover] \(appearanceLabel): hover layer = \(number(alpha)) · idle "
                    + "+ \(number(beta))  (idle \(number(lightEnd.idle)) vs "
                    + "\(number(darkEnd.idle)), lift \(number(liftLight)) vs "
                    + "\(number(liftDark)))"
            )
            measured["\(appearanceLabel)-alpha"] = (alpha, beta)
            // The solved layer, asserted. 0.24 white over the plate is
            // `α = 1 − 0.24 = 0.76`, `β = 0.24 · 255 = 61.2`; the tolerances
            // absorb the chip fill's own antialiasing and the plate's
            // picture-to-picture differences. A `.primary` wash in 浅色 solves
            // to α ≈ 0.8 with
            // β ≈ 0 and a negative lift, which is exactly what this rejects.
            check(
                "pin-hover (\(appearanceLabel)): the layer solves to a 24 % white lift",
                abs(alpha - 0.76) <= 0.10
                    && beta >= 35 && beta <= 95
                    && liftLight > 0 && liftDark > 0,
                "hover = \(number(alpha)) · idle + \(number(beta)) "
                    + "(expected ≈ 0.76 · idle + 61) "
                    + "lift light=\(number(liftLight)) dark=\(number(liftDark))"
            )
        }
    }

    /// The panel's action row: one family of capsules, and a read-out built
    /// exactly like the buttons beside it.
    ///
    /// The read-out used to carry two private coats — a 4 % matte and a 60 %
    /// dark floor — that the buttons never had. Both are gone: it now calls the
    /// same `capsuleControlSurface` and the same `Color.primary` label ink, so
    /// these checks pin "one recipe" instead of "two coats that nearly cancel".
    private static func runPanelCapsuleTests(into directory: URL) {
        print("[capsule] --- count read-out vs icon buttons ---")
        // Resting was 0.07 / 0.05 and read as loose glyphs rather than
        // buttons; it is now half the shared hover tier (see `ToolbarInk`).
        check(
            "capsule: the count read-out keeps the family ink",
            abs(CapsuleControlStyle.restingFill - 0.10) < 0.0001,
            "resting=\(CapsuleControlStyle.restingFill)"
        )
        check(
            "capsule: both surfaces still share padding / height / hairline",
            CapsuleControlStyle.horizontalPadding == 8
                && CapsuleControlStyle.height == 26
                && abs(CapsuleControlStyle.restingHairline - 0.08) < 0.0001,
            "padding=\(CapsuleControlStyle.horizontalPadding) "
                + "height=\(CapsuleControlStyle.height) "
                + "hairline=\(CapsuleControlStyle.restingHairline)"
        )
        // The panel keeps the shared ink ladder — and it is now the *only*
        // surface that reads a hover ink at all: the pinned toolbar's hover is a
        // white lift (white at 24 %), so `ToolbarInk.hoverFill` must stay the
        // panel's number and the pin must not claim the shared hover tier.
        check(
            "capsule: the panel keeps the ink tier the pinned toolbar left behind",
            CapsuleControlStyle.hoverFill == ToolbarInk.hoverFill
                && abs(CapsuleControlStyle.hoverFill - 0.20) < 0.0001
                && !PinToolbarSurface.hoverUsesInk,
            "panel=\(CapsuleControlStyle.hoverFill) "
                + "shared=\(ToolbarInk.hoverFill) "
                + "pinUsesInk=\(PinToolbarSurface.hoverUsesInk)"
        )
        check(
            "capsule: resting < hover < latched hover, with a resting lift",
            CapsuleControlStyle.restingFill >= 0.09
                && CapsuleControlStyle.restingFill < CapsuleControlStyle.hoverFill
                && CapsuleControlStyle.activeFill > CapsuleControlStyle.restingFill
                && CapsuleControlStyle.activeFill < CapsuleControlStyle.hoverFill
                && CapsuleControlStyle.activeHoverFill > CapsuleControlStyle.hoverFill,
            "resting=\(CapsuleControlStyle.restingFill) "
                + "hover=\(CapsuleControlStyle.hoverFill) "
                + "active=\(CapsuleControlStyle.activeFill) "
                + "activeHover=\(CapsuleControlStyle.activeHoverFill)"
        )

        // MARK: - One row, rendered exactly as the panel builds it

        // The full panel, not a 47 pt strip: `LiquidGlassWash` is sized to the
        // panel, so squeezing the row into a strip would exaggerate its
        // top-leading gradient and measure a surface that never ships.
        let rowSize = CGSize(width: 420, height: 560)
        // Where the four right-hand buttons sit, and the read-out's own slot —
        // the panel's real geometry, so the wash gradient is sampled where the
        // user actually sees it.
        let buttonCentres: [CGFloat] = [282, 318, 356, 394]
        let readoutCentre: CGFloat = 54
        // The action row's 9 pt top inset plus half the 47 pt row.
        let capsuleY: CGFloat = 32.5

        /// `withReadout` draws the real read-out; without it the same slot holds
        /// the same modifier and no content, which is the reference the read-out
        /// must match pixel for pixel.
        func renderRow(
            wash: Bool,
            withReadout: Bool,
            name: String? = nil,
            scheme: ColorScheme = .dark,
            ground: Double = 0.35
        ) -> CGImage? {
            let row = ZStack {
                Color(white: ground)
                if wash { LiquidGlassWash() }
                Group {
                    if withReadout {
                        HStack(spacing: 6) {
                            Text("剪贴板")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.primary)
                            Text("487 条")
                                .font(.system(size: 11))
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, CapsuleControlStyle.horizontalPadding)
                        .frame(height: CapsuleControlStyle.height)
                    } else {
                        Color.clear.frame(
                            width: 96,
                            height: CapsuleControlStyle.height
                        )
                    }
                }
                .capsuleControlSurface()
                .position(x: readoutCentre, y: capsuleY)

                ForEach(buttonCentres, id: \.self) { centre in
                    Image(systemName: "pin")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, CapsuleControlStyle.horizontalPadding)
                        .frame(height: CapsuleControlStyle.height)
                        .capsuleControlSurface()
                        .position(x: centre, y: capsuleY)
                }
            }
            .frame(width: rowSize.width, height: rowSize.height)
            .environment(\.colorScheme, scheme)
            let hosting = NSHostingView(rootView: row)
            hosting.frame = CGRect(origin: .zero, size: rowSize)
            hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
            else { return nil }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            if let name, let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: directory.appendingPathComponent(name))
            }
            return rep.cgImage
        }

        func scaleX(_ buffer: PixelBuffer) -> CGFloat {
            CGFloat(buffer.width) / rowSize.width
        }
        func scaleY(_ buffer: PixelBuffer) -> CGFloat {
            CGFloat(buffer.height) / rowSize.height
        }
        func sample(_ buffer: PixelBuffer, _ x: CGFloat, _ y: CGFloat) -> (Int, Int, Int) {
            let px = min(buffer.width - 1, max(0, Int(x * scaleX(buffer))))
            let py = min(buffer.height - 1, max(0, Int(y * scaleY(buffer))))
            return buffer.rgb(x: px, y: py)
        }
        func grey(_ rgb: (Int, Int, Int)) -> Int { (rgb.0 + rgb.1 + rgb.2) / 3 }
        func channel(_ value: Int) -> Double {
            let c = Double(value) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        func luminance(_ rgb: (Int, Int, Int)) -> Double {
            0.2126 * channel(rgb.0) + 0.7152 * channel(rgb.1) + 0.0722 * channel(rgb.2)
        }
        /// Brightest pixel inside a row rect — the ink.
        func peak(_ buffer: PixelBuffer, _ rect: CGRect) -> (Int, Int, Int) {
            var best = (0, 0, 0)
            var bestLum = -1.0
            let x0 = max(0, Int(rect.minX * scaleX(buffer)))
            let x1 = min(buffer.width, Int(rect.maxX * scaleX(buffer)))
            let y0 = max(0, Int(rect.minY * scaleY(buffer)))
            let y1 = min(buffer.height, Int(rect.maxY * scaleY(buffer)))
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let rgb = buffer.rgb(x: x, y: y)
                    let lum = luminance(rgb)
                    if lum > bestLum { bestLum = lum; best = rgb }
                }
            }
            return best
        }
        /// Darkest pixel inside a row rect — the ink in the light appearance.
        func trough(_ buffer: PixelBuffer, _ rect: CGRect) -> (Int, Int, Int) {
            var best = (255, 255, 255)
            var bestLum = 2.0
            let x0 = max(0, Int(rect.minX * scaleX(buffer)))
            let x1 = min(buffer.width, Int(rect.maxX * scaleX(buffer)))
            let y0 = max(0, Int(rect.minY * scaleY(buffer)))
            let y1 = min(buffer.height, Int(rect.maxY * scaleY(buffer)))
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let rgb = buffer.rgb(x: x, y: y)
                    let lum = luminance(rgb)
                    if lum < bestLum { bestLum = lum; best = rgb }
                }
            }
            return best
        }
        /// Peak ink over the rect's median ground, the same ratio the dark
        /// audit uses.
        func contrast(_ buffer: PixelBuffer, _ rect: CGRect) -> Double? {
            var samples: [Double] = []
            let x0 = max(0, Int(rect.minX * scaleX(buffer)))
            let x1 = min(buffer.width, Int(rect.maxX * scaleX(buffer)))
            let y0 = max(0, Int(rect.minY * scaleY(buffer)))
            let y1 = min(buffer.height, Int(rect.maxY * scaleY(buffer)))
            guard x1 > x0, y1 > y0 else { return nil }
            for y in y0..<y1 {
                for x in x0..<x1 {
                    samples.append(luminance(buffer.rgb(x: x, y: y)))
                }
            }
            samples.sort()
            let ground = samples[samples.count / 2]
            return (samples[samples.count - 1] + 0.05) / (ground + 0.05)
        }

        guard let washedImage = renderRow(
                  wash: true,
                  withReadout: true,
                  name: "capsule-row-wash.png"
              ),
              let bareImage = renderRow(wash: true, withReadout: false),
              let flatImage = renderRow(
                  wash: false,
                  withReadout: true,
                  name: "capsule-row-flat.png"
              ),
              let lightImage = renderRow(
                  wash: true,
                  withReadout: true,
                  name: "capsule-row-wash-light.png",
                  scheme: .light,
                  // The light appearance is meant for a bright page; the
                  // 2026-10-23 capture sits on a white one (row ground #f9).
                  ground: 0.95
              ),
              let washed = pixelBuffer(washedImage),
              let bare = pixelBuffer(bareImage),
              let flat = pixelBuffer(flatImage),
              let light = pixelBuffer(lightImage)
        else {
            check("capsule: the action-row strip renders", false)
            return
        }

        // Fill is read 8.5 pt below each capsule's centre line: still inside
        // the 26 pt capsule, below every glyph, so neither a glyph nor the
        // 1 pt hairline can leak into the sample.
        let fillY = capsuleY + 8.5
        // Ground is read in the row's top padding, 7.5 pt above the capsules.
        let groundY: CGFloat = 12
        let readoutFill = grey(sample(washed, readoutCentre, fillY))
        let bareFill = grey(sample(bare, readoutCentre, fillY))
        let flatReadoutFill = grey(sample(flat, readoutCentre, fillY))
        let buttonFills = buttonCentres.map { grey(sample(washed, $0, fillY)) }
        let flatButtonFill = grey(sample(flat, buttonCentres[0], fillY))
        let cornerGround = grey(sample(washed, readoutCentre, groundY))
        let buttonGrounds = buttonCentres.map { grey(sample(washed, $0, groundY)) }

        // The deleted coats were drawn *under the read-out only*. With the same
        // modifier and no content, the read-out's slot must therefore be the
        // same pixel as the reference capsule: any private layer shows up here.
        check(
            "capsule: the read-out draws no coat the buttons do not have",
            abs(readoutFill - bareFill) <= 1,
            "readout=\(readoutFill) bareSameModifier=\(bareFill)"
        )
        // Root cause of the residual difference, still measured: one identical
        // 10 % fill sits on a brighter ground at the top-leading corner.
        check(
            "capsule: the wash leaves the top-leading corner's ground brighter",
            cornerGround - buttonGrounds.max()! >= 2,
            "cornerBase=\(cornerGround) buttons=\(buttonGrounds)"
        )
        check(
            "capsule: the same ink therefore lands higher at the corner",
            readoutFill - buttonFills.max()! >= 2,
            "readout=\(readoutFill) buttons=\(buttonFills)"
        )
        // Without the wash the two positions are identical, which is what makes
        // the wash — not the recipe — the remaining cause.
        check(
            "capsule: over a flat ground the two ends render identically",
            abs(flatReadoutFill - flatButtonFill) <= 1,
            "readout=\(flatReadoutFill) button=\(flatButtonFill)"
        )
        // The user-facing acceptance: with one recipe the read-out may not be
        // *darker* than the buttons (the 60 % coat) and may not drift more than
        // 5 RGB outside the row's own fill range. The residual left is the
        // wash's corner gradient, which moves the four buttons themselves by
        // 3–5 RGB (measured in `Docs/verification/panel-count-align-2026-10-23`).
        check(
            "capsule: the read-out stays within 5 RGB of the button row",
            readoutFill >= buttonFills.min()! - 2
                && readoutFill <= buttonFills.max()! + 5,
            "readout=\(readoutFill) buttons=\(buttonFills) "
                + "deltas=\(buttonFills.map { readoutFill - $0 })"
        )
        // …and it keeps the family's fill-over-ground contrast: the read-out
        // must not be a darker (or paler) surface than the buttons are.
        check(
            "capsule: the read-out keeps its own fill contrast",
            readoutFill - cornerGround >= buttonFills.min()! - buttonGrounds.max()! - 2,
            "readoutContrast=\(readoutFill - cornerGround) "
                + "buttonContrast=\(buttonFills.min()! - buttonGrounds.max()!)"
        )

        // The light appearance is the other half of the same claim: `.primary`
        // turns black, and both surfaces still have to land on one pixel.
        let lightReadoutFill = grey(sample(light, readoutCentre, fillY))
        let lightButtonFills = buttonCentres.map { grey(sample(light, $0, fillY)) }
        let lightReadoutInk = trough(light, CGRect(x: 20, y: 24, width: 76, height: 18))
        let lightButtonInk = trough(
            light,
            CGRect(x: buttonCentres[0] - 11, y: 24, width: 22, height: 18)
        )
        check(
            "capsule: in the light appearance both surfaces land on one pixel",
            lightButtonFills.allSatisfy { abs(lightReadoutFill - $0) <= 2 }
                && grey(lightReadoutInk) <= 60
                && abs(grey(lightReadoutInk) - grey(lightButtonInk)) <= 2,
            "readout=\(lightReadoutFill) buttons=\(lightButtonFills) "
                + "ink=\(grey(lightReadoutInk))/\(grey(lightButtonInk))"
        )

        // MARK: - Same ink

        // The label used to be `.secondary` and the count `SupportingInk`
        // (primary @ 45 %); both are now the buttons' `Color.primary` label
        // ink. Rendered ink, not the source: 255 in dark means "full label".
        let readoutInk = peak(washed, CGRect(x: 20, y: 24, width: 76, height: 18))
        let buttonInk = peak(
            washed,
            CGRect(x: buttonCentres[0] - 11, y: 24, width: 22, height: 18)
        )
        check(
            "capsule: the read-out and the buttons reach the same ink",
            grey(readoutInk) >= 228
                && grey(buttonInk) >= 228
                && abs(grey(readoutInk) - grey(buttonInk)) <= 2,
            "readoutInk=\(grey(readoutInk)) buttonInk=\(grey(buttonInk))"
        )
        // Contrast, read inside one row: same ink + same fill tier ⇒ the same
        // ratio, up to the corner's few RGB of extra ground.
        let readoutContrast = contrast(
            washed,
            CGRect(x: 20, y: 23, width: 76, height: 20)
        )
        let buttonContrast = contrast(
            washed,
            CGRect(x: buttonCentres[0] - 12, y: 23, width: 24, height: 20)
        )
        if let readoutContrast, let buttonContrast {
            check(
                "capsule: the read-out reads at the buttons' contrast",
                abs(readoutContrast - buttonContrast) <= 0.35,
                "readout=\(String(format: "%.2f", readoutContrast)) "
                    + "button=\(String(format: "%.2f", buttonContrast))"
            )
        } else {
            check("capsule: the row contrast probe renders", false)
        }

        // MARK: - Bright-page stress
        //
        // A bright page lifts the glass; the dark floor used to absorb that.
        // Without it the read-out shares the buttons' ceiling: full-white ink on
        // a 10 % white capsule. `103/255` is the ground measured *behind the
        // row* on a white page, dark appearance, after the shared
        // `GlassWash.darkScrim = 0.50` (2026-10-23 capture). The raw,
        // unscrimmed glass (#8b) is printed alongside, with no floor assertion
        // of its own.
        let stressSize = CGSize(width: 260, height: 44)
        func renderStress(ground: Double, hovering: Bool) -> CGImage? {
            let root = ZStack {
                Color(white: ground)
                HStack(spacing: 6) {
                    Text("剪贴板")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("508 条")
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, CapsuleControlStyle.horizontalPadding)
                .frame(height: CapsuleControlStyle.height)
                .capsuleControlSurface(isHovering: hovering)
            }
            .frame(width: stressSize.width, height: stressSize.height)
            .environment(\.colorScheme, .dark)
            let hosting = NSHostingView(rootView: root)
            hosting.frame = CGRect(origin: .zero, size: stressSize)
            hosting.appearance = NSAppearance(named: .darkAqua)
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
            else { return nil }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            return rep.cgImage
        }
        func stressContrast(_ image: CGImage) -> Double? {
            guard let buffer = pixelBuffer(image) else { return nil }
            var samples: [(Double, Double)] = []
            let sx = CGFloat(buffer.width) / stressSize.width
            let sy = CGFloat(buffer.height) / stressSize.height
            let rect = CGRect(x: 88, y: 13, width: 84, height: 20)
            for y in Int(rect.minY * sy)..<min(buffer.height, Int(rect.maxY * sy)) {
                for x in Int(rect.minX * sx)..<min(buffer.width, Int(rect.maxX * sx)) {
                    let rgb = buffer.rgb(x: x, y: y)
                    samples.append((luminance(rgb), 0))
                }
            }
            guard !samples.isEmpty else { return nil }
            samples.sort { $0.0 < $1.0 }
            let ground = samples[samples.count / 2].0
            let ink = samples[samples.count - 1].0
            return (ink + 0.05) / (ground + 0.05)
        }

        let scrimmedGround = 103.0 / 255.0
        let rawGlassGround = 139.0 / 255.0
        if let rest = renderStress(ground: scrimmedGround, hovering: false),
           let hover = renderStress(ground: scrimmedGround, hovering: true),
           let restContrast = stressContrast(rest),
           let hoverContrast = stressContrast(hover),
           let rawRest = renderStress(ground: rawGlassGround, hovering: false)
                       .flatMap { stressContrast($0) },
           let rawHover = renderStress(ground: rawGlassGround, hovering: true)
                       .flatMap { stressContrast($0) } {
            check(
                "capsule: the bright page keeps the count above 3:1",
                restContrast >= 3.0,
                "rest=\(String(format: "%.2f", restContrast)) "
                    + "hover=\(String(format: "%.2f", hoverContrast)) "
                    + "ground=#67"
            )
            check(
                "capsule: hovering still clears 3:1 on the bright page",
                hoverContrast >= 3.0 && hoverContrast < restContrast,
                "hover=\(String(format: "%.2f", hoverContrast)) "
                    + "rest=\(String(format: "%.2f", restContrast))"
            )
            print(
                "[capsule] bright page (#67): count "
                    + "\(String(format: "%.2f", restContrast)) → "
                    + "\(String(format: "%.2f", hoverContrast)) hover"
                    + " · raw unscrimmed glass (#8b): "
                    + "\(String(format: "%.2f", rawRest)) → "
                    + "\(String(format: "%.2f", rawHover)) hover"
            )
        } else {
            check("capsule: the bright-page read-out probe renders", false)
        }
    }

    /// 深色专项: the four shortcut-slot states and the controls whose supporting
    /// ink was raised for the dark appearance.
    ///
    /// Every probe renders through `cacheDisplay` with a real `.darkAqua`
    /// hosting view, then measures the glyph ink against the slot's own fill
    /// (the brightest pixel over the median). That is the same "grey on grey"
    /// failure the settings pane had: the numbers, not the colour literals,
    /// are what the checks pin.
    private static func runDarkAppearanceAudit(into directory: URL) {
        print("[dark] --- shortcut states / supporting ink ---")

        func luminance(_ rgb: (Int, Int, Int)) -> Double {
            func channel(_ value: Int) -> Double {
                let c = Double(value) / 255
                return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(rgb.0)
                + 0.7152 * channel(rgb.1)
                + 0.0722 * channel(rgb.2)
        }
        func contrast(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Double {
            let first = max(luminance(a), luminance(b))
            let second = min(luminance(a), luminance(b))
            return (first + 0.05) / (second + 0.05)
        }
        func render<V: View>(_ view: V, size: CGSize) -> NSHostingView<V> {
            let hosting = NSHostingView(rootView: view)
            hosting.frame = CGRect(origin: .zero, size: size)
            hosting.appearance = NSAppearance(named: .darkAqua)
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            return hosting
        }
        func capture(_ hosting: NSView) -> CGImage? {
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
            else { return nil }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            return rep.cgImage
        }
        /// Ink (brightest pixel, so an antialiased 11 pt glyph still reaches its
        /// core) against the fill (median) inside `rect`, which is expressed in
        /// view points and scaled to the backing bitmap.
        func inkContrast(
            _ image: CGImage,
            viewSize: CGSize,
            rect: CGRect
        ) -> (ink: (Int, Int, Int), fill: (Int, Int, Int), ratio: Double)? {
            guard let buffer = pixelBuffer(image) else { return nil }
            let scaleX = CGFloat(buffer.width) / viewSize.width
            let scaleY = CGFloat(buffer.height) / viewSize.height
            let x0 = max(0, Int(rect.minX * scaleX))
            let x1 = min(buffer.width, Int(rect.maxX * scaleX))
            let y0 = max(0, Int(rect.minY * scaleY))
            let y1 = min(buffer.height, Int(rect.maxY * scaleY))
            guard x1 > x0, y1 > y0 else { return nil }
            var samples: [(l: Double, rgb: (Int, Int, Int))] = []
            samples.reserveCapacity((x1 - x0) * (y1 - y0))
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let rgb = buffer.rgb(x: x, y: y)
                    samples.append((luminance(rgb), rgb))
                }
            }
            samples.sort { $0.l < $1.l }
            let fill = samples[samples.count / 2].rgb
            let ink = samples[samples.count - 1].rgb
            return (ink, fill, contrast(ink, fill))
        }
        /// One slot on the real window ground, captured to its own PNG.
        func slot(
            _ name: String,
            keyCode: Int,
            modifiers: Int,
            conflict: String? = nil,
            click: Bool = false
        ) -> (image: CGImage, probe: (ink: (Int, Int, Int), fill: (Int, Int, Int), ratio: Double))? {
            let size = CGSize(width: 190, height: 48)
            let root = ZStack {
                Color(nsColor: .windowBackgroundColor)
                HotKeyRecorderView(
                    keyCode: .constant(keyCode),
                    modifiers: .constant(modifiers),
                    conflictLabel: conflict
                )
            }
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
            let hosting = render(root, size: size)
            var interactionWindow: NSWindow?
            if click {
                // A SwiftUI button only receives a click through a window, so
                // the probe gets an invisible offscreen one. The slot spans
                // x 0…110; 55 pt lands on its label, not on 默认.
                let window = NSWindow(
                    contentRect: CGRect(x: -3000, y: -3000, width: size.width, height: size.height),
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                window.contentView = hosting
                window.alphaValue = 0
                window.orderFront(nil)
                let point = CGPoint(x: 55, y: 24)
                func mouse(_ type: NSEvent.EventType) -> NSEvent {
                    NSEvent.mouseEvent(
                        with: type,
                        location: point,
                        modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber,
                        context: nil,
                        eventNumber: 0,
                        clickCount: 1,
                        pressure: 1
                    )!
                }
                window.sendEvent(mouse(.leftMouseDown))
                window.sendEvent(mouse(.leftMouseUp))
                hosting.layoutSubtreeIfNeeded()
                hosting.displayIfNeeded()
                interactionWindow = window
            }
            defer {
                interactionWindow?.orderOut(nil)
                interactionWindow?.contentView = nil
            }
            guard let image = capture(hosting),
                  let probe = inkContrast(
                      image,
                      viewSize: size,
                      rect: CGRect(x: 12, y: 10, width: 88, height: 28)
                  )
            else { return nil }
            if let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try? png.write(to: directory.appendingPathComponent("dark-hotkey-\(name).png"))
            }
            return (image, probe)
        }

        let control = Int(controlKey | optionKey | cmdKey)
        guard let unbound = slot("unbound", keyCode: 0, modifiers: 0),
              let bound = slot("bound", keyCode: Int(kVK_ANSI_A), modifiers: control),
              let recording = slot(
                  "recording",
                  keyCode: 0,
                  modifiers: 0,
                  click: true
              ),
              let conflict = slot(
                  "conflict",
                  keyCode: Int(kVK_ANSI_A),
                  modifiers: control,
                  conflict: "与「区域截图」重复"
              )
        else {
            check("dark: the four shortcut-slot probes render", false)
            return
        }

        // The unbound placeholder used to be `.secondary` already; what matters
        // is that it still reads as a slot rather than a disabled row.
        check(
            "dark: the unbound 快捷键 placeholder stays readable",
            unbound.probe.ratio >= 3.0,
            "ink=\(unbound.probe.ink) fill=\(unbound.probe.fill) "
                + "ratio=\(String(format: "%.2f", unbound.probe.ratio))"
        )
        check(
            "dark: the bound combination keeps the accent state readable",
            bound.probe.ratio >= 3.0,
            "ink=\(bound.probe.ink) fill=\(bound.probe.fill) "
                + "ratio=\(String(format: "%.2f", bound.probe.ratio))"
        )
        check(
            "dark: the recording prompt is white on the accent fill",
            recording.probe.ratio >= 3.5
                && recording.probe.fill.2 > recording.probe.fill.0 + 30,
            "ink=\(recording.probe.ink) fill=\(recording.probe.fill) "
                + "ratio=\(String(format: "%.2f", recording.probe.ratio))"
        )
        check(
            "dark: the conflict state reads red, not a second grey",
            conflict.probe.ratio >= 3.0
                && conflict.probe.ink.0 > conflict.probe.ink.1 + 30,
            "ink=\(conflict.probe.ink) fill=\(conflict.probe.fill) "
                + "ratio=\(String(format: "%.2f", conflict.probe.ratio))"
        )
        // Four states must also be four *different* surfaces, otherwise the ink
        // checks above would pass on a single washed-out slot.
        let fills = [unbound.probe.fill, bound.probe.fill, recording.probe.fill, conflict.probe.fill]
        check(
            "dark: unbound, bound, recording and conflict keep distinct fills",
            Set(fills.map { "\($0.0),\($0.1),\($0.2)" }).count == 4,
            "fills=\(fills)"
        )

        // 菜单栏 rename field: the placeholder is the canonical name, so it is
        // information rather than decoration.
        let fieldRoot = ZStack {
            Color(nsColor: .windowBackgroundColor)
            NeutralInlineTextField(
                placeholder: "打开剪贴板",
                text: .constant(""),
                width: 128
            )
        }
        .frame(width: 180, height: 44)
        .environment(\.colorScheme, .dark)
        let fieldHosting = render(fieldRoot, size: CGSize(width: 180, height: 44))
        if let fieldImage = capture(fieldHosting),
           let field = inkContrast(
               fieldImage,
               viewSize: CGSize(width: 180, height: 44),
               rect: CGRect(x: 44, y: 12, width: 104, height: 22)
           ) {
            if let png = NSBitmapImageRep(cgImage: fieldImage)
                .representation(using: .png, properties: [:]) {
                try? png.write(to: directory.appendingPathComponent("dark-rename-field.png"))
            }
            check(
                "dark: the rename placeholder survives on the dark capsule",
                field.ratio >= 3.0,
                "ink=\(field.ink) fill=\(field.fill) "
                    + "ratio=\(String(format: "%.2f", field.ratio))"
            )
        } else {
            check("dark: the rename-field probe renders", false)
        }

        // MARK: - The dark glass floor
        //
        // 深色 × 半透明 / 液态玻璃 had only been measured on a dark wallpaper.
        // Over a white page the floating panel's raw glass sat at #8b and its
        // white labels fell to 2.2–2.9:1. `GlassWash.darkScrim` is the
        // appearance-scoped floor that caps that case; this probe renders the
        // wash over the measured raw-glass value (#8b, 0.545) rather than over
        // pure white — no backdrop can make the composited glass brighter than
        // that. 浅色 is probed over white, because the check there is that the
        // floor is *absent*.
        check(
            "dark: the glass floor is a meaningful scrim, not a token tint",
            GlassWash.darkScrim >= 0.35 && GlassWash.darkScrim <= 0.65,
            "scrim=\(GlassWash.darkScrim)"
        )
        func washFloor(
            _ scheme: ColorScheme,
            base: CGFloat
        ) -> (fill: (Int, Int, Int), luminance: Double)? {
            let size = CGSize(width: 160, height: 120)
            let root = ZStack {
                Color(white: base)
                LiquidGlassWash()
            }
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, scheme)
            let hosting = NSHostingView(rootView: root)
            hosting.frame = CGRect(origin: .zero, size: size)
            hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            guard let image = capture(hosting),
                  let probe = inkContrast(
                      image,
                      viewSize: size,
                      rect: CGRect(origin: .zero, size: size)
                  )
            else { return nil }
            if let png = NSBitmapImageRep(cgImage: image)
                .representation(using: .png, properties: [:]) {
                try? png.write(to: directory.appendingPathComponent(
                    "dark-wash-floor-\(scheme == .dark ? "dark" : "light").png"
                ))
            }
            return (probe.fill, luminance(probe.fill))
        }
        // #8b is the raw composited glass measured over a white page before the
        // floor; the floor itself is what this probe is about.
        if let darkWash = washFloor(.dark, base: 0.545),
           let lightWash = washFloor(.light, base: 1.0) {
            check(
                "dark: a bright page under the dark wash stays below mid-grey",
                darkWash.luminance < 0.26,
                "fill=\(darkWash.fill) luminance=\(String(format: "%.3f", darkWash.luminance))"
            )
            check(
                "dark: the dark floor keeps white ink at ≥ 4.5:1 on the wash",
                contrast((255, 255, 255), darkWash.fill) >= 4.5,
                "fill=\(darkWash.fill) "
                    + "ratio=\(String(format: "%.2f", contrast((255, 255, 255), darkWash.fill)))"
            )
            check(
                "dark: the floor leaves the approved light wash alone",
                lightWash.luminance > 0.85
                    && darkWash.luminance < lightWash.luminance - 0.4,
                "light=\(String(format: "%.3f", lightWash.luminance)) "
                    + "dark=\(String(format: "%.3f", darkWash.luminance))"
            )
        } else {
            check("dark: the wash-floor probes render", false)
        }
        check(
            "dark: the space preview asks for the floating glass body",
            ClipPreviewView.quickLookUsesGlassChrome,
            "quickLookUsesGlassChrome=\(ClipPreviewView.quickLookUsesGlassChrome)"
        )
    }

    /// 设置 → 通用 → 钉图 → 指针反转.
    ///
    /// The direction itself is one sign flip in `PinnedImagePanel.scrollWheel`,
    /// so the test drives a real borderless panel with a real scrolling event
    /// instead of only asserting a constant.
    private static func runPinScrollInversionTests() {
        print("[pin-scroll] --- 指针反转 ---")
        let suiteName = "UnseenPinScroll-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            check("pin-scroll: create isolated defaults", false)
            return
        }
        let settings = AppSettings(defaults: defaults)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        check("pin-scroll: 指针反转 is off by default", !settings.pinScrollInverted)

        let panel = PinnedImagePanel(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        var deltas: [CGFloat] = []
        Pinboard.installWheelGestures(
            on: panel,
            settings: settings,
            zoom: { deltas.append($0) },
            opacity: { _ in }
        )

        let event = scrollEvent(deltaY: 7)
        let raw = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY
            : event.scrollingDeltaY * 3
        check("pin-scroll: the synthetic wheel carries a delta", abs(raw) > 0, "raw=\(raw)")

        panel.scrollWheel(with: event)
        let plain = deltas.last ?? 0
        check(
            "pin-scroll: the default direction is the shipped one",
            plain == raw,
            "delta=\(plain) raw=\(raw)"
        )

        // Turning it on must reach a pin that is already on screen: the panel
        // reads the live preference, so nothing has to be rebuilt.
        settings.pinScrollInverted = true
        panel.scrollWheel(with: event)
        let inverted = deltas.last ?? 0
        check(
            "pin-scroll: 指针反转 flips an existing pin's wheel",
            inverted == -plain && abs(inverted) == abs(plain),
            "plain=\(plain) inverted=\(inverted)"
        )

        check(
            "pin-scroll: the value survives a relaunch",
            AppSettings(defaults: defaults).pinScrollInverted
        )

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("unseen-pin-scroll-\(UUID().uuidString).plist")
        do {
            try settings.writePreferences(to: url)
            settings.pinScrollInverted = false
            try settings.readPreferences(from: url)
        } catch {
            check("pin-scroll: 导出 / 导入 round trip", false, "\(error)")
            try? FileManager.default.removeItem(at: url)
            return
        }
        check("pin-scroll: 导出 / 导入 carries the toggle", settings.pinScrollInverted)
        try? FileManager.default.removeItem(at: url)

        settings.resetAll()
        check("pin-scroll: 重置全部设置 returns it to the default", !settings.pinScrollInverted)
        check(
            "pin-scroll: a reset pin no longer inverts",
            {
                deltas.removeAll()
                panel.scrollWheel(with: event)
                return deltas.last == plain
            }(),
            "delta=\(String(describing: deltas.last)) plain=\(plain)"
        )
    }

    /// 设置 → 通用 → 钉图 → 滚轮缩放钉图.
    ///
    /// The toggle is one guard in `PinnedImagePanel.scrollWheel`, so this drives
    /// a real borderless panel with a real wheel event: the plain wheel must
    /// zoom while it is on, do nothing while it is off, and ⌘ + wheel must keep
    /// scrubbing opacity with the zoom switched off (⌘ has priority).
    private static func runPinScrollZoomTests() {
        print("[pin-zoom] --- 滚轮缩放钉图 ---")
        let suiteName = "UnseenPinZoom-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            check("pin-zoom: create isolated defaults", false)
            return
        }
        let settings = AppSettings(defaults: defaults)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        check("pin-zoom: 滚轮缩放 is on by default", settings.pinScrollZoom)

        let panel = PinnedImagePanel(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        var zooms: [CGFloat] = []
        var opacities: [CGFloat] = []
        Pinboard.installWheelGestures(
            on: panel,
            settings: settings,
            zoom: { zooms.append($0) },
            opacity: { opacities.append($0) }
        )

        let plain = scrollEvent(deltaY: 9)
        let command = scrollEvent(deltaY: 9, modifiers: .maskCommand)

        panel.scrollWheel(with: plain)
        check(
            "pin-zoom: the wheel zooms while the setting is on",
            zooms.count == 1 && opacities.isEmpty,
            "zooms=\(zooms.count) opacities=\(opacities.count)"
        )

        // Turning it off must reach a pin that is already on screen: the panel
        // reads the live preference instead of a snapshot from build time.
        settings.pinScrollZoom = false
        panel.scrollWheel(with: plain)
        check(
            "pin-zoom: turning it off makes an existing pin's wheel inert",
            zooms.count == 1 && opacities.isEmpty,
            "zooms=\(zooms.count) opacities=\(opacities.count)"
        )

        panel.scrollWheel(with: command)
        check(
            "pin-zoom: ⌘ + wheel still scrubs opacity while zoom is off",
            zooms.count == 1 && opacities.count == 1,
            "zooms=\(zooms.count) opacities=\(opacities.count)"
        )

        // Both wheel gestures off: the wheel is completely inert.
        settings.pinCommandScrollOpacity = false
        panel.scrollWheel(with: command)
        check(
            "pin-zoom: with both gestures off the wheel does nothing",
            zooms.count == 1 && opacities.count == 1,
            "zooms=\(zooms.count) opacities=\(opacities.count)"
        )
        settings.pinCommandScrollOpacity = true

        settings.pinScrollZoom = true
        panel.scrollWheel(with: plain)
        check(
            "pin-zoom: turning it back on reaches the existing pin",
            zooms.count == 2 && opacities.count == 1,
            "zooms=\(zooms.count) opacities=\(opacities.count)"
        )

        settings.pinScrollZoom = false
        check(
            "pin-zoom: the value survives a relaunch",
            !AppSettings(defaults: defaults).pinScrollZoom
        )

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("unseen-pin-zoom-\(UUID().uuidString).plist")
        do {
            try settings.writePreferences(to: url)
            settings.pinScrollZoom = true
            try settings.readPreferences(from: url)
        } catch {
            check("pin-zoom: 导出 / 导入 round trip", false, "\(error)")
            try? FileManager.default.removeItem(at: url)
            return
        }
        check("pin-zoom: 导出 / 导入 carries the toggle", !settings.pinScrollZoom)
        try? FileManager.default.removeItem(at: url)

        settings.resetAll()
        check(
            "pin-zoom: 重置全部设置 returns it to the default",
            settings.pinScrollZoom
        )
        check(
            "pin-zoom: a reset pin zooms again",
            {
                zooms.removeAll()
                panel.scrollWheel(with: plain)
                return zooms.count == 1
            }(),
            "zooms=\(zooms.count)"
        )
    }

    /// 设置 → 通用 → 钉图 → ⌘ + 滚轮调整钉图不透明度.
    ///
    /// The gesture is one branch in `PinnedImagePanel.scrollWheel`, so this
    /// drives a real panel with a real ⌘-modified wheel event and then a real
    /// `Pinboard` pin, proving both the routing and the value the `%` chip
    /// reads.
    private static func runPinCommandScrollOpacityTests() {
        print("[pin-opacity] --- ⌘ + 滚轮 ---")
        let suiteName = "UnseenPinOpacity-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            check("pin-opacity: create isolated defaults", false)
            return
        }
        let settings = AppSettings(defaults: defaults)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        check(
            "pin-opacity: ⌘ + 滚轮 is on by default",
            settings.pinCommandScrollOpacity
        )
        check(
            "pin-opacity: the ladder matches the toolbar menu (100/80/60/40/20)",
            PinOpacity.choices == [1.0, 0.8, 0.6, 0.4, 0.2]
        )
        check(
            "pin-opacity: the range is 20%–100%",
            PinOpacity.range == 0.2...1.0
        )
        check(
            "pin-opacity: the chip renders the same integers as the menu",
            PinOpacity.percent(1.0) == 100 && PinOpacity.percent(0.6) == 60
                && PinOpacity.percent(0.2) == 20
                && PinOpacity.percent(0.01) == 20,
            "1.0=\(PinOpacity.percent(1.0)) 0.6=\(PinOpacity.percent(0.6)) "
                + "0.2=\(PinOpacity.percent(0.2)) 0.01=\(PinOpacity.percent(0.01))"
        )

        // MARK: Routing: ⌘ takes the wheel, releasing it gives it back.

        let panel = PinnedImagePanel(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        var zooms: [CGFloat] = []
        var opacities: [CGFloat] = []
        Pinboard.installWheelGestures(
            on: panel,
            settings: settings,
            zoom: { zooms.append($0) },
            opacity: { opacities.append($0) }
        )

        let plain = scrollEvent(deltaY: -12)
        let command = scrollEvent(deltaY: -12, modifiers: .maskCommand)

        panel.scrollWheel(with: plain)
        check(
            "pin-opacity: a plain wheel still zooms",
            zooms.count == 1 && opacities.isEmpty,
            "zooms=\(zooms) opacities=\(opacities)"
        )

        panel.scrollWheel(with: command)
        check(
            "pin-opacity: ⌘ hands the wheel to opacity instead of zoom",
            zooms.count == 1 && opacities.count == 1,
            "zooms=\(zooms) opacities=\(opacities)"
        )
        check(
            "pin-opacity: the opacity gesture gets the same points of travel",
            opacities.last == plain.scrollingDeltaY * (plain.hasPreciseScrollingDeltas ? 1 : 3),
            "opacity=\(String(describing: opacities.last)) "
                + "delta=\(plain.scrollingDeltaY) precise=\(plain.hasPreciseScrollingDeltas)"
        )

        panel.scrollWheel(with: plain)
        check(
            "pin-opacity: releasing ⌘ restores zoom",
            zooms.count == 2 && opacities.count == 1,
            "zooms=\(zooms.count) opacities=\(opacities.count)"
        )

        // The preference gates the branch, not only the UI.
        settings.pinCommandScrollOpacity = false
        panel.scrollWheel(with: command)
        check(
            "pin-opacity: turning the setting off makes ⌘ scroll zoom again",
            zooms.count == 3 && opacities.count == 1,
            "zooms=\(zooms.count) opacities=\(opacities.count)"
        )
        settings.pinCommandScrollOpacity = true

        // MARK: A real pin: the value, the panel alpha and the chip state move together.

        let tempHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("unseen-pin-opacity-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        let previousHome = ProcessInfo.processInfo.environment["UNSEEN_HOME"]
        setenv("UNSEEN_HOME", tempHome.path, 1)
        defer {
            if let previousHome {
                setenv("UNSEEN_HOME", previousHome, 1)
            } else {
                unsetenv("UNSEEN_HOME")
            }
            try? FileManager.default.removeItem(at: tempHome)
        }
        let model = AppModel(settings: settings)
        model.stopMonitoring()

        let image = solidImage(width: 120, height: 80)
        guard model.pinboard.pinImage(image),
              let pin = model.pinboard.pins.first,
              let live = model.pinboard.panelForTesting(pin.id) else {
            check("pin-opacity: a pin creates a real panel", false)
            return
        }
        model.pinboard.setVisible(pin.id, false)
        check(
            "pin-opacity: a fresh pin is fully opaque",
            abs(pin.opacity - 1) < 0.0001
                && abs(live.alphaValue - 1) < 0.0001
                && abs((live.pinState?.opacity ?? 0) - 1) < 0.0001
        )

        // One ⌘ scroll down of 40 points is 40 % of the range.
        live.scrollWheel(with: scrollEvent(deltaY: -40, modifiers: .maskCommand))
        let afterDown = model.pinboard.pins.first?.opacity ?? 0
        check(
            "pin-opacity: ⌘ + wheel lowers the pin's opacity",
            abs(afterDown - 0.6) < 0.0001,
            "opacity=\(afterDown)"
        )
        check(
            "pin-opacity: the panel alpha and the chip state follow the gesture",
            abs(live.alphaValue - 0.6) < 0.0001
                && abs((live.pinState?.opacity ?? 0) - 0.6) < 0.0001,
            "alpha=\(live.alphaValue) chip=\(String(describing: live.pinState?.opacity))"
        )
        check(
            "pin-opacity: the chip would read 60%",
            PinOpacity.percent(live.pinState?.opacity ?? 0) == 60
        )

        // The same clamp as the menu: never below 20 %, never above 100 %.
        live.scrollWheel(with: scrollEvent(deltaY: -1000, modifiers: .maskCommand))
        let floor = model.pinboard.pins.first?.opacity ?? 0
        check(
            "pin-opacity: scrolling down stops at 20%",
            abs(floor - 0.2) < 0.0001 && PinOpacity.percent(floor) == 20,
            "opacity=\(floor)"
        )
        live.scrollWheel(with: scrollEvent(deltaY: 1000, modifiers: .maskCommand))
        let ceiling = model.pinboard.pins.first?.opacity ?? 0
        check(
            "pin-opacity: scrolling up stops at 100%",
            abs(ceiling - 1) < 0.0001 && PinOpacity.percent(ceiling) == 100,
            "opacity=\(ceiling)"
        )

        // The gesture must not move the window; the plain wheel still does.
        let widthBefore = model.pinboard.pins.first?.width ?? 0
        live.scrollWheel(with: scrollEvent(deltaY: -40, modifiers: .maskCommand))
        let widthAfterOpacity = model.pinboard.pins.first?.width ?? 0
        check(
            "pin-opacity: the opacity gesture never resizes the pin",
            abs(widthAfterOpacity - widthBefore) < 0.0001,
            "before=\(widthBefore) after=\(widthAfterOpacity)"
        )
        live.scrollWheel(with: scrollEvent(deltaY: 40))
        let widthAfterZoom = model.pinboard.pins.first?.width ?? 0
        check(
            "pin-opacity: the same pin still zooms on a plain wheel",
            widthAfterZoom > widthAfterOpacity,
            "before=\(widthAfterOpacity) after=\(widthAfterZoom)"
        )

        // A tap on the chip menu still lands on a real rung.
        model.pinboard.setOpacity(pin.id, 0.4)
        check(
            "pin-opacity: the menu's 40% preset writes the same channel",
            abs((model.pinboard.pins.first?.opacity ?? 0) - 0.4) < 0.0001
                && abs(live.alphaValue - 0.4) < 0.0001
                && PinOpacity.percent(live.pinState?.opacity ?? 0) == 40
        )

        model.pinboard.unpin(pin.id)
        check("pin-opacity: the harness pin is cleaned up", model.pinboard.count == 0)
    }

    /// A flat-colour image for the pin harness (no screen access needed).
    private static func solidImage(width: Int, height: Int) -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) ?? NSBitmapImageRep()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemPink.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }

    private static func runHoverHighlightTests(into directory: URL) {
        print("[hover] --- one wash for every row ---")
        check(
            "hover: the wash is one notch fainter than selection",
            SelectionStyle.hoverOpacity < SelectionStyle.fillOpacity,
            "hover=\(SelectionStyle.hoverOpacity) selected=\(SelectionStyle.fillOpacity)"
        )
        check(
            "hover: the wash is a 6 % primary tint",
            abs(SelectionStyle.hoverOpacity - 0.06) < 0.0001,
            "hover=\(SelectionStyle.hoverOpacity)"
        )
        check(
            "hover: the fade is short (<= 0.15 s) so it tracks the pointer",
            SelectionStyle.hoverDuration > 0 && SelectionStyle.hoverDuration <= 0.15,
            "duration=\(SelectionStyle.hoverDuration)"
        )
        let lightHover = SelectionStyle.resolvedHoverFill(for: NSAppearance(named: .aqua)!)
        let darkHover = SelectionStyle.resolvedHoverFill(for: NSAppearance(named: .darkAqua)!)
        let lightFill = SelectionStyle.resolvedFill(for: NSAppearance(named: .aqua)!)
        let darkFill = SelectionStyle.resolvedFill(for: NSAppearance(named: .darkAqua)!)
        check(
            "hover: every row uses the same corner radius as the selection chip",
            SelectionStyle.cornerRadius == 7,
            "radius=\(SelectionStyle.cornerRadius)"
        )
        check(
            "hover: the resolved alpha stays below selection in light and dark",
            lightHover.alphaComponent > 0
                && darkHover.alphaComponent > 0
                && lightHover.alphaComponent < lightFill.alphaComponent
                && darkHover.alphaComponent < darkFill.alphaComponent,
            "light=\(lightHover.alphaComponent)/\(lightFill.alphaComponent) "
                + "dark=\(darkHover.alphaComponent)/\(darkFill.alphaComponent)"
        )
        check(
            "hover: the wash is neutral, not an accent colour",
            isNeutral(lightHover) && isNeutral(darkHover),
            "light=\(components(lightHover)) dark=\(components(darkHover))"
        )

        print("[hover] --- rendered proof (pinned hover state) ---")
        let probeSize = CGSize(width: 260, height: 44)
        // A white canvas under a light appearance makes the tint unambiguous:
        // `Color.primary` is black, so idle is 255, the hover wash lands around
        // 245 and the selected chip around 234 (read back through a device-RGB
        // context, which is a couple of points off the nominal alpha — hence the
        // "darker by at least 8" assertions instead of exact values).
        func render(hovering: Bool, selected: Bool, enabled: Bool = true) -> CGImage? {
            let root = ZStack {
                Color.white
                HoverProbeRow(
                    title: "标注",
                    selected: selected,
                    hovering: hovering,
                    enabled: enabled
                )
            }
            .frame(width: probeSize.width, height: probeSize.height)
            let hosting = NSHostingView(rootView: root)
            hosting.frame = CGRect(origin: .zero, size: probeSize)
            hosting.appearance = NSAppearance(named: .aqua)
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
            else { return nil }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                let name = "hover-probe-"
                    + (selected ? "selected" : "idle")
                    + (hovering ? "-hover" : "")
                    + (enabled ? "" : "-disabled")
                    + ".png"
                try? png.write(to: directory.appendingPathComponent(name))
            }
            return rep.cgImage
        }

        /// Read the row's right-hand end: no glyph, no value, only the wash.
        func wash(_ image: CGImage) -> (r: Int, g: Int, b: Int)? {
            guard let sample = pixel(image, x: image.width - 24, y: image.height / 2)
            else { return nil }
            return (sample.r, sample.g, sample.b)
        }

        guard let idle = render(hovering: false, selected: false).flatMap(wash),
              let hover = render(hovering: true, selected: false).flatMap(wash),
              let pick = render(hovering: false, selected: true).flatMap(wash),
              let pickHover = render(hovering: true, selected: true).flatMap(wash),
              let disabledHover = render(hovering: true, selected: false, enabled: false)
                .flatMap(wash)
        else {
            check("hover: the probe row renders", false)
            return
        }

        check(
            "hover: hovering alone darkens the row",
            idle.r - hover.r >= 8,
            "idle=\(idle.r) hover=\(hover.r)"
        )
        check(
            "hover: the wash is fainter than the selected chip",
            pick.r < hover.r && hover.r - pick.r >= 8,
            "hover=\(hover.r) selected=\(pick.r)"
        )
        check(
            "hover: a selected row does not stack the hover wash",
            abs(pickHover.r - pick.r) <= 1
                && abs(pickHover.g - pick.g) <= 1
                && abs(pickHover.b - pick.b) <= 1,
            "selected=\(pick) selected+hover=\(pickHover)"
        )
        check(
            "hover: a disabled row never shows the wash",
            abs(disabledHover.r - idle.r) <= 1,
            "idle=\(idle.r) disabled-hover=\(disabledHover.r)"
        )
        print(
            "[hover] idle rgb=\(idle) hover rgb=\(hover) selected rgb=\(pick) "
                + "selected+hover rgb=\(pickHover)"
        )
    }

    // MARK: - Preview plate

    /// The preview pane's background, pinned.
    ///
    /// It used to be a deliberately dark stage — `Color(white: 0.10)` 深色 /
    /// `0.22` 浅色 — which read as a black hole cut into a translucent window;
    /// the owner asked for "和软件的背景搞成一样". These checks measure the
    /// replacement rather than restating it:
    ///
    /// * 纯色 — the plate *is* `windowBackgroundColor`, in both appearances.
    /// * 液态玻璃 / 半透明 — the plate is the same `GlassWash.inset` wash the
    ///   left column's list already paints over its card, so the two cannot
    ///   drift apart, and both glass tiers paint the same thing.
    private static func runPreviewPlateTests(into directory: URL) {
        let previousBackground = AppearanceRuntime.backgroundStyle
        defer { AppearanceRuntime.backgroundStyle = previousBackground }

        let size = CGSize(width: 120, height: 80)

        /// Render one probe view offscreen and read the middle of both halves.
        func samples<Content: View>(
            _ content: Content,
            scheme: NSAppearance.Name
        ) -> (Int, Int, Int)? {
            let hosting = NSHostingView(
                rootView: content.frame(width: size.width, height: size.height)
            )
            hosting.frame = CGRect(origin: .zero, size: size)
            hosting.appearance = NSAppearance(named: scheme)
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
            else { return nil }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let image = rep.cgImage,
                  let sample = pixel(image, x: Int(size.width / 2), y: Int(size.height / 2))
            else { return nil }
            return (sample.r, sample.g, sample.b)
        }

        /// Left half: the app background itself. Right half: the preview plate.
        func pair(
            _ background: AppBackgroundStyle,
            scheme: NSAppearance.Name
        ) -> (background: (Int, Int, Int), plate: (Int, Int, Int))? {
            AppearanceRuntime.backgroundStyle = background
            let root = HStack(spacing: 0) {
                Color(nsColor: .windowBackgroundColor)
                Color.clear.previewPlate(cornerRadius: 0)
            }
            let hosting = NSHostingView(
                rootView: root.frame(width: size.width, height: size.height)
            )
            hosting.frame = CGRect(origin: .zero, size: size)
            hosting.appearance = NSAppearance(named: scheme)
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
            else { return nil }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let image = rep.cgImage,
                  let left = pixel(image, x: Int(size.width * 0.25), y: Int(size.height / 2)),
                  let right = pixel(image, x: Int(size.width * 0.75), y: Int(size.height / 2))
            else { return nil }
            if let png = rep.representation(using: .png, properties: [:]) {
                let name = "preview-plate-\(background.rawValue)-"
                    + (scheme == .darkAqua ? "dark" : "light") + ".png"
                try? png.write(to: directory.appendingPathComponent(name))
            }
            return ((left.r, left.g, left.b), (right.r, right.g, right.b))
        }

        print("[preview-plate] --- 纯色: the plate is the window's own colour ---")
        guard let solidLight = pair(.solid, scheme: .aqua),
              let solidDark = pair(.solid, scheme: .darkAqua)
        else {
            check("preview: the plate probe renders", false)
            return
        }
        func near(_ lhs: (Int, Int, Int), _ rhs: (Int, Int, Int), _ tolerance: Int = 1) -> Bool {
            abs(lhs.0 - rhs.0) <= tolerance
                && abs(lhs.1 - rhs.1) <= tolerance
                && abs(lhs.2 - rhs.2) <= tolerance
        }
        check(
            "preview: 纯色 paints the preview plate in windowBackgroundColor (浅色)",
            near(solidLight.background, solidLight.plate),
            "window=\(solidLight.background) plate=\(solidLight.plate)"
        )
        check(
            "preview: 纯色 paints the preview plate in windowBackgroundColor (深色)",
            near(solidDark.background, solidDark.plate),
            "window=\(solidDark.background) plate=\(solidDark.plate)"
        )
        // The trap this replaces: a near-black plate in 浅色 (56/56/56) and an
        // even darker one in 深色 (25/25/25). Neither appearance may go back.
        check(
            "preview: the plate is not a dark stage any more (浅色)",
            solidLight.plate.0 > 200,
            "plate=\(solidLight.plate)"
        )
        check(
            "preview: the plate is not a dark stage any more (深色)",
            solidDark.plate.0 > 40 && solidDark.plate.0 != 25,
            "plate=\(solidDark.plate)"
        )

        print("[preview-plate] --- glass tiers: the same wash as the left list ---")
        // The list side paints `GlassWash.fill(GlassWash.inset)` over its card;
        // the preview plate has to be that exact colour, not a private tint.
        func washReference(
            _ background: AppBackgroundStyle,
            scheme: NSAppearance.Name
        ) -> (Int, Int, Int)? {
            AppearanceRuntime.backgroundStyle = background
            let root = ZStack {
                Color(white: 0.55)
                Color.clear.background { GlassWash.fill(GlassWash.inset) }
            }
            return samples(root, scheme: scheme)
        }
        func plateOverGrey(
            _ background: AppBackgroundStyle,
            scheme: NSAppearance.Name
        ) -> (Int, Int, Int)? {
            AppearanceRuntime.backgroundStyle = background
            let root = ZStack {
                Color(white: 0.55)
                Color.clear.previewPlate(cornerRadius: 0)
            }
            return samples(root, scheme: scheme)
        }
        for scheme: NSAppearance.Name in [.aqua, .darkAqua] {
            let label = scheme == .darkAqua ? "深色" : "浅色"
            for background in [AppBackgroundStyle.liquidGlass, .translucent] {
                guard let wash = washReference(background, scheme: scheme),
                      let plate = plateOverGrey(background, scheme: scheme)
                else {
                    check("preview: the \(background.rawValue) plate probe renders (\(label))", false)
                    continue
                }
                check(
                    "preview: \(background.title) \(label) paints the list's inset wash",
                    near(wash, plate),
                    "wash=\(wash) plate=\(plate)"
                )
            }
        }
        // The action bar under 复制 / 粘贴 / 固定 is the same bottom as the
        // plate above it. It used to be a live GlassBackdrop + LiquidGlassWash
        // layer, which read as a seam 20 pt under the picture.
        func actionBarOverGrey(
            _ background: AppBackgroundStyle,
            scheme: NSAppearance.Name
        ) -> (Int, Int, Int)? {
            AppearanceRuntime.backgroundStyle = background
            let root = ZStack {
                Color(white: 0.55)
                Color.clear.background { PreviewActionBarSurface() }
            }
            return samples(root, scheme: scheme)
        }
        for scheme: NSAppearance.Name in [.aqua, .darkAqua] {
            let label = scheme == .darkAqua ? "深色" : "浅色"
            for background in [AppBackgroundStyle.solid, .liquidGlass, .translucent] {
                guard let plate = plateOverGrey(background, scheme: scheme),
                      let bar = actionBarOverGrey(background, scheme: scheme)
                else {
                    check("preview: the \(background.rawValue) action-bar probe renders (\(label))", false)
                    continue
                }
                check(
                    "preview: \(background.title) \(label) paints the action bar in the plate's bottom",
                    near(plate, bar),
                    "plate=\(plate) bar=\(bar)"
                )
                if background == .liquidGlass {
                    AppearanceRuntime.backgroundStyle = background
                    let host = NSHostingView(
                        rootView: ZStack {
                            Color(white: 0.55)
                            Color.clear.background { PreviewActionBarSurface() }
                        }.frame(width: size.width, height: size.height)
                    )
                    host.frame = CGRect(origin: .zero, size: size)
                    host.appearance = NSAppearance(named: scheme)
                    host.layoutSubtreeIfNeeded()
                    host.displayIfNeeded()
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        if let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(
                                to: directory.appendingPathComponent(
                                    "preview-action-bar-\(label).png"
                                )
                            )
                        }
                    }
                }
            }
        }

        guard let glassLight = plateOverGrey(.liquidGlass, scheme: .aqua),
              let translucLight = plateOverGrey(.translucent, scheme: .aqua)
        else {
            check("preview: both glass tiers render", false)
            return
        }
        check(
            "preview: 液态玻璃 and 半透明 paint the same plate",
            near(glassLight, translucLight),
            "liquid=\(glassLight) translucent=\(translucLight)"
        )
        print(
            "[preview-plate] 纯色 light plate=\(solidLight.plate) window=\(solidLight.background) "
                + "dark plate=\(solidDark.plate) window=\(solidDark.background)"
        )
    }

    // MARK: - 外观 → 主题 (one card, two sliders)

    /// 外观 is one 主题 card: 外观 / 风格, then **two** opacity sliders —
    /// 背景不透明度 (the window wash) and 板块不透明度 (the three columns).
    ///
    /// 2026-10-25 history: the card shipped with one slider for both layers, an
    /// early two-slider attempt was withdrawn, and the owner then asked for two
    /// explicitly ("滑条还是改成两个，一个控制背景，一个控制三个板块"). These checks pin
    /// the accepted shape: the split keys, the unchanged defaults, the panel
    /// plate moving with 板块不透明度 (so 0 % really clears a card), and the
    /// independence of the two dimensions.
    private static func runAppearanceTopicTests() {
        print("[appearance] --- 主题: 外观 / 风格 / 不透明度 ---")
        let appearanceGroups = SettingsSection.appearance.pageGroups
        check(
            "appearance: the page is 主题 then 图标",
            appearanceGroups.map(\.id) == [PageGroupID.theme, PageGroupID.iconColour]
                && appearanceGroups.map(\.title) == ["主题", "图标"],
            "groups=\(appearanceGroups.map { "\($0.id)/\($0.title)" })"
        )
        check(
            "appearance: 主题 is the first group the page lands on",
            appearanceGroups.first?.id == PageGroupID.theme
                && PageGroupID.theme == "theme"
        )
        check(
            "appearance: 风格 offers 液态玻璃 / 半透明 / 实色 in this order",
            AppBackgroundStyle.displayOrder.map(\.title) == ["液态玻璃", "半透明", "实色"],
            "titles=\(AppBackgroundStyle.displayOrder.map(\.title))"
        )
        check(
            "appearance: the opaque style is called 实色 now",
            AppBackgroundStyle.solid.title == "实色"
                && AppBackgroundStyle.solid.detail.hasPrefix("不透明实色")
        )
        check(
            "appearance: the three columns use a 6 % coat over a depth plate",
            abs(GlassWash.card - 0.06) < 1e-9
                && abs(GlassWash.columnPlateLight - 0.045) < 1e-9
                && abs(GlassWash.columnPlateDark - 0.08) < 1e-9
                && GlassWash.slab == 0.20
                && GlassWash.inset == 0.10,
            "coat=\(GlassWash.card) plate=\(GlassWash.columnPlateLight)/"
                + "\(GlassWash.columnPlateDark) slab=\(GlassWash.slab) "
                + "inset=\(GlassWash.inset)"
        )

        // MARK: the two opacity sliders (2026-10-25)
        //
        // 背景不透明度 (`glassOpacity`) owns the window wash; 板块不透明度
        // (`panelOpacity`) owns the three column cards, their depth plate and the
        // nested slabs / insets. The runtime is a shared singleton, so every
        // probe below restores both values.
        let savedWindowWash = GlassOpacityRuntime.shared.windowWashDark
        let savedPanelWash = GlassOpacityRuntime.shared.panelWash
        defer {
            GlassOpacityRuntime.shared.apply(savedWindowWash)
            GlassOpacityRuntime.shared.applyPanel(savedPanelWash)
        }
        GlassOpacityRuntime.shared.apply(GlassOpacityRuntime.defaultValue)
        GlassOpacityRuntime.shared.applyPanel(GlassOpacityRuntime.panelDefaultValue)

        check(
            "appearance: 板块不透明度 ships the same 8 % the one slider did",
            abs(GlassOpacityRuntime.panelDefaultValue - 0.08) < 1e-9
                && GlassOpacityRuntime.panelDefaultValue
                    == GlassOpacityRuntime.defaultValue,
            "panel=\(GlassOpacityRuntime.panelDefaultValue) "
                + "window=\(GlassOpacityRuntime.defaultValue)"
        )
        /// The panel coat's resolved alpha for one tier at the current slider.
        func panelAlpha(_ tier: Double) -> Double {
            NSColor(GlassWash.fill(tier)).alphaComponent
        }
        // The split must not move the shipped look: at the panel default the coat
        // is 0.06 × (0.08 / 0.15) = 0.032 — exactly the pre-split number — and
        // `panelPlateScale` is exactly 1, so the authored 4.5 % / 8 % plate is
        // untouched too.
        let coastAtPanelDefault = panelAlpha(GlassWash.card)
        let plateScaleAtDefault = GlassOpacityRuntime.shared.panelPlateScale
        check(
            "appearance: the panel default reproduces the pre-split card stack",
            abs(coastAtPanelDefault - 0.06 * (0.08 / 0.15)) < 1e-6
                && abs(plateScaleAtDefault - 1) < 1e-9,
            "coat=\(coastAtPanelDefault) plateScale=\(plateScaleAtDefault)"
        )
        // A window-coloured plate is what made the columns *lighter* than the
        // window in 浅色: the window background is pure white there. The plate
        // has to be a dark wash in both appearances.
        let lightColumnPlate = GlassSurfaceFactory.columnPlateColor(dark: false)
        let darkColumnPlate = GlassSurfaceFactory.columnPlateColor(dark: true)
        let lightColumnComponents = lightColumnPlate.usingColorSpace(.sRGB)!
        let darkColumnComponents = darkColumnPlate.usingColorSpace(.sRGB)!
        check(
            "appearance: the column plate is a black depth wash in both appearances",
            lightColumnComponents.redComponent < 0.02
                && lightColumnComponents.greenComponent < 0.02
                && lightColumnComponents.blueComponent < 0.02
                && darkColumnComponents.redComponent < 0.02
                && abs(lightColumnComponents.alphaComponent - 0.045) < 1e-9
                && abs(darkColumnComponents.alphaComponent - 0.08) < 1e-9,
            "light=\(components(lightColumnPlate)) dark=\(components(darkColumnPlate))"
        )

        // 0 % has to *really* clear the card: the owner's complaint was that the
        // fixed plate survived the slider, so the three blocks never went away.
        // Both the coat and the plate now read 板块不透明度.
        GlassOpacityRuntime.shared.applyPanel(GlassOpacityRuntime.range.lowerBound)
        let coatAtPanelZero = panelAlpha(GlassWash.card)
        let slabAtPanelZero = panelAlpha(GlassWash.slab)
        let insetAtPanelZero = panelAlpha(GlassWash.inset)
        let plateAtPanelZero = GlassSurfaceFactory.columnPlateColor(dark: false).alphaComponent
        let darkPlateAtPanelZero = GlassSurfaceFactory.columnPlateColor(dark: true).alphaComponent
        check(
            "appearance: 板块不透明度 0 erases the coat, the slabs and the plate",
            coatAtPanelZero < 1e-9
                && slabAtPanelZero < 1e-9
                && insetAtPanelZero < 1e-9
                && plateAtPanelZero < 1e-9
                && darkPlateAtPanelZero < 1e-9,
            "coat=\(coatAtPanelZero) slab=\(slabAtPanelZero) inset=\(insetAtPanelZero) "
                + "plate=\(plateAtPanelZero)/\(darkPlateAtPanelZero)"
        )
        // 100 % has to be clearly deeper, not lighter: the coat alone cannot do
        // that (it is `windowBackgroundColor`, which is white in 浅色), so the
        // plate deepens with the slider and carries the top of the range.
        GlassOpacityRuntime.shared.applyPanel(GlassOpacityRuntime.range.upperBound)
        // The coat is the nap, not the depth: it stops growing at the 0.15
        // recipe (0.06 card / 0.20 slab) and the plate carries the rest, so the
        // columns get *deeper* toward 100 % instead of turning into white sheets
        // (the 0.5 grey probe measured the list area at 199 where the card
        // border read 148 before this cap).
        GlassOpacityRuntime.shared.applyPanel(GlassOpacityRuntime.referenceWash)
        let coatAtRecipe = panelAlpha(GlassWash.card)
        GlassOpacityRuntime.shared.applyPanel(GlassOpacityRuntime.range.upperBound)
        let coatAtPanelFull = panelAlpha(GlassWash.card)
        let slabAtPanelFull = panelAlpha(GlassWash.slab)
        let plateAtPanelFull = GlassSurfaceFactory.columnPlateColor(dark: false).alphaComponent
        let darkPlateAtPanelFull = GlassSurfaceFactory.columnPlateColor(dark: true).alphaComponent
        check(
            "appearance: 板块不透明度 100 deepens the plate, not the white coat",
            abs(coatAtPanelFull - 0.06) < 1e-6
                && abs(coatAtPanelFull - coatAtRecipe) < 1e-9
                && abs(slabAtPanelFull - 0.20) < 1e-6
                && plateAtPanelFull > 0.5
                && darkPlateAtPanelFull > 0.99,
            "coat=\(coatAtPanelFull) coat@15%=\(coatAtRecipe) "
                + "slab=\(slabAtPanelFull) "
                + "plate=\(plateAtPanelFull)/\(darkPlateAtPanelFull)"
        )
        // The two dimensions are independent. Moving 背景不透明度 must not touch a
        // single panel alpha (and vice versa); that is what the owner's
        // "两个维度独立" means in numbers.
        GlassOpacityRuntime.shared.applyPanel(GlassOpacityRuntime.panelDefaultValue)
        GlassOpacityRuntime.shared.apply(0)
        let panelProbeAtWindowZero = (
            panelAlpha(GlassWash.card),
            panelAlpha(GlassWash.slab),
            GlassSurfaceFactory.columnPlateColor(dark: false).alphaComponent,
            GlassOpacityRuntime.shared.panelScale
        )
        GlassOpacityRuntime.shared.apply(GlassOpacityRuntime.range.upperBound)
        let panelProbeAtWindowFull = (
            panelAlpha(GlassWash.card),
            panelAlpha(GlassWash.slab),
            GlassSurfaceFactory.columnPlateColor(dark: false).alphaComponent,
            GlassOpacityRuntime.shared.panelScale
        )
        check(
            "appearance: 背景不透明度 never moves the panel layer",
            panelProbeAtWindowZero.0 == panelProbeAtWindowFull.0
                && panelProbeAtWindowZero.1 == panelProbeAtWindowFull.1
                && panelProbeAtWindowZero.2 == panelProbeAtWindowFull.2
                && panelProbeAtWindowZero.3 == panelProbeAtWindowFull.3,
            "panel@bg0=\(panelProbeAtWindowZero) panel@bg1=\(panelProbeAtWindowFull)"
        )
        GlassOpacityRuntime.shared.apply(GlassOpacityRuntime.defaultValue)
        let windowWashAtPanelDefault = GlassOpacityRuntime.shared.windowWashDark
        let lightWashAtPanelDefault = GlassOpacityRuntime.shared.windowWash(for: .light)
        GlassOpacityRuntime.shared.applyPanel(0)
        let windowWashAtPanelZero = GlassOpacityRuntime.shared.windowWashDark
        let lightWashAtPanelZero = GlassOpacityRuntime.shared.windowWash(for: .light)
        GlassOpacityRuntime.shared.applyPanel(1)
        let windowWashAtPanelFull = GlassOpacityRuntime.shared.windowWashDark
        let lightWashAtPanelFull = GlassOpacityRuntime.shared.windowWash(for: .light)
        check(
            "appearance: 板块不透明度 never moves the window wash",
            windowWashAtPanelZero == windowWashAtPanelFull
                && windowWashAtPanelZero == windowWashAtPanelDefault
                && lightWashAtPanelZero == lightWashAtPanelFull
                && lightWashAtPanelZero == lightWashAtPanelDefault
                && abs(windowWashAtPanelDefault - 0.08) < 1e-9,
            "dark=\(windowWashAtPanelZero)/\(windowWashAtPanelDefault)/\(windowWashAtPanelFull) "
                + "light=\(lightWashAtPanelZero)/\(lightWashAtPanelDefault)/\(lightWashAtPanelFull)"
        )
        // A hand-edited defaults file must not reach the renderer unclamped.
        check(
            "appearance: 板块不透明度 clamps to 0–1 and rejects NaN",
            AppSettings.clampedPanelOpacity(-2) == 0
                && AppSettings.clampedPanelOpacity(7) == 1
                && AppSettings.clampedPanelOpacity(0.37) == 0.37
                && AppSettings.clampedPanelOpacity(.nan) == GlassOpacityRuntime.panelDefaultValue,
            "lo=\(AppSettings.clampedPanelOpacity(-2)) "
                + "hi=\(AppSettings.clampedPanelOpacity(7)) "
                + "nan=\(AppSettings.clampedPanelOpacity(.nan))"
        )
        // The labels must name their own layer: two sliders both reading
        // 不透明度 was exactly what the owner ruled out.
        check(
            "appearance: the two sliders are labelled by layer",
            SettingsView.appearanceOpacityLabels == ["背景不透明度", "板块不透明度"]
                && Set(SettingsView.appearanceOpacityLabels).count == 2,
            "labels=\(SettingsView.appearanceOpacityLabels)"
        )
        check(
            "appearance: the footer explains both sliders and the 实色 caveat",
            SettingsView.appearanceOpacityFooter.contains("背景不透明度")
                && SettingsView.appearanceOpacityFooter.contains("板块不透明度")
                && SettingsView.appearanceOpacityFooter.contains("互不影响")
                && SettingsView.appearanceOpacityFooter.contains("实色"),
            "footer=\(SettingsView.appearanceOpacityFooter)"
        )
        check(
            "appearance: 实色 disables both sliders and says why",
            SettingsView.appearanceSolidOpacityNote.contains("实色")
                && SettingsView.appearanceSolidOpacityNote.contains("禁用"),
            "note=\(SettingsView.appearanceSolidOpacityNote)"
        )
        GlassOpacityRuntime.shared.apply(savedWindowWash)
        GlassOpacityRuntime.shared.applyPanel(savedPanelWash)

        // The bug behind the dark columns: `windowBackgroundColor` is a dynamic
        // colour. Resolved without the surface's own appearance it used the
        // *process* appearance (深色 on this machine) even inside a forced-浅色
        // window, so the flat plate was near-black in a light card.
        let lightPlate = GlassSurfaceFactory.liquidGlassTint(
            0.20, appearance: NSAppearance(named: .aqua)!
        )
        let darkPlate = GlassSurfaceFactory.liquidGlassTint(
            0.20, appearance: NSAppearance(named: .darkAqua)!
        )
        let lightComponents = lightPlate.usingColorSpace(.sRGB)!
        let darkComponents = darkPlate.usingColorSpace(.sRGB)!
        check(
            "appearance: the card plate resolves 浅色 white and 深色 near-black",
            lightComponents.redComponent > 0.6
                && darkComponents.redComponent < 0.3
                && abs(lightComponents.alphaComponent - 0.20) < 1e-9,
            "light=\(components(lightPlate)) dark=\(components(darkPlate))"
        )
        let lightCard = GlassSurfaceFactory.makeBackdrop(
            cornerRadius: 12,
            style: .clear,
            plateColor: lightColumnPlate,
            offscreen: false,
            appearance: NSAppearance(named: .aqua)!,
            backgroundStyle: .liquidGlass,
            glassAllowed: true
        )
        check(
            "appearance: the column plate alpha and colour reach the AppKit tint",
            abs((lightCard.layer?.backgroundColor?.alpha ?? -1) - 0.045) < 1e-6
                && (lightCard.layer?.backgroundColor?.components?.first ?? 1) < 0.02,
            "alpha=\(lightCard.layer?.backgroundColor?.alpha ?? -1) "
                + "colour=\(String(describing: lightCard.layer?.backgroundColor?.components))"
        )
        // 实色 / offscreen cards must resolve in the same appearance too.
        let solidCard = GlassSurfaceFactory.makeBackdrop(
            cornerRadius: 12,
            style: .clear,
            offscreen: true,
            appearance: NSAppearance(named: .aqua)!,
            backgroundStyle: .solid,
            glassAllowed: true
        )
        check(
            "appearance: the opaque card resolves in 浅色, not the system 深色",
            (solidCard.layer?.backgroundColor?.components?.first ?? 0) > 0.6,
            "colour=\(String(describing: solidCard.layer?.backgroundColor?.components))"
        )

        // Render the 主题 card and count its sliders: exactly one.
        let tempHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("unseen-appearance-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        let previousHome = ProcessInfo.processInfo.environment["UNSEEN_HOME"]
        setenv("UNSEEN_HOME", tempHome.path, 1)
        defer {
            if let previousHome { setenv("UNSEEN_HOME", previousHome, 1) }
            else { unsetenv("UNSEEN_HOME") }
            try? FileManager.default.removeItem(at: tempHome)
        }
        let suiteName = "UnseenAppearance-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            check("appearance: create isolated defaults", false)
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.glassOpacity = 0.42
        settings.panelOpacity = 0.66
        let model = AppModel(settings: settings)
        model.stopMonitoring()
        func renderAppearance(solid: Bool = false) -> (NSHostingView<SettingsView>, [NSSlider]) {
            settings.backgroundStyle = solid ? "solid" : "liquidGlass"
            let hosting = NSHostingView(
                rootView: SettingsView(
                    model: model,
                    section: .appearance,
                    groupID: PageGroupID.theme
                )
            )
            hosting.frame = CGRect(x: 0, y: 0, width: 760, height: 620)
            hosting.appearance = NSAppearance(named: .darkAqua)
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            return (hosting, subviews(of: NSSlider.self, in: hosting))
        }
        let (_, sliders) = renderAppearance()
        check(
            "appearance: the 主题 card draws exactly two opacity sliders",
            sliders.count == 2,
            "sliders=\(sliders.count)"
        )
        check(
            "appearance: both sliders span 0–1",
            sliders.allSatisfy { $0.minValue == 0 && $0.maxValue == 1 },
            "ranges=\(sliders.map { "\($0.minValue)…\($0.maxValue)" })"
        )
        // Draw order is 背景不透明度 first (the window layer), 板块不透明度
        // second. Their *values* prove each one is bound to its own key: 0.42 is
        // only ever written to glassOpacity and 0.66 only to panelOpacity.
        check(
            "appearance: the sliders are bound to glassOpacity then panelOpacity",
            sliders.count == 2
                && abs(sliders[0].doubleValue - 0.42) < 1e-6
                && abs(sliders[1].doubleValue - 0.66) < 1e-6,
            "values=\(sliders.map(\.doubleValue)) glass=\(settings.glassOpacity) "
                + "panel=\(settings.panelOpacity)"
        )
        // 实色 has no glass layer at all, so both sliders are disabled and the
        // card explains why. The sliders still exist (the layout does not jump).
        let (_, solidSliders) = renderAppearance(solid: true)
        check(
            "appearance: 实色 disables both sliders",
            solidSliders.count == 2 && solidSliders.allSatisfy { !$0.isEnabled },
            "enabled=\(solidSliders.map(\.isEnabled))"
        )
        renderAppearance()
        // The new key has to behave like every other appearance preference, not
        // just render: persist, export, and come back to its default on reset.
        let persisted = AppSettings(defaults: defaults)
        persisted.panelOpacity = 0.37
        let reread = AppSettings(defaults: defaults)
        check(
            "appearance: 板块不透明度 persists and reloads through UserDefaults",
            abs(reread.panelOpacity - 0.37) < 1e-6
                && abs(reread.glassOpacity - 0.42) < 1e-6,
            "panel=\(reread.panelOpacity) glass=\(reread.glassOpacity)"
        )
        check(
            "appearance: 板块不透明度 is in the exported / resettable key set",
            AppSettings.exportedKeys.contains("panelOpacity")
                && AppSettings.exportedKeys.contains("glassOpacity"),
            "exported=\(AppSettings.exportedKeys.count) keys, hasPanel="
                + "\(AppSettings.exportedKeys.contains("panelOpacity"))"
        )
        reread.resetAll()
        check(
            "appearance: reset returns 板块不透明度 to its shipped default",
            abs(reread.panelOpacity - GlassOpacityRuntime.panelDefaultValue) < 1e-6
                && abs(reread.glassOpacity - GlassOpacityRuntime.defaultValue) < 1e-6,
            "panel=\(reread.panelOpacity) glass=\(reread.glassOpacity)"
        )

        // The selected mock-up used to wear `Color.primary.opacity(0.55)` — a
        // hard 2 pt black frame in 浅色, which the owner rejected as "丑且不和谐"
        // on a Liquid Glass window. The replacement is a white keyline over a
        // soft halo (SelectionBorderStyle at thumbnail scale).
        let ringColor = NSColor(ThemeSelectionRing.color).usingColorSpace(.sRGB)
        let ringHalo = NSColor(ThemeSelectionRing.halo).usingColorSpace(.sRGB)
        check(
            "appearance: the selected mock-up wears a white ring, not a black frame",
            ThemeSelectionRing.width == 2
                && (ringColor?.redComponent ?? 0) > 0.95
                && (ringColor?.alphaComponent ?? 0) >= 0.9,
            "width=\(ThemeSelectionRing.width) "
                + "color=\(String(describing: ringColor))"
        )
        check(
            "appearance: the ring floats outside the tile over a blurred halo",
            ThemeSelectionRing.inset == -3
                && ThemeSelectionRing.cornerRadius == 11
                && ThemeSelectionRing.scale > 1
                && (ringHalo?.alphaComponent ?? 1) <= 0.32
                && ThemeSelectionRing.haloRadius <= 3,
            "inset=\(ThemeSelectionRing.inset) radius=\(ThemeSelectionRing.cornerRadius) "
                + "halo=\(String(describing: ringHalo)) blur=\(ThemeSelectionRing.haloRadius)"
        )
    }

    // MARK: - GlassSurface

    /// The reusable glass base: real `NSGlassEffectView` on macOS 26, the blur
    /// fallback below it, and an opaque card for 纯色 / offscreen renders.
    private static func runGlassSurfaceTests(into directory: URL) {
        let previousBackground = AppearanceRuntime.backgroundStyle
        let previousGlass = AppearanceRuntime.useGlass
        defer {
            AppearanceRuntime.backgroundStyle = previousBackground
            AppearanceRuntime.useGlass = previousGlass
        }
        AppearanceRuntime.useGlass = true
        AppearanceRuntime.backgroundStyle = .liquidGlass

        print("[glass] --- factory per background tier ---")
        let live = GlassSurfaceFactory.makeBackdrop(
            cornerRadius: 12,
            style: .regular,
            offscreen: false,
            backgroundStyle: .liquidGlass,
            glassAllowed: true
        )
        if #available(macOS 26.0, *) {
            // f00e22f's approved in-window recipe is a flat 20 % tint, not a
            // second NSGlassEffectView (the fog was measured and removed).
            check(
                "glass: in-window liquid glass is the flat tint container",
                live is NSView && !(live is NSGlassEffectView)
                    && !(live is NSVisualEffectView)
                    && abs((live.layer?.backgroundColor?.alpha ?? 0) - 0.20) < 0.001,
                "class=\(String(describing: type(of: live))) "
                    + "alpha=\(live.layer?.backgroundColor?.alpha ?? -1)"
            )

            // The in-window surfaces must be `.clear`, not `.regular`. On
            // macOS 27 a second `.regular` material stacked on the window's own
            // glass renders as an opaque-looking dark slab: measured over a
            // photo wallpaper the card was a flat 0.39 grey with no wallpaper
            // structure, which is exactly the "只有背景是液态玻璃" report.
            check(
                "glass: in-window surfaces default to the clear glass style",
                GlassSurface().style == .surface && GlassStyleKind.surface == .clear,
                "default=\(GlassSurface().style.rawValue) surface=\(GlassStyleKind.surface.rawValue)"
            )
            check(
                "glass: the clear surface style is the official .clear style",
                GlassStyleKind.surface.appKitStyle == .clear
                    && GlassStyleKind.regular.appKitStyle == .regular,
                "surface=\(String(describing: GlassStyleKind.surface.appKitStyle)) "
                    + "regular=\(String(describing: GlassStyleKind.regular.appKitStyle))"
            )
            let windowLayer = GlassBackdropView.makeBackdrop()
            let windowGlass = windowLayer as? NSGlassEffectView
            check(
                "glass: the window back layer keeps the .regular style",
                windowGlass?.style == .regular,
                "class=\(String(describing: type(of: windowLayer))) "
                    + "style=\(String(describing: windowGlass?.style))"
            )
        } else {
            check(
                "glass: below macOS 26 液态玻璃 falls back to NSVisualEffectView",
                live is NSVisualEffectView,
                "class=\(String(describing: type(of: live)))"
            )
        }

        let solid = GlassSurfaceFactory.makeBackdrop(
            cornerRadius: 12,
            style: .regular,
            offscreen: false,
            backgroundStyle: .solid,
            glassAllowed: true
        )
        check(
            "glass: 纯色 degrades every surface to an opaque card",
            solid is GlassCardBackdropView
                && (solid.layer?.backgroundColor?.alpha ?? 0) == 1,
            "class=\(String(describing: type(of: solid))) "
                + "alpha=\(solid.layer?.backgroundColor?.alpha ?? -1)"
        )
        let offscreen = GlassSurfaceFactory.makeBackdrop(
            cornerRadius: 12,
            style: .regular,
            offscreen: true,
            backgroundStyle: .liquidGlass,
            glassAllowed: true
        )
        check(
            "glass: offscreen rendering (no window) uses the opaque card",
            offscreen is GlassCardBackdropView
                && (offscreen.layer?.backgroundColor?.alpha ?? 0) == 1,
            "class=\(String(describing: type(of: offscreen))) "
                + "alpha=\(offscreen.layer?.backgroundColor?.alpha ?? -1)"
        )
        let translucent = GlassSurfaceFactory.makeBackdrop(
            cornerRadius: 12,
            style: .regular,
            offscreen: false,
            backgroundStyle: .translucent,
            glassAllowed: true
        )
        check(
            "glass: 半透明 wraps an NSVisualEffectView in the clipping container",
            translucent is NSView && containsVisualEffect(in: translucent),
            "class=\(String(describing: type(of: translucent))) "
                + "blur=\(containsVisualEffect(in: translucent))"
        )
        let legacy = GlassSurfaceFactory.makeBackdrop(
            cornerRadius: 12,
            style: .regular,
            offscreen: false,
            backgroundStyle: .liquidGlass,
            glassAllowed: false
        )
        // The approved in-window recipe is a flat tint, so 经典 (glassAllowed
        // = false) keeps that tint instead of swapping in a blur.
        check(
            "glass: 经典 / pre-26 keeps the flat in-window tint",
            legacy is NSView && !containsVisualEffect(in: legacy)
                && abs((legacy.layer?.backgroundColor?.alpha ?? 0) - 0.20) < 0.001,
            "class=\(String(describing: type(of: legacy))) "
                + "blur=\(containsVisualEffect(in: legacy)) "
                + "alpha=\(legacy.layer?.backgroundColor?.alpha ?? -1)"
        )

        print("[glass] --- offscreen hosting + PNG ---")
        let surface = NSHostingView(
            rootView: GlassSurface(cornerRadius: 12, style: .regular)
                .frame(width: 180, height: 90)
        )
        surface.frame = CGRect(x: 20, y: 20, width: 180, height: 90)
        surface.appearance = NSAppearance(named: .darkAqua)
        let canvas = TestCanvasView(frame: CGRect(x: 0, y: 0, width: 220, height: 130))
        canvas.addSubview(surface)
        surface.layoutSubtreeIfNeeded()
        surface.displayIfNeeded()

        let offscreenContainer = findSubview(GlassSurfaceContainer.self, in: surface)
        let offscreenBackdrop = offscreenContainer?.backdropViewForTesting
        check(
            "glass: a GlassSurface outside a window installs the opaque fallback",
            offscreenBackdrop is GlassCardBackdropView,
            "class=\(offscreenBackdrop.map { String(describing: type(of: $0)) } ?? "nil")"
        )
        if let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) {
            canvas.cacheDisplay(in: canvas.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                let url = directory.appendingPathComponent("glass-surface-offscreen.png")
                try? png.write(to: url)
                print("[glass] wrote \(url.path) (\(rep.pixelsWide)×\(rep.pixelsHigh) px)")
                let pixel = rep.colorAt(x: 60, y: 60)
                let brightness = pixel?.brightnessComponent ?? -1
                check(
                    "glass: the offscreen fallback renders visible pixels, not black",
                    png.count > 500 && brightness > 0.05,
                    "bytes=\(png.count) brightness=\(String(format: "%.2f", brightness))"
                )
            }
        }

        print("[glass] --- live window hosting ---")
        // Attaching the same view to a window flips the container from the
        // offscreen card to the real glass (or the blur on older systems).
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 220, height: 130),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = canvas
        canvas.layoutSubtreeIfNeeded()
        let liveContainer = findSubview(GlassSurfaceContainer.self, in: surface)
        let liveBackdrop = liveContainer?.backdropViewForTesting
        if #available(macOS 26.0, *) {
            check(
                "glass: attaching to a window swaps in the flat glass tint",
                liveBackdrop is NSView && !(liveBackdrop is NSGlassEffectView)
                    && !(liveBackdrop is GlassCardBackdropView),
                "class=\(liveBackdrop.map { String(describing: type(of: $0)) } ?? "nil")"
            )
        } else {
            check(
                "glass: attaching to a window on older systems swaps in NSVisualEffectView",
                liveBackdrop is NSVisualEffectView,
                "class=\(liveBackdrop.map { String(describing: type(of: $0)) } ?? "nil")"
            )
        }
        // Switching 外观 → 背景 while the window is open must replace the live
        // backdrop, not leave a stale glass view under an opaque window.
        AppearanceRuntime.backgroundStyle = .solid
        liveContainer?.configure(
            cornerRadius: 12,
            style: .regular,
            interactive: false,
            tint: nil
        )
        check(
            "glass: switching to 纯色 swaps the live glass for an opaque card",
            liveContainer?.backdropViewForTesting is GlassCardBackdropView,
            "class=\(liveContainer?.backdropViewForTesting.map { String(describing: type(of: $0)) } ?? "nil")"
        )
        AppearanceRuntime.backgroundStyle = .liquidGlass
        liveContainer?.configure(
            cornerRadius: 12,
            style: .regular,
            interactive: false,
            tint: nil
        )
        if #available(macOS 26.0, *) {
            check(
                "glass: switching back to 液态玻璃 restores the flat glass tint",
                liveContainer?.backdropViewForTesting is NSView
                    && !(liveContainer?.backdropViewForTesting is GlassCardBackdropView),
                "class=\(liveContainer?.backdropViewForTesting.map { String(describing: type(of: $0)) } ?? "nil")"
            )
        } else {
            check(
                "glass: switching back to 液态玻璃 restores the blur backdrop",
                liveContainer?.backdropViewForTesting is NSVisualEffectView
            )
        }
        window.orderOut(nil)
        window.close()

        print("[glass] --- neutral selection + formats ---")
        let light = SelectionStyle.resolvedFill(for: NSAppearance(named: .aqua)!)
        let dark = SelectionStyle.resolvedFill(for: NSAppearance(named: .darkAqua)!)
        check(
            "glass: the selected pill / chip alpha is < 1",
            light.alphaComponent > 0 && light.alphaComponent < 1
                && dark.alphaComponent > 0 && dark.alphaComponent < 1,
            "light=\(light.alphaComponent) dark=\(dark.alphaComponent)"
        )
        check(
            "glass: the selected pill / chip is neutral, not accent blue",
            isNeutral(light) && isNeutral(dark),
            "light=\(components(light)) dark=\(components(dark))"
        )
        check(
            "glass: the colour picker offers HEX / RGB / HSL",
            ColorPickFormat.allCases.map(\.rawValue) == ["hex", "rgb", "hsl"],
            "cases=\(ColorPickFormat.allCases.map(\.rawValue))"
        )
        check(
            "glass: HSL produces a hsl() clipboard string",
            PickedColor(red: 255, green: 128, blue: 0).string(for: .hsl)
                == "hsl(30, 100%, 50%)",
            "text=\(PickedColor(red: 255, green: 128, blue: 0).string(for: .hsl))"
        )
        check(
            "glass: Tab keeps the historical HEX ↔ RGB cycle",
            ColorPickFormat.hex.next == .rgb && ColorPickFormat.rgb.next == .hex
        )

        // Settings must feed the runtime, not just persist.
        let suiteName = "UnseenGlass-\(UUID().uuidString)"
        if let defaults = UserDefaults(suiteName: suiteName) {
            let settings = AppSettings(defaults: defaults)
            settings.backgroundStyle = "liquidGlass"
            check(
                "glass: 外观 → 背景 updates the glass runtime",
                AppearanceRuntime.backgroundStyle == .liquidGlass
            )
            settings.backgroundStyle = "solid"
            check(
                "glass: returning to 纯色 updates the glass runtime",
                AppearanceRuntime.backgroundStyle == .solid
            )
            settings.annotationFontSize = 33
            check(
                "glass: 标注 → 字号 updates the next-stroke default",
                AnnotationStyle.defaultStyle(for: .text).fontSize == 33
            )
            settings.annotationHiddenTools = [AnnotationTool.sticker.rawValue]
            check(
                "glass: 标注 → 工具显隐 filters the toolbar layout",
                !AnnotationToolbarLayout.visibleTools.contains(.sticker)
                    && AnnotationToolbarLayout.visibleTools.contains(.arrow),
                "tools=\(AnnotationToolbarLayout.visibleTools.map(\.rawValue))"
            )
            defaults.removePersistentDomain(forName: suiteName)
        } else {
            check("glass: create isolated defaults", false)
        }
        AnnotationDefaults.reset()
    }

    private static func findSubview<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = findSubview(type, in: subview) { return match }
        }
        return nil
    }

    private static func countSubviews<T: NSView>(of type: T.Type, in view: NSView) -> Int {
        var count = view is T ? 1 : 0
        for subview in view.subviews {
            count += countSubviews(of: type, in: subview)
        }
        return count
    }

    /// Every `T` in the hosting tree, in traversal order — used where the
    /// *state* of each control matters, not just how many there are.
    private static func subviews<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        var found: [T] = []
        if let match = view as? T { found.append(match) }
        for subview in view.subviews {
            found += subviews(of: type, in: subview)
        }
        return found
    }

    // MARK: - Q. Preset size

    private static func runPresetSizeTests() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let centered = PresetSelection.rect(
            for: CGSize(width: 600, height: 400),
            on: main
        )
        check(
            "preset: 600×400 is centred on the screen",
            centered == CGRect(x: 420, y: 250, width: 600, height: 400),
            "rect=\(format(centered))"
        )
        check("preset: centred rect stays inside the screen", main.contains(centered))

        let secondary = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let onSecondary = PresetSelection.rect(
            for: CGSize(width: 600, height: 400),
            on: secondary
        )
        check(
            "preset: centres inside a screen whose origin is not (0,0)",
            onSecondary == CGRect(x: 2100, y: 340, width: 600, height: 400),
            "rect=\(format(onSecondary))"
        )

        let oversized = PresetSelection.rect(
            for: CGSize(width: 2000, height: 1200),
            on: main
        )
        check(
            "preset: a preset larger than the display clamps to the screen",
            oversized == main,
            "rect=\(format(oversized))"
        )

        let tiny = PresetSelection.rect(for: CGSize(width: 10, height: 10), on: main)
        check(
            "preset: a tiny preset is raised to the 40 pt minimum",
            tiny == CGRect(x: 700, y: 430, width: 40, height: 40),
            "rect=\(format(tiny))"
        )

        let zero = PresetSelection.rect(for: CGSize(width: 0, height: 0), on: main)
        check(
            "preset: zero size becomes a valid 40×40 selection",
            zero.width == 40 && zero.height == 40 && main.contains(zero),
            "rect=\(format(zero))"
        )

        // The capture overlay accepts the preset as a normal prefill, still
        // clamped to the screen and with its toolbar visible for adjustment.
        let overlay = makeOverlay()
        overlay.applySelectionForTesting(centered)
        check(
            "preset: prefilled selection is usable by the overlay",
            overlay.selectionRectForTesting == centered
                && overlay.isToolbarVisibleForTesting,
            "selection=\(format(overlay.selectionRectForTesting))"
        )
        check(
            "preset: toolbar stays inside the 1440×900 canvas",
            inside(overlay.toolbarFrameForTesting, canvasSize),
            "toolbar=\(format(overlay.toolbarFrameForTesting))"
        )
    }

    // MARK: - R. Wiring for the four new entries

    // MARK: - V. 套壳 / 美化截图

    /// Fully deterministic: a known bitmap plus known parameters produce a
    /// fixed output size and known pixels. Nothing here touches the screen,
    /// the pasteboard or a file panel.
    private static func runBeautifyTests(into directory: URL) {
        guard let source = makeBeautifySourceImage(width: 600, height: 400),
              let sourceCentre = pixel(source, x: 300, y: 200) else {
            check("beautify: source bitmap can be built", false)
            return
        }

        let orange = NSColor(srgbRed: 1, green: 180.0 / 255.0, blue: 40.0 / 255.0, alpha: 1)
        let orangeRGB = (r: 255, g: 180, b: 40)
        let options = BeautifyOptions(
            padding: 48,
            cornerRadius: 16,
            shadowRadius: 24,
            background: .solid(orange),
            shadowOpacity: 0.28
        )

        let defaults = BeautifyOptions()
        check(
            "beautify: defaults are padding 48 / radius 16 / shadow 24 / opacity 0.28",
            defaults.padding == 48 && defaults.cornerRadius == 16
                && defaults.shadowRadius == 24 && defaults.shadowOpacity == 0.28,
            "padding=\(defaults.padding) radius=\(defaults.cornerRadius) "
                + "shadow=\(defaults.shadowRadius) opacity=\(defaults.shadowOpacity)"
        )

        let size = BeautifyRenderer.outputSize(for: source, options: options)
        let rendered = BeautifyRenderer.render(source, options: options)
        check(
            "beautify: 600×400 + padding 48 → 696×496",
            size == CGSize(width: 696, height: 496)
                && rendered.width == 696 && rendered.height == 496,
            "size=\(Int(size.width))×\(Int(size.height)) "
                + "image=\(rendered.width)×\(rendered.height)"
        )

        // The preview window must construct and compose at the same size
        // without being ordered on screen (catches AppKit wiring mistakes).
        let preview = BeautifyWindowController(
            shot: CapturedScreenshot(image: source, scale: 1)
        )
        let previewImage = preview.composedImage()
        check(
            "beautify: preview window builds and composes 696×496",
            previewImage?.width == 696 && previewImage?.height == 496
        )
        let savedURL = directory.appendingPathComponent("beautify-window-save.png")
        do {
            _ = try preview.save(to: savedURL)
            let dimensions = sipsDimensions(savedURL)
            check(
                "beautify: preview window's save writes a 696×496 PNG",
                dimensions.width == 696 && dimensions.height == 496,
                "dimensions=\(dimensions.width ?? -1)×\(dimensions.height ?? -1) "
                    + "sips=\(dimensions.output.prefix(80))"
            )
        } catch {
            check(
                "beautify: preview window's save writes a 696×496 PNG",
                false,
                error.localizedDescription
            )
        }
        preview.close()

        // 1. The four *outer* corners are background, and so are the four
        //    corners of the screenshot itself (the rounded clip).
        let outerCorners = [
            (x: 0, y: 0), (x: 695, y: 0), (x: 0, y: 495), (x: 695, y: 495)
        ]
        let outerOK = outerCorners.allSatisfy { point in
            guard let value = pixel(rendered, x: point.x, y: point.y) else { return false }
            return matches(value, orangeRGB, tolerance: 2) && value.a == 255
        }
        check("beautify: outer four corners are the background colour", outerOK)

        let innerCorners = [
            (x: 49, y: 49), (x: 646, y: 49), (x: 49, y: 446), (x: 646, y: 446)
        ]
        // With the shadow on, these pixels sit in the shadow just outside the
        // rounded clip: they must read as darkened background, not as source
        // pixels. That is exactly what a rounded corner looks like.
        let roundedCornerOK = innerCorners.allSatisfy { point in
            guard let value = pixel(rendered, x: point.x, y: point.y) else { return false }
            let toBackground = colourDistance(value, orangeRGB)
            let toSource = colourDistance(value, (51, 102, 204))
            return toBackground < 160 && toBackground < toSource
        }
        check(
            "beautify: screenshot corners are clipped to the background (radius 16)",
            roundedCornerOK
        )

        // Shadow off → the same pixels are *exactly* the background, proving
        // the clip and not merely a dark shadow.
        let flatOptions = BeautifyOptions(
            padding: 48,
            cornerRadius: 16,
            shadowRadius: 24,
            background: .solid(orange),
            shadowOpacity: 0
        )
        let flat = BeautifyRenderer.render(source, options: flatOptions)
        let flatCornersOK = innerCorners.allSatisfy { point in
            guard let value = pixel(flat, x: point.x, y: point.y) else { return false }
            return matches(value, orangeRGB, tolerance: 2)
        }
        check(
            "beautify: with the shadow off, rounded corners are exactly background",
            flatCornersOK
        )

        // 2. The centre still has exactly the source colour.
        if let centre = pixel(rendered, x: 348, y: 248) {
            check(
                "beautify: centre pixel keeps the source colour",
                matches(centre, (sourceCentre.r, sourceCentre.g, sourceCentre.b), tolerance: 1)
                    && centre.a == 255,
                "actual=\(centre) source=\(sourceCentre)"
            )
        } else {
            check("beautify: centre pixel keeps the source colour", false, "unreadable")
        }

        // 3. Anywhere in the padding is plain background.
        let paddingPoints = [
            (x: 4, y: 248), (x: 691, y: 248), (x: 348, y: 4), (x: 348, y: 491)
        ]
        let paddingOK = paddingPoints.allSatisfy { point in
            guard let value = pixel(rendered, x: point.x, y: point.y) else { return false }
            return matches(value, orangeRGB, tolerance: 2)
        }
        check("beautify: padding area is the background colour", paddingOK)

        // 4. A grid of source pixels survives at the offset position.
        var preserved = true
        for point in [(x: 10, y: 10), (x: 200, y: 100), (x: 450, y: 320), (x: 580, y: 390)] {
            guard let expected = pixel(source, x: point.x, y: point.y),
                  let actual = pixel(rendered, x: point.x + 48, y: point.y + 48),
                  matches(actual, (expected.r, expected.g, expected.b), tolerance: 1) else {
                preserved = false
                break
            }
        }
        check("beautify: source pixels are placed at padding offset", preserved)

        // 5. The shadow is actually painted: just outside the screenshot edge
        //    is darker than the far padding.
        if let nearEdge = pixel(rendered, x: 44, y: 248),
           let farPadding = pixel(rendered, x: 4, y: 248) {
            let near = nearEdge.r + nearEdge.g + nearEdge.b
            let far = farPadding.r + farPadding.g + farPadding.b
            check(
                "beautify: drop shadow darkens the padding next to the screenshot",
                near < far - 9,
                "near=\(near) far=\(far)"
            )
        } else {
            check("beautify: drop shadow darkens the padding next to the screenshot", false)
        }

        // 6. Gradient: the visual top-left and bottom-right differ.
        let gradientOptions = BeautifyOptions(
            padding: 48,
            cornerRadius: 16,
            shadowRadius: 24,
            background: .gradient(
                NSColor(srgbRed: 1, green: 0.35, blue: 0.35, alpha: 1),
                NSColor(srgbRed: 0.15, green: 0.25, blue: 0.95, alpha: 1)
            ),
            shadowOpacity: 0.28
        )
        let gradient = BeautifyRenderer.render(source, options: gradientOptions)
        if let topLeft = pixel(gradient, x: 2, y: 2),
           let bottomRight = pixel(gradient, x: 693, y: 493) {
            let distance = abs(topLeft.r - bottomRight.r)
                + abs(topLeft.g - bottomRight.g)
                + abs(topLeft.b - bottomRight.b)
            check(
                "beautify: gradient background differs top-left → bottom-right",
                distance > 60 && topLeft.a == 255 && bottomRight.a == 255,
                "distance=\(distance) topLeft=\(topLeft) bottomRight=\(bottomRight)"
            )
            check(
                "beautify: gradient keeps the 696×496 size",
                gradient.width == 696 && gradient.height == 496
            )
        } else {
            check("beautify: gradient background differs top-left → bottom-right", false)
        }

        // 7. Transparent background: alpha 0 outside the rounded rect.
        let transparentOptions = BeautifyOptions(
            padding: 48,
            cornerRadius: 16,
            shadowRadius: 24,
            background: .transparent,
            shadowOpacity: 0.28
        )
        let transparent = BeautifyRenderer.render(source, options: transparentOptions)
        let alphaOuterCorners = [
            (x: 0, y: 0), (x: 695, y: 0), (x: 0, y: 495), (x: 695, y: 495)
        ]
        let transparentOK = alphaOuterCorners.allSatisfy { point in
            pixel(transparent, x: point.x, y: point.y)?.a == 0
        }
        // A shadow is still painted in transparent mode, so the corner sample
        // is intentionally checked on a shadow-free render.
        let transparentFlatOptions = BeautifyOptions(
            padding: 48,
            cornerRadius: 16,
            shadowRadius: 24,
            background: .transparent,
            shadowOpacity: 0
        )
        let transparentFlat = BeautifyRenderer.render(source, options: transparentFlatOptions)
        let transparentCornerAlpha = pixel(transparentFlat, x: 49, y: 49)?.a
        check(
            "beautify: transparent background has alpha 0 outside the clip",
            transparentOK && transparentCornerAlpha == 0,
            "outerOK=\(transparentOK) clippedCornerAlpha=\(transparentCornerAlpha ?? -1)"
        )
        if let centre = pixel(transparent, x: 348, y: 248) {
            check(
                "beautify: transparent output still contains the screenshot",
                centre.a == 255
                    && matches(centre, (sourceCentre.r, sourceCentre.g, sourceCentre.b), tolerance: 1)
            )
        } else {
            check("beautify: transparent output still contains the screenshot", false)
        }

        // 8. Rendering is deterministic.
        let again = BeautifyRenderer.render(source, options: options)
        if let first = pixelBuffer(rendered), let second = pixelBuffer(again) {
            check(
                "beautify: two identical renders produce identical pixels",
                first.bytes == second.bytes
            )
        } else {
            check("beautify: two identical renders produce identical pixels", false)
        }

        // 9. Point-space values scale to Retina pixels.
        let scaled = options.scaled(by: 2)
        check(
            "beautify: scaling by 2 doubles padding / radius / shadow",
            scaled.padding == 96 && scaled.cornerRadius == 32 && scaled.shadowRadius == 48,
            "padding=\(scaled.padding) radius=\(scaled.cornerRadius) shadow=\(scaled.shadowRadius)"
        )
        check(
            "beautify: a 2× capture keeps the visual layout",
            BeautifyRenderer.outputSize(for: source, options: scaled)
                == CGSize(width: 792, height: 592)
        )

        // 10. Leave inspectable PNGs next to the other verification images.
        let artefacts: [(String, CGImage)] = [
            ("beautify-solid", rendered),
            ("beautify-gradient", gradient),
            ("beautify-transparent", transparent)
        ]
        for (name, image) in artefacts {
            guard let data = NSBitmapImageRep(cgImage: image)
                .representation(using: .png, properties: [:]) else { continue }
            try? data.write(to: directory.appendingPathComponent("\(name).png"))
            copyToVerification(data, named: "\(name).png")
        }
        check(
            "beautify: three inspection PNGs were written",
            artefacts.allSatisfy {
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent("\($0.0).png").path
                )
            }
        )
    }

    // MARK: - W. 摄像头画中画

    // MARK: - V2. 截图圆角 / 截图阴影（只作用于导出图）

    /// iShot's `needFilletOfnotSingleWindow` / `needShadowOfnotSingleWindow`
    /// pair. Deterministic on purpose: a known bitmap plus known parameters must
    /// produce an exact output size and known pixels, and an untouched install
    /// must keep the pre-existing (undecorated) output.
    private static func runExportDecorationTests(into directory: URL) {
        guard let source = makeBeautifySourceImage(width: 600, height: 400),
              let sourceCentre = pixel(source, x: 300, y: 200) else {
            check("export: source bitmap can be built", false)
            return
        }

        // 1. Settings → decoration, and the "off by default" guarantee.
        let suite = "unseen.selftest.export.\(UUID().uuidString)"
        let scratch = UserDefaults(suiteName: suite)!
        scratch.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: scratch)
        defer { scratch.removePersistentDomain(forName: suite) }

        check(
            "export: both 圆角 / 阴影 toggles default off",
            !settings.captureCornerRadiusEnabled && !settings.captureShadowEnabled
                && settings.screenshotDecoration == ScreenshotDecoration.none,
            "decoration=\(settings.screenshotDecoration)"
        )
        settings.captureCornerRadiusEnabled = true
        settings.captureShadowEnabled = true
        check(
            "export: toggles map to the stored radius / shadow size",
            settings.screenshotDecoration
                == ScreenshotDecoration(
                    cornerRadius: CGFloat(AppSettings.defaultExportCornerRadius),
                    shadowSize: CGFloat(AppSettings.defaultExportShadowSize)
                ),
            "decoration=\(settings.screenshotDecoration)"
        )
        settings.captureCornerRadius = 999
        check(
            "export: an out-of-range radius is clamped for the renderer",
            settings.exportCornerRadius == AppSettings.maxExportCornerRadius
                && settings.captureCornerRadius == 999,
            "stored=\(settings.captureCornerRadius) used=\(settings.exportCornerRadius)"
        )

        // 2. Nothing enabled → the very same image object comes back.
        let passthrough = ScreenshotDecorator.render(source, scale: 2, decoration: .none)
        check(
            "export: decoration off returns the original pixels",
            passthrough === source, "same=\(passthrough === source)"
        )

        // 3. Fillet alone: size unchanged, the corner becomes transparent.
        let fillet = ScreenshotDecoration(cornerRadius: 16, shadowSize: 0)
        let filletImage = ScreenshotDecorator.render(source, scale: 2, decoration: fillet)
        let filletCorner = pixel(filletImage, x: 1, y: 1)
        let filletCentre = pixel(filletImage, x: 300, y: 200)
        check(
            "export: a fillet never changes the canvas size",
            filletImage.width == 600 && filletImage.height == 400,
            "size=\(filletImage.width)×\(filletImage.height)"
        )
        check(
            "export: the fillet rounds the corner away (alpha 0)",
            filletCorner?.a == 0, "corner=\(filletCorner.map { "\($0)" } ?? "nil")"
        )
        check(
            "export: the fillet leaves the centre pixel untouched",
            filletCentre?.r == sourceCentre.r && filletCentre?.g == sourceCentre.g
                && filletCentre?.b == sourceCentre.b,
            "centre=\(filletCentre.map { "\($0)" } ?? "nil")"
        )

        // 4. Shadow alone: iShot's padding (size × scale) on every side.
        let shadow = ScreenshotDecoration(cornerRadius: 0, shadowSize: 12)
        let pad = ScreenshotDecorator.padding(for: shadow, scale: 2)
        let shadowImage = ScreenshotDecorator.render(source, scale: 2, decoration: shadow)
        check(
            "export: iShot's shadow constants (blur = size × 1.1, 30 % black)",
            ScreenshotDecorator.shadowBlurFactor == 1.1
                && ScreenshotDecorator.shadowOpacity == 0.30,
            "blur=\(ScreenshotDecorator.shadowBlurFactor) "
                + "opacity=\(ScreenshotDecorator.shadowOpacity)"
        )
        check(
            "export: shadow 12 pt at 2× pads by 24 px per side → 648×448",
            pad == 24 && shadowImage.width == 648 && shadowImage.height == 448,
            "pad=\(pad) size=\(shadowImage.width)×\(shadowImage.height)"
        )
        let shadowCentre = pixel(shadowImage, x: Int(pad) + 300, y: Int(pad) + 200)
        check(
            "export: the shadow keeps the screenshot itself at the centre",
            shadowCentre?.r == sourceCentre.r && shadowCentre?.g == sourceCentre.g
                && shadowCentre?.b == sourceCentre.b,
            "centre=\(shadowCentre.map { "\($0)" } ?? "nil")"
        )
        let shadowEdge = pixel(shadowImage, x: 2, y: 224)
        check(
            "export: outside the image is soft shadow, not opaque black",
            (shadowEdge?.a ?? 0) > 0 && (shadowEdge?.a ?? 0) < 255,
            "edge=\(shadowEdge.map { "\($0)" } ?? "nil")"
        )

        // 5. Both: the shadow wraps a rounded rectangle inside the padding.
        let both = ScreenshotDecoration(cornerRadius: 16, shadowSize: 12)
        let bothImage = ScreenshotDecorator.render(source, scale: 2, decoration: both)
        let bothCentre = pixel(bothImage, x: Int(pad) + 300, y: Int(pad) + 200)
        check(
            "export: fillet + shadow keeps 648×448 and the centre",
            bothImage.width == 648 && bothImage.height == 448
                && bothCentre?.r == sourceCentre.r,
            "size=\(bothImage.width)×\(bothImage.height) "
                + "centre=\(bothCentre.map { "\($0)" } ?? "nil")"
        )

        // 6. JPEG has no alpha: the export fills the padding with paper instead
        //    of letting the encoder composite the corners onto black.
        let paper = ScreenshotDecorator.render(
            source,
            scale: 1,
            decoration: ScreenshotDecoration(cornerRadius: 16, shadowSize: 0),
            background: .white
        )
        let paperCorner = pixel(paper, x: 1, y: 1)
        check(
            "export: an opaque background fills the rounded corner white",
            paperCorner?.r == 255 && paperCorner?.g == 255 && paperCorner?.b == 255
                && paperCorner?.a == 255,
            "corner=\(paperCorner.map { "\($0)" } ?? "nil")"
        )

        // 7. Sample artifact for the report.
        if let png = NSBitmapImageRep(cgImage: bothImage).representation(
            using: .png,
            properties: [:]
        ) {
            let url = directory.appendingPathComponent("export-decoration.png")
            try? png.write(to: url)
            print("[export] wrote \(url.path) (\(bothImage.width)×\(bothImage.height) px)")
            copyToVerification(png, named: "export-decoration-sample.png")
        }
        _ = directory
    }

    private static func runCameraOverlayTests() {
        let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let medium = CameraSize.medium.size
        let small = CameraSize.small.size
        let large = CameraSize.large.size
        check(
            "camera: size tiers are 160×120 / 240×180 / 320×240",
            small == CGSize(width: 160, height: 120)
                && medium == CGSize(width: 240, height: 180)
                && large == CGSize(width: 320, height: 240),
            "small=\(small) medium=\(medium) large=\(large)"
        )

        let topLeft = CameraPlacement.frame(size: medium, screenFrame: screen, position: .topLeft)
        let topRight = CameraPlacement.frame(size: medium, screenFrame: screen, position: .topRight)
        let bottomLeft = CameraPlacement.frame(size: medium, screenFrame: screen, position: .bottomLeft)
        let bottomRight = CameraPlacement.frame(size: medium, screenFrame: screen, position: .bottomRight)
        check(
            "camera: four corners land at the expected frames",
            sameRect(topLeft, CGRect(x: 24, y: 696, width: 240, height: 180))
                && sameRect(topRight, CGRect(x: 1_176, y: 696, width: 240, height: 180))
                && sameRect(bottomLeft, CGRect(x: 24, y: 24, width: 240, height: 180))
                && sameRect(bottomRight, CGRect(x: 1_176, y: 24, width: 240, height: 180)),
            "tl=\(topLeft) tr=\(topRight) bl=\(bottomLeft) br=\(bottomRight)"
        )

        let tinyScreen = CGRect(x: 0, y: 0, width: 200, height: 150)
        let clamped = CameraPlacement.frame(size: large, screenFrame: tinyScreen, position: .bottomRight)
        check(
            "camera: a panel larger than the screen is clamped inside it",
            sameRect(clamped, tinyScreen),
            "frame=\(clamped) screen=\(tinyScreen)"
        )

        let offsetScreen = CGRect(x: 100, y: 50, width: 400, height: 300)
        let offsetTopRight = CameraPlacement.frame(
            size: large,
            screenFrame: offsetScreen,
            position: .topRight
        )
        check(
            "camera: placement keeps a screen with a non-zero origin inside bounds",
            offsetTopRight.minX >= offsetScreen.minX
                && offsetTopRight.minY >= offsetScreen.minY
                && offsetTopRight.maxX <= offsetScreen.maxX
                && offsetTopRight.maxY <= offsetScreen.maxY,
            "frame=\(offsetTopRight) screen=\(offsetScreen)"
        )
        let offsetBottomRight = CameraPlacement.frame(
            size: large,
            screenFrame: offsetScreen,
            position: .bottomRight
        )
        check(
            "camera: corner arithmetic uses the screen origin, not the world origin",
            sameRect(offsetBottomRight, CGRect(x: 156, y: 74, width: 320, height: 240)),
            "frame=\(offsetBottomRight)"
        )

        // No permission: refuse, do not crash, do not prompt repeatedly. The
        // override means the test never touches the real TCC prompt.
        let denied = CameraOverlayController(permissionOverride: .denied)
        let deniedStart = denied.start(
            position: .bottomRight,
            size: .medium,
            screenFrame: screen
        )
        check(
            "camera: denied permission refuses to start a session",
            deniedStart == false
                && denied.isActive == false
                && denied.session == nil
                && denied.isSessionRunning == false
                && denied.panel == nil
        )
        check(
            "camera: denied permission is queryable with a reason",
            denied.permission == .denied
                && (denied.lastFailureReason?.isEmpty == false),
            "permission=\(denied.permission.rawValue) reason=\(denied.lastFailureReason ?? "nil")"
        )
        denied.start(position: .topLeft, size: .small, screenFrame: screen)
        denied.stop()
        denied.stop()
        check(
            "camera: repeated start / stop without permission is safe",
            denied.isActive == false && denied.panel == nil && denied.session == nil
        )

        let undetermined = CameraOverlayController(
            permissionOverride: .notDetermined,
            allowsPermissionRequest: false
        )
        let undeterminedStart = undetermined.start(
            position: .bottomRight,
            size: .medium,
            screenFrame: screen
        )
        check(
            "camera: not-determined refuses without prompting in the test",
            undeterminedStart == false
                && undetermined.didRequestPermission == false
                && undetermined.session == nil
        )

        let restricted = CameraOverlayController(permissionOverride: .restricted)
        check(
            "camera: restricted permission also degrades",
            restricted.start(position: .bottomRight, size: .medium, screenFrame: screen) == false
                && restricted.lastFailureReason != nil
        )

        // Window exclusion: build the production panel (no session needed) and
        // assert both registries, then clean up.
        let camera = CameraOverlayController(permissionOverride: .denied)
        let frame = camera.presentPanelForTesting(
            screenFrame: screen,
            position: .bottomRight,
            size: .medium
        )
        let windowNumber = camera.panel?.windowNumber ?? 0
        check(
            "camera: the floating panel uses the requested corner and .floating level",
            sameRect(frame, CGRect(x: 1_176, y: 24, width: 240, height: 180))
                && camera.panel?.level == .floating
                && camera.panel?.styleMask.contains(.nonactivatingPanel) == true,
            "frame=\(frame) level=\(camera.panel?.level.rawValue ?? -1) number=\(windowNumber)"
        )
        check(
            "camera: the camera window is in ScreenCapture's exclusion set",
            windowNumber > 0
                && ScreenCapture.excludedWindowNumbers.contains(CGWindowID(windowNumber)),
            "windowNumber=\(windowNumber) excluded=\(ScreenCapture.excludedWindowNumbers)"
        )
        check(
            "camera: the camera window stays in the recording keep-set",
            windowNumber > 0
                && CameraOverlayRegistry.activeWindowNumbers.contains(CGWindowID(windowNumber))
        )
        let previousPosition = CameraOverlayRegistry.activeWindowNumbers
        camera.updatePlacement(position: .topLeft, size: .small, screenFrame: screen)
        check(
            "camera: updatePlacement moves the existing panel without restarting",
            sameRect(camera.frame, CGRect(x: 24, y: 756, width: 160, height: 120)),
            "frame=\(camera.frame)"
        )
        camera.stop()
        check(
            "camera: stopping removes the window from both registries",
            !ScreenCapture.excludedWindowNumbers.contains(CGWindowID(windowNumber))
                && !CameraOverlayRegistry.activeWindowNumbers.contains(CGWindowID(windowNumber))
                && camera.panel == nil,
            "excluded=\(ScreenCapture.excludedWindowNumbers) "
                + "keep=\(CameraOverlayRegistry.activeWindowNumbers) "
                + "previous=\(previousPosition)"
        )
    }

    /// 设置 → 截图 → 框选行为 → 显示十字线.
    ///
    /// `CaptureCoordinator` threads `settings.showCrosshair` into
    /// `CaptureOverlayController` → `CaptureOverlayView`; this drives the view
    /// directly so the drawing decision is observable without a window server.
    /// Turning it off hides only the drawn lines: the cursor rects stay
    /// `.crosshair`, so the pointer itself is never hidden. The armed window
    /// state hides the crosshair independently of this preference (covered by
    /// the window-pick tests).
    private static func runCrosshairVisibilityTests() {
        print("[crosshair] --- 显示十字线 ---")
        let points = [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 250)]

        let off = CaptureOverlayView(
            frame: CGRect(origin: .zero, size: canvasSize),
            mode: .region,
            prefilledSelection: nil,
            showCrosshair: false,
            rendersOffscreen: true
        )
        check(
            "crosshair: the setting off draws no crosshair",
            !off.isCrosshairVisibleForTesting
        )
        stroke(off, points: points)
        check(
            "crosshair: it stays off through a real drag",
            !off.isCrosshairVisibleForTesting
        )

        let on = CaptureOverlayView(
            frame: CGRect(origin: .zero, size: canvasSize),
            mode: .region,
            prefilledSelection: nil,
            showCrosshair: true,
            rendersOffscreen: true
        )
        check(
            "crosshair: the setting on draws it",
            on.isCrosshairVisibleForTesting
        )
        stroke(on, points: points)
        check(
            "crosshair: it stays on through a real drag",
            on.isCrosshairVisibleForTesting
        )
    }

    private static func runFeatureWiringTests(into directory: URL) {
        let suiteName = "UnseenOverlayTest-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            check("wiring: create isolated defaults", false)
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)

        // The shipped preferences are the owner's exported plist. Dump what a
        // virgin preference domain actually resolves — registration defaults
        // included, nothing persisted — so the file can be diffed key by key
        // against `~/Downloads/Unseen-Preferences.plist`.
        // `exportPreferences()` uses `object(forKey:)`, which consults the
        // registration domain, so this really is the effective default.
        let effectiveDefaults = settings.exportPreferences()
        if let data = try? PropertyListSerialization.data(
            fromPropertyList: effectiveDefaults,
            format: .xml,
            options: 0
        ) {
            let url = directory.appendingPathComponent("effective-defaults.plist")
            try? data.write(to: url)
            print("[wiring] wrote \(url.path) (\(effectiveDefaults.count) keys)")
        }
        check(
            "wiring: the effective defaults cover every persisted key",
            AppSettings.exportedKeys.isSubset(of: Set(effectiveDefaults.keys)),
            "effective=\(effectiveDefaults.count) exported=\(AppSettings.exportedKeys.count)"
        )
        // `register(defaults:)` writes to the registration domain only. Reading
        // a virgin `AppSettings` must not leave a single value in the persistent
        // domain — that is what keeps "defaults" from looking like a user edit,
        // and what lets the defaults move again in a later build.
        let persistent = defaults.persistentDomain(forName: suiteName) ?? [:]
        check(
            "wiring: registration defaults never enter the persistent domain",
            persistent.isEmpty,
            "persistent=\(persistent.keys.sorted())"
        )
        check(
            "wiring: the owner's preference file has no status-menu renames baked in",
            settings.menuBarCustomTitles.isEmpty
                && settings.menuBarTitle(for: .ocr) == MenuBarEntry.ocr.title
                && settings.menuBarTitle(for: .openClipboard) == MenuBarEntry.openClipboard.title,
            "custom=\(settings.menuBarCustomTitles)"
        )
        check(
            "wiring: the ignored-app list ships empty while password managers stay excluded",
            settings.ignoredBundleIDs.isEmpty
                && settings.effectiveIgnores.isSuperset(of: AppSettings.knownPasswordManagers),
            "ignored=\(settings.ignoredBundleIDs.sorted()) "
                + "effective=\(settings.effectiveIgnores.count)"
        )
        check(
            "wiring: the export / glass / annotation defaults match the preference file",
            settings.exportCornerRadius == 12
                && settings.exportShadowSize == 12
                && settings.glassOpacity == GlassOpacityRuntime.defaultValue
                && settings.panelOpacity == GlassOpacityRuntime.panelDefaultValue
                && settings.annotationFontSize == 20
                && settings.annotationLineWidth == 0
                && settings.annotationColorHex.isEmpty
                && settings.scrollCaptureInterval == 0.35,
            "corner=\(settings.exportCornerRadius) shadow=\(settings.exportShadowSize) "
                + "glass=\(settings.glassOpacity) panel=\(settings.panelOpacity) "
                + "font=\(settings.annotationFontSize) "
                + "line=\(settings.annotationLineWidth) interval=\(settings.scrollCaptureInterval)"
        )

        check(
            "wiring: delay default is 3 seconds",
            settings.timeOfDelayScreenshots == 3,
            "value=\(settings.timeOfDelayScreenshots)"
        )
        check(
            "wiring: preset default is 600 × 400",
            settings.presetCaptureWidth == 600 && settings.presetCaptureHeight == 400,
            "value=\(settings.presetCaptureWidth)×\(settings.presetCaptureHeight)"
        )
        check(
            "wiring: scroll hotkey ships bound (⌥Z) with the switch on",
            settings.scrollHotKeyEnabled
                && settings.scrollHotKeyConfiguration == .scroll
                && settings.scrollHotKeyConfiguration.isBound,
            "display=\(settings.scrollHotKeyConfiguration.displayString) "
                + "bound=\(settings.scrollHotKeyConfiguration.isBound)"
        )
        check(
            "wiring: scroll hotkey action id is 5",
            HotKeyAction.scroll.rawValue == 5,
            "id=\(HotKeyAction.scroll.rawValue)"
        )
        let exported = AppSettings.exportedKeys
        check(
            "wiring: new preferences are included in backup/restore",
            exported.isSuperset(of: [
                AppSettings.Key.scrollHotKeyEnabled,
                AppSettings.Key.scrollHotKeyKeyCode,
                AppSettings.Key.scrollHotKeyModifiers,
                AppSettings.Key.timeOfDelayScreenshots,
                AppSettings.Key.presetCaptureWidth,
                AppSettings.Key.presetCaptureHeight
            ])
        )
        check(
            "wiring: scroll sampling outruns a fast flick (0.1 s)",
            ScrollCaptureController.defaultInterval == 0.1,
            "interval=\(ScrollCaptureController.defaultInterval)"
        )

        check(
            "wiring: record hotkey ships bound (⌥X) with the switch on",
            settings.recordHotKeyEnabled
                && settings.recordHotKeyConfiguration == .record
                && settings.recordHotKeyConfiguration.isBound,
            "display=\(settings.recordHotKeyConfiguration.displayString) "
                + "bound=\(settings.recordHotKeyConfiguration.isBound)"
        )
        check(
            "wiring: colour picker hotkey ships unbound with the switch on",
            settings.colorPickerHotKeyEnabled
                && settings.colorPickerHotKeyConfiguration == .unbound
                && !settings.colorPickerHotKeyConfiguration.isBound,
            "display=\(settings.colorPickerHotKeyConfiguration.displayString) "
                + "bound=\(settings.colorPickerHotKeyConfiguration.isBound)"
        )
        check(
            "wiring: record / colour hotkey action ids are 6 / 7",
            HotKeyAction.record.rawValue == 6 && HotKeyAction.colorPicker.rawValue == 7,
            "record=\(HotKeyAction.record.rawValue) picker=\(HotKeyAction.colorPicker.rawValue)"
        )
        check(
            "wiring: beautify hotkey ships unbound with the switch on",
            settings.beautifyHotKeyEnabled
                && settings.beautifyHotKeyConfiguration == .unbound
                && !settings.beautifyHotKeyConfiguration.isBound,
            "config=\(settings.beautifyHotKeyConfiguration) "
                + "bound=\(settings.beautifyHotKeyConfiguration.isBound)"
        )
        check(
            "wiring: beautify hotkey action id is 8",
            HotKeyAction.beautify.rawValue == 8,
            "id=\(HotKeyAction.beautify.rawValue)"
        )
        check(
            "wiring: camera defaults off / bottom-right / medium",
            !settings.cameraOverlayEnabled
                && settings.cameraOverlayPosition == "bottomRight"
                && settings.cameraOverlayPositionValue == .bottomRight
                && settings.cameraOverlaySize == "medium"
                && settings.cameraOverlaySizeValue == .medium
                && settings.cameraOverlaySizeValue.size == CGSize(width: 240, height: 180),
            "enabled=\(settings.cameraOverlayEnabled) position=\(settings.cameraOverlayPosition) "
                + "size=\(settings.cameraOverlaySize)"
        )
        check(
            "wiring: recording defaults are MP4 / 30 fps / 12 Mbps / no mic",
            settings.recordingFormat == "mp4"
                && settings.recordingFrameRate == 30
                && settings.recordingBitrate == 12_000_000
                && !settings.recordingMicrophone
                && settings.recordingConfiguration.format == .mp4
                && settings.recordingConfiguration.effectiveFrameRate == 30,
            "format=\(settings.recordingFormat) fps=\(settings.recordingFrameRate) "
                + "bitrate=\(settings.recordingBitrate) mic=\(settings.recordingMicrophone)"
        )
        check(
            "wiring: colour picker copies HEX by default",
            settings.colorPickerFormat == "hex" && settings.colorPickFormat == .hex
        )
        check(
            "wiring: key display defaults off / bottom centre / 2 s",
            !settings.keyDisplayEnabled
                && settings.keyDisplayPosition == "bottomCenter"
                && settings.keyDisplayPositionValue == .bottomCenter
                && settings.keyDisplayDuration == 2,
            "position=\(settings.keyDisplayPosition) duration=\(settings.keyDisplayDuration)"
        )
        check(
            "wiring: recording / picker / key display preferences are in backup/restore",
            exported.isSuperset(of: [
                AppSettings.Key.recordHotKeyEnabled,
                AppSettings.Key.recordHotKeyKeyCode,
                AppSettings.Key.recordHotKeyModifiers,
                AppSettings.Key.colorPickerHotKeyEnabled,
                AppSettings.Key.colorPickerHotKeyKeyCode,
                AppSettings.Key.colorPickerHotKeyModifiers,
                AppSettings.Key.recordingFormat,
                AppSettings.Key.recordingFrameRate,
                AppSettings.Key.recordingBitrate,
                AppSettings.Key.recordingMicrophone,
                AppSettings.Key.colorPickerFormat,
                AppSettings.Key.keyDisplayEnabled,
                AppSettings.Key.keyDisplayPosition,
                AppSettings.Key.keyDisplayDuration,
                AppSettings.Key.beautifyHotKeyEnabled,
                AppSettings.Key.beautifyHotKeyKeyCode,
                AppSettings.Key.beautifyHotKeyModifiers,
                AppSettings.Key.cameraOverlayEnabled,
                AppSettings.Key.cameraOverlayPosition,
                AppSettings.Key.cameraOverlaySize
            ])
        )

        // Round-trip one edited value through UserDefaults.
        settings.timeOfDelayScreenshots = 5
        check(
            "wiring: delay choice persists to UserDefaults",
            defaults.integer(forKey: AppSettings.Key.timeOfDelayScreenshots) == 5
        )
        settings.presetCaptureWidth = 0
        settings.presetCaptureHeight = 20_000
        check(
            "wiring: preset size helper clamps edited values",
            settings.presetCaptureSize.width == PresetSelection.minimumSide
                && settings.presetCaptureSize.height == 10_000,
            "size=\(settings.presetCaptureSize)"
        )

        settings.recordingFormat = "mov"
        settings.recordingFrameRate = 1
        settings.keyDisplayEnabled = true
        settings.colorPickerFormat = "rgb"
        settings.cameraOverlayEnabled = true
        settings.cameraOverlayPosition = "topLeft"
        settings.cameraOverlaySize = "large"
        check(
            "wiring: new preferences round-trip through UserDefaults",
            defaults.string(forKey: AppSettings.Key.recordingFormat) == "mov"
                && defaults.integer(forKey: AppSettings.Key.recordingFrameRate) == 1
                && defaults.bool(forKey: AppSettings.Key.keyDisplayEnabled)
                && defaults.string(forKey: AppSettings.Key.colorPickerFormat) == "rgb"
                && defaults.bool(forKey: AppSettings.Key.cameraOverlayEnabled)
                && defaults.string(forKey: AppSettings.Key.cameraOverlayPosition) == "topLeft"
                && defaults.string(forKey: AppSettings.Key.cameraOverlaySize) == "large"
        )
        check(
            "wiring: camera position / size values resolve from the stored strings",
            settings.cameraOverlayPositionValue == .topLeft
                && settings.cameraOverlaySizeValue == .large
        )
        check(
            "wiring: edited recording frame rate is clamped at use",
            settings.recordingConfiguration.effectiveFrameRate == 10,
            "effective=\(settings.recordingConfiguration.effectiveFrameRate)"
        )

        // Three modes now: the interactive window picker is back as a state of
        // the region overlay, exposed as a mode at this layer.
        check(
            "wiring: capture modes are region / window / full screen",
            CaptureMode.allCases.count == 3
                && CaptureMode.allCases.map(\.rawValue) == ["region", "window", "fullScreen"],
            "modes=\(CaptureMode.allCases.map(\.rawValue).joined(separator: " | "))"
        )

        // Multi-window mode must not reuse the resize-handle chrome.
        let overlay = CaptureOverlayView(
            frame: CGRect(origin: .zero, size: canvasSize),
            mode: .multiWindow,
            prefilledSelection: nil,
            showCrosshair: true,
            rendersOffscreen: true
        )
        check(
            "wiring: multi-window mode hides the selection toolbar",
            !overlay.isToolbarVisibleForTesting && !overlay.isIndicatorVisibleForTesting
        )
        check(
            "wiring: multi-window mode has no rectangle selection",
            overlay.selectionRectForTesting == .zero,
            "selection=\(format(overlay.selectionRectForTesting))"
        )

        // Menu wiring: the four new entries must actually be installed under
        // 「截图」, not just reachable from a selector.
        let menuDelegate = AppDelegate()
        AppMenuBuilder.install(appName: "Unseen Self Test", delegate: menuDelegate)
        // Top-level submenu items are created with an empty title; AppKit takes
        // the visible name from the submenu itself.
        let captureMenu = NSApp.mainMenu?.items.first {
            $0.title == "截图" || $0.submenu?.title == "截图"
        }?.submenu
        let captureTitles = captureMenu?.items.map(\.title) ?? []
        for title in [
            "截图光标下的窗口",
            "长截图", "延时截图", "多窗口截图", "预设区域尺寸截图",
            "开始 / 停止录屏", "取色",
            "带壳截图", "摄像头画中画"
        ] {
            check(
                "wiring: menu「截图」contains \(title)",
                captureTitles.contains(title),
                "titles=\(captureTitles.joined(separator: " | "))"
            )
        }
    }

    // MARK: - Status menu: the shortcut column

    /// The status menu's right-hand shortcut column.
    ///
    /// The real menu is built with a throw-away preferences domain, so these
    /// checks pin what the user sees on a fresh install and what happens when a
    /// feature switch or a slot changes. AppKit draws the column from
    /// `keyEquivalent` + `keyEquivalentModifierMask`, so both are asserted —
    /// plus the text they add up to, against the same `displayString` the
    /// settings page shows.
    private static func runStatusMenuShortcutTests(into directory: URL) {
        print("[status-menu] --- each row prints its own shortcut ---")
        let suiteName = "UnseenStatusMenu-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            check("status menu: isolated defaults", false)
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)

        func menu() -> NSMenu {
            AppMenuBuilder.statusMenu(settings: settings, target: NSApp)
        }

        func find(_ entry: MenuBarEntry, in menu: NSMenu) -> NSMenuItem? {
            menu.items.first { $0.title == settings.menuBarTitle(for: entry) }
        }

        /// The text AppKit draws for an item, written the way the settings page
        /// writes it: modifiers in system order, then the key.
        func text(_ item: NSMenuItem?) -> String {
            guard let item else { return "missing" }
            // Separators and unbound rows have no key, so they draw no glyph.
            guard !item.keyEquivalent.isEmpty else { return "" }
            var symbols = ""
            let mask = item.keyEquivalentModifierMask
            if mask.contains(.control) { symbols += "⌃" }
            if mask.contains(.option) { symbols += "⌥" }
            if mask.contains(.shift) { symbols += "⇧" }
            if mask.contains(.command) { symbols += "⌘" }
            return symbols + item.keyEquivalent.uppercased()
        }

        let expected: [(entry: MenuBarEntry, key: String, mask: NSEvent.ModifierFlags, text: String)] = [
            // Global shortcut rows: the bindable combination, in the key and
            // the mask AppKit needs to draw and match it.
            // The shipped binding is ⌘P (key code 35), not the README's ⌥⌘V.
            (.openClipboard, "p", [.command], "⌘P"),
            (.captureRegion, "a", [.option], "⌥A"),
            (.captureWindow, "q", [.option], "⌥Q"),
            (.captureFullScreen, "w", [.option], "⌥W"),
            (.ocr, "", [], ""),
            (.scroll, "z", [.option], "⌥Z"),
            (.recording, "x", [.option], "⌥X"),
            (.colorPicker, "", [], ""),
            (.keyDisplay, "", [], ""),
            // Rows with no bindable slot fall back to the app menu's key.
            (.capturePreset, "e", [.control, .option, .command], "⌃⌥⌘E"),
            (.settings, ",", [.command], "⌘,"),
            (.quit, "q", [.command], "⌘Q"),
            // No shortcut anywhere: no key, and therefore no glyph.
            (.camera, "", [], ""),
            (.about, "", [], "")
        ]

        let status = menu()
        var mismatches: [String] = []
        for row in expected {
            guard let item = find(row.entry, in: status) else {
                mismatches.append("\(row.entry.rawValue)=missing")
                continue
            }
            if item.keyEquivalent != row.key
                || item.keyEquivalentModifierMask != row.mask
                || text(item) != row.text {
                mismatches.append(
                    "\(row.entry.rawValue)=[\(item.keyEquivalent)|\(text(item))]"
                        + " want [\(row.key)|\(row.text)]"
                )
            }
        }
        check(
            "status menu: every row prints the shortcut that invokes it",
            mismatches.isEmpty,
            mismatches.isEmpty ? "14 rows" : mismatches.joined(separator: " ")
        )

        check(
            "status menu: an unbound row reserves no key and draws no placeholder",
            [MenuBarEntry.ocr, .colorPicker, .keyDisplay, .camera, .about]
                .allSatisfy { text(find($0, in: status)).isEmpty },
            "empty=" + [MenuBarEntry.ocr, .colorPicker, .keyDisplay, .camera, .about]
                .map { "\($0.rawValue):\(text(find($0, in: status)))" }
                .joined(separator: " ")
        )

        // The globally-bound rows must read exactly like the settings page.
        var drifting: [String] = []
        var boundRows = 0
        for entry in MenuBarEntry.allCases {
            guard let id = entry.hotKeyID else { continue }
            let state = settings.hotKeyState(id)
            guard state.enabled, state.configuration.isBound else { continue }
            boundRows += 1
            let shown = text(find(entry, in: status))
            if shown != state.configuration.displayString {
                drifting.append("\(entry.rawValue)=\(shown)≠\(state.configuration.displayString)")
            }
        }
        check(
            "status menu: a global row reads the same as the 快捷键 page",
            drifting.isEmpty && boundRows == 7,
            drifting.isEmpty ? "bound=\(boundRows)" : drifting.joined(separator: " ")
        )

        // Two visible rows sharing a combination would make the press
        // ambiguous; the shipped configuration must not do that.
        var combinations: [String: Int] = [:]
        for item in status.items where !item.isSeparatorItem && !item.keyEquivalent.isEmpty {
            let key = "\(item.keyEquivalent)|\(item.keyEquivalentModifierMask.rawValue)"
            combinations[key, default: 0] += 1
        }
        check(
            "status menu: no two rows claim the same combination",
            combinations.values.allSatisfy { $0 == 1 },
            "combos=" + combinations.filter { $0.value > 1 }.map(\.key).sorted().joined(separator: ",")
        )

        // A switched-off feature must not advertise its key: Carbon does not
        // register it, so the right-hand column would be a promise the app
        // cannot keep.
        settings.scrollHotKeyEnabled = false
        let scrollOff = menu()
        check(
            "status menu: switching a shortcut off clears its row",
            text(find(.scroll, in: scrollOff)).isEmpty
                && text(find(.captureRegion, in: scrollOff)) == "⌥A",
            "scroll=\(text(find(.scroll, in: scrollOff))) "
                + "region=\(text(find(.captureRegion, in: scrollOff)))"
        )
        settings.scrollHotKeyEnabled = true

        // Clearing a slot (the recorder's ×) does the same, independently of
        // the switch.
        let savedKeyCode = settings.scrollHotKeyKeyCode
        let savedModifiers = settings.scrollHotKeyModifiers
        settings.scrollHotKeyKeyCode = Int(HotKeyConfiguration.unbound.keyCode)
        settings.scrollHotKeyModifiers = Int(HotKeyConfiguration.unbound.modifiers)
        let cleared = menu()
        check(
            "status menu: clearing a slot clears its row, the switch stays on",
            settings.scrollHotKeyEnabled
                && text(find(.scroll, in: cleared)).isEmpty,
            "scroll=\(text(find(.scroll, in: cleared)))"
        )
        settings.scrollHotKeyKeyCode = savedKeyCode
        settings.scrollHotKeyModifiers = savedModifiers

        // ⇧⌘P lives on 钉图, which has no status row; the status menu must not
        // borrow it for 退出 or anything else.
        check(
            "status menu: only the rows with a real slot print a key",
            MenuBarEntry.allCases.filter { !text(find($0, in: status)).isEmpty }
                .map(\.rawValue)
                == ["openClipboard", "captureRegion", "captureWindow", "capturePreset",
                    "captureFullScreen", "scroll", "recording", "settings", "quit"],
            "rows=" + MenuBarEntry.allCases
                .filter { !text(find($0, in: status)).isEmpty }
                .map(\.rawValue).joined(separator: ",")
        )

        // The utility rows' keys are the app menu's own, so the two surfaces
        // cannot disagree about what ⌘Q or ⌘, does.
        check(
            "status menu: 设置 / 退出 carry the app menu's ⌘, and ⌘Q",
            text(find(.settings, in: status)) == "⌘,"
                && text(find(.quit, in: status)) == "⌘Q",
            "settings=\(text(find(.settings, in: status))) "
                + "quit=\(text(find(.quit, in: status)))"
        )

        print("[status-menu] " + expected.map { "\($0.entry.rawValue)=\($0.text)" }
            .joined(separator: " "))

        // A dump of the built menu, so the screenshot in Docs has a text twin.
        let url = directory.appendingPathComponent("status-menu-shortcuts.txt")
        let dump = status.items.map { item in
            let shown = text(item)
            return shown.isEmpty ? item.title : "\(item.title)  \(shown)"
        }.joined(separator: "\n") + "\n"
        try? Data(dump.utf8).write(to: url)
        check("status menu: the shortcut column is dumped for review", !dump.isEmpty)
    }

    /// The 快捷键 page as cards: four `GroupSlab`s, thirty rows, one aligned
    /// shortcut column, the `GroupRow` rhythm, and no caption strip.
    ///
    /// The real page is laid out in an `NSHostingView`; the columns are read
    /// from the invisible `HotKeyListColumnMarker`s each row places at its two
    /// fixed-width cells, so this measures the shipping layout rather than
    /// recomputing it from the metrics.
    ///
    /// 2026-10-24 (second pass): the table was replaced by the same
    /// `GroupHeader` + `GroupSlab` pair the other settings pages draw. What is
    /// checked below is what outlived the table: every action on the page
    /// exactly once, one card per block, the shortcut slot as one column, the
    /// 44 pt row rhythm, and the longest name still fitting at the owner's
    /// 538 pt pane. A caption row, a stacked fallback and a zebra stripe are
    /// gone with the table, so there is nothing left to assert about them.
    private static func runHotKeyListTests(into directory: URL) {
        print("[hotkey-list] --- four cards, thirty rows, one shortcut column ---")
        let tempHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("unseen-hotkey-list-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        let previousHome = ProcessInfo.processInfo.environment["UNSEEN_HOME"]
        setenv("UNSEEN_HOME", tempHome.path, 1)
        let suiteName = "UnseenHotKeyList-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            check("hotkey-list: isolated defaults", false)
            return
        }
        let settings = AppSettings(defaults: defaults)
        let model = AppModel(settings: settings)
        model.stopMonitoring()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            if let previousHome {
                setenv("UNSEEN_HOME", previousHome, 1)
            } else {
                unsetenv("UNSEEN_HOME")
            }
            try? FileManager.default.removeItem(at: tempHome)
        }

        let lightGround = NSColor(srgbRed: 0.965, green: 0.965, blue: 0.972, alpha: 1)
        let darkGround = NSColor(srgbRed: 0.118, green: 0.118, blue: 0.125, alpha: 1)
        func ground(_ appearance: NSAppearance.Name) -> NSColor {
            appearance == .aqua ? lightGround : darkGround
        }

        struct PageRender {
            let container: NSView
            let hosting: NSHostingView<SettingsView>
            let image: NSBitmapImageRep?
        }

        /// One settings page on a solid ground, so the cards are measured with
        /// the same backdrop the other snapshot checks use.
        func render(
            section: SettingsSection = .hotkeys,
            groupID: String = PageGroupID.none,
            appearance: NSAppearance.Name = .aqua,
            width: CGFloat,
            height: CGFloat = 1800
        ) -> PageRender {
            let frame = CGRect(x: 0, y: 0, width: width, height: height)
            let container = NSView(frame: frame)
            container.appearance = NSAppearance(named: appearance)
            container.wantsLayer = true
            container.layer?.backgroundColor = ground(appearance).cgColor
            let hosting = NSHostingView(
                rootView: SettingsView(model: model, section: section, groupID: groupID)
            )
            hosting.frame = frame
            hosting.appearance = NSAppearance(named: appearance)
            container.addSubview(hosting)
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            container.layoutSubtreeIfNeeded()
            container.displayIfNeeded()
            let image = container.bitmapImageRepForCachingDisplay(in: container.bounds)
            if let image {
                container.cacheDisplay(in: container.bounds, to: image)
            }
            return PageRender(container: container, hosting: hosting, image: image)
        }

        struct Anchor {
            let column: HotKeyListColumn
            let frame: CGRect
        }

        func anchors(in hosting: NSView) -> [Anchor] {
            var result: [Anchor] = []
            func walk(_ view: NSView) {
                if let marker = view as? HotKeyListColumnMarkerView {
                    result.append(Anchor(
                        column: marker.column,
                        frame: marker.convert(marker.bounds, to: hosting)
                    ))
                }
                for subview in view.subviews { walk(subview) }
            }
            walk(hosting)
            return result
        }

        func textWidth(_ text: String, size: CGFloat = 13) -> CGFloat {
            (text as NSString).size(
                withAttributes: [.font: NSFont.systemFont(ofSize: size)]
            ).width
        }

        func write(_ image: NSBitmapImageRep?, as filename: String) -> Int {
            guard let image,
                  let png = image.representation(using: .png, properties: [:])
            else { return 0 }
            let url = directory.appendingPathComponent(filename)
            try? png.write(to: url)
            print("[hotkey-list] wrote \(url.path) "
                + "(\(image.pixelsWide)×\(image.pixelsHigh) px)")
            return png.count
        }

        // The 快捷键 right pane at the owner's 1020 pt window: the same layout
        // formula `runSettingsLayoutTests` pins (1020 − 2·10 − 182 − 2·10 − 260).
        let pane: CGFloat = 538
        // SettingsView.page's horizontal padding. Quoted here only to place the
        // name column; the anchors themselves are measured.
        let pagePadding: CGFloat = 22

        let page = render(width: pane)
        let pageAnchors = anchors(in: page.hosting)
        let slots = pageAnchors.filter { $0.column == .shortcut }
        let defaultAnchors = pageAnchors.filter { $0.column == .defaultValue }
        let totalRows = HotKeyBindingID.allCases.count

        check(
            "hotkey-list: with no selection the page draws all thirty actions",
            slots.count == totalRows && defaultAnchors.count == totalRows,
            "slots=\(slots.count) defaults=\(defaultAnchors.count) expected=\(totalRows)"
        )

        let slabs = countSubviews(of: GroupSlabMarkerView.self, in: page.hosting)
        check(
            "hotkey-list: the thirty rows live in four GroupSlab cards",
            slabs == HotKeyGroup.allCases.count
                && HotKeyGroup.allCases.reduce(0) { $0 + $1.members.count } == totalRows,
            "slabs=\(slabs) blocks=\(HotKeyGroup.allCases.count) rows=\(totalRows)"
        )

        // The page picks its block from the middle column exactly like every
        // other settings page picks a group, so a selection draws one card.
        print("[hotkey-list] --- the middle column swaps one card for another ---")
        var selectionProblems: [String] = []
        for block in HotKeyGroup.allCases {
            let selected = render(
                groupID: PageGroupID.hotKeyGroup(block),
                width: pane
            )
            let selectedSlabs = countSubviews(
                of: GroupSlabMarkerView.self, in: selected.hosting
            )
            let selectedSlots = anchors(in: selected.hosting)
                .filter { $0.column == .shortcut }
            if selectedSlabs != 1 || selectedSlots.count != block.members.count {
                selectionProblems.append(
                    "\(block.rawValue):slabs=\(selectedSlabs) rows=\(selectedSlots.count)"
                )
            }
        }
        check(
            "hotkey-list: selecting a block draws exactly that one card",
            selectionProblems.isEmpty,
            selectionProblems.isEmpty
                ? HotKeyGroup.allCases.map { "\($0.rawValue):\($0.members.count)" }
                    .joined(separator: " ")
                : selectionProblems.joined(separator: " ")
        )

        // One column even without a caption row: every slot starts at the same
        // x, and 默认 starts exactly one slot + gap further right, so the
        // 136 pt cell and the 8 pt gap are both measured off the layout.
        let slotX = slots.first?.frame.minX ?? 0
        let defaultX = defaultAnchors.first?.frame.minX ?? 0
        var drift: [String] = []
        for anchor in slots where abs(anchor.frame.minX - slotX) > 0.5 {
            drift.append("slot:\(number(anchor.frame.minX))")
        }
        for anchor in defaultAnchors where abs(anchor.frame.minX - defaultX) > 0.5 {
            drift.append("default:\(number(anchor.frame.minX))")
        }
        let expectedGap = HotKeyListMetrics.shortcutColumn + HotKeyListMetrics.controlGap
        check(
            "hotkey-list: one shortcut column at 136 + 8 pt on all thirty rows",
            drift.isEmpty && abs((defaultX - slotX) - expectedGap) < 0.5,
            drift.isEmpty
                ? "slot=\(number(slotX)) default=\(number(defaultX)) "
                    + "gap=\(number(defaultX - slotX)) expected=\(number(expectedGap))"
                : drift.joined(separator: " ")
        )

        // The recorder the cards embed carries only its slot (the 默认 capsule
        // lives in the row), and the slot is exactly the declared width.
        let slotOnly = HotKeyRecorderView(
            keyCode: .constant(Int(HotKeyConfiguration.scroll.keyCode)),
            modifiers: .constant(Int(HotKeyConfiguration.scroll.modifiers)),
            showsDefaultButton: false
        )
        let slotHosting = NSHostingView(rootView: slotOnly)
        slotHosting.layoutSubtreeIfNeeded()
        let slotSize = slotHosting.fittingSize
        check(
            "hotkey-list: the slot is the recorder without its paired button (136 × 28)",
            abs(slotSize.width - HotKeyListMetrics.shortcutColumn) < 0.5
                && slotSize.height >= 26 && slotSize.height <= 30,
            "size=\(slotSize) column=\(HotKeyListMetrics.shortcutColumn)"
        )

        // The card rhythm: 46 pt rows, a 1 pt GroupDivider between neighbours,
        // and only the three card boundaries paying a larger gap.
        let ys = slots.map(\.frame.minY).sorted()
        let pitches = zip(ys, ys.dropFirst()).map { $1 - $0 }
        let expectedPitch = HotKeyListMetrics.rowMinHeight + 1
        let inCard = pitches.filter { abs($0 - expectedPitch) < 0.75 }
        let acrossCards = pitches.filter { abs($0 - expectedPitch) >= 0.75 }
        check(
            "hotkey-list: rows keep the GroupRow 46 pt rhythm, 1 pt hairline between",
            inCard.count == totalRows - HotKeyGroup.allCases.count
                && acrossCards.count == HotKeyGroup.allCases.count - 1
                && acrossCards.allSatisfy { $0 > 50 },
            "inCard=\(inCard.count) across=\(acrossCards.map { number($0) })"
        )

        // No wrap / no ellipsis: at the owner's pane the longest name still
        // fits between the glyph tile and the shortcut slot.
        let nameStart = pagePadding + 14 + 26 + 11
        let available = slotX - nameStart - 10 // the row's Spacer minimum
        let longest = HotKeyBindingID.allCases.map(\.title)
            .max { textWidth($0) < textWidth($1) } ?? ""
        check(
            "hotkey-list: the longest name fits without wrapping at 538 pt",
            available > textWidth(longest) + 4,
            "available=\(number(available)) longest=\(longest) "
                + "needs=\(number(textWidth(longest)))"
        )

        // The four blocks cover the thirty actions in the order they ship.
        check(
            "hotkey-list: the four blocks cover all thirty actions",
            HotKeyGroup.allCases.flatMap(\.members) == HotKeyBindingID.allCases
                && HotKeyGroup.annotationTools.members.count == 12
                && HotKeyGroup.capture.members.count == 8
                && HotKeyGroup.tools.members.count == 4
                && HotKeyGroup.application.members.count == 6,
            "blocks=" + HotKeyGroup.allCases
                .map { "\($0.rawValue):\($0.members.count)" }.joined(separator: " ")
        )

        // Snapshots. The pair puts 快捷键 beside 截图 at the same width and in
        // the same appearance — that image is the "same visual language" proof
        // (card shape, corner radius, group header, hairlines); the single page
        // images keep the old per-appearance artefacts.
        let savedAppearance = NSApp.appearance
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua),
                                       ("dark", NSAppearance.Name.darkAqua)] {
            // The harness launches the app dark; a `NSHostingView` alone is not
            // enough because dynamic AppKit colours (and the page's own
            // secondary ink) resolve against `NSApp.appearance`. Flip the app
            // for this render, then restore it.
            NSApp.appearance = NSAppearance(named: appearanceName)

            let hotkeysPage = render(appearance: appearanceName, width: 1120, height: 1800)
            let pageBytes = write(
                hotkeysPage.image, as: "settings-hotkeys-full-\(name).png"
            )
            check(
                "hotkey-list: the full 快捷键 page renders real pixels (\(name))",
                pageBytes > 10_000,
                "bytes=\(pageBytes)"
            )

            let gap: CGFloat = 16
            let combined = NSView(
                frame: CGRect(x: 0, y: 0, width: pane * 2 + gap, height: 1800)
            )
            combined.appearance = NSAppearance(named: appearanceName)
            combined.wantsLayer = true
            combined.layer?.backgroundColor = ground(appearanceName).cgColor
            for (index, section) in [SettingsSection.hotkeys, .regionCapture].enumerated() {
                let hosting = NSHostingView(
                    rootView: SettingsView(
                        model: model, section: section, groupID: PageGroupID.none
                    )
                )
                hosting.frame = CGRect(
                    x: CGFloat(index) * (pane + gap),
                    y: 0,
                    width: pane,
                    height: 1800
                )
                hosting.appearance = NSAppearance(named: appearanceName)
                combined.addSubview(hosting)
            }
            combined.layoutSubtreeIfNeeded()
            combined.displayIfNeeded()
            let combinedImage = combined.bitmapImageRepForCachingDisplay(in: combined.bounds)
            if let combinedImage {
                combined.cacheDisplay(in: combined.bounds, to: combinedImage)
            }
            let pairBytes = write(
                combinedImage, as: "hotkeys-vs-capture-\(name).png"
            )
            check(
                "hotkey-list: 快捷键 sits beside 截图 as the same card language (\(name))",
                pairBytes > 10_000,
                "bytes=\(pairBytes)"
            )
        }
        NSApp.appearance = savedAppearance

        if !drift.isEmpty {
            print("[hotkey-list] drift: \(drift)")
        }
    }

    // MARK: - History header: one width for search and segments

    /// The owner's screenshot showed the 分类 bar running past the 搜索 field.
    /// Both controls sit in the same 260 pt column with a 10 pt inset, so their
    /// shared width is a property of that column. This renders the two shipping
    /// components exactly as `MainView` stacks them, measures the painted
    /// capsules in the bitmap, and proves every segment label still fits its
    /// equal share — alignment must never be bought with clipped text.
    private static func runHistoryHeaderWidthTests(into directory: URL) {
        print("[history-header] --- search and 分类 share the column width ---")

        struct HeaderProbe: View {
            @State private var text = ""
            @State private var filter: ClipFilter = .all
            let counts: [ClipFilter: Int]

            var body: some View {
                ZStack {
                    Color.white
                    VStack(spacing: 8) {
                        CapsuleSearchField(
                            placeholder: "搜索历史…",
                            text: $text,
                            shortcutHint: "⌘K"
                        )
                        SegmentedPillBar(
                            items: ClipFilter.allCases,
                            selection: $filter,
                            title: \.title,
                            count: { counts[$0] ?? 0 }
                        )
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                }
                // MainColumnMetrics.middle is 260; the two 10 pt insets leave
                // 240 pt for the controls.
                .frame(width: 260, height: 100)
            }
        }

        let counts: [ClipFilter: Int] = [.all: 500, .text: 238, .image: 262]
        let host = NSHostingView(rootView: HeaderProbe(counts: counts))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = CGRect(x: 0, y: 0, width: 260, height: 100)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            check("history header: render bitmap", false)
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            let url = directory.appendingPathComponent("history-header-width.png")
            try? png.write(to: url)
            print("[history-header] wrote \(url.path) (\(rep.pixelsWide)×\(rep.pixelsHigh) px)")
        }

        let scale = CGFloat(rep.pixelsWide) / 260
        struct Band {
            var minY = 0
            var maxY = 0
            var left = Int.max
            var right = -1
        }
        var bands: [Band] = []
        // 6 % ink on white is ≈ 240/255; the 255 ground is the gap above,
        // between and below the controls. A row belongs to a capsule when its
        // first-to-last dark run is wide enough to be the row, not a label.
        for y in 0..<rep.pixelsHigh {
            var first: Int?
            var last: Int?
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let luminance = 0.2126 * color.redComponent
                    + 0.7152 * color.greenComponent
                    + 0.0722 * color.blueComponent
                if luminance < 0.972 {
                    if first == nil { first = x }
                    last = x
                }
            }
            guard let left = first, let right = last,
                  right - left > Int(180 * scale) else { continue }
            if let lastBand = bands.last, y - lastBand.maxY <= 2 {
                bands[bands.count - 1].maxY = y
                bands[bands.count - 1].left = min(bands[bands.count - 1].left, left)
                bands[bands.count - 1].right = max(bands[bands.count - 1].right, right)
            } else {
                bands.append(Band(minY: y, maxY: y, left: left, right: right))
            }
        }

        check(
            "history header: the search field and the bar both render",
            bands.count == 2,
            "bands=\(bands.count)"
        )
        guard bands.count == 2 else { return }

        let searchLeft = CGFloat(bands[0].left) / scale
        let searchRight = CGFloat(bands[0].right + 1) / scale
        let barLeft = CGFloat(bands[1].left) / scale
        let barRight = CGFloat(bands[1].right + 1) / scale
        let searchWidth = searchRight - searchLeft
        let barWidth = barRight - barLeft
        let widthDelta = abs(searchWidth - barWidth)

        check(
            "history header: left edges agree within 1 pt",
            abs(searchLeft - barLeft) <= 1,
            "search=\(number(searchLeft)) bar=\(number(barLeft))"
        )
        check(
            "history header: right edges agree within 1 pt",
            abs(searchRight - barRight) <= 1,
            "search=\(number(searchRight)) bar=\(number(barRight))"
        )
        check(
            "history header: widths agree within 1 pt",
            widthDelta <= 1,
            "search w=\(number(searchWidth)) bar w=\(number(barWidth)) Δ=\(number(widthDelta))"
        )
        check(
            "history header: both fill the 240 pt row",
            abs(searchWidth - 240) <= 1.5 && abs(barWidth - 240) <= 1.5,
            "search=\(number(searchWidth)) bar=\(number(barWidth))"
        )

        // Height is scanned down one interior column of each capsule, not off
        // the band's top and bottom rows: a capsule's topmost row is a straight
        // run, but the ink there is antialiased and only partly covered, so a
        // row-threshold scan can lose the first or last row on one control and
        // not the other — a 0.5 pt error that would swamp the 1 pt tolerance.
        // One column through the middle crosses both edges at full strength.
        func inkHeight(x: Int, overlapping range: ClosedRange<Int>) -> CGFloat {
            var runs: [(Int, Int)] = []
            var start: Int?
            for y in 0..<rep.pixelsHigh {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let luminance = 0.2126 * color.redComponent
                    + 0.7152 * color.greenComponent
                    + 0.0722 * color.blueComponent
                if luminance < 0.965 {
                    if start == nil { start = y }
                } else if let began = start {
                    runs.append((began, y - 1))
                    start = nil
                }
            }
            if let began = start { runs.append((began, rep.pixelsHigh - 1)) }
            // The run that spans this control's vertical middle is its capsule;
            // any other run in the column would be a detached glyph.
            guard let run = runs.first(where: {
                $0.0 <= range.upperBound && $0.1 >= range.lowerBound
            }) else { return 0 }
            return CGFloat(run.1 - run.0 + 1) / scale
        }

        let searchHeight = inkHeight(
            x: (bands[0].left + bands[0].right) / 2,
            overlapping: bands[0].minY...bands[0].maxY
        )
        let barHeight = inkHeight(
            x: (bands[1].left + bands[1].right) / 2,
            overlapping: bands[1].minY...bands[1].maxY
        )
        let heightDelta = abs(searchHeight - barHeight)
        print(
            "[history-header] heights: search \(number(searchHeight)) pt, "
                + "bar \(number(barHeight)) pt, Δ \(number(heightDelta)) pt"
        )
        check(
            "history header: the two capsules are the same height within 1 pt",
            heightDelta <= 1,
            "search=\(number(searchHeight)) bar=\(number(barHeight)) Δ=\(number(heightDelta))"
        )
        // The search field is the reference and has not been touched, so the bar
        // has to land on its measured height rather than on an assumed one.
        check(
            "history header: the bar matches the search field's height",
            abs(barHeight - searchHeight) <= 1,
            "bar=\(number(barHeight)) search=\(number(searchHeight))"
        )
        // Not clipped: the segment capsule is the bar less its 3 pt outer pad on
        // both sides, and it must still clear the 12 pt line box.
        let segmentCapsuleHeight = barHeight - 6
        let lineHeight = NSFont.systemFont(ofSize: 12, weight: .semibold)
            .boundingRectForFont.height
        check(
            "history header: the segment capsule still clears the 12 pt line box",
            segmentCapsuleHeight >= lineHeight + 1,
            "capsule=\(number(segmentCapsuleHeight)) line=\(number(lineHeight))"
        )

        // Each segment gets an equal share. The label + its 10 pt count + the
        // 4 pt gap + 4 pt inner padding on both sides must fit that share;
        // otherwise SwiftUI would truncate the label or draw outside the
        // capsule.
        check(
            "history header: four filter segments",
            ClipFilter.allCases.count == 4,
            "count=\(ClipFilter.allCases.count)"
        )
        let segmentWidth = (barWidth - 3 * 2 - 2 * 3) / 4
        func textWidth(_ string: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
            (string as NSString).size(
                withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]
            ).width
        }
        var widest = 0.0
        for filter in ClipFilter.allCases {
            let title = max(
                textWidth(filter.title, size: 12, weight: .semibold),
                textWidth(filter.title, size: 12, weight: .regular)
            )
            let value = counts[filter] ?? 0
            let countWidth = value > 0 ? textWidth("\(value)", size: 10, weight: .medium) : 0
            let needed = title + (value > 0 ? 4 + countWidth : 0) + 4 * 2
            widest = max(widest, needed)
            check(
                "history header: \(filter.title) fits its segment",
                needed <= segmentWidth + 0.5,
                "needs=\(number(needed)) share=\(number(segmentWidth))"
            )
        }
        print(
            "[history-header] widest label \(number(widest)) of "
                + "\(number(segmentWidth)) pt per segment"
        )
    }

    // MARK: - Shortcut slot: clearing without a visible ×

    /// 2026-10-24: the slot carries one key label again. The `×` segment added
    /// in 4336e51 read as an error cross beside the combination, so the owner
    /// asked for the original capsule back; clearing is Delete-while-recording
    /// (plus the context menu) and the 快捷键 page prints that in one line.
    ///
    /// The checks below prove the shape and that the Delete path still works on
    /// a real recorder driven through the live local event monitor:
    ///
    /// 1. bound and unbound draw the same 164 × 28 pt recorder (the 110 pt slot
    ///    plus the 46 pt 默认 capsule), so 默认 cannot be squeezed (9f140ca);
    /// 2. clicking the slot arms recording, a posted ⌥A is captured (the
    ///    control: if the monitor did not see the event, nothing would bind and
    ///    this check would fail), a click on the 9 pt padding strip records too
    ///    (the whole capsule is the button again), and a posted Delete then
    ///    returns the slot to 0/0 — and ends the recording with it.
    ///
    /// PNGs of both states land next to the other verification images.
    private static func runHotKeyClearEntryTests(into directory: URL) async {
        let unboundView = HotKeyRecorderView(keyCode: .constant(0), modifiers: .constant(0))
        let boundView = HotKeyRecorderView(
            keyCode: .constant(Int(HotKeyConfiguration.scroll.keyCode)),
            modifiers: .constant(Int(HotKeyConfiguration.scroll.modifiers))
        )
        let unboundHosting = NSHostingView(rootView: unboundView)
        let boundHosting = NSHostingView(rootView: boundView)
        unboundHosting.layoutSubtreeIfNeeded()
        boundHosting.layoutSubtreeIfNeeded()
        let unboundSize = unboundHosting.fittingSize
        let boundSize = boundHosting.fittingSize
        // The slot plus its 8 pt gap and the 46 pt 默认 capsule: with the clear
        // segment gone the label is back to the full 92 pt, so 默认 keeps its
        // width and cannot be squeezed into an ellipsis (9f140ca).
        let expectedWidth = HotKeyListMetrics.shortcutColumn
            + HotKeyListMetrics.controlGap
            + HotKeyListMetrics.defaultColumn
        check(
            "hotkey slot: bound and unbound fit one 190 × 28 recorder, 默认 never squeezed",
            boundSize == unboundSize
                && abs(unboundSize.width - expectedWidth) < 0.5
                && abs(unboundSize.height - 28) < 0.5,
            "bound=\(boundSize) unbound=\(unboundSize) expected=\(expectedWidth)×28"
        )

        // The slot is one button now, so a click anywhere on it arms recording.
        var keyCode = Int(HotKeyConfiguration.scroll.keyCode)
        var modifiers = Int(HotKeyConfiguration.scroll.modifiers)
        let interactive = HotKeyRecorderView(
            keyCode: Binding(get: { keyCode }, set: { keyCode = $0 }),
            modifiers: Binding(get: { modifiers }, set: { modifiers = $0 })
        )
        let hosting = NSHostingView(rootView: interactive)
        hosting.frame = CGRect(origin: .zero, size: boundSize)
        hosting.layoutSubtreeIfNeeded()
        let window = NSWindow(
            contentRect: CGRect(x: -3000, y: -3000, width: boundSize.width, height: boundSize.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.alphaValue = 0
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        // One button covers the whole capsule, so a click anywhere on it — the
        // 9 pt padding included — arms recording.
        var clickPoint = CGPoint(x: 55, y: boundSize.height / 2)
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(
                with: type,
                location: clickPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )!
        }
        func click(at point: CGPoint) {
            clickPoint = point
            window.sendEvent(mouse(.leftMouseDown))
            window.sendEvent(mouse(.leftMouseUp))
        }
        /// A key press goes in through the app's own event queue, so the
        /// recorder's local monitor — the shipping path — is what handles it.
        func post(_ code: Int, _ flags: NSEvent.ModifierFlags, _ characters: String) {
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: UInt16(code)
            ) else { return }
            NSApp.postEvent(event, atStart: false)
        }
        func settle() async {
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        func shown() -> String {
            HotKeyConfiguration(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers))
                .displayString
        }

        click(at: CGPoint(x: 55, y: boundSize.height / 2))
        await settle()
        post(kVK_ANSI_A, [.option], "a")
        await settle()
        check(
            "hotkey slot: an armed slot captures the posted ⌥A through the monitor",
            keyCode != Int(HotKeyConfiguration.scroll.keyCode) && shown() == "⌥A",
            "keyCode=\(keyCode) modifiers=\(modifiers) shown=\(shown())"
        )

        // The padding strip is inside the button: a 4 pt click arms recording
        // just like the centre, which is the pre-`×` hit area.
        click(at: CGPoint(x: 4, y: boundSize.height / 2))
        await settle()
        post(kVK_ANSI_B, [.option], "b")
        await settle()
        check(
            "hotkey slot: the whole capsule is the button, the 4 pt padding click records",
            shown() == "⌥B",
            "keyCode=\(keyCode) modifiers=\(modifiers) shown=\(shown())"
        )

        click(at: CGPoint(x: 55, y: boundSize.height / 2))
        await settle()
        post(kVK_Delete, [], "\u{7f}")
        await settle()
        check(
            "hotkey slot: Delete while recording clears the slot to the placeholder",
            keyCode == 0 && modifiers == 0
                && !HotKeyConfiguration(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers)).isBound,
            "keyCode=\(keyCode) modifiers=\(modifiers)"
        )

        // Clearing ends the recording too, so a stray key after it is ignored.
        post(kVK_ANSI_A, [.option], "a")
        await settle()
        check(
            "hotkey slot: clearing also ends the recording, so a later key is ignored",
            keyCode == 0 && modifiers == 0,
            "keyCode=\(keyCode) modifiers=\(modifiers)"
        )

        // Snapshots of the two visible states for the verification folder.
        for (name, view) in [("hotkey-slot-bound", boundView), ("hotkey-slot-unbound", unboundView)] {
            let size = CGSize(width: 190, height: 48)
            let container = NSView(frame: CGRect(origin: .zero, size: size))
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            let snapshot = NSHostingView(rootView: view)
            snapshot.frame = CGRect(origin: .zero, size: size)
            snapshot.appearance = NSAppearance(named: .darkAqua)
            container.addSubview(snapshot)
            snapshot.layoutSubtreeIfNeeded()
            snapshot.displayIfNeeded()
            if let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) {
                container.cacheDisplay(in: container.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: directory.appendingPathComponent("\(name).png"))
                }
            }
        }
    }

    // MARK: - X. Instant capture (window picker, zero-UI path, wiring)

    /// Three independent sections:
    /// 1. the pure `WindowPicker` rules (deterministic, synthetic candidates);
    /// 2. the real instant path: a live test window, real ScreenCaptureKit
    ///    pixels, pasteboard dimensions, optional file, and the cue window's
    ///    level / click-through / 250 ms lifetime;
    /// 3. settings, hotkey registration and menu wiring.
    private static func runInstantCaptureTests(into directory: URL) async {
        print("[instant] --- window picker (pure) ---")

        let ownPID: pid_t = 4_242
        func candidate(
            _ number: Int,
            _ rect: CGRect,
            layer: Int = 0,
            pid: pid_t = 501,
            name: String = "Example",
            own: Bool = false
        ) -> WindowCandidate {
            WindowCandidate(
                windowNumber: number,
                bounds: rect,
                layer: layer,
                ownerPID: pid,
                ownerName: name,
                isOwnedBySelf: own
            )
        }
        func pick(
            _ point: CGPoint,
            _ candidates: [WindowCandidate],
            menubarHeights: Set<Int> = [],
            screenHeight: CGFloat = 0,
            probe: (WindowCandidate) -> WindowContentProbe = { _ in .unavailable }
        ) -> WindowCandidate? {
            WindowPicker.window(
                under: point,
                candidates: candidates,
                ownPID: ownPID,
                screenHeight: screenHeight,
                menubarHeights: menubarHeights,
                probe: probe
            )
        }

        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let middle = CGPoint(x: 500, y: 400)

        // 1. One full-screen window contains the pointer.
        let fullScreen = candidate(101, display, name: "Finder")
        check(
            "instant picker: a single containing window is returned",
            pick(middle, [fullScreen])?.windowNumber == 101,
            "result=\(pick(middle, [fullScreen])?.windowNumber ?? -1)"
        )

        // 2. Overlap: the list is front-to-back, so the first match wins.
        let front = candidate(201, CGRect(x: 100, y: 100, width: 600, height: 400), name: "Front")
        let back = candidate(202, CGRect(x: 0, y: 0, width: 1000, height: 800), name: "Back")
        let overlapPoint = CGPoint(x: 300, y: 300)
        check(
            "instant picker: overlapping windows pick the z-order first match",
            pick(overlapPoint, [front, back])?.windowNumber == 201,
            "result=\(pick(overlapPoint, [front, back])?.windowNumber ?? -1)"
        )

        // 3. A point only in the back window reaches the back window.
        let backOnly = CGPoint(x: 900, y: 700)
        check(
            "instant picker: a point outside the front window reaches the back one",
            pick(backOnly, [front, back])?.windowNumber == 202,
            "result=\(pick(backOnly, [front, back])?.windowNumber ?? -1)"
        )

        // 4. Own windows are invisible to the picker.
        let ownPanel = candidate(301, display, pid: ownPID, name: "Unseen", own: true)
        let normal = candidate(302, CGRect(x: 200, y: 200, width: 500, height: 400))
        check(
            "instant picker: own windows are skipped",
            pick(middle, [ownPanel, normal])?.windowNumber == 302,
            "result=\(pick(middle, [ownPanel, normal])?.windowNumber ?? -1)"
        )

        // 4b. The app's own **main window** is ordinary content: once it is
        //     named as capturable, the picker selects it instead of dropping
        //     it. This is the "he cannot select Unseen's own window"
        //     fix — everything else about own windows is unchanged.
        let ownMain = candidate(303, display, pid: ownPID, name: "Unseen", own: true)
        let mainAllowed = WindowPicker.window(
            under: middle,
            candidates: [ownMain, normal],
            ownPID: ownPID,
            ownCapturableWindowNumbers: [303]
        )
        check(
            "instant picker: the app's own main window is picked when capturable",
            mainAllowed?.windowNumber == 303,
            "result=\(mainAllowed?.windowNumber ?? -1)"
        )

        // 4c. Only that window is allowed. A second own window (the overlay,
        //     panel or a pin — all own, all in front of the main window) is
        //     still rejected, and the ledger says why.
        let ownChrome = candidate(304, display, pid: ownPID, name: "Unseen", own: true)
        let chromeOutcome = WindowPicker.pick(
            at: middle,
            candidates: [ownChrome, ownMain, normal],
            ownPID: ownPID,
            ownCapturableWindowNumbers: [303]
        )
        check(
            "instant picker: own capture chrome is still rejected as ownWindow",
            chromeOutcome.pick?.candidate.windowNumber == 303
                && chromeOutcome.rows.first?.windowNumber == 304
                && chromeOutcome.rows.first?.reject == .ownWindow,
            "pick=\(chromeOutcome.pick?.candidate.windowNumber ?? -1) "
                + "rows=\(chromeOutcome.rows.map { "\($0.windowNumber):\($0.reject?.rawValue ?? "SELECTED")" })"
        )

        // 4d. The allowance is per window number, not "any own window": a
        //     non-empty allow-list must not make an unnamed own window pickable.
        let unnamedOwn = WindowPicker.window(
            under: middle,
            candidates: [ownChrome],
            ownPID: ownPID,
            ownCapturableWindowNumbers: [303]
        )
        check(
            "instant picker: the own-window allowance is exactly one window number",
            unnamedOwn == nil,
            "result=\(unnamedOwn?.windowNumber ?? -1)"
        )

        // 4e. Being allowed bypasses nothing else: the main window is still
        //     subject to containment, so a pointer outside it selects nothing.
        let outsideMain = WindowPicker.window(
            under: CGPoint(x: 2_000, y: 1_200),
            candidates: [ownMain],
            ownPID: ownPID,
            ownCapturableWindowNumbers: [303]
        )
        check(
            "instant picker: an allowed own window still has to contain the pointer",
            outsideMain == nil,
            "result=\(outsideMain?.windowNumber ?? -1)"
        )

        // 5. Layer 25 is the cursor mirror. iShot drops it only when its height
        //    equals a real menu bar — the layer alone is not a veto, which is
        //    what used to hide every layered tool window.
        let menuBar = candidate(401, display, layer: 25, name: "Window Server")
        check(
            "instant picker: the layer-25 cursor mirror is dropped when it matches a menu bar",
            pick(middle, [menuBar, normal], menubarHeights: [900])?.windowNumber == 302,
            "result=\(pick(middle, [menuBar, normal], menubarHeights: [900])?.windowNumber ?? -1)"
        )
        check(
            "instant picker: layer 25 alone does not hide a window",
            pick(middle, [menuBar, normal])?.windowNumber == 401,
            "result=\(pick(middle, [menuBar, normal])?.windowNumber ?? -1)"
        )
        // 5b. A layered tool window (layer 3) is capturable; the old
        //     "layer must be 0" rule was the reason real apps picked nothing.
        let floating = candidate(402, CGRect(x: 100, y: 100, width: 700, height: 500),
                                 layer: 3, name: "Floating")
        check(
            "instant picker: a layer-3 tool window is pickable",
            pick(CGPoint(x: 300, y: 300), [floating, back])?.windowNumber == 402,
            "result=\(pick(CGPoint(x: 300, y: 300), [floating, back])?.windowNumber ?? -1)"
        )
        // 5c. iShot's empty-content rule: a layered window whose bitmap has no
        //     opaque area (or under 10 pt of it) is dropped.
        let ghost = candidate(403, CGRect(x: 100, y: 100, width: 700, height: 500),
                              layer: 5, name: "Ghost")
        check(
            "instant picker: a layered window with empty content is dropped",
            pick(CGPoint(x: 300, y: 300), [ghost, back],
                 probe: { _ in .empty })?.windowNumber == 202,
            "result=\(pick(CGPoint(x: 300, y: 300), [ghost, back], probe: { _ in .empty })?.windowNumber ?? -1)"
        )
        let thinContent = pick(
            CGPoint(x: 300, y: 300),
            [ghost, back],
            probe: { _ in .content(CGRect(x: 110, y: 110, width: 9, height: 400)) }
        )
        check(
            "instant picker: content thinner than 10 pt is dropped",
            thinContent?.windowNumber == 202,
            "result=\(thinContent?.windowNumber ?? -1)"
        )
        // 5d. A trimmed content rect (iShot's >5 pt mismatch) becomes the pick.
        let trimmedPick = WindowPicker.pick(
            at: CGPoint(x: 300, y: 300),
            candidates: [ghost],
            ownPID: ownPID,
            probe: { _ in .content(CGRect(x: 120, y: 120, width: 300, height: 200)) }
        )
        check(
            "instant picker: a >5 pt content mismatch trims the picked rect",
            trimmedPick.pick?.trimmed == true
                && trimmedPick.pick?.rect == CGRect(x: 120, y: 120, width: 300, height: 200),
            "pick=\(String(describing: trimmedPick.pick))"
        )
        // 5e. Desktop windows (negative layer) are only capturable as wallpaper.
        check(
            "instant picker: a negative-layer desktop window is skipped",
            pick(middle, [candidate(404, display, layer: -1, name: "Window Server"),
                          normal])?.windowNumber == 302
        )

        // 6. A 20 pt floating window is below the 40 pt minimum.
        let tooltip = candidate(501, CGRect(x: 450, y: 350, width: 20, height: 20), name: "Tooltip")
        check(
            "instant picker: windows smaller than 40 pt are skipped",
            pick(middle, [tooltip, normal])?.windowNumber == 302,
            "result=\(pick(middle, [tooltip, normal])?.windowNumber ?? -1)"
        )
        check(
            "instant picker: a 40 pt window is large enough",
            pick(
                middle,
                [candidate(502, CGRect(x: 480, y: 380, width: 40, height: 40))]
            )?.windowNumber == 502
        )

        // 7. Empty desktop → nil. The instant path reports this instead of
        //    quietly capturing the whole display, which is what iShot does.
        check(
            "instant picker: an empty desktop returns nil",
            pick(CGPoint(x: 1300, y: 850), [normal]) == nil
        )

        // 8. Empty candidate list → nil.
        check("instant picker: an empty candidate list returns nil", pick(middle, []) == nil)

        // 9. Boundary semantics: half-open containment, like CGRect.contains.
        //    A pointer exactly on maxX/maxY belongs to the window behind it.
        let edgeWindow = candidate(601, CGRect(x: 100, y: 100, width: 300, height: 200))
        check(
            "instant picker: x == maxX is outside (half-open bounds)",
            pick(CGPoint(x: 400, y: 200), [edgeWindow]) == nil,
            "point=(400,200) bounds=\(NSStringFromRect(edgeWindow.bounds))"
        )
        check(
            "instant picker: x == maxX - 0.01 is inside",
            pick(CGPoint(x: 399.99, y: 200), [edgeWindow])?.windowNumber == 601
        )
        check(
            "instant picker: minX is inside (closed lower edge)",
            pick(CGPoint(x: 100, y: 200), [edgeWindow])?.windowNumber == 601
        )

        // 10. Mixed stack: own panel + menu bar + tooltip + one normal window.
        let mixed = [
            ownPanel,
            candidate(701, display, layer: 25, name: "HUD"),
            tooltip,
            candidate(702, CGRect(x: 150, y: 150, width: 480, height: 360), name: "Editor")
        ]
        check(
            "instant picker: mixed stack finds the only normal window",
            pick(CGPoint(x: 250, y: 250), mixed, menubarHeights: [900])?.windowNumber == 702,
            "result=\(pick(CGPoint(x: 250, y: 250), mixed, menubarHeights: [900])?.windowNumber ?? -1)"
        )

        // MARK: Real instant path

        print("[instant] --- instant path (real pixels) ---")
        let suiteName = "UnseenInstantTest-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            check("instant: create isolated defaults", false)
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)

        let root = directory.appendingPathComponent("instant", isDirectory: true)
        let noSaveDirectory = root.appendingPathComponent("no-save", isDirectory: true)
        let saveDirectory = root.appendingPathComponent("save", isDirectory: true)
        // A re-run into the same UNSEEN_TEST_OUT must not inherit the
        // previous run's files: the "no file" assertion is about this run.
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: noSaveDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
        settings.captureFormat = "png"
        settings.captureCursor = false
        settings.instantCaptureSound = false
        settings.instantCaptureVisualCue = false
        settings.instantCaptureAlsoSave = false
        settings.captureDirectoryPath = noSaveDirectory.path

        // Wiring checks do not need screen-recording permission, so they run
        // even if the pixel section below has to be skipped.
        defer { runInstantWiringChecks() }

        guard ScreenCapture.hasScreenRecordingPermission else {
            print("[instant] SKIP real captures: no screen recording permission; "
                + "picker + wiring checks above remain the coverage")
            return
        }

        // A real window owned by this process, used as the capture target. It
        // is a real `MainWindow` — the class `MainWindowController` creates —
        // so the candidate carries the production flags (own pid, owned by
        // self) and is allowed by the own-window rule the same way the app's
        // own history window is. Any other own window stays rejected; see
        // `runOwnWindowCaptureTests`.
        let target = MainWindow(
            contentRect: CGRect(x: 260, y: 300, width: 300, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        target.title = "Instant Self Test Target"
        target.backgroundColor = NSColor.systemPink
        target.isReleasedWhenClosed = false
        target.orderFrontRegardless()
        target.displayIfNeeded()
        try? await Task.sleep(nanoseconds: 200_000_000)
        defer { target.orderOut(nil); target.close() }

        let frame = target.frame
        let point = CGPoint(x: frame.midX, y: frame.midY)
        let scale = target.backingScaleFactor
        let expectedPixels = CGSize(
            width: (frame.width * scale).rounded(),
            height: (frame.height * scale).rounded()
        )
        print(
            "[instant] target frame=\(NSStringFromRect(frame)) scale=\(scale) "
            + "expectedPixels=\(Int(expectedPixels.width))×\(Int(expectedPixels.height)) "
            + "windowNumber=\(target.windowNumber)"
        )
        check(
            "instant: target display is 2x (pixel expectation is 2 × points)",
            scale == 2,
            "scale=\(scale)"
        )

        let targetCandidate = WindowCandidate(
            windowNumber: target.windowNumber,
            bounds: frame,
            layer: 0,
            ownerPID: ProcessInfo.processInfo.processIdentifier,
            ownerName: "Unseen",
            isOwnedBySelf: true
        )

        let coordinator = CaptureCoordinator(settings: settings)
        let overlayBefore = coordinator.isOverlayPresenting
        let task = coordinator.startInstant(
            .window,
            pointer: point,
            candidates: [targetCandidate]
        )
        let result: InstantCaptureResult?
        if let task {
            result = await task.value
        } else {
            result = nil
        }

        // 11. Zero-UI: no overlay controller, no overlay panel.
        check(
            "instant: the coordinator accepts the instant request",
            result != nil,
            "result=\(result == nil ? "nil" : "returned")"
        )
        check(
            "instant: no overlay was presented (before/during/after)",
            !overlayBefore && !coordinator.isOverlayPresenting,
            "before=\(overlayBefore) after=\(coordinator.isOverlayPresenting)"
        )
        let visibleOverlayPanels = NSApp.windows
            .compactMap { $0 as? CaptureOverlayPanel }
            .filter(\.isVisible)
        check(
            "instant: no CaptureOverlayPanel is visible after the capture",
            visibleOverlayPanels.isEmpty,
            "panels=\(visibleOverlayPanels.count)"
        )

        // 12. The window's exact pixel size landed on the pasteboard.
        check(
            "instant: the result is a window capture",
            result?.succeeded == true && result?.windowNumber == target.windowNumber,
            "succeeded=\(result?.succeeded ?? false) "
                + "window=\(result?.windowNumber ?? -1) target=\(target.windowNumber) "
                + "error=\(result?.error?.localizedDescription ?? "-")"
        )
        check(
            "instant: captured pixels are frame × scale",
            result?.pixelSize == expectedPixels,
            "pixels=\(Int(result?.pixelSize.width ?? 0))×\(Int(result?.pixelSize.height ?? 0)) "
                + "expected=\(Int(expectedPixels.width))×\(Int(expectedPixels.height))"
        )

        let pastedImage = NSPasteboard.general
            .readObjects(forClasses: [NSImage.self], options: nil)?
            .first as? NSImage
        let pastedReps = pastedImage?.representations.compactMap { $0 as? NSBitmapImageRep } ?? []
        let pastedWidth = pastedReps.map(\.pixelsWide).max() ?? 0
        let pastedHeight = pastedReps.map(\.pixelsHigh).max() ?? 0
        check(
            "instant: the pasteboard holds the window image at frame × scale",
            pastedWidth == Int(expectedPixels.width)
                && pastedHeight == Int(expectedPixels.height),
            "pasteboard=\(pastedWidth)×\(pastedHeight) "
                + "expected=\(Int(expectedPixels.width))×\(Int(expectedPixels.height))"
        )

        // 13. alsoSave=false writes nothing; alsoSave=true writes one PNG with
        //     the same pixel dimensions.
        let filesAfterNoSave = (try? FileManager.default
            .contentsOfDirectory(atPath: noSaveDirectory.path)) ?? []
        check(
            "instant: alsoSave=false writes no file",
            filesAfterNoSave.isEmpty,
            "files=\(filesAfterNoSave.joined(separator: ","))"
        )

        settings.captureDirectoryPath = saveDirectory.path
        settings.instantCaptureAlsoSave = true
        var savedResult: InstantCaptureResult?
        if let saveTask = coordinator.startInstant(
            .window,
            pointer: point,
            candidates: [targetCandidate]
        ) {
            savedResult = await saveTask.value
        }
        let savedFiles = (try? FileManager.default
            .contentsOfDirectory(atPath: saveDirectory.path)) ?? []
        check(
            "instant: alsoSave=true writes exactly one file",
            savedFiles.count == 1 && savedResult?.savedURL != nil,
            "files=\(savedFiles.joined(separator: ",")) "
                + "saved=\(savedResult?.savedURL?.lastPathComponent ?? "-")"
        )
        if let url = savedResult?.savedURL {
            let dimensions = sipsDimensions(url)
            check(
                "instant: the saved PNG has the window's pixel size",
                dimensions.width == Int(expectedPixels.width)
                    && dimensions.height == Int(expectedPixels.height),
                "sips=\(dimensions.width.map(String.init) ?? "?")×"
                    + "\(dimensions.height.map(String.init) ?? "?") "
                    + "expected=\(Int(expectedPixels.width))×\(Int(expectedPixels.height))"
            )
        } else {
            check("instant: the saved PNG has the window's pixel size", false, "no URL")
        }

        // 14. Cue window: click-through, above the overlay level, gone after
        //     ~250 ms.
        if let screen = NSScreen.screens.first {
            let cue = InstantCaptureCueController()
            let cuePoint = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
            cue.show(at: cuePoint, on: screen)
            if let cueWindow = cue.window {
                check(
                    "instant cue: the cue ignores mouse events",
                    cueWindow.ignoresMouseEvents,
                    "ignoresMouseEvents=\(cueWindow.ignoresMouseEvents)"
                )
                check(
                    "instant cue: the cue is at or above the screen-saver level",
                    cueWindow.level.rawValue >= NSWindow.Level.screenSaver.rawValue,
                    "level=\(cueWindow.level.rawValue) "
                        + "screenSaver=\(NSWindow.Level.screenSaver.rawValue)"
                )
                check(
                    "instant cue: the cue is visible but cannot become key",
                    cueWindow.isVisible && !cueWindow.canBecomeKey,
                    "visible=\(cueWindow.isVisible) canBecomeKey=\(cueWindow.canBecomeKey)"
                )
                check(
                    "instant cue: the ring is centred on the pointer",
                    abs(cueWindow.frame.midX - cuePoint.x) < 1
                        && abs(cueWindow.frame.midY - cuePoint.y) < 1,
                    "frame=\(NSStringFromRect(cueWindow.frame)) point=\(NSStringFromPoint(cuePoint))"
                )

                try? await Task.sleep(nanoseconds: 400_000_000)
                check(
                    "instant cue: it closes itself after ~250 ms",
                    !cue.isPresenting && !(cue.window?.isVisible ?? false),
                    "presenting=\(cue.isPresenting) "
                        + "visible=\(cue.window?.isVisible ?? false) "
                        + "duration=\(InstantCaptureCueController.duration)s"
                )
            } else {
                check("instant cue: a cue window is created", false)
            }
            cue.close()
        } else {
            check("instant cue: a screen is available", false)
        }
    }

    /// The app's own windows: the main window is capturable, every capture
    /// surface stays excluded.
    ///
    /// The pure rules above prove the decision function; this group proves the
    /// *real* one — real `MainWindow`, real chrome windows of the classes the
    /// overlay/panel/pin use, the real window-server stack and real
    /// ScreenCaptureKit pixels. It deliberately avoids opening the user's
    /// database or pins: the rule only looks at window ownership, class and
    /// number, none of which the controllers change.
    private static func runOwnWindowCaptureTests(into directory: URL) async {
        print("[own-window] --- app's own main window vs capture chrome ---")

        /// The production picker over a candidate list, with the ledger printed
        /// so a failure names the window and the rule. The default is the live
        /// window-server stack; callers that need isolation from a transient
        /// foreign window (a notification banner, another app) pass a subset of
        /// those same real candidates.
        func ledger(
            _ label: String,
            at point: CGPoint,
            candidates: [WindowCandidate]? = nil
        ) -> WindowPickOutcome {
            let stack = ScreenCapture.instantWindowStack()
            let pool = candidates ?? stack.candidates
            let outcome = WindowPicker.pick(
                at: point,
                candidates: pool,
                ownPID: ProcessInfo.processInfo.processIdentifier,
                ownCapturableWindowNumbers: OwnWindowCapture.capturableWindowNumbers,
                screenHeight: stack.screenHeight,
                menubarHeights: stack.menubarHeights,
                probe: { ScreenCapture.windowContentProbe(for: $0) }
            )
            print("[own-window] \(label) point=\(NSStringFromPoint(point)) "
                + "candidates=\(pool.count) "
                + "capturable=\(OwnWindowCapture.capturableWindowNumbers.sorted())")
            for row in outcome.rows {
                print("[own-window]   #\(row.windowNumber) "
                    + "\(row.ownerName.isEmpty ? "?" : row.ownerName) "
                    + "\(row.windowName.isEmpty ? "" : "\"\(row.windowName)\" ")"
                    + "layer=\(row.layer) bounds=\(NSStringFromRect(row.bounds)) "
                    + "→ \(row.reject?.rawValue ?? "SELECTED")")
            }
            return outcome
        }

        /// The real-stack entries for windows this process owns, in the window
        /// server's z-order. The picker's own-window rule is the thing under
        /// test, and these are the real window-server facts for it.
        func ownCandidates() -> [WindowCandidate] {
            let ownPID = ProcessInfo.processInfo.processIdentifier
            return ScreenCapture.instantWindowStack().candidates.filter {
                $0.isOwnedBySelf || ($0.ownerPID != 0 && $0.ownerPID == ownPID)
            }
        }

        func rowSummary(_ outcome: WindowPickOutcome) -> String {
            outcome.rows
                .map { "\($0.windowNumber):\($0.reject?.rawValue ?? "SELECTED")" }
                .joined(separator: ",")
        }

        // 1. The policy names the visible `MainWindow` and nothing else, and a
        //    window that is off screen is never capturable — that is what stops
        //    a closed window's number from naming somebody else's window later.
        let mainWindow = MainWindow(
            contentRect: NSRect(x: 320, y: 260, width: 420, height: 300),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        mainWindow.title = "Unseen"
        mainWindow.isReleasedWhenClosed = false
        mainWindow.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
        defer { mainWindow.orderOut(nil); mainWindow.close() }
        check(
            "own-window: an off-screen MainWindow is not capturable",
            OwnWindowCapture.numbers(in: [mainWindow]).isEmpty,
            "numbers=\(OwnWindowCapture.numbers(in: [mainWindow]).sorted())"
        )

        mainWindow.orderFrontRegardless()
        mainWindow.displayIfNeeded()
        try? await Task.sleep(nanoseconds: 300_000_000)
        let mainNumber = mainWindow.windowNumber
        check(
            "own-window: the visible MainWindow is the capturable own window",
            OwnWindowCapture.numbers(in: [mainWindow]) == [mainNumber]
                && OwnWindowCapture.capturableWindowNumbers.contains(mainNumber),
            "policy=\(OwnWindowCapture.numbers(in: [mainWindow]).sorted()) "
                + "app=\(OwnWindowCapture.capturableWindowNumbers.sorted()) "
                + "window=\(mainNumber)"
        )

        // 2. A real own window in front of it — an ordinary `NSPanel`, which is
        //    what every capture surface is. The pointer is inside both; the
        //    picker must reject the chrome and walk down to the main window.
        let chrome = NSPanel(
            contentRect: NSRect(x: 380, y: 300, width: 260, height: 180),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        chrome.isReleasedWhenClosed = false
        chrome.level = .floating
        chrome.backgroundColor = .systemOrange
        chrome.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 180))
        chrome.orderFrontRegardless()
        defer { chrome.orderOut(nil); chrome.close() }
        try? await Task.sleep(nanoseconds: 250_000_000)

        let chromeOutcome = ledger(
            "chrome",
            at: CGPoint(x: chrome.frame.midX, y: chrome.frame.midY),
            candidates: ownCandidates()
        )
        let chromeRow = chromeOutcome.rows.first { $0.windowNumber == chrome.windowNumber }
        check(
            "own-window: an own chrome window of another class is rejected as ownWindow",
            chromeOutcome.rows.contains { $0.windowNumber == chrome.windowNumber }
                && chromeRow?.reject == .ownWindow,
            "row=\(chromeRow.map { "\($0.windowNumber):\($0.reject?.rawValue ?? "SELECTED")" } ?? "absent") "
                + "rows=\(rowSummary(chromeOutcome))"
        )
        check(
            "own-window: the picker walks past the chrome to the main window",
            chromeOutcome.pick?.candidate.windowNumber == mainNumber,
            "pick=\(chromeOutcome.pick?.candidate.windowNumber ?? -1) main=\(mainNumber) "
                + "rows=\(rowSummary(chromeOutcome))"
        )
        check(
            "own-window: the chrome window is not in the capturable set",
            !OwnWindowCapture.capturableWindowNumbers.contains(chrome.windowNumber),
            "capturable=\(OwnWindowCapture.capturableWindowNumbers.sorted()) "
                + "chrome=\(chrome.windowNumber)"
        )

        // 3. Real pixels: the own main window is capturable end to end, at the
        //    same frame × scale a foreign window gets.
        if ScreenCapture.hasScreenRecordingPermission {
            do {
                let shot = try await ScreenCapture.captureWindow(CGWindowID(mainNumber))
                let expectedWidth = Int((mainWindow.frame.width * shot.scale).rounded())
                let expectedHeight = Int((mainWindow.frame.height * shot.scale).rounded())
                check(
                    "own-window: ScreenCaptureKit captures the app's own main window at frame × scale",
                    shot.image.width == expectedWidth && shot.image.height == expectedHeight,
                    "pixels=\(shot.image.width)×\(shot.image.height) "
                        + "expected=\(expectedWidth)×\(expectedHeight) "
                        + "scale=\(shot.scale)"
                )
            } catch {
                check(
                    "own-window: ScreenCaptureKit captures the app's own main window at frame × scale",
                    false,
                    "error=\(error.localizedDescription)"
                )
            }
        } else {
            print("[own-window] SKIP own-window pixels: no screen-recording permission")
        }

        // 4. The history panel (⌥⌘V): a real `ClipboardPanel`, the class and
        //    level the production panel uses.
        let clipboardPanel = ClipboardPanel(
            contentRect: NSRect(x: 640, y: 300, width: 420, height: 560),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        clipboardPanel.isReleasedWhenClosed = false
        clipboardPanel.isFloatingPanel = true
        clipboardPanel.level = .floating
        clipboardPanel.hidesOnDeactivate = false
        clipboardPanel.becomesKeyOnlyIfNeeded = false
        clipboardPanel.isOpaque = false
        clipboardPanel.backgroundColor = .clear
        clipboardPanel.hasShadow = true
        clipboardPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        clipboardPanel.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 560))
        clipboardPanel.orderFrontRegardless()
        defer { clipboardPanel.orderOut(nil); clipboardPanel.close() }
        try? await Task.sleep(nanoseconds: 250_000_000)

        let panelOutcome = ledger(
            "panel",
            at: CGPoint(x: clipboardPanel.frame.midX, y: clipboardPanel.frame.midY),
            candidates: ownCandidates()
        )
        let panelRow = panelOutcome.rows.first { $0.windowNumber == clipboardPanel.windowNumber }
        check(
            "own-window: the history panel's window class is rejected as ownWindow",
            panelRow?.reject == .ownWindow
                && panelOutcome.pick?.candidate.windowNumber != clipboardPanel.windowNumber,
            "row=\(panelRow.map { "\($0.windowNumber):\($0.reject?.rawValue ?? "SELECTED")" } ?? "absent") "
                + "rows=\(rowSummary(panelOutcome))"
        )

        // 5. A pin (钉图): a real `PinnedImagePanel` with the production level
        //    and collection behaviour.
        let pinPanel = PinnedImagePanel(
            contentRect: NSRect(x: 700, y: 320, width: 240, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        pinPanel.isReleasedWhenClosed = false
        pinPanel.level = .floating
        pinPanel.isOpaque = false
        pinPanel.backgroundColor = .clear
        pinPanel.hasShadow = true
        pinPanel.isMovableByWindowBackground = false
        pinPanel.isMovable = true
        pinPanel.hidesOnDeactivate = false
        pinPanel.animationBehavior = .none
        pinPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let pinContent = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 160))
        pinContent.wantsLayer = true
        pinContent.layer?.backgroundColor = NSColor.systemTeal.cgColor
        pinPanel.contentView = pinContent
        pinPanel.orderFrontRegardless()
        defer { pinPanel.orderOut(nil); pinPanel.close() }
        try? await Task.sleep(nanoseconds: 250_000_000)

        let pinOutcome = ledger(
            "pin",
            at: CGPoint(x: pinPanel.frame.midX, y: pinPanel.frame.midY),
            candidates: ownCandidates()
        )
        let pinRow = pinOutcome.rows.first { $0.windowNumber == pinPanel.windowNumber }
        check(
            "own-window: the pin window class is rejected as ownWindow",
            pinRow?.reject == .ownWindow
                && pinOutcome.pick?.candidate.windowNumber != pinPanel.windowNumber,
            "row=\(pinRow.map { "\($0.windowNumber):\($0.reject?.rawValue ?? "SELECTED")" } ?? "absent") "
                + "rows=\(rowSummary(pinOutcome))"
        )

        // 6. The region overlay (⌃⌥⌘A): the production controller's real
        //    full-screen panels, above everything. The picker at the main
        //    window's centre must walk past them and never select one.
        //
        //    Bring our own windows forward first: another app's window in front
        //    of the main window is not what this test is about, and the ledger
        //    from the live stack is kept for the overlay rows only.
        NSApp.activate()
        mainWindow.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 150_000_000)
        let overlay = CaptureOverlayController(
            mode: .region,
            prefilledSelection: nil,
            showCrosshair: false
        )
        if let screen = NSScreen.main {
            overlay.presentPanelsForTesting(on: screen)
        }
        try? await Task.sleep(nanoseconds: 350_000_000)
        let overlayNumbers = NSApp.windows
            .compactMap { $0 as? CaptureOverlayPanel }
            .filter(\.isVisible)
            .map(\.windowNumber)
        check(
            "own-window: the overlay presents real panels",
            !overlayNumbers.isEmpty,
            "panels=\(overlayNumbers.sorted())"
        )
        check(
            "own-window: no overlay panel is capturable",
            OwnWindowCapture.capturableWindowNumbers.isDisjoint(with: overlayNumbers),
            "capturable=\(OwnWindowCapture.capturableWindowNumbers.sorted()) "
                + "overlay=\(overlayNumbers.sorted())"
        )

        let overlayOutcome = ledger(
            "overlay",
            at: CGPoint(x: mainWindow.frame.midX, y: mainWindow.frame.midY)
        )
        check(
            "own-window: the overlay cannot become its own capture target",
            overlayOutcome.pick.map { !overlayNumbers.contains($0.candidate.windowNumber) } ?? true,
            "pick=\(overlayOutcome.pick?.candidate.windowNumber ?? -1) "
                + "overlay=\(overlayNumbers.sorted())"
        )
        check(
            "own-window: every overlay panel is rejected with ownWindow",
            overlayNumbers.allSatisfy { number in
                overlayOutcome.rows.contains {
                    $0.windowNumber == number && $0.reject == .ownWindow
                }
            },
            "rows=\(rowSummary(overlayOutcome))"
        )
        let overlayOwnOutcome = ledger(
            "overlay/own",
            at: CGPoint(x: mainWindow.frame.midX, y: mainWindow.frame.midY),
            candidates: ownCandidates()
        )
        check(
            "own-window: the overlay still lets the main window underneath through",
            overlayOwnOutcome.pick?.candidate.windowNumber == mainNumber,
            "pick=\(overlayOwnOutcome.pick?.candidate.windowNumber ?? -1) main=\(mainNumber) "
                + "rows=\(rowSummary(overlayOwnOutcome))"
        )

        overlay.close()
        try? await Task.sleep(nanoseconds: 200_000_000)
        check(
            "own-window: closing the overlay removes its panels",
            !overlay.isPresenting,
            "presenting=\(overlay.isPresenting)"
        )
    }

    /// Settings / hotkey / menu coverage for the instant entries. Split out so
    /// it still runs when the pixel section is skipped for permissions.
    private static func runInstantWiringChecks() {
        print("[instant] --- wiring ---")

        let suiteName = "UnseenInstantWiring-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            check("wiring: create isolated defaults for instant checks", false)
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)

        check(
            "wiring: instant window hotkey ships bound (⌥S) with the switch on",
            settings.instantWindowHotKeyEnabled
                && settings.instantWindowHotKeyConfiguration == .instantWindow
                && settings.instantWindowHotKeyConfiguration.isBound,
            "display=\(settings.instantWindowHotKeyConfiguration.displayString) "
                + "bound=\(settings.instantWindowHotKeyConfiguration.isBound)"
        )
        check(
            "wiring: instant full-screen hotkey ships bound (⌥D) with the switch on",
            settings.instantFullScreenHotKeyEnabled
                && settings.instantFullScreenHotKeyConfiguration == .instantFullScreen
                && settings.instantFullScreenHotKeyConfiguration.isBound,
            "display=\(settings.instantFullScreenHotKeyConfiguration.displayString) "
                + "bound=\(settings.instantFullScreenHotKeyConfiguration.isBound)"
        )
        check(
            "wiring: instant action ids are 9 / 10",
            HotKeyAction.instantWindow.rawValue == 9
                && HotKeyAction.instantFullScreen.rawValue == 10,
            "ids=\(HotKeyAction.instantWindow.rawValue)/"
                + "\(HotKeyAction.instantFullScreen.rawValue)"
        )

        let exported = AppSettings.exportedKeys
        check(
            "wiring: instant preferences are in backup/restore",
            exported.isSuperset(of: [
                AppSettings.Key.instantWindowHotKeyEnabled,
                AppSettings.Key.instantWindowHotKeyKeyCode,
                AppSettings.Key.instantWindowHotKeyModifiers,
                AppSettings.Key.instantFullScreenHotKeyEnabled,
                AppSettings.Key.instantFullScreenHotKeyKeyCode,
                AppSettings.Key.instantFullScreenHotKeyModifiers,
                AppSettings.Key.instantCaptureSound,
                AppSettings.Key.instantCaptureVisualCue,
                AppSettings.Key.instantCaptureAlsoSave
            ])
        )
        check(
            "wiring: instant feedback defaults are sound on / cue on / save off",
            settings.instantCaptureSound
                && settings.instantCaptureVisualCue
                && !settings.instantCaptureAlsoSave,
            "sound=\(settings.instantCaptureSound) cue=\(settings.instantCaptureVisualCue) "
                + "save=\(settings.instantCaptureAlsoSave)"
        )

        // Edit, persist, then reset through the same path the settings page uses.
        settings.instantWindowHotKeyKeyCode = Int(kVK_ANSI_9)
        settings.instantFullScreenHotKeyEnabled = false
        settings.instantCaptureSound = false
        settings.instantCaptureVisualCue = false
        settings.instantCaptureAlsoSave = true
        check(
            "wiring: edited instant preferences reach UserDefaults",
            settings.instantWindowHotKeyKeyCode == Int(kVK_ANSI_9)
                && !settings.instantFullScreenHotKeyEnabled
                && !settings.instantCaptureSound
                && !settings.instantCaptureVisualCue
                && settings.instantCaptureAlsoSave
        )
        settings.resetAll()
        check(
            "wiring: resetAll restores every instant default",
            settings.instantWindowHotKeyEnabled
                && settings.instantWindowHotKeyConfiguration == .instantWindow
                && settings.instantFullScreenHotKeyEnabled
                && settings.instantFullScreenHotKeyConfiguration == .instantFullScreen
                && settings.instantCaptureSound
                && settings.instantCaptureVisualCue
                && !settings.instantCaptureAlsoSave,
            "window=\(settings.instantWindowHotKeyConfiguration.displayString) "
                + "full=\(settings.instantFullScreenHotKeyConfiguration.displayString) "
                + "sound=\(settings.instantCaptureSound) "
                + "cue=\(settings.instantCaptureVisualCue) "
                + "save=\(settings.instantCaptureAlsoSave)"
        )

        // Real Carbon registration, exactly what AppDelegate does at launch.
        let center = GlobalHotKeyCenter.shared
        let windowRegistered = center.set(
            .instantWindow,
            configuration: .instantWindow
        ) {}
        let fullRegistered = center.set(
            .instantFullScreen,
            configuration: .instantFullScreen
        ) {}
        check(
            "wiring: the two instant hotkeys register with Carbon",
            windowRegistered && fullRegistered
                && center.lastErrors[.instantWindow] == nil
                && center.lastErrors[.instantFullScreen] == nil,
            "window=\(windowRegistered) full=\(fullRegistered) errors=\(center.lastErrors)"
        )
        center.unregister(.instantWindow)
        center.unregister(.instantFullScreen)

        // Menu: two new instant items and no app-local key equivalents that
        // could double-fire with the globals. The adjustable window variant is
        // gone on purpose: window capture only exists as the instant path.
        let menuDelegate = AppDelegate()
        AppMenuBuilder.install(appName: "Unseen Self Test", delegate: menuDelegate)
        let captureMenu = NSApp.mainMenu?.items.first {
            $0.title == "截图" || $0.submenu?.title == "截图"
        }?.submenu
        let titles = captureMenu?.items.map(\.title) ?? []
        for title in [
            "即时窗口", "即时全屏"
        ] {
            check(
                "wiring: menu「截图」contains \(title)",
                titles.contains(title),
                "titles=\(titles.joined(separator: " | "))"
            )
        }
        check(
            "wiring: menu「截图」no longer offers an adjustable window mode",
            !titles.contains("窗口截图（可调整）"),
            "titles=\(titles.joined(separator: " | "))"
        )
        let instantItems = captureMenu?.items.filter {
            ["即时窗口", "即时全屏"].contains($0.title)
        } ?? []
        check(
            "wiring: instant menu items carry no local key equivalents",
            instantItems.count == 2 && instantItems.allSatisfy { $0.keyEquivalent.isEmpty },
            "items=\(instantItems.map { "\($0.title)[\($0.keyEquivalent)]" }.joined(separator: " | "))"
        )
        check(
            "wiring: last-region feature is gone",
            !titles.contains { $0.contains("上次区域") },
            "titles=\(titles.joined(separator: " | "))"
        )
    }

    private static func describe(_ items: [RecognizedItem]) -> String {
        items.map {
            "\($0.kind):\"\($0.text)\"@\(String(format: "%.2f", $0.confidence))"
        }.joined(separator: " | ")
    }

    private static func makeSolidImage(
        color: NSColor,
        width: Int,
        height: Int
    ) -> CGImage? {        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func makeTextImage(
        text: String,
        pixelWidth: Int,
        pixelHeight: Int,
        fontSize: CGFloat,
        fontName: String
    ) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.setShouldAntialias(true)

        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                NSColor.black.cgColor
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.textPosition = CGPoint(
            x: (CGFloat(pixelWidth) - bounds.width) / 2 - bounds.minX,
            y: (CGFloat(pixelHeight) - bounds.height) / 2 - bounds.minY
        )
        CTLineDraw(line, context)
        return context.makeImage()
    }

    /// A QR code on a white field with a quiet zone, generated entirely by
    /// CoreImage so the test needs no fixture file.
    private static func makeQRCodeImage(payload: String, side: Int) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        let extent = output.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scale = CGFloat(side) * 0.75 / max(extent.width, extent.height)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))

        let ciContext = CIContext(options: nil)
        guard let qr = ciContext.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        context.interpolationQuality = .none
        let inset = CGFloat(side) / 8
        context.draw(qr, in: CGRect(
            x: inset,
            y: inset,
            width: CGFloat(side) - inset * 2,
            height: CGFloat(side) - inset * 2
        ))
        return context.makeImage()
    }

    /// QR plus text on one white canvas, to prove both requests run and that
    /// the barcode still sorts first.
    private static func makeMixedRecognitionImage(payload: String, text: String) -> CGImage? {
        guard let qr = makeQRCodeImage(payload: payload, side: 520),
              let textImage = makeTextImage(
                  text: text,
                  pixelWidth: 700,
                  pixelHeight: 300,
                  fontSize: 110,
                  fontName: "Helvetica-Bold"
              ) else { return nil }
        guard let context = CGContext(
            data: nil,
            width: 1400,
            height: 600,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 1400, height: 600))
        context.draw(textImage, in: CGRect(x: 50, y: 150, width: 700, height: 300))
        context.draw(qr, in: CGRect(x: 820, y: 40, width: 520, height: 520))
        return context.makeImage()
    }

    private static func writePNG(_ image: CGImage, to url: URL) {
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            return
        }
        try? data.write(to: url)
    }

    /// `sips -g pixelWidth -g pixelHeight` parsed into numbers. Uses the real
    /// system tool, exactly like the acceptance criteria asked for.
    private static func sipsDimensions(_ url: URL) -> (width: Int?, height: Int?, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        process.arguments = ["-g", "pixelWidth", "-g", "pixelHeight", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (nil, nil, "launch failed: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)

        func value(_ key: String) -> Int? {
            for line in output.split(separator: "\n") where line.contains(key) {
                guard let raw = line.split(separator: ":").last else { continue }
                if let number = Int(raw.trimmingCharacters(in: .whitespaces)) {
                    return number
                }
            }
            return nil
        }
        return (value("pixelWidth"), value("pixelHeight"), output)
    }

    // MARK: - S. Recording (state machine, naming, real SCStream sessions)

    /// Pure transition/clock/naming checks. These run everywhere, including on
    /// machines where TCC refuses screen recording.
    // MARK: - Region recording: the screenshot selector, an explicit start

    /// The recording hotkey opens the same region overlay a screenshot uses,
    /// and the only way out of it into a stream is an explicit confirm:
    /// Return, the toolbar's 开始录制, or a double-click. Drawing a box must
    /// never start a recording on its own (the old auto-confirm behaviour), a
    /// window click must stay a selection until confirmed, and Esc must leave
    /// no file behind.
    private static func runRecordingSelectionTests(into directory: URL) {
        print("[record-ui] --- region recording selector ---")
        let bounds = CGRect(origin: .zero, size: canvasSize)
        let box = CGRect(x: 300, y: 260, width: 800, height: 600)
        let overlay = CaptureOverlayView(
            frame: bounds,
            mode: .region,
            prefilledSelection: nil,
            showCrosshair: false,
            rendersOffscreen: true,
            recordingMode: true
        )
        var confirmedRect: CGRect?
        var confirmedAction: CaptureToolbarAction?
        var cancelCount = 0
        overlay.onConfirm = { rect, _, action in
            confirmedRect = rect
            confirmedAction = action
        }
        overlay.onCancel = { cancelCount += 1 }

        // 1. A finished drag is still only a selection.
        drag(
            overlay,
            from: CGPoint(x: box.minX, y: box.minY),
            to: CGPoint(x: box.maxX, y: box.maxY)
        )
        check(
            "record-ui: drawing a box alone starts nothing",
            confirmedAction == nil && cancelCount == 0,
            "action=\(confirmedAction?.rawValue ?? "nil") cancels=\(cancelCount)"
        )
        check(
            "record-ui: the recorded source is the drawn box",
            sameRect(overlay.selectionRectForTesting, box),
            "selection=\(format(overlay.selectionRectForTesting)) expected=\(format(box))"
        )

        // 2. The bar is the recording bar: 开始录制 and 取消, no drawing tools.
        overlay.revealToolbarForTesting()
        overlay.layoutSubtreeIfNeeded()
        let actionFrames = overlay.toolbarButtonFramesForTesting()
        check(
            "record-ui: the bar offers exactly 开始录制 and 取消",
            actionFrames.map(\.action) == [.record, .cancel],
            "actions=\(actionFrames.map(\.action.rawValue))"
        )
        check(
            "record-ui: a recording bar has no annotation tools or history",
            overlay.visibleToolCountForTesting == 0
                && overlay.visibleHistoryCountForTesting == 0,
            "tools=\(overlay.visibleToolCountForTesting) "
                + "history=\(overlay.visibleHistoryCountForTesting)"
        )
        check(
            "record-ui: the record action is labelled and glyphed for recording",
            CaptureToolbarAction.record.label == "开始录制"
                && CaptureToolbarAction.record.symbol == "record.circle",
            "label=\(CaptureToolbarAction.record.label) "
                + "symbol=\(CaptureToolbarAction.record.symbol)"
        )
        if let recordFrame = actionFrames.first(where: { $0.action == .record })?.frame {
            let hit = overlay.hitTest(
                CGPoint(x: recordFrame.midX, y: recordFrame.midY)
            )
            check(
                "record-ui: 开始录制 receives its own clicks",
                (hit as? CaptureToolbarButton)?.toolbarAction == .record,
                "hit=\(String(describing: hit.map { type(of: $0) }))"
            )
        } else {
            check("record-ui: 开始录制 has a frame", false)
        }

        // 3. The button and Return both confirm the same rectangle.
        overlay.performToolbarActionForTesting(.record)
        check(
            "record-ui: 开始录制 confirms the box with .record",
            confirmedAction == .record && confirmedRect.map { sameRect($0, box) } == true,
            "action=\(confirmedAction?.rawValue ?? "nil") "
                + "rect=\(confirmedRect.map(format) ?? "-")"
        )
        confirmedRect = nil
        confirmedAction = nil
        overlay.keyDown(with: keyEvent(keyCode: 36, modifiers: [], characters: "\r"))
        check(
            "record-ui: Return confirms the same box with .record",
            confirmedAction == .record && confirmedRect.map { sameRect($0, box) } == true,
            "action=\(confirmedAction?.rawValue ?? "nil") "
                + "rect=\(confirmedRect.map(format) ?? "-")"
        )

        // 4. Esc is a cancel with no recording action.
        confirmedRect = nil
        confirmedAction = nil
        let cancelsBeforeEsc = cancelCount
        overlay.keyDown(with: keyEvent(keyCode: 53, modifiers: [], characters: "\u{1b}"))
        check(
            "record-ui: Esc cancels without a .record action",
            cancelCount == cancelsBeforeEsc + 1 && confirmedAction == nil,
            "cancels=\(cancelCount) action=\(confirmedAction?.rawValue ?? "nil")"
        )

        // 5. A window is a rectangle source: one click arms it, a second click
        //    cannot start a stream, and Return records exactly the window rect.
        let windowOverlay = CaptureOverlayView(
            frame: bounds,
            mode: .region,
            prefilledSelection: nil,
            showCrosshair: false,
            rendersOffscreen: true,
            recordingMode: true
        )
        var windowRect: CGRect?
        var windowAction: CaptureToolbarAction?
        windowOverlay.onConfirm = { rect, _, action in
            windowRect = rect
            windowAction = action
        }
        let fixture = CGRect(x: 360, y: 300, width: 600, height: 400)
        windowOverlay.setWindowPickCandidatesForTesting([
            WindowCandidate(
                windowNumber: 8801,
                bounds: fixture,
                layer: 0,
                ownerPID: 8801,
                ownerName: "RecordFixture",
                windowName: "RecordFixture",
                isOwnedBySelf: false
            )
        ])
        let fixturePoint = CGPoint(x: fixture.midX, y: fixture.midY)
        click(windowOverlay, at: fixturePoint)
        check(
            "record-ui: one click selects a window for recording",
            windowOverlay.armedWindowIDForTesting == 8801,
            "armed=\(windowOverlay.armedWindowIDForTesting.map(String.init) ?? "-")"
        )
        click(windowOverlay, at: fixturePoint)
        check(
            "record-ui: a second click on the selected window does not start recording",
            windowOverlay.armedWindowIDForTesting == 8801
                && windowAction == nil
                && windowRect == nil,
            "armed=\(windowOverlay.armedWindowIDForTesting.map(String.init) ?? "-") "
                + "action=\(windowAction?.rawValue ?? "nil")"
        )
        windowOverlay.keyDown(with: keyEvent(keyCode: 36, modifiers: [], characters: "\r"))
        check(
            "record-ui: Return records the selected window rectangle",
            windowAction == .record && windowRect.map { sameRect($0, fixture) } == true,
            "action=\(windowAction?.rawValue ?? "nil") "
                + "rect=\(windowRect.map(format) ?? "-") expected=\(format(fixture))"
        )

        // 6. Evidence render of the selector itself.
        let renderCanvas = TestCanvasView(frame: bounds)
        let renderOverlay = CaptureOverlayView(
            frame: bounds,
            mode: .region,
            prefilledSelection: nil,
            showCrosshair: false,
            rendersOffscreen: true,
            recordingMode: true
        )
        renderCanvas.addSubview(renderOverlay)
        renderOverlay.applySelectionForTesting(box)
        renderOverlay.revealToolbarForTesting()
        renderOverlay.layoutSubtreeIfNeeded()
        if let image = renderImage(of: renderCanvas) {
            writePNG(
                image,
                to: directory.appendingPathComponent("70-recording-region-selector.png")
            )
            print("[record-ui] wrote 70-recording-region-selector.png")
        }

        // 7. 录制中: the confirmed overlay does NOT close. It is the recording
        //    UI, and it must still be the screenshot selector — veil hole,
        //    border, eight handles, size chip, crosshair — with only the
        //    capture toolbar swapped for the recording HUD.
        let live = CaptureOverlayView(
            frame: bounds,
            mode: .region,
            prefilledSelection: nil,
            showCrosshair: true,
            rendersOffscreen: true,
            recordingMode: true
        )
        var liveConfirms = 0
        var liveCancels = 0
        live.onConfirm = { _, _, action in
            if action == .record { liveConfirms += 1 }
        }
        live.onCancel = { liveCancels += 1 }
        live.applySelectionForTesting(box)
        live.revealToolbarForTesting()
        live.layoutSubtreeIfNeeded()
        let toolbarFrameBefore = live.toolbarFrameForTesting
        let indicatorFrameBefore = live.indicatorFrameForTesting
        let sizeTextBefore = live.sizeIndicatorTextForTesting
        check(
            "record-ui: before 录制 the selector shows its capture toolbar",
            live.isToolbarVisibleForTesting && live.isIndicatorVisibleForTesting,
            "toolbar=\(live.isToolbarVisibleForTesting) chip=\(live.isIndicatorVisibleForTesting)"
        )

        live.beginRecordingUIForTesting()
        check(
            "record-ui: 录制中 keeps the overlay open (no confirm, no cancel)",
            liveConfirms == 0 && liveCancels == 0 && live.isRecordingLiveForTesting,
            "confirms=\(liveConfirms) cancels=\(liveCancels) live=\(live.isRecordingLiveForTesting)"
        )
        check(
            "record-ui: 录制中 keeps the selection exactly as captured",
            sameRect(live.selectionRectForTesting, box),
            "selection=\(format(live.selectionRectForTesting)) expected=\(format(box))"
        )
        check(
            "record-ui: 录制中 keeps the dimming mask over everything but the selection",
            sameRect(live.dimmingSelectionRectForTesting, box),
            "mask hole=\(format(live.dimmingSelectionRectForTesting))"
        )
        check(
            "record-ui: 录制中 keeps the selection border and its eight handles",
            live.isSelectionBorderVisibleForTesting
                && BorderHandle.allCases.count == 8,
            "border=\(live.isSelectionBorderVisibleForTesting) "
                + "handles=\(BorderHandle.allCases.count)"
        )
        check(
            "record-ui: 录制中 keeps the size chip, still reading the captured size",
            live.isIndicatorVisibleForTesting
                && live.sizeIndicatorTextForTesting == sizeTextBefore
                && !live.sizeIndicatorTextForTesting.isEmpty,
            "text=\(live.sizeIndicatorTextForTesting) before=\(sizeTextBefore)"
        )
        check(
            "record-ui: 录制中 swaps the capture toolbar for recording controls",
            !live.isToolbarVisibleForTesting,
            "toolbarVisible=\(live.isToolbarVisibleForTesting)"
        )
        check(
            "record-ui: the recording HUD occupies the toolbar's exact place",
            sameRect(live.recordingControlFrameForTesting, toolbarFrameBefore),
            "hud=\(format(live.recordingControlFrameForTesting)) "
                + "toolbar=\(format(toolbarFrameBefore))"
        )
        check(
            "record-ui: the size chip does not jump when the toolbar is replaced",
            sameRect(live.indicatorFrameForTesting, indicatorFrameBefore),
            "chip=\(format(live.indicatorFrameForTesting)) "
                + "before=\(format(indicatorFrameBefore))"
        )
        check(
            "record-ui: 录制中 keeps the crosshair when the user has it enabled",
            !live.isCrosshairHiddenForTesting,
            "hidden=\(live.isCrosshairHiddenForTesting)"
        )
        // 十字线在录制期间冻结，和区域截图完全一致。A box that never went
        // through a drag has no release point, so it is pinned to the corner of
        // the committed rectangle nearest the last known pointer — the default
        // corner when there is no pointer yet.
        let prefilledCross = live.crosshairPointForTesting
        check(
            "record-ui: 录制开始把预填选择的十字线钉在一个角上",
            live.isCrosshairFrozenForTesting
                && prefilledCross == CGPoint(x: box.maxX, y: box.maxY),
            "frozen=\(live.isCrosshairFrozenForTesting) "
                + "point=\(prefilledCross.map(NSStringFromPoint) ?? "nil")"
        )
        live.mouseMoved(with: event(.mouseMoved, at: CGPoint(x: 777, y: 333)))
        check(
            "record-ui: 录制中 mouseMoved 不改动十字线位置",
            live.crosshairPointForTesting == prefilledCross,
            "point=\(live.crosshairPointForTesting.map(NSStringFromPoint) ?? "nil") "
                + "before=\(prefilledCross.map(NSStringFromPoint) ?? "nil")"
        )
        check(
            "record-ui: 录制中 is not an annotation surface",
            live.isAnnotationCanvasHiddenForTesting,
            "canvasHidden=\(live.isAnnotationCanvasHiddenForTesting)"
        )
        check(
            "record-ui: the loupe is gone once the box is locked",
            live.isLoupeHiddenForTesting,
            "loupeHidden=\(live.isLoupeHiddenForTesting)"
        )

        // The rectangle is the stream's source rect: synthetic gestures and
        // keys must not move it or dismiss the UI.
        drag(
            live,
            from: CGPoint(x: box.midX, y: box.midY),
            to: CGPoint(x: box.midX + 120, y: box.midY + 80)
        )
        check(
            "record-ui: a live recording cannot be dragged into a new box",
            sameRect(live.selectionRectForTesting, box),
            "selection=\(format(live.selectionRectForTesting))"
        )
        live.keyDown(with: keyEvent(keyCode: 53, modifiers: [], characters: "\u{1b}"))
        check(
            "record-ui: Esc cannot dismiss the recording UI (停止 is the exit)",
            liveCancels == 0 && live.isRecordingLiveForTesting,
            "cancels=\(liveCancels) live=\(live.isRecordingLiveForTesting)"
        )

        // 7b. 回归: e524f12 kept a 33 ms `NSEvent.mouseLocation` poller alive
        //     during 录制中 so the crosshair could keep following the pointer.
        //     That is the opposite of the screenshot, where a committed box
        //     freezes its cross on release (0da7287 / b635b64). The poller is
        //     gone: the cross stays on the release corner, and every pointer
        //     path a click-through panel could still be handed is a no-op.
        let frozen = CaptureOverlayView(
            frame: bounds,
            mode: .region,
            prefilledSelection: nil,
            showCrosshair: true,
            rendersOffscreen: true,
            recordingMode: true
        )
        var frozenConfirms = 0
        frozen.onConfirm = { _, _, action in
            if action == .record { frozenConfirms += 1 }
        }
        drag(
            frozen,
            from: CGPoint(x: 320, y: 240),
            to: CGPoint(x: 840, y: 700)
        )
        let releaseCross = frozen.crosshairPointForTesting
        let releasedRect = frozen.selectionRectForTesting
        check(
            "record-ui: 松手即冻结十字线 (screenshot parity)",
            frozen.isCrosshairFrozenForTesting
                && releaseCross.map {
                    ($0.x == releasedRect.minX || $0.x == releasedRect.maxX)
                        && ($0.y == releasedRect.minY || $0.y == releasedRect.maxY)
                } == true,
            "frozen=\(frozen.isCrosshairFrozenForTesting) "
                + "point=\(releaseCross.map(NSStringFromPoint) ?? "nil") "
                + "rect=\(format(releasedRect))"
        )
        // The user reaches for 开始录制: a toolbar button click never touches
        // the box, and the confirm turns the same selector into the recording
        // UI (the controller calls `beginRecordingUI` from `onConfirm`).
        frozen.performToolbarActionForTesting(.record)
        frozen.beginRecordingUIForTesting()
        check(
            "record-ui: 录制开始后十字线仍在松手时的位置",
            frozenConfirms == 1
                && frozen.isRecordingLiveForTesting
                && frozen.isCrosshairFrozenForTesting
                && frozen.crosshairPointForTesting == releaseCross,
            "confirms=\(frozenConfirms) live=\(frozen.isRecordingLiveForTesting) "
                + "point=\(frozen.crosshairPointForTesting.map(NSStringFromPoint) ?? "nil") "
                + "release=\(releaseCross.map(NSStringFromPoint) ?? "nil")"
        )
        // Every pointer path a click-through panel could still be handed —
        // plus the moving pointer the removed poller used to read.
        frozen.mouseMoved(with: event(.mouseMoved, at: CGPoint(x: 120, y: 900)))
        frozen.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 980, y: 120)))
        frozen.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 1010, y: 90)))
        frozen.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 1010, y: 90)))
        frozen.rightMouseDown(with: event(.rightMouseDown, at: CGPoint(x: 100, y: 100)))
        check(
            "record-ui: 录制中鼠标移动/拖拽/点击都不改动十字线",
            frozen.crosshairPointForTesting == releaseCross
                && frozen.isCrosshairFrozenForTesting
                && sameRect(frozen.selectionRectForTesting, releasedRect),
            "point=\(frozen.crosshairPointForTesting.map(NSStringFromPoint) ?? "nil") "
                + "release=\(releaseCross.map(NSStringFromPoint) ?? "nil") "
                + "rect=\(format(frozen.selectionRectForTesting))"
        )

        // Evidence render: the recording-state selector, with the HUD composited
        // on the toolbar frame exactly as the controller places it. The box is
        // produced by a real drag, so the crosshair is frozen exactly where the
        // screenshot overlay leaves it — on the release corner.
        let recordCanvas = TestCanvasView(frame: bounds)
        let recordOverlay = CaptureOverlayView(
            frame: bounds,
            mode: .region,
            prefilledSelection: nil,
            showCrosshair: true,
            rendersOffscreen: true,
            recordingMode: true
        )
        recordCanvas.addSubview(recordOverlay)
        drag(
            recordOverlay,
            from: CGPoint(x: box.minX, y: box.minY),
            to: CGPoint(x: box.maxX, y: box.maxY)
        )
        recordOverlay.beginRecordingUIForTesting()
        // The mouse keeps moving after the release and after 开始录制; nothing
        // follows it. This is the state the evidence shots below show.
        let pointerAfterStart = CGPoint(x: 1270, y: 150)
        recordOverlay.mouseMoved(with: event(.mouseMoved, at: pointerAfterStart))
        let hudView = RecordingIndicatorView(
            frame: CGRect(origin: .zero, size: RecordingIndicatorPlacement.panelSize)
        )
        hudView.update(state: .recording, elapsedText: "00:07")
        hudView.frame = CGRect(
            origin: CaptureOverlayController.recordingHUDOrigin(
                controlFrame: recordOverlay.recordingControlFrameForTesting,
                screenFrame: bounds
            ),
            size: RecordingIndicatorPlacement.panelSize
        )
        recordCanvas.addSubview(hudView)
        recordCanvas.layoutSubtreeIfNeeded()
        if let image = renderImage(of: recordCanvas) {
            writePNG(
                image,
                to: directory.appendingPathComponent("73-recording-state.png")
            )
            print("[record-ui] wrote 73-recording-state.png (\(image.width)×\(image.height) px)")
        }
        // 82: the same frozen state with the pointer drawn where the mouse
        // actually is, far from the cross — the "selection fixed, mouse free"
        // pair the recording UI has to read as.
        let pointerView = TestPointerView(frame: bounds)
        pointerView.tip = pointerAfterStart
        recordCanvas.addSubview(pointerView)
        if let image = renderImage(of: recordCanvas) {
            writePNG(
                image,
                to: directory.appendingPathComponent("82-recording-crosshair-frozen.png")
            )
            print(
                "[record-ui] wrote 82-recording-crosshair-frozen.png "
                    + "(\(image.width)×\(image.height) px, cross="
                    + "\(recordOverlay.crosshairPointForTesting.map(NSStringFromPoint) ?? "nil"), "
                    + "pointer=\(NSStringFromPoint(pointerAfterStart)))"
            )
        }
    }

    private static func runRecordingStateMachineTests() {
        var machine = RecordingStateMachine()
        check("recording: initial state is idle", machine.state == .idle)
        check("recording: stop before start is rejected", machine.stop(at: 0) == false && machine.state == .idle)
        check("recording: pause before start is rejected", machine.pause(at: 0) == false && machine.state == .idle)
        check("recording: idle → recording", machine.start(at: 10) && machine.state == .recording)
        check("recording: second start is rejected", machine.start(at: 11) == false && machine.state == .recording)
        check("recording: recording → paused", machine.pause(at: 11.5) && machine.state == .paused)
        check("recording: pause twice is rejected", machine.pause(at: 12) == false && machine.state == .paused)
        check(
            "recording: elapsed freezes while paused",
            approx(machine.elapsed(at: 20), 1.5),
            "elapsed=\(machine.elapsed(at: 20))"
        )
        check("recording: paused → recording", machine.resume(at: 22.7) && machine.state == .recording)
        check("recording: resume while running is rejected", machine.resume(at: 23) == false)
        check(
            "recording: elapsed excludes the 1.2s pause",
            approx(machine.elapsed(at: 24.2), 3.0),
            "elapsed=\(machine.elapsed(at: 24.2))"
        )
        check("recording: recording → finished", machine.stop(at: 24.2) && machine.state == .finished)
        check(
            "recording: lastElapsed excludes the pause",
            approx(machine.lastElapsed, 3.0),
            "lastElapsed=\(machine.lastElapsed)"
        )
        check("recording: repeated stop is a no-op", machine.stop(at: 30) == false && machine.state == .finished)
        check("recording: finished → recording is allowed", machine.start(at: 40) && machine.state == .recording)
        check(
            "recording: restart resets the clock",
            approx(machine.elapsed(at: 40.5), 0.5),
            "elapsed=\(machine.elapsed(at: 40.5))"
        )

        var pausedStop = RecordingStateMachine()
        _ = pausedStop.start(at: 0)
        _ = pausedStop.pause(at: 1)
        _ = pausedStop.stop(at: 5)
        check(
            "recording: stopping while paused keeps only active time",
            approx(pausedStop.lastElapsed, 1.0),
            "lastElapsed=\(pausedStop.lastElapsed)"
        )

        var timeline = RecordingTimeline()
        timeline.begin(at: 100)
        _ = timeline.pause(at: 101.5)
        _ = timeline.resume(at: 103.7)
        check(
            "recording: timeline ignores the 2.2s pause",
            approx(timeline.elapsed(at: 104.2), 2.0),
            "elapsed=\(timeline.elapsed(at: 104.2))"
        )

        check(
            "recording: frame rate is clamped to 10…60",
            RecordingConfiguration(frameRate: 1).effectiveFrameRate == 10
                && RecordingConfiguration(frameRate: 999).effectiveFrameRate == 60
        )
        check(
            "recording: bitrate is clamped to 1…100 Mbps",
            RecordingConfiguration(bitrate: 1).effectiveBitrate == 1_000_000
                && RecordingConfiguration(bitrate: 999_000_000).effectiveBitrate == 100_000_000
        )
        check(
            "recording: bitrate labels",
            RecordingConfiguration.bitrateLabel(4_000_000) == "4 Mbps"
                && RecordingConfiguration.bitrateLabel(12_000_000) == "12 Mbps"
        )
        check("recording: format picker offers MP4 and MOV",
              RecordingFormat.allCases == [.mp4, .mov]
                && RecordingFormat.mp4.title.contains("H.264")
                && RecordingFormat.mp4.fileExtension == "mp4")

        let stamp = Date(timeIntervalSince1970: 0)
        let name = RecordingNaming.fileName(date: stamp, format: .mp4)
        check(
            "recording: file name follows 录屏-yyyyMMdd-HHmmss",
            name.hasPrefix("录屏-") && name.hasSuffix(".mp4") && name.count == "录屏-19700101-080000.mp4".count,
            "name=\(name)"
        )
        let directory = URL(fileURLWithPath: "/tmp/unseen-recording-naming", isDirectory: true)
        let first = RecordingNaming.url(in: directory, date: stamp, format: .mp4) { _ in false }
        let second = RecordingNaming.url(in: directory, date: stamp, format: .mp4) {
            $0.lastPathComponent == first.lastPathComponent
        }
        check(
            "recording: a taken name gets a -2 suffix",
            first.lastPathComponent != second.lastPathComponent
                && second.lastPathComponent.contains("-2"),
            "second=\(second.lastPathComponent)"
        )

        check(
            "recording: elapsed text is MM:SS / H:MM:SS",
            ScreenRecorder.elapsedText(2.5) == "00:02"
                && ScreenRecorder.elapsedText(65) == "01:05"
                && ScreenRecorder.elapsedText(3661) == "1:01:01"
        )

        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let indicatorOrigin = RecordingIndicatorPlacement.origin(screenFrame: frame)
        check(
            "recording: indicator sits below the menu bar, horizontally centred",
            abs(indicatorOrigin.x - (500 - RecordingIndicatorPlacement.panelSize.width / 2)) < 0.5
                && abs(indicatorOrigin.y - (800 - RecordingIndicatorPlacement.panelSize.height - 44)) < 0.5,
            "origin=\(NSStringFromPoint(indicatorOrigin))"
        )

        // 录制中: the HUD is not parked somewhere new — it takes the capture
        // toolbar's exact place, so the selector reads as the same interface
        // with the toolbar's contents swapped for the recording controls.
        let toolbarSlot = CGRect(x: 500, y: 400, width: 118, height: 34)
        let hudSlot = CaptureOverlayController.recordingHUDOrigin(
            controlFrame: toolbarSlot,
            screenFrame: frame
        )
        check(
            "recording: the HUD is centred on the toolbar frame it replaces",
            hudSlot == CGPoint(x: 455, y: 397),
            "origin=\(NSStringFromPoint(hudSlot)) toolbar=\(format(toolbarSlot))"
        )
        check(
            "recording: the HUD covers the toolbar's centre (same spot, not nearby)",
            CGRect(
                origin: hudSlot,
                size: RecordingIndicatorPlacement.panelSize
            ).contains(CGPoint(x: toolbarSlot.midX, y: toolbarSlot.midY)),
            "hud=\(format(CGRect(origin: hudSlot, size: RecordingIndicatorPlacement.panelSize)))"
        )
        check(
            "recording: a toolbar hugging the left edge keeps the HUD on screen",
            CaptureOverlayController.recordingHUDOrigin(
                controlFrame: CGRect(x: 0, y: 400, width: 118, height: 34),
                screenFrame: frame
            ).x == 6,
            "origin=\(NSStringFromPoint(CaptureOverlayController.recordingHUDOrigin(controlFrame: CGRect(x: 0, y: 400, width: 118, height: 34), screenFrame: frame)))"
        )
        check(
            "recording: a toolbar hugging the right edge keeps the HUD on screen",
            CaptureOverlayController.recordingHUDOrigin(
                controlFrame: CGRect(x: 980, y: 400, width: 118, height: 34),
                screenFrame: frame
            ).x == 786,
            "origin=\(NSStringFromPoint(CaptureOverlayController.recordingHUDOrigin(controlFrame: CGRect(x: 980, y: 400, width: 118, height: 34), screenFrame: frame)))"
        )
        check(
            "recording: a toolbar at the bottom keeps the HUD above the screen edge",
            CaptureOverlayController.recordingHUDOrigin(
                controlFrame: CGRect(x: 500, y: 780, width: 118, height: 34),
                screenFrame: frame
            ).y == 754,
            "origin=\(NSStringFromPoint(CaptureOverlayController.recordingHUDOrigin(controlFrame: CGRect(x: 500, y: 780, width: 118, height: 34), screenFrame: frame)))"
        )
        check(
            "recording: the standalone HUD (no overlay) keeps the legacy top-centre spot",
            RecordingIndicatorPlacement.origin(screenFrame: frame) == CGPoint(x: 396, y: 716),
            "origin=\(NSStringFromPoint(RecordingIndicatorPlacement.origin(screenFrame: frame)))"
        )

        let indicatorView = RecordingIndicatorView(
            frame: CGRect(origin: .zero, size: RecordingIndicatorPlacement.panelSize)
        )
        indicatorView.update(state: .recording, elapsedText: "00:42")
        check(
            "recording: indicator shows the state and MM:SS",
            indicatorView.state == .recording && indicatorView.elapsedText == "00:42"
        )
        indicatorView.update(state: .paused, elapsedText: "00:42")
        check("recording: indicator reflects paused", indicatorView.state == .paused)
        indicatorView.stopPulse()

        check(
            "recording: status bar badge is a red dot plus timer",
            RecordingStatusBadge.text(state: .recording, elapsedText: "00:12") == "● 00:12",
            "badge=\(RecordingStatusBadge.text(state: .recording, elapsedText: "00:12") ?? "nil")"
        )
        check(
            "recording: status bar badge switches to the paused glyph",
            RecordingStatusBadge.text(state: .paused, elapsedText: "00:12") == "⏸ 00:12"
                && RecordingStatusBadge.isPaused(.paused)
        )
        check(
            "recording: status bar badge clears when idle or finished",
            RecordingStatusBadge.text(state: .idle, elapsedText: "00:00") == nil
                && RecordingStatusBadge.text(state: .finished, elapsedText: "00:10") == nil
        )

        let region = ScreenRecorder.localTopLeftRect(
            region: CGRect(x: 100, y: 200, width: 300, height: 150),
            screenFrame: frame
        )
        check(
            "recording: region maps to display-local top-left coordinates",
            region == CGRect(x: 100, y: 450, width: 300, height: 150),
            "local=\(String(describing: region))"
        )
        let clippedRegion = ScreenRecorder.localTopLeftRect(
            region: CGRect(x: -100, y: -100, width: 300, height: 200),
            screenFrame: frame
        )
        check(
            "recording: region is clipped to the screen",
            clippedRegion == CGRect(x: 0, y: 700, width: 200, height: 100),
            "local=\(String(describing: clippedRegion))"
        )
        check(
            "recording: no region means the whole screen",
            ScreenRecorder.localTopLeftRect(region: nil, screenFrame: frame) == nil
        )
    }

    private struct RecordingAssetInfo {
        let duration: Double
        let size: CGSize
        let codec: String
        let nominalFrameRate: Float
        let trackCount: Int
    }

    private static func inspectRecording(_ url: URL) async -> RecordingAssetInfo? {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else {
                print("[recording] no video track in \(url.lastPathComponent)")
                return nil
            }
            let size = try await track.load(.naturalSize)
            let frameRate = try await track.load(.nominalFrameRate)
            let descriptions = try await track.load(.formatDescriptions)
            let codec: String
            if let description = descriptions.first {
                codec = fourCharacterCode(CMFormatDescriptionGetMediaSubType(description))
            } else {
                codec = "?"
            }
            return RecordingAssetInfo(
                duration: duration.seconds,
                size: size,
                codec: codec,
                nominalFrameRate: frameRate,
                trackCount: tracks.count
            )
        } catch {
            print("[recording] AVURLAsset inspection failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// First decodable video frame, for pixel probes on a real recording.
    private static func firstFrame(of url: URL) -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try? generator.copyCGImage(
            at: CMTime(seconds: 0.2, preferredTimescale: 600),
            actualTime: nil
        )
    }

    /// One frame from an already-written clip, at `seconds` (zero tolerance).
    private static func videoFrame(of url: URL, at seconds: Double) -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try? generator.copyCGImage(
            at: CMTime(seconds: seconds, preferredTimescale: 600),
            actualTime: nil
        )
    }

    /// Map a global AppKit rect into an image's top-left pixel coordinates.
    private static func pixelRect(
        of globalRect: CGRect,
        in captureRect: CGRect,
        scale: CGFloat
    ) -> CGRect {
        CGRect(
            x: (globalRect.minX - captureRect.minX) * scale,
            y: (captureRect.maxY - globalRect.maxY) * scale,
            width: globalRect.width * scale,
            height: globalRect.height * scale
        )
    }

    /// Saturated-red pixels within `tolerance` device pixels of `rect`'s four
    /// edges. Used to ask "is the accent line here?" of one real image and
    /// "is the accent line here?" of the same region in a recording.
    private static func redPixels(
        in buffer: PixelBuffer,
        bandAround rect: CGRect,
        tolerance: Int
    ) -> Int {
        let left = Int(rect.minX.rounded())
        let top = Int(rect.minY.rounded())
        let right = Int(rect.maxX.rounded()) - 1
        let bottom = Int(rect.maxY.rounded()) - 1
        guard right >= left, bottom >= top,
              buffer.width > 0, buffer.height > 0 else { return 0 }
        let xRange = max(0, left - tolerance)...min(buffer.width - 1, right + tolerance)
        let yRange = max(0, top - tolerance)...min(buffer.height - 1, bottom + tolerance)
        guard xRange.lowerBound <= xRange.upperBound,
              yRange.lowerBound <= yRange.upperBound else { return 0 }
        var count = 0
        for y in yRange {
            for x in xRange {
                let nearTopBottom = x >= left && x <= right
                    && (abs(y - top) <= tolerance || abs(y - bottom) <= tolerance)
                let nearLeftRight = y >= top && y <= bottom
                    && (abs(x - left) <= tolerance || abs(x - right) <= tolerance)
                guard nearTopBottom || nearLeftRight else { continue }
                let (r, g, b) = buffer.rgb(x: x, y: y)
                if r >= 170, g <= 130, b <= 130, r - max(g, b) >= 50 {
                    count += 1
                }
            }
        }
        return count
    }

    /// Move the cursor in a small circle inside `rect` for `seconds`.
    ///
    /// ScreenCaptureKit only delivers a frame when the pixels change; a static
    /// desktop would produce a one-frame file no matter how long the session
    /// ran. The cursor is part of the recorded pixels (`showsCursor = true`), so
    /// moving it keeps real frames flowing. The original position is restored.
    private static func cursorMotion(
        in rect: CGRect,
        seconds: TimeInterval
    ) -> Task<Void, Never> {
        let restore = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? rect.maxY
        return Task { @MainActor in
            let started = Date()
            var step = 0
            while !Task.isCancelled, Date().timeIntervalSince(started) < seconds {
                let angle = Double(step) * 0.6
                let point = CGPoint(
                    x: rect.midX + CGFloat(cos(angle)) * 140,
                    y: rect.midY + CGFloat(sin(angle)) * 90
                )
                CGWarpMouseCursorPosition(
                    CGPoint(x: point.x, y: primaryHeight - point.y)
                )
                step += 1
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            CGWarpMouseCursorPosition(
                CGPoint(x: restore.x, y: primaryHeight - restore.y)
            )
        }
    }

    private static func fourCharacterCode(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "0x\(String(code, radix: 16))"
    }

    /// Real SCStream + AVAssetWriter sessions.
    ///
    /// The assertions read the produced file back with `AVURLAsset`, so they
    /// cannot pass unless frames were actually encoded. If the machine has no
    /// screen-recording grant the integration part is reported as skipped and
    /// the state-machine group above remains the coverage.
    private static func runRecordingGroup(into directory: URL) async {
        guard ScreenCapture.hasScreenRecordingPermission else {
            print("[recording] SKIP: no screen recording permission for this process; "
                + "state-machine checks above remain the coverage")
            return
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            check("recording: a screen is available", false)
            return
        }

        let output = directory.appendingPathComponent("recording", isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let rawScale = max(screen.backingScaleFactor, 1)
        let expectedPointSize = screen.frame.size
        let expectedPixelSize = CGSize(
            width: (expectedPointSize.width * rawScale).rounded(),
            height: (expectedPointSize.height * rawScale).rounded()
        )
        let configuration = RecordingConfiguration(
            format: .mp4,
            frameRate: 30,
            bitrate: 8_000_000,
            capturesMicrophone: false
        )
        print(
            "[recording] screen points=\(Int(expectedPointSize.width))×\(Int(expectedPointSize.height)) "
            + "scale=\(rawScale) → expecting pixels="
            + "\(Int(expectedPixelSize.width))×\(Int(expectedPixelSize.height))"
        )

        // 1. Record 2.5 s, then read duration / natural size / codec back.
        let plain = ScreenRecorder()
        do {
            _ = try await plain.start(
                screen: screen,
                region: nil,
                configuration: configuration,
                directory: output
            )
            check(
                "recording: state is recording after start",
                plain.state == .recording,
                "state=\(plain.state.rawValue)"
            )
            try await Task.sleep(nanoseconds: 2_500_000_000)
            let result = try await plain.stop()
            check(
                "recording: state is finished after stop",
                plain.state == .finished && !plain.isActive,
                "state=\(plain.state.rawValue)"
            )
            check(
                "recording: file exists and is non-empty",
                FileManager.default.fileExists(atPath: result.url.path)
                    && fileSize(result.url) > 0,
                "bytes=\(fileSize(result.url))"
            )
            check(
                "recording: frames were actually encoded",
                result.framesWritten > 30,
                "frames=\(result.framesWritten)"
            )
            if let info = await inspectRecording(result.url) {
                print(
                    "[recording] AVURLAsset duration=\(String(format: "%.4f", info.duration))s "
                    + "naturalSize=\(Int(info.size.width))×\(Int(info.size.height)) "
                    + "codec=\(info.codec) fps=\(String(format: "%.2f", info.nominalFrameRate)) "
                    + "bytes=\(fileSize(result.url))"
                )
                check(
                    "recording: duration ≈ 2.5 s (±0.8)",
                    abs(info.duration - 2.5) <= 0.8,
                    "duration=\(String(format: "%.3f", info.duration))s"
                )
                check(
                    "recording: naturalSize = screen pixels (points × scale)",
                    abs(info.size.width - expectedPixelSize.width) <= 2
                        && abs(info.size.height - expectedPixelSize.height) <= 2,
                    "naturalSize=\(Int(info.size.width))×\(Int(info.size.height)) "
                        + "expected=\(Int(expectedPixelSize.width))×\(Int(expectedPixelSize.height))"
                )
                check(
                    "recording: video codec is H.264 (avc1)",
                    info.codec == "avc1",
                    "codec=\(info.codec)"
                )
                check("recording: exactly one video track", info.trackCount == 1)
            } else {
                check("recording: file is readable by AVURLAsset", false)
            }
        } catch {
            check("recording: a 2.5 s session completes", false, "error=\(error.localizedDescription)")
        }

        // 2. Pause semantics: 1.5 s + pause 1.2 s + resume 1.5 s. The file must
        //    contain ~3.0 s, not the ~4.2 s of wall-clock time.
        let paused = ScreenRecorder()
        do {
            let url = try await paused.start(
                screen: screen,
                region: nil,
                configuration: configuration,
                directory: output
            )
            try await Task.sleep(nanoseconds: 1_500_000_000)
            check("recording: pause is accepted", paused.pause() && paused.state == .paused)
            let frozen = paused.elapsed()
            try await Task.sleep(nanoseconds: 1_200_000_000)
            let frozenAgain = paused.elapsed()
            check(
                "recording: elapsed is frozen while paused",
                abs(frozenAgain - frozen) < 0.2,
                "before=\(String(format: "%.2f", frozen))s after=\(String(format: "%.2f", frozenAgain))s"
            )
            check("recording: resume is accepted", paused.resume() && paused.state == .recording)
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let result = try await paused.stop()
            check(
                "recording: paused session ends in finished",
                paused.state == .finished,
                "state=\(paused.state.rawValue)"
            )
            if let info = await inspectRecording(url) {
                print(
                    "[recording] paused file duration=\(String(format: "%.4f", info.duration))s "
                    + "activeElapsed=\(String(format: "%.3f", result.elapsed))s "
                    + "wallClock≈4.2s naturalSize=\(Int(info.size.width))×\(Int(info.size.height)) "
                    + "codec=\(info.codec) bytes=\(fileSize(url))"
                )
                check(
                    "recording: duration ≈ 3.0 s, pause excluded (±0.8)",
                    abs(info.duration - 3.0) <= 0.8,
                    "duration=\(String(format: "%.3f", info.duration))s"
                )
                check(
                    "recording: paused clip is shorter than wall clock",
                    info.duration < 3.9,
                    "duration=\(String(format: "%.3f", info.duration))s wall≈4.2s"
                )
                check(
                    "recording: paused clip still reports H.264",
                    info.codec == "avc1",
                    "codec=\(info.codec)"
                )
            } else {
                check("recording: paused file is readable by AVURLAsset", false)
            }
        } catch {
            check("recording: a paused session completes", false, "error=\(error.localizedDescription)")
        }

        // 3. Region recording: the selected rectangle becomes the buffer size.
        //    The example is the owner's own: an 800×600 pt box on a 2× display
        //    must produce a 1600×1200 px video.
        let regional = ScreenRecorder()
        do {
            let region = CGRect(
                x: screen.frame.midX - 400,
                y: screen.frame.midY - 300,
                width: 800,
                height: 600
            )
            let regionPixelSize = CGSize(
                width: (region.width * rawScale).rounded(),
                height: (region.height * rawScale).rounded()
            )
            let url = try await regional.start(
                screen: screen,
                region: region,
                configuration: configuration,
                directory: output
            )
            try await Task.sleep(nanoseconds: 2_400_000_000)
            let result = try await regional.stop()
            if let info = await inspectRecording(url) {
                print(
                    "[recording] region file duration=\(String(format: "%.4f", info.duration))s "
                    + "naturalSize=\(Int(info.size.width))×\(Int(info.size.height)) "
                    + "codec=\(info.codec) bytes=\(fileSize(url))"
                )
                check(
                    "recording: region buffer is the region × scale "
                        + "(\(Int(region.width))×\(Int(region.height)) pt "
                        + "→ \(Int(regionPixelSize.width))×\(Int(regionPixelSize.height)) px)",
                    abs(info.size.width - regionPixelSize.width) <= 2
                        && abs(info.size.height - regionPixelSize.height) <= 2,
                    "naturalSize=\(Int(info.size.width))×\(Int(info.size.height)) "
                        + "expected=\(Int(regionPixelSize.width))×\(Int(regionPixelSize.height)) "
                        + "points=\(Int(region.width))×\(Int(region.height)) scale=\(rawScale)"
                )
                check(
                    // AVAssetWriter emits a frame only when the pixels change,
                    // so a static test region yields a very short asset no
                    // matter how long the stream ran. Assert that a real,
                    // playable clip exists; the stream's own elapsed clock is
                    // covered separately.
                    "recording: region clip is a playable asset",
                    info.duration > 0 && info.size.width > 0 && info.size.height > 0,
                    "duration=\(String(format: "%.3f", info.duration))s size=\(Int(info.size.width))×\(Int(info.size.height))"
                )
                check(
                    "recording: region clip is H.264",
                    info.codec == "avc1",
                    "codec=\(info.codec)"
                )
                check("recording: region clip has frames", result.framesWritten >= 1,
                      "frames=\(result.framesWritten)")
            } else {
                check("recording: region file is readable", false)
            }
        } catch {
            check("recording: a region session completes", false, "error=\(error.localizedDescription)")
        }

        // 3b. Own windows are excluded from the video. Two observations per
        //     decoration: the window is in the stream's exclusion list, and its
        //     pixels are absent from a real recorded frame.
        //
        //     First the generic probe: a magenta own window inside the
        //     recorded region must not reach the frame.
        let probeRect = CGRect(
            x: screen.frame.midX - 200,
            y: screen.frame.midY - 150,
            width: 400,
            height: 300
        )
        let magentaWindow = NSWindow(
            contentRect: CGRect(
                x: probeRect.midX - 60,
                y: probeRect.midY - 40,
                width: 120,
                height: 80
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        magentaWindow.isOpaque = true
        magentaWindow.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        magentaWindow.level = .floating
        magentaWindow.collectionBehavior = [.canJoinAllSpaces, .stationary]
        magentaWindow.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 150_000_000)
        let probeRectPixels = CGSize(
            width: (probeRect.width * rawScale).rounded(),
            height: (probeRect.height * rawScale).rounded()
        )
        var ownProbeExcluded = false
        do {
            let exclusion = try await ScreenCapture.displayAndOwnWindows(matching: screen)
            ownProbeExcluded = exclusion.ownWindows.contains {
                $0.windowID == CGWindowID(magentaWindow.windowNumber)
            }
            check(
                "recording: a visible own window joins the exclusion list",
                magentaWindow.isVisible && ownProbeExcluded,
                "window=\(magentaWindow.windowNumber) visible=\(magentaWindow.isVisible) "
                    + "excluded=\(ownProbeExcluded)"
            )
            let probeRecorder = ScreenRecorder()
            let probeURL = try await probeRecorder.start(
                screen: screen,
                region: probeRect,
                configuration: configuration,
                directory: output
            )
            try await Task.sleep(nanoseconds: 1_200_000_000)
            _ = try await probeRecorder.stop()
            let windowCentre = CGPoint(
                x: magentaWindow.frame.midX,
                y: magentaWindow.frame.midY
            )
            let pixelX = Int(
                ((windowCentre.x - probeRect.minX) * rawScale).rounded()
            )
            let pixelY = Int(
                ((probeRect.maxY - windowCentre.y) * rawScale).rounded()
            )
            let sampled = firstFrame(of: probeURL).flatMap {
                pixel($0, x: pixelX, y: pixelY)
            }
            let isMagenta = sampled.map {
                $0.r > 200 && $0.g < 60 && $0.b > 200
            } ?? false
            check(
                "recording: the own window's pixels are absent from the video frame",
                sampled != nil
                    && !isMagenta
                    && abs(CGFloat(sampled!.r) - CGFloat(sampled!.b)) < 120,
                "videoPixel=\(String(describing: sampled)) "
                    + "frame=\(Int(probeRectPixels.width))×\(Int(probeRectPixels.height)) "
                    + "at=\(pixelX),\(pixelY)"
            )
            if let frameImage = firstFrame(of: probeURL) {
                writePNG(
                    frameImage,
                    to: directory.appendingPathComponent("72-recording-own-window-excluded.png")
                )
                print(
                    "[recording] wrote 72-recording-own-window-excluded.png "
                        + "(\(frameImage.width)×\(frameImage.height) px)"
                )
            }
        } catch {
            check(
                "recording: the own-window exclusion probe completes",
                false,
                "error=\(error.localizedDescription)"
            )
        }
        // `isReleasedWhenClosed` defaults to true, so `close()` would send the
        // release ARC also owns and the window would be freed twice at scope
        // exit. The probe only needs the window off screen.
        magentaWindow.isReleasedWhenClosed = false
        magentaWindow.orderOut(nil)
        magentaWindow.close()

        // 3c. 录制中: the selector itself is the recording UI.
        //
        //      The user's rule: a recording looks like a region *screenshot* —
        //      veil, border, eight handles, size chip, crosshair — and only the
        //      toolbar's contents change to the recording controls. The HUD is a
        //      separate panel (the overlay is click-through so the recorded app
        //      stays usable) but it is centred on the toolbar's exact frame.
        //
        //      This drives the shipping path end to end: the real overlay
        //      panels, the 开始录制 toolbar action, the coordinator, a real
        //      SCStream, a real live screenshot (own windows included) and a
        //      chrome-free reference from the same instant. The video is not
        //      supposed to contain any of it.
        let recordingSuite = "UnseenRecordingUI-\(UUID().uuidString)"
        var clipURL: URL?
        var referenceBuffer: PixelBuffer?
        var liveRect = CGRect.zero
        var chromeEvidence = (
            borderCoverage: 0.0,
            handles: 0,
            hudWhite: 0,
            hudResidual: 0,
            hudRed: 0
        )
        var hudFrameGlobal = CGRect.zero
        if let defaults = UserDefaults(suiteName: recordingSuite) {
            defer { defaults.removePersistentDomain(forName: recordingSuite) }
            let settings = AppSettings(defaults: defaults)
            let clipDirectory = directory.appendingPathComponent(
                "recording-ui",
                isDirectory: true
            )
            try? FileManager.default.createDirectory(
                at: clipDirectory,
                withIntermediateDirectories: true
            )
            settings.captureDirectoryPath = clipDirectory.path
            settings.captureSound = false
            settings.keyDisplayEnabled = false
            settings.cameraOverlayEnabled = false

            let region = CGRect(
                x: (screen.frame.midX - 320).rounded(),
                y: (screen.frame.midY - 200).rounded(),
                width: 640,
                height: 400
            )
            let coordinator = CaptureCoordinator(settings: settings)
            let controller = coordinator.presentRecordingOverlayForTesting(
                on: screen,
                prefill: region
            )
            if let view = controller.overlayViewsForTesting.first {
                view.revealToolbarForTesting()
                try? await Task.sleep(nanoseconds: 250_000_000)
                let toolbarBefore = view.toolbarFrameForTesting
                let chipBefore = view.indicatorFrameForTesting
                let chipTextBefore = view.sizeIndicatorTextForTesting
                check(
                    "recording-ui: the selector opens with the chosen box and its toolbar",
                    sameRect(view.selectionRectForTesting, region)
                        && view.isToolbarVisibleForTesting,
                    "selection=\(format(view.selectionRectForTesting)) "
                        + "toolbar=\(view.isToolbarVisibleForTesting)"
                )

                // The shipping 开始录制 path.
                view.performToolbarActionForTesting(.record)
                var started = false
                // `recordingState` flips synchronously when the coordinator is
                // asked to start; the stream (and its content filter snapshot)
                // is ready when `isBusy` returns to false.
                for _ in 0..<160 {
                    if coordinator.recordingState == .recording,
                       !coordinator.isBusy,
                       controller.recordingIndicatorForTesting != nil {
                        started = true
                        break
                    }
                    if !coordinator.isBusy, coordinator.recordingState == .idle { break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                // Let the window server actually register the HUD before asking
                // ScreenCaptureKit what it can see.
                try? await Task.sleep(nanoseconds: 250_000_000)
                check(
                    "recording-ui: 开始录制 starts the stream",
                    started,
                    "state=\(coordinator.recordingState.rawValue) "
                        + "busy=\(coordinator.isBusy)"
                )
                check(
                    "recording-ui: the selector does NOT close for 录制中",
                    controller.hasPanelsForTesting && view.isRecordingLiveForTesting,
                    "panels=\(controller.hasPanelsForTesting) "
                        + "live=\(view.isRecordingLiveForTesting)"
                )
                check(
                    "recording-ui: 录制中 keeps the veil, border, handles, size chip "
                        + "and crosshair",
                    sameRect(view.dimmingSelectionRectForTesting, region)
                        && view.isSelectionBorderVisibleForTesting
                        && view.isIndicatorVisibleForTesting
                        && view.sizeIndicatorTextForTesting == chipTextBefore
                        && !view.isCrosshairHiddenForTesting,
                    "mask=\(format(view.dimmingSelectionRectForTesting)) "
                        + "border=\(view.isSelectionBorderVisibleForTesting) "
                        + "chip=\(view.isIndicatorVisibleForTesting) "
                        + "crosshair=\(!view.isCrosshairHiddenForTesting)"
                )
                check(
                    "recording-ui: the size chip does not move when the toolbar is swapped",
                    sameRect(view.indicatorFrameForTesting, chipBefore),
                    "chip=\(format(view.indicatorFrameForTesting)) "
                        + "before=\(format(chipBefore))"
                )
                check(
                    "recording-ui: the capture toolbar is replaced in place by the HUD",
                    !view.isToolbarVisibleForTesting
                        && sameRect(view.recordingControlFrameForTesting, toolbarBefore),
                    "toolbarVisible=\(view.isToolbarVisibleForTesting) "
                        + "hudSlot=\(format(view.recordingControlFrameForTesting)) "
                        + "toolbar=\(format(toolbarBefore))"
                )
                let passthrough = controller.panelPassthroughForTesting
                check(
                    "recording-ui: the panels are click-through, so the recorded app "
                        + "stays usable",
                    !passthrough.isEmpty && passthrough.allSatisfy { $0 },
                    "panels=\(passthrough)"
                )
                let hud = controller.recordingIndicatorForTesting
                check(
                    "recording-ui: the recording HUD is on screen",
                    hud?.isVisible == true && hud?.panel?.isVisible == true,
                    "visible=\(String(describing: hud?.isVisible)) "
                        + "panel=\(String(describing: hud?.panel?.isVisible))"
                )
                if let hudPanel = hud?.panel {
                    hudFrameGlobal = hudPanel.frame
                    let slotGlobal = view.recordingControlFrameForTesting.offsetBy(
                        dx: screen.frame.minX,
                        dy: screen.frame.minY
                    )
                    let expectedOrigin = CaptureOverlayController.recordingHUDOrigin(
                        controlFrame: slotGlobal,
                        screenFrame: screen.frame
                    )
                    check(
                        "recording-ui: the HUD sits exactly where the toolbar was",
                        hudPanel.frame.origin == expectedOrigin,
                        "hud=\(NSStringFromPoint(hudPanel.frame.origin)) "
                            + "expected=\(NSStringFromPoint(expectedOrigin))"
                    )
                    check(
                        "recording-ui: the HUD controls are outside the recorded rectangle",
                        !hudPanel.frame.intersects(region),
                        "hud=\(format(hudPanel.frame)) region=\(format(region))"
                    )
                } else {
                    check("recording-ui: the HUD sits exactly where the toolbar was", false)
                    check("recording-ui: the HUD controls are outside the recorded rectangle", false)
                }
                if let hudView = hud?.indicatorView {
                    check(
                        "recording-ui: the HUD reads 录制中 with a timer, pause and stop",
                        hudView.state == .recording
                            && hudView.elapsedText == "00:00",
                        "state=\(hudView.state.rawValue) elapsed=\(hudView.elapsedText)"
                    )
                } else {
                    check(
                        "recording-ui: the HUD reads 录制中 with a timer, pause and stop",
                        false
                    )
                }

                if let (_, ownWindows) = try? await ScreenCapture.displayAndOwnWindows(
                    matching: screen
                ) {
                    let overlayNumbers = Set(controller.panelWindowNumbersForTesting.map {
                        CGWindowID($0)
                    })
                    let ownNumbers = Set(ownWindows.map(\.windowID))
                    let hudNumber = hud?.panel.map { CGWindowID($0.windowNumber) }
                    print(
                        "[recording-ui] own windows: "
                            + ownWindows.map {
                                "\($0.windowID) layer=\($0.windowLayer) "
                                    + "\(NSStringFromRect($0.frame))"
                            }.joined(separator: " | ")
                    )
                    check(
                        "recording-ui: every overlay panel is in the stream's "
                            + "own-window exclusion list",
                        !overlayNumbers.isEmpty && overlayNumbers.isSubset(of: ownNumbers),
                        "panels=\(overlayNumbers.sorted()) own=\(ownNumbers.sorted())"
                    )
                    check(
                        "recording-ui: the recording HUD is in the same exclusion list",
                        hudNumber != nil && ownNumbers.contains(hudNumber!),
                        "hud=\(String(describing: hudNumber)) own=\(ownNumbers.sorted())"
                    )
                } else {
                    check(
                        "recording-ui: every overlay panel is in the stream's "
                            + "own-window exclusion list",
                        false
                    )
                    check(
                        "recording-ui: the recording HUD is in the same exclusion list",
                        false
                    )
                }

                // Why the selection is visible in the evidence shot and why the
                // recording still has frames: keep the cursor moving inside it.
                let motion = cursorMotion(in: region, seconds: 4.4)
                try? await Task.sleep(nanoseconds: 1_300_000_000)
                if let hudView = hud?.indicatorView {
                    check(
                        "recording-ui: the elapsed clock ticks in the HUD",
                        hudView.elapsedText != "00:00",
                        "elapsed=\(hudView.elapsedText)"
                    )
                } else {
                    check("recording-ui: the elapsed clock ticks in the HUD", false)
                }

                // Reverse-verification switch: with
                // `UNSEEN_OVERLAY_TEST_SUPPRESS_CHROME=1` the overlay
                // panels and the HUD really leave the screen before the two
                // captures below. That is how the self test proves its
                // "overlay is on screen" checks are not vacuous: with no
                // chrome to see, they must fail. It only applies to this
                // already test-only harness and is off by default.
                if environment["UNSEEN_OVERLAY_TEST_SUPPRESS_CHROME"] == "1" {
                    for overlayView in controller.overlayViewsForTesting {
                        overlayView.window?.orderOut(nil)
                    }
                    hud?.panel?.orderOut(nil)
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    print("[recording-ui] chrome suppressed for the pixel checks")
                }

                // The screen as the user sees it (own windows included) and the
                // same instant with every own window excluded — the latter is
                // what the video must look like.
                liveRect = region.insetBy(dx: -80, dy: -80).intersection(screen.frame)
                let live = try? await ScreenCapture.captureArea(
                    liveRect,
                    on: screen,
                    includeCursor: false,
                    excludingOwnWindows: false
                )
                let reference = try? await ScreenCapture.captureArea(
                    liveRect,
                    on: screen,
                    includeCursor: false,
                    excludingOwnWindows: true
                )
                if let live, let reference,
                   let livePixels = pixelBuffer(live.image),
                   let referencePixels = pixelBuffer(reference.image) {
                    referenceBuffer = referencePixels
                    writePNG(
                        live.image,
                        to: directory.appendingPathComponent(
                            "74-recording-ui-live-screen.png"
                        )
                    )
                    if let full = try? await ScreenCapture.captureFullScreen(
                        screen,
                        includeCursor: false
                    ) {
                        writePNG(
                            full.image,
                            to: directory.appendingPathComponent(
                                "76-recording-ui-full-screen.png"
                            )
                        )
                        print(
                            "[recording-ui] wrote 76-recording-ui-full-screen.png "
                                + "(\(full.image.width)×\(full.image.height) px)"
                        )
                    }
                    print(
                        "[recording-ui] wrote 74-recording-ui-live-screen.png "
                            + "(\(live.image.width)×\(live.image.height) px)"
                    )
                    // The chrome-free twin of the live shot: the reference the
                    // recording must match, and the subtractive partner for
                    // the overlay-presence checks below.
                    writePNG(
                        reference.image,
                        to: directory.appendingPathComponent(
                            "77-recording-ui-reference.png"
                        )
                    )
                    print(
                        "[recording-ui] wrote 77-recording-ui-reference.png "
                            + "(\(reference.image.width)×\(reference.image.height) px)"
                    )

                    let regionInLive = pixelRect(
                        of: region,
                        in: liveRect,
                        scale: rawScale
                    )
                    let hudInLive = pixelRect(
                        of: hudFrameGlobal,
                        in: liveRect,
                        scale: rawScale
                    )
                    var darkened = 0
                    var samples = 0
                    var liveLumaSum = 0.0
                    var referenceLumaSum = 0.0
                    func luma(_ buffer: PixelBuffer, _ x: Int, _ y: Int) -> Double {
                        let (r, g, b) = buffer.rgb(x: x, y: y)
                        return 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
                    }
                    func isChromeWhite(_ buffer: PixelBuffer, _ x: Int, _ y: Int) -> Bool {
                        let (r, g, b) = buffer.rgb(x: x, y: y)
                        return r >= 190 && g >= 190 && b >= 190
                    }
                    let avoid = regionInLive.insetBy(
                        dx: -12 * rawScale,
                        dy: -12 * rawScale
                    )
                    for y in stride(from: 0, to: livePixels.height, by: 6) {
                        for x in stride(from: 0, to: livePixels.width, by: 6) {
                            let point = CGPoint(x: x, y: y)
                            if avoid.contains(point) { continue }
                            if hudInLive.contains(point) { continue }
                            let l = luma(livePixels, x, y)
                            let r = luma(referencePixels, x, y)
                            liveLumaSum += l
                            referenceLumaSum += r
                            samples += 1
                            if l < r - 8 { darkened += 1 }
                        }
                    }
                    check(
                        "recording-ui: the veil still darkens the desktop outside the selection",
                        samples > 100 && darkened > samples * 3 / 4
                            && referenceLumaSum / Double(samples)
                                - liveLumaSum / Double(samples) > 10,
                        "darkened=\(darkened)/\(samples) "
                            + "liveLuma=\(String(format: "%.1f", liveLumaSum / Double(samples))) "
                            + "referenceLuma=\(String(format: "%.1f", referenceLumaSum / Double(samples)))"
                    )

                    // The outline is a 1.5 pt opaque white line over a 3 pt
                    // 35 % black halo. Counting white pixels cannot see it on a
                    // light desktop: the page behind the band is white too (a
                    // white-walled desktop made the old check compare 33 k
                    // against 66 k "white" pixels that were all backdrop).
                    //
                    // Instead, model what the live frame would show if the
                    // overlay drew nothing and compare. The veil multiplies the
                    // desktop by a constant, so the live/reference ratio in a
                    // chrome-free ring *measures* that constant for this frame
                    // instead of hard-coding it. The residual
                    // `|live − ratio × reference|` then cancels the desktop on
                    // any backdrop: a white page hides the white line but not
                    // the dark halo, a black page hides the halo but not the
                    // line, and neither hides either. Without the overlay the
                    // residual is exactly zero everywhere.
                    let calibrationOuter = regionInLive.insetBy(
                        dx: -20 * rawScale,
                        dy: -20 * rawScale
                    )
                    let calibrationInner = regionInLive.insetBy(
                        dx: -12 * rawScale,
                        dy: -12 * rawScale
                    )
                    var veilRatios: [Double] = []
                    for y in stride(
                        from: Int(calibrationOuter.minY),
                        to: Int(calibrationOuter.maxY),
                        by: 2
                    ) {
                        for x in stride(
                            from: Int(calibrationOuter.minX),
                            to: Int(calibrationOuter.maxX),
                            by: 2
                        ) {
                            if calibrationInner.contains(CGPoint(x: x, y: y)) { continue }
                            guard x >= 0, y >= 0,
                                  x < livePixels.width, y < livePixels.height,
                                  x < referencePixels.width, y < referencePixels.height
                            else { continue }
                            let referenceValue = luma(referencePixels, x, y)
                            guard referenceValue >= 45 else { continue }
                            // No upper bound: when the overlay is absent the
                            // ring ratio is exactly 1.0, and that has to be
                            // measurable rather than treated as "no samples"
                            // and replaced by the fallback below.
                            veilRatios.append(luma(livePixels, x, y) / referenceValue)
                        }
                    }
                    veilRatios.sort()
                    // A nearly black backdrop leaves the ring too dark to
                    // divide by; the residual there is carried by the stroke
                    // itself, so the veil's nominal transmission is a safe
                    // stand-in rather than a load-bearing constant. (On a
                    // measured (non-black) backdrop the median is 1.0 with no
                    // overlay and 0.62 with it, so the fallback is never the
                    // difference between pass and fail.)
                    let veilRatio = veilRatios.count >= 200
                        ? veilRatios[veilRatios.count / 2]
                        : 0.62
                    func outlineResidual(
                        _ x: Int,
                        _ y: Int,
                        dx: Int,
                        dy: Int
                    ) -> Double {
                        var best = 0.0
                        for step in -6...6 {
                            let sx = x + step * dx
                            let sy = y + step * dy
                            guard sx >= 0, sy >= 0,
                                  sx < livePixels.width, sy < livePixels.height,
                                  sx < referencePixels.width, sy < referencePixels.height
                            else { continue }
                            let residual = abs(
                                luma(livePixels, sx, sy)
                                    - veilRatio * luma(referencePixels, sx, sy)
                            )
                            best = max(best, residual)
                        }
                        return best
                    }
                    let borderMargin = Int((16 * rawScale).rounded())
                    let minX = Int(regionInLive.minX)
                    let minY = Int(regionInLive.minY)
                    let maxX = Int(regionInLive.maxX) - 1
                    let maxY = Int(regionInLive.maxY) - 1
                    var outlineHits = 0
                    var outlineSamples = 0
                    func sampleOutline(_ x: Int, _ y: Int, dx: Int, dy: Int) {
                        outlineSamples += 1
                        if outlineResidual(x, y, dx: dx, dy: dy) >= 30 { outlineHits += 1 }
                    }
                    // Skip 16 pt at each end so a missing handle cannot be
                    // confused with a missing border; the edge-midpoint handle
                    // is deliberately inside the sampled span.
                    if maxX - borderMargin > minX + borderMargin,
                       maxY - borderMargin > minY + borderMargin {
                        for x in stride(
                            from: minX + borderMargin,
                            through: maxX - borderMargin,
                            by: 2
                        ) {
                            sampleOutline(x, minY, dx: 0, dy: 1)
                            sampleOutline(x, maxY, dx: 0, dy: 1)
                        }
                        for y in stride(
                            from: minY + borderMargin,
                            through: maxY - borderMargin,
                            by: 2
                        ) {
                            sampleOutline(minX, y, dx: 1, dy: 0)
                            sampleOutline(maxX, y, dx: 1, dy: 0)
                        }
                    }
                    let borderCoverage = outlineSamples > 0
                        ? Double(outlineHits) / Double(outlineSamples)
                        : 0
                    chromeEvidence.borderCoverage = borderCoverage
                    check(
                        "recording-ui: the selection border and handles are on screen",
                        borderCoverage >= 0.9,
                        "outline=\(outlineHits)/\(outlineSamples) "
                            + "(\(String(format: "%.1f", borderCoverage * 100))%) "
                            + "veilRatio=\(String(format: "%.3f", veilRatio))"
                    )

                    // The eight handles: white discs on the corners and edge
                    // midpoints of the selection.
                    // Four corners + four edge midpoints = the eight handles.
                    let handleCentres: [CGPoint] = [
                        CGPoint(x: region.minX, y: region.minY),
                        CGPoint(x: region.midX, y: region.minY),
                        CGPoint(x: region.maxX, y: region.minY),
                        CGPoint(x: region.minX, y: region.midY),
                        CGPoint(x: region.maxX, y: region.midY),
                        CGPoint(x: region.minX, y: region.maxY),
                        CGPoint(x: region.midX, y: region.maxY),
                        CGPoint(x: region.maxX, y: region.maxY)
                    ]
                    var handleHits = 0
                    for centre in handleCentres {
                        let mapped = pixelRect(
                            of: CGRect(x: centre.x, y: centre.y, width: 1, height: 1),
                            in: liveRect,
                            scale: rawScale
                        )
                        let px = Int(mapped.midX)
                        let py = Int(mapped.midY)
                        var found = false
                        for dy in -4...4 where !found {
                            for dx in -4...4 where !found {
                                if isChromeWhite(livePixels, px + dx, py + dy) {
                                    found = true
                                }
                            }
                        }
                        if found { handleHits += 1 }
                    }
                    chromeEvidence.handles = handleHits
                    check(
                        "recording-ui: all eight resize handles are on screen",
                        handleHits == handleCentres.count,
                        "handles=\(handleHits)/\(handleCentres.count)"
                    )

                    // The HUD: white controls + the red dot.
                    //
                    // Its capsule is 76 % black, so whatever the desktop shows
                    // through it is bounded: black under a white page is 38,
                    // and even a fully red desktop under the capsule cannot
                    // reach r ≥ 70. That makes "white controls" and "clearly
                    // red dot" absolute evidence *inside the HUD's own frame*
                    // on any backdrop — the old check instead compared the
                    // count against the chrome-free reference, which is 32 k
                    // white pixels on a white desktop and can never be beaten.
                    //
                    // The calibrated residual supplies the other half: it is
                    // large wherever the capsule or its contents replaced the
                    // veiled desktop, and zero when the HUD is not there.
                    var hudWhite = 0
                    var hudResidual = 0
                    var hudRed = 0
                    // The capsule is a rounded rect inside a square panel, so
                    // the panel's corners are transparent and would show a red
                    // desktop as "red". The dot sits on the capsule's vertical
                    // centre line, where the capsule is opaque, so only count
                    // red in the middle half of the panel height.
                    let hudMiddleTop = Int(
                        (hudInLive.minY + hudInLive.height / 4).rounded(.down)
                    )
                    let hudMiddleBottom = Int(
                        (hudInLive.maxY - hudInLive.height / 4).rounded(.up)
                    )
                    for y in Int(hudInLive.minY)..<Int(hudInLive.maxY) {
                        for x in Int(hudInLive.minX)..<Int(hudInLive.maxX) {
                            guard x >= 0, y >= 0,
                                  x < livePixels.width, y < livePixels.height,
                                  x < referencePixels.width, y < referencePixels.height
                            else { continue }
                            if isChromeWhite(livePixels, x, y) { hudWhite += 1 }
                            let residual = abs(
                                luma(livePixels, x, y)
                                    - veilRatio * luma(referencePixels, x, y)
                            )
                            if residual >= 30 { hudResidual += 1 }
                            // The dot pulses between full and 35 % alpha;
                            // 35 % of systemRed over the black capsule is a
                            // dark red, so ask for "clearly red", not "bright".
                            guard y >= hudMiddleTop, y < hudMiddleBottom else { continue }
                            let (r, g, b) = livePixels.rgb(x: x, y: y)
                            if r >= 70, r - g >= 25, r - b >= 25 { hudRed += 1 }
                        }
                    }
                    chromeEvidence.hudWhite = hudWhite
                    chromeEvidence.hudResidual = hudResidual
                    chromeEvidence.hudRed = hudRed
                    check(
                        "recording-ui: the HUD's controls and red dot are on screen",
                        hudResidual >= 1000 && hudWhite > 150 && hudRed > 20,
                        "hudResidual=\(hudResidual) hudWhite=\(hudWhite) "
                            + "hudRed=\(hudRed)"
                    )
                } else {
                    check(
                        "recording-ui: the veil still darkens the desktop outside the selection",
                        false
                    )
                    check("recording-ui: the selection border and handles are on screen", false)
                    check("recording-ui: all eight resize handles are on screen", false)
                    check("recording-ui: the HUD's controls and red dot are on screen", false)
                }

                try? await Task.sleep(nanoseconds: 2_200_000_000)
                motion.cancel()
                coordinator.stopRecording()
                var finished = false
                for _ in 0..<120 {
                    if coordinator.recordingState == .finished {
                        finished = true
                        break
                    }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
                check(
                    "recording-ui: 停止 ends the stream",
                    finished,
                    "state=\(coordinator.recordingState.rawValue)"
                )
                check(
                    "recording-ui: 停止 closes the selector and its HUD",
                    !controller.hasPanelsForTesting
                        && coordinator.recordingOverlayForTesting == nil
                        && controller.recordingIndicatorForTesting == nil
                        && hud?.panel == nil,
                    "panels=\(controller.hasPanelsForTesting) "
                        + "hudPanel=\(String(describing: hud?.panel))"
                )
                let written = (try? FileManager.default.contentsOfDirectory(
                    atPath: clipDirectory.path
                )) ?? []
                if let name = written.first(where: { $0.hasSuffix(".mp4") }) {
                    clipURL = clipDirectory.appendingPathComponent(name)
                }
                check(
                    "recording-ui: the 录制中 session wrote a clip",
                    clipURL != nil,
                    "files=\(written)"
                )
            } else {
                check("recording-ui: the selector presents a real panel", false)
            }
        } else {
            check("recording-ui: the recording overlay test gets isolated defaults", false)
        }

        // 3d. The video must not contain any of it. A live screenshot (own
        //     windows included) is the control: it *does* show the chrome, so a
        //     chrome-free video is a real exclusion and not an empty screen.
        if let url = clipURL {
            if let info = await inspectRecording(url) {
                let expected = CGSize(
                    width: (640 * rawScale).rounded(),
                    height: (400 * rawScale).rounded()
                )
                check(
                    "recording-ui: the clip is the region × scale",
                    abs(info.size.width - expected.width) <= 2
                        && abs(info.size.height - expected.height) <= 2,
                    "naturalSize=\(Int(info.size.width))×\(Int(info.size.height)) "
                        + "expected=\(Int(expected.width))×\(Int(expected.height))"
                )
                check(
                    "recording-ui: the clip covers about 3 s",
                    info.duration >= 2.0,
                    "duration=\(String(format: "%.3f", info.duration))s"
                )
                check(
                    "recording-ui: the clip is H.264",
                    info.codec == "avc1",
                    "codec=\(info.codec)"
                )
            } else {
                check("recording-ui: the 录制中 clip is readable by AVURLAsset", false)
            }
            if let frameImage = videoFrame(of: url, at: 1.0) ?? firstFrame(of: url),
               let videoPixels = pixelBuffer(frameImage),
               let referencePixels = referenceBuffer {
                writePNG(
                    frameImage,
                    to: directory.appendingPathComponent(
                        "75-recording-ui-video-frame.png"
                    )
                )
                let regionInLive = pixelRect(
                    of: CGRect(
                        x: (screen.frame.midX - 320).rounded(),
                        y: (screen.frame.midY - 200).rounded(),
                        width: 640,
                        height: 400
                    ),
                    in: liveRect,
                    scale: rawScale
                )
                let referenceOriginX = Int(regionInLive.minX.rounded())
                let referenceOriginY = Int(regionInLive.minY.rounded())
                func videoColor(_ x: Int, _ y: Int) -> (Int, Int, Int) {
                    videoPixels.rgb(x: x, y: y)
                }
                func referenceColor(_ x: Int, _ y: Int) -> (Int, Int, Int) {
                    referencePixels.rgb(
                        x: referenceOriginX + x,
                        y: referenceOriginY + y
                    )
                }
                func isWhite(_ c: (Int, Int, Int)) -> Bool {
                    c.0 >= 190 && c.1 >= 190 && c.2 >= 190
                }
                // The user's check: four pixels inwards from every side.
                let videoWidth = videoPixels.width
                let videoHeight = videoPixels.height
                var videoWhite = 0
                var referenceWhite = 0
                var videoRed = 0
                var edgeDelta = 0.0
                var edgeSamples = 0
                for y in 0..<videoHeight {
                    for x in 0..<videoWidth {
                        let edge = x < 4 || y < 4
                            || x >= videoWidth - 4 || y >= videoHeight - 4
                        guard edge else { continue }
                        let v = videoColor(x, y)
                        let r = referenceColor(x, y)
                        if isWhite(v) { videoWhite += 1 }
                        if isWhite(r) { referenceWhite += 1 }
                        if v.0 >= 170, v.1 <= 120, v.2 <= 120 { videoRed += 1 }
                        edgeDelta += abs(Double(v.0 - r.0))
                            + abs(Double(v.1 - r.1))
                            + abs(Double(v.2 - r.2))
                        edgeSamples += 1
                    }
                }
                let meanEdgeDelta = edgeSamples > 0
                    ? edgeDelta / Double(edgeSamples) / 3
                    : 999
                // A leaked border is a straight line on the outermost rows or
                // columns, so the strongest *mean* deviation of those rows and
                // columns is the line detector. Absolute white counts cannot do
                // this job: on a white desktop the video legitimately has
                // 16 k white pixels in its edge band (they are the page).
                //
                // The video and the screenshot travel through different colour
                // profiles, so a saturated desktop shifts by tens of levels
                // even when the content is identical (a teal page measured
                // +27 red). Measure that shift on the interior — the chrome
                // band cannot reach 16 px inside — and remove it per channel
                // before asking whether the edge carries a line.
                var channelShiftSum = (r: 0.0, g: 0.0, b: 0.0)
                var channelShiftSamples = 0.0
                for y in stride(from: 16, to: videoHeight - 16, by: 4) {
                    for x in stride(from: 16, to: videoWidth - 16, by: 4) {
                        let v = videoColor(x, y)
                        let r = referenceColor(x, y)
                        channelShiftSum.r += Double(v.0 - r.0)
                        channelShiftSum.g += Double(v.1 - r.1)
                        channelShiftSum.b += Double(v.2 - r.2)
                        channelShiftSamples += 1
                    }
                }
                let channelShift = (
                    r: channelShiftSamples > 0
                        ? channelShiftSum.r / channelShiftSamples : 0,
                    g: channelShiftSamples > 0
                        ? channelShiftSum.g / channelShiftSamples : 0,
                    b: channelShiftSamples > 0
                        ? channelShiftSum.b / channelShiftSamples : 0
                )
                func edgeLineDelta(_ x: Int, _ y: Int) -> Double {
                    let v = videoColor(x, y)
                    let r = referenceColor(x, y)
                    return abs(
                        0.2126 * (Double(v.0 - r.0) - channelShift.r)
                            + 0.7152 * (Double(v.1 - r.1) - channelShift.g)
                            + 0.0722 * (Double(v.2 - r.2) - channelShift.b)
                    )
                }
                func edgeRowMean(_ y: Int) -> Double {
                    var sum = 0.0
                    for x in 0..<videoWidth { sum += edgeLineDelta(x, y) }
                    return sum / Double(max(1, videoWidth))
                }
                func edgeColumnMean(_ x: Int) -> Double {
                    var sum = 0.0
                    for y in 0..<videoHeight { sum += edgeLineDelta(x, y) }
                    return sum / Double(max(1, videoHeight))
                }
                var edgeLineMean = 0.0
                for y in 0..<4 { edgeLineMean = max(edgeLineMean, edgeRowMean(y)) }
                for y in (videoHeight - 4)..<videoHeight {
                    edgeLineMean = max(edgeLineMean, edgeRowMean(y))
                }
                for x in 0..<4 { edgeLineMean = max(edgeLineMean, edgeColumnMean(x)) }
                for x in (videoWidth - 4)..<videoWidth {
                    edgeLineMean = max(edgeLineMean, edgeColumnMean(x))
                }
                check(
                    "recording-ui: the video's 4 px edge band has no border or handle line",
                    chromeEvidence.borderCoverage >= 0.9 && edgeLineMean < 32,
                    "liveOutline="
                        + "\(String(format: "%.1f", chromeEvidence.borderCoverage * 100))% "
                        + "edgeLineMean=\(String(format: "%.1f", edgeLineMean)) "
                        + "videoWhite=\(videoWhite) referenceWhite=\(referenceWhite)"
                )
                check(
                    "recording-ui: the video's 4 px edge band matches the chrome-free screen",
                    edgeSamples > 1000 && meanEdgeDelta < 32,
                    "meanDelta=\(String(format: "%.1f", meanEdgeDelta)) "
                        + "samples=\(edgeSamples)"
                )
                check(
                    "recording-ui: no red HUD pixel reaches the video",
                    videoRed == 0,
                    "videoRed=\(videoRed)"
                )
                check(
                    "recording-ui: the live screenshot really did show the chrome "
                        + "(control for the edge check)",
                    chromeEvidence.borderCoverage >= 0.9
                        && chromeEvidence.handles == 8
                        && chromeEvidence.hudResidual >= 1000,
                    "liveOutline="
                        + "\(String(format: "%.1f", chromeEvidence.borderCoverage * 100))% "
                        + "handles=\(chromeEvidence.handles) "
                        + "hudResidual=\(chromeEvidence.hudResidual)"
                )
                print(
                    "[recording-ui] wrote 75-recording-ui-video-frame.png "
                        + "(\(videoWidth)×\(videoHeight) px) "
                        + "videoWhite=\(videoWhite) referenceWhite=\(referenceWhite) "
                        + "videoRed=\(videoRed)"
                )
            } else {
                check("recording-ui: the video has a readable frame", false)
                check(
                    "recording-ui: the video's 4 px edge band has no border or handle line",
                    false
                )
                check(
                    "recording-ui: the video's 4 px edge band matches the chrome-free screen",
                    false
                )
                check("recording-ui: no red HUD pixel reaches the video", false)
                check(
                    "recording-ui: the live screenshot really did show the chrome "
                        + "(control for the edge check)",
                    false
                )
            }
        }

        // The control bar itself, rendered for the "录制中" evidence shot.
        let hud = RecordingIndicatorView(
            frame: CGRect(origin: .zero, size: RecordingIndicatorPlacement.panelSize)
        )
        hud.update(state: .recording, elapsedText: "00:12")
        let hudCanvas = WhiteCanvasView(frame: hud.bounds)
        hudCanvas.addSubview(hud)
        if let hudImage = renderImage(of: hudCanvas) {
            writePNG(
                hudImage,
                to: directory.appendingPathComponent("71-recording-control-bar.png")
            )
            print("[recording] wrote 71-recording-control-bar.png")
        }
        hud.stopPulse()
        check(
            "recording: the control bar shows elapsed time and both controls",
            hud.elapsedText == "00:12" && hud.state == .recording
        )

        // 4. Illegal calls on a live recorder do not crash and do not stack.
        let idle = ScreenRecorder()
        check("recording: pause on an idle recorder is a no-op", idle.pause() == false && idle.state == .idle)
        check("recording: resume on an idle recorder is a no-op", idle.resume() == false && idle.state == .idle)
        do {
            _ = try await idle.stop()
            check("recording: stop on an idle recorder throws instead of crashing", false)
        } catch {
            check(
                "recording: stop on an idle recorder throws instead of crashing",
                (error as? RecordingError) == RecordingError.notRecording,
                "error=\(error.localizedDescription)"
            )
        }
        check("recording: idle recorder is reusable after a rejected stop", idle.state == .idle)
    }

    private static func fileSize(_ url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    // MARK: - T. Colour picker

    private static func runColorPickerTests(into directory: URL) {
        let orange = PickedColor(red: 255, green: 128, blue: 0)
        check("color: hex is FF8000", orange.hex == "FF8000", "hex=\(orange.hex)")
        check("color: hex string is #FF8000", orange.hexString == "#FF8000")
        check("color: rgb string is 255, 128, 0", orange.rgbString == "255, 128, 0", "rgb=\(orange.rgbString)")
        check(
            "color: hsl of #FF8000 is 30°, 100%, 50%",
            orange.hslString == "30°, 100%, 50%",
            "hsl=\(orange.hslString)"
        )
        check("color: HEX copy format", orange.string(for: .hex) == "#FF8000")
        check("color: RGB copy format", orange.string(for: .rgb) == "rgb(255, 128, 0)")
        check(
            "color: Tab toggles HEX → RGB → HEX",
            ColorPickFormat.hex.next == .rgb && ColorPickFormat.rgb.next == .hex
        )
        check(
            "color: extreme colours have sane HSL",
            PickedColor(red: 0, green: 0, blue: 0).hslString == "0°, 0%, 0%"
                && PickedColor(red: 255, green: 255, blue: 255).hslString == "0°, 0%, 100%",
            "black=\(PickedColor(red: 0, green: 0, blue: 0).hslString) "
                + "white=\(PickedColor(red: 255, green: 255, blue: 255).hslString)"
        )
        check(
            "color: out-of-range components clamp",
            PickedColor(red: -10, green: 300, blue: 0) == PickedColor(red: 0, green: 255, blue: 0)
        )

        // Known-colour image → sampler.
        guard let solid = makePixelImage(width: 16, height: 16, pixel: { _, _ in (255, 128, 0) }),
              let sampler = ColorSampler(image: solid) else {
            check("color: a known-colour image can be sampled", false)
            return
        }
        let sampled = sampler.color(atX: 8, y: 8)
        check(
            "color: sampler reads FF8000 / 255,128,0",
            sampled == orange && sampled?.hex == "FF8000" && sampled?.rgbString == "255, 128, 0",
            "sampled=\(sampled?.hex ?? "nil") rgb=\(sampled?.rgbString ?? "nil")"
        )
        let outsideLeft = sampler.color(atX: -500, y: 8)
        let outsideFar = sampler.color(atX: 99_999, y: -99_999)
        check(
            "color: off-image sample coordinates clamp instead of crashing",
            outsideLeft == orange && outsideFar == orange,
            "left=\(outsideLeft?.hex ?? "nil") far=\(outsideFar?.hex ?? "nil")"
        )

        // Global-point → pixel mapping with the bottom-left/top-left flip.
        guard let quadrants = makePixelImage(width: 20, height: 20, pixel: { x, y in
            if x < 10 && y < 10 { return (255, 0, 0) }
            if x >= 10 && y < 10 { return (0, 255, 0) }
            if x < 10 { return (0, 0, 255) }
            return (255, 255, 255)
        }) else {
            check("color: quadrant image can be built", false)
            return
        }
        let frame = CGRect(x: 100, y: 100, width: 10, height: 10)
        let snapshot = ScreenSnapshot(image: quadrants, screenFrame: frame)
        let topLeft = snapshot.color(atGlobalPoint: CGPoint(x: 102, y: 107))
        let topRight = snapshot.color(atGlobalPoint: CGPoint(x: 107, y: 107))
        let bottomLeft = snapshot.color(atGlobalPoint: CGPoint(x: 102, y: 102))
        let bottomRight = snapshot.color(atGlobalPoint: CGPoint(x: 107, y: 102))
        check(
            "color: snapshot maps global top-left to red",
            topLeft == PickedColor(red: 255, green: 0, blue: 0),
            "actual=\(topLeft?.hex ?? "nil")"
        )
        check(
            "color: snapshot maps global top-right to green",
            topRight == PickedColor(red: 0, green: 255, blue: 0),
            "actual=\(topRight?.hex ?? "nil")"
        )
        check(
            "color: snapshot maps global bottom-left to blue (Y flip)",
            bottomLeft == PickedColor(red: 0, green: 0, blue: 255),
            "actual=\(bottomLeft?.hex ?? "nil")"
        )
        check(
            "color: snapshot maps global bottom-right to white",
            bottomRight == PickedColor(red: 255, green: 255, blue: 255),
            "actual=\(bottomRight?.hex ?? "nil")"
        )
        let wayOutside = snapshot.color(atGlobalPoint: CGPoint(x: -5_000, y: 5_000))
        check(
            "color: off-screen global point clamps, no crash",
            wayOutside != nil,
            "actual=\(wayOutside?.hex ?? "nil")"
        )

        // Clipboard writing, on a private pasteboard.
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("UnseenSelfTest-\(UUID().uuidString)")
        )
        let hexText = ColorPickerClipboard.copy(orange, format: .hex, to: pasteboard)
        check(
            "color: click copies HEX text to the pasteboard",
            hexText == "#FF8000" && pasteboard.string(forType: .string) == "#FF8000",
            "text=\(pasteboard.string(forType: .string) ?? "nil")"
        )
        let rgbText = ColorPickerClipboard.copy(orange, format: .rgb, to: pasteboard)
        check(
            "color: RGB format switch changes the pasted text",
            rgbText == "rgb(255, 128, 0)" && pasteboard.string(forType: .string) == rgbText,
            "text=\(pasteboard.string(forType: .string) ?? "nil")"
        )
        pasteboard.clearContents()
        pasteboard.releaseGlobally()

        // Leave the known-colour swatch next to the other verification images.
        if let data = NSBitmapImageRep(cgImage: solid).representation(using: .png, properties: [:]) {
            try? data.write(to: directory.appendingPathComponent("color-picker-ff8000.png"))
        }
    }

    // MARK: - U. Key display

    private static func runKeyDisplayTests() {
        let cmdShift4 = KeyDisplayFormatter.text(modifiers: [.command, .shift], keyCode: UInt16(kVK_ANSI_4))
        check(
            "key display: ⌘ + ⇧ + 4",
            cmdShift4 == "⌘ + ⇧ + 4",
            "text=\(cmdShift4)"
        )
        check(
            "key display: NSEvent flags produce the same text",
            KeyDisplayFormatter.text(modifierFlags: [.command, .shift], keyCode: UInt16(kVK_ANSI_4))
                == cmdShift4
        )
        check(
            "key display: ⌘ + R",
            KeyDisplayFormatter.text(modifiers: [.command], keyCode: UInt16(kVK_ANSI_R)) == "⌘ + R",
            "text=\(KeyDisplayFormatter.text(modifiers: [.command], keyCode: UInt16(kVK_ANSI_R)))"
        )
        check(
            "key display: arrow keys use symbols",
            KeyDisplayFormatter.text(modifiers: [.command], keyCode: UInt16(kVK_LeftArrow)) == "⌘ + ←",
            "text=\(KeyDisplayFormatter.text(modifiers: [.command], keyCode: UInt16(kVK_LeftArrow)))"
        )
        check(
            "key display: space is rendered as 空格",
            KeyDisplayFormatter.text(modifiers: [], keyCode: UInt16(kVK_Space)) == "空格",
            "text=\(KeyDisplayFormatter.text(modifiers: [], keyCode: UInt16(kVK_Space)))"
        )
        check(
            "key display: modifier-only flags render just the symbols",
            KeyDisplayFormatter.text(modifiers: [.command, .shift], keyCode: UInt16(kVK_Shift)) == "⌘ + ⇧",
            "text=\(KeyDisplayFormatter.text(modifiers: [.command, .shift], keyCode: UInt16(kVK_Shift)))"
        )
        check(
            "key display: modifier order is ⌘ ⌃ ⌥ ⇧",
            KeyDisplayFormatter.text(
                modifiers: [.shift, .option, .control, .command],
                keyCode: UInt16(kVK_ANSI_S)
            ) == "⌘ + ⌃ + ⌥ + ⇧ + S",
            "text=\(KeyDisplayFormatter.text(modifiers: [.shift, .option, .control, .command], keyCode: UInt16(kVK_ANSI_S)))"
        )
        check(
            "key display: descriptor exposes the same text",
            KeyEventDescriptor(modifiers: [.command, .shift], keyCode: UInt16(kVK_ANSI_4)).displayText
                == "⌘ + ⇧ + 4"
        )

        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = KeyDisplayPlacement.panelSize(for: "⌘ + ⇧ + 4")
        let centred = KeyDisplayPlacement.origin(panelSize: size, screenFrame: frame, position: .bottomCenter)
        let right = KeyDisplayPlacement.origin(panelSize: size, screenFrame: frame, position: .bottomRight)
        check(
            "key display: bottom-centre vs bottom-right placement",
            abs(centred.x - (500 - size.width / 2)) < 0.5
                && abs(right.x - (1000 - size.width - 40)) < 0.5
                && centred.y == right.y
                && centred.x < right.x,
            "centre=\(NSStringFromPoint(centred)) right=\(NSStringFromPoint(right)) size=\(NSStringFromSize(size))"
        )

        // Graceful degradation: no Accessibility permission → no tap at all.
        let denied = KeyEventMonitor(permissionOverride: false)
        var fired = 0
        let installed = denied.start { _ in fired += 1 }
        check(
            "key display: without permission the tap is not installed",
            installed == false && denied.isInstalled == false && fired == 0
        )
        check(
            "key display: permission flag is queryable",
            denied.permission == .denied && denied.lastFailureReason=="需要辅助功能权限",
            "permission=\(denied.permission.rawValue) reason=\(denied.lastFailureReason ?? "nil")"
        )
        denied.stop()
        denied.stop()
        check("key display: stopping a never-installed monitor is safe", denied.isInstalled == false)

        let controller = KeyDisplayController(permissionOverride: false)
        let started = controller.start(position: .bottomRight, duration: 2)
        check(
            "key display: controller degrades without permission",
            started == false && controller.isActive == false
        )
        check("key display: no pill appears without permission", controller.isVisible == false)
        controller.stop()
        controller.stop()
        check("key display: controller stop is idempotent", controller.isActive == false)

        // The listener itself is only installable with the real grant; on a
        // machine without it this is reported as skipped rather than failed.
        if AXIsProcessTrusted() {
            let granted = KeyEventMonitor(permissionOverride: true)
            let liveInstalled = granted.start { _ in }
            check(
                "key display: granted permission installs a listen-only tap",
                liveInstalled && granted.isInstalled,
                "reason=\(granted.lastFailureReason ?? "none")"
            )
            granted.stop()
            check("key display: stop removes the tap", granted.isInstalled == false)
        } else {
            print("[key-display] SKIP: live CGEventTap (accessibility not granted to this process)")
        }

        // The pill itself is independent of the tap and can be exercised.
        let pill = KeyDisplayController(permissionOverride: false)
        pill.showText("⌘ + ⇧ + 4")
        check(
            "key display: pill shows the formatted shortcut",
            pill.isVisible && pill.currentText == "⌘ + ⇧ + 4",
            "visible=\(pill.isVisible) text=\(pill.currentText ?? "nil")"
        )
        pill.hide()
        check("key display: pill hides", pill.isVisible == false)
        pill.stop()
    }

    private static func approx(_ a: Double, _ b: Double, tolerance: Double = 0.001) -> Bool {
        abs(a - b) <= tolerance
    }

    // MARK: - Editable size chip (iShot: 提示条里修改长宽数值可以调整框选尺寸)

    /// One plate, one row: the left auxiliary group, the annotation tools, the
    /// action group and the pinned tail. Covers the plate geometry, the left
    /// group's order / alignment, the hairlines, hit testing, the chip's
    /// in-toolbar state, the shadow menu, the crosshair switch, drag/reset,
    /// hiding the aux group, and four offscreen renders
    /// (light / dark / flipped / hover). The chip's own click → edit → commit
    /// grammar is exercised in `runSizeChipTests` below.
    private static func runCaptureToolbarLayoutTests(into directory: URL) {
        print("[toolbar] --- ink: one plate, bare glyphs, hover feedback only ---")
        check(
            "toolbar: every icon is bare at rest",
            CaptureToolbarInk.restingFill == 0 && CaptureToolbarInk.restingStroke == 0
                && CaptureToolbarInk.restingGlyph < 1,
            "fill=\(CaptureToolbarInk.restingFill) stroke=\(CaptureToolbarInk.restingStroke) "
                + "glyph=\(CaptureToolbarInk.restingGlyph)"
        )
        check(
            "toolbar: the hover shape uses the shared ink ladder",
            CaptureToolbarInk.hoverFill == ToolbarInk.hoverFill
                && CaptureToolbarInk.hoverStroke == ToolbarInk.hoverStroke
                && abs(CaptureToolbarInk.hoverFill - 0.20) < 0.0001,
            "fill=\(CaptureToolbarInk.hoverFill) stroke=\(CaptureToolbarInk.hoverStroke)"
        )
        check(
            "toolbar: the compact row is 26 pt boxes in a 34 pt plate",
            CaptureToolbarView.buttonSize == 26
                && CaptureToolbarView.gap == 6
                && CaptureToolbarView.groupGap == 8
                && CaptureToolbarView.rowHeight == 34
                && CaptureToolbarView.horizontalPadding == 10,
            "button=\(CaptureToolbarView.buttonSize) gap=\(CaptureToolbarView.gap) "
                + "group=\(CaptureToolbarView.groupGap) height=\(CaptureToolbarView.rowHeight) "
                + "pad=\(CaptureToolbarView.horizontalPadding)"
        )
        check(
            "toolbar: the hover/selection shape is a 6 pt rounded square, not a disc",
            CaptureToolbarInk.controlCornerRadius >= 5
                && CaptureToolbarInk.controlCornerRadius <= 6
                && CaptureToolbarInk.controlInset * 2 < CaptureToolbarView.buttonSize,
            "radius=\(CaptureToolbarInk.controlCornerRadius) "
                + "inset=\(CaptureToolbarInk.controlInset) "
                + "button=\(CaptureToolbarView.buttonSize)"
        )
        // 1164 → 1038 pt for the canonical layout (76 pt chip, aux visible,
        // twelve tools): −126 pt from the 28 → 26 boxes and the 8 → 6 /
        // 10 → 8 gaps. `contentWidth` is the same function `preferredSize`
        // uses, so this is the real plate width, not a restatement of the
        // individual constants.
        let compactWidth = CaptureToolbarView.contentWidth(
            chipWidth: CaptureToolbarView.defaultChipWidth,
            auxVisible: true,
            toolCount: AnnotationTool.allCases.count
        )
        check(
            "toolbar: the compact plate is exactly 126 pt narrower than the 28 pt row",
            compactWidth == 1038 && compactWidth == 1164 - 126,
            "width=\(number(compactWidth)) old=1164"
        )
        check(
            "toolbar: the current tool is a hairline rounded-square ring, never a fill",
            CaptureToolbarInk.selectedStroke > 0
                && CaptureToolbarInk.selectedStroke > CaptureToolbarInk.hoverStroke,
            "selected=\(CaptureToolbarInk.selectedStroke) "
                + "hover=\(CaptureToolbarInk.hoverStroke)"
        )

        print("[toolbar] --- one plate: aux │ tools │ actions │ tail ---")
        CaptureToolbarView.auxRowVisibleOverrideForTesting = true
        let storedAux = UserDefaults.standard.object(
            forKey: CaptureToolbarView.auxRowVisibleDefaultsKey
        )
        defer {
            CaptureToolbarView.auxRowVisibleOverrideForTesting = nil
            if let storedAux {
                UserDefaults.standard.set(
                    storedAux,
                    forKey: CaptureToolbarView.auxRowVisibleDefaultsKey
                )
            } else {
                UserDefaults.standard.removeObject(
                    forKey: CaptureToolbarView.auxRowVisibleDefaultsKey
                )
            }
        }

        let bounds = CGRect(origin: .zero, size: canvasSize)
        let canvas = TestCanvasView(frame: bounds)
        let overlay = makeOverlay()
        canvas.addSubview(overlay)
        let initial = CGRect(x: 520, y: 350, width: 400, height: 220)
        overlay.applySelectionForTesting(initial)
        overlay.revealToolbarForTesting()

        let toolbarFrame = overlay.toolbarFrameForTesting
        let plate = overlay.toolbarRowOneFrameForTesting
        let aux = overlay.toolbarAuxFrameForTesting
        let chip = overlay.toolbarSizeChipFrameForTesting
        let stepDown = overlay.toolbarStepDownFrameForTesting
        let stepUp = overlay.toolbarStepUpFrameForTesting
        let shadowChip = overlay.toolbarShadowChipFrameForTesting
        let toggle = overlay.toolbarCrosshairSwitchFrameForTesting
        let toolFrames = overlay.toolbarToolFramesForTesting()
        let actionFrames = overlay.toolbarButtonFramesForTesting()
        let firstTool = toolFrames.min { $0.frame.minX < $1.frame.minX }?.frame ?? .zero

        check(
            "toolbar: the left auxiliary group is part of the default look",
            overlay.isAuxRowVisibleForTesting
        )
        check(
            "toolbar: the toolbar is one 34 pt row",
            abs(toolbarFrame.height - CaptureToolbarView.height) < 0.01
                && abs(CaptureToolbarView.height - 34) < 0.01,
            "height=\(number(toolbarFrame.height))"
        )
        check(
            "toolbar: the plate is the whole row, not a second capsule",
            abs(plate.height - toolbarFrame.height) < 0.01
                && abs(plate.width - toolbarFrame.width) < 0.01,
            "plate=\(format(plate)) toolbar=\(format(toolbarFrame))"
        )
        check(
            "toolbar: the plate is a fixed 12 pt rounded rectangle, not a capsule",
            CaptureToolbarView.cornerRadius == 12
                && CaptureToolbarView.cornerRadius < CaptureToolbarView.rowHeight / 2,
            "radius=\(CaptureToolbarView.cornerRadius) height=\(CaptureToolbarView.rowHeight)"
        )
        check(
            "toolbar: the live plate is the canonical width",
            abs(toolbarFrame.width - CaptureToolbarView.width) < 0.01,
            "width=\(number(toolbarFrame.width)) "
                + "canonical=\(number(CaptureToolbarView.width))"
        )
        check(
            "toolbar: the left group is steppers / chip / shadow / switch, left of the tools",
            aux.contains(chip)
                && stepDown.maxX <= chip.minX
                && stepUp.minX >= chip.maxX
                && shadowChip.minX > stepUp.maxX
                && toggle.minX > shadowChip.maxX
                && firstTool.minX > toggle.maxX,
            "aux=\(format(aux)) down=\(format(stepDown)) chip=\(format(chip)) "
                + "up=\(format(stepUp)) shadow=\(format(shadowChip)) "
                + "switch=\(format(toggle)) firstTool=\(format(firstTool))"
        )
        check(
            "toolbar: the left group hugs the plate's leading edge",
            abs(aux.minX - (toolbarFrame.minX + CaptureToolbarView.horizontalPadding)) < 0.01
                && aux.width > 200,
            "aux=\(format(aux)) toolbar=\(format(toolbarFrame))"
        )
        check(
            "toolbar: the chip uses the toolbar's light/dark ink",
            overlay.sizeChipAppearanceForTesting == "toolbar",
            overlay.sizeChipAppearanceForTesting
        )
        check(
            "toolbar: every left-group control shares the icons' centre line",
            [stepDown, stepUp, shadowChip, toggle, chip]
                .allSatisfy { abs($0.midY - plate.midY) < 0.01 },
            "plate.midY=\(number(plate.midY)) "
                + "ys=\([stepDown, stepUp, shadowChip, toggle, chip].map { number($0.midY) })"
        )
        let allIconFrames = toolFrames.map(\.frame)
            + actionFrames.map(\.frame)
            + [overlay.toolbarMoreFrameForTesting, overlay.toolbarDragHandleFrameForTesting]
        check(
            "toolbar: every icon is vertically centred in the one row",
            allIconFrames.allSatisfy { abs($0.midY - plate.midY) < 0.01 },
            "ys=\(Set(allIconFrames.map { number($0.midY) }))"
        )
        check(
            "toolbar: five hairlines split aux-size / shadow / switch / tools / actions / tail",
            overlay.toolbarSeparatorXsForTesting.count == 5,
            "xs=\(overlay.toolbarSeparatorXsForTesting.map(number))"
        )

        // Tail: ⋯ / pin / cancel / drag handle, in that order.
        let more = overlay.toolbarMoreFrameForTesting
        let pin = actionFrames.first { $0.action == .pin }?.frame ?? .zero
        let cancel = actionFrames.first { $0.action == .cancel }?.frame ?? .zero
        let handle = overlay.toolbarDragHandleFrameForTesting
        check(
            "toolbar: the tail is ⋯ / pin / cancel / handle",
            more.maxX <= pin.minX && pin.maxX <= cancel.minX && cancel.maxX <= handle.minX,
            "more=\(format(more)) pin=\(format(pin)) cancel=\(format(cancel)) "
                + "handle=\(format(handle))"
        )
        check(
            "toolbar: the drag handle is the last control",
            handle.maxX <= toolbarFrame.maxX - CaptureToolbarView.horizontalPadding + 0.01,
            "handle=\(format(handle)) toolbar=\(format(toolbarFrame))"
        )

        // Every tail / left-group control must claim its own rect.
        let hitTargets: [(String, CGPoint, NSView?)] = [
            ("⋯", CGPoint(x: more.midX, y: more.midY), overlay.hitTest(
                CGPoint(x: more.midX, y: more.midY))),
            ("pin", CGPoint(x: pin.midX, y: pin.midY), overlay.hitTest(
                CGPoint(x: pin.midX, y: pin.midY))),
            ("cancel", CGPoint(x: cancel.midX, y: cancel.midY), overlay.hitTest(
                CGPoint(x: cancel.midX, y: cancel.midY))),
            ("handle", CGPoint(x: handle.midX, y: handle.midY), overlay.hitTest(
                CGPoint(x: handle.midX, y: handle.midY)))
        ]
        for (name, point, hit) in hitTargets {
            check(
                "toolbar: \(name) receives its own click",
                hit != nil && hit !== overlay,
                "point=\(format(CGRect(origin: point, size: .zero))) "
                    + "hit=\(String(describing: hit.map { type(of: $0) }))"
            )
        }
        check(
            "toolbar: the handle is the drag-handle button",
            (overlay.hitTest(CGPoint(x: handle.midX, y: handle.midY))
                as? CaptureToolbarDragHandleButton) != nil
        )
        let auxHitTargets: [(String, CGPoint)] = [
            ("stepper-down", CGPoint(x: stepDown.midX, y: stepDown.midY)),
            ("stepper-up", CGPoint(x: stepUp.midX, y: stepUp.midY)),
            ("shadow", CGPoint(x: shadowChip.midX, y: shadowChip.midY)),
            ("switch", CGPoint(x: toggle.midX, y: toggle.midY))
        ]
        for (name, point) in auxHitTargets {
            let hit = overlay.hitTest(point)
            check(
                "toolbar: the \(name) control claims its rect",
                hit != nil && hit !== overlay,
                "point=\(format(CGRect(origin: point, size: .zero))) "
                    + "hit=\(String(describing: hit.map { type(of: $0) }))"
            )
        }
        // The chip is the overlay's sibling; its idle click must fall through
        // to the plate (the toolbar then calls the one editing grammar).
        let chipHit = overlay.hitTest(CGPoint(x: chip.midX, y: chip.midY))
        check(
            "toolbar: the idle size chip's click falls through to the plate",
            chipHit is CaptureToolbarView && chipHit !== overlay,
            "hit=\(String(describing: chipHit.map { type(of: $0) }))"
        )

        print("[toolbar] --- ⋯ menu ---")
        check(
            "toolbar: ⋯ holds 另存为, the aux-group toggle and reset",
            overlay.toolbarMoreMenuTitlesForTesting == [
                "另存为…", "隐藏左侧辅助控件", "重置工具栏位置"
            ],
            "titles=\(overlay.toolbarMoreMenuTitlesForTesting)"
        )
        var confirmed: CaptureToolbarAction?
        overlay.onConfirm = { _, _, action in confirmed = action }
        check(
            "toolbar: ⋯ → 另存为 runs the real saveAs action",
            overlay.performMoreMenuForTesting(title: "另存为…") && confirmed == .saveAs,
            "action=\(confirmed?.rawValue ?? "-")"
        )
        overlay.onConfirm = nil

        print("[toolbar] --- steppers: ±1 pt, Shift ±10 pt ---")
        overlay.applySelectionForTesting(initial)
        overlay.revealToolbarForTesting()
        overlay.sizeStepForTesting(shrink: false, shift: false)
        expect(
            "toolbar: ▶ adds 1 pt to both axes",
            overlay.selectionRectForTesting,
            CGRect(x: 519.5, y: 349.5, width: 401, height: 221)
        )
        overlay.sizeStepForTesting(shrink: true, shift: true)
        expect(
            "toolbar: ◀ with Shift removes 10 pt from both axes",
            overlay.selectionRectForTesting,
            CGRect(x: 524.5, y: 354.5, width: 391, height: 211)
        )
        overlay.applySelectionForTesting(CGRect(x: 700, y: 430, width: 40, height: 40))
        overlay.revealToolbarForTesting()
        overlay.sizeStepForTesting(shrink: true, shift: false)
        expect(
            "toolbar: the stepper cannot go below the 40 pt minimum",
            overlay.selectionRectForTesting,
            CGRect(x: 700, y: 430, width: 40, height: 40)
        )

        print("[toolbar] --- chip ⇄ editor, still one view ---")
        overlay.applySelectionForTesting(initial)
        overlay.revealToolbarForTesting()
        let readOnlyChip = overlay.toolbarSizeChipFrameForTesting.width
        let fullWidth = overlay.toolbarFrameForTesting.width
        overlay.tapSizeChipForTesting()
        check(
            "toolbar: the left-group chip opens the two-field editor",
            overlay.isSizeEditingForTesting && overlay.sizeEditFieldCountForTesting == 2,
            "editing=\(overlay.isSizeEditingForTesting) "
                + "fields=\(overlay.sizeEditFieldCountForTesting)"
        )
        check(
            "toolbar: the editor stays inside the plate and the plate keeps its height",
            overlay.toolbarFrameForTesting.contains(overlay.indicatorFrameForTesting)
                && abs(overlay.toolbarFrameForTesting.height - CaptureToolbarView.height) < 0.01,
            "toolbar=\(format(overlay.toolbarFrameForTesting)) "
                + "chip=\(format(overlay.indicatorFrameForTesting))"
        )
        check(
            "toolbar: the editor widens the plate instead of overlapping the tools",
            overlay.toolbarFrameForTesting.width > fullWidth + 20
                && overlay.toolbarSizeChipFrameForTesting.width > readOnlyChip,
            "full=\(number(fullWidth)) "
                + "editor=\(number(overlay.toolbarFrameForTesting.width)) "
                + "readOnlyChip=\(number(readOnlyChip)) "
                + "editorChip=\(number(overlay.toolbarSizeChipFrameForTesting.width))"
        )
        overlay.setSizeEditValuesForTesting(width: "640", height: "360")
        overlay.keyDown(with: keyEvent(keyCode: 36, modifiers: []))
        check(
            "toolbar: Return commits the size from the left-group editor",
            sameRect(
                overlay.selectionRectForTesting,
                CGRect(x: 400, y: 280, width: 640, height: 360)
            ) && !overlay.isSizeEditingForTesting,
            "rect=\(format(overlay.selectionRectForTesting))"
        )

        print("[toolbar] --- shadow menu → the real export preference ---")
        let suiteName = "UnseenToolbar-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            check("toolbar: create isolated defaults", false)
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.captureShadowEnabled = false

        let shadowOverlay = makeOverlay(settings: settings)
        canvas.addSubview(shadowOverlay)
        shadowOverlay.applySelectionForTesting(initial)
        shadowOverlay.revealToolbarForTesting()
        check(
            "toolbar: the menu starts on 无阴影",
            shadowOverlay.toolbarShadowLevelForTesting == .none,
            "level=\(shadowOverlay.toolbarShadowLevelForTesting)"
        )
        shadowOverlay.selectShadowLevelForTesting(.medium)
        check(
            "toolbar: 中等 writes captureShadowEnabled + 16 pt",
            settings.captureShadowEnabled && abs(settings.captureShadowSize - 16) < 0.001,
            "enabled=\(settings.captureShadowEnabled) size=\(settings.captureShadowSize)"
        )
        check(
            "toolbar: the chip follows the chosen level",
            shadowOverlay.toolbarShadowLevelForTesting == .medium
        )
        shadowOverlay.selectShadowLevelForTesting(.none)
        check(
            "toolbar: 无阴影 clears the export toggle",
            !settings.captureShadowEnabled,
            "enabled=\(settings.captureShadowEnabled)"
        )
        settings.captureShadowEnabled = true
        settings.captureShadowSize = 12
        let remapped = makeOverlay(settings: settings)
        canvas.addSubview(remapped)
        remapped.applySelectionForTesting(initial)
        remapped.revealToolbarForTesting()
        check(
            "toolbar: a stored 12 pt shadow reads as 轻微",
            remapped.toolbarShadowLevelForTesting == .light,
            "level=\(remapped.toolbarShadowLevelForTesting)"
        )
        check(
            "toolbar: the decoration the export would use keeps the chosen size",
            abs(settings.screenshotDecoration.shadowSize - 12) < 0.001,
            "shadow=\(settings.screenshotDecoration.shadowSize)"
        )

        print("[toolbar] --- crosshair switch → the real preference ---")
        settings.showCrosshair = true
        let crossOverlay = makeOverlay(settings: settings, showCrosshair: true)
        canvas.addSubview(crossOverlay)
        crossOverlay.applySelectionForTesting(initial)
        crossOverlay.revealToolbarForTesting()
        check(
            "toolbar: the switch starts on with 显示十字线",
            crossOverlay.toolbarCrosshairSwitchOnForTesting
                && crossOverlay.isCrosshairVisibleForTesting,
            "on=\(crossOverlay.toolbarCrosshairSwitchOnForTesting) "
                + "visible=\(crossOverlay.isCrosshairVisibleForTesting)"
        )
        crossOverlay.toggleCrosshairSwitchForTesting()
        check(
            "toolbar: switching off hides the crosshair and stores the preference",
            !settings.showCrosshair
                && !crossOverlay.isCrosshairVisibleForTesting
                && !crossOverlay.toolbarCrosshairSwitchOnForTesting,
            "setting=\(settings.showCrosshair) "
                + "visible=\(crossOverlay.isCrosshairVisibleForTesting)"
        )
        crossOverlay.toggleCrosshairSwitchForTesting()
        check(
            "toolbar: switching on restores both",
            settings.showCrosshair && crossOverlay.isCrosshairVisibleForTesting,
            "setting=\(settings.showCrosshair)"
        )

        print("[toolbar] --- drag handle and reset ---")
        overlay.applySelectionForTesting(initial)
        overlay.revealToolbarForTesting()
        let baseFrame = overlay.toolbarFrameForTesting
        overlay.dragToolbarForTesting(by: CGSize(width: 40, height: -26))
        let moved = overlay.toolbarFrameForTesting
        check(
            "toolbar: the handle moves the plate by the drag delta",
            abs(moved.minX - (baseFrame.minX + 40)) < 0.01
                && abs(moved.minY - (baseFrame.minY - 26)) < 0.01,
            "base=\(format(baseFrame)) moved=\(format(moved))"
        )
        overlay.dragToolbarForTesting(by: CGSize(width: 5000, height: 5000))
        let clamped = overlay.toolbarFrameForTesting
        check(
            "toolbar: a dragged plate is clamped inside the screen",
            clamped.maxX <= canvas.bounds.maxX - 8 + 0.01
                && clamped.maxY <= canvas.bounds.maxY - 8 + 0.01,
            format(clamped)
        )
        check(
            "toolbar: ⋯ → 重置工具栏位置 clears the drag",
            overlay.performMoreMenuForTesting(title: "重置工具栏位置")
                && overlay.toolbarUserOffsetForTesting == .zero
                && abs(overlay.toolbarFrameForTesting.minX - baseFrame.minX) < 0.01,
            "offset=\(overlay.toolbarUserOffsetForTesting)"
        )

        print("[toolbar] --- hiding the left aux group ---")
        let groupedWidth = overlay.toolbarFrameForTesting.width
        check(
            "toolbar: ⋯ → 隐藏左侧辅助控件 removes the group but keeps one bar",
            overlay.performMoreMenuForTesting(title: "隐藏左侧辅助控件")
                && !overlay.isAuxRowVisibleForTesting
                && abs(overlay.toolbarFrameForTesting.height - CaptureToolbarView.height) < 0.01
                && overlay.toolbarFrameForTesting.width < groupedWidth - 100,
            "aux=\(overlay.isAuxRowVisibleForTesting) "
                + "frame=\(format(overlay.toolbarFrameForTesting)) grouped=\(number(groupedWidth))"
        )
        let strippedTool = overlay.toolbarToolFramesForTesting()
            .min { $0.frame.minX < $1.frame.minX }?.frame ?? .zero
        check(
            "toolbar: with the group hidden the tools start at the plate's leading edge",
            abs(strippedTool.minX
                - (overlay.toolbarFrameForTesting.minX + CaptureToolbarView.horizontalPadding))
                < 0.01,
            "tool=\(format(strippedTool)) toolbar=\(format(overlay.toolbarFrameForTesting))"
        )
        check(
            "toolbar: the chip returns to its floating spot, dodging the plate",
            overlay.isIndicatorVisibleForTesting
                && !overlay.toolbarFrameForTesting.contains(overlay.indicatorFrameForTesting)
                && !overlay.indicatorFrameForTesting.intersects(overlay.toolbarFrameForTesting)
                && overlay.sizeChipAppearanceForTesting == "floating",
            "chip=\(format(overlay.indicatorFrameForTesting)) "
                + "toolbar=\(format(overlay.toolbarFrameForTesting))"
        )
        check(
            "toolbar: ⋯ → 显示左侧辅助控件 restores the group and the canonical width",
            overlay.performMoreMenuForTesting(title: "显示左侧辅助控件")
                && overlay.isAuxRowVisibleForTesting
                && overlay.toolbarAuxFrameForTesting.contains(
                    overlay.toolbarSizeChipFrameForTesting
                )
                && abs(overlay.toolbarFrameForTesting.width - groupedWidth) < 0.01,
            "aux=\(overlay.isAuxRowVisibleForTesting) "
                + "frame=\(format(overlay.toolbarFrameForTesting))"
        )

        print("[toolbar] --- offscreen renders (light / dark / hover / flipped) ---")
        renderToolbarScenario(
            name: "16-toolbar-light",
            canvas: ToolbarLightCanvasView(frame: bounds),
            appearance: NSAppearance(named: .aqua),
            selection: CGRect(x: 380, y: 330, width: 680, height: 300),
            into: directory
        )
        renderToolbarScenario(
            name: "17-toolbar-dark",
            canvas: TestCanvasView(frame: bounds),
            appearance: NSAppearance(named: .darkAqua),
            selection: CGRect(x: 380, y: 330, width: 680, height: 300),
            into: directory
        )
        renderToolbarScenario(
            name: "18-toolbar-flipped",
            canvas: ToolbarLightCanvasView(frame: bounds),
            appearance: NSAppearance(named: .aqua),
            selection: CGRect(x: 380, y: 0, width: 680, height: 220),
            into: directory,
            expectFlipped: true
        )
        renderToolbarScenario(
            name: "19-toolbar-hover",
            canvas: ToolbarLightCanvasView(frame: bounds),
            appearance: NSAppearance(named: .aqua),
            selection: CGRect(x: 380, y: 330, width: 680, height: 300),
            hoveredTool: .rectangle,
            into: directory
        )
        runToolbarHoverProbe()
    }

    /// Render the real overlay (cacheDisplay) on a chosen desktop and
    /// appearance, then assert the plate edge is actually visible in the PNG.
    private static func renderToolbarScenario(
        name: String,
        canvas: NSView,
        appearance: NSAppearance?,
        selection: CGRect,
        hoveredTool: AnnotationTool? = nil,
        into directory: URL,
        expectFlipped: Bool = false
    ) {
        canvas.appearance = appearance
        let overlay = makeOverlay()
        canvas.addSubview(overlay)
        overlay.appearance = appearance
        overlay.applySelectionForTesting(selection)
        overlay.revealToolbarForTesting()
        if let hoveredTool {
            overlay.setToolHoverForTesting(hoveredTool, hovering: true)
        }
        overlay.layoutSubtreeIfNeeded()

        let toolbar = overlay.toolbarFrameForTesting
        let rowOne = overlay.toolbarRowOneFrameForTesting
        let aux = overlay.toolbarAuxFrameForTesting
        if expectFlipped {
            check(
                "\(name): the toolbar flips above a bottom selection",
                toolbar.minY >= selection.maxY,
                "toolbar=\(format(toolbar)) selection=\(format(selection))"
            )
        }
        check(
            "\(name): the whole one-row plate is inside the screen",
            canvas.bounds.contains(toolbar)
                && abs(rowOne.height - CaptureToolbarView.rowHeight) < 0.01,
            "toolbar=\(format(toolbar)) rowOne=\(format(rowOne))"
        )
        check(
            "\(name): the left auxiliary group is inside the plate",
            aux.width > 200 && toolbar.contains(aux),
            "aux=\(format(aux)) toolbar=\(format(toolbar))"
        )

        guard let representation = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
            check("\(name): render bitmap", false)
            return
        }
        canvas.cacheDisplay(in: canvas.bounds, to: representation)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            check("\(name): encode PNG", false)
            return
        }
        let url = directory.appendingPathComponent("\(name).png")
        do {
            try png.write(to: url)
            print("[toolbar] wrote \(url.path) "
                + "(\(representation.pixelsWide)×\(representation.pixelsHigh) px)")
            copyToVerification(png, named: "overlay-\(name).png")
            check("\(name): the render has real pixels", png.count > 4_000, "bytes=\(png.count)")
        } catch {
            check("\(name): write PNG", false, error.localizedDescription)
            return
        }

        guard let image = representation.cgImage else {
            check("\(name): bitmap to CGImage", false)
            return
        }
        let scale = CGFloat(representation.pixelsWide) / canvas.bounds.width
        let sampleX = Int((rowOne.midX * scale).rounded())
        let edgeY = Int(((canvas.bounds.height - rowOne.maxY) * scale).rounded())
        var samples: [Int] = []
        for offset in -4...5 {
            if let value = pixel(image, x: sampleX, y: edgeY + offset) {
                samples.append((value.r + value.g + value.b) / 3)
            }
        }
        guard samples.count == 10 else {
            check("\(name): the plate edge is inside the bitmap", false)
            return
        }
        let outside = samples[0]
        let inside = samples[9]
        let darkest = samples.min() ?? 0
        let brightest = samples.max() ?? 0
        print("[toolbar] \(name) edge samples=\(samples) outside=\(outside) inside=\(inside)")
        if appearance?.name == .darkAqua {
            check(
                "\(name): the dark plate edge stays visible",
                brightest > inside + 6 && brightest > outside + 6,
                "samples=\(samples)"
            )
        } else {
            check(
                "\(name): the light plate edge stays visible",
                inside > outside + 8 && darkest < inside - 6,
                "samples=\(samples) outside=\(outside) inside=\(inside)"
            )
        }
    }

    /// Pixel proof of the pin-toolbar rule: no disc at rest, one disc under the
    /// pointer, and no change anywhere else on the plate.
    private static func runToolbarHoverProbe() {
        print("[toolbar] --- hover feedback probe ---")
        let bounds = CGRect(origin: .zero, size: canvasSize)
        let selection = CGRect(x: 380, y: 330, width: 680, height: 300)

        struct Probe {
            let image: CGImage
            let scale: CGFloat
            let plate: CGRect
            let frames: [AnnotationTool: CGRect]
        }

        func render(hovering: Bool) -> Probe? {
            let canvas = ToolbarLightCanvasView(frame: bounds)
            canvas.appearance = NSAppearance(named: .aqua)
            let overlay = makeOverlay()
            canvas.addSubview(overlay)
            overlay.appearance = NSAppearance(named: .aqua)
            overlay.applySelectionForTesting(selection)
            overlay.revealToolbarForTesting()
            if hovering {
                overlay.setToolHoverForTesting(.rectangle, hovering: true)
            }
            overlay.layoutSubtreeIfNeeded()
            var frames: [AnnotationTool: CGRect] = [:]
            for item in overlay.toolbarToolFramesForTesting() {
                frames[item.tool] = item.frame
            }
            guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
                return nil
            }
            canvas.cacheDisplay(in: canvas.bounds, to: rep)
            guard let image = rep.cgImage else { return nil }
            return Probe(
                image: image,
                scale: CGFloat(rep.pixelsWide) / canvas.bounds.width,
                plate: overlay.toolbarFrameForTesting,
                frames: frames
            )
        }

        func sample(_ probe: Probe, in frame: CGRect) -> Int? {
            // 4 pt in from the button's edge: inside the 22 pt rounded square,
            // outside the 13 pt glyph.
            let x = Int(((frame.minX + 4) * probe.scale).rounded())
            let y = Int(((bounds.height - frame.midY) * probe.scale).rounded())
            guard let value = pixel(probe.image, x: x, y: y) else { return nil }
            return (value.r + value.g + value.b) / 3
        }

        guard let rest = render(hovering: false),
              let hover = render(hovering: true),
              let rectangle = rest.frames[.rectangle],
              let ellipse = rest.frames[.ellipse],
              let plateRest = sample(rest, in: CGRect(
                x: rest.plate.minX + 6,
                y: rest.plate.minY,
                width: 1,
                height: rest.plate.height
              )),
              let iconRest = sample(rest, in: rectangle),
              let iconHover = sample(hover, in: rectangle),
              let otherRest = sample(rest, in: ellipse),
              let otherHover = sample(hover, in: ellipse)
        else {
            check("toolbar: the hover probe renders", false)
            return
        }

        check(
            "toolbar: a resting icon draws no shape of its own",
            abs(iconRest - plateRest) <= 4,
            "icon=\(iconRest) plate=\(plateRest)"
        )
        check(
            "toolbar: hovering one icon lifts only that icon",
            iconHover <= iconRest - 15,
            "rest=\(iconRest) hover=\(iconHover)"
        )
        check(
            "toolbar: the neighbouring icons stay bare under the pointer",
            abs(otherHover - otherRest) <= 1,
            "rest=\(otherRest) hover=\(otherHover)"
        )
    }

    private static func runSizeChipTests(into directory: URL) {
        let bounds = CGRect(origin: .zero, size: canvasSize)
        let canvas = TestCanvasView(frame: bounds)
        let overlay = makeOverlay()
        canvas.addSubview(overlay)

        func render(_ name: String) {
            guard let representation = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
                check("\(name): render bitmap", false)
                return
            }
            canvas.cacheDisplay(in: canvas.bounds, to: representation)
            guard let png = representation.representation(using: .png, properties: [:]) else {
                check("\(name): encode PNG", false)
                return
            }
            let url = directory.appendingPathComponent("\(name).png")
            do {
                try png.write(to: url)
                print(
                    "[size-chip] wrote \(url.path) "
                    + "(\(representation.pixelsWide)×\(representation.pixelsHigh) px)"
                )
                copyToVerification(png, named: "overlay-\(name).png")
                check("\(name): the render has real pixels", png.count > 2_000, "bytes=\(png.count)")
            } catch {
                check("\(name): write PNG", false, error.localizedDescription)
            }
        }

        func chipPoint(of target: CaptureOverlayView) -> CGPoint {
            let frame = target.indicatorFrameForTesting
            return CGPoint(x: frame.midX, y: frame.midY)
        }

        print("[size-chip] --- centre-anchored geometry ---")
        let initial = CGRect(x: 520, y: 350, width: 400, height: 220)
        expect(
            "size-chip geometry: 800×500 keeps the centre",
            SelectionBorderView.centeredResize(
                initial,
                to: CGSize(width: 800, height: 500),
                within: bounds
            ),
            CGRect(x: 320, y: 210, width: 800, height: 500)
        )
        expect(
            "size-chip geometry: 5000×5000 clamps to the screen",
            SelectionBorderView.centeredResize(
                initial,
                to: CGSize(width: 5000, height: 5000),
                within: bounds
            ),
            bounds
        )
        expect(
            "size-chip geometry: 10×10 clamps to the 40 pt minimum",
            SelectionBorderView.centeredResize(
                initial,
                to: CGSize(width: 10, height: 10),
                within: bounds
            ),
            CGRect(x: 700, y: 440, width: 40, height: 40)
        )
        expect(
            "size-chip geometry: a box grown against an edge shifts inside",
            SelectionBorderView.centeredResize(
                CGRect(x: 0, y: 0, width: 400, height: 220),
                to: CGSize(width: 800, height: 500),
                within: bounds
            ),
            CGRect(x: 0, y: 0, width: 800, height: 500)
        )

        print("[size-chip] --- enter / Tab / Escape ---")
        overlay.applySelectionForTesting(initial)
        let readOnlyWidth = overlay.indicatorFrameForTesting.width
        click(overlay, at: chipPoint(of: overlay))
        check("size-chip: a single click enters editing", overlay.isSizeEditingForTesting)
        check(
            "size-chip: the click does not start a new box",
            sameRect(overlay.selectionRectForTesting, initial),
            format(overlay.selectionRectForTesting)
        )
        check(
            "size-chip: the two fields are on screen",
            overlay.sizeEditFieldCountForTesting == 2,
            "fields=\(overlay.sizeEditFieldCountForTesting)"
        )
        check(
            "size-chip: width is prefilled and focused",
            overlay.sizeEditValuesForTesting.width == "400"
                && overlay.sizeEditActiveFieldForTesting == 0,
            "width='\(overlay.sizeEditValuesForTesting.width)' "
                + "focus=\(overlay.sizeEditActiveFieldForTesting)"
        )
        check(
            "size-chip: height is prefilled",
            overlay.sizeEditValuesForTesting.height == "220",
            "height='\(overlay.sizeEditValuesForTesting.height)'"
        )
        check(
            "size-chip: the chip grows into the editor",
            overlay.indicatorFrameForTesting.width > readOnlyWidth,
            "read-only=\(number(readOnlyWidth)) "
                + "editor=\(number(overlay.indicatorFrameForTesting.width))"
        )
        render("13-size-chip-editing")

        overlay.toggleSizeEditFieldForTesting()
        check(
            "size-chip: Tab moves focus to height",
            overlay.sizeEditActiveFieldForTesting == 1
        )
        overlay.toggleSizeEditFieldForTesting()
        check(
            "size-chip: Tab again returns to width",
            overlay.sizeEditActiveFieldForTesting == 0
        )

        // A digit must not reach the number-key ratio lock while typing.
        overlay.keyDown(with: digitEvent(1))
        check(
            "size-chip: a digit is not a ratio shortcut while editing",
            overlay.lockedAspectForTesting == nil && overlay.isSizeEditingForTesting,
            "locked=\(String(describing: overlay.lockedAspectForTesting))"
        )

        overlay.setSizeEditValuesForTesting(width: "900", height: "600")
        overlay.keyDown(with: keyEvent(keyCode: 53, modifiers: []))
        check("size-chip: Escape leaves editing", !overlay.isSizeEditingForTesting)
        check(
            "size-chip: Escape leaves the selection unchanged",
            sameRect(overlay.selectionRectForTesting, initial),
            format(overlay.selectionRectForTesting)
        )
        check(
            "size-chip: Escape restores the read-only chip",
            overlay.indicatorTextForTesting == "400 × 220"
                && overlay.sizeEditFieldCountForTesting == 0,
            "text='\(overlay.indicatorTextForTesting)'"
        )

        print("[size-chip] --- Return commits (and never captures) ---")
        var confirmCount = 0
        overlay.onConfirm = { _, _, _ in confirmCount += 1 }
        click(overlay, at: chipPoint(of: overlay))
        overlay.setSizeEditValuesForTesting(width: "800", height: "500")
        overlay.keyDown(with: keyEvent(keyCode: 36, modifiers: []))
        check(
            "size-chip: Return commits the typed size",
            sameRect(
                overlay.selectionRectForTesting,
                CGRect(x: 320, y: 210, width: 800, height: 500)
            ),
            format(overlay.selectionRectForTesting)
        )
        check(
            "size-chip: the chip shows the new size",
            overlay.indicatorTextForTesting == "800 × 500",
            "text='\(overlay.indicatorTextForTesting)'"
        )
        check(
            "size-chip: Return while editing does not capture",
            confirmCount == 0 && overlay.isIndicatorVisibleForTesting,
            "confirm=\(confirmCount)"
        )
        let actualHandles = overlay.selectionHandleCentresForTesting.map {
            "\(Int($0.x.rounded())),\(Int($0.y.rounded()))"
        }.sorted()
        let expectedHandles = [
            "320,210", "720,210", "1120,210", "1120,460",
            "1120,710", "720,710", "320,710", "320,460"
        ].sorted()
        check(
            "size-chip: all eight handles follow the new rectangle",
            actualHandles == expectedHandles,
            "handles=\(actualHandles)"
        )
        check(
            "size-chip: the toolbar and its left-group chip follow the rectangle",
            overlay.toolbarFrameForTesting.maxY <= overlay.selectionRectForTesting.minY
                && overlay.toolbarFrameForTesting.contains(overlay.indicatorFrameForTesting),
            "toolbar=\(format(overlay.toolbarFrameForTesting)) "
                + "chip=\(format(overlay.indicatorFrameForTesting))"
        )
        render("14-size-chip-commit")

        print("[size-chip] --- clamps ---")
        click(overlay, at: chipPoint(of: overlay))
        overlay.setSizeEditValuesForTesting(width: "5000", height: "5000")
        overlay.keyDown(with: keyEvent(keyCode: 36, modifiers: []))
        check(
            "size-chip: oversized input clamps to the screen",
            sameRect(overlay.selectionRectForTesting, bounds),
            format(overlay.selectionRectForTesting)
        )
        check(
            "size-chip: the chip reports the clamped size",
            overlay.indicatorTextForTesting == "1440 × 900",
            "text='\(overlay.indicatorTextForTesting)'"
        )
        render("15-size-chip-clamp")

        overlay.applySelectionForTesting(initial)
        click(overlay, at: chipPoint(of: overlay))
        overlay.setSizeEditValuesForTesting(width: "10", height: "10")
        overlay.keyDown(with: keyEvent(keyCode: 36, modifiers: []))
        check(
            "size-chip: undersized input clamps to 40×40",
            sameRect(
                overlay.selectionRectForTesting,
                CGRect(x: 700, y: 440, width: 40, height: 40)
            ),
            format(overlay.selectionRectForTesting)
        )

        print("[size-chip] --- click-away and forgiving input ---")
        overlay.applySelectionForTesting(initial)
        click(overlay, at: chipPoint(of: overlay))
        overlay.setSizeEditValuesForTesting(width: "800", height: "500")
        click(overlay, at: CGPoint(x: 100, y: 100))
        check(
            "size-chip: clicking elsewhere commits and is swallowed",
            !overlay.isSizeEditingForTesting
                && sameRect(
                    overlay.selectionRectForTesting,
                    CGRect(x: 320, y: 210, width: 800, height: 500)
                )
                && confirmCount == 0,
            "editing=\(overlay.isSizeEditingForTesting) "
                + format(overlay.selectionRectForTesting)
        )

        overlay.applySelectionForTesting(initial)
        click(overlay, at: chipPoint(of: overlay))
        overlay.setSizeEditValuesForTesting(width: "800", height: "abc")
        overlay.keyDown(with: keyEvent(keyCode: 36, modifiers: []))
        expect(
            "size-chip: a non-numeric axis keeps its old value",
            overlay.selectionRectForTesting,
            CGRect(x: 320, y: 350, width: 800, height: 220)
        )

        print("[size-chip] --- armed window ---")
        let armedOverlay = makeOverlay()
        let fixture = WindowCandidate(
            windowNumber: 801,
            bounds: CGRect(x: 200, y: 200, width: 320, height: 200),
            layer: 0,
            ownerPID: 8801,
            ownerName: "SizeChipFixture",
            windowName: "SizeChipFixture",
            isOwnedBySelf: false
        )
        armedOverlay.setWindowPickCandidatesForTesting([fixture])
        click(armedOverlay, at: CGPoint(x: 360, y: 300))
        check(
            "size-chip: the fixture window armed first",
            armedOverlay.armedWindowIDForTesting == 801
                && armedOverlay.isIndicatorVisibleForTesting,
            "armed=\(armedOverlay.armedWindowIDForTesting.map(String.init) ?? "-")"
        )
        click(armedOverlay, at: chipPoint(of: armedOverlay))
        check(
            "size-chip: the armed window's chip is editable",
            armedOverlay.isSizeEditingForTesting
                && armedOverlay.sizeEditValuesForTesting.width == "320"
                && armedOverlay.sizeEditValuesForTesting.height == "200",
            "editing=\(armedOverlay.isSizeEditingForTesting) "
                + "values=\(armedOverlay.sizeEditValuesForTesting)"
        )
        armedOverlay.setSizeEditValuesForTesting(width: "400", height: "300")
        armedOverlay.keyDown(with: keyEvent(keyCode: 36, modifiers: []))
        check(
            "size-chip: committing an armed chip promotes a normal selection",
            armedOverlay.armedWindowIDForTesting == nil
                && sameRect(
                    armedOverlay.selectionRectForTesting,
                    CGRect(x: 160, y: 150, width: 400, height: 300)
                ),
            "armed=\(armedOverlay.armedWindowIDForTesting.map(String.init) ?? "-") "
                + format(armedOverlay.selectionRectForTesting)
        )

        // The risky half is the real thing: a non-activating panel must still
        // hand focus to an NSTextField and let the field editor hold the value.
        // Offscreen views have no window, so this is checked on a real panel.
        print("[size-chip] --- live panel focus ---")
        if let screen = NSScreen.main {
            let controller = CaptureOverlayController(
                mode: .region,
                prefilledSelection: nil,
                showCrosshair: false
            )
            controller.presentPanelsForTesting(on: screen)
            if let view = controller.overlayViewsForTesting.first {
                view.applySelectionForTesting(CGRect(x: 200, y: 200, width: 400, height: 220))
                // The size chip travels with the toolbar, so the toolbar must
                // be revealed before its chip can take focus (the 0.5 s delay is
                // skipped here the way a click inside the delay would be).
                view.revealToolbarForTesting()
                view.beginSizeEditingForTesting()
                let firstEditor = view.window?.firstResponder as? NSTextView
                check(
                    "size-chip live: the panel hands focus to the width field",
                    firstEditor != nil && firstEditor?.string == "400",
                    "firstResponder=\(String(describing: view.window?.firstResponder.map { type(of: $0) })) "
                        + "text='\(firstEditor?.string ?? "nil")'"
                )
                view.toggleSizeEditFieldForTesting()
                let secondEditor = view.window?.firstResponder as? NSTextView
                check(
                    "size-chip live: Tab hands focus to the height field",
                    secondEditor != nil && secondEditor?.string == "220",
                    "text='\(secondEditor?.string ?? "nil")'"
                )
                view.setSizeEditValuesForTesting(width: "800", height: "500")
                view.keyDown(with: keyEvent(keyCode: 36, modifiers: []))
                check(
                    "size-chip live: Return commits and focus returns to the overlay",
                    sameRect(
                        view.selectionRectForTesting,
                        CGRect(x: 0, y: 60, width: 800, height: 500)
                    ) && view.window?.firstResponder === view,
                    format(view.selectionRectForTesting)
                )
                controller.close()
            } else {
                check("size-chip live: a panel exists", false)
            }
        } else {
            print("[size-chip] SKIP: no NSScreen for the live panel focus checks")
        }
    }

    // MARK: - Harness helpers

    private static func makeOverlay(
        settings: AppSettings? = nil,
        showCrosshair: Bool = false
    ) -> CaptureOverlayView {
        CaptureOverlayView(
            frame: CGRect(origin: .zero, size: canvasSize),
            mode: .region,
            prefilledSelection: nil,
            showCrosshair: showCrosshair,
            rendersOffscreen: true,
            settings: settings
        )
    }

    private static func drag(_ overlay: CaptureOverlayView, from start: CGPoint, to end: CGPoint) {
        stroke(overlay, points: [start, end])
    }

    private static func stroke(_ overlay: CaptureOverlayView, points: [CGPoint]) {
        guard let first = points.first, let last = points.last else { return }
        overlay.mouseDown(with: event(.leftMouseDown, at: first))
        for point in points.dropFirst() {
            overlay.mouseDragged(with: event(.leftMouseDragged, at: point))
        }
        overlay.mouseUp(with: event(.leftMouseUp, at: last))
    }

    private static func click(_ overlay: CaptureOverlayView, at point: CGPoint) {
        overlay.mouseDown(with: event(.leftMouseDown, at: point))
        overlay.mouseUp(with: event(.leftMouseUp, at: point))
    }

    private static func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    /// Mouse event carrying extra modifiers (Shift-click multi-window).
    private static func event(
        _ type: NSEvent.EventType,
        at point: CGPoint,
        modifiers: NSEvent.ModifierFlags
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    /// Digit key with the real character so the ratio handler can parse it.
    private static func digitEvent(_ digit: Int) -> NSEvent {
        let keyCodes: [Int: UInt16] = [
            0: 29, 1: 18, 2: 19, 3: 20, 4: 21, 5: 23,
            6: 22, 7: 26, 8: 28, 9: 25
        ]
        let text = String(digit)
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: text,
            charactersIgnoringModifiers: text,
            isARepeat: false,
            keyCode: keyCodes[digit] ?? 18
        )!
    }

    /// Synthetic scroll for the highlighter opacity handler and the pin's
    /// zoom / ⌘-opacity gestures.
    private static func scrollEvent(
        deltaY: CGFloat,
        modifiers: CGEventFlags = []
    ) -> NSEvent {
        let cg = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: Int32(deltaY),
            wheel2: 0,
            wheel3: 0
        )!
        // Always assign: a CGEvent created without flags inherits the *current*
        // global modifier state, so a harness that has just sent ⌘-combinations
        // would turn every "plain" wheel into a ⌘ wheel. The test must describe
        // the event it means, not the machine it runs on.
        cg.flags = modifiers
        return NSEvent(cgEvent: cg)!
    }

    /// Synthetic modifier change for the iShot "tap Control" toolbar toggle.
    private static func flagsEvent(_ modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 59
        )!
    }

    /// Synthetic ⌘Z / ⇧⌘Z. `charactersIgnoringModifiers` is always "z"; the
    /// overlay reads that plus the modifier flags.
    private static func keyEvent(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        characters: String = "z"
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    private static func sameRect(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 0.01) -> Bool {
        abs(a.origin.x - b.origin.x) <= tolerance
            && abs(a.origin.y - b.origin.y) <= tolerance
            && abs(a.width - b.width) <= tolerance
            && abs(a.height - b.height) <= tolerance
    }

    private static func colourDistance(
        _ value: (r: Int, g: Int, b: Int, a: Int),
        _ expected: (r: Int, g: Int, b: Int)
    ) -> Int {
        abs(value.r - expected.r) + abs(value.g - expected.g) + abs(value.b - expected.b)
    }

    private static func matches(
        _ value: (r: Int, g: Int, b: Int, a: Int),
        _ expected: (r: Int, g: Int, b: Int),
        tolerance: Int
    ) -> Bool {
        abs(value.r - expected.r) <= tolerance
            && abs(value.g - expected.g) <= tolerance
            && abs(value.b - expected.b) <= tolerance
    }

    /// A deterministic 600×400 "screenshot": blue field, light grid and a red
    /// centre block, so padding, clipping, shadows and centre preservation are
    /// all easy to see in the exported PNGs.
    private static func makeBeautifySourceImage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setFillColor(NSColor(srgbRed: 0.20, green: 0.40, blue: 0.80, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        context.setFillColor(NSColor(white: 0.88, alpha: 1).cgColor)
        for x in stride(from: 0, to: width, by: 50) {
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        for y in stride(from: 0, to: height, by: 50) {
            context.fill(CGRect(x: 0, y: y, width: width, height: 1))
        }

        context.setFillColor(NSColor(srgbRed: 0.86, green: 0.16, blue: 0.24, alpha: 1).cgColor)
        context.fill(CGRect(x: width / 2 - 100, y: height / 2 - 50, width: 200, height: 100))
        return context.makeImage()
    }

    private static func makeBaseImage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setFillColor(
            NSColor(srgbRed: 0.10, green: 0.16, blue: 0.24, alpha: 1).cgColor
        )
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(
            NSColor(srgbRed: 0.20, green: 0.30, blue: 0.42, alpha: 1).cgColor
        )
        context.fill(CGRect(x: 0, y: 0, width: width, height: 80))
        return context.makeImage()
    }

    /// A busy "desktop" for the 05-tools preview: a light surface covered in
    /// small saturated rectangles, like a dense UI full of text and icons.
    /// Averaging 20 px blocks over it produces visibly different tiles.
    private static func makeSnapshotImage(width: Int, height: Int) -> CGImage? {
        makeConfettiImage(width: width, height: height)
    }

    /// 720×480 base for the tools flatten test. The mosaic region carries the
    /// detailed pattern; everything else is flat dark, so red text and the
    /// yellow note bubble are unambiguous.
    private static func makeDetailedBaseImage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setFillColor(
            NSColor(srgbRed: 0.09, green: 0.12, blue: 0.18, alpha: 1).cgColor
        )
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Same pixel rect as the mosaic annotation in *top-left* space:
        // x 36…324, y 48…216. A CGContext is bottom-left origin, so the band
        // sits at y = height - 216 with the same height.
        if let pattern = makeConfettiImage(width: 288, height: 168) {
            context.draw(pattern, in: CGRect(x: 36, y: height - 216, width: 288, height: 168))
        }
        return context.makeImage()
    }

    /// Deterministic "UI screenshot" texture: light paper plus a few thousand
    /// small, strongly coloured rectangles. The rectangles are 2–8 px, so a
    /// 20 px mosaic block mixes them into its own shade.
    private static func makeConfettiImage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setFillColor(
            NSColor(srgbRed: 0.90, green: 0.90, blue: 0.87, alpha: 1).cgColor
        )
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let palette = [
            NSColor(srgbRed: 0.10, green: 0.16, blue: 0.26, alpha: 1),
            NSColor(srgbRed: 0.12, green: 0.42, blue: 0.85, alpha: 1),
            NSColor(srgbRed: 0.15, green: 0.72, blue: 0.82, alpha: 1),
            NSColor(srgbRed: 0.20, green: 0.72, blue: 0.38, alpha: 1),
            NSColor(srgbRed: 0.96, green: 0.50, blue: 0.12, alpha: 1),
            NSColor(srgbRed: 0.88, green: 0.18, blue: 0.22, alpha: 1)
        ].map(\.cgColor)

        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return seed >> 33
        }

        let count = max(800, width * height / 100)
        for _ in 0..<count {
            let x = Int(next() % UInt64(max(1, width)))
            let y = Int(next() % UInt64(max(1, height)))
            let w = 2 + Int(next() % 8)
            let h = 2 + Int(next() % 8)
            context.setFillColor(palette[Int(next() % UInt64(palette.count))])
            context.fill(CGRect(x: x, y: y, width: w, height: h))
        }
        return context.makeImage()
    }

    private struct PixelBuffer {
        let bytes: [UInt8]
        let width: Int
        let height: Int

        /// Top-left-origin RGB triple.
        func rgb(x: Int, y: Int) -> (Int, Int, Int) {
            let index = (y * width + x) * 4
            return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
        }
    }

    private static func pixelBuffer(_ image: CGImage) -> PixelBuffer? {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drew = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drew ? PixelBuffer(bytes: bytes, width: width, height: height) : nil
    }

    /// Read one top-left-origin RGBA pixel from a CGImage.
    private static func pixel(
        _ image: CGImage,
        x: Int,
        y: Int
    ) -> (r: Int, g: Int, b: Int, a: Int)? {
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drew = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        // A CGBitmapContext's data buffer starts at the image's top row, while
        // `draw(_:in:)` places the source's first row at the rect's top edge.
        // The caller speaks top-left, so the row is used directly.
        let index = (y * width + x) * 4
        return (
            Int(bytes[index]),
            Int(bytes[index + 1]),
            Int(bytes[index + 2]),
            Int(bytes[index + 3])
        )
    }

    /// Keep the two inspection PNGs next to the other verification images when
    /// the harness is launched from the repository root.
    private static func copyToVerification(_ data: Data, named name: String) {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Docs/verification", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            print("[verify] Docs/verification not found at \(directory.path); skipped \(name)")
            return
        }
        let url = directory.appendingPathComponent(name)
        do {
            try data.write(to: url)
            print("[verify] wrote \(url.path) (\(data.count) bytes)")
        } catch {
            print("[verify] failed to write \(url.path): \(error.localizedDescription)")
        }
    }

    /// `true` when `rect` is fully inside a `size`-sized render space.
    private static func inside(_ rect: CGRect, _ size: CGSize) -> Bool {
        rect.minX >= -0.01 && rect.minY >= -0.01
            && rect.maxX <= size.width + 0.01 && rect.maxY <= size.height + 0.01
    }

    /// Quantised colour buckets (RGB / 32) of the saturated pixels inside
    /// `rect`. Proves an emoji really rendered as a colour glyph: a monochrome
    /// fallback yields one or two buckets, 😀/🌈 yield many.
    private static func colourBuckets(in rect: CGRect, buffer: PixelBuffer) -> Set<Int> {
        var buckets: Set<Int> = []
        let x0 = max(0, Int(rect.minX))
        let x1 = min(buffer.width, Int(rect.maxX.rounded(.up)))
        let y0 = max(0, Int(rect.minY))
        let y1 = min(buffer.height, Int(rect.maxY.rounded(.up)))
        guard x1 > x0, y1 > y0 else { return buckets }
        for y in y0..<y1 {
            for x in x0..<x1 {
                let (r, g, b) = buffer.rgb(x: x, y: y)
                let maxC = max(r, g, b)
                let minC = min(r, g, b)
                guard maxC - minC > 40, maxC > 80 else { continue }
                buckets.insert((r / 32) * 64 + (g / 32) * 8 + (b / 32))
            }
        }
        return buckets
    }

    // MARK: - Assertions

    private static func expect(_ label: String, _ actual: CGRect, _ expected: CGRect) {
        let tolerance: CGFloat = 0.01
        let matches =
            abs(actual.origin.x - expected.origin.x) <= tolerance
            && abs(actual.origin.y - expected.origin.y) <= tolerance
            && abs(actual.width - expected.width) <= tolerance
            && abs(actual.height - expected.height) <= tolerance

        checks += 1
        if !matches { failures += 1 }
        print(
            "[handles] \(label) -> origin=(\(number(actual.origin.x)),\(number(actual.origin.y))) "
            + "size=(\(number(actual.width)),\(number(actual.height))) "
            + "expected origin=(\(number(expected.origin.x)),\(number(expected.origin.y))) "
            + "size=(\(number(expected.width)),\(number(expected.height))) "
            + (matches ? "PASS" : "FAIL")
        )
    }

    private static func check(_ label: String, _ condition: Bool, _ detail: String = "") {
        checks += 1
        if !condition { failures += 1 }
        let suffix = detail.isEmpty ? "" : " (\(detail))"
        print("[check] \(label): \(condition ? "PASS" : "FAIL")\(suffix)")
    }

    private static func format(_ rect: CGRect) -> String {
        "x=\(number(rect.origin.x)) y=\(number(rect.origin.y)) "
            + "w=\(number(rect.width)) h=\(number(rect.height))"
    }

    private static func number(_ value: CGFloat) -> String {
        String(format: "%.1f", value)
    }
}

/// Fake desktop behind the overlay so the dimming hole is visible in the PNG.
/// Test-only.
/// The three-mode capture page state, rendered offscreen for `08-window-mode`.
///
/// `.window` never presents the overlay, so the meaningful visual is the mode
/// list itself: all three entries with 窗口截图 selected. It mirrors the middle
/// column's copy and symbols rather than instantiating the whole `MainView`
/// (which would open the user's database and pasteboard monitor).
private struct CaptureModesPreview: View {
    let selected: CaptureMode

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("截图模式")
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 6)
                Text("\(CaptureMode.allCases.count) 种")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Divider()

            VStack(spacing: 2) {
                ForEach(CaptureMode.allCases) { mode in
                    let isSelected = mode == selected
                    HStack(spacing: 8) {
                        Image(systemName: mode.symbol)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(isSelected ? Color.white : Color.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(mode.title)
                                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            Text(mode.shortDetail)
                                .font(.system(size: 10))
                                .foregroundStyle(
                                    isSelected ? Color.white.opacity(0.75) : Color.secondary
                                )
                        }
                        Spacer(minLength: 4)
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isSelected ? Color.accentColor : Color.clear)
                    )
                }
            }

            Divider()

            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "command")
                    .font(.system(size: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text("区域 ⌃⌥⌘A")
                    Text("窗口 ⌃⌥⌘W")
                }
                .font(.system(size: 10))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.tertiary)

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(
            width: 440,
            height: 340,
            alignment: .topLeading
        )
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// One navigable row rendered offscreen with the hover state pinned, so the
/// harness can diff "idle" against "hover" pixels without a pointer. Mirrors
/// the navigation row: chip background + `hoverHighlight`, no local `onHover`.
private struct HoverProbeRow: View {
    let title: String
    let selected: Bool
    let hovering: Bool
    var enabled: Bool = true

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil.tip")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 16)
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .foregroundStyle(Color.primary)
        .background(SelectionBackground(selected: selected))
        .contentShape(Rectangle())
        .hoverHighlightForTesting(hovering, isSelected: selected, isEnabled: enabled)
    }
}

/// Light-mode desktop for the toolbar verification renders: a soft blue-grey
/// wallpaper with two fake windows and a few text rules. The capsule is drawn
/// as a 90 % window-background wash, so the desktop has to be mid-tone for the
/// fill and the `labelColor` hairline to be measurable in the PNG.
private final class ToolbarLightCanvasView: NSView {
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [
            NSColor(calibratedRed: 0.91, green: 0.94, blue: 0.98, alpha: 1),
            NSColor(calibratedRed: 0.72, green: 0.79, blue: 0.90, alpha: 1)
        ])?.draw(in: bounds, angle: -90)

        let panels = [
            CGRect(x: 90, y: 470, width: 560, height: 300),
            CGRect(x: 760, y: 520, width: 520, height: 240),
            CGRect(x: 260, y: 90, width: 760, height: 300)
        ]
        for (index, rect) in panels.enumerated() {
            NSColor.white.withAlphaComponent(index == 0 ? 0.60 : 0.45).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
            NSColor.black.withAlphaComponent(0.10).setStroke()
            let outline = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
            outline.lineWidth = 1
            outline.stroke()

            NSColor.black.withAlphaComponent(0.12).setFill()
            for row in 0..<5 {
                NSRect(
                    x: rect.minX + 24,
                    y: rect.maxY - 44 - CGFloat(row) * 26,
                    width: rect.width - 120 - CGFloat(row % 3) * 60,
                    height: 7
                ).fill()
            }
        }
    }
}

private final class TestCanvasView: NSView {
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.24, alpha: 1),
            NSColor(calibratedRed: 0.30, green: 0.22, blue: 0.38, alpha: 1)
        ])
        gradient?.draw(in: bounds, angle: -90)

        // A few fake "windows" make it obvious where the veil is and where the
        // hole is.
        let panels = [
            CGRect(x: 120, y: 480, width: 520, height: 260),
            CGRect(x: 760, y: 520, width: 460, height: 220),
            CGRect(x: 300, y: 120, width: 700, height: 240)
        ]
        for (index, rect) in panels.enumerated() {
            let alpha: CGFloat = index == 0 ? 0.20 : 0.12
            NSColor.white.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
            NSColor.white.withAlphaComponent(0.10).setStroke()
            let outline = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
            outline.lineWidth = 1
            outline.stroke()
        }

        NSColor.white.withAlphaComponent(0.07).setStroke()
        let grid = NSBezierPath()
        var x: CGFloat = 0
        while x <= bounds.width {
            grid.move(to: CGPoint(x: x, y: bounds.minY))
            grid.line(to: CGPoint(x: x, y: bounds.maxY))
            x += 48
        }
        var y: CGFloat = 0
        while y <= bounds.height {
            grid.move(to: CGPoint(x: bounds.minX, y: y))
            grid.line(to: CGPoint(x: bounds.maxX, y: y))
            y += 48
        }
        grid.lineWidth = 1
        grid.stroke()
    }
}

/// A plain white ground for the fade/opacity probe: a uniform background makes
/// the strip's translucency and its gradient measurable.
private final class WhiteCanvasView: NSView {
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
    }
}

/// One flat colour behind a probe view.
private final class FlatGroundView: NSView {
    var color: NSColor = .white {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
    }
}

/// A stand-in macOS arrow pointer for the offscreen evidence renders.
///
/// The self test cannot move the real cursor, and a recording overlay may not
/// look at it anyway. Drawing the pointer is how the "the mouse is over here
/// now, the selection is still there" half of a frozen-crosshair shot is
/// captured: the tip is a plain injected coordinate, not `NSEvent.mouseLocation`.
private final class TestPointerView: NSView {
    /// Pointer tip in this view's coordinates.
    var tip: CGPoint = .zero {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath()
        outline.move(to: tip)
        outline.line(to: CGPoint(x: tip.x, y: tip.y - 21))
        outline.line(to: CGPoint(x: tip.x + 5.5, y: tip.y - 15.5))
        outline.line(to: CGPoint(x: tip.x + 9.5, y: tip.y - 24))
        outline.line(to: CGPoint(x: tip.x + 13.5, y: tip.y - 22))
        outline.line(to: CGPoint(x: tip.x + 9.5, y: tip.y - 13.5))
        outline.line(to: CGPoint(x: tip.x + 16.5, y: tip.y - 13.5))
        outline.close()
        outline.lineJoinStyle = .round

        NSColor.white.setFill()
        outline.fill()
        NSColor.black.withAlphaComponent(0.9).setStroke()
        outline.lineWidth = 1.6
        outline.stroke()
    }
}

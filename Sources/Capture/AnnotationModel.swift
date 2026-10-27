import AppKit
import CoreGraphics
import CoreText

/// The annotation tools the overlay exposes. `move` is the selection transform
/// tool and deliberately lives in the same enum as the drawing tools so the
/// toolbar can render one mutually exclusive row.
///
/// Three interaction families:
///
/// * **drag** — arrow / rectangle / ellipse / line / pencil / highlighter /
///   mosaic paint a stroke between mouse-down and mouse-up;
/// * **inline field** — text / note wait for a click, open an `NSTextField` and
///   commit what was typed;
/// * **click placement** — counter stamps the next number immediately, sticker
///   opens the emoji picker and then stamps the chosen glyph.
///
/// P1b-1 added mosaic / text / note; P1b-2 adds counter and sticker, which is
/// why the tool row is now twelve buttons wide.
enum AnnotationTool: String, CaseIterable, Identifiable, Sendable {
    case move
    case arrow
    case rectangle
    case ellipse
    case line
    case pencil
    case highlighter
    case mosaic
    case text
    case note
    case counter
    case sticker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .move: "移动"
        case .arrow: "箭头"
        case .rectangle: "矩形"
        case .ellipse: "椭圆"
        case .line: "直线"
        case .pencil: "铅笔"
        case .highlighter: "高亮"
        case .mosaic: "马赛克"
        case .text: "文本"
        case .note: "步骤标注"
        case .counter: "序号"
        case .sticker: "贴纸"
        }
    }

    /// SF Symbol names. `hand.raised` for move is the same metaphor iShot uses
    /// for its pan tool; the rest are visually distinct at 13 pt.
    var symbol: String {
        switch self {
        case .move: "hand.raised"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .pencil: "scribble"
        case .highlighter: "highlighter"
        case .mosaic: "squareshape.split.2x2"
        case .text: "text.cursor"
        case .note: "note.text"
        case .counter: "number.circle"
        // `face.smiling` is a multi-layer symbol: the toolbar's single-colour
        // palette collapses it into a solid blob at 13 pt. The masks stay
        // legible as an outline and read as "sticker".
        case .sticker: "theatermasks"
        }
    }

    /// `true` for every tool that paints between mouse-down and mouse-up.
    /// `move` pans the selection; the click tools place one point instead.
    var isDrawingTool: Bool {
        self != .move && !isClickPlacement
    }

    /// Text and note share the inline input flow and differ only in rendering.
    var isTextTool: Bool { self == .text || self == .note }

    /// Tools that place a single anchor on click rather than dragging a stroke.
    /// Text/note then open an inline field, counter stamps immediately, sticker
    /// asks for an emoji first.
    var isClickPlacement: Bool { isTextTool || self == .counter || self == .sticker }

    /// Tools whose annotation is meaningless without a non-empty string.
    /// Counter and sticker build their own payload, so they are excluded.
    var requiresText: Bool { isTextTool }

    /// Freehand tools keep the whole sampled polyline; the other drawing tools
    /// only use the first and last point.
    var isFreehand: Bool { self == .pencil || self == .highlighter }

    /// Highlighter is rendered four times wider than the pencil (see
    /// `Annotation.effectiveLineWidth`), so its stored pen size matches the
    /// pencil and the marker ends up ~4× the pen stroke.
    var defaultLineWidth: CGFloat {
        switch self {
        case .move, .mosaic, .text, .note, .counter, .sticker: 0
        case .arrow, .line: 3
        case .rectangle, .ellipse: 2.5
        case .pencil: 2.5
        case .highlighter: 2.5
        }
    }

    /// Fixed sRGB colours rather than `systemRed`/`systemYellow`: the same value
    /// has to rasterise identically in the overlay (dark appearance) and in the
    /// exported bitmap (no appearance), and the self test checks the pixels.
    var defaultColor: NSColor {
        switch self {
        case .move: .white
        case .arrow: NSColor(srgbRed: 0.93, green: 0.20, blue: 0.22, alpha: 1)
        case .rectangle: NSColor(srgbRed: 0.13, green: 0.70, blue: 0.38, alpha: 1)
        case .ellipse: NSColor(srgbRed: 0.16, green: 0.47, blue: 0.96, alpha: 1)
        case .line: NSColor(srgbRed: 0.98, green: 0.62, blue: 0.10, alpha: 1)
        case .pencil: NSColor(srgbRed: 0.85, green: 0.20, blue: 0.75, alpha: 1)
        case .highlighter: NSColor(srgbRed: 1.00, green: 0.90, blue: 0.15, alpha: 1)
        case .mosaic: NSColor(srgbRed: 0.70, green: 0.70, blue: 0.70, alpha: 1)
        case .text: NSColor(srgbRed: 0.92, green: 0.14, blue: 0.16, alpha: 1)
        case .note: NSColor(srgbRed: 0.24, green: 0.19, blue: 0.06, alpha: 1)
        // Solid red badge with white digits, like iShot's counter tool.
        case .counter: NSColor(srgbRed: 0.93, green: 0.20, blue: 0.22, alpha: 1)
        // Never used as a tint: emoji are colour glyphs and ignore it.
        case .sticker: .white
        }
    }
}

/// One annotation, stored as a value type so the undo stack is just an array.
///
/// Geometry is **normalised to the selection** (0…1, top-left origin). That is
/// what makes an annotation follow the selection while a handle is dragged:
/// the normalised point does not change and the canvas simply multiplies by the
/// new selection size. It also makes the same value render correctly at overlay
/// point scale and at Retina pixel scale.
struct Annotation: Equatable {
    var tool: AnnotationTool

    /// Normalised points (0…1, top-left origin).
    /// - arrow / rectangle / ellipse / line: `[start, end]`
    /// - pencil / highlighter: the full sampled polyline
    var points: [CGPoint]

    var color: NSColor

    /// Stroke width in *points*. The renderer scales it when the target is a
    /// pixel buffer (Retina), so 3 pt stays 3 pt on screen and becomes 6 px at
    /// 2×.
    var lineWidth: CGFloat

    /// Text/note font size in points. `nil` keeps the renderer default, so old
    /// annotations and every non-text tool stay unchanged.
    var fontSize: CGFloat?

    /// Payload for `.text` / `.note` / `.counter` / `.sticker`. `nil` for every
    /// other tool; the store rejects a text annotation whose payload is empty.
    ///
    /// * `.text` / `.note` — the typed string
    /// * `.counter` — the decimal number (`"1"`, `"2"`, …)
    /// * `.sticker` — the emoji scalar sequence
    ///
    /// Reusing one string field keeps `Annotation` trivially `Equatable` and
    /// makes the undo stack a plain array; the tool discriminates the meaning.
    var text: String?

    init(
        tool: AnnotationTool,
        points: [CGPoint],
        color: NSColor,
        lineWidth: CGFloat,
        fontSize: CGFloat? = nil,
        text: String? = nil
    ) {
        self.tool = tool
        self.points = points
        self.color = color
        self.lineWidth = lineWidth
        self.fontSize = fontSize
        self.text = text
    }

    var requiresText: Bool { tool.requiresText }

    var hasText: Bool {
        !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Numeric payload of a `.counter` annotation, parsed from `text`.
    /// `nil` for every other tool (and for a malformed counter payload).
    var counterValue: Int? {
        guard tool == .counter, let text else { return nil }
        return Int(text)
    }

    /// Freehand tools use every point; the rest use the first and the last.
    var isFreehand: Bool { tool.isFreehand }

    /// Highlighter is a broad translucent marker, not a fat opaque pencil.
    var effectiveLineWidth: CGFloat {
        tool == .highlighter ? lineWidth * 4 : lineWidth
    }

    var effectiveAlpha: CGFloat {
        tool == .highlighter ? 0.35 : 1
    }

    var boundingRectNormalized: CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Reject a click that produced no visible stroke. Lengths are compared in
    /// the selection's *points* because the normalised space is anisotropic.
    func hasMinimumGeometry(in selectionSize: CGSize) -> Bool {
        let usable = points.filter { $0.x.isFinite && $0.y.isFinite }
        guard usable.count >= 2 else { return false }
        let scaled = usable.map {
            CGPoint(x: $0.x * selectionSize.width, y: $0.y * selectionSize.height)
        }
        var length: CGFloat = 0
        for index in 1..<scaled.count {
            length += hypot(scaled[index].x - scaled[index - 1].x,
                            scaled[index].y - scaled[index - 1].y)
        }
        return length >= 2.5
    }
}

// MARK: - Undo / redo

/// The annotation array plus its undo/redo history.
///
/// Undo pops the newest annotation into the redo stack; adding a new annotation
/// clears redo (the usual non-linear-history rule). No annotation mutation
/// exists in P1a, so snapshotting whole arrays would only duplicate storage.
///
/// **Counter high-water mark.** The next badge number is
/// `max(highest live counter, highest counter ever added) + 1`. The second
/// term is the important one: after undoing the "2" badge the live maximum is
/// 1, but the next badge must be 3, not 2 — otherwise a user who undoes a
/// misplaced badge ends up with two "2"s in one screenshot. Redo restores the
/// popped annotation without lowering the mark, so the numbering never
/// reuses a value within a session.
@MainActor
final class AnnotationStore {
    private(set) var annotations: [Annotation] = []
    private(set) var redoStack: [Annotation] = []

    /// Highest counter value this session has ever produced. Undo and redo do
    /// not touch it; `removeAll` (a fresh selection) resets it.
    private(set) var counterHighWater = 0

    /// Fired after every successful mutation so the canvas and the toolbar can
    /// refresh without the callers duplicating the wiring.
    var onChange: (() -> Void)?

    var canUndo: Bool { !annotations.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Number the next counter badge will carry.
    var nextCounterValue: Int {
        let live = annotations.compactMap(\.counterValue).max() ?? 0
        return max(counterHighWater, live) + 1
    }

    @discardableResult
    func add(_ annotation: Annotation) -> Bool {
        guard annotation.points.count >= 2 else { return false }
        if annotation.requiresText, !annotation.hasText { return false }
        annotations.append(annotation)
        if let value = annotation.counterValue {
            counterHighWater = max(counterHighWater, value)
        }
        redoStack.removeAll()
        onChange?()
        return true
    }

    @discardableResult
    func undo() -> Bool {
        guard let last = annotations.popLast() else { return false }
        redoStack.append(last)
        onChange?()
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard let restored = redoStack.popLast() else { return false }
        annotations.append(restored)
        onChange?()
        return true
    }

    func removeAll() {
        guard !annotations.isEmpty || !redoStack.isEmpty else {
            counterHighWater = 0
            return
        }
        annotations.removeAll()
        redoStack.removeAll()
        counterHighWater = 0
        onChange?()
    }
}

// MARK: - Rendering

/// Draws annotations in a **top-left origin, y-down** space of `renderSize`.
///
/// Callers set that space up (an overlay view flips around its selection, the
/// flattener flips around the image), which is why the same geometry works at
/// point scale and at pixel scale.
@MainActor
enum AnnotationRenderer {
    /// Effective font size of one text/note annotation, before the Retina
    /// scale. The annotation's own size wins so the style panel can change a
    /// single annotation without touching the renderer default.
    static func fontSize(of annotation: Annotation) -> CGFloat {
        annotation.fontSize ?? textFontSize
    }

    /// Text/note font size in points. The renderer multiplies it by `scale`, so
    /// 20 pt on screen becomes 40 px in a 2× export.
    static let textFontSize: CGFloat = 20

    /// Counter badge diameter in points (26 pt ≈ a comfortable 2-digit badge).
    static let counterDiameter: CGFloat = 26

    /// Digit size before fitting. 15 pt fits two digits in the 26 pt badge; a
    /// longer number is scaled down until it fits.
    static let counterFontSize: CGFloat = 15

    /// Sticker glyph size in points.
    static let stickerFontSize: CGFloat = 40

    /// Padding between note text and the bubble edge.
    static let notePadding: CGFloat = 7

    /// - Parameters:
    ///   - scale: target pixels per annotation point. `1` for overlay drawing,
    ///     `2` for a 2× Retina export.
    ///   - highlighterBlendMode: the overlay passes `.normal` because its
    ///     layer has a transparent backing store (there is no desktop in it to
    ///     multiply against); the flattener uses `.multiply`, which is what
    ///     makes the marker look like a real highlighter over the image.
    ///   - mosaic: pixels for `.mosaic`. Passing `nil` (snapshot unavailable)
    ///     draws the translucent placeholder instead, never a broken block.
    static func draw(
        _ annotations: [Annotation],
        in context: CGContext,
        renderSize: CGSize,
        scale: CGFloat,
        highlighterBlendMode: CGBlendMode = .multiply,
        mosaic: MosaicSource? = nil
    ) {
        guard renderSize.width > 0, renderSize.height > 0 else { return }

        for annotation in annotations {
            guard annotation.points.count >= 2 else { continue }
            let width = max(1, annotation.effectiveLineWidth * scale)
            let points = annotation.points.map {
                CGPoint(x: $0.x * renderSize.width, y: $0.y * renderSize.height)
            }
            let color = (annotation.color.usingColorSpace(.sRGB) ?? annotation.color)
                .withAlphaComponent(annotation.effectiveAlpha)
                .cgColor

            context.saveGState()
            defer { context.restoreGState() }

            switch annotation.tool {
            case .move:
                break

            case .arrow:
                strokeArrow(from: points[0], to: points[points.count - 1],
                            color: color, width: width, scale: scale, in: context)

            case .line:
                context.beginPath()
                context.move(to: points[0])
                context.addLine(to: points[points.count - 1])
                context.setStrokeColor(color)
                context.setLineWidth(width)
                context.setLineCap(.round)
                context.strokePath()

            case .rectangle:
                let box = rect(from: points[0], to: points[points.count - 1])
                let radius = min(6 * scale, width)
                context.addPath(CGPath(
                    roundedRect: box,
                    cornerWidth: radius,
                    cornerHeight: radius,
                    transform: nil
                ))
                context.setStrokeColor(color)
                context.setLineWidth(width)
                context.strokePath()

            case .ellipse:
                let box = rect(from: points[0], to: points[points.count - 1])
                context.setStrokeColor(color)
                context.setLineWidth(width)
                context.strokeEllipse(in: box)

            case .pencil:
                strokePolyline(points, color: color, width: width, in: context)

            case .highlighter:
                context.setBlendMode(highlighterBlendMode)
                strokePolyline(points, color: color, width: width, in: context)

            case .mosaic:
                drawMosaic(annotation, points: points, source: mosaic, scale: scale, in: context)

            case .text, .note:
                drawText(
                    annotation,
                    anchor: points[0],
                    renderSize: renderSize,
                    scale: scale,
                    in: context
                )

            case .counter:
                drawCounter(
                    annotation,
                    anchor: points[0],
                    renderSize: renderSize,
                    scale: scale,
                    in: context
                )

            case .sticker:
                drawSticker(
                    annotation,
                    anchor: points[0],
                    renderSize: renderSize,
                    scale: scale,
                    in: context
                )
            }
        }
    }

    /// Rasterise `base` plus annotations at the base image's pixel resolution.
    ///
    /// `referencePointSize` is the selection's logical size (points). The
    /// scale factor is derived from the **pixel** width divided by it, so a
    /// Retina shot's annotation lands at the right pixel and keeps the stroke
    /// width the user saw on screen.
    static func flattened(
        base: CGImage,
        annotations: [Annotation],
        referencePointSize: CGSize
    ) -> CGImage? {
        let width = base.width
        let height = base.height
        guard width > 0, height > 0 else { return nil }
        guard !annotations.isEmpty else { return base }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            // Keep the capture's own RGB space (many Macs capture in Display
            // P3). Forcing DeviceRGB would shift every colour in the image, not
            // just the annotation. Non-RGB sources fall back to sRGB.
            space: (base.colorSpace?.model == .rgb
                ? base.colorSpace! : CGColorSpaceCreateDeviceRGB()),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let pixelSize = CGSize(width: width, height: height)
        context.interpolationQuality = .high
        // The bitmap context is bottom-left origin, which is how CGImage wants
        // to be drawn so it comes out upright.
        context.draw(base, in: CGRect(origin: .zero, size: pixelSize))

        let referenceWidth = referencePointSize.width > 0
            ? referencePointSize.width
            : pixelSize.width
        let scale = CGFloat(width) / referenceWidth

        // Annotation geometry is top-left y-down, so it gets its own flip.
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        // The mosaic samples the captured image itself. Its mapping is the
        // trivial 1:1 normalised → pixel one, because `renderSize` *is* the
        // image's pixel size here.
        draw(
            annotations,
            in: context,
            renderSize: pixelSize,
            scale: scale,
            mosaic: MosaicSource.flattening(image: base, scale: scale)
        )
        context.restoreGState()

        return context.makeImage()
    }

    // MARK: - Mosaic

    private static func drawMosaic(
        _ annotation: Annotation,
        points: [CGPoint],
        source: MosaicSource?,
        scale: CGFloat,
        in context: CGContext
    ) {
        let destination = rect(from: points[0], to: points[points.count - 1])
        guard destination.width >= 1, destination.height >= 1 else { return }

        if let source,
           let pixelRect = source.pixelRect(annotation.boundingRectNormalized),
           let crop = source.image.cropping(to: pixelRect),
           let pixelated = Pixelator.pixelate(crop, blockSize: source.blockSizePixels) {
            context.saveGState()
            context.interpolationQuality = .none
            context.clip(to: destination)
            context.draw(pixelated, in: destination)
            context.restoreGState()
            return
        }

        // Degraded preview (no snapshot available): a translucent placeholder
        // that still shows *where* the mosaic will be. Export always has the
        // captured pixels, so it never takes this branch.
        context.saveGState()
        context.setFillColor(
            NSColor.white.withAlphaComponent(0.28).cgColor
        )
        context.fill(destination)
        context.setStrokeColor(
            NSColor.black.withAlphaComponent(0.55).cgColor
        )
        context.setLineWidth(max(1, 1.5 * scale))
        context.setLineDash(phase: 0, lengths: [4 * scale, 3 * scale])
        context.stroke(destination.insetBy(dx: 0.5 * scale, dy: 0.5 * scale))
        context.setLineDash(phase: 0, lengths: [])
        context.restoreGState()
    }

    // MARK: - Text metrics

    /// One laid-out line: the CTLine plus the numbers every placement and every
    /// assertion needs. Shared by the renderer and the self test so "where the
    /// text lands" has exactly one definition.
    struct TextRun {
        let line: CTLine
        let width: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
        let leading: CGFloat

        var lineHeight: CGFloat { ascent + descent + leading }
        /// Line-box rect with its top-left at `origin` (y-down space).
        func rect(at origin: CGPoint) -> CGRect {
            CGRect(
                origin: origin,
                size: CGSize(width: width, height: ascent + descent)
            )
        }
    }

    /// Build the line for one payload. `color == nil` leaves the colour
    /// unset — that is what makes emoji keep their colour glyphs (a foreground
    /// colour would only tint fallback text). `monospacedDigits` is for the
    /// counter, whose "1" and "8" must have the same width.
    static func textRun(
        _ string: String,
        fontSize: CGFloat,
        weight: NSFont.Weight,
        color: NSColor?,
        monospacedDigits: Bool = false
    ) -> TextRun? {
        guard !string.isEmpty, fontSize > 0 else { return nil }
        let font = monospacedDigits
            ? NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: weight)
            : NSFont.systemFont(ofSize: fontSize, weight: weight)
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if let color {
            attributes[.foregroundColor] = color
        }
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: string, attributes: attributes)
        )
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(
            CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        )
        return TextRun(
            line: line,
            width: width,
            ascent: ascent,
            descent: descent,
            leading: leading
        )
    }

    // MARK: - Geometry (shared by the renderer and the self test)

    /// Normalised anchor → the caller's y-down render space.
    static func anchorPoint(_ annotation: Annotation, renderSize: CGSize) -> CGPoint? {
        guard let point = annotation.points.first,
              point.x.isFinite, point.y.isFinite else { return nil }
        return CGPoint(x: point.x * renderSize.width, y: point.y * renderSize.height)
    }

    /// Badge circle of a `.counter`, kept fully inside the selection so a badge
    /// dropped on the border is nudged inward instead of clipped in half.
    static func counterRect(
        anchor: CGPoint,
        renderSize: CGSize,
        scale: CGFloat = 1
    ) -> CGRect {
        let diameter = counterDiameter * scale
        let maxX = max(0, renderSize.width - diameter)
        let maxY = max(0, renderSize.height - diameter)
        return CGRect(
            x: min(max(anchor.x - diameter / 2, 0), maxX),
            y: min(max(anchor.y - diameter / 2, 0), maxY),
            width: diameter,
            height: diameter
        )
    }

    /// Sticky-note bubble in the caller's y-down space. It is *pushed back*
    /// inside `renderSize` when the click is near the right / bottom edge, and
    /// only shrunk when it still would not fit — so the capture edge can never
    /// cut it.
    static func noteBubbleRect(
        _ annotation: Annotation,
        renderSize: CGSize,
        scale: CGFloat = 1
    ) -> CGRect? {
        guard annotation.tool == .note,
              let text = annotation.text,
              let run = textRun(
                  text,
                  fontSize: fontSize(of: annotation) * scale,
                  weight: .semibold,
                  color: nil
              ),
              let anchor = anchorPoint(annotation, renderSize: renderSize)
        else { return nil }
        return notePlacement(
            run: run,
            anchor: anchor,
            renderSize: renderSize,
            scale: scale
        ).bubble
    }

    /// Line-box rect of `.text` / `.note` (top-left origin, y-down). For a note
    /// this is the text inside the bubble, padding included.
    static func textLineRect(
        _ annotation: Annotation,
        renderSize: CGSize,
        scale: CGFloat = 1
    ) -> CGRect? {
        guard annotation.tool.isTextTool,
              let text = annotation.text,
              let run = textRun(
                  text,
                  fontSize: fontSize(of: annotation) * scale,
                  weight: .semibold,
                  color: nil
              ),
              let anchor = anchorPoint(annotation, renderSize: renderSize)
        else { return nil }
        let placement = textPlacement(
            annotation,
            run: run,
            anchor: anchor,
            renderSize: renderSize,
            scale: scale
        )
        return run.rect(at: placement.textOrigin)
    }

    /// Glyph-box rect of a `.sticker` (top-left origin, y-down).
    static func stickerRect(
        _ annotation: Annotation,
        renderSize: CGSize,
        scale: CGFloat = 1
    ) -> CGRect? {
        guard annotation.tool == .sticker,
              let text = annotation.text,
              let run = textRun(
                  text,
                  fontSize: stickerFontSize * scale,
                  weight: .regular,
                  color: nil
              ),
              let anchor = anchorPoint(annotation, renderSize: renderSize)
        else { return nil }
        return stickerPlacement(
            run: run,
            anchor: anchor,
            renderSize: renderSize
        ).rect
    }

    // MARK: - Text / note / counter / sticker

    private struct TextPlacement {
        /// Bubble (`.note`) or line box (`.text`).
        let bubble: CGRect
        /// Area the glyphs may occupy; `.note` clips to it.
        let content: CGRect
        let textOrigin: CGPoint
    }

    private static func textPlacement(
        _ annotation: Annotation,
        run: TextRun,
        anchor: CGPoint,
        renderSize: CGSize,
        scale: CGFloat
    ) -> TextPlacement {
        if annotation.tool == .note {
            return notePlacement(
                run: run,
                anchor: anchor,
                renderSize: renderSize,
                scale: scale
            )
        }
        // Plain text starts exactly at its anchor: the inline field is placed
        // by the overlay and the committed text must land where the box was.
        let line = run.rect(at: anchor)
        return TextPlacement(bubble: line, content: line, textOrigin: anchor)
    }

    private static func notePlacement(
        run: TextRun,
        anchor: CGPoint,
        renderSize: CGSize,
        scale: CGFloat
    ) -> TextPlacement {
        let padding = notePadding * scale
        let natural = CGSize(
            width: run.width + padding * 2,
            height: run.ascent + run.descent + padding * 2
        )
        let size = CGSize(
            width: min(natural.width, max(renderSize.width, 1)),
            height: min(natural.height, max(renderSize.height, 1))
        )
        // Clamping the origin is what pushes the bubble back inside; shrinking
        // (above) is the last resort for a bubble wider than the selection.
        let origin = CGPoint(
            x: min(max(anchor.x, 0), max(0, renderSize.width - size.width)),
            y: min(max(anchor.y, 0), max(0, renderSize.height - size.height))
        )
        let bubble = CGRect(origin: origin, size: size)
        let content = bubble.insetBy(dx: padding, dy: padding)
        return TextPlacement(
            bubble: bubble,
            content: content,
            textOrigin: content.origin
        )
    }

    private static func stickerPlacement(
        run: TextRun,
        anchor: CGPoint,
        renderSize: CGSize
    ) -> (rect: CGRect, baseline: CGPoint) {
        let height = run.ascent + run.descent
        var origin = CGPoint(x: anchor.x - run.width / 2, y: anchor.y - height / 2)
        origin.x = min(max(origin.x, 0), max(0, renderSize.width - run.width))
        origin.y = min(max(origin.y, 0), max(0, renderSize.height - height))
        let rect = CGRect(
            origin: origin,
            size: CGSize(width: run.width, height: height)
        )
        return (rect, CGPoint(x: rect.minX, y: rect.minY + run.ascent))
    }

    private static func drawText(
        _ annotation: Annotation,
        anchor: CGPoint,
        renderSize: CGSize,
        scale: CGFloat,
        in context: CGContext
    ) {
        guard let text = annotation.text,
              let run = textRun(
                  text,
                  fontSize: fontSize(of: annotation) * scale,
                  weight: .semibold,
                  color: annotation.color.usingColorSpace(.sRGB) ?? annotation.color
              )
        else { return }

        let placement = textPlacement(
            annotation,
            run: run,
            anchor: anchor,
            renderSize: renderSize,
            scale: scale
        )
        let baseline = CGPoint(
            x: placement.textOrigin.x,
            y: placement.textOrigin.y + run.ascent
        )

        if annotation.tool == .note {
            drawNoteBubble(placement.bubble, scale: scale, in: context)
            // A bubble narrowed by the selection edge clips its text instead of
            // leaking glyphs outside itself.
            context.saveGState()
            context.clip(to: placement.content)
            drawLine(run, baseline: baseline, in: context)
            context.restoreGState()
        } else {
            drawLine(run, baseline: baseline, in: context)
        }
    }

    /// Pale yellow sticky note with a thin warm border.
    private static func drawNoteBubble(
        _ bubble: CGRect,
        scale: CGFloat,
        in context: CGContext
    ) {
        let radius = min(6 * scale, bubble.height / 2, bubble.width / 2)
        let fill = NSColor(
            srgbRed: 1.00,
            green: 0.96,
            blue: 0.72,
            alpha: 0.97
        ).cgColor
        let border = NSColor(
            srgbRed: 0.52,
            green: 0.42,
            blue: 0.14,
            alpha: 0.90
        ).cgColor

        context.saveGState()
        context.addPath(CGPath(
            roundedRect: bubble,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        ))
        context.setFillColor(fill)
        context.fillPath()
        context.addPath(CGPath(
            roundedRect: bubble.insetBy(dx: 0.5 * scale, dy: 0.5 * scale),
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        ))
        context.setStrokeColor(border)
        context.setLineWidth(max(1, scale))
        context.strokePath()
        context.restoreGState()
    }

    /// Solid badge with white, bold, monospaced digits centred in it.
    private static func drawCounter(
        _ annotation: Annotation,
        anchor: CGPoint,
        renderSize: CGSize,
        scale: CGFloat,
        in context: CGContext
    ) {
        guard let text = annotation.text, !text.isEmpty else { return }
        let badge = counterRect(anchor: anchor, renderSize: renderSize, scale: scale)

        context.saveGState()
        context.setFillColor(
            (annotation.color.usingColorSpace(.sRGB) ?? annotation.color).cgColor
        )
        context.fillEllipse(in: badge)
        context.restoreGState()

        // Shrink the digits until they fit; 3+ digit sequences get smaller.
        let available = badge.width * 0.78
        var fontSize = counterFontSize * scale
        var run = textRun(
            text,
            fontSize: fontSize,
            weight: .bold,
            color: .white,
            monospacedDigits: true
        )
        if let current = run, current.width > available, current.width > 0 {
            fontSize *= available / current.width
            run = textRun(
                text,
                fontSize: fontSize,
                weight: .bold,
                color: .white,
                monospacedDigits: true
            )
        }
        guard let run else { return }

        // Vertically centre the glyph box on the badge centre (y-down space:
        // the baseline sits (ascent − descent) / 2 below the centre).
        let baseline = CGPoint(
            x: badge.midX - run.width / 2,
            y: badge.midY + (run.ascent - run.descent) / 2
        )
        drawLine(run, baseline: baseline, in: context)
    }

    /// `.sticker`: one emoji glyph, centred on the click. No foreground colour
    /// is set — Apple Color Emoji ignores it and the glyphs stay in colour.
    private static func drawSticker(
        _ annotation: Annotation,
        anchor: CGPoint,
        renderSize: CGSize,
        scale: CGFloat,
        in context: CGContext
    ) {
        guard let text = annotation.text,
              let run = textRun(
                  text,
                  fontSize: stickerFontSize * scale,
                  weight: .regular,
                  color: nil
              )
        else { return }
        let placement = stickerPlacement(
            run: run,
            anchor: anchor,
            renderSize: renderSize
        )
        drawLine(run, baseline: placement.baseline, in: context)
    }

    /// Draw one CTLine upright inside the caller's y-down space, baseline at
    /// `baseline`. CoreText draws in an unflipped space, hence the local flip.
    private static func drawLine(
        _ run: TextRun,
        baseline: CGPoint,
        in context: CGContext
    ) {
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: baseline.x, y: baseline.y)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(run.line, context)
        context.restoreGState()
    }

    // MARK: - Primitives

    private static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }

    private static func strokePolyline(
        _ points: [CGPoint],
        color: CGColor,
        width: CGFloat,
        in context: CGContext
    ) {
        context.beginPath()
        context.move(to: points[0])
        for point in points.dropFirst() { context.addLine(to: point) }
        context.setStrokeColor(color)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
    }

    private static func strokeArrow(
        from start: CGPoint,
        to end: CGPoint,
        color: CGColor,
        width: CGFloat,
        scale: CGFloat,
        in context: CGContext
    ) {
        context.beginPath()
        context.move(to: start)
        context.addLine(to: end)
        context.setStrokeColor(color)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.strokePath()

        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = max(10 * scale, width * 4)
        let spread = CGFloat.pi / 7

        context.beginPath()
        context.move(to: end)
        context.addLine(to: CGPoint(
            x: end.x - headLength * cos(angle - spread),
            y: end.y - headLength * sin(angle - spread)
        ))
        context.move(to: end)
        context.addLine(to: CGPoint(
            x: end.x - headLength * cos(angle + spread),
            y: end.y - headLength * sin(angle + spread)
        ))
        context.setStrokeColor(color)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
    }
}

extension CapturedScreenshot {
    /// Bake annotations into the pixels. Returns `self` unchanged when there is
    /// nothing to draw, which is what keeps unannotated captures byte-identical
    /// to P0.
    @MainActor
    func flattened(annotations: [Annotation]) -> CapturedScreenshot {
        guard !annotations.isEmpty,
              let flattened = AnnotationRenderer.flattened(
                  base: image,
                  annotations: annotations,
                  referencePointSize: pointSize
              )
        else { return self }
        return CapturedScreenshot(image: flattened, scale: scale)
    }
}

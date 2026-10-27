import AppKit
import CoreGraphics

/// One sampled colour, independent of AppKit / the display's colour space.
///
/// The colour is stored as 8-bit sRGB components because that is what the hex
/// code users paste into CSS or a design tool means.
struct PickedColor: Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(red: Int, green: Int, blue: Int) {
        self.red = UInt8(min(max(red, 0), 255))
        self.green = UInt8(min(max(green, 0), 255))
        self.blue = UInt8(min(max(blue, 0), 255))
    }

    /// `FF8000` — no leading `#`, which is the form the history copies.
    var hex: String {
        String(format: "%02X%02X%02X", red, green, blue)
    }

    /// `#FF8000`
    var hexString: String { "#\(hex)" }

    /// `255, 128, 0`
    var rgbString: String { "\(red), \(green), \(blue)" }

    /// `30°, 100%, 50%`
    var hslString: String {
        let hsl = hslComponents
        return "\(Int(hsl.hue.rounded()))°, \(Int((hsl.saturation * 100).rounded()))%, "
            + "\(Int((hsl.lightness * 100).rounded()))%"
    }

    var hslComponents: (hue: Double, saturation: Double, lightness: Double) {
        let r = Double(red) / 255
        let g = Double(green) / 255
        let b = Double(blue) / 255
        let maxValue = max(r, g, b)
        let minValue = min(r, g, b)
        let delta = maxValue - minValue
        let lightness = (maxValue + minValue) / 2

        guard delta > 0 else { return (0, 0, lightness) }

        let saturation = delta / (1 - abs(2 * lightness - 1))
        var hue: Double
        if maxValue == r {
            hue = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
        } else if maxValue == g {
            hue = 60 * (((b - r) / delta) + 2)
        } else {
            hue = 60 * (((r - g) / delta) + 4)
        }
        if hue < 0 { hue += 360 }
        return (hue, min(max(saturation, 0), 1), lightness)
    }

    var nsColor: NSColor {
        NSColor(
            srgbRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: 1
        )
    }

    /// What the picker writes to the pasteboard.
    func string(for format: ColorPickFormat) -> String {
        switch format {
        case .hex: hexString
        case .rgb: "rgb(\(rgbString))"
        case .hsl:
            "hsl(\(Int(hslComponents.hue.rounded())), "
                + "\(Int((hslComponents.saturation * 100).rounded()))%, "
                + "\(Int((hslComponents.lightness * 100).rounded()))%)"
        }
    }
}

/// The copy formats offered in 设置 → 取色器. HEX is the default.
///
/// Tab keeps its historical two-step cycle (HEX ↔ RGB); HSL is selectable in
/// Settings and is shown as a third hint in the magnifier. Changing the Tab
/// cycle would break the muscle memory of anyone using the picker.
enum ColorPickFormat: String, Sendable, Equatable, CaseIterable, Identifiable {
    case hex
    case rgb
    case hsl

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hex: "HEX"
        case .rgb: "RGB"
        case .hsl: "HSL"
        }
    }

    var next: ColorPickFormat {
        switch self {
        case .hex: .rgb
        case .rgb, .hsl: .hex
        }
    }
}

/// Random-access RGB sampling from one `CGImage`.
///
/// The source is redrawn once into an sRGB RGBA8 buffer, so:
/// * the sampled value is in sRGB regardless of the display's native colour
///   space (Display P3 screens otherwise yield hex codes that look wrong
///   everywhere outside that screen);
/// * repeated sampling during mouse tracking is just three array reads.
struct ColorSampler {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init?(image: CGImage) {
        guard image.width > 0, image.height > 0 else { return nil }
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let drew = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    /// Top-left-origin pixel access. Coordinates outside the image are clamped
    /// to the nearest edge instead of trapping: the picker can legitimately be
    /// asked about a point just off-screen (multi-display edges, a fast drag
    /// during a screen change).
    func color(atX x: Int, y: Int) -> PickedColor? {
        guard width > 0, height > 0 else { return nil }
        let clampedX = min(max(x, 0), width - 1)
        let clampedY = min(max(y, 0), height - 1)
        let index = (clampedY * width + clampedX) * 4
        guard index + 2 < bytes.count else { return nil }
        return PickedColor(
            red: bytes[index],
            green: bytes[index + 1],
            blue: bytes[index + 2]
        )
    }

    func color(atPixel point: CGPoint) -> PickedColor? {
        color(
            atX: Int(point.x.rounded(.down)),
            y: Int(point.y.rounded(.down))
        )
    }
}

/// A full-screen snapshot plus the mapping from AppKit global points
/// (bottom-left) to snapshot pixels (top-left).
struct ScreenSnapshot {
    let image: CGImage
    let screenFrame: CGRect
    /// Pixels per point, derived from the actual image size so a scaled display
    /// maps correctly even if it is not exactly 2×.
    let pixelScale: CGSize
    private let sampler: ColorSampler?

    init(image: CGImage, screenFrame: CGRect) {
        self.image = image
        self.screenFrame = screenFrame
        self.pixelScale = CGSize(
            width: CGFloat(image.width) / max(screenFrame.width, 1),
            height: CGFloat(image.height) / max(screenFrame.height, 1)
        )
        self.sampler = ColorSampler(image: image)
    }

    var isUsable: Bool { sampler != nil && image.width > 0 && image.height > 0 }

    /// Global point → top-left pixel coordinate, clamped into the image.
    func pixelPoint(atGlobalPoint point: CGPoint) -> CGPoint {
        let rawX = (point.x - screenFrame.minX) * pixelScale.width
        let rawY = (screenFrame.maxY - point.y) * pixelScale.height
        return CGPoint(
            x: min(max(rawX, 0), CGFloat(max(image.width - 1, 0))),
            y: min(max(rawY, 0), CGFloat(max(image.height - 1, 0)))
        )
    }

    /// The colour under a global point. `nil` only when the snapshot itself is
    /// unusable; an off-screen point is clamped to the closest edge pixel.
    func color(atGlobalPoint point: CGPoint) -> PickedColor? {
        color(atPixel: pixelPoint(atGlobalPoint: point))
    }

    /// Top-left-origin pixel access, used by the magnifier.
    func color(atPixel point: CGPoint) -> PickedColor? {
        sampler?.color(atPixel: point)
    }

    func color(pixelX: Int, pixelY: Int) -> PickedColor? {
        sampler?.color(atX: pixelX, y: pixelY)
    }
}

/// Writes the picked colour as text. Split from the controller so the self
/// test can target a private pasteboard instead of overwriting the user's
/// clipboard.
enum ColorPickerClipboard {
    @discardableResult
    static func copy(
        _ color: PickedColor,
        format: ColorPickFormat,
        to pasteboard: NSPasteboard = .general
    ) -> String {
        let text = color.string(for: format)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return text
    }
}

/// Full-screen magnifier: move to sample, click to copy, Tab toggles HEX/RGB.
@MainActor
final class ColorPickerController {
    private var panel: NSPanel?
    private var overlay: ColorPickerOverlayView?
    private var snapshot: ScreenSnapshot?
    private(set) var isPresenting = false
    private(set) var initialFormat: ColorPickFormat
    private(set) var lastPicked: PickedColor?
    private(set) var lastCopiedText: String?

    var onPick: ((PickedColor, String) -> Void)?
    var onCancel: (() -> Void)?

    init(format: ColorPickFormat = .hex) {
        self.initialFormat = format
    }

    /// Snapshot the screen under the pointer, then present the magnifier.
    func present() {
        guard !isPresenting else { return }
        isPresenting = true
        NSApp.activate(ignoringOtherApps: true)

        guard let screen = Self.screenUnderMouse() else {
            finishCancelled()
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let shot = try await ScreenCapture.captureFullScreen(screen, includeCursor: false)
                let snapshot = ScreenSnapshot(image: shot.image, screenFrame: screen.frame)
                guard snapshot.isUsable else {
                    DebugLog.log("color picker: snapshot unusable")
                    self.finishCancelled()
                    return
                }
                self.snapshot = snapshot
                self.buildPanel(snapshot: snapshot, on: screen)
            } catch {
                DebugLog.log("color picker: snapshot failed \(error.localizedDescription)")
                self.finishCancelled()
            }
        }
    }

    func cancel() {
        guard isPresenting else { return }
        finishCancelled()
    }

    private func buildPanel(snapshot: ScreenSnapshot, on screen: NSScreen) {
        guard isPresenting else { return }

        let panel = ColorPickerPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true

        let startPoint = NSEvent.mouseLocation
        let view = ColorPickerOverlayView(
            frame: CGRect(origin: .zero, size: screen.frame.size),
            snapshot: snapshot,
            screenOrigin: screen.frame.origin,
            format: initialFormat
        )
        view.cursorPoint = CGPoint(
            x: startPoint.x - screen.frame.minX,
            y: startPoint.y - screen.frame.minY
        )
        view.onPick = { [weak self] color, format in
            self?.finishPicked(color, format: format)
        }
        view.onCancel = { [weak self] in self?.finishCancelled() }
        panel.contentView = view
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        panel.orderFrontRegardless()

        self.panel = panel
        self.overlay = view
        DebugLog.log(
            "color picker: presented on \(screen.localizedName) "
            + "snapshot=\(snapshot.image.width)×\(snapshot.image.height) format=\(initialFormat.rawValue)"
        )
    }

    private func finishPicked(_ color: PickedColor, format: ColorPickFormat) {
        lastPicked = color
        lastCopiedText = ColorPickerClipboard.copy(color, format: format)
        close()
        onPick?(color, lastCopiedText ?? color.hexString)
        DebugLog.log("color picker: picked \(color.hexString) rgb=(\(color.rgbString)) copied=\(lastCopiedText ?? "-")")
    }

    private func finishCancelled() {
        guard isPresenting else { return }
        close()
        onCancel?()
        DebugLog.log("color picker: cancelled")
    }

    private func close() {
        isPresenting = false
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        overlay = nil
        snapshot = nil
    }

    static func screenUnderMouse() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}

/// Needs key status so Escape / Tab / Return reach it.
private final class ColorPickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Draws the magnifier, the crosshair and the colour card.
@MainActor
final class ColorPickerOverlayView: NSView {
    private let snapshot: ScreenSnapshot
    private let screenOrigin: CGPoint
    private(set) var format: ColorPickFormat

    var onPick: ((PickedColor, ColorPickFormat) -> Void)?
    var onCancel: (() -> Void)?

    /// View-local point (bottom-left) under the pointer.
    var cursorPoint: CGPoint = .zero {
        didSet {
            guard cursorPoint != oldValue else { return }
            needsDisplay = true
        }
    }

    private static let magnifierPixels = 15
    private static let magnifierPixelSize: CGFloat = 9
    private static let magnifierSide = CGFloat(magnifierPixels) * magnifierPixelSize
    private static let cardWidth: CGFloat = 268
    private static let cardHeight: CGFloat = 116

    init(frame: NSRect, snapshot: ScreenSnapshot, screenOrigin: CGPoint, format: ColorPickFormat) {
        self.snapshot = snapshot
        self.screenOrigin = screenOrigin
        self.format = format
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    /// Global (bottom-left) point for a view-local point.
    func globalPoint(for local: CGPoint) -> CGPoint {
        CGPoint(x: screenOrigin.x + local.x, y: screenOrigin.y + local.y)
    }

    /// The colour currently under the crosshair; exposed for the self test and
    /// for the card.
    var colorUnderCursor: PickedColor? {
        snapshot.color(atGlobalPoint: globalPoint(for: cursorPoint))
    }

    // MARK: - Events

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        window?.makeFirstResponder(self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseMoved(with event: NSEvent) {
        cursorPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        cursorPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDown(with event: NSEvent) {
        cursorPoint = convert(event.locationInWindow, from: nil)
        guard let color = colorUnderCursor else {
            onCancel?()
            return
        }
        onPick?(color, format)
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            onCancel?()
        case 48: // Tab
            format = format.next
            needsDisplay = true
        case 36, 76: // Return / keypad Enter
            if let color = colorUnderCursor {
                onPick?(color, format)
            }
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.shouldAntialias = true

        // Crosshair at the sampled point.
        let crosshair = NSBezierPath()
        crosshair.move(to: CGPoint(x: cursorPoint.x - 18, y: cursorPoint.y))
        crosshair.line(to: CGPoint(x: cursorPoint.x + 18, y: cursorPoint.y))
        crosshair.move(to: CGPoint(x: cursorPoint.x, y: cursorPoint.y - 18))
        crosshair.line(to: CGPoint(x: cursorPoint.x, y: cursorPoint.y + 18))
        crosshair.lineWidth = 1
        NSColor.white.withAlphaComponent(0.85).setStroke()
        crosshair.stroke()

        let magnifierRect = magnifierFrame()
        drawMagnifier(in: magnifierRect)
        drawCard(adjacentTo: magnifierRect)
    }

    /// Keep the magnifier on screen, preferring up-right of the cursor so it
    /// never covers the pixel being sampled.
    private func magnifierFrame() -> CGRect {
        let side = Self.magnifierSide
        let margin: CGFloat = 24
        var origin = CGPoint(x: cursorPoint.x + margin, y: cursorPoint.y + margin)
        if origin.x + side > bounds.width - margin {
            origin.x = cursorPoint.x - margin - side
        }
        if origin.y + side > bounds.height - margin {
            origin.y = cursorPoint.y - margin - side
        }
        origin.x = min(max(origin.x, margin), max(margin, bounds.width - side - margin))
        origin.y = min(max(origin.y, margin), max(margin, bounds.height - side - margin))
        return CGRect(origin: origin, size: CGSize(width: side, height: side))
    }

    private func drawMagnifier(in rect: CGRect) {
        let side = Int(Self.magnifierPixels)
        let pixelSize = Self.magnifierPixelSize
        let center = (side - 1) / 2
        let centerPixel = snapshot.pixelPoint(atGlobalPoint: globalPoint(for: cursorPoint))

        // Snapshot pixel at the top-left of the magnified block.
        let originX = Int(centerPixel.x) - center
        let originY = Int(centerPixel.y) - center

        for row in 0..<side {
            for column in 0..<side {
                guard let color = sample(originX + column, originY + row) else { continue }
                color.nsColor.setFill()
                // View coordinates are bottom-left; rows run top-down.
                let cell = CGRect(
                    x: rect.minX + CGFloat(column) * pixelSize,
                    y: rect.maxY - CGFloat(row + 1) * pixelSize,
                    width: pixelSize,
                    height: pixelSize
                )
                cell.fill()
            }
        }

        // Grid + frame.
        NSColor.black.withAlphaComponent(0.18).setStroke()
        let grid = NSBezierPath()
        for index in 0...side {
            let offset = CGFloat(index) * pixelSize
            grid.move(to: CGPoint(x: rect.minX + offset, y: rect.minY))
            grid.line(to: CGPoint(x: rect.minX + offset, y: rect.maxY))
            grid.move(to: CGPoint(x: rect.minX, y: rect.minY + offset))
            grid.line(to: CGPoint(x: rect.maxX, y: rect.minY + offset))
        }
        grid.lineWidth = 0.5
        grid.stroke()

        let outer = NSBezierPath(rect: rect)
        NSColor.white.withAlphaComponent(0.75).setStroke()
        outer.lineWidth = 1.5
        outer.stroke()

        // Centre cell outline so the sampled pixel is unambiguous.
        let centerCell = CGRect(
            x: rect.minX + CGFloat(center) * pixelSize,
            y: rect.maxY - CGFloat(center + 1) * pixelSize,
            width: pixelSize,
            height: pixelSize
        )
        let marker = NSBezierPath(rect: centerCell.insetBy(dx: 0.5, dy: 0.5))
        NSColor.white.setStroke()
        marker.lineWidth = 1.5
        marker.stroke()
    }

    private func drawCard(adjacentTo magnifier: CGRect) {
        let cardSize = CGSize(width: Self.cardWidth, height: Self.cardHeight)
        var origin = CGPoint(
            x: magnifier.maxX + 12,
            y: magnifier.maxY - cardSize.height
        )
        if origin.x + cardSize.width > bounds.width - 16 {
            origin.x = magnifier.minX - cardSize.width - 12
        }
        origin.x = max(16, origin.x)
        origin.y = min(max(16, origin.y), max(16, bounds.height - cardSize.height - 16))
        let card = CGRect(origin: origin, size: cardSize)

        // Card background.
        let path = NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12)
        NSColor.black.withAlphaComponent(0.82).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.18).setStroke()
        path.lineWidth = 1
        path.stroke()

        guard let color = colorUnderCursor else {
            drawText("无法读取快照", at: CGPoint(x: card.minX + 14, y: card.maxY - 30), size: 12, alpha: 0.9)
            return
        }

        // Swatch.
        let swatch = CGRect(x: card.minX + 14, y: card.maxY - 62, width: 48, height: 48)
        color.nsColor.setFill()
        NSBezierPath(roundedRect: swatch, xRadius: 8, yRadius: 8).fill()
        NSColor.white.withAlphaComponent(0.3).setStroke()
        let swatchBorder = NSBezierPath(roundedRect: swatch, xRadius: 8, yRadius: 8)
        swatchBorder.lineWidth = 1
        swatchBorder.stroke()

        let textX = swatch.maxX + 14
        drawText(color.hexString, at: CGPoint(x: textX, y: card.maxY - 34), size: 17, weight: .bold)
        drawText("RGB  \(color.rgbString)", at: CGPoint(x: textX, y: card.maxY - 55), size: 11, alpha: 0.85)
        drawText("HSL  \(color.hslString)", at: CGPoint(x: textX, y: card.maxY - 72), size: 11, alpha: 0.85)

        // Format hint: the active copy format is highlighted.
        let hexAttributes = attributes(size: 10.5, weight: format == .hex ? .semibold : .regular,
                                       alpha: format == .hex ? 1 : 0.45)
        let rgbAttributes = attributes(size: 10.5, weight: format == .rgb ? .semibold : .regular,
                                       alpha: format == .rgb ? 1 : 0.45)
        let hslAttributes = attributes(size: 10.5, weight: format == .hsl ? .semibold : .regular,
                                       alpha: format == .hsl ? 1 : 0.45)
        ("HEX" as NSString).draw(at: CGPoint(x: card.minX + 14, y: card.minY + 12), withAttributes: hexAttributes)
        ("RGB" as NSString).draw(at: CGPoint(x: card.minX + 48, y: card.minY + 12), withAttributes: rgbAttributes)
        ("HSL" as NSString).draw(at: CGPoint(x: card.minX + 82, y: card.minY + 12), withAttributes: hslAttributes)
        drawText(
            "点击复制 · Tab 切换 · Esc 取消",
            at: CGPoint(x: card.minX + 118, y: card.minY + 12),
            size: 10,
            alpha: 0.62
        )
    }

    /// Sample a snapshot pixel, clamped by `ColorSampler` at the image edges.
    private func sample(_ x: Int, _ y: Int) -> PickedColor? {
        snapshot.color(pixelX: x, pixelY: y)
    }

    private func drawText(
        _ text: String,
        at point: CGPoint,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        alpha: CGFloat = 0.96
    ) {
        (text as NSString).draw(at: point, withAttributes: attributes(size: size, weight: weight, alpha: alpha))
    }

    private func attributes(
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        alpha: CGFloat = 0.96
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha)
        ]
    }
}

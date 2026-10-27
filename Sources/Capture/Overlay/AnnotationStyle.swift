import AppKit

/// Overrides for the *next* annotation, edited in 设置 → 标注.
///
/// Stored outside `AnnotationStyle` so the pure style model stays free of
/// `UserDefaults`. `nonisolated(unsafe)` is deliberate: the values are only
/// written from the main actor (settings) and read while the overlay draws.
enum AnnotationDefaults {
    nonisolated(unsafe) static var color: NSColor?
    nonisolated(unsafe) static var lineWidth: CGFloat?
    nonisolated(unsafe) static var fontSize: CGFloat = 20
    nonisolated(unsafe) static var hiddenTools: Set<AnnotationTool> = []
    nonisolated(unsafe) static var toolOrder: [AnnotationTool] = AnnotationTool.allCases

    /// Tools the single 默认颜色 applies to. Mosaic/counter/sticker keep their
    /// built-in colours because those are part of what the tool means.
    static let colorOverrideTools: Set<AnnotationTool> = [
        .arrow, .rectangle, .ellipse, .line, .pencil, .highlighter, .text
    ]

    /// Every tool that paints a user-editable stroke.
    static let lineWidthOverrideTools: Set<AnnotationTool> = [
        .arrow, .rectangle, .ellipse, .line, .pencil, .highlighter
    ]

    static func apply(
        colorHex: String,
        lineWidth: Double,
        fontSize: Double,
        hiddenTools: [String],
        toolOrder: [String]
    ) {
        self.color = parseHex(colorHex)
        self.lineWidth = lineWidth > 0 ? CGFloat(lineWidth) : nil
        self.fontSize = min(max(CGFloat(fontSize), AnnotationStyle.fontSizeRange.lowerBound),
                            AnnotationStyle.fontSizeRange.upperBound)

        // Move must stay available: without it the selection cannot be moved.
        let hidden = Set(hiddenTools.compactMap(AnnotationTool.init(rawValue:)))
            .subtracting([.move])
        self.hiddenTools = hidden

        var order: [AnnotationTool] = []
        for raw in toolOrder {
            guard let tool = AnnotationTool(rawValue: raw), !order.contains(tool) else { continue }
            order.append(tool)
        }
        for tool in AnnotationTool.allCases where !order.contains(tool) {
            order.append(tool)
        }
        self.toolOrder = order
        AnnotationToolbarLayout.rebuild(hidden: hidden, order: order)
    }

    /// `FF3B30` or `#FF3B30`; empty/invalid means "no override".
    static func parseHex(_ hex: String) -> NSColor? {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    static func hexString(of color: NSColor) -> String {
        let srgb = color.usingColorSpace(.sRGB) ?? NSColor.white
        return String(
            format: "%02X%02X%02X",
            Int((srgb.redComponent * 255).rounded()),
            Int((srgb.greenComponent * 255).rounded()),
            Int((srgb.blueComponent * 255).rounded())
        )
    }

    /// Back to built-in defaults. Used by the self test so a user's custom
    /// annotation defaults cannot change its expectations.
    static func reset() {
        color = nil
        lineWidth = nil
        fontSize = 20
        hiddenTools = []
        toolOrder = AnnotationTool.allCases
        AnnotationToolbarLayout.rebuild(hidden: [], order: AnnotationTool.allCases)
    }
}

/// Which tool buttons the floating capture toolbar shows, and in what order.
/// Kept separate from the view so settings and the offline test can drive it.
enum AnnotationToolbarLayout {
    nonisolated(unsafe) private(set) static var hidden: Set<AnnotationTool> = []
    nonisolated(unsafe) private(set) static var order: [AnnotationTool] = AnnotationTool.allCases

    static var visibleTools: [AnnotationTool] {
        order.filter { !hidden.contains($0) }
    }

    static func rebuild(hidden: Set<AnnotationTool>, order: [AnnotationTool]) {
        self.hidden = hidden
        self.order = order
    }

    static func reset() {
        hidden = []
        order = AnnotationTool.allCases
    }
}

/// Per-tool annotation appearance. The panel edits one of these at a time;
/// changing it affects the next stroke, never the annotations already on the
/// canvas (matching iShot's editor).
struct AnnotationStyle: Equatable {
    var color: NSColor
    var lineWidth: CGFloat
    var fontSize: CGFloat
    /// Highlighter alpha; ignored by other tools.
    var opacity: CGFloat

    static let lineWidthRange: ClosedRange<CGFloat> = 1...24
    static let fontSizeRange: ClosedRange<CGFloat> = 10...72
    static let opacityRange: ClosedRange<CGFloat> = 0.15...1

    static func defaultStyle(for tool: AnnotationTool) -> AnnotationStyle {
        var color = tool.defaultColor
        if let override = AnnotationDefaults.color,
           AnnotationDefaults.colorOverrideTools.contains(tool) {
            color = override
        }
        let lineWidth: CGFloat
        if let override = AnnotationDefaults.lineWidth,
           AnnotationDefaults.lineWidthOverrideTools.contains(tool) {
            lineWidth = max(1, override)
        } else {
            lineWidth = max(1, tool.defaultLineWidth)
        }
        return AnnotationStyle(
            color: color,
            lineWidth: lineWidth,
            fontSize: AnnotationDefaults.fontSize,
            opacity: 1
        )
    }

    /// Tool-appropriate clamping, so a slider can never store a 0-width stroke
    /// or an invisible highlighter.
    func clamped(for tool: AnnotationTool) -> AnnotationStyle {
        var copy = self
        copy.lineWidth = min(max(copy.lineWidth, Self.lineWidthRange.lowerBound),
                             Self.lineWidthRange.upperBound)
        copy.fontSize = min(max(copy.fontSize, Self.fontSizeRange.lowerBound),
                            Self.fontSizeRange.upperBound)
        copy.opacity = min(max(copy.opacity, Self.opacityRange.lowerBound),
                           Self.opacityRange.upperBound)
        if !tool.isDrawingTool, tool != .counter {
            copy.lineWidth = max(1, tool.defaultLineWidth)
        }
        return copy
    }

    var nsColor: NSColor {
        color.usingColorSpace(.sRGB) ?? color
    }

    static func == (lhs: AnnotationStyle, rhs: AnnotationStyle) -> Bool {
        lhs.lineWidth == rhs.lineWidth
            && lhs.fontSize == rhs.fontSize
            && lhs.opacity == rhs.opacity
            && lhs.nsColor.isEqual(rhs.nsColor)
    }
}

/// The style-aware bits of `AnnotationTool` used by the panel. Kept here so the
/// model does not need a direct dependency on the overlay view.
extension AnnotationTool {
    var supportsLineWidth: Bool {
        isDrawingTool
    }

    var supportsFontSize: Bool {
        self == .text || self == .note
    }

    var supportsOpacity: Bool {
        self == .highlighter
    }
}

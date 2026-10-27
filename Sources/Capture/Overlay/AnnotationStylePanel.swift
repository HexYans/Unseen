import AppKit
import SwiftUI

/// The fixed annotation palette: six standards instead of a full colour wheel.
///
/// The values are fixed sRGB constants rather than `systemRed`/`systemOrange`:
/// the same colour has to rasterise identically in the overlay (dark
/// appearance) and in the exported bitmap (no appearance), and a small palette
/// is faster to pick from than the system colour panel.
enum AnnotationPalette {
    struct Swatch {
        let name: String
        let hex: String
        let color: NSColor
    }

    static let swatches: [Swatch] = [
        Swatch(name: "红", hex: "FF3B30", color: fixed(0xFF3B30)),
        Swatch(name: "橙", hex: "FF9500", color: fixed(0xFF9500)),
        Swatch(name: "黄", hex: "FFCC00", color: fixed(0xFFCC00)),
        Swatch(name: "绿", hex: "34C759", color: fixed(0x34C759)),
        Swatch(name: "蓝", hex: "007AFF", color: fixed(0x007AFF)),
        Swatch(name: "紫", hex: "AF52DE", color: fixed(0xAF52DE))
    ]

    /// The swatch shown as selected for a colour. The six fixed colours are the
    /// only choices now, but each tool still has its own built-in sRGB default
    /// (`AnnotationTool.defaultColor`) and older preferences may hold a custom
    /// hex, so snap to the nearest standard within a small RGB distance instead
    /// of showing no selection at all. Beyond that distance nothing is marked.
    static func closestSwatch(to color: NSColor) -> Swatch? {
        guard let color = color.usingColorSpace(.sRGB) else { return nil }
        var best: (swatch: Swatch, distance: CGFloat)?
        for swatch in swatches {
            guard let candidate = swatch.color.usingColorSpace(.sRGB) else { continue }
            let red = color.redComponent - candidate.redComponent
            let green = color.greenComponent - candidate.greenComponent
            let blue = color.blueComponent - candidate.blueComponent
            let distance = red * red + green * green + blue * blue
            if distance < (best?.distance ?? .infinity) {
                best = (swatch, distance)
            }
        }
        // 0.09 ≈ a 0.17 average channel difference; every built-in tool colour
        // lands well inside this, while a clearly custom colour does not.
        guard let best, best.distance <= 0.09 else { return nil }
        return best.swatch
    }

    private static func fixed(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// One row of fixed colour chips. Shared by the overlay style popover and
/// 设置 → 标注 → 默认颜色 so both offer the same six options. Selection is a
/// neutral ring, not the accent blue.
struct AnnotationColorSwatches: View {
    var selected: NSColor?
    var swatchSize: CGFloat = 18
    var onSelect: (NSColor) -> Void

    var body: some View {
        let selectedSwatch = selected.flatMap(AnnotationPalette.closestSwatch)
        HStack(spacing: 6) {
            ForEach(Array(AnnotationPalette.swatches.enumerated()), id: \.offset) { _, swatch in
                let isSelected = selectedSwatch?.hex == swatch.hex
                Button {
                    onSelect(swatch.color)
                } label: {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(nsColor: swatch.color))
                        .frame(width: swatchSize, height: swatchSize)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(
                                    isSelected
                                        ? Color.primary.opacity(0.75)
                                        : Color.primary.opacity(0.14),
                                    lineWidth: isSelected ? 2 : 1
                                )
                        }
                }
                .buttonStyle(.plain)
                .help("\(swatch.name) #\(swatch.hex)")
                .accessibilityLabel(swatch.name)
            }
        }
    }
}

/// The iShot-style annotation style popover: colour swatches, stroke width,
/// text/note font size and highlighter opacity. Edits apply to the next
/// annotation of the current tool; existing marks stay untouched.
struct AnnotationStylePanel: View {
    let tool: AnnotationTool
    @State private var style: AnnotationStyle
    private let onChange: (AnnotationStyle) -> Void

    init(
        tool: AnnotationTool,
        style: AnnotationStyle,
        onChange: @escaping (AnnotationStyle) -> Void
    ) {
        self.tool = tool
        self._style = State(initialValue: style)
        self.onChange = onChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.tint)
                Text(tool.title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("恢复默认") {
                    update(.defaultStyle(for: tool))
                }
                .font(.system(size: 11))
                .buttonStyle(.link)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("颜色")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                AnnotationColorSwatches(selected: style.nsColor) { swatch in
                    var next = style
                    next.color = swatch
                    update(next)
                }
            }

            if tool.supportsLineWidth {
                slider(
                    title: "线宽",
                    value: $style.lineWidth,
                    range: AnnotationStyle.lineWidthRange,
                    format: "%.1f pt"
                )
            }

            if tool.supportsFontSize {
                slider(
                    title: "字号",
                    value: $style.fontSize,
                    range: AnnotationStyle.fontSizeRange,
                    format: "%.0f pt"
                )
            }

            if tool.supportsOpacity {
                slider(
                    title: "不透明度",
                    value: $style.opacity,
                    range: AnnotationStyle.opacityRange,
                    format: "%.0f%%",
                    displayScale: 100
                )
            }

            if !tool.supportsLineWidth, !tool.supportsFontSize, !tool.supportsOpacity {
                Text(tool.isClickPlacement
                     ? "这个工具使用固定外观；颜色仍可用于序号。"
                     : "这个工具没有可调样式。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func slider(
        title: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        format: String,
        displayScale: CGFloat = 1
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: format, value.wrappedValue * displayScale))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { newValue in
                        var next = style
                        if title == "线宽" { next.lineWidth = CGFloat(newValue) }
                        if title == "字号" { next.fontSize = CGFloat(newValue) }
                        if title == "不透明度" { next.opacity = CGFloat(newValue) }
                        update(next)
                    }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound)
            )
            .controlSize(.small)
        }
    }

    private func update(_ next: AnnotationStyle) {
        style = next.clamped(for: tool)
        onChange(style)
    }
}

@MainActor
final class AnnotationStylePanelController: NSViewController {
    private let tool: AnnotationTool
    private let style: AnnotationStyle
    private let onChange: (AnnotationStyle) -> Void

    init(
        tool: AnnotationTool,
        style: AnnotationStyle,
        onChange: @escaping (AnnotationStyle) -> Void
    ) {
        self.tool = tool
        self.style = style
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 300, height: tool.supportsFontSize ? 330 : 300)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSHostingView(
            rootView: AnnotationStylePanel(tool: tool, style: style, onChange: onChange)
        )
    }
}

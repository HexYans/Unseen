import SwiftUI

/// A neutral on/off switch.
///
/// The system switch is the one remaining bright-blue control in the app; the
/// user explicitly asked for no blue selection, so the switch uses the same
/// translucent wash + hairline as `SelectionStyle`. It is still a capsule with
/// a sliding knob, just monochrome.
struct NeutralSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.16)) { configuration.isOn.toggle() }
        } label: {
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(configuration.isOn ? 0.22 : 0.11))
                .frame(width: 32, height: 19)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(
                            Color.primary.opacity(configuration.isOn ? 0.92 : 0.45)
                        )
                        .frame(width: 15, height: 15)
                        .padding(2)
                        .shadow(color: .black.opacity(0.16), radius: 0.5, y: 0.5)
                }
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(configuration.isOn ? "开" : "关"))
    }
}

/// A compact segmented control with a **neutral** selected pill.
///
/// AppKit/SwiftUI's `.pickerStyle(.segmented)` paints the selection with the
/// system accent colour, which is exactly the blue slab the user rejected. This
/// control uses the same `SelectionStyle` wash + hairline as the navigation and
/// history rows, so every "selected" state in the app reads the same.
struct NeutralSegmentedControl<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String
    var height: CGFloat = 22

    @State private var hovered: Item?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                let isSelected = item == selection
                Button {
                    withAnimation(.snappy(duration: 0.18)) { selection = item }
                } label: {
                    Text(title(item))
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .frame(height: height)
                        .background(
                            SelectionBackground(
                                selected: isSelected,
                                hovered: hovered == item,
                                cornerRadius: 6
                            )
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    hovered = hovering ? item : (hovered == item ? nil : hovered)
                }
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }
}

/// The neutral control language used by settings rows.
///
/// The settings pane must not mix system-blue AppKit controls with the app's
/// monochrome language: a `.pickerStyle(.menu)` chevron and a `.bordered`
/// button were the last two blue/grey holdouts. These three metrics describe
/// one capsule family — same height, ink and hairline — so a menu, a button
/// and an inline name field read as siblings.
///
/// Values are relative to `Color.primary` (black on a light ground, white on a
/// dark one), exactly like `CapsuleControlStyle`, and deliberately lighter
/// than the toolbar capsules: a settings row already sits on a glass slab.
enum NeutralControlMetrics {
    static let height: CGFloat = 24
    /// A button that has to line up with a 22 pt shortcut slot.
    static let compactHeight: CGFloat = 22
    static let horizontalPadding: CGFloat = 10

    static let restingFill: Double = 0.05
    static let hoverFill: Double = 0.09
    static let primaryFill: Double = 0.12
    static let primaryHoverFill: Double = 0.16

    static let restingStroke: Double = 0.10
    static let hoverStroke: Double = 0.15
    static let primaryStroke: Double = 0.16
}

/// The shared capsule chrome for settings controls.
private struct NeutralCapsuleChrome: ViewModifier {
    var fill: Double
    var stroke: Double
    var height: CGFloat
    var width: CGFloat?

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, NeutralControlMetrics.horizontalPadding)
            .frame(width: width, height: height)
            // A capsule without a fixed width must not be squeezed by its row:
            // the 隐私 添加 button lost its whole two-glyph label (the capsule
            // stayed, empty) the moment the trailing area got tight. Its width
            // *is* its content, so it is never allowed to compress horizontally.
            // Explicit-width call sites keep their frame.
            .fixedSize(horizontal: width == nil, vertical: false)
            .background(
                Capsule(style: .continuous).fill(Color.primary.opacity(fill))
            )
            .overlay(
                Capsule(style: .continuous).strokeBorder(
                    Color.primary.opacity(stroke),
                    lineWidth: 1
                )
            )
            .contentShape(Capsule(style: .continuous))
    }
}

/// A neutral capsule button for settings rows.
///
/// `.secondary` is a transparent capsule with a hairline; `.primary` is the
/// same shape one ink step stronger, for the one action that matters in a row
/// (重新检查 / 请求权限). Neither uses the system accent colour.
struct NeutralCapsuleButton: View {
    enum Emphasis {
        case primary
        case secondary
    }

    var title: String
    var symbol: String? = nil
    var emphasis: Emphasis = .secondary
    var height: CGFloat = NeutralControlMetrics.height
    var width: CGFloat? = nil
    /// Overrides the label ink. Used by the rows whose system counterpart was a
    /// `role: .destructive` button (重置 / 清空 / 全部清空): macOS draws those as
    /// red *text on the system's white bezel*, so keeping the red ink while
    /// dropping the bezel preserves the warning without the white slab.
    var ink: Color? = nil
    /// The 11 pt label is the settings-row default; the page header's primary
    /// action is one step larger so it still reads as the page's main verb now
    /// that it is a capsule instead of `borderedProminent`.
    var fontSize: CGFloat? = nil
    var help: String? = nil
    /// Unavailable state, drawn here rather than through SwiftUI's `.disabled`:
    /// the plain button style fades its whole label (hairline included) until
    /// the capsule is invisible on the slab, which read as a hole in the row
    /// next to a live 加入 capsule. This keeps the shape and drops only the
    /// label, so "not yet" still looks like a control.
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovering = false

    private var fill: Double {
        guard isEnabled else { return NeutralControlMetrics.restingFill }
        switch emphasis {
        case .primary:
            return isHovering
                ? NeutralControlMetrics.primaryHoverFill
                : NeutralControlMetrics.primaryFill
        case .secondary:
            return isHovering
                ? NeutralControlMetrics.hoverFill
                : NeutralControlMetrics.restingFill
        }
    }

    private var stroke: Double {
        guard isEnabled else { return NeutralControlMetrics.restingStroke * 0.6 }
        switch emphasis {
        case .primary: return NeutralControlMetrics.primaryStroke
        case .secondary:
            return isHovering
                ? NeutralControlMetrics.hoverStroke
                : NeutralControlMetrics.restingStroke
        }
    }

    /// The label ink, including the unavailable state. A disabled label fades to
    /// a plain 30 % primary — *not* `.secondary.opacity(…)`, because `.secondary`
    /// is already ~50 % and the product disappeared; `ink` (destructive red) is
    /// faded the same way, so a disabled 清空 still reads as one.
    private var labelInk: Color {
        let base = ink ?? (emphasis == .primary
            ? Color.primary.opacity(0.9)
            : Color.secondary)
        guard isEnabled else {
            return ink?.opacity(0.5) ?? Color.primary.opacity(0.30)
        }
        return base
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: (fontSize ?? 11) - 1, weight: .medium))
                }
                Text(title)
                    .font(.system(
                        size: fontSize ?? 11,
                        weight: emphasis == .primary ? .semibold : .regular
                    ))
                    .lineLimit(1)
            }
            .foregroundStyle(labelInk)
            .modifier(NeutralCapsuleChrome(
                fill: fill,
                stroke: stroke,
                height: height,
                width: width
            ))
        }
        .buttonStyle(.plain)
        .allowsHitTesting(isEnabled)
        .onHover { hovering in
            guard isEnabled else { return }
            withAnimation(.snappy(duration: 0.12)) { isHovering = hovering }
        }
        .help(help ?? title)
    }
}

/// A neutral pull-down menu for settings rows.
///
/// SwiftUI's `.pickerStyle(.menu)` paints its chevron and selection with the
/// system accent colour, which is exactly the mismatch the save-location row
/// showed next to a grey 选择… button. This menu keeps the system's popup
/// behaviour but draws its own capsule label in the shared ink.
struct NeutralCapsuleMenu<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String
    var width: CGFloat = 116
    var help: String? = nil

    @State private var isHovering = false

    var body: some View {
        Menu {
            ForEach(items, id: \.self) { item in
                Button {
                    selection = item
                } label: {
                    if item == selection {
                        Label(title(item), systemImage: "checkmark")
                    } else {
                        Text(title(item))
                    }
                }
            }
        } label: {
            // The label carries the value only. `.borderlessButton` maps a
            // `Menu` label onto AppKit's image+title control, so an `Image`
            // inside the label is hoisted to the **leading** slot and the
            // `Spacer` is dropped — which is how the chevron used to end up on
            // the left with a hole on the right. Drawing the chevron as a
            // trailing overlay keeps the capsule's two ends balanced and puts
            // the disclosure where a popup's belongs.
            Text(title(selection))
                .font(.system(size: 11))
                .foregroundStyle(Color.primary.opacity(0.85))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // The capsule has to wrap the *Menu*, not just its label: the
        // borderless menu style draws the label through its own control layer
        // and silently drops a background applied inside it. Wrapping the
        // control keeps the menu visually identical to the 选择… capsule.
        .modifier(NeutralCapsuleChrome(
            fill: isHovering
                ? NeutralControlMetrics.hoverFill
                : NeutralControlMetrics.restingFill,
            stroke: isHovering
                ? NeutralControlMetrics.hoverStroke
                : NeutralControlMetrics.restingStroke,
            height: NeutralControlMetrics.height,
            width: width
        ))
        .overlay(alignment: .trailing) {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.secondary)
                .padding(.trailing, NeutralControlMetrics.horizontalPadding)
                .allowsHitTesting(false)
        }
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.12)) { isHovering = hovering }
        }
        .help(help ?? title(selection))
    }
}

/// A capsule text field for an inline rename affordance.
///
/// The placeholder is the canonical name, so an empty field visibly means "use
/// the default". A pencil glyph marks the field as editable at a glance; focus
/// lifts the hairline so the row shows which name is being typed.
struct NeutralInlineTextField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat = 128
    var help: String? = nil

    @FocusState private var isFocused: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "pencil")
                .font(.system(size: 9, weight: .semibold))
                // `.tertiary` put the affordance at ~2.2:1 on the dark capsule;
                // the pencil and the canonical-name prompt are the only things
                // that say "this field is editable and empty = default".
                .foregroundStyle(.secondary)
            TextField(
                "",
                text: $text,
                prompt: Text(placeholder).foregroundStyle(.secondary)
            )
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .focused($isFocused)
        }
        .padding(.horizontal, 8)
        .frame(width: width, height: NeutralControlMetrics.height)
        .background(
            Capsule(style: .continuous).fill(
                Color.primary.opacity(
                    isFocused
                        ? NeutralControlMetrics.hoverFill
                        : (isHovering ? 0.075 : NeutralControlMetrics.restingFill)
                )
            )
        )
        .overlay(
            Capsule(style: .continuous).strokeBorder(
                Color.primary.opacity(
                    isFocused
                        ? 0.24
                        : (isHovering ? NeutralControlMetrics.hoverStroke
                                      : NeutralControlMetrics.restingStroke)
                ),
                lineWidth: 1
            )
        )
        .contentShape(Capsule(style: .continuous))
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.12)) { isHovering = hovering }
        }
        .help(help ?? "留空使用默认名称「\(placeholder)」")
    }
}

/// Capsule chrome for an inline text field.
///
/// `TextField(...).textFieldStyle(.roundedBorder)` — what the 固定大小 preset
/// width/height box and the 隐私 Bundle ID box used — is AppKit's own white
/// rounded rectangle: the same "纯白 + 灰边" slab the owner flagged on the
/// buttons, just with a caret in it. This modifier gives a `.plain` field the
/// shared capsule ground, hairline and hover lift so a number box reads as one
/// of the row's controls.
///
/// Applied to the field rather than baked into one view so the numeric and the
/// text field keep their own keyboard behaviour / binding.
struct NeutralCapsuleFieldChrome: ViewModifier {
    var width: CGFloat?
    var height: CGFloat = NeutralControlMetrics.height

    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 8)
            .frame(width: width, height: height)
            .background(
                Capsule(style: .continuous).fill(
                    Color.primary.opacity(
                        isHovering ? 0.075 : NeutralControlMetrics.restingFill
                    )
                )
            )
            .overlay(
                Capsule(style: .continuous).strokeBorder(
                    Color.primary.opacity(
                        isHovering
                            ? NeutralControlMetrics.hoverStroke
                            : NeutralControlMetrics.restingStroke
                    ),
                    lineWidth: 1
                )
            )
            .contentShape(Capsule(style: .continuous))
            .onHover { hovering in
                withAnimation(.snappy(duration: 0.12)) { isHovering = hovering }
            }
    }
}

extension View {
    /// See `NeutralCapsuleFieldChrome`.
    func neutralCapsuleField(
        width: CGFloat? = nil,
        height: CGFloat = NeutralControlMetrics.height
    ) -> some View {
        modifier(NeutralCapsuleFieldChrome(width: width, height: height))
    }
}

/// A neutral numeric stepper.
///
/// `Stepper` is AppKit's own up/down control: a bright metal block whose arrows
/// belong to the system — the same foreign material as the white popup the
/// owner flagged on 帧率 / 码率. This is the `NeutralCapsuleMenu` family with the
/// two arrows as plain glyphs and the value in monospace, so the 最多保留 row
/// matches the 自动清理 / 单张图片上限 menus directly above and below it.
struct NeutralStepper: View {
    @Binding var value: Int
    var range: ClosedRange<Int>
    var step: Int = 1
    var width: CGFloat = 104
    var help: String? = nil

    private enum Edge { case down, up }

    @State private var hovered: Edge?

    private var canStepDown: Bool { value - step >= range.lowerBound }
    private var canStepUp: Bool { value + step <= range.upperBound }

    var body: some View {
        HStack(spacing: 0) {
            arrow("minus", edge: .down, enabled: canStepDown) {
                value = max(range.lowerBound, value - step)
            }
            Text(value.formatted())
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .contentTransition(.numericText())
            arrow("plus", edge: .up, enabled: canStepUp) {
                value = min(range.upperBound, value + step)
            }
        }
        .padding(.horizontal, 3)
        .frame(width: width, height: NeutralControlMetrics.height)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(NeutralControlMetrics.restingFill))
        )
        .overlay(
            Capsule(style: .continuous).strokeBorder(
                Color.primary.opacity(NeutralControlMetrics.restingStroke),
                lineWidth: 1
            )
        )
        .help(help ?? "\(range.lowerBound)–\(range.upperBound)")
    }

    private func arrow(
        _ symbol: String,
        edge: Edge,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(
                    Color.primary.opacity(enabled ? 0.75 : 0.22)
                )
                .frame(width: 19, height: NeutralControlMetrics.height - 6)
                .background(
                    Capsule(style: .continuous).fill(
                        Color.primary.opacity(
                            hovered == edge && enabled
                                ? NeutralControlMetrics.hoverFill
                                : 0
                        )
                    )
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { inside in
            hovered = inside ? edge : (hovered == edge ? nil : hovered)
        }
    }
}

/// The segmented control from the reference: a rounded container with a single
/// pill that *slides* to the selected segment.
///
/// The container is **full width** and every segment gets an equal share of it
/// (`maxWidth: .infinity`). That is deliberate: an earlier version let the bar
/// hug its content and centred it, which left the bar visibly narrower than the
/// search field directly above it — and simply stretching a content-sized bar
/// would have reintroduced the large empty gutters at both ends that the user
/// explicitly rejected. Equal-width segments fill the row while keeping the
/// edges aligned with the search field's.
struct SegmentedPillBar<Item: Hashable & Identifiable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String
    var count: ((Item) -> Int)?

    @Namespace private var pill
    @State private var hovered: Item?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                let isSelected = item == selection
                Button {
                    withAnimation(.snappy(duration: 0.22, extraBounce: 0.05)) { selection = item }
                } label: {
                    HStack(spacing: 4) {
                        Text(title(item))
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            .lineLimit(1)
                            // The bar is exactly as wide as the search field, so
                            // a growing count has to shrink the label a little
                            // rather than truncate it. At today's three-digit
                            // counts the factor is inert: the text still draws
                            // at its full 12 pt / 10 pt measure.
                            .minimumScaleFactor(0.8)
                        if let count {
                            let value = count(item)
                            if value > 0 {
                                Text("\(value)")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    // 3, not 5, so the bar is exactly as tall as the search
                    // field above it. That field is a 12 pt line box plus 6 pt
                    // above and below — 27 pt. The bar is the same line box
                    // plus this 3 pt, the outer 3 pt `padding(3)` below, and
                    // the 1 pt hairline: 15 + 3 + 3 + 3 + 3 = 27 pt, and the
                    // selected capsule is the 21 pt segment itself. The 12 pt
                    // label still clears its line box (21 > 15), so nothing is
                    // cropped; the 5 pt it had before made the bar 31 pt and
                    // broke the row's height (see the measured check in
                    // `runHistoryHeaderWidthTests`).
                    .padding(.vertical, 3)
                    // Equal share of the row. The frame comes *before* the
                    // background so the moving pill is exactly one segment
                    // wide, not the width of its label.
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .background {
                        if isSelected {
                            Capsule(style: .continuous)
                                .fill(SelectionStyle.fill)
                                .overlay(
                                    Capsule(style: .continuous)
                                        .strokeBorder(SelectionStyle.stroke, lineWidth: 1)
                                )
                                .matchedGeometryEffect(id: "segment-pill", in: pill)
                        } else if hovered == item {
                            Capsule(style: .continuous).fill(SelectionStyle.hoverFill)
                        }
                    }
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? item : (hovered == item ? nil : hovered) }
            }
        }
        .padding(3)
        // Same width as the search field above: both sit in a column with one
        // shared horizontal inset, so their left and right edges line up.
        .frame(maxWidth: .infinity)
        .background(
            Capsule(style: .continuous).fill(Color.primary.opacity(0.055))
        )
        .overlay(
            Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }
}

/// The ink ladder the app's two floating toolbars share.
///
/// The pinned-image toolbar (`PinToolbarSurface`) and the clipboard panel's
/// action row (`CapsuleControlStyle`) are different surfaces: the pin is one
/// solid dark plate with bare glyphs, the panel is a row of capsules on glass.
/// So they cannot share a literal fill — the plate's 13 % white would be a grey
/// slab on the panel's light appearance. What they *can* share, and now do, is
/// the strength of the two states a control can be in: "this is a control" and
/// "this is the one under the pointer". Both enums read these numbers; neither
/// restates one.
///
/// Every value is relative to `Color.primary` — white on a dark ground, black on
/// a light one — which is what lets one ladder work in both appearances: the
/// pin toolbar forces dark, the panel follows the system.
enum ToolbarInk {
    /// Pointer-over fill and hairline of a glyph-sized control. The pin's icons
    /// and the panel's capsule buttons sit on exactly this tier.
    static let hoverFill: Double = 0.20
    static let hoverStroke: Double = 0.10
    /// A text chip is the same tier one notch stronger, so a `%` readout carries
    /// as much weight as the glyph next to it.
    static let chipHoverFill: Double = 0.22
    static let chipHoverStroke: Double = 0.10

    /// The panel has no plate: every capsule *is* its own ground, so it keeps a
    /// resting ink as well. Half the hover tier is the point where a capsule
    /// reads as a button at a glance without competing with the hovered one;
    /// the previous 0.07 / 0.05 sat just under it and read as loose glyphs.
    static let capsuleRestingFill: Double = hoverFill * 0.5
    static let capsuleRestingStroke: Double = hoverStroke * 0.8
    /// Latched (钉住面板): a step above resting and still under hover, with a
    /// much stronger hairline — "on" should be a different signature from
    /// "pointed at", not just the same wash one notch darker.
    static let capsuleActiveFill: Double = hoverFill * 0.8
    static let capsuleActiveStroke: Double = hoverStroke * 1.6
    /// A latched capsule lifts one notch above hover while pointed at.
    static let capsuleActiveHoverFill: Double = hoverFill * 1.2
}

/// The one capsule recipe shared by every toolbar capsule.
///
/// The clipboard panel now shows a read-only "剪贴板 N 条" capsule directly next
/// to its icon buttons, so the two must read as one family. The fill, hairline,
/// height and padding live here instead of being repeated as literals at each
/// call site. The inks themselves come from `ToolbarInk`, the same ladder the
/// pinned toolbar reads, so the two toolbars cannot drift apart again.
enum CapsuleControlStyle {
    /// Resting fill of an idle capsule.
    static let restingFill: Double = ToolbarInk.capsuleRestingFill
    /// Fill while the pointer is over an idle capsule.
    static let hoverFill: Double = ToolbarInk.hoverFill
    /// Fill of a latched capsule (e.g. 钉住面板 while pinned).
    static let activeFill: Double = ToolbarInk.capsuleActiveFill
    /// Hovered latched capsule.
    static let activeHoverFill: Double = ToolbarInk.capsuleActiveHoverFill
    static let restingHairline: Double = ToolbarInk.capsuleRestingStroke
    static let activeHairline: Double = ToolbarInk.capsuleActiveStroke
    /// Horizontal padding for an icon-only capsule.
    static let horizontalPadding: CGFloat = 8
    /// Horizontal padding when the capsule carries a label.
    static let titledHorizontalPadding: CGFloat = 11
    /// Fixed interior height, so an icon capsule and the text capsule are
    /// exactly the same tall in the panel's action row.
    static let height: CGFloat = 26
}

extension View {
    /// The shared resting / hover / latched capsule surface.
    ///
    /// `CapsuleToolbarButton` and the panel's read-only count capsule both use
    /// this, so "same background as the buttons" is literally one
    /// implementation: the read-out has no surface of its own, not even a
    /// matte layer.
    func capsuleControlSurface(
        isActive: Bool = false,
        isHovering: Bool = false
    ) -> some View {
        let fill = isActive
            ? (isHovering ? CapsuleControlStyle.activeHoverFill : CapsuleControlStyle.activeFill)
            : (isHovering ? CapsuleControlStyle.hoverFill : CapsuleControlStyle.restingFill)
        // An idle capsule under the pointer is drawn on exactly the shared
        // hover tier (fill *and* stroke), the same numbers `PinToolButton`
        // uses. A latched capsule keeps its own (stronger) rim.
        let stroke = isActive
            ? CapsuleControlStyle.activeHairline
            : (isHovering ? ToolbarInk.hoverStroke : CapsuleControlStyle.restingHairline)
        return background(
            Capsule(style: .continuous).fill(Color.primary.opacity(fill))
        )
        .overlay(
            Capsule(style: .continuous).strokeBorder(
                Color.primary.opacity(stroke),
                lineWidth: 1
            )
        )
    }
}

/// A capsule button with an icon and an optional label — the shape used
/// throughout the reference toolbar.
struct CapsuleToolbarButton: View {
    let symbol: String
    var title: String?
    var showsChevron: Bool = false
    var tint: Color?
    var help: String?
    /// Latched state (e.g. 钉住面板). Sits between resting and hover and adds a
    /// stronger hairline, so "this is on" is obvious without becoming a
    /// coloured slab.
    var isActive: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                if let title {
                    Text(title).font(.system(size: 12))
                }
                if showsChevron {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(tint ?? .primary)
            .padding(.horizontal, title == nil
                ? CapsuleControlStyle.horizontalPadding
                : CapsuleControlStyle.titledHorizontalPadding)
            .frame(height: CapsuleControlStyle.height)
            .capsuleControlSurface(isActive: isActive, isHovering: isHovering)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        // Same fade as `PinToolButton`: the lift is a constant, not a pop.
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.14)) { isHovering = hovering }
        }
        .help(help ?? title ?? symbol)
    }
}

/// The capsule search field from the reference toolbar.
struct CapsuleSearchField: View {
    let placeholder: String
    @Binding var text: String
    var shortcutHint: String?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focused)
            if text.isEmpty, let shortcutHint {
                Text(shortcutHint)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            } else if !text.isEmpty {
                Button {
                    text = ""
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous).fill(Color.primary.opacity(0.06))
        )
        .overlay(
            Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }
}


/// A transparent strip that drags its window.
///
/// The clipboard panel is `.borderless`, so AppKit gives it no titlebar to grab
/// and `isMovableByWindowBackground` is off (it would fight the list). Placing
/// one of these *behind* the controls in a row lets the blank parts of that row
/// move the panel while the buttons keep working.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        // Deliberately *not* `mouseDownCanMoveWindow`: that hands the drag to
        // AppKit, which only acts on it when `isMovableByWindowBackground` is
        // on. With it off the event was swallowed and nothing moved.
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(convert(point, from: superview)) ? self : nil
        }
    }
}

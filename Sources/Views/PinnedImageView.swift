import AppKit
import SwiftUI

/// Content of one on-screen pinned image: the picture plus a hover toolbar.
struct PinnedImageView: View {
    let image: NSImage
    /// Live geometry/opacity of this pin. Read from `body` so a scroll-zoom
    /// updates the percentage chips while the gesture is still running.
    let state: PinPanelState
    let onClose: () -> Void
    let onCopy: () -> Void
    let onSave: () -> Void
    let onOpacity: (Double) -> Void
    let onFitToActualSize: () -> Void

    @State private var isHovering = false
    @State private var isOpacityMenuOpen = false

    /// The popover's presets. Shared with the ⌘+wheel gesture through
    /// `PinOpacity` so the chip can only ever show a value inside the same
    /// range the menu offers.
    private static var opacityChoices: [Double] { PinOpacity.choices }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                // Double-click closes the pin, exactly like the context menu's
                // 关闭. `PinnedImagePanel.sendEvent` only starts a window drag
                // after 3 pt, so this click can never be interpreted as one.
                .onTapGesture(count: 2) { onClose() }

            // Kept alive while the popover is open: moving the pointer into the
            // popover leaves the image, and tearing the toolbar down would take
            // the popover's anchor with it — which closed the menu mid-selection.
            if isHovering || isOpacityMenuOpen {
                toolbar
                    .padding(6)
                    .transition(
                        .scale(scale: 0.86, anchor: .topTrailing)
                        .combined(with: .opacity)
                    )
            }
        }
        // No border: the pinned image is the artwork, and a stroke around it
        // reads as a stray rectangle sitting outside the picture.
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.74)) {
                isHovering = hovering
            }
        }
        .contextMenu { menu }
    }

    private var toolbar: some View {
        HStack(spacing: 3) {
            PinToolButton(symbol: "doc.on.doc", help: "复制图片", action: onCopy)
            PinToolButton(symbol: "square.and.arrow.down", help: "存储为…", action: onSave)
            PinToolButton(
                symbol: "arrow.up.left.and.arrow.down.right",
                help: "恢复原始大小",
                action: onFitToActualSize
            )

            opacityChip
            zoomChip

            PinToolButton(symbol: "xmark", help: "关闭", tint: .red, action: onClose)
        }
        .padding(4)
        // The one plate: the app's shared 液态玻璃 surface (`GlassStyle.swift`),
        // sampling **inside this window** so the pinned picture itself is the
        // backdrop (see `PinToolbarSurface.plateBlending`). No bespoke
        // material, no white sheet and no flat dark slab: the same factory the
        // window cards, the clipboard panel and the capture toolbar use, with
        // the same 20 % `liquidGlassTint` wash on top.
        .background(
            GlassSurface(
                cornerRadius: PinToolbarSurface.plateCornerRadius,
                style: .surface,
                plateAlpha: PinToolbarSurface.plateAlpha,
                backgroundStyle: .liquidGlass,
                blending: PinToolbarSurface.plateBlending,
                material: PinToolbarSurface.plateMaterial,
                showsBorder: false
            )
            // The drop shadow belongs to the *plate*, not to the toolbar group.
            //
            // It used to sit on the `HStack` (after this `.background`), which
            // made every hovered chip part of the shadow's alpha silhouette:
            // the plate is translucent, so a 24 % white chip under the shadow
            // raised the shadow's local alpha and the chip came back with a
            // soft **grey halo** around it (measured on a live pin: −4…−8
            // levels in 浅色 within the 8 pt blur radius, plus a blue shift of
            // the fill). That halo is the exact "半透明的阴影" the owner
            // rejected, so a white highlight alone would have looked wrong.
            //
            // Attached to the plate, the shadow's silhouette is the plate only
            // — the same outline at rest, because every control already sits
            // inside it — and hovering no longer changes it. The one measured
            // difference at rest is that the 1 pt hairline no longer feeds the
            // shadow's alpha, so the plate is 0–4 levels brighter in 浅色
            // (139 → 141 over a black picture, 241 → 245 over a white one) and
            // unchanged in 深色; the 4.61:1 worst-case legibility still holds.
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PinToolbarSurface.plateCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        )
    }

    /// The current opacity, with a popover to change it.
    private var opacityChip: some View {
        PinValueChip(
            text: "\(PinOpacity.percent(state.opacity))%",
            help: "不透明度（⌘ + 滚轮也可调节）",
            action: { isOpacityMenuOpen = true }
        )
        .popover(isPresented: $isOpacityMenuOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Self.opacityChoices, id: \.self) { value in
                    Button {
                        onOpacity(value)
                        isOpacityMenuOpen = false
                    } label: {
                        HStack(spacing: 8) {
                            Text("\(PinOpacity.percent(value))%")
                            Spacer(minLength: 12)
                            Image(systemName: "checkmark")
                                .opacity(abs(state.opacity - value) < 0.005 ? 1 : 0)
                        }
                        .frame(width: 96)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                }
            }
            .padding(6)
        }
    }

    /// How big the picture is drawn right now, relative to its own natural size.
    ///
    /// 100% is deliberately the image's *natural* size rather than the size the
    /// pin happened to be created at (`Pinboard.initialSize` shrinks anything
    /// longer than 480 pt to fit the screen). That is exactly the size
    /// `恢复原始大小` restores, so clicking this chip lands on 100% — the two can
    /// never disagree, and no baseline has to be persisted with the record (an
    /// older record without extra fields therefore still reads correctly: the
    /// baseline is derived from the stored image itself).
    private var zoomText: String? {
        let base = image.size.width
        guard base > 0, state.displaySize.width > 0 else { return nil }
        let percent = Double(state.displaySize.width / base) * 100
        // Never claim "0%" for a picture that is still on screen: 48 pt of a
        // very wide image really is under one percent.
        if percent < 1 { return "<1%" }
        return "\(Int(percent.rounded()))%"
    }

    private var zoomChip: some View {
        PinValueChip(
            text: zoomText ?? "—",
            help: "缩放（点击恢复原始大小）",
            action: onFitToActualSize
        )
    }

    @ViewBuilder
    private var menu: some View {
        Button("复制图片") { onCopy() }
        Button("存储为…") { onSave() }
        Button("恢复原始大小") { onFitToActualSize() }

        Divider()

        Menu("不透明度") {
            ForEach(Self.opacityChoices, id: \.self) { value in
                Button {
                    onOpacity(value)
                } label: {
                    if abs(state.opacity - value) < 0.005 {
                        Label("\(PinOpacity.percent(value))%", systemImage: "checkmark")
                    } else {
                        Text("\(PinOpacity.percent(value))%")
                    }
                }
            }
        }
        Text("滚轮缩放 · ⌘ + 滚轮调不透明度 · 拖拽移动")

        Divider()

        Button("关闭", role: .destructive) { onClose() }
    }
}

/// The inks of the pinned-image toolbar's six controls, in one place.
///
/// The glass plate is the toolbar's *only* background at rest: each glyph and each
/// `%` chip is bare until the pointer is over that one control. At rest nothing
/// is drawn at all; on hover one **white lift** fades in under that control
/// (see `PinHoverHighlight`) — a wash of white plus a faint white hairline, so
/// the chip is *lit*, never darkened.
///
/// Keeping these as named constants (instead of literals inside two private
/// views) is what lets the self-test pin the rule "nothing at rest, one white
/// chip on hover" without a live pointer.
enum PinToolbarSurface {
    /// Resting fill / hairline of a glyph. Zero: the plate shows through.
    ///
    /// Nothing in the view installs these any more — at rest the controls draw
    /// *nothing at all*, which is exactly what zero means. They stay as the
    /// pinned statement of that tier so the self test can fail if a later edit
    /// reintroduces a resting fill.
    static let restingFill: Double = 0
    static let restingStroke: Double = 0

    /// The hover layer's ink: **white**, in both appearances.
    ///
    /// The history matters, because this is the third attempt:
    ///
    /// * `Color.primary.opacity(0.20)` — light mode's `.primary` is black, so
    ///   the chip composited as `0.80 · backdrop` and read as a grey shadow on
    ///   the plate. The owner rejected it as "好丑".
    /// * `NSGlassEffectView(.clear)` — the system material transmitted the
    ///   backdrop but its rim light plus the second glass slab read as heavy on
    ///   this small plate; the owner rejected it as "有点丑".
    /// * **White at 24 %** (this one). `.primary` was the wrong channel: what a
    ///   highlight has to do is *add* light, and white does that in both
    ///   appearances. Over the plate's measured 139 (浅色) / 116 (深色) median
    ///   the lift is `0.24 · (255 − plate)`, i.e. ≈ +28 / +33 levels — visibly
    ///   lit, not a spotlight.
    ///
    /// 11 pt is half of a 22 pt control, so one number is a circle on a glyph
    /// and a capsule on a `%` chip — the same shape each control's
    /// `contentShape` already had.
    static let hoverCornerRadius: CGFloat = 11
    /// The fill. 0.24 sits in the middle of the 0.20–0.28 band the owner asked
    /// for: below 0.20 the chip disappears over a bright picture, above 0.28 the
    /// white starts to wash the glyph out.
    static let hoverFill: Double = 0.24
    /// A hairline of the same white, a touch stronger, so the chip keeps a
    /// defined edge over an almost-white picture. "极淡" — no shadow, and it
    /// never darkens the layer.
    static let hoverStroke: Double = 0.12
    /// The highlight is white, not `.primary`. Named so the self-test can fail
    /// if someone reintroduces the ink wash that started this.
    static let hoverIsWhite = true
    /// …and therefore it does not use the panel's `ToolbarInk.hoverFill`, which
    /// is still a `.primary` wash on the clipboard rows. The two surfaces are
    /// deliberately different now: a row highlight sits on a window background,
    /// this chip sits on a picture.
    static let hoverUsesInk = false
    /// No `shadow(...)` and no material: a shadow is the one thing the owner
    /// has rejected twice. Pinned here so it cannot come back silently.
    static let hoverHasShadow = false

    /// The plate the whole toolbar sits on: the app's shared 液态玻璃 surface,
    /// sampling **inside this window**.
    ///
    /// The toolbar floats on the pinned picture, and that picture is drawn in
    /// the same borderless panel. A `.behindWindow` material would therefore
    /// blur the desktop showing through the panel's transparent background —
    /// the picture itself would stay invisible under the plate (which is what
    /// drove one earlier build back to a solid plate). `.withinWindow` samples
    /// the content already drawn in the window, so the picture is the
    /// backdrop: blurred by the material, tinted by the same 20 %
    /// `liquidGlassTint` wash every small glass surface in the app wears.
    ///
    /// 0.20 is `GlassSurfaceFactory.liquidGlassTint`'s default and the
    /// `GlassSurface.plateAlpha` the rest of the app installs — the number is
    /// named here only so the self test can pin "the pin's plate is the shared
    /// recipe", not a private one.
    static let plateAlpha: Double = 0.20
    static let plateBlending: NSVisualEffectView.BlendingMode = .withinWindow
    static let plateMaterial: NSVisualEffectView.Material = .underWindowBackground
    static let plateCornerRadius: CGFloat = 11
}

/// The hover highlight of one control: one **white lift**, no material, no
/// shadow, no ink.
///
/// A highlight has one job — make the target read as *lit*. The first attempt
/// did that with `Color.primary.opacity(0.20)`, which is black in 浅色, so the
/// chip subtracted light and looked like a grey shadow. The second used the
/// system's clear glass, which transmits but also stacks a second material and
/// rim light on the plate; the owner called it "有点丑". White is the channel
/// that actually adds light, and it does so in both appearances:
///
/// ```
/// hovered = 0.76 · plate + 0.24 · white
/// ```
///
/// The shape follows the control it sits under. 11 pt on a 22 pt square is a
/// circle and on a 22 pt-tall chip a capsule, so one radius covers both and the
/// highlight matches the `contentShape` that receives the hover. `.circular` —
/// not `.continuous` — is deliberate: it is the exact shape of the hit area, so
/// the lit edge and the clickable edge are the same line.
///
/// No `shadow`: a shadow is precisely what the owner rejected, twice. The faint
/// white hairline is the only edge treatment, and it *brightens* the rim.
struct PinHoverHighlight: View {
    var cornerRadius: CGFloat = PinToolbarSurface.hoverCornerRadius

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .circular)
            .fill(Color.white.opacity(PinToolbarSurface.hoverFill))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .circular)
                    .strokeBorder(
                        Color.white.opacity(PinToolbarSurface.hoverStroke),
                        lineWidth: 1
                    )
            }
    }
}

/// One glyph in the pinned-image toolbar. Highlights on hover so the target is
/// never in doubt.
///
/// At rest the glyph is **bare**: the toolbar already sits on one glass plate,
/// so a per-icon disc on top of it only added six small circles to the same
/// strip. On hover one chip of white is lit under that one glyph
/// (`PinHoverHighlight`). The only other thing that changes is the glyph's own
/// ink, which comes up to full strength so it stays readable on top of the
/// lift.
///
/// Note: no `scaleEffect` here. Scaling the view also scaled its hit shape, so
/// the cursor kept falling off the edge and the hover state flickered — that
/// was the "shaking". The highlight is now geometry-stable.
private struct PinToolButton: View {
    let symbol: String
    let help: String
    var tint: Color?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHovering ? (tint ?? .primary) : (tint ?? .primary).opacity(0.85))
                .frame(width: 22, height: 22)
                // The hover layer exists only while the pointer is on this one
                // control: an inserted representable, not an always-present
                // view at alpha 0, so six idle glyphs can never add six
                // compositor passes to the plate.
                .background {
                    if isHovering {
                        PinHoverHighlight()
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.14)) { isHovering = hovering }
        }
        .help(help)
    }
}

/// A `%` readout in the pinned-image toolbar — the opacity and zoom chips are
/// the same control so the two are guaranteed to look identical.
///
/// Like `PinToolButton`, the chip is bare at rest and only shows a shape while
/// the pointer is over it: the six glyphs share one glass plate, so a shape
/// behind each one would read as six separate buttons again. The shape is the
/// same white lift, and 11 pt is half the chip's height, so the lift reads as
/// the capsule the `%` text always had.
///
/// Deliberately a `Button` rather than a `Menu`: a borderless `Menu` never
/// delivers hover events, so the background highlight that every neighbouring
/// button shows could not be reproduced on it.
private struct PinValueChip: View {
    let text: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                // Fixed advance widths: the chip must not change width while a
                // continuous zoom is running.
                .monospacedDigit()
                // Matches `PinToolButton`'s resting colour. Using
                // `Color.secondary` here made the chips a full step dimmer than
                // the icons beside them.
                .foregroundStyle(Color.primary.opacity(isHovering ? 1 : 0.85))
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background {
                    if isHovering {
                        PinHoverHighlight()
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.14)) { isHovering = hovering }
        }
        .help(help)
    }
}

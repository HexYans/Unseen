import AppKit
import Observation
import SwiftUI

/// Liquid Glass (macOS 26+) with a graceful fallback for older systems.
///
/// Everything that wants a glass surface goes through here, so the app still
/// builds and looks reasonable on macOS 14/15 where `glassEffect` does not
/// exist.
/// Read while views are built, so the 外观 → 主题风格 choice takes effect
/// without threading settings through every call site.
@MainActor
enum AppearanceRuntime {
    static var useGlass = true
    static var colorScheme: ColorScheme?
    /// When true every glyph is grey and the selection is the only colour.
    static var monochromeIcons = true
    /// Mirrors 外观 → 背景. Glass surfaces read it while they are built, so the
    /// three background tiers do not have to be threaded through every call.
    /// 纯色 turns every glass surface into an opaque card.
    static var backgroundStyle: AppBackgroundStyle = .solid
}

extension View {
    /// One-stop glass background. Kept as a modifier for call sites that want a
    /// surface without owning a `GlassSurface` view; it shares the exact same
    /// AppKit implementation.
    func glassSurface(
        cornerRadius: CGFloat = 16,
        tint: Color? = nil,
        interactive: Bool = false,
        fillOpacity: Double = 0
    ) -> some View {
        background(
            GlassSurface(
                cornerRadius: cornerRadius,
                style: .surface,
                interactive: interactive,
                tint: tint,
                fillOpacity: fillOpacity
            )
        )
    }
}

/// The two user-tunable numbers behind the glass washes.
///
/// 外观 → 主题 → **背景不透明度** writes `AppSettings.glassOpacity` and drives
/// *the window's own layer only* (`LiquidGlassWash` / `windowWash(for:)`).
/// **板块不透明度** writes `AppSettings.panelOpacity` and drives the three
/// vertical column cards — their coat, their depth plate and the grouped slabs
/// and list insets nested inside them (`GlassWash.fill`).
///
/// 2026-10-25: this used to be **one** number for both layers. The owner asked
/// for two sliders ("一个控制背景，一个控制三个板块"), so the value split and the
/// panel layer moved onto `panelWash`. The split is a *pure* re-parameterisation
/// at the default: `panelWash` uses the same reference wash and the same tier
/// numbers as before, so the shipped 8 % reproduces the pre-split card stack to
/// the pixel (coat 0.06 × 0.08/0.15 = 0.032, plate 4.5 % / 8 %) — an untouched
/// install looks exactly like it did.
///
/// **The numbers are opacities, not transparencies**: larger = more coat =
/// more opaque. Both sliders span 0.00–1.00; the middle of the old 0.05–0.40
/// range is still exactly what it looked like before, which is why existing
/// preferences need no migration.
///
/// The window value is the **dark-appearance window wash**; the light appearance
/// keeps the original 0.04 : 0.15 ratio, so 浅色 is always fainter than 深色. The
/// wash tiers keep their original relative order too (0.06 card / 0.20 slab /
/// 0.10 inset) because they scale by the same factor on the panel slider.
///
/// The two layers never read each other's number. Moving 背景不透明度 cannot
/// change the panel alphas, and moving 板块不透明度 cannot change the window
/// wash — that is what "两个维度独立" means operationally, and the self test
/// pins it (`runAppearanceTopicTests`).
///
/// `@Observable` matters: the sliders should repaint the main window and the
/// clipboard panel while the user is still dragging, without posting a global
/// notification for something that changes on every tick.
@MainActor
@Observable
final class GlassOpacityRuntime {
    static let shared = GlassOpacityRuntime()

    /// The slider's full span: 0.00 = glass only, 1.00 = a solid coat.
    ///
    /// It used to stop at 0.40, which hid most of the range: the owner asked
    /// for 0–1, so the two ends are now the real extremes instead of two taste
    /// positions. The number keeps meaning exactly what it always did — the
    /// dark-appearance window wash — which is why an existing preference keeps
    /// its look and never needs migrating.
    static let range: ClosedRange<Double> = 0.0...1.0
    /// The shipped recipe's dark-mode window wash (f00e22f). Everything else is
    /// expressed relative to it, so the *stored number* always means "dark
    /// window wash" and the tiers keep their ratio.
    ///
    /// 2026-10-24: 0.15 → 0.08. The slider now spans 0–1, so the default had to
    /// move with it: the owner asked for a visibly thinner glass, and 0.08 is
    /// just under half the old wash. Measured over a vivid photo backdrop
    /// (2026-10-24, "behind the window" probe): the empty card ground moves
    /// 99.8 → 110.9 in 深色 and 210.9 → 207.1 in 浅色, and white body ink on the
    /// new ground still measures 5.0:1 深色 / 9.3:1 浅色 (`darkScrim` holds the
    /// floor; it is not scaled).
    ///
    /// 2026-10-25: this number is now **only** the window wash. The `GlassWash`
    /// tiers used to scale with it (card 0.28 → 0.149, slab 0.107, inset 0.053
    /// at 8 %); they scale with `panelDefaultValue` instead, at the identical
    /// factor, so the shipped look did not move.
    static let defaultValue: Double = 0.08
    /// 板块不透明度's default. **Deliberately equal to `defaultValue`**, because
    /// the panel tiers were authored on the same `referenceWash` scale as the
    /// window's: at 8 % the card coat is 0.06 × (0.08 / 0.15) = 0.032 and the
    /// plate is its authored 4.5 % / 8 %, which is exactly the pre-split card
    /// stack. Splitting the one slider into two therefore changes nothing until
    /// the user moves something — the owner's requirement was "拆分后默认状态
    /// 下三栏看起来和现在一样".
    static let panelDefaultValue: Double = 0.08
    /// The wash the `GlassWash` tiers were authored against (f00e22f), and the
    /// fixed anchor for `washScale` — deliberately **not** `defaultValue`.
    ///
    /// Normalising by the default was the first version of this and it was
    /// wrong: `0.08 / 0.08` is 1.0, so moving the default down thinned only the
    /// window and left every column at full tint. The tier numbers below *are*
    /// the 0.15 recipe, so 0.15 has to stay the divisor for a lower default to
    /// mean "the whole recipe got thinner" (0.08 → scale 0.533 → card 0.149,
    /// slab 0.107, inset 0.053). It also keeps the slider honest: 0.15 still
    /// reproduces the old approved look exactly.
    static let referenceWash: Double = 0.15
    /// The light wash at the default: the recipe's 0.04 : 0.15 ratio, kept so
    /// 浅色 stays fainter than 深色 and both move with the same slider. That
    /// ratio (×0.2667) is what `windowWash(for:)` applies.
    static let defaultLightWash: Double = 0.0213

    private(set) var windowWashDark: Double = defaultValue
    /// 板块不透明度, i.e. the panel layer's wash. Same units and same
    /// `referenceWash` anchor as `windowWashDark`, so the two sliders read the
    /// same way on screen (0 % clear, 100 % solid) without either one borrowing
    /// the other's number.
    private(set) var panelWash: Double = panelDefaultValue

    /// Multiplier applied to the window wash: 0.533 at the default,
    /// 1.0 at the 0.15 recipe.
    var washScale: Double { windowWashDark / Self.referenceWash }

    /// Multiplier applied to every `GlassWash` tier — the column coat, the
    /// grouped slabs and the list insets: 0 at 0 %, 0.533 at the shipped 8 %
    /// default (the pre-split number), and **capped at 1** above 15 %.
    ///
    /// The cap is what keeps 板块不透明度 honest at the top of its range. These
    /// tiers are `windowBackgroundColor` — *white* in 浅色 — so scaling them
    /// without a ceiling turned the columns into white sheets at 100 % (measured
    /// on the 0.5 grey backdrop: the list area read 199 where the card border
    /// read 148, i.e. the panel got *lighter* than its own ground). The coat is
    /// the nap, not the depth: it stops growing at the 0.15 recipe and the plate
    /// below carries the rest of the range, so every step of the slider deepens
    /// the card instead of bleaching it.
    var panelScale: Double { min(1, panelWash / Self.referenceWash) }

    /// Multiplier for the column depth plate — the black floor under a column.
    ///
    /// The plate used to be a constant, which is why 0 % could not erase the
    /// cards. The owner explicitly asked for it to be handed over to the panel
    /// slider as well ("把这个固定 plate 也交给 `panelOpacity` 控制，否则 0% 仍然
    /// 清不掉"), so 0 % → no plate at all.
    ///
    /// It is normalised by `panelDefaultValue`, **not** by `referenceWash`:
    /// 1.0 at the shipped 8 % means the authored 4.5 % / 8 % plate is untouched
    /// by the split, and the top of the slider deepens it — 12.5× at 100 % turns
    /// the authored plate into 56 % black in 浅色 and a fully opaque plate in
    /// 深色 (the alpha itself is clamped at 1 in `columnPlateColor`, because a
    /// plate cannot be more than opaque). Because `panelScale` stops at the 0.15
    /// recipe, this plate is the only tier still moving above 15 %: every
    /// remaining step of the slider deepens the columns.
    var panelPlateScale: Double {
        max(0, panelWash / Self.panelDefaultValue)
    }

    /// Window-background wash for the current appearance.
    func windowWash(for scheme: ColorScheme) -> Double {
        scheme == .dark
            ? windowWashDark
            : windowWashDark * (Self.defaultLightWash / Self.defaultValue)
    }

    func apply(_ value: Double) {
        let clamped = min(max(value, Self.range.lowerBound), Self.range.upperBound)
        guard clamped != windowWashDark else { return }
        windowWashDark = clamped
    }

    /// 板块不透明度. Clamped by the same 0–1 `range`; never touches
    /// `windowWashDark`.
    func applyPanel(_ value: Double) {
        let clamped = min(max(value, Self.range.lowerBound), Self.range.upperBound)
        guard clamped != panelWash else { return }
        panelWash = clamped
    }
}

/// The neutral base coat drawn inside a glass surface.
///
/// The glass is a sampling layer, so on its own the wallpaper runs straight
/// through the list text. Each tier lays a translucent copy of the window
/// background colour over it — off-white in Aqua, near-black in Dark Aqua — so
/// contrast rises in both appearances without turning the card opaque. A
/// label-colour tint (the old 2–3 % `Color.primary`) would do the opposite:
/// it tracks the text colour, so it closes the contrast gap it should open.
enum GlassWash {
    /// The five window columns (`floatingCard`), closest to the wallpaper.
    ///
    /// 2026-10-25 history, in order, because each step fixed the previous one:
    ///
    /// 1. 0.28 → 0.10. The card's flat plate was resolving
    ///    `windowBackgroundColor` in the *process* appearance (dark, because the
    ///    system is dark) while the window was forced 浅色, so a near-black 20 %
    ///    plate was painted inside a light window and the columns measured
    ///    −15.6 RGB. Fixing the appearance and thinning the coat to 0.10 plus a
    ///    6 % plate brought them to +6.4 at 8 % and +4.4 at 0 % — the "three
    ///    blocks vanished" report.
    /// 2. This revision: **middle ground**. The plate is no longer a copy of the
    ///    window background (which is white in 浅色, so it *lifted* the card);
    ///    it is a fixed black depth wash, and the scalable coat is 0.06 instead
    ///    of 0.10 so the slider's white coat cannot cancel the depth it sits
    ///    on. Measured card − window ΔRGB, over a controlled 0.5 grey backdrop:
    ///    **−6.8 / −7.8** (浅色 8 % / 0 %) and **−6.5 / −5.5** (深色 8 % / 0 %).
    /// 3. 2026-10-25 (two sliders): the tiers below are **板块不透明度**'s, not
    ///    背景不透明度's — `GlassWash.fill` scales them by
    ///    `GlassOpacityRuntime.panelScale`. The numbers themselves did not move,
    ///    so at the panel default (8 %, the same normalisation) the card stack is
    ///    bit-for-bit what step 2 measured. The plate is no longer exempt from
    ///    the slider (see `columnPlate`), which is what lets 0 % actually erase
    ///    the card.
    static let card: Double = 0.06
    /// The depth plate under a column: the card's material floor, and — since
    /// 2026-10-25 — part of the **板块不透明度** layer.
    ///
    /// It used to be a fixed number, independent of any slider ("0 % 仍然清不掉"
    /// was the consequence). The owner asked for it to follow 板块不透明度 too,
    /// so the runtime multiplies it by `panelPlateScale`: 0 at 0 %, 1× at the
    /// shipped 8 % default (these authored values), and up to 4.5 % → 56 % /
    /// 8 % → opaque toward 100 %, where the columns read as solid cards.
    ///
    /// A black wash rather than `windowBackgroundColor` on purpose: in 浅色 the
    /// window background is pure white, so a "window-coloured" plate made the
    /// column *lighter* than the window and the three blocks disappeared. Black
    /// is the only tint that reads as depth in both appearances. It also has to
    /// carry the top of the panel range: the coat is `windowBackgroundColor`
    /// (*white* in 浅色), so a coat-only recipe would bleach the columns out
    /// instead of deepening them at 100 %.
    static let columnPlateDark: Double = 0.08
    static let columnPlateLight: Double = 0.045

    static func columnPlate(dark: Bool) -> Double {
        dark ? columnPlateDark : columnPlateLight
    }
    /// Grouped slabs nested inside a page.
    static let slab: Double = 0.20
    /// A content area inside a card (history list, preview pane).
    static let inset: Double = 0.10

    /// A dark-appearance floor under the window glass, **not** scaled by
    /// 背景不透明度.
    ///
    /// The wash above is tuned for a dark wallpaper, where the glass lands near
    /// #2a. Over a bright window it is not enough: a white page behind the
    /// clipboard panel lifted its ground to #8a and every white label fell
    /// below 4.5:1 (the count capsule measured 2.2:1, a selected row title
    /// 2.9:1). This coat is the same near-black `windowBackgroundColor` the
    /// wash already uses: it leaves the dark wallpaper almost untouched (≈8
    /// RGB) while capping a white backdrop near #4b, where primary ink is
    /// ≈9:1.
    ///
    /// 2026-10-24: 0.50 → 0.48 together with the 0.15 → 0.08 wash, so 深色 got
    /// thinner too instead of the floor hiding the change. Measured on a vivid
    /// photo backdrop: the empty card ground moves #63 → #6f and white body ink
    /// on it measures 5.0:1; over the worst case (a white page, the self-test's
    /// `#8b` raw glass) white ink reads 4.95:1, down from 5.25:1 but still
    /// above 4.5:1.
    ///
    /// The 4.5 guarantee is *for the shipped 8 % default and brighter pages*,
    /// not for every reachable state: at 0 % the glass is fully clear, so
    /// contrast is whatever the wallpaper gives (4.2–4.9:1 on that vivid
    /// photo). A floor high enough to fix that would make the slider's
    /// transparent end a lie, which is the worse trade.
    ///
    /// It is deliberately **not** multiplied by the 背景不透明度 slider: the
    /// slider is a taste control, but white-on-glass legibility is not optional,
    /// so the floor survives the most transparent setting.
    static let darkScrim: Double = 0.48

    /// The legibility floor for a plate that floats over **arbitrary in-window
    /// content** — the pinned-image toolbar, whose backdrop is whatever picture
    /// the user pinned rather than the window's own glass.
    ///
    /// The window recipe can get away without a light floor because the window
    /// background is opaque; a plate over a photograph cannot. Measured on the
    /// pinned toolbar at 2×, median of the plate's interior, on a **pure black**
    /// and a **pure white** picture (the worst case for each ink colour; the
    /// original 6.0 / 5.0 were taken on a near-black and a "white page" picture,
    /// which are gentler than these):
    ///
    /// * 浅色, black picture: 0.35 of white leaves the plate at #808080, where
    ///   black `.primary` ink is **5.3:1**; 0.42 lifts it to #8b8b8b and
    ///   **6.2:1**. On a white picture the plate is already #f2f2f2 and stays
    ///   there (#f1f1f1 measured) — white-plus-white cannot get brighter.
    /// * 深色, white picture: 0.62 of near-black leaves the plate at #6f6f6f,
    ///   where white `.primary` ink is **5.0:1**; 0.59 lifts it to #747474 and
    ///   **4.7:1**. The plate moves about five levels per 0.03 of alpha here, so
    ///   the next hundredth down (0.58) sits on the 4.5 line; 0.59 keeps a small
    ///   margin and is the last step that still promises 4.5:1.
    ///
    /// 深色 needs the larger number because its ink is white: white-on-bright
    /// loses contrast faster than black-on-dark, and the two ends are tuned
    /// independently for that reason, not for symmetry.
    ///
    /// 2026-10-25 (owner: the toolbar plate is "有点暗"): the two ends move in
    /// **opposite directions**, because the floor is the appearance's window
    /// background — near-black in 深色, white in 浅色. Lowering the 深色 alpha
    /// makes its plate brighter (0.62 → 0.59). Lowering the 浅色 alpha would do
    /// the opposite: it *removes* white and darkens the plate, so that end went
    /// **up** (0.35 → 0.42) to answer the same request. "Brighter" and "more
    /// transparent" are not both available in 浅色 over a dark picture; the owner
    /// asked for brighter, so the plate trades a little transmission for it.
    static func plateFloor(dark: Bool) -> Double {
        dark ? 0.59 : 0.42
    }

    /// Every in-window tier is scaled by **板块不透明度**, so the column coat,
    /// the grouped slabs and the list insets move together instead of drifting
    /// out of balance. The window's own wash is *not* this function — that one
    /// reads `windowWash(for:)` and the 背景不透明度 slider.
    ///
    /// The product is clamped at 1. `panelScale` itself already stops at the
    /// 0.15 recipe (see above), so the clamp only guards a tier that would
    /// exceed 1 through a hand-edited value; keeping it here means a tier can
    /// never ask for an alpha SwiftUI would silently squash.
    @MainActor
    static func fill(_ amount: Double) -> Color {
        Color(nsColor: .windowBackgroundColor)
            .opacity(min(1, amount * GlassOpacityRuntime.shared.panelScale))
    }
}

/// The two official AppKit glass styles, laid out by what they are for.
///
/// * `.regular` — the window's own back layer. Its job is to sit on the desktop
///   and give the window a glass body.
/// * `.clear` / `.thin` — **every in-window surface**: the three columns and
///   each `GroupSlab`. They are drawn on top of the window's glass, so the
///   `.regular` material would stack a second heavy tint onto the first and
///   read as an opaque dark card (measured: 0.39 grey over a photo wallpaper,
///   i.e. no visible wallpaper structure). `.clear` is Apple's style for glass
///   over already-rich content and transmits the backdrop instead.
///
/// `NSGlassEffectView` only exposes `.regular` and `.clear`; `.thin` is the
/// historical name for the nested-slab variant and maps to `.clear`.
enum GlassStyleKind: String, CaseIterable, Sendable {
    case regular
    case clear
    case thin

    @available(macOS 26.0, *)
    var appKitStyle: NSGlassEffectView.Style {
        switch self {
        case .regular: .regular
        case .clear, .thin: .clear
        }
    }

    /// The style used by everything that sits *inside* the window.
    static let surface: GlassStyleKind = .clear
}

/// What colour the flat plate under a glass surface is.
///
/// Two recipes exist, and they are not interchangeable:
///
/// * `.windowBackground` — a translucent copy of the window background. Every
///   small surface (toolbar plate, viewfinder card) uses it, because those sit
///   on content and should read as "frosted window", not "darker panel".
/// * `.columnDepth` — the three window columns. They need to read as *slightly
///   deeper* than the window in both appearances, and they own that depth
///   through 板块不透明度 (0 % erases it, 100 % makes it solid). A
///   window-background tint cannot do that: in 浅色 the window background is
///   white, so it lifts the card instead of settling it.
enum GlassPlateStyle: String, Sendable {
    case windowBackground
    case columnDepth
}

/// A reusable Liquid Glass surface.
///
/// macOS 26+ uses the official `NSGlassEffectView`; macOS 14/15 (and 经典 theme
/// mode) fall back to `NSVisualEffectView`. Two further fallbacks keep the app
/// honest:
///
/// * **纯色 background** paints an opaque card — glass over an opaque window
///   would either look transparent (broken) or sample nothing.
/// * **Offscreen rendering** (no window, e.g. `cacheDisplay(in:to:)` in the
///   self test) also paints an opaque card, because a glass/blur layer rendered
///   without a window-server composite comes out black or fully transparent.
///
/// Only large containers use this. Never one per row: each glass view is a
/// separate compositor pass.
struct GlassSurface: View {
    var cornerRadius: CGFloat = 12
    var style: GlassStyleKind = .surface
    var interactive: Bool = false
    var tint: Color?
    /// A neutral wash drawn inside the glass. This is what visually separates a
    /// nested slab from the card behind it without a second opaque layer.
    var fillOpacity: Double = 0
    var plateAlpha: Double = 0.20
    /// Which plate recipe this surface paints. `.columnDepth` ignores
    /// `plateAlpha` and uses the appearance-tuned depth plate instead, scaled by
    /// 板块不透明度 (`GlassOpacityRuntime.panelPlateScale`).
    var plateStyle: GlassPlateStyle = .windowBackground
    /// Pin this surface to one background tier instead of following
    /// 外观 → 背景. The pinned-image toolbar uses it: that plate is always the
    /// 液态玻璃 recipe, exactly like the capture toolbar's, because it floats
    /// over the pinned picture rather than over the app's window — and the
    /// picture is what it has to sample in every setting.
    var backgroundStyle: AppBackgroundStyle?
    /// How the material samples its backdrop. See
    /// `GlassSurfaceFactory.makeBackdrop(blending:)`: `.behindWindow` (the
    /// default) samples the desktop through the window, which is right for a
    /// window-level surface. A plate that floats **over content inside the same
    /// window** — the pinned-image toolbar over the pinned picture — has to
    /// pass `.withinWindow`, or it samples the desktop behind a transparent
    /// panel and the picture it sits on never shows through.
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    /// The material used when `blending` asks for real sampling.
    var material: NSVisualEffectView.Material = .underWindowBackground
    var showsBorder: Bool = true
    /// The outline a surface draws. The three columns use a slightly stronger
    /// hairline than the shipped 6 % so the structure survives the thinner card.
    var borderColor: Color = SelectionStyle.stroke
    /// Experiment: the surface's own colour scheme, so AppKit colours resolve
    /// in the forced appearance instead of the process default.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            GlassSurfaceRepresentable(
                cornerRadius: cornerRadius,
                style: style,
                interactive: interactive,
                tint: tint,
                colorScheme: colorScheme,
                plateAlpha: plateAlpha,
                plateStyle: plateStyle,
                backgroundStyle: backgroundStyle,
                blending: blending,
                material: material
            )

            if fillOpacity > 0 {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(GlassWash.fill(fillOpacity))
            }

            if showsBorder {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        // A background must never swallow clicks meant for the content above it.
        .allowsHitTesting(false)
    }
}

/// SwiftUI wrapper around the AppKit backdrop. The AppKit side decides which
/// concrete view to install because only it knows whether it has a window.
struct GlassSurfaceRepresentable: NSViewRepresentable {
    var cornerRadius: CGFloat
    var style: GlassStyleKind
    var interactive: Bool
    var tint: Color?
    var colorScheme: ColorScheme
    var plateAlpha: Double
    var plateStyle: GlassPlateStyle
    var backgroundStyle: AppBackgroundStyle?
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> GlassSurfaceContainer {
        let view = GlassSurfaceContainer()
        view.configure(
            cornerRadius: cornerRadius,
            style: style,
            interactive: interactive,
            tint: tint,
            colorScheme: colorScheme,
            plateAlpha: plateAlpha,
            plateStyle: plateStyle,
            backgroundStyle: backgroundStyle,
            blending: blending,
            material: material
        )
        return view
    }

    func updateNSView(_ view: GlassSurfaceContainer, context: Context) {
        view.configure(
            cornerRadius: cornerRadius,
            style: style,
            interactive: interactive,
            tint: tint,
            colorScheme: colorScheme,
            plateAlpha: plateAlpha,
            plateStyle: plateStyle,
            backgroundStyle: backgroundStyle,
            blending: blending,
            material: material
        )
    }
}

/// Container that re-evaluates its backdrop when it gains or loses a window.
/// SwiftUI creates the representable before the window is attached, so the
/// first build is always the offscreen fallback; `viewDidMoveToWindow` then
/// swaps in the live glass.
@MainActor
final class GlassSurfaceContainer: NSView {
    private var backdrop: NSView?
    private var cornerRadius: CGFloat = 12
    private var style: GlassStyleKind = .regular
    private var interactive = false
    private var tint: NSColor?
    private var colorScheme: ColorScheme = .light
    private var plateAlpha: Double = 0.20
    private var plateStyle: GlassPlateStyle = .windowBackground
    /// How the backdrop samples (see `GlassSurfaceFactory.makeBackdrop`), and
    /// with which material. `.behindWindow` is the desktop-sampling default
    /// every window-level surface uses; the pinned-image toolbar passes
    /// `.withinWindow` so the picture it floats over is what gets sampled.
    private var blending: NSVisualEffectView.BlendingMode = .behindWindow
    private var material: NSVisualEffectView.Material = .underWindowBackground
    /// When set, the surface stays on this background tier instead of
    /// following 外观 → 背景 (see `GlassSurface.backgroundStyle`).
    private var backgroundStyleOverride: AppBackgroundStyle?
    /// Runtime state the current backdrop was built for. `configure` compares
    /// these so changing 外观 → 背景 (or 主题风格) swaps the live backdrop
    /// instead of leaving a stale NSGlassEffectView under an opaque window.
    private var builtForTier: AppBackgroundStyle = .solid
    private var builtWithGlass = true
    /// The 板块不透明度 the current plate was built with. The plate is an AppKit
    /// layer colour, not a SwiftUI modifier, so a drag on the panel slider only
    /// reaches it through `configure` → `rebuild`.
    private var builtForPanel: Double = GlassOpacityRuntime.panelDefaultValue

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }

    func configure(
        cornerRadius: CGFloat,
        style: GlassStyleKind,
        interactive: Bool,
        tint: Color?,
        colorScheme: ColorScheme = .light,
        plateAlpha: Double = 0.20,
        plateStyle: GlassPlateStyle = .windowBackground,
        backgroundStyle: AppBackgroundStyle? = nil,
        blending: NSVisualEffectView.BlendingMode = .behindWindow,
        material: NSVisualEffectView.Material = .underWindowBackground
    ) {
        let tintColor = tint.map { NSColor($0) }
        // A pinned tier ignores the global 外观 → 背景 while it is pinned, so
        // moving that setting must not rebuild this backdrop.
        let tier = backgroundStyle ?? AppearanceRuntime.backgroundStyle
        let runtimeChanged = tier != builtForTier
            || AppearanceRuntime.useGlass != builtWithGlass
        // Only the depth plate reads 板块不透明度; every other surface's plate is
        // a constant tint, so this comparison is skipped for them.
        let panelPlateChanged = plateStyle == .columnDepth
            && GlassOpacityRuntime.shared.panelWash != builtForPanel
        let changed = cornerRadius != self.cornerRadius
            || style != self.style
            || interactive != self.interactive
            || colorScheme != self.colorScheme
            || plateAlpha != self.plateAlpha
            || plateStyle != self.plateStyle
            || backgroundStyle != self.backgroundStyleOverride
            || blending != self.blending
            || material != self.material
            || !Self.sameColor(tintColor, self.tint)
        self.cornerRadius = cornerRadius
        self.style = style
        self.interactive = interactive
        self.tint = tintColor
        self.colorScheme = colorScheme
        self.plateAlpha = plateAlpha
        self.plateStyle = plateStyle
        self.blending = blending
        self.material = material
        self.backgroundStyleOverride = backgroundStyle
        if changed || runtimeChanged || panelPlateChanged || backdrop == nil {
            builtForTier = tier
            builtWithGlass = AppearanceRuntime.useGlass
            builtForPanel = GlassOpacityRuntime.shared.panelWash
            rebuild()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rebuild()
    }

    override func layout() {
        super.layout()
        backdrop?.frame = bounds
    }

    /// Test hook: the installed backdrop's concrete class.
    var backdropViewForTesting: NSView? { backdrop }

    private func rebuild() {
        let live = window != nil
        let new = GlassSurfaceFactory.makeBackdrop(
            cornerRadius: cornerRadius,
            style: style,
            interactive: interactive,
            tint: tint,
            plateAlpha: plateAlpha,
            plateColor: plateStyle == .columnDepth
                ? GlassSurfaceFactory.columnPlateColor(dark: colorScheme == .dark)
                : nil,
            offscreen: !live,
            appearance: resolvedAppearance,
            backgroundStyle: backgroundStyleOverride ?? AppearanceRuntime.backgroundStyle,
            blending: blending,
            material: material
        )
        let replaced = new !== backdrop
        if replaced {
            backdrop?.removeFromSuperview()
            new.frame = bounds
            new.autoresizingMask = [.width, .height]
            addSubview(new)
            backdrop = new
            needsLayout = true
        }
    }

    /// The appearance this surface renders in. SwiftUI's
    /// `.preferredColorScheme` is not the process appearance (设置 → 外观 overrides
    /// the system), so resolving `windowBackgroundColor` without this context
    /// produced a near-black plate inside a light window: exactly the "三栏比
    /// 窗口背景深一截" report.
    private var resolvedAppearance: NSAppearance {
        NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
            ?? NSApp?.effectiveAppearance
            ?? NSAppearance(named: .aqua)!
    }

    private static func sameColor(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?): lhs.isEqual(rhs)
        default: false
        }
    }
}

/// Builds the concrete backdrop. Pulled out of the container so the self test
/// can assert the class produced for each combination without a window server.
@MainActor
enum GlassSurfaceFactory {
    /// Opaque card colour for 纯色 and offscreen renders. This is the old
    /// `floatingCard` tint (window background + 5 % label) baked into a single
    /// opaque colour, so the card keeps its shape without any transparency.
    static func opaqueCardColor(
        for appearance: NSAppearance = NSApp?.effectiveAppearance
            ?? NSAppearance(named: .aqua)!
    ) -> NSColor {
        var resolved = NSColor.windowBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            let base = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)
                ?? NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
            let label = NSColor.labelColor.usingColorSpace(.sRGB)
                ?? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
            resolved = (base.blended(withFraction: 0.05, of: label) ?? base)
        }
        // The fallback must be genuinely opaque: `blended` can carry a 0.99
        // alpha from the system colours, which would make an offscreen card
        // slightly see-through.
        return resolved.withAlphaComponent(1)
    }

    static func makeBackdrop(
        cornerRadius: CGFloat,
        style: GlassStyleKind,
        interactive: Bool = false,
        tint: NSColor? = nil,
        plateAlpha: Double = 0.20,
        /// Explicit plate colour; `nil` means "a copy of the window background
        /// at `plateAlpha`", which is what every small surface wants. The three
        /// columns pass the fixed depth tint instead (see `GlassPlateStyle`).
        plateColor: NSColor? = nil,
        offscreen: Bool,
        appearance: NSAppearance? = nil,
        backgroundStyle: AppBackgroundStyle = AppearanceRuntime.backgroundStyle,
        glassAllowed: Bool = AppearanceRuntime.useGlass,
        /// How the material samples. `.behindWindow` — the historical default
        /// for every window-level surface — blurs the desktop showing through
        /// the (non-opaque) window. `.withinWindow` blurs the content **inside
        /// this window**, which is the only correct mode for a plate that
        /// floats over in-window content: the pinned-image toolbar sits on a
        /// picture drawn in its own panel, so `.behindWindow` sampled the
        /// desktop behind the transparent panel and the picture never showed
        /// through.
        blending: NSVisualEffectView.BlendingMode = .behindWindow,
        /// Material used when sampling is on. `.underWindowBackground` is what
        /// the rest of the app's blur surfaces already install.
        material: NSVisualEffectView.Material = .underWindowBackground
    ) -> NSView {
        // The surface's own appearance; falls back to the process appearance for
        // callers that cannot supply one (the capture overlay's viewfinder).
        let surfaceAppearance = appearance
            ?? NSApp?.effectiveAppearance
            ?? NSAppearance(named: .aqua)!
        // 纯色 and offscreen: opaque card, never glass, never transparent.
        guard !offscreen, backgroundStyle != .solid else {
            let card = GlassCardBackdropView()
            card.wantsLayer = true
            card.layer?.backgroundColor = opaqueCardColor(for: surfaceAppearance).cgColor
            card.layer?.cornerRadius = cornerRadius
            card.layer?.cornerCurve = .continuous
            card.layer?.masksToBounds = true
            return card
        }

        if backgroundStyle == .liquidGlass {
            // A blurred, lightly tinted panel. The blur is clipped to the same
            // continuous corner as the card, otherwise its square edges show up
            // as stray lines and bites at the corners.
            let container = NSView()
            container.wantsLayer = true
            container.layer?.cornerRadius = cornerRadius
            container.layer?.cornerCurve = .continuous
            container.layer?.masksToBounds = true
            let plate = plateColor ?? liquidGlassTint(
                CGFloat(plateAlpha),
                appearance: surfaceAppearance
            )
            // Only sample when the caller asked for in-window content. On a
            // window-level surface there is nothing of ours behind the plate
            // but the window's own glass, and every blur tried there reads as
            // fog on a card this small — that is why the shipped recipe is a
            // flat tint.
            guard blending == .withinWindow else {
                container.layer?.backgroundColor = plate.cgColor
                return container
            }
            // In-window content *does* need sampling: the pinned-image
            // toolbar floats on the pinned picture, and the picture has to be
            // visible under the plate, not the desktop behind the transparent
            // panel. The recipe is still the app's: the official glass (or, in
            // 经典, the same material the older systems use) samples, and the
            // exact same `liquidGlassTint` wash goes on top — one material,
            // one tint.
            var samplesWithGlass = false
            if #available(macOS 26.0, *), glassAllowed {
                let glass = NSGlassEffectView()
                // `.surface` is `.clear`: the app measured that a second
                // `.regular` stacked on the window's own glass reads as an
                // opaque slab, and over a picture the clear style is what lets
                // the picture through.
                glass.style = style.appKitStyle
                glass.cornerRadius = cornerRadius
                glass.wantsLayer = true
                glass.frame = container.bounds
                glass.autoresizingMask = [.width, .height]
                container.addSubview(glass)
                samplesWithGlass = true
            } else {
                let blur = VisualEffectBackdrop.makeBackdrop(material: material, blending: blending)
                blur.frame = container.bounds
                blur.autoresizingMask = [.width, .height]
                container.addSubview(blur)
            }
            let wash = NSView()
            wash.wantsLayer = true
            wash.layer?.backgroundColor = plate.cgColor
            wash.frame = container.bounds
            wash.autoresizingMask = [.width, .height]
            container.addSubview(wash)
            // A legibility floor for the *official glass* only. The pre-26
            // material is already semi-opaque and follows the appearance, so it
            // keeps `.primary` ink readable on its own (that is why the rest of
            // the app trusts it). The Liquid Glass style is far more
            // transmissive — measured on the pin toolbar at 2×, over a
            // near-black picture it left the plate at #56575a where black ink
            // is 2.9:1 — so a plate over arbitrary user content needs the same
            // kind of floor the window recipe has in `GlassWash.darkScrim`.
            if samplesWithGlass {
                let floorView = NSView()
                floorView.wantsLayer = true
                let dark = surfaceAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                floorView.layer?.backgroundColor = liquidGlassTint(
                    CGFloat(GlassWash.plateFloor(dark: dark)),
                    appearance: surfaceAppearance
                ).cgColor
                floorView.frame = container.bounds
                floorView.autoresizingMask = [.width, .height]
                container.addSubview(floorView)
            }
            return container
        }

        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = cornerRadius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        let blur = VisualEffectBackdrop.makeBackdrop(material: material, blending: blending)
        blur.frame = container.bounds
        blur.autoresizingMask = [.width, .height]
        container.addSubview(blur)
        return container
    }
}

extension GlassSurfaceFactory {
    /// The depth plate for the three window columns.
    ///
    /// A black wash, not the window background: in 浅色 `windowBackgroundColor`
    /// is white, so a window-coloured plate lifted the card away from the window
    /// and the columns read as a brighter rectangle. Black settles the card
    /// *into* the window in both appearances.
    ///
    /// 2026-10-25: the authored alpha (`GlassWash.columnPlate`) is multiplied by
    /// `panelPlateScale`, i.e. the plate now belongs to the **板块不透明度**
    /// slider. At the shipped default the multiplier is exactly 1 and the plate
    /// is the 4.5 % / 8 % it always was; at 0 % it is zero, which is what makes
    /// 0 % mean "the card ground is gone, only the hairline and the content
    /// remain"; toward 100 % it deepens to the point where the column is a solid
    /// card.
    static func columnPlateColor(dark: Bool) -> NSColor {
        let alpha = min(
            1,
            GlassWash.columnPlate(dark: dark)
                * GlassOpacityRuntime.shared.panelPlateScale
        )
        return NSColor.black.withAlphaComponent(alpha)
    }

    /// The plate tint every **small** glass surface shares: the 液态玻璃
    /// recipe's 20 % window-background wash. The toolbar's plate and the
    /// scrolling viewfinder's card read this one number, which is what keeps two
    /// surfaces in two different windows looking like the same material.
    static func liquidGlassTint(_ alpha: CGFloat = 0.20, appearance: NSAppearance? = nil) -> NSColor {
        var base = NSColor.windowBackgroundColor
        let resolve = {
            base = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)
                ?? NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        }
        if let appearance {
            appearance.performAsCurrentDrawingAppearance(resolve)
        } else {
            resolve()
        }
        return base.withAlphaComponent(alpha)
    }
}

/// The main window's background. `solid` is the classic opaque surface;
/// `translucent` blurs the desktop; `liquidGlass` is the official system glass
/// (or the same blur on older systems) with nothing painted on top.
struct AppBackground: View {
    let style: AppBackgroundStyle

    var body: some View {
        switch style {
        case .solid:
            Color(nsColor: .windowBackgroundColor)
        case .translucent:
            // The blur is the window's body; this coat is the only thing
            // dimming it. 0.60 read as a grey sheet over a bright desktop, so
            // 2026-10-24 took it to 0.48 — the same "one step thinner" as the
            // 液态玻璃 wash, which is what keeps 半透明 and 液态玻璃 feeling like
            // the same family rather than two unrelated materials.
            ZStack {
                VisualEffectBackdrop()
                Color(nsColor: .windowBackgroundColor).opacity(0.48)
            }
        case .liquidGlass:
            // The original recipe, restored: official full-window glass, a 20%
            // system-background wash for legibility, a diagonal gradient for
            // depth and a soft radial highlight from above the window. Stripping
            // these left the material reading as a flat bright sheet.
            ZStack {
                GlassBackdropView()
                LiquidGlassWash()
            }
        }
    }
}

/// The wash drawn on top of `GlassBackdropView`.
///
/// Shared by the main window and the floating clipboard panel so both surfaces
/// read as the same material: a translucent window-background coat, a diagonal
/// gradient for depth and a soft radial highlight from above. The light
/// appearance needs far less wash — `windowBackgroundColor` is almost white
/// there, so the dark-mode percentages would turn the surface into a grey sheet.
struct LiquidGlassWash: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            // The one tier the 背景不透明度 slider names directly: dark takes
            // the user's value, light keeps the recipe's 0.04 : 0.15 ratio.
            // 板块不透明度 never reaches this view — the window layer and the
            // panel layer are independent.
            Color(nsColor: .windowBackgroundColor)
                .opacity(GlassOpacityRuntime.shared.windowWash(for: scheme))
            // Dark only: a fixed floor that keeps a bright window from turning
            // the glass into a light-grey sheet under white text. Light is
            // untouched — it already sits above 4.5:1 over bright content.
            if scheme == .dark {
                Color(nsColor: .windowBackgroundColor)
                    .opacity(GlassWash.darkScrim)
            }
            LinearGradient(
                colors: [
                    Color.white.opacity(scheme == .dark ? 0.07 : 0.10),
                    Color.clear,
                    Color.black.opacity(scheme == .dark ? 0.07 : 0.04)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [
                    Color.white.opacity(scheme == .dark ? 0.10 : 0.06),
                    Color.white.opacity(0.0)
                ],
                center: .init(x: 0.5, y: -0.15),
                startRadius: 10,
                endRadius: 640
            )
        }
        // A background must never swallow clicks meant for the content above it.
        .allowsHitTesting(false)
    }
}

// MARK: - Restored shared styling (rebuilt after a destructive edit)

/// Which backdrop an `AppBackgroundStyle` installs behind the window.
enum WindowBackdropKind: Equatable {
    case none
    case visualEffect
    case glass
}

extension AppBackgroundStyle {
    var backdropKind: WindowBackdropKind {
        switch self {
        case .solid: .none
        case .translucent: .visualEffect
        case .liquidGlass: .glass
        }
    }
}

/// The one place selection and hover tints are defined. Neutral by design: a
/// solid accent fill is far too loud on top of a translucent surface.
enum SelectionStyle {
    static let cornerRadius: CGFloat = 7
    static let fillOpacity: Double = 0.12
    static let hoverOpacity: Double = 0.06
    static let hoverDuration: Double = 0.12

    static let fill = Color.primary.opacity(fillOpacity)
    static let hoverFill = Color.primary.opacity(hoverOpacity)
    static let stroke = Color.primary.opacity(0.06)
    static let hoverAnimation: Animation = .easeOut(duration: hoverDuration)

    static func resolvedFill(for appearance: NSAppearance) -> NSColor {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return (dark ? NSColor.white : NSColor.black).withAlphaComponent(fillOpacity)
    }

    static func resolvedHoverFill(for appearance: NSAppearance) -> NSColor {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return (dark ? NSColor.white : NSColor.black).withAlphaComponent(hoverOpacity)
    }
}

/// Ink for text that has to be read but must not compete with a row title.
///
/// `.tertiary` is a fixed 25 % alpha in both appearances. On the dark window
/// wash that measures ~2.2:1 — the group footers, the sidebar's section labels
/// and the status-menu rename placeholder were legible only if you already knew
/// what they said. 45 % is the first step that stays near 3.6:1 on both the
/// light and the dark ground while remaining clearly below `Color.secondary`
/// (which is the row-subtitle tier).
enum SupportingInk {
    static let text = Color.primary.opacity(0.45)
}

/// The chip drawn behind a selected (or hovered) row.
struct SelectionBackground: View {
    var selected: Bool
    var hovered: Bool = false
    var cornerRadius: CGFloat = SelectionStyle.cornerRadius

    private var fill: Color {
        if selected { return SelectionStyle.fill }
        if hovered { return SelectionStyle.hoverFill }
        return .clear
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(fill)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(selected ? SelectionStyle.stroke : .clear, lineWidth: 1)
            }
    }
}

/// Per-section accents used by the navigation glyphs.
enum SectionPalette {
    static let history = Color.blue
    static let pins = Color.orange
    static let capture = Color.purple
    static let settings = Color.secondary
}

/// Pointer feedback for a row: a wash fainter than selection, never stacked on
/// top of a selected row.
struct HoverHighlight: ViewModifier {
    var isSelected: Bool
    var isEnabled: Bool
    var cornerRadius: CGFloat
    var inset: EdgeInsets
    var forced: Bool?

    @State private var hovering = false

    private var active: Bool {
        // The forced seam is what the self test uses, so it must honour the
        // same `isEnabled` gate as real hover; otherwise a disabled row would
        // still light up under the test.
        if let forced { return forced && isEnabled && !isSelected }
        return hovering && isEnabled && !isSelected
    }

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(SelectionStyle.hoverFill)
                    .padding(inset)
                    .opacity(active ? 1 : 0)
                    .animation(SelectionStyle.hoverAnimation, value: active)
                    .allowsHitTesting(false)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active: hovering = true
                case .ended: hovering = false
                }
            }
            .onDisappear { hovering = false }
    }
}

extension View {
    func hoverHighlight(
        isSelected: Bool = false,
        isEnabled: Bool = true,
        cornerRadius: CGFloat = SelectionStyle.cornerRadius,
        inset: EdgeInsets = EdgeInsets()
    ) -> some View {
        modifier(
            HoverHighlight(
                isSelected: isSelected,
                isEnabled: isEnabled,
                cornerRadius: cornerRadius,
                inset: inset,
                forced: nil
            )
        )
    }

    /// Test seam: pin the hover state without a real pointer.
    func hoverHighlightForTesting(
        _ active: Bool,
        isSelected: Bool = false,
        isEnabled: Bool = true
    ) -> some View {
        modifier(
            HoverHighlight(
                isSelected: isSelected,
                isEnabled: isEnabled,
                cornerRadius: SelectionStyle.cornerRadius,
                inset: EdgeInsets(),
                forced: active
            )
        )
    }
}

/// AppKit blur backdrop for SwiftUI; `behindWindow` is what actually reveals the
/// desktop, which is why the window is non-opaque on these styles.
struct VisualEffectBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        Self.makeBackdrop(material: material, blending: blending)
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }

    static func makeBackdrop(
        material: NSVisualEffectView.Material = .underWindowBackground,
        blending: NSVisualEffectView.BlendingMode = .behindWindow
    ) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        view.wantsLayer = true
        return view
    }
}

/// A plain layer-backed card: used for the opaque fallback and for panels that
/// must be a flat tint rather than a second material.
final class GlassCardBackdropView: NSView {}

/// The window's back layer: the official material on macOS 26+, the blur below.
struct GlassBackdropView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        Self.makeBackdrop()
    }

    func updateNSView(_ view: NSView, context: Context) {}

    static func makeBackdrop() -> NSView {
        if #available(macOS 26.0, *), AppearanceRuntime.useGlass {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.wantsLayer = true
            return glass
        }
        return VisualEffectBackdrop.makeBackdrop()
    }
}

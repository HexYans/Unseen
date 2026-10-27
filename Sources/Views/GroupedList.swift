import AppKit
import SwiftUI

/// The visual language for the content area: grouped slabs of compact rows,
/// the way iOS Settings (and the Egern app) do it — replacing the big
/// block-per-action cards the app used before.
///
///     GroupHeader("快捷键")
///     GroupSlab {
///         GroupRow(symbol: "command", color: .indigo, title: "打开历史面板") {
///             HotKeyRecorderView(…)
///         }
///     }
struct GroupHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
            .padding(.bottom, 6)
    }
}

/// Rounded container that visually groups its rows.
///
/// The container itself is a `GlassSurface`: on macOS 26 a real Liquid Glass
/// slab, on 14/15 a blur, and an opaque card for 纯色/offscreen renders. Only
/// one glass view per slab — never one per row.
struct GroupSlab<Content: View>: View {
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 0) {
                content
            }
            .background {
                GlassSurface(
                    cornerRadius: 11,
                    style: .thin,
                    fillOpacity: GlassWash.slab
                )
            }
            // Rows highlight edge-to-edge, so the slab clips them: a hover wash
            // on the first or last row would otherwise poke past the slab's
            // rounded corner (a 7 pt row radius is "sharper" than the slab's
            // 11 pt one).
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .background {
                GroupSlabMarker()
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
            }

            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    // The footer explains what the slab does; at `.tertiary`
                    // it read as a smudge on the dark wash.
                    .foregroundStyle(SupportingInk.text)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Invisible marker that makes "this settings page really draws a GroupSlab"
/// assertable from the offline test. A custom NSView class survives SwiftUI's
/// opaque view erasure; nothing else is observable from outside.
struct GroupSlabMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> GroupSlabMarkerView { GroupSlabMarkerView() }
    func updateNSView(_ nsView: GroupSlabMarkerView, context: Context) {}
}

final class GroupSlabMarkerView: NSView {
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}


/// A hairline that starts where the title starts, the way iOS insets them.
struct GroupDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 1)
            .padding(.leading, 50)
    }
}

/// One row: coloured glyph, title (and optional second line), trailing value
/// and/or chevron, optionally a control.
struct GroupRow<Trailing: View>: View {
    var symbol: String?
    /// When set, a small preview image replaces the SF Symbol glyph.
    var thumbnail: NSImage?
    var color: Color = .accentColor
    var title: String
    var subtitle: String?
    var value: String?
    var showsChevron: Bool = false
    var isEnabled: Bool = true
    var action: (() -> Void)?
    @ViewBuilder var trailing: Trailing

    /// A row earns hover feedback only when it can actually be operated:
    /// either the whole row is a button (`action`), or it carries a control in
    /// its trailing area. Read-only rows (版本号, 辅助功能 state with no button)
    /// stay flat so the wash never promises a click that does not exist.
    private var isHoverable: Bool {
        isEnabled && (action != nil || Trailing.self != EmptyView.self)
    }

    var body: some View {
        let row = HStack(spacing: 11) {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                    )
                    .opacity(isEnabled ? 1 : 0.4)
            } else if let symbol {
                // Colour is opt-in: by default the palette stays quiet so the
                // only strong colour on screen is the current selection.
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AppearanceRuntime.monochromeIcons
                          ? AnyShapeStyle(Color.primary.opacity(0.13))
                          : AnyShapeStyle(color.gradient))
                    .frame(width: 26, height: 26)
                    .overlay(
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: AppearanceRuntime.monochromeIcons ? .medium : .semibold))
                            .foregroundStyle(AppearanceRuntime.monochromeIcons
                                             ? Color.primary.opacity(0.75)
                                             : Color.white)
                    )
                    .opacity(isEnabled ? 1 : 0.4)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 10)

            trailing

            if let value {
                Text(value)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, subtitle == nil ? 9 : 7)
        .frame(minHeight: 40)
        .contentShape(Rectangle())
        .hoverHighlight(isEnabled: isHoverable)
        .opacity(isEnabled ? 1 : 0.5)

        if let action {
            Button(action: action) { row }
                .buttonStyle(.plain)
        } else {
            row
        }
    }
}

extension GroupRow where Trailing == EmptyView {
    init(
        symbol: String? = nil,
        thumbnail: NSImage? = nil,
        color: Color = .accentColor,
        title: String,
        subtitle: String? = nil,
        value: String? = nil,
        showsChevron: Bool = false,
        isEnabled: Bool = true,
        action: (() -> Void)? = nil
    ) {
        self.init(
            symbol: symbol,
            thumbnail: thumbnail,
            color: color,
            title: title,
            subtitle: subtitle,
            value: value,
            showsChevron: showsChevron,
            isEnabled: isEnabled,
            action: action,
            trailing: { EmptyView() }
        )
    }
}

import AppKit
import SwiftUI

/// Full rendering of one clipboard entry: everything the history list only
/// summarises. Used by the quick-look overlay and the main window detail pane.
struct ClipPreviewView: View {
    @Bindable var model: AppModel
    let item: ClipItem
    /// The overlay is chrome-free; the main window pane draws its own header.
    var showsActions: Bool = true
    /// The space preview floats over arbitrary content, so in dark appearance
    /// it carries the same glass body as the clipboard panel — otherwise its
    /// white header sits directly on whatever window is behind it (over a
    /// bright page it measured ~2.4:1). The main window's pane already sits on
    /// its column, so it leaves this off and keeps its approved look.
    var drawsGlassChrome: Bool = false

    /// The one call site that floats in its own window. Kept as a named seam so
    /// the self test can prove the quick look still asks for the glass body
    /// without constructing an `AppModel`.
    static let quickLookUsesGlassChrome = true

    @State private var image: NSImage?
    /// The appearance the picture's drop shadow is tuned for (深色 needs more
    /// of it before the plate reads as dark; 浅色 only a whisper). Read from the
    /// environment so switching 外观 repaints the preview without rebuilding
    /// the item.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showsActions {
                Divider()
                actions
            }
        }
        .background {
            if drawsGlassChrome, colorScheme == .dark {
                floatingGlassCard
            }
        }
        .task(id: item.id) {
            image = model.previewImage(for: item)
        }
    }

    /// The floating surface behind the space preview in dark appearance.
    ///
    /// It is the panel's recipe at the panel's radius: official glass, the
    /// shared wash (which carries the dark legibility floor) and a hairline.
    /// 纯色 still degrades to an opaque card, exactly like the panel.
    private var floatingGlassCard: some View {
        ZStack {
            if AppearanceRuntime.backgroundStyle == .solid {
                Color(nsColor: .windowBackgroundColor)
            } else {
                GlassBackdropView()
                LiquidGlassWash()
            }
        }
        .clipShape(
            RoundedRectangle(cornerRadius: MainWindowChrome.cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MainWindowChrome.cornerRadius, style: .continuous)
                .strokeBorder(SelectionStyle.stroke, lineWidth: 1)
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: item.kind.symbolName)
                .foregroundStyle(.secondary)
            Text(item.kind.displayName)
                .font(.system(size: 12, weight: .semibold))
            Text("·").foregroundStyle(.tertiary)
            Text(item.sourceApp ?? "未知来源")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("·").foregroundStyle(.tertiary)
            Text(RelativeTime.string(for: item.updatedAt))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Text(item.byteCountText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if item.hasImage {
            imageContent
        } else if !item.fileURLs.isEmpty {
            fileList
        } else if let text = item.text, !text.isEmpty {
            textContent(text)
        } else {
            Text("（空）")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var imageContent: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    // The picture used to sit on a deliberately dark plate so
                    // its own edges were the brightest thing in the pane. Now
                    // that the plate *is* the app background (see
                    // `previewPlate()`), a light screenshot on the light pane
                    // would dissolve into it: the picture carries its own
                    // hairline and a very soft shadow instead, so the edge is
                    // still readable without a dark stage behind it.
                    .clipShape(Self.imageShape)
                    .overlay(
                        Self.imageShape.strokeBorder(
                            Color.primary.opacity(0.14),
                            lineWidth: 1
                        )
                    )
                    // Flatten picture + hairline first, otherwise the shadow
                    // is cast by the unclipped bitmap.
                    .compositingGroup()
                    .shadow(
                        color: .black.opacity(colorScheme == .dark ? 0.45 : 0.16),
                        radius: 5,
                        x: 0,
                        y: 1
                    )
                    .padding(10)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // No transparency checkerboard: transparent pixels show the plate, not
        // a grey/white grid.
        .previewPlate()
        .padding(12)
    }

    private func textContent(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .previewSlab()
    }

    private var fileList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(item.fileURLs, id: \.self) { path in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                            .resizable()
                            .frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(URL(fileURLWithPath: path).lastPathComponent)
                                .font(.system(size: 12))
                            Text(path)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        NeutralCapsuleButton(
                            title: "显示",
                            symbol: "folder",
                            height: NeutralControlMetrics.compactHeight,
                            help: "在访达里显示这个文件"
                        ) {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    Divider().padding(.leading, 48)
                }
            }
            .padding(.vertical, 6)
        }
        .previewSlab()
    }

    /// The image's own corner. One step tighter than the plate's 11 pt, the way
    /// a picture sits inside a mount.
    private static var imageShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
    }

    // MARK: - Actions

    /// The preview's action bar: an auxiliary glass strip, not four primary
    /// controls.
    ///
    /// This used to be four system `.bordered` buttons — solid pale-grey slabs
    /// with white labels. On the floating Space preview that bar is the
    /// brightest thing on screen when it sits over the settings page, which is
    /// exactly what the translucent app language is trying to avoid. The
    /// buttons are now the same wash + hairline capsules as `SelectionStyle`,
    /// and the row carries the shared window material.
    private var actions: some View {
        HStack(spacing: 6) {
            PreviewActionButton(title: "复制") { model.copy(item, paste: false) }
            PreviewActionButton(title: "粘贴") { model.copy(item, paste: true) }
            if item.hasImage {
                PreviewActionButton(title: "钉在屏幕上") { model.pinToScreen(item) }
            }
            Spacer(minLength: 8)
            PreviewActionButton(
                title: item.pinned ? "取消固定" : "固定",
                isPrimary: true
            ) { model.togglePin(item) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        // The bar used to be the *other* bottom in this pane: a live
        // `GlassBackdropView` + `LiquidGlassWash` layer, while the picture and
        // the text previews above it paint `previewPlate()`. Two materials 20 pt
        // apart read as a seam, which is exactly what the owner saw
        // (「右侧底部的颜色不和谐」). It now reuses the preview's own plate, so
        // the pane has one bottom in 纯色 and in both glass tiers; the buttons
        // keep their hover/press feedback because that lives on the controls,
        // not on this surface.
        .background { PreviewActionBarSurface() }
        .clipShape(Self.actionBarShape)
        // One hairline only: a second inner stroke read as a double frame.
        .overlay(Self.actionBarShape.strokeBorder(SelectionStyle.stroke, lineWidth: 1))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    /// Follows the floating window's own 12 pt corner (`MainWindowChrome`),
    /// so the strip and the preview panel it lives in have the same radius.
    private static var actionBarShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: MainWindowChrome.cornerRadius, style: .continuous)
    }
}

/// One text button in the preview action bar.
///
/// Resting fill is `SelectionStyle.hoverFill` (0.06); hover lifts to
/// `SelectionStyle.fill` (0.12), the same wash every other control in the app
/// uses. `固定` is the bar's main action, so it keeps one extra step of fill
/// (0.10) and semibold text — never a solid block.
private struct PreviewActionButton: View {
    let title: String
    var isPrimary: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    /// `固定` is the bar's main action: one extra step of fill. Everything
    /// else reuses the app's shared washes — resting is
    /// `SelectionStyle.hoverFill` (0.06) and hover is `SelectionStyle.fill`
    /// (0.12) — so this control has no private tint palette.
    private static let primaryFill: Double = 0.10

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isPrimary ? .semibold : .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: SelectionStyle.cornerRadius, style: .continuous)
                        .fill(
                            isHovering
                                ? SelectionStyle.fill
                                : (isPrimary
                                    ? Color.primary.opacity(Self.primaryFill)
                                    : SelectionStyle.hoverFill)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: SelectionStyle.cornerRadius, style: .continuous)
                        .strokeBorder(SelectionStyle.stroke, lineWidth: 1)
                )
                .contentShape(
                    RoundedRectangle(cornerRadius: SelectionStyle.cornerRadius, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(SelectionStyle.hoverAnimation) { isHovering = hovering }
        }
    }
}

extension View {
    /// The inset rounded container every preview pane sits in, so the detail
    /// side matches the grouped slabs on the list side.
    func previewSlab() -> some View {
        previewPlate()
            .padding(12)
    }

    /// The one background every preview area uses — image, text and file list.
    ///
    /// It is the **app's own surface**, not a second material, which is the
    /// whole point: the preview used to be a dark stage (`Color(white: 0.10)`
    /// 深色 / `0.22` 浅色) that read as a black hole cut into a translucent
    /// window. The recipe per 外观 → 背景:
    ///
    /// * 纯色 — `windowBackgroundColor`, i.e. literally the window's own
    ///   colour, so the pane *is* the app background.
    /// * 液态玻璃 / 半透明 — `GlassWash.inset`, the exact wash the left
    ///   column's list already paints over its card (`GlassWash.inset` is
    ///   documented as "a content area inside a card — history list, preview
    ///   pane"). No new material, no extra glass layer: the card's own
    ///   glass/blur still shows through, so the preview transmits the desktop
    ///   exactly like its neighbours.
    ///
    /// Both appearances follow the appearance automatically (the wash is
    /// `windowBackgroundColor` under the hood).
    ///
    /// The hairline is what keeps "harmonious" from becoming "no boundary":
    /// measured against the card ring directly above it the plate differs by
    /// 0.9 RGB 浅色 / 0.2 RGB 深色 — invisible on its own, so the 0.07 border is
    /// the edge.
    func previewPlate(cornerRadius: CGFloat = 11) -> some View {
        self
            .background { PreviewPlate() }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
    }
}

/// The preview action bar's surface. It is `previewPlate()` — deliberately the
/// same view, not a copy of its colours — so the strip under the buttons and
/// the plate under the picture can never drift apart again. The type exists
/// (instead of the bar calling `PreviewPlate()` inline) so the self test can
/// render the exact surface the bar uses and compare it with the plate.
struct PreviewActionBarSurface: View {
    var body: some View {
        PreviewPlate()
    }
}

/// Backing colour of `previewPlate()`; kept tiny so the two tiers cannot drift.
struct PreviewPlate: View {
    var body: some View {
        if AppearanceRuntime.backgroundStyle == .solid {
            Color(nsColor: .windowBackgroundColor)
        } else {
            GlassWash.fill(GlassWash.inset)
        }
    }
}

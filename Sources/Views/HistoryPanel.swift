import AppKit
import SwiftUI

/// Measured frames of the two groups in the action row, in the row's top-left
/// coordinate space.
///
/// The window-drag strip is the blank gap between them. Measuring the real
/// layout instead of hard-coding an x-range means the strip keeps its distance
/// when the count grows a digit (which widens the left capsule) or a button
/// changes its symbol width.
struct PanelActionBarLayout: Equatable {
    var countCapsule: CGRect = .zero
    var buttonGroup: CGRect = .zero
}

struct HistoryPanel: View {
    /// Matches `MainWindowChrome.cornerRadius`; the two surfaces share the
    /// system's 12 pt rounded-window corner.
    private static let cornerRadius: CGFloat = 12
    /// Named space used to report the action row's geometry.
    private static let actionBarSpace = "clipboard-panel-action-bar"

    @Bindable var model: AppModel
    /// Supplied by the panel controller so Space can open the quick-look overlay.
    var onPreview: (() -> Void)?
    /// Supplied by the panel controller so it can place its drag strip in the
    /// measured blank middle of the action row.
    var onActionBarLayout: (@MainActor (PanelActionBarLayout) -> Void)?
    /// Supplied by the panel controller. Reports which row the pointer is over
    /// so ⌘⇧P can pin the hovered row; `nil` means the pointer is off the list.
    var onHoverRow: (@MainActor (Int64?) -> Void)?
    @FocusState private var searchFocused: Bool

    @State private var countCapsuleFrame: CGRect = .zero
    @State private var countHovering = false
    @State private var buttonGroupFrame: CGRect = .zero
    @State private var hoveredRowItemID: Int64?

    var body: some View {
        VStack(spacing: 0) {
            actionBar
            Divider()
            searchBar
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 420, height: 560)
        // Same material as the main window: official Liquid Glass plus the
        // shared wash. The panel window is borderless and non-opaque, so this
        // lets the desktop show through instead of a flat `.regularMaterial`
        // sheet.
        .background {
            ZStack {
                if AppearanceRuntime.backgroundStyle == .solid {
                    // 纯色 promises every glass surface degrades to a solid
                    // card; the panel is a window-level surface, so it has to
                    // honour that too instead of tinting whatever is behind it.
                    Color(nsColor: .windowBackgroundColor)
                } else {
                    GlassBackdropView()
                    LiquidGlassWash()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(SelectionStyle.stroke, lineWidth: 1)
        )
        .onAppear { searchFocused = true }
        .alert(
            "出错了",
            isPresented: Binding(
                get: { model.lastError != nil },
                set: { if !$0 { model.dismissError() } }
            ),
            actions: { Button("好") { model.dismissError() } },
            message: { Text(model.lastError ?? "") }
        )
    }

    // MARK: - Actions

    /// The panel is a launcher, not just a clipboard list.
    ///
    /// Left: the entry count in the same capsule the buttons use, so it reads
    /// as part of the control row instead of loose text. Middle: blank, used as
    /// the panel's drag strip. Right: 钉住 plus the three window actions.
    private var actionBar: some View {
        HStack(spacing: 6) {
            countCapsule
                .background {
                    ActionBarFrameReader(space: Self.actionBarSpace) { frame in
                        guard frame != countCapsuleFrame else { return }
                        countCapsuleFrame = frame
                        publishActionBarLayout()
                    }
                }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                // 钉住面板: first in the action group so the screenshot /
                // main-window / quit trio keeps its established right-hand
                // positions. The icon fills and the capsule lifts while pinned.
                CapsuleToolbarButton(
                    symbol: model.panelPinned ? "pin.fill" : "pin",
                    help: model.panelPinned
                        ? "取消钉住（失焦后自动关闭）"
                        : "钉住面板（切换 App 时不关闭）",
                    isActive: model.panelPinned
                ) {
                    model.panelPinned.toggle()
                }
                CapsuleToolbarButton(symbol: "camera.viewfinder", help: "截图（区域）") {
                    model.onRequestCapture?(.region)
                }
                CapsuleToolbarButton(symbol: "macwindow", help: "打开主窗口") {
                    model.onRequestMainWindow?()
                }
                CapsuleToolbarButton(symbol: "power", help: "退出") {
                    model.onRequestQuit?()
                }
            }
            .background {
                ActionBarFrameReader(space: Self.actionBarSpace) { frame in
                    guard frame != buttonGroupFrame else { return }
                    buttonGroupFrame = frame
                    publishActionBarLayout()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 9)
        .padding(.bottom, 8)
        .frame(height: 47)
        .coordinateSpace(.named(Self.actionBarSpace))
        // The blank stretches of this row drag the panel; the buttons on top
        // still receive their own clicks.
        .background(WindowDragArea())
    }

    /// The count, restyled into the same capsule as the buttons to its right.
    ///
    /// This is a read-out, not a control: no Button, gesture, hover state or
    /// keyboard focus. A plain SwiftUI view still claims its own clicks, so
    /// they do not fall through to the drag strip behind the row.
    ///
    /// The construction is the buttons' construction line for line — same
    /// `capsuleControlSurface`, same fill/hairline/height/padding, same
    /// `Color.primary` label ink — so the two cannot drift apart in *recipe*.
    /// What still differs on screen is only the ground under them: the wash is
    /// brighter at the top-leading corner than at the right-hand button group.
    private var countCapsule: some View {
        HStack(spacing: 6) {
            Text("剪贴板")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
            Text("\(model.totalCount) 条")
                .font(.system(size: 11))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, CapsuleControlStyle.horizontalPadding)
        .frame(height: CapsuleControlStyle.height)
        // Reads like the buttons beside it — it *is* the buttons' surface: the
        // same hover tier, no extra matte or dark floor of its own.
        .capsuleControlSurface(isHovering: countHovering)
        .animation(.easeOut(duration: 0.12), value: countHovering)
        .onContinuousHover { phase in
            switch phase {
            case .active: countHovering = true
            case .ended: countHovering = false
            }
        }
        .contentShape(Capsule(style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("剪贴板 \(model.totalCount) 条")
    }

    /// Hands the measured action-row geometry to `PanelController`.
    private func publishActionBarLayout() {
        onActionBarLayout?(
            PanelActionBarLayout(
                countCapsule: countCapsuleFrame,
                buttonGroup: buttonGroupFrame
            )
        )
    }

    /// Records the row under the pointer. A fast move from row A to row B can
    /// deliver B's "enter" before A's "exit"; the `rowID` check stops that late
    /// exit from clearing B.
    private func setHoveredRow(_ id: Int64?, for rowID: Int64) {
        if id == nil, hoveredRowItemID != rowID { return }
        guard hoveredRowItemID != id else { return }
        hoveredRowItemID = id
        onHoverRow?(id)
    }

    // MARK: - Sections

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索历史…", text: $model.searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if model.filteredItems.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.filteredItems.enumerated()), id: \.element.id) { index, item in
                            ClipRowView(
                                model: model,
                                item: item,
                                isSelected: index == model.selectedIndex,
                                shortcutNumber: index < 9 ? index + 1 : nil,
                                onPreview: onPreview,
                                onHoverChange: { hovering in
                                    setHoveredRow(hovering ? item.id : nil, for: item.id)
                                }
                            )
                            .id(item.id)
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .onChange(of: model.selectedIndex) { _, _ in
                    guard let id = model.selectedItem?.id else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: model.searchText.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(model.searchText.isEmpty ? "还没有记录，复制点什么试试" : "没有匹配的记录")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("\(model.totalCount) 条")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            // ⌘P is kept as the "selected row" shortcut for muscle memory;
            // ⌘⇧P pins whatever row is under the pointer. The hint only names
            // shortcuts that actually do something here.
            Text("1–9 复制 · ⌘1–9 粘贴 · 空格预览 · ⌘P / ⌘⇧P 钉图")
                .font(.caption2)
                // Keyboard help is not decoration: at `.tertiary` it sat at
                // ~2.3:1 on the panel ground and disappeared first.
                .foregroundStyle(SupportingInk.text)

            Spacer()

        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Reports the host view's frame in a named coordinate space, once on appear
/// and again whenever the layout changes (e.g. the entry count grows a digit).
private struct ActionBarFrameReader: View {
    let space: String
    let onFrame: @MainActor (CGRect) -> Void

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named(space))
            Color.clear
                .onAppear { onFrame(frame) }
                .onChange(of: frame) { _, newFrame in onFrame(newFrame) }
        }
    }
}

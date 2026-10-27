import AppKit
import SwiftUI

/// Column geometry of the root window. The numbers live here so the widths are
/// one edit, and so a test can quote them.
///
/// **One middle width for every page.** 2026-10-24 unified the three per-page
/// numbers (历史/钉图 292, 截图 272, 设置页 260) into `middle`: the owner asked
/// that 截图设置 / 历史记录设置 and the like use the same three-column
/// distribution as 通用 / 快捷键, and a single constant is the only way the
/// cards cannot jump width when the section changes. The middle card is the
/// narrow one — it only ever lists short labels — while the right pane draws
/// the whole page and takes the flexible remainder.
///
/// The navigation column is frozen: the owner asked that 最左列 never change,
/// so it keeps the 182 pt it has had since the three-column layout shipped.
/// The right pane is **not** a constant: it is `maxWidth: .infinity`, so at
/// the owner's saved 1020 pt window it measures 538 pt and can never disagree
/// between pages because no page sets it.
enum MainColumnMetrics {
    /// The navigation column. Frozen — do not tune this.
    static let navigation: CGFloat = 182
    /// The middle column on *every* page: the clip list (历史记录 / 钉图), the
    /// mode list (截图) and the group list (all settings pages, 快捷键
    /// included). One number, so switching sections never resizes a card.
    static let middle: CGFloat = 260
    /// Gutter between the floating cards, and the window's outer padding.
    static let gutter: CGFloat = 10
    static let outerPadding: CGFloat = 10
}

/// Root of the main window.
///
/// Two columns rather than three: the left column *is* the content list, the
/// way Telegram does it — header, search, segmented filters with counts, the
/// list itself, and a bottom icon bar for switching what the column shows.
struct MainView: View {
    @Bindable var model: AppModel
    @Bindable var navigation: NavigationState

    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: MainColumnMetrics.gutter) {
            navColumn
                .frame(width: MainColumnMetrics.navigation)
                .floatingCard()
            // One middle width for every section (see `MainColumnMetrics`).
            // The *contents* still differ — a clip list, the 截图 mode list or
            // a page's group list — but the card never changes size, so the
            // three-column boundary is identical on every page.
            middleColumn
                .frame(width: MainColumnMetrics.middle)
                .floatingCard()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .floatingCard()
        }
        .padding(MainColumnMetrics.outerPadding)
        // Full-bleed: with `fullSizeContentView` the SwiftUI content starts
        // below the titlebar, so the backdrop must ignore the safe area or the
        // glass would stop short and leave a square-cornered top edge.
        .background {
            AppBackground(style: model.settings.backgroundStyleValue)
                .ignoresSafeArea()
        }
        .preferredColorScheme(AppearanceRuntime.colorScheme)
    }

    /// The middle column's contents. History and pins list their items;
    /// settings list their groups, and the detail pane draws only the selected
    /// group — so the two columns never show the same rows twice. 快捷键 is no
    /// exception: its middle column lists the four blocks and the right pane
    /// draws the selected one.
    @ViewBuilder
    private var middleColumn: some View {
        switch navigation.section {
        case .history, .pins: contentColumn
        case .capture: captureToolColumn
        case .settings: groupColumn
        }
    }

    // MARK: - Column 1: navigation (icon + label + count, like Surge)

    private var navColumn: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(NavItem.groups, id: \.0) { header, items in
                        Text(header)
                            .font(.system(size: 10, weight: .semibold))
                            // Section labels are structure, not decoration: at
                            // `.tertiary` they measured ~2.2:1 on the dark wash
                            // and the four groups stopped reading as headings.
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.top, 12)
                            .padding(.bottom, 4)
                        ForEach(items) { item in
                            navRow(item)
                        }
                    }
                }
                .padding(.top, 2)
                .padding(.horizontal, 8)
            }

            VStack(alignment: .leading, spacing: 3) {
                Label("\(model.totalCount) 条", systemImage: "internaldrive")
                if model.pinboard.count > 0 {
                    Label("\(model.pinboard.count) 张钉图", systemImage: "pin")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(SupportingInk.text)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func navRow(_ item: NavItem) -> some View {
        let selected = navigation.item == item
        return Button {
            withAnimation(.snappy(duration: 0.2)) { navigation.item = item }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.symbol)
                    .font(.system(size: 12, weight: .medium))
                    // Selection is a translucent wash: glyphs keep their normal
                    // colour instead of flipping to white on accent blue.
                    .foregroundStyle(
                        AppearanceRuntime.monochromeIcons
                            ? (selected ? Color.primary : Color.secondary)
                            : item.color
                    )
                    .frame(width: 16)
                Text(item.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let badge = navBadge(item) {
                    Text("\(badge)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(selected ? Color.primary.opacity(0.7) : Color.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .foregroundStyle(Color.primary)
            .background(SelectionBackground(selected: selected))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(isSelected: selected)
    }

    private func navBadge(_ item: NavItem) -> Int? {
        switch item {
        case .history: model.totalCount
        case .pins: model.pinboard.count
        default: nil
        }
    }

    // MARK: - Column 2 for 工具 → 截图工具: the four modes

    private var captureToolColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("截图模式")
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 6)
                Text("\(CaptureToolMode.allCases.count) 种")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 10)

            Divider()

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(CaptureToolMode.allCases) { tool in
                        captureToolRow(tool)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }

            Divider()

            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "command")
                    .font(.system(size: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text("区域 \(model.settings.screenshotHotKeyConfiguration.displayString)")
                    Text("即时窗口 \(model.settings.instantWindowHotKeyConfiguration.displayString)")
                }
                .font(.system(size: 10))
                Spacer(minLength: 0)
            }
            .foregroundStyle(SupportingInk.text)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The one middle-column row geometry, shared by the 截图 mode list and
    /// every settings page's group list.
    ///
    /// 2026-10-24: the four mode rows used to carry a one-line description
    /// under the title (框选任意区域 / 单击选中…), which made them ~14 pt taller
    /// than a 通用 / 外观 group row. The owner removed the descriptions so the
    /// two lists read at the same size; drawing both through this function is
    /// what keeps them equal instead of merely equal today.
    private func middleRow(
        symbol: String,
        title: String,
        selected: Bool,
        showsDisclosure: Bool = false
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                // Monochrome everywhere: selection is a neutral glass chip,
                // not a coloured slab.
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 4)
            // 截图 keeps its trailing chevron: its row opens the mode's own
            // page, which is one level deeper than a group row.
            if showsDisclosure, selected {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .foregroundStyle(Color.primary)
        .background(SelectionBackground(selected: selected))
        .contentShape(Rectangle())
    }

    private func captureToolRow(_ tool: CaptureToolMode) -> some View {
        let selected = navigation.captureTool == tool
        return Button {
            withAnimation(.snappy(duration: 0.2)) { navigation.captureTool = tool }
        } label: {
            // No subtitle: a mode row is one title line, exactly like a group
            // row on 通用 / 外观, so both lists measure the same height.
            middleRow(
                symbol: tool.symbol,
                title: tool.title,
                selected: selected,
                showsDisclosure: true
            )
        }
        .buttonStyle(.plain)
        .hoverHighlight(isSelected: selected)
    }

    // MARK: - Column 2 for grouped pages: the page's groups

    /// The groups of the current `.settings` page. Selecting one narrows the
    /// detail pane to that group, which is what makes the layout three levels
    /// instead of two.
    private var currentPageGroups: [PageGroup] {
        switch navigation.section {
        case .settings: navigation.settingsSection.pageGroups
        default: []
        }
    }

    private var groupColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(navigation.item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 10)

            Divider()

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(currentPageGroups) { pageGroup in
                        groupRow(pageGroup)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
        }
    }

    private func groupRow(_ pageGroup: PageGroup) -> some View {
        let selected = navigation.groupID == pageGroup.id
        return Button {
            withAnimation(.snappy(duration: 0.2)) { navigation.groupID = pageGroup.id }
        } label: {
            middleRow(symbol: pageGroup.symbol, title: pageGroup.title, selected: selected)
        }
        .buttonStyle(.plain)
        .hoverHighlight(isSelected: selected)
    }

    // MARK: - Column 2: header + search + segments + list

    private var contentColumn: some View {
        VStack(spacing: 0) {
            contentHeader

            if navigation.section == .history {
                VStack(spacing: 8) {
                    CapsuleSearchField(
                        placeholder: "搜索历史…",
                        text: $model.searchText,
                        shortcutHint: "⌘K"
                    )
                    SegmentedPillBar(
                        items: ClipFilter.allCases,
                        selection: $model.filter,
                        title: \.title,
                        count: { model.count(for: $0) }
                    )
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .center)
            }

            Divider()
            list
        }
    }

    /// Title plus capsule actions, the toolbar shape from the reference.
    private var contentHeader: some View {
        HStack(spacing: 8) {
            Text(navigation.item.title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)

            Spacer(minLength: 6)

            if navigation.section == .pins, !model.pinboard.pins.isEmpty {
                CapsuleToolbarButton(symbol: "square.3.layers.3d.top.filled", help: "全部置顶") {
                    model.pinboard.bringAllToFront()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    // MARK: - Column 2 content

    @ViewBuilder
    private var list: some View {
        switch navigation.section {
        case .history: historyList
        case .pins: pinList
        case .capture: EmptyView()
        case .settings: EmptyView()
        }
    }

    @ViewBuilder
    private var historyList: some View {
        if model.filteredItems.isEmpty {
            columnPlaceholder(
                symbol: model.searchText.isEmpty ? "doc.on.clipboard" : "magnifyingglass",
                title: model.searchText.isEmpty ? "还没有记录" : "没有匹配的记录"
            )
        } else {
            // No ScrollViewReader: the only thing that changes the selection in
            // this window is a click on a row that is already visible, so
            // scrolling it to the centre would just animate the list under the
            // pointer.
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.filteredItems.enumerated()), id: \.element.id) { index, item in
                        ClipRowView(
                            model: model,
                            item: item,
                            isSelected: index == model.selectedIndex,
                            onTap: { model.select(item) },
                            onDoubleTap: { model.activate(item) }
                        )
                        .id(item.id)
                        if index < model.filteredItems.count - 1 {
                            Rectangle()
                                .fill(Color.primary.opacity(0.06))
                                .frame(height: 1)
                                .padding(.leading, 52)
                        }
                    }
                }
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(GlassWash.fill(GlassWash.inset))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                )
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
    }

    private var pinList: some View {
        Group {
            if model.pinboard.pins.isEmpty {
                columnPlaceholder(symbol: "pin", title: "还没有钉图", subtitle: "选中图片按 ⌘P 钉在屏幕上")
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.pinboard.pins) { pin in
                            SidebarPinRow(model: model, pin: pin)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func columnPlaceholder(symbol: String, title: String, subtitle: String? = nil) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 13)).foregroundStyle(.secondary)
            if let subtitle {
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch navigation.section {
        case .history:
            if let item = model.selectedItem {
                ClipPreviewView(model: model, item: item)
            } else {
                detailPlaceholder("选中左侧任意一条查看预览")
            }
        case .pins:
            PinboardPage(model: model)
        case .capture:
            // The middle column picked one of the four modes; the right pane is
            // that mode's *own* settings page, drawn in full (no group filter),
            // with the page's 开始截图 action kept in the header so the tool page
            // still starts a capture.
            SettingsView(
                model: model,
                section: navigation.captureTool.settingsSection,
                groupID: PageGroupID.none,
                action: captureToolAction
            )
        case .settings:
            // The middle column lists this page's groups (on 快捷键, its four
            // shortcut blocks) and the right pane draws the selected one.
            SettingsView(
                model: model,
                section: navigation.settingsSection,
                groupID: navigation.groupID
            )
        }
    }

    /// The 截图工具 page's header action: start the selected mode. 固定大小 has no
    /// `CaptureMode`; it opens the preset entry instead (the same one the menu's
    /// 预设区域尺寸截图 uses).
    private var captureToolAction: SettingsPageAction {
        let tool = navigation.captureTool
        return SettingsPageAction(
            title: "开始截图",
            symbol: "camera.viewfinder"
        ) {
            if let mode = tool.captureMode {
                model.onRequestCapture?(mode)
            } else {
                model.onRequestPresetCapture?()
            }
        }
    }

    private func detailPlaceholder(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Compact pinned-image row for the column.
private struct SidebarPinRow: View {
    @Bindable var model: AppModel
    let pin: PinnedImage

    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.12)
                }
            }
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text("\(Int(pin.width)) × \(Int(pin.height))")
                    .font(.system(size: 12.5))
                Text(pin.isVisible ? "显示中 · \(Int(pin.opacity * 100))%" : "已隐藏")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Button {
                model.pinboard.setVisible(pin.id, !pin.isVisible)
            } label: {
                Image(systemName: pin.isVisible ? "eye.slash" : "eye").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            Button {
                model.pinboard.unpin(pin.id)
            } label: {
                Image(systemName: "xmark").font(.system(size: 11))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .task(id: pin.itemID) {
            guard thumbnail == nil, let data = model.pinboard.imageData(for: pin) else { return }
            thumbnail = NSImage(data: data)
        }
    }
}

extension View {
    /// A rounded panel lifted off the window background — the shape Telegram's
    /// left column uses.
    ///
    /// Three large surfaces use this (left navigation, middle list, right
    /// detail). On macOS 26 they become Liquid Glass; on 14/15 a blur; under
    /// 纯色 they turn into opaque cards so the layout never goes see-through.
    func floatingCard(cornerRadius: CGFloat = 12) -> some View {
        self
            .background {
                GlassSurface(
                    cornerRadius: cornerRadius,
                    // `.surface` (the official `.clear` glass), not `.regular`:
                    // these cards already sit on the window's own glass, and a
                    // second `.regular` material stacks into an opaque-looking
                    // dark slab instead of transmitting the backdrop.
                    style: .surface,
                    // The card coat scales with 板块不透明度 inside
                    // `GlassWash.fill`; its plate is the black depth wash, also
                    // scaled by that slider (0 % erases both — the owner's
                    // requirement was that 0 % really clears the card). The plate
                    // is not a copy of the window background: in 浅色 that is
                    // white, so a window-coloured plate made the column
                    // *brighter* than the window (2026-10-25).
                    // The stronger hairline carries the structure now that the
                    // fill is close to the window.
                    fillOpacity: GlassWash.card,
                    plateStyle: .columnDepth,
                    borderColor: Color.primary.opacity(0.10)
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

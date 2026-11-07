import AppKit
import SwiftUI

/// 相册 — the screenshot library, drawn in the app's ordinary three-column
/// language instead of as one long scrolling page.
///
/// The middle column lists this page's groups (图片库 / 文件夹监听 / 导入行为) and
/// the right pane draws the selected one, exactly like every settings page. That
/// replaced a second 设置 → 相册 entry point: there is now **one** album page, and
/// the folder switches live inside it rather than in two places.
struct AlbumPage: View {
    @Bindable var model: AppModel
    @Binding var groupID: String
    @State private var selection: UUID?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)]

    var body: some View {
        Group {
            switch groupID {
            case AlbumPageGroup.folder: folderPane
            case AlbumPageGroup.behavior: behaviorPane
            default: libraryPane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - 图片库

    private var libraryPane: some View {
        let entries = model.albumItems
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(count: entries.count)

                if entries.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(entries, id: \.record.id) { entry in
                            AlbumTile(
                                model: model,
                                record: entry.record,
                                item: entry.item,
                                isSelected: selection == entry.record.id
                            ) {
                                selection = entry.record.id
                                model.select(entry.item)
                            }
                            .contextMenu {
                                Button("复制") { model.copy(entry.item, paste: false) }
                                Button("钉在屏幕上") { model.pinToScreen(entry.item) }
                                Button("在照片中查看") {
                                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") {
                                        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                                    }
                                }
                                Divider()
                                Button("从记录中移除（照片里保留）", role: .destructive) {
                                    model.removeFromAlbum(entry.record)
                                    if selection == entry.record.id { selection = nil }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, SettingsPageMetrics.headerTopPadding)
            .padding(.bottom, 28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func header(count: Int) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: SettingsPageMetrics.headerTitleSpacing) {
                Text("相册")
                    .font(.system(size: 26, weight: .bold))
                Text(
                    count == 0
                        ? "监听文件夹里的新截图会自动存进「照片」App。"
                        : "\(count) 张已存入「照片」。右键可以复制、钉图或从记录里移除。"
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            NeutralCapsuleButton(title: "打开照片", help: "打开系统的「照片」App") {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") {
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                }
            }
        }
    }

    /// Nothing collected yet: this pane is the whole page, so it has to explain
    /// both ways in and offer the folder switch instead of sending the user off
    /// to another page.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeader("怎么把图片放进来")
            GroupSlab {
                GroupRow(
                    symbol: "folder.badge.plus",
                    color: SectionPalette.album,
                    title: "监听一个文件夹",
                    subtitle: model.settings.autoImportEnabled
                        ? "已开启：新截图会自动存进「照片」"
                        : "在「文件夹监听」里选择文件夹并开启"
                ) {
                    NeutralCapsuleButton(title: "去设置", help: "打开本页的「文件夹监听」") {
                        groupID = AlbumPageGroup.folder
                    }
                }
                GroupDivider()
                GroupRow(
                    symbol: "clock.arrow.circlepath",
                    color: SectionPalette.history,
                    title: "从历史记录存档",
                    subtitle: "在历史记录里右键一张图片 →「存入「照片」」"
                )
            }
        }
    }

    // MARK: - 文件夹监听

    private var folderPane: some View {
        page("选一个文件夹，之后保存进去的截图会自动进入相册。") {
            GroupSlab(
                footer: "只认图片文件（png / jpg / heic 等）。开启的那一刻，文件夹里已有的图片不会被导入。"
            ) {
                GroupRow(
                    symbol: "folder.badge.plus",
                    color: SectionPalette.album,
                    title: "监听文件夹",
                    subtitle: model.settings.watchedFolderPath.isEmpty
                        ? "还没有选择"
                        : (model.settings.watchedFolderPath as NSString).abbreviatingWithTildeInPath
                ) {
                    HStack(spacing: 6) {
                        if !model.settings.watchedFolderPath.isEmpty {
                            NeutralCapsuleButton(title: "扫描", help: "立刻扫描一次，不用等下一次轮询") {
                                model.folderWatcher.scanNow()
                            }
                        }
                        NeutralCapsuleButton(title: "选择…", help: "选择要监听的文件夹") {
                            chooseWatchedFolder()
                        }
                    }
                }

                GroupDivider()

                GroupRow(
                    symbol: "eye.fill",
                    color: model.settings.autoImportEnabled ? .green : .gray,
                    title: "开启监听",
                    subtitle: model.settings.autoImportEnabled
                        ? watcherStatusText
                        : "关闭时不会读取任何文件"
                ) {
                    toggle(Binding(
                        get: { model.settings.autoImportEnabled },
                        set: { model.settings.autoImportEnabled = $0; model.albumSettingsDidChange() }
                    ))
                }

                GroupDivider()

                GroupRow(
                    symbol: "arrow.triangle.branch",
                    color: .blue,
                    title: "包含子文件夹",
                    subtitle: "开启后连子文件夹里的图片一起收"
                ) {
                    toggle(Binding(
                        get: { model.settings.autoImportRespectSubfolders },
                        set: { model.settings.autoImportRespectSubfolders = $0; model.albumSettingsDidChange() }
                    ))
                }
            }
        }
    }

    private var watcherStatusText: String {
        let watcher = model.folderWatcher
        if let error = watcher.lastError { return "出错：\(error)" }
        guard watcher.isWatching else {
            return model.settings.watchedFolderPath.isEmpty ? "先选择一个文件夹" : "未在监听"
        }
        var parts = ["监听中"]
        if let name = watcher.lastImportedName { parts.append("最近 \(name)") }
        parts.append("本次已导入 \(watcher.importedCount) 张")
        return parts.joined(separator: " · ")
    }

    // MARK: - 导入行为

    private var behaviorPane: some View {
        page("导入之后怎么处理文件。") {
            GroupSlab(footer: "「保留原文件」关闭时，文件会在成功导入之后才删除；导入失败绝不会删文件。") {
                GroupRow(
                    symbol: "doc.badge.plus",
                    color: .teal,
                    title: "保留原文件",
                    subtitle: model.settings.autoImportKeepOriginal
                        ? "导入后文件还在原处（复制一份进相册）"
                        : "导入后删除原文件（相当于移进相册）"
                ) {
                    toggle(Binding(
                        get: { model.settings.autoImportKeepOriginal },
                        set: { model.settings.autoImportKeepOriginal = $0 }
                    ))
                }

                GroupDivider()

                GroupRow(
                    symbol: "photo",
                    color: .indigo,
                    title: "只导入图片",
                    subtitle: model.settings.autoImportOnlyImages
                        ? "跳过非图片文件"
                        : "尝试读取所有文件（非图片仍会被拒绝）"
                ) {
                    toggle(Binding(
                        get: { model.settings.autoImportOnlyImages },
                        set: { model.settings.autoImportOnlyImages = $0 }
                    ))
                }

                GroupDivider()

                GroupRow(
                    symbol: "macwindow",
                    color: .orange,
                    title: "导入后打开面板",
                    subtitle: "方便马上把刚收的截图粘出去"
                ) {
                    toggle(Binding(
                        get: { model.settings.autoImportOpenPanel },
                        set: { model.settings.autoImportOpenPanel = $0 }
                    ))
                }
            }
        }
    }

    // MARK: - Shared bits

    /// One right-pane page: big title + scrolling groups, with the same metrics
    /// every settings page uses so 相册 does not look like a different app.
    private func page<Content: View>(
        _ subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsPageMetrics.sectionSpacing) {
                VStack(alignment: .leading, spacing: SettingsPageMetrics.headerTitleSpacing) {
                    Text("相册")
                        .font(.system(size: 26, weight: .bold))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                content()
            }
            .padding(.horizontal, 22)
            .padding(.top, SettingsPageMetrics.headerTopPadding)
            .padding(.bottom, 24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func toggle(_ isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn)
            .labelsHidden()
            .toggleStyle(NeutralSwitchStyle())
    }

    /// Picking a folder implies intent, so arm the watcher in the same click.
    private func chooseWatchedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "监听此文件夹"
        panel.message = "选择截图保存到的文件夹"
        if !model.settings.watchedFolderPath.isEmpty {
            panel.directoryURL = URL(
                fileURLWithPath: (model.settings.watchedFolderPath as NSString).expandingTildeInPath
            )
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.settings.watchedFolderPath = url.path
        if !model.settings.autoImportEnabled { model.settings.autoImportEnabled = true }
        model.albumSettingsDidChange()
    }
}

/// One album tile: a thumbnail with the provenance line underneath.
private struct AlbumTile: View {
    @Bindable var model: AppModel
    let record: AlbumStore.AlbumRecord
    let item: ClipItem
    let isSelected: Bool
    let onTap: () -> Void

    @State private var thumbnail: NSImage?

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 22))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(height: 108)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            isSelected ? SectionPalette.album : Color.primary.opacity(0.08),
                            lineWidth: isSelected ? 2 : 1
                        )
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(record.originText ?? item.kind.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(record.addedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(SectionPalette.album.opacity(0.10))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: record.id) {
            guard thumbnail == nil else { return }
            if let data = AlbumStore.imageData(for: record) {
                thumbnail = NSImage(data: data)
            } else if let image = model.thumbnailImage(for: item) {
                thumbnail = image
            }
        }
    }
}

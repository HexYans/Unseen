import AppKit
import SwiftUI

/// 相册 — the screenshot library.
///
/// Deliberately a *grid*, not the grouped-rows language the settings pages use:
/// the whole point of an album is to see pictures. Every tile is a real history
/// row, so clicking one selects it in 历史记录 and the standard preview pane
/// (copy / pin / ⌘1–9) keeps working; the album only adds the folder-derived
/// provenance line and its own delete.
struct AlbumPage: View {
    @Bindable var model: AppModel
    @State private var selection: UUID?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)]

    var body: some View {
        let entries = model.albumItems
        ScrollView {
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
                                Button("在 Finder 中显示") {
                                    let url = AlbumStore.fileURL(for: entry.record.id)
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                }
                                Divider()
                                Button("从相册移除", role: .destructive) {
                                    model.removeFromAlbum(entry.record)
                                    if selection == entry.record.id { selection = nil }
                                }
                            }
                        }
                    }
                }

                watcherCard
            }
            .padding(.horizontal, 22)
            .padding(.top, 4)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Header

    private func header(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("相册")
                .font(.system(size: 26, weight: .bold))
            Text(
                count == 0
                    ? "监听文件夹里的新截图会自动收进这里。"
                    : "\(count) 张图片。右键可以复制、钉图或移出相册。"
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Empty state

    /// When nothing has been collected yet, this is the only thing on the page,
    /// so it explains both ways in *and* carries the folder switches: a user who
    /// has never turned the feature on should be able to do it right here
    /// instead of hunting through 设置 → 相册.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeader("怎么把图片放进来")
            GroupSlab {
                GroupRow(
                    symbol: "folder.badge.plus",
                    color: SectionPalette.album,
                    title: "监听一个文件夹",
                    subtitle: model.settings.autoImportEnabled
                        ? "已开启：新截图会自动收进相册"
                        : "在下方开启后，保存到该文件夹的截图会自动进来"
                )
                GroupDivider()
                GroupRow(
                    symbol: "clock.arrow.circlepath",
                    color: SectionPalette.history,
                    title: "从历史记录添加",
                    subtitle: "在历史记录里右键一张图片 →「加入相册」"
                )
            }
        }
    }

    // MARK: - Folder watching (the switches live here as well as in 设置 → 相册)

    /// The folder-watching controls, inline on the album page.
    ///
    /// These are the *same* `AppSettings` switches the 设置 → 相册 page edits —
    /// one source of truth, two doors. The album page is where a user actually
    /// notices "nothing is being collected", so making them come back through
    /// 设置 to fix it would be a gratuitous detour.
    private var watcherCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeader("文件夹监听")
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
                    NeutralCapsuleButton(
                        title: "选择…",
                        help: "选择截图保存到的文件夹"
                    ) {
                        chooseWatchedFolder()
                    }
                }

                GroupDivider()

                GroupRow(
                    symbol: "eye.fill",
                    color: model.settings.autoImportEnabled ? .green : .gray,
                    title: "开启监听",
                    subtitle: model.settings.autoImportEnabled
                        ? watcherSubtitle
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

            GroupHeader("导入行为")
                .padding(.top, 14)
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

    private var watcherSubtitle: String {
        let watcher = model.folderWatcher
        if let error = watcher.lastError { return "出错：\(error)" }
        if !model.settings.watchedFolderPath.isEmpty && !watcher.isWatching {
            return "未在监听"
        }
        var parts = ["监听中"]
        if let name = watcher.lastImportedName { parts.append("最近 \(name)") }
        parts.append("本次已导入 \(watcher.importedCount) 张")
        return parts.joined(separator: " · ")
    }

    /// Trailing switch, same style every settings row uses.
    private func toggle(_ isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn)
            .labelsHidden()
            .toggleStyle(NeutralSwitchStyle())
    }

    /// Picking a folder implies intent, so arm the watcher in the same click —
    /// otherwise the user chooses a folder and nothing happens until they also
    /// find the 开启监听 row.
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

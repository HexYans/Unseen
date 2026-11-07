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

    // MARK: - Watcher summary (read-only here; the switches live in 设置 → 相册)

    private var watcherCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeader("文件夹监听")
            GroupSlab(footer: "开关和选项在 设置 → 相册。这里只显示当前状态。") {
                GroupRow(
                    symbol: model.folderWatcher.isWatching ? "eye.fill" : "eye.slash",
                    color: model.folderWatcher.isWatching ? .green : .gray,
                    title: model.settings.watchedFolderPath.isEmpty
                        ? "还没有选择文件夹"
                        : (model.settings.watchedFolderPath as NSString).abbreviatingWithTildeInPath,
                    subtitle: watcherSubtitle
                ) {
                    NeutralCapsuleButton(
                        title: "去设置",
                        help: "打开 设置 → 相册，选择要监听的文件夹"
                    ) {
                        model.onRequestOpenAlbumSettings?()
                    }
                }
            }
        }
    }

    private var watcherSubtitle: String {
        let watcher = model.folderWatcher
        if let error = watcher.lastError { return "出错：\(error)" }
        guard model.settings.autoImportEnabled else { return "未开启" }
        guard watcher.isWatching else { return "没有可监听的文件夹" }
        var parts = ["监听中"]
        if let name = watcher.lastImportedName { parts.append("最近导入 \(name)") }
        parts.append("本次已导入 \(watcher.importedCount) 张")
        return parts.joined(separator: " · ")
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

import AppKit
import SwiftUI

/// 相册 — where screenshots are saved into **macOS Photos**.
///
/// The page has two groups: 文件夹监听 and 导入行为. There is deliberately no
/// list of what has already been imported: the pictures live in 照片, which
/// already is the library — a second in-app gallery would only be a stale copy
/// of the same thing.
struct AlbumPage: View {
    @Bindable var model: AppModel
    @Binding var groupID: String

    var body: some View {
        Group {
            switch groupID {
            case AlbumPageGroup.behavior: behaviorPane
            default: folderPane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - 文件夹监听

    private var folderPane: some View {
        page(
            "选一个文件夹，之后保存进去的截图会自动存进「照片」。",
            action: ("打开照片", {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") {
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                }
            })
        ) {
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
        action: (title: String, handler: () -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsPageMetrics.sectionSpacing) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: SettingsPageMetrics.headerTitleSpacing) {
                        Text("相册")
                            .font(.system(size: 26, weight: .bold))
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if let action {
                        NeutralCapsuleButton(title: action.title, help: nil) {
                            action.handler()
                        }
                    }
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

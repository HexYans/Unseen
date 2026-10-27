import AppKit
import SwiftUI

/// A single clipboard row. Shared by the menu bar panel and the main window.
///
/// In the panel a single click copies immediately (speed matters). In the main
/// window a click only selects, and a double click copies — hence the two
/// optional callbacks.
struct ClipRowView: View {
    let model: AppModel
    let item: ClipItem
    let isSelected: Bool
    /// 1…9 in the panel, where the number keys jump straight to a row. `nil`
    /// everywhere else, so the main window does not advertise a shortcut it
    /// does not have.
    var shortcutNumber: Int?
    var onTap: (() -> Void)?
    var onDoubleTap: (() -> Void)?
    /// Only supplied by the panel, where a quick-look overlay makes sense.
    var onPreview: (() -> Void)?
    /// Reports this row's hover state. The panel uses it so ⌘⇧P can pin the row
    /// under the pointer instead of whichever row happens to be selected.
    var onHoverChange: ((Bool) -> Void)?

    /// When the previous tap happened, used to recognise a double click
    /// ourselves. Attaching both `.onTapGesture(count: 2)` and
    /// `.onTapGesture` makes SwiftUI hold the single tap for the system
    /// double-click interval (~0.4 s) before committing the selection, which
    /// is exactly the "click feels stuck" delay.
    @State private var lastTapAt: CFAbsoluteTime = 0

    var body: some View {
        row.onTapGesture(perform: handleTap)
    }

    private func handleTap() {
        let now = CFAbsoluteTimeGetCurrent()
        let isDoubleClick = onDoubleTap != nil
            && lastTapAt > 0
            && now - lastTapAt < NSEvent.doubleClickInterval
        lastTapAt = isDoubleClick ? 0 : now
        if isDoubleClick {
            onDoubleTap?()
        } else if let onTap {
            onTap()
        } else {
            model.activate(item)
        }
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 10) {
            leading

            VStack(alignment: .leading, spacing: 3) {
                Text(item.preview)
                    .font(.system(size: 13))
                    // Selected rows keep primary text: the selection is a
                    // translucent glass wash, not an accent slab.
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 5) {
                    if item.pinned {
                        Image(systemName: "pin.fill").font(.system(size: 9))
                    }
                    Text(item.sourceApp ?? "未知来源")
                    Text("·")
                    Text(RelativeTime.string(for: item.updatedAt))
                    if item.copyCount > 0 {
                        Text("·")
                        Text("用过 \(item.copyCount) 次")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
            }

            if let shortcutNumber {
                Text("\(shortcutNumber)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.primary.opacity(0.9) : Color.secondary.opacity(0.8))
                    .frame(width: 16, height: 16)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isSelected ? Color.primary.opacity(0.10) : Color.primary.opacity(0.06))
                    )
                    .padding(.top, 1)
                    .help("按 \(shortcutNumber) 复制这一条")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        // The selection chip is inset 5 pt horizontally, so the hover chip is
        // inset by exactly the same amount and the two never disagree.
        .background(SelectionBackground(selected: isSelected).padding(.horizontal, 5))
        .contentShape(Rectangle())
        .hoverHighlight(
            isSelected: isSelected,
            inset: EdgeInsets(top: 0, leading: 5, bottom: 0, trailing: 5)
        )
        .contextMenu { menuItems }
        .onHover { hovering in onHoverChange?(hovering) }
        .help("点击即复制\(model.settings.autoPaste ? "并粘贴到上一个 App" : "")")
    }

    @ViewBuilder
    private var leading: some View {
        if item.hasImage {
            ImageThumbnail(model: model, item: item)
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.14))
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: item.kind.symbolName)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                )
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("复制") { model.copy(item, paste: false) }
        Button(model.settings.autoPaste ? "粘贴到当前 App" : "粘贴到当前 App（需在设置中开启）") {
            model.copy(item, paste: true)
        }
        if let onPreview {
            Button("预览") { onPreview() }
        }
        if item.hasImage {
            Button("钉在屏幕上") { model.pinToScreen(item) }
        }

        Divider()

        Button(item.pinned ? "取消固定" : "固定到顶部") { model.togglePin(item) }
        if let bundleID = item.bundleID {
            Button("不再记录 \(item.sourceApp ?? bundleID)") { model.ignoreApp(bundleID: bundleID) }
        }

        Divider()

        if !item.fileURLs.isEmpty {
            Button("在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting(item.fileURLs.map { URL(fileURLWithPath: $0) })
            }
        }
        Button("删除", role: .destructive) { model.delete(item) }
    }
}

/// Small square thumbnail for image entries, loaded lazily from the database.
struct ImageThumbnail: View {
    let model: AppModel
    let item: ClipItem
    var side: CGFloat = 28

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.secondary.opacity(0.1)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.18))
        .overlay(
            RoundedRectangle(cornerRadius: side * 0.18)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .task(id: item.id) {
            guard image == nil else { return }
            image = model.thumbnailImage(for: item)
        }
    }
}

@MainActor
enum RelativeTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    static func string(for date: Date) -> String {
        formatter.localizedString(for: date, relativeTo: Date())
    }
}

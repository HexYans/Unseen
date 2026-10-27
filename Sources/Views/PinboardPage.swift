import AppKit
import SwiftUI

/// Manage the images currently pinned onto the screen — as grouped rows, so it
/// matches the rest of the app.
struct PinboardPage: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if model.pinboard.pins.isEmpty {
                    emptyState
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        GroupHeader("屏幕上的钉图")
                        GroupSlab(footer: "拖拽移动、滚轮缩放、悬停出现工具条、esc 关闭。关掉 App 后下次启动会自动恢复。") {
                            ForEach(Array(model.pinboard.pins.enumerated()), id: \.element.id) { index, pin in
                                if index > 0 { GroupDivider() }
                                PinRow(model: model, pin: pin)
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        NeutralCapsuleButton(
                            title: "全部置顶",
                            symbol: "square.3.layers.3d.top.filled",
                            help: "把所有钉图都提到最前面"
                        ) {
                            model.pinboard.bringAllToFront()
                        }
                        NeutralCapsuleButton(
                            title: "全部关闭",
                            ink: .red,
                            help: "关闭屏幕上所有钉图"
                        ) {
                            model.pinboard.unpinAll()
                        }
                    }
                    .padding(.leading, 4)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 4)
            .padding(.bottom, 24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("钉图")
                .font(.system(size: 26, weight: .bold))
            if !model.pinboard.pins.isEmpty {
                Text("\(model.pinboard.pins.count) 张图片正贴在屏幕上。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeader("怎么钉图")
            GroupSlab {
                GroupRow(
                    symbol: "clock.arrow.circlepath",
                    color: SectionPalette.history,
                    title: "从历史里钉",
                    subtitle: "选中图片按 ⌘P，或右键选「钉在屏幕上」"
                )
                GroupDivider()
                GroupRow(
                    symbol: "doc.on.clipboard",
                    color: .gray,
                    title: "从剪贴板里钉",
                    subtitle: "复制一张图，然后打开历史面板"
                )
            }
        }
    }
}

/// One pinned image, as a row with a thumbnail.
private struct PinRow: View {
    @Bindable var model: AppModel
    let pin: PinnedImage

    @State private var thumbnail: NSImage?

    var body: some View {
        GroupRow(
            thumbnail: thumbnail,
            color: .orange,
            title: "\(Int(pin.width)) × \(Int(pin.height))",
            subtitle: pin.isVisible
                ? "显示中 · 不透明度 \(Int(pin.opacity * 100))%"
                : "已隐藏 · 不透明度 \(Int(pin.opacity * 100))%"
        ) {
            HStack(spacing: 6) {
                NeutralCapsuleButton(
                    title: pin.isVisible ? "隐藏" : "显示",
                    help: pin.isVisible ? "把这张钉图从屏幕上藏起来" : "重新显示这张钉图"
                ) {
                    model.pinboard.setVisible(pin.id, !pin.isVisible)
                }
                NeutralCapsuleButton(
                    title: "关闭",
                    ink: .red,
                    help: "移除这张钉图"
                ) {
                    model.pinboard.unpin(pin.id)
                }
            }
        }
        .task(id: pin.itemID) {
            guard thumbnail == nil,
                  let data = model.pinboard.imageData(for: pin) else { return }
            thumbnail = NSImage(data: data)
        }
    }
}

import AppKit
import SwiftUI

/// Widths shared by every row of the 快捷键 page.
///
/// The page is a stack of `GroupSlab` cards now — the owner asked for the same
/// visual language as 通用 / 外观 / 截图, and a data table (caption strip,
/// zebra rows, its own rounded frame) was the only page that did not speak it.
/// Each row is therefore an ordinary `GroupRow`, and only the two trailing
/// controls keep fixed widths, so the shortcut cells still form a column:
///
///     [icon] 名称 ………………… [ 快捷键槽位 136 ] [默认 46]
///
/// The 136 pt is `HotKeyRecorderView`'s own capsule (118 pt label + 9 pt
/// padding each side); the 46 pt is the capsule button every other settings
/// row uses. Both are fixed, so a long name wraps instead of pushing the keys
/// off the card.
enum HotKeyListMetrics {
    /// `HotKeyRecorderView`'s capsule at its shipped width (118 + 9 + 9).
    static let shortcutColumn: CGFloat = 136
    static let defaultColumn: CGFloat = 46
    /// Slot → 默认. The same 8 pt the recorder uses when it draws the paired
    /// button itself, so the two shapes sit exactly as they do on 截图.
    static let controlGap: CGFloat = 8
    /// `GroupRow`'s pitch on this page: the 28 pt recorder is taller than the
    /// 26 pt glyph tile, and `GroupRow` adds 9 pt above and below it. Quoted so
    /// the offline test can prove the cards keep one rhythm.
    static let rowMinHeight: CGFloat = 46
}

/// The two fixed-width cells a 快捷键 row lines up.
///
/// There is no caption row any more, so these anchors are what the offline
/// test measures: every row's slot starts at the same x, every 默认 button
/// starts exactly one slot + gap further right.
enum HotKeyListColumn: String, CaseIterable {
    case shortcut
    case defaultValue
}

/// Invisible 1×1 anchor. SwiftUI gives no public way to read a layout frame, and
/// a custom `NSView` survives the view erasure — the same trick as
/// `GroupSlabMarker`.
struct HotKeyListColumnMarker: NSViewRepresentable {
    let column: HotKeyListColumn

    func makeNSView(context: Context) -> HotKeyListColumnMarkerView {
        HotKeyListColumnMarkerView(column: column)
    }

    func updateNSView(_ nsView: HotKeyListColumnMarkerView, context: Context) {}

    static func anchor(_ column: HotKeyListColumn) -> some View {
        HotKeyListColumnMarker(column: column)
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
    }
}

final class HotKeyListColumnMarkerView: NSView {
    let column: HotKeyListColumn

    init(column: HotKeyListColumn) {
        self.column = column
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

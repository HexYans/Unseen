import AppKit

/// The emoji the sticker tool offers. A fixed, curated list rather than the
/// system emoji picker: it opens instantly, needs no character viewer, and every
/// glyph is guaranteed to be a colour emoji (some "symbol" scalars fall back to
/// monochrome text and would look wrong next to the other stickers).
enum StickerCatalog {
    /// 24 emoji in four rows of six: reactions, gestures, markers, objects.
    static let emojis: [String] = [
        "😀", "😂", "😍", "😎", "🤔", "😭",
        "😡", "👍", "👎", "👏", "🙏", "💪",
        "🎉", "❤️", "🔥", "⭐️", "✅", "❌",
        "❗️", "❓", "💡", "🚀", "🎯", "👀"
    ]
}

/// The sticker tool's emoji grid. Drawn by hand for the same reason the toolbar
/// is: the offscreen self test has to see exactly the same pixels as the live
/// popover, and `NSButton` bezels only exist in a window server session.
///
/// Coordinates are standard AppKit (bottom-left origin); row 0 is the **top**
/// row, so the grid reads like the emoji picker every user already knows.
@MainActor
final class StickerPickerView: NSView {
    /// One cell is 36 pt: a 26 pt glyph plus breathing room.
    static let cellSize: CGFloat = 36
    static let columns = 6
    static let padding: CGFloat = 8

    let emojis: [String]
    var onPick: ((String) -> Void)?

    private var hoveredIndex: Int?

    init(emojis: [String] = StickerCatalog.emojis) {
        self.emojis = emojis
        let rows = Self.rows(for: emojis.count)
        let size = CGSize(
            width: Self.padding * 2 + CGFloat(Self.columns) * Self.cellSize,
            height: Self.padding * 2 + CGFloat(rows) * Self.cellSize
        )
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
        setAccessibilityRole(.group)
        setAccessibilityLabel("贴纸选择器")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: Self.padding * 2 + CGFloat(Self.columns) * Self.cellSize,
            height: Self.padding * 2 + CGFloat(Self.rows(for: emojis.count)) * Self.cellSize
        )
    }

    static func rows(for count: Int) -> Int {
        max(1, (count + columns - 1) / columns)
    }

    // MARK: - Geometry (shared with the self test)

    /// Frame of the cell at `index` in this view's coordinates. Row 0 is the
    /// top row.
    func cellFrame(at index: Int) -> CGRect {
        let column = index % Self.columns
        let row = index / Self.columns
        let x = Self.padding + CGFloat(column) * Self.cellSize
        let y = bounds.height
            - Self.padding
            - CGFloat(row + 1) * Self.cellSize
        return CGRect(x: x, y: y, width: Self.cellSize, height: Self.cellSize)
    }

    /// Emoji under a point, or `nil` in the padding / gaps.
    func emoji(at point: CGPoint) -> String? {
        for (index, emoji) in emojis.enumerated() {
            if cellFrame(at: index).contains(point) { return emoji }
        }
        return nil
    }

    // MARK: - Events

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        updateHover(at: nil)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let emoji = emoji(at: point) {
            onPick?(emoji)
        }
    }

    private func updateHover(at point: CGPoint?) {
        let index = point.flatMap { location in
            emojis.indices.first { cellFrame(at: $0).contains(location) }
        }
        guard index != hoveredIndex else { return }
        hoveredIndex = index
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.shouldAntialias = true

        if let hoveredIndex, hoveredIndex < emojis.count {
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(
                roundedRect: cellFrame(at: hoveredIndex).insetBy(dx: 2, dy: 2),
                xRadius: 7,
                yRadius: 7
            ).fill()
        }

        for (index, emoji) in emojis.enumerated() {
            let cell = cellFrame(at: index)
            let attributed = NSAttributedString(
                string: emoji,
                attributes: [.font: NSFont.systemFont(ofSize: 24)]
            )
            let size = attributed.size()
            let origin = CGPoint(
                x: cell.midX - size.width / 2,
                y: cell.midY - size.height / 2
            )
            attributed.draw(at: origin)
        }
    }
}

/// Owns the popover that hosts `StickerPickerView` and reports the pick.
///
/// It is deliberately tiny: the overlay decides *where* the picker appears and
/// what happens with the emoji; this type only lifetimes the `NSPopover`.
@MainActor
final class StickerPickerController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()

    var onPick: ((String) -> Void)?
    /// Fired when the popover closes for any reason (pick, Escape, click-away).
    var onClose: (() -> Void)?

    override init() {
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
    }

    func present(anchorRect: CGRect, in view: NSView) {
        let grid = StickerPickerView()
        grid.onPick = { [weak self] emoji in
            guard let self else { return }
            // Report first, close second: the overlay clears its pending anchor
            // when the popover closes, and the pick must still know where to land.
            self.onPick?(emoji)
            self.popover.close()
        }

        let controller = NSViewController()
        controller.view = grid
        popover.contentViewController = controller
        popover.contentSize = grid.intrinsicContentSize
        popover.show(relativeTo: anchorRect, of: view, preferredEdge: .maxY)
    }

    func close() {
        popover.close()
    }

    var isShown: Bool { popover.isShown }

    func popoverDidClose(_ notification: Notification) {
        onClose?()
    }
}

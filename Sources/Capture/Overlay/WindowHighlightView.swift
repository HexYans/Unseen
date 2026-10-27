import AppKit

/// Paints every capturable window plus the current multi-select state.
///
/// Multi-window capture deliberately reuses none of `SelectionBorderView`'s
/// eight-handle machinery: those handles mean "resize this rectangle", which is
/// not what a set of clicked windows does. Keeping this in its own view also
/// guarantees the frozen handle semantics are untouched.
final class WindowHighlightView: NSView {
    struct Entry {
        let frame: CGRect
        let selected: Bool
        let hovered: Bool
    }

    /// How one entry's outline is painted.
    ///
    /// `isMatchedToSelection` means "use `SelectionBorderStyle` verbatim": the
    /// same dark halo and white border a dragged region gets. The window under
    /// the pointer and an armed/selected window both take it; in multi-window
    /// mode the not-yet-clicked windows get the faint neutral outline instead.
    struct OutlineStyle {
        let isMatchedToSelection: Bool
        let color: NSColor
        let width: CGFloat
    }

    /// The single decision the self-test reads and `draw` uses. There is no
    /// accent colour anywhere on this path.
    static func outlineStyle(selected: Bool, hovered: Bool) -> OutlineStyle {
        if selected || hovered {
            return OutlineStyle(
                isMatchedToSelection: true,
                color: SelectionBorderStyle.borderColor,
                width: SelectionBorderStyle.borderWidth
            )
        }
        return OutlineStyle(
            isMatchedToSelection: false,
            color: NSColor.white.withAlphaComponent(0.55),
            width: 1.25
        )
    }

    var entries: [Entry] = [] {
        didSet { needsDisplay = true }
    }

    /// Timing probe for the single-click window pick: called with the wall
    /// clock at the first `draw` that paints a selected entry, then cleared.
    /// Only the click-timing run sets it, so production pays nothing.
    var armedPaintProbe: ((_ paintedAt: CFAbsoluteTime) -> Void)?

    var hint: String = "" {
        didSet {
            guard hint != oldValue else { return }
            needsDisplay = true
        }
    }

    /// When set, the hint capsule is drawn just above this point (in this
    /// view's coordinates) instead of at the bottom centre. Window picking
    /// follows the pointer; multi-window keeps the fixed footer.
    var hintAnchor: CGPoint? {
        didSet {
            guard hintAnchor != oldValue else { return }
            needsDisplay = true
        }
    }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.shouldAntialias = true

        // Measured here rather than at `needsDisplay`: this is the point where
        // the armed pixels actually exist.
        if let probe = armedPaintProbe, entries.contains(where: { $0.selected }) {
            armedPaintProbe = nil
            probe(CFAbsoluteTimeGetCurrent())
        }

        for entry in entries {
            guard entry.frame.width >= 1, entry.frame.height >= 1 else { continue }

            // A neutral white wash marks "this is the part that will be
            // captured". It is deliberately not the accent colour and it is not
            // a tinted slab; the outline carries the contrast.
            let fillAlpha: CGFloat = entry.selected ? 0.14 : (entry.hovered ? 0.10 : 0.05)
            NSColor.white.withAlphaComponent(fillAlpha).setFill()
            NSBezierPath(rect: entry.frame).fill()

            let style = Self.outlineStyle(selected: entry.selected, hovered: entry.hovered)
            if style.isMatchedToSelection {
                // Exactly the region selection's outline (halo + white border),
                // read from the one shared definition.
                SelectionBorderStyle.strokeOutline(entry.frame)
            } else {
                style.color.setStroke()
                let outline = NSBezierPath(rect: entry.frame)
                outline.lineWidth = style.width
                outline.stroke()
            }
        }

        // Selection order badges, so "3 windows" is not just a count. Neutral
        // chrome, like the hint capsule, so the highlight stays monochrome.
        var index = 0
        for entry in entries where entry.selected {
            index += 1
            let centre = CGPoint(x: entry.frame.minX + 15, y: entry.frame.maxY - 15)
            let badge = NSBezierPath(
                ovalIn: CGRect(x: centre.x - 10, y: centre.y - 10, width: 20, height: 20)
            )
            NSColor.black.withAlphaComponent(0.72).setFill()
            badge.fill()
            NSColor.white.withAlphaComponent(0.16).setStroke()
            badge.lineWidth = 1
            badge.stroke()

            let number = "\(index)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
                .foregroundColor: NSColor.white
            ]
            let size = number.size(withAttributes: attributes)
            number.draw(
                at: CGPoint(x: centre.x - size.width / 2, y: centre.y - size.height / 2),
                withAttributes: attributes
            )
        }

        drawHint()
    }

    private func drawHint() {
        guard !hint.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let text = hint as NSString
        let textSize = text.size(withAttributes: attributes)
        let width = ceil(textSize.width) + 28
        let height: CGFloat = 28

        // Near the pointer by default; clamped so a cursor at the screen edge
        // still shows the whole capsule. No anchor keeps multi-window's fixed
        // bottom-centre footer.
        let proposed: CGPoint
        if let hintAnchor {
            proposed = CGPoint(x: hintAnchor.x + 14, y: hintAnchor.y + 14)
        } else {
            proposed = CGPoint(x: bounds.midX - width / 2, y: 34)
        }
        let maxX = max(8, bounds.maxX - width - 8)
        let maxY = max(8, bounds.maxY - height - 8)
        let frame = CGRect(
            x: min(max(proposed.x, 8), maxX),
            y: min(max(proposed.y, 8), maxY),
            width: width,
            height: height
        )
        let capsule = NSBezierPath(
            roundedRect: frame,
            xRadius: height / 2,
            yRadius: height / 2
        )
        NSColor.black.withAlphaComponent(0.72).setFill()
        capsule.fill()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        capsule.lineWidth = 1
        capsule.stroke()
        text.draw(
            at: CGPoint(
                x: frame.midX - textSize.width / 2,
                y: frame.midY - textSize.height / 2
            ),
            withAttributes: attributes
        )
    }
}

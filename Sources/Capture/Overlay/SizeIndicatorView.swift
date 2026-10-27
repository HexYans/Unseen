import AppKit

/// The small "300 × 200" chip near the selection.
///
/// It measures text and decides where to sit; it never draws the border or
/// handles. Placement has to dodge both the toolbar and the screen edges,
/// which is why the frame calculation takes the toolbar frame as input.
///
/// The chip is also the editable size field (iShot: "提示条里修改长宽数值可以
/// 调整框选尺寸"). While editing it grows into a two-field editor; the overlay
/// owns the keyboard grammar (Return / Tab / Escape) and the geometry, this
/// view only owns the controls and their layout.
final class SizeIndicatorView: NSView, NSTextFieldDelegate {
    /// Where the chip is being shown. `floating` keeps the historical dark
    /// capsule that sits on the dimmed desktop; `toolbar` is the same view
    /// hosted in the capture toolbar's left auxiliary group, where the ink must
    /// follow the light/dark appearance of the plate behind it. This changes
    /// drawing only — the editing state machine is identical in both.
    enum ChipStyle {
        case floating
        case toolbar
    }

    var chipStyle: ChipStyle = .floating {
        didSet {
            guard chipStyle != oldValue else { return }
            updateFieldAppearance()
            needsDisplay = true
        }
    }

    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            needsDisplay = true
        }
    }

    /// `true` while the two number fields are on screen. Non-editing hit
    /// testing still returns nil, so the overlay root keeps routing clicks.
    private(set) var isEditing = false

    /// Which field owns focus: 0 = width, 1 = height. Kept here so the
    /// offscreen harness can assert focus without a window server, and so the
    /// active field can be highlighted even in a non-activating panel.
    private(set) var activeField = 0

    /// Return pressed in a field. The overlay's key monitor is the primary
    /// path; this is the standard field-action fallback.
    var onFieldAction: (() -> Void)?

    /// Called when the chip's own size changes (entering / leaving edit mode)
    /// so the overlay can re-run `placement` against the new width.
    var onPreferredSizeChange: (() -> Void)?

    private var widthField: NSTextField?
    private var heightField: NSTextField?
    private var timesLabel: NSTextField?

    /// Padding around the label, plus the capsule height.
    private static let horizontalPadding: CGFloat = 8
    private static let height: CGFloat = 22
    private static let fontSize: CGFloat = 11

    // Editor metrics. Two 54 pt number fields with a "×" between them; the
    // capsule is a little taller than the read-only chip so the fields breathe.
    private static let editorFieldWidth: CGFloat = 54
    private static let editorFieldHeight: CGFloat = 20
    private static let editorHeight: CGFloat = 26
    private static let editorGap: CGFloat = 4
    private static let editorPadding: CGFloat = 6
    private static let editorTimesWidth: CGFloat = 12

    private static var font: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
    }

    override var isOpaque: Bool { false }

    /// Only the editor takes clicks. The read-only chip stays invisible to hit
    /// testing so the overlay root keeps owning every gesture on it (which is
    /// how a single click is detected).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEditing else { return nil }
        return super.hitTest(point)
    }

    static func text(for size: CGSize) -> String {
        "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
    }

    private static func measuredSize(for text: String) -> CGSize {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let label = (text as NSString).size(withAttributes: attributes)
        return CGSize(
            width: ceil(label.width) + horizontalPadding * 2,
            height: height
        )
    }

    private static var editorSize: CGSize {
        CGSize(
            width: editorPadding * 2
                + editorFieldWidth * 2
                + editorGap * 2
                + editorTimesWidth,
            height: editorHeight
        )
    }

    /// The size `placement` must reserve: the editor while editing, the
    /// measured label otherwise.
    var preferredSize: CGSize {
        isEditing ? Self.editorSize : Self.measuredSize(for: text)
    }

    // MARK: - Edit mode

    /// Turn the chip into two number fields prefilled with the current size,
    /// width selected. The overlay installs the key monitor and focus.
    func beginEditing(width: Int, height: Int) {
        guard !isEditing else { return }
        isEditing = true
        activeField = 0

        let widthField = makeField(String(width))
        let heightField = makeField(String(height))
        let times = makeTimesLabel()

        addSubview(widthField)
        addSubview(times)
        addSubview(heightField)
        self.widthField = widthField
        self.timesLabel = times
        self.heightField = heightField

        updateFieldAppearance()
        needsDisplay = true
        needsLayout = true
        layoutSubtreeIfNeeded()
        onPreferredSizeChange?()
    }

    /// Remove the fields and go back to the read-only capsule. Values are read
    /// by the overlay *before* this runs.
    func endEditing() {
        guard isEditing else { return }
        isEditing = false
        for field in [widthField, heightField] {
            // Drop the delegate before detaching: removing a first responder
            // must not call back into the commit path.
            field?.delegate = nil
            field?.removeFromSuperview()
        }
        timesLabel?.removeFromSuperview()
        widthField = nil
        heightField = nil
        timesLabel = nil
        needsDisplay = true
        needsLayout = true
        onPreferredSizeChange?()
    }

    /// Parsed field contents. `nil` means "leave that dimension alone": empty
    /// or non-numeric text is forgiven rather than committing a nonsense size.
    func editingValues() -> (width: Int?, height: Int?) {
        (Self.parseInt(widthField?.stringValue), Self.parseInt(heightField?.stringValue))
    }

    /// Focus one field and select all of its text, matching the requirement
    /// that the prefilled value is ready to be overwritten.
    func focusField(_ index: Int) {
        guard isEditing, index == 0 || index == 1 else { return }
        activeField = index
        updateFieldAppearance()
        guard let field = index == 0 ? widthField : heightField else { return }
        // Offscreen harness: no window, so focus is the logical `activeField`
        // (which the render highlights); production also selects the text.
        guard let window else { return }
        window.makeFirstResponder(field)
        field.selectText(nil)
    }

    /// Test seam: write values through the same fields the user types into.
    func setEditingValuesForTesting(width: String, height: String) {
        widthField?.stringValue = width
        heightField?.stringValue = height
    }

    /// Raw field text, for logging and the offscreen harness.
    var editingTextValues: (width: String, height: String) {
        (widthField?.stringValue ?? "", heightField?.stringValue ?? "")
    }

    private static func parseInt(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Plain decimal only; a pasted "460.0" or "abc" leaves the axis alone.
        return Int(trimmed)
    }

    private func makeField(_ value: String) -> NSTextField {
        let field = NSTextField()
        field.stringValue = value
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.white.withAlphaComponent(0.10)
        field.focusRingType = .none
        field.alignment = .center
        field.font = Self.font
        field.textColor = inkColor
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.cell?.sendsActionOnEndEditing = false
        field.delegate = self
        field.target = self
        field.action = #selector(fieldAction(_:))
        field.wantsLayer = true
        field.layer?.cornerRadius = 4
        field.layer?.borderWidth = 1
        field.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        return field
    }

    private func makeTimesLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "×")
        label.alignment = .center
        label.font = Self.font
        label.textColor = inkColor.withAlphaComponent(0.75)
        return label
    }

    /// Glyph/field ink. `labelColor` is the light/dark-aware ink; the floating
    /// chip keeps white because it sits on its own near-black capsule.
    private var inkColor: NSColor {
        chipStyle == .toolbar ? .labelColor : .white
    }

    private func updateFieldAppearance() {
        let ink = inkColor
        let activeBackground = ink.withAlphaComponent(0.24)
        let idleBackground = ink.withAlphaComponent(0.10)
        let activeBorder = NSColor.controlAccentColor.withAlphaComponent(0.95).cgColor
        let idleBorder = ink.withAlphaComponent(0.12).cgColor

        for (index, field) in [widthField, heightField].enumerated() {
            guard let field else { continue }
            field.textColor = ink
            field.backgroundColor = activeField == index ? activeBackground : idleBackground
            field.layer?.borderColor = activeField == index ? activeBorder : idleBorder
            field.layer?.borderWidth = activeField == index ? 1.5 : 1
        }
    }

    @objc private func fieldAction(_ sender: Any?) {
        onFieldAction?()
    }

    /// A click directly into the other field must move the accent highlight
    /// with the field editor; Tab already does this through `focusField`.
    func controlTextDidBeginEditing(_ notification: Notification) {
        guard isEditing, let field = notification.object as? NSTextField else { return }
        if field === widthField {
            activeField = 0
        } else if field === heightField {
            activeField = 1
        } else {
            return
        }
        updateFieldAppearance()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        guard isEditing else { return }
        let fieldY = (bounds.height - Self.editorFieldHeight) / 2
        let widthX = Self.editorPadding
        let timesX = widthX + Self.editorFieldWidth + Self.editorGap
        let heightX = timesX + Self.editorTimesWidth + Self.editorGap
        widthField?.frame = CGRect(
            x: widthX,
            y: fieldY,
            width: Self.editorFieldWidth,
            height: Self.editorFieldHeight
        )
        timesLabel?.frame = CGRect(
            x: timesX,
            y: fieldY,
            width: Self.editorTimesWidth,
            height: Self.editorFieldHeight
        )
        heightField?.frame = CGRect(
            x: heightX,
            y: fieldY,
            width: Self.editorFieldWidth,
            height: Self.editorFieldHeight
        )
    }

    // MARK: - Placement

    /// Pick a position that does not overlap the toolbar, preferring inside
    /// the selection (top-left, then bottom-left) and falling back to just
    /// outside it. The result is always clamped inside the screen.
    func placement(
        for selection: CGRect,
        screenBounds: CGRect,
        avoiding toolbarFrame: CGRect
    ) -> CGRect {
        let size = preferredSize
        let margin: CGFloat = 6
        let gap: CGFloat = 6
        let forbidden = toolbarFrame.insetBy(dx: -4, dy: -4)

        let candidates: [CGPoint] = [
            CGPoint(x: selection.minX + margin, y: selection.maxY - size.height - margin),
            CGPoint(x: selection.minX + margin, y: selection.minY + margin),
            CGPoint(x: selection.maxX - size.width - margin, y: selection.maxY - size.height - margin),
            CGPoint(x: selection.minX, y: selection.maxY + gap),
            CGPoint(x: selection.minX, y: selection.minY - size.height - gap)
        ]

        for origin in candidates {
            let frame = clamp(CGRect(origin: origin, size: size), to: screenBounds, margin: margin)
            if !frame.intersects(forbidden) {
                return frame
            }
        }

        // Everything overlaps (tiny screen or tiny selection): stay visible at
        // the selection's top-left rather than vanishing.
        return clamp(
            CGRect(
                x: selection.minX + margin,
                y: selection.maxY - size.height - margin,
                width: size.width,
                height: size.height
            ),
            to: screenBounds,
            margin: margin
        )
    }

    private func clamp(_ rect: CGRect, to bounds: CGRect, margin: CGFloat) -> CGRect {
        var result = rect
        let maxX = max(bounds.minX + margin, bounds.maxX - result.width - margin)
        let maxY = max(bounds.minY + margin, bounds.maxY - result.height - margin)
        result.origin.x = min(max(result.origin.x, bounds.minX + margin), maxX)
        result.origin.y = min(max(result.origin.y, bounds.minY + margin), maxY)
        return result
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        if isEditing {
            drawEditorCapsule()
            return
        }
        guard !text.isEmpty else { return }
        NSGraphicsContext.current?.shouldAntialias = true

        let capsule = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: bounds.height / 2,
            yRadius: bounds.height / 2
        )
        // Bare at rest in the toolbar, exactly like the icons beside it: the
        // plate is the only surface. The floating chip keeps its dark capsule.
        if chipStyle == .floating {
            NSColor.black.withAlphaComponent(0.68).setFill()
            capsule.fill()
            NSColor.white.withAlphaComponent(0.18).setStroke()
            capsule.lineWidth = 1
            capsule.stroke()
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: inkColor
        ]
        let label = text as NSString
        let labelSize = label.size(withAttributes: attributes)
        let origin = CGPoint(
            x: (bounds.width - labelSize.width) / 2,
            y: (bounds.height - labelSize.height) / 2
        )
        label.draw(at: origin, withAttributes: attributes)
    }

    /// The editing capsule: same dark glass, with an accent edge so it reads
    /// as "this is an input now" even in an offscreen render where the system
    /// focus ring is suppressed.
    private func drawEditorCapsule() {
        NSGraphicsContext.current?.shouldAntialias = true
        let capsule = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
            xRadius: 8,
            yRadius: 8
        )
        if chipStyle == .toolbar {
            NSColor.labelColor.withAlphaComponent(0.10).setFill()
        } else {
            NSColor.black.withAlphaComponent(0.82).setFill()
        }
        capsule.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.70).setStroke()
        capsule.lineWidth = 1.5
        capsule.stroke()
    }
}

import AppKit
import SwiftUI

/// The data behind the result card: one line per recognised item, in the order
/// Vision returned them (barcodes first).
///
/// Kept as a value type so the window's content and the self test read the
/// exact same source. Nothing in here touches AppKit.
struct OCRResultModel: Equatable, Sendable {
    let items: [RecognizedItem]

    var lines: [String] { items.map(\.text) }

    /// What the copy button puts on the pasteboard.
    var text: String { lines.joined(separator: "\n") }

    var barcodeCount: Int { items.filter { $0.kind == .barcode }.count }
    var textCount: Int { items.filter { $0.kind == .text }.count }

    var summary: String {
        var parts: [String] = []
        if textCount > 0 { parts.append("\(textCount) 段文字") }
        if barcodeCount > 0 { parts.append("\(barcodeCount) 个条码") }
        return parts.isEmpty ? "没有识别到内容" : parts.joined(separator: " · ")
    }
}

/// Floating result panel. Closing it never changes the capture itself.
final class OCRResultPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // esc
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

/// Owns one OCR result window: the model, the selectable text view, the panel
/// geometry and the three footer actions.
///
/// The text view is created here (not inside SwiftUI) so the actual selectable
/// content exists deterministically, even in the offscreen self test where the
/// panel is never ordered on screen.
@MainActor
final class OCRResultWindowController: NSObject, NSWindowDelegate {
    /// Hard cap from the spec; the card is never allowed to grow past this.
    static let maximumSize = NSSize(width: 400, height: 500)
    static let minimumSize = NSSize(width: 320, height: 200)

    private static let horizontalPadding: CGFloat = 14
    private static let textFont = NSFont.systemFont(ofSize: 13)

    let model: OCRResultModel
    private(set) var window: OCRResultPanel?
    private(set) var textView: NSTextView
    /// Called after the panel is ordered out (button, red close, Escape).
    var onClose: (() -> Void)?

    private var hasClosed = false

    init(items: [RecognizedItem]) {
        let model = OCRResultModel(items: items)
        self.model = model
        self.textView = Self.makeTextView(text: model.text)
        super.init()
        self.window = makeWindow()
    }

    // MARK: - Test hooks

    var lines: [String] { model.lines }
    var text: String { model.text }
    var contentLineCountForTesting: Int { model.lines.count }
    var contentTextForTesting: String { model.text }

    /// Lay the hosted view out without ordering the panel on screen.
    func prepareContentForTesting() {
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.contentView?.displayIfNeeded()
    }

    // MARK: - Presentation

    func show() {
        guard !hasClosed, let panel = window else { return }
        position(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        DebugLog.log(
            "ocr: result window shown lines=\(model.lines.count) "
            + "size=\(Int(panel.frame.width))×\(Int(panel.frame.height))"
        )
    }

    // MARK: - Actions

    @discardableResult
    func copy(to pasteboard: NSPasteboard = .general) -> Bool {
        guard !model.text.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(model.text, forType: .string)
    }

    func copyAndClose(to pasteboard: NSPasteboard = .general) {
        copy(to: pasteboard)
        close()
    }

    func close() {
        guard !hasClosed else { return }
        hasClosed = true
        window?.orderOut(nil)
        onClose?()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard !hasClosed else { return }
        hasClosed = true
        onClose?()
    }

    // MARK: - Geometry

    /// Width follows the longest line, height follows the line count, both
    /// clamped to the 400 × 500 cap. Pure so the self test can assert the cap
    /// without a window server.
    static func preferredSize(for text: String) -> NSSize {
        let lines = max(1, text.components(separatedBy: "\n").count)
        let longest = text
            .components(separatedBy: "\n")
            .map { (($0.isEmpty ? " " : $0) as NSString).size(withAttributes: [.font: textFont]).width }
            .max() ?? 0
        let lineHeight = ceil(
            textFont.ascender - textFont.descender + textFont.leading
        )

        let chromeHeight: CGFloat = 46 + 54 + 26  // header + footer + padding
        let width = min(
            maximumSize.width,
            max(minimumSize.width, ceil(longest) + horizontalPadding * 2 + 8)
        )
        let height = min(
            maximumSize.height,
            max(minimumSize.height, chromeHeight + CGFloat(lines) * lineHeight + 20)
        )
        return NSSize(width: width, height: height)
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            panel.center()
            return
        }
        let size = panel.frame.size
        let x = min(
            max(visible.midX - size.width / 2, visible.minX + 8),
            visible.maxX - size.width - 8
        )
        let y = min(
            max(visible.midY - size.height / 2, visible.minY + 8),
            visible.maxY - size.height - 8
        )
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Construction

    private func makeWindow() -> OCRResultPanel {
        let size = Self.preferredSize(for: model.text)
        // Borderless: the glass card is the whole surface, there is no title
        // bar to eat into the 400×500 cap, and the footer already offers 关闭.
        let panel = OCRResultPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.title = "识别结果"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.delegate = self
        panel.setAccessibilityLabel("识别结果")
        panel.onEscape = { [weak self] in self?.close() }

        let root = OCRResultCard(
            model: model,
            textView: textView,
            onCopy: { [weak self] in self?.copy() },
            onCopyAndClose: { [weak self] in self?.copyAndClose() },
            onClose: { [weak self] in self?.close() }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        return panel
    }

    private static func makeTextView(text: String) -> NSTextView {
        let textView = NSTextView()
        textView.string = text
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = textFont
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = []
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.setAccessibilityLabel("识别结果文本")
        return textView
    }
}

// MARK: - SwiftUI card

private struct OCRResultCard: View {
    let model: OCRResultModel
    let textView: NSTextView
    var onCopy: () -> Void
    var onCopyAndClose: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Divider().opacity(0.45)

            OCRTextArea(textView: textView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().opacity(0.45)

            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.001))
        .glassSurface(cornerRadius: 18)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("识别结果")
                    .font(.system(size: 13, weight: .semibold))
                Text(model.summary)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("⌘C 复制 · Esc 关闭")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            Spacer(minLength: 0)

            Button("复制") { onCopy() }
                .controlSize(.small)
                .buttonStyle(.bordered)

            Button("复制并关闭") { onCopyAndClose() }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)

            Button("关闭") { onClose() }
                .controlSize(.small)
                .buttonStyle(.bordered)
        }
    }
}

/// Hosts the controller-owned `NSTextView` inside SwiftUI. Keeping the text
/// view outside the view builder is what lets the self test inspect its
/// selectability and string directly.
private struct OCRTextArea: NSViewRepresentable {
    let textView: NSTextView

    func makeNSView(context: Context) -> OCRTextContainerView {
        OCRTextContainerView(textView: textView)
    }

    func updateNSView(_ nsView: OCRTextContainerView, context: Context) {
        nsView.textView.string = textView.string
        nsView.needsLayout = true
    }
}

/// A scroll view that gives its document view a real frame.
///
/// An `NSTextView` dropped into an `NSScrollView` keeps a zero frame unless
/// something sizes it; SwiftUI's representable sizing is not enough because the
/// text view is not the representable's root view. Doing it in `layout()` also
/// makes the offscreen self-test render the real text.
private final class OCRTextContainerView: NSScrollView {
    let textView: NSTextView

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        borderType = .noBorder
        documentView = textView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        guard let container = textView.textContainer else { return }
        let width = max(1, contentSize.width)
        container.widthTracksTextView = true
        container.containerSize = NSSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.frame = NSRect(x: 0, y: 0, width: width, height: max(1, contentSize.height))
        textView.layoutManager?.ensureLayout(for: container)
        let used = textView.layoutManager?.usedRect(for: container) ?? .zero
        let height = max(
            contentSize.height,
            ceil(used.height + textView.textContainerInset.height * 2)
        )
        textView.frame = NSRect(x: 0, y: 0, width: width, height: height)
    }
}

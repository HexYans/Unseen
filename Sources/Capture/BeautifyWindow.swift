import AppKit
import CoreGraphics

/// Preview window for 套壳 / 美化截图.
///
/// Left: the composed image on a checkerboard (so a transparent background is
/// visible as transparency, not as black). Right: the three sliders, a
/// background preset picker and the copy/save actions.
///
/// The window owns no capture logic: it receives the already-captured pixels
/// and calls back only when it closes. Every render is delegated to
/// `BeautifyRenderer`, which is pure and separately covered by the self test.
@MainActor
final class BeautifyWindowController: NSObject, NSWindowDelegate {
    static let defaultSize = NSSize(width: 1_000, height: 660)
    static let inspectorWidth: CGFloat = 300

    let shot: CapturedScreenshot
    private(set) var options = BeautifyOptions()
    private(set) var renderedImage: CGImage?
    private(set) var window: NSWindow?

    /// Called after the window is ordered out (button, red close or ⌘W).
    var onClose: (() -> Void)?

    private var previewView: BeautifyPreviewView!
    private var paddingSlider: NSSlider!
    private var cornerSlider: NSSlider!
    private var shadowSlider: NSSlider!
    private var paddingValueLabel: NSTextField!
    private var cornerValueLabel: NSTextField!
    private var shadowValueLabel: NSTextField!
    private var backgroundPopup: NSPopUpButton!
    private var sizeLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var hasClosed = false

    init(shot: CapturedScreenshot) {
        self.shot = shot
        super.init()
        self.window = makeWindow()
        refresh()
    }

    // MARK: - Presentation

    func show() {
        guard let window else { return }
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        refresh()
        DebugLog.log(
            "beautify: window shown source=\(shot.image.width)×\(shot.image.height) "
            + "scale=\(shot.scale) output=\(renderedImage?.width ?? 0)×\(renderedImage?.height ?? 0)"
        )
    }

    func close() {
        window?.close()
    }

    // MARK: - Actions

    @discardableResult
    func copyToPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        guard let image = composedImage() else { return false }
        let pointSize = CGSize(
            width: CGFloat(image.width) / max(shot.scale, 0.01),
            height: CGFloat(image.height) / max(shot.scale, 0.01)
        )
        pasteboard.clearContents()
        let copied = pasteboard.writeObjects([NSImage(cgImage: image, size: pointSize)])
        statusLabel?.stringValue = copied ? "已拷贝到剪贴板" : "拷贝失败"
        return copied
    }

    @discardableResult
    func save(to url: URL) throws -> URL {
        guard let image = composedImage() else { throw BeautifyError.encodingFailed }
        try Self.writePNG(image, to: url)
        statusLabel?.stringValue = "已保存到 \(url.lastPathComponent)"
        return url
    }

    /// The last composed image, or a fresh composition if the window has not
    /// been laid out yet. Exposed for the self test.
    func composedImage() -> CGImage? {
        if let renderedImage { return renderedImage }
        return BeautifyRenderer.render(shot.image, options: options.scaled(by: shot.scale))
    }

    @objc private func paddingChanged(_ sender: NSSlider) {
        options.padding = CGFloat(sender.doubleValue)
        refresh()
    }

    @objc private func cornerChanged(_ sender: NSSlider) {
        options.cornerRadius = CGFloat(sender.doubleValue)
        refresh()
    }

    @objc private func shadowChanged(_ sender: NSSlider) {
        options.shadowRadius = CGFloat(sender.doubleValue)
        refresh()
    }

    @objc private func backgroundChanged(_ sender: NSPopUpButton) {
        guard let preset = BeautifyBackgroundPreset(rawValue: sender.indexOfSelectedItem) else { return }
        options.background = preset.background
        refresh()
    }

    @objc private func copyTapped() {
        copyToPasteboard()
    }

    @objc private func saveTapped() {
        guard let image = composedImage() else { return }
        let panel = NSSavePanel()
        panel.title = "保存套壳截图"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "套壳-\(fileNameTimestamp()).png"
        panel.directoryURL = FileManager.default.urls(
            for: .picturesDirectory,
            in: .userDomainMask
        ).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Self.writePNG(image, to: url)
            statusLabel?.stringValue = "已保存到 \(url.lastPathComponent)"
        } catch {
            statusLabel?.stringValue = "保存失败：\(error.localizedDescription)"
            NSSound.beep()
        }
    }

    @objc private func closeTapped() {
        window?.close()
    }

    // MARK: - Rendering

    private func refresh() {
        paddingValueLabel?.stringValue = "\(Int(options.padding.rounded())) pt"
        cornerValueLabel?.stringValue = "\(Int(options.cornerRadius.rounded())) pt"
        shadowValueLabel?.stringValue = "\(Int(options.shadowRadius.rounded())) pt"

        let composed = BeautifyRenderer.render(shot.image, options: options.scaled(by: shot.scale))
        renderedImage = composed
        previewView?.image = composed
        previewView?.imageScale = shot.scale
        sizeLabel?.stringValue = "输出 \(composed.width) × \(composed.height) px"
    }

    // MARK: - Window

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "套壳 / 美化截图"
        window.minSize = NSSize(width: 820, height: 560)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = makeContent()
        window.center()
        return window
    }

    private func makeContent() -> NSView {
        let root = NSView()

        let preview = BeautifyPreviewView()
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        preview.layer?.cornerRadius = 12
        preview.layer?.masksToBounds = true
        previewView = preview

        let inspector = makeInspector()
        inspector.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(preview)
        root.addSubview(inspector)

        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            preview.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            preview.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            preview.trailingAnchor.constraint(equalTo: inspector.leadingAnchor, constant: -18),

            inspector.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            inspector.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            inspector.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20),
            inspector.widthAnchor.constraint(equalToConstant: Self.inspectorWidth)
        ])
        return root
    }

    private func makeInspector() -> NSView {
        let title = NSTextField(labelWithString: "套壳 / 美化截图")
        title.font = .systemFont(ofSize: 20, weight: .bold)

        let subtitle = NSTextField(
            wrappingLabelWithString: "给截图加一个展台：四周留白、圆角与阴影。导出尺寸随参数实时更新。"
        )
        subtitle.font = .systemFont(ofSize: 11.5)
        subtitle.textColor = .secondaryLabelColor

        paddingSlider = makeSlider(min: 0, max: 160, value: Double(options.padding), action: #selector(paddingChanged(_:)))
        cornerSlider = makeSlider(min: 0, max: 80, value: Double(options.cornerRadius), action: #selector(cornerChanged(_:)))
        shadowSlider = makeSlider(min: 0, max: 80, value: Double(options.shadowRadius), action: #selector(shadowChanged(_:)))

        paddingValueLabel = makeValueLabel()
        cornerValueLabel = makeValueLabel()
        shadowValueLabel = makeValueLabel()

        let paddingRow = sliderRow("留白", valueLabel: paddingValueLabel, slider: paddingSlider)
        let cornerRow = sliderRow("圆角", valueLabel: cornerValueLabel, slider: cornerSlider)
        let shadowRow = sliderRow("阴影", valueLabel: shadowValueLabel, slider: shadowSlider)

        let backgroundTitle = NSTextField(labelWithString: "背景")
        backgroundTitle.font = .systemFont(ofSize: 12, weight: .medium)

        backgroundPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        backgroundPopup.addItems(withTitles: BeautifyBackgroundPreset.allCases.map(\.title))
        backgroundPopup.target = self
        backgroundPopup.action = #selector(backgroundChanged(_:))
        backgroundPopup.controlSize = .small
        backgroundPopup.selectItem(at: 0)

        let backgroundRow = NSStackView(views: [backgroundTitle, backgroundPopup])
        backgroundRow.orientation = .horizontal
        backgroundRow.spacing = 10
        backgroundRow.distribution = .fill
        backgroundRow.alignment = .centerY
        backgroundPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        sizeLabel = NSTextField(labelWithString: "")
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.alignment = .right

        let copyButton = NSButton(title: "拷贝", target: self, action: #selector(copyTapped))
        copyButton.bezelStyle = .rounded
        copyButton.keyEquivalent = "\r"
        copyButton.bezelColor = .controlAccentColor
        copyButton.controlSize = .large

        let saveButton = NSButton(title: "保存…", target: self, action: #selector(saveTapped))
        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .large

        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closeTapped))
        closeButton.bezelStyle = .rounded
        closeButton.controlSize = .large

        let buttonRow = NSStackView(views: [copyButton, saveButton, closeButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.distribution = .fill
        buttonRow.alignment = .centerY

        statusLabel = NSTextField(labelWithString: "调整后点「拷贝」或「保存…」。")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle

        let stack = NSStackView(views: [
            title, subtitle,
            spacer(of: 4),
            paddingRow, cornerRow, shadowRow,
            spacer(of: 4),
            backgroundRow,
            sizeLabel,
            spacer(of: 6),
            buttonRow,
            statusLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 14
        stack.setCustomSpacing(4, after: title)
        return stack
    }

    private func makeSlider(
        min: Double,
        max: Double,
        value: Double,
        action: Selector
    ) -> NSSlider {
        let slider = NSSlider(value: value, minValue: min, maxValue: max, target: self, action: action)
        slider.isContinuous = true
        slider.controlSize = .small
        return slider
    }

    private func makeValueLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }

    private func sliderRow(_ title: String, valueLabel: NSTextField, slider: NSSlider) -> NSView {
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [name, spacer, valueLabel])
        header.orientation = .horizontal
        header.distribution = .fill
        header.alignment = .centerY

        let row = NSStackView(views: [header, slider])
        row.orientation = .vertical
        row.spacing = 5
        return row
    }

    private func spacer(of height: CGFloat) -> NSView {
        let view = NSView()
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    // MARK: - Window delegate

    func windowWillClose(_ notification: Notification) {
        guard !hasClosed else { return }
        hasClosed = true
        window = nil
        DebugLog.log("beautify: window closed")
        onClose?()
    }

    // MARK: - File writing

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw BeautifyError.encodingFailed
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}

enum BeautifyError: LocalizedError {
    case encodingFailed

    var errorDescription: String? { "图片编码失败，无法保存。" }
}

/// Left-hand preview with a checkerboard so transparent backgrounds are
/// unmistakable, and an aspect-fit drawing of the composed output.
private final class BeautifyPreviewView: NSView {
    var image: CGImage? {
        didSet { needsDisplay = true }
    }
    var imageScale: CGFloat = 1

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let area = bounds.insetBy(dx: 14, dy: 14)
        guard area.width > 2, area.height > 2 else { return }
        drawCheckerboard(in: area)

        guard let image else { return }
        let natural = CGSize(
            width: CGFloat(image.width) / max(imageScale, 0.01),
            height: CGFloat(image.height) / max(imageScale, 0.01)
        )
        guard natural.width > 0, natural.height > 0 else { return }
        let fit = min(area.width / natural.width, area.height / natural.height)
        let size = CGSize(width: natural.width * fit, height: natural.height * fit)
        let rect = CGRect(
            x: area.midX - size.width / 2,
            y: area.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: image, size: natural).draw(
            in: rect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
    }

    private func drawCheckerboard(in rect: NSRect) {
        NSColor(white: 0.13, alpha: 1).setFill()
        NSBezierPath(rect: rect).fill()

        let tile: CGFloat = 12
        NSColor(white: 0.19, alpha: 1).setFill()
        var row = 0
        var y = rect.minY
        while y < rect.maxY {
            var x = rect.minX + (row.isMultiple(of: 2) ? 0 : tile)
            while x < rect.maxX {
                let cell = NSRect(
                    x: x,
                    y: y,
                    width: min(tile, rect.maxX - x),
                    height: min(tile, rect.maxY - y)
                ).intersection(rect)
                if !cell.isEmpty {
                    NSBezierPath(rect: cell).fill()
                }
                x += tile * 2
            }
            y += tile
            row += 1
        }
    }
}

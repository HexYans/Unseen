import AppKit
import SwiftUI

/// Non-key panel: it must never steal focus from the history panel, otherwise
/// the ↑/↓/esc key monitor would stop working while a preview is on screen.
final class QuickLookPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The Space-bar preview overlay.
@MainActor
final class QuickLookController {
    private static let size = NSSize(width: 480, height: 540)

    private let model: AppModel
    private var panel: QuickLookPanel?

    init(model: AppModel) {
        self.model = model
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Show the preview for `item`, placed next to `anchor` (the history panel).
    func show(for item: ClipItem, beside anchor: NSRect) {
        let panel = panel ?? makePanel()
        self.panel = panel

        // The root view is replaced rather than mutated so that switching rows
        // reloads image data from the database.
        panel.contentView = NSHostingView(
            rootView: ClipPreviewView(
                model: model,
                item: item,
                drawsGlassChrome: ClipPreviewView.quickLookUsesGlassChrome
            )
        )
        position(panel, beside: anchor)
        panel.orderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> QuickLookPanel {
        let panel = QuickLookPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: Color.clear)
        return panel
    }

    /// Prefer the right of the history panel; flip to the left when it would
    /// fall off screen.
    private func position(_ panel: NSPanel, beside anchor: NSRect) {
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        var x = anchor.maxX + 12
        if x + size.width > visible.maxX - 8 {
            x = anchor.minX - size.width - 12
        }
        if x < visible.minX + 8 {
            x = min(max(visible.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        }

        var y = anchor.maxY - size.height
        y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

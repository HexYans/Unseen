import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Borderless panel that can still become key, so the search field accepts
/// typing without pulling the whole app to the front.
final class ClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A blank strip that drags its window. Sits above the SwiftUI content, so it
/// must never overlap a control.
private final class PanelDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }
}

/// Where the history panel lands relative to the pointer.
///
/// Pure so the placement can be reasoned about (and verified) without a
/// window: the panel is centred on the pointer, then clamped into one screen's
/// `visibleFrame`, so a pointer near an edge — or in a corner — still opens a
/// fully visible panel.
enum PanelPlacement {
    /// Gap kept between the panel and the menu bar / Dock.
    static let screenInset: CGFloat = 8

    /// Panel origin for a pointer position on `visibleFrame`'s screen.
    static func origin(pointer: NSPoint, size: NSSize, visibleFrame: NSRect) -> NSPoint {
        clamp(
            NSPoint(x: pointer.x - size.width / 2, y: pointer.y - size.height / 2),
            size: size,
            visibleFrame: visibleFrame
        )
    }

    /// Moves `origin` as little as possible while keeping the whole panel
    /// inside `visibleFrame`. A screen smaller than the panel cannot fit it;
    /// such a screen falls back to its bottom-left corner instead of
    /// inverting the clamp range.
    static func clamp(_ origin: NSPoint, size: NSSize, visibleFrame: NSRect) -> NSPoint {
        let minX = visibleFrame.minX + screenInset
        let maxX = visibleFrame.maxX - size.width - screenInset
        let minY = visibleFrame.minY + screenInset
        let maxY = visibleFrame.maxY - size.height - screenInset
        let x = minX <= maxX ? min(max(origin.x, minX), maxX) : visibleFrame.minX
        let y = minY <= maxY ? min(max(origin.y, minY), maxY) : visibleFrame.minY
        return NSPoint(x: x, y: y)
    }
}

/// Owns the floating history panel: positioning, key handling, show/hide.
@MainActor
final class PanelController: NSObject {
    private static let size = NSSize(width: 420, height: 560)

    /// Inset kept between the drag strip and the groups on either side, so a
    /// click meant for the count capsule or a button never starts a drag.
    private static let dragInset: CGFloat = 10
    /// The strip sits inside the 47 pt action row with a small top/bottom gap.
    private static let dragRowInset: CGFloat = 4
    private static let dragRowHeight: CGFloat = 42

    private let panel: ClipboardPanel
    private let model: AppModel
    private let quickLook: QuickLookController
    /// Above the SwiftUI host, sized to the measured blank middle of the action
    /// row (see `applyActionBarLayout`).
    private let dragView: PanelDragView
    /// Last geometry reported by `HistoryPanel`, in the action row's top-left
    /// space.
    private var actionBarLayout = PanelActionBarLayout()
    /// Drag strip in the same top-left space; kept for the debug probe.
    private var dragArea = NSRect.zero
    private var keyMonitor: Any?
    /// Row under the pointer, reported by `HistoryPanel`. ⌘⇧P pins it when
    /// present and falls back to the selection when the pointer is off-list.
    private var hoveredRowItemID: Int64?
    /// Last time ⌘⇧P pinned the hovered row, for the global/local de-dupe.
    private var lastPinShortcutTime: TimeInterval = 0

    /// True while the panel owns the keyboard, which is when ⌘⇧P means
    /// "pin the row under the pointer" instead of "pin the newest image".
    var isKeyWindow: Bool { panel.isKeyWindow }

    init(model: AppModel, quickLook: QuickLookController) {
        self.model = model
        self.quickLook = quickLook
        self.panel = ClipboardPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.dragView = PanelDragView(frame: .zero)
        super.init()

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        // NB: do *not* add `.transient` here — it hides the window whenever the
        // app is deactivated, which fights the show/hide cycle.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // Borderless panels have no titlebar; without this nothing outside
        // the explicit drag area can move them.
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow

        let hosting = NSHostingView(rootView: HistoryPanel(
            model: model,
            onPreview: { [weak self] in self?.togglePreview() },
            onActionBarLayout: { [weak self] layout in
                self?.applyActionBarLayout(layout)
            },
            onHoverRow: { [weak self] itemID in
                self?.hoveredRowItemID = itemID
            }
        ))
        hosting.frame = NSRect(origin: .zero, size: Self.size)

        // The hosting view covers the whole panel, so there is no exposed
        // *window* background left for `isMovableByWindowBackground` to act on,
        // and SwiftUI never reports `mouseDownCanMoveWindow`. Put an AppKit
        // view on top instead — above the hosting view, but only over the blank
        // middle of the action row so the buttons keep their clicks.
        let container = NSView(frame: NSRect(origin: .zero, size: Self.size))
        container.autoresizesSubviews = true
        container.addSubview(hosting)
        container.addSubview(dragView)
        panel.contentView = container
        // Same 12 pt continuous corner as the main window. The SwiftUI
        // `clipShape` rounds the glass itself; masking the content layer as
        // well keeps the window's backing store (and therefore the shadow)
        // inside that shape.
        MainWindowChrome.apply(to: container, fullScreen: false)

        // Clicking anywhere else dismisses the panel.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelResignedKey),
            name: NSWindow.didResignKeyNotification,
            object: panel
        )
    }

    // MARK: - Action row geometry

    /// Fits `dragView` into the blank middle reported by `HistoryPanel`.
    ///
    /// The SwiftUI row measures the count capsule and the four-button group and
    /// hands both frames here, so the strip follows the real layout: it stays
    /// clear of the capsule when the count grows a digit and clear of the
    /// buttons when a symbol changes width.
    private func applyActionBarLayout(_ layout: PanelActionBarLayout) {
        actionBarLayout = layout
        guard layout.countCapsule != .zero, layout.buttonGroup != .zero else { return }

        let minX = layout.countCapsule.maxX + Self.dragInset
        let maxX = layout.buttonGroup.minX - Self.dragInset
        guard maxX > minX else {
            dragArea = .zero
            dragView.frame = .zero
            DebugLog.log("panelActionBar: no blank middle for the drag strip")
            return
        }
        dragArea = NSRect(
            x: minX,
            y: Self.dragRowInset,
            width: maxX - minX,
            height: Self.dragRowHeight
        )
        // The action row sits at the panel's top edge, so the top-left strip
        // converts to the container's bottom-left space directly.
        dragView.frame = NSRect(
            x: dragArea.minX,
            y: Self.size.height - dragArea.maxY,
            width: dragArea.width,
            height: dragArea.height
        )
        DebugLog.log(
            "panelActionBar count=\(NSStringFromRect(layout.countCapsule)) "
                + "buttons=\(NSStringFromRect(layout.buttonGroup)) "
                + "drag=\(NSStringFromRect(dragArea)) (top-left)"
        )
    }

    /// Reports what a click in the action row would actually hit: the drag
    /// strip's centre must be `PanelDragView`, and every sample in the button
    /// group must stay with the SwiftUI host.
    func debugHitTest() {
        guard let container = panel.contentView else {
            DebugLog.log("dragHitTest: no contentView")
            return
        }
        guard dragArea != .zero else {
            DebugLog.log("dragHitTest: drag strip not measured yet")
            return
        }
        DebugLog.log(
            "dragHitTest layout count=\(NSStringFromRect(actionBarLayout.countCapsule)) "
                + "buttons=\(NSStringFromRect(actionBarLayout.buttonGroup)) "
                + "drag=\(NSStringFromRect(dragArea)) (top-left)"
        )

        logHit(
            "drag centre",
            in: container,
            at: viewPoint(x: dragArea.midX, y: dragArea.midY)
        )
        logHit(
            "count capsule",
            in: container,
            at: viewPoint(
                x: actionBarLayout.countCapsule.midX,
                y: actionBarLayout.countCapsule.midY
            )
        )
        // Four equal slices of the button group; each slice centre lands inside
        // one of the four buttons (gaps are narrower than half a button).
        for index in 0..<4 {
            let fraction = (CGFloat(index) + 0.5) / 4
            let point = viewPoint(
                x: actionBarLayout.buttonGroup.minX + actionBarLayout.buttonGroup.width * fraction,
                y: actionBarLayout.buttonGroup.midY
            )
            logHit("button \(index + 1)", in: container, at: point)
        }
    }

    /// Top-left action-row coordinates → the container's bottom-left space.
    private func viewPoint(x: CGFloat, y: CGFloat) -> NSPoint {
        NSPoint(x: x, y: Self.size.height - y)
    }

    private func logHit(_ label: String, in container: NSView, at point: NSPoint) {
        let hit = container.hitTest(point)
        DebugLog.log(
            "dragHitTest \(label) at=\(NSStringFromPoint(point)) "
                + "hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil")"
        )
    }

    var isVisible: Bool { panel.isVisible }
    var windowNumber: Int { panel.windowNumber }

    // MARK: - Presentation

    func toggle() {
        if panel.isVisible {
            hide(restoreFocus: true)
        } else {
            show()
        }
    }

    func show() {
        model.prepareForPresentation()
        positionAtPointer()
        // Taking focus is what makes the search field and ↑/↓ reliable; a
        // never-activating panel gets its key status revoked by the system.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        DebugLog.log("panel shown at \(NSStringFromRect(panel.frame))")
    }

    /// - Parameter restoreFocus: hand focus back to the app the user came from.
    ///   Pass `false` when the panel is closing *because* the user already
    ///   focused something else, otherwise we would steal it back.
    func hide(restoreFocus: Bool = false) {
        guard panel.isVisible else { return }
        quickLook.hide()
        removeKeyMonitor()
        panel.orderOut(nil)
        DebugLog.log("panel hidden (restoreFocus: \(restoreFocus))")

        guard restoreFocus, NSApp.isActive else { return }
        if let target = model.lastExternalApp, !target.isTerminated {
            target.activate()
        }
    }

    /// The 钉住 rule, pure so the self test can assert it without a window.
    static func hidesOnResignKey(panelPinned: Bool) -> Bool { !panelPinned }

    @objc private func panelResignedKey() {
        // 钉住面板: while pinned, switching apps (or clicking another window)
        // must leave the panel on screen. Esc still hides it.
        guard Self.hidesOnResignKey(panelPinned: model.panelPinned) else {
            DebugLog.log("panel kept open (pinned)")
            return
        }
        hide(restoreFocus: false)
    }

    // MARK: - Positioning

    /// Places the panel at the pointer, on the screen that pointer is on.
    ///
    /// The panel is centred on the pointer and then clamped to that screen's
    /// `visibleFrame`, so the menu bar and Dock stay clear and the panel is
    /// always fully visible — including when the pointer is in a corner or on
    /// a secondary display with its own frame.
    private func positionAtPointer() {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        else { return }

        let size = panel.frame.size
        let origin = PanelPlacement.origin(
            pointer: pointer,
            size: size,
            visibleFrame: screen.visibleFrame
        )
        panel.setFrameOrigin(origin)
        DebugLog.log(
            "panel positioned pointer=\(NSStringFromPoint(pointer)) "
                + "screen=\(NSStringFromRect(screen.frame)) "
                + "visible=\(NSStringFromRect(screen.visibleFrame)) "
                + "frame=\(NSStringFromRect(panel.frame))"
        )
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        // A local monitor sees events before they reach the window, which lets
        // ↑/↓ drive the list even while the search field has focus.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Wraps `process` so an open preview follows the selection, including when
    /// the selection moves because the user kept typing in the search field.
    private func handle(_ event: NSEvent) -> Bool {
        let previous = model.selectedItem?.id
        let consumed = process(event)
        if quickLook.isVisible, model.selectedItem?.id != previous, let item = model.selectedItem {
            quickLook.show(for: item, beside: panel.frame)
        }
        return consumed
    }

    private func process(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case kVK_Escape:
            if quickLook.isVisible {
                quickLook.hide()
            } else {
                hide(restoreFocus: true)
            }
            return true

        case kVK_UpArrow:
            model.moveSelection(by: -1)
            return true

        case kVK_DownArrow:
            model.moveSelection(by: 1)
            return true

        case kVK_Return, kVK_ANSI_KeypadEnter:
            model.activateSelected()
            return true

        case kVK_Space:
            // A space is a meaningful character in a search query, so only
            // claim it when there is nothing being typed.
            if isEditingText, !model.searchText.isEmpty { return false }
            togglePreview()
            return true

        case kVK_ANSI_P:
            guard event.modifierFlags.contains(.command) else { return false }
            if event.modifierFlags.contains(.shift) {
                pinHoveredOrSelected()
            } else {
                pinSelected()
            }
            return true

        default:
            return handleNumberKey(event)
        }
    }

    /// `1`…`9` copy the row at that position, exactly like clicking it.
    ///
    /// The panel is short-lived, so digits are a shortcut rather than text — but
    /// a query being typed must never lose characters. Same rule as Space above:
    /// while the search field is in use, only claim the key when the query is
    /// still empty, so "1" as the first character of a search still works after
    /// the user presses a non-digit key.
    /// With ⌘ held the row is copied **and** pasted into the app the user came
    /// from; without it the row is only copied, exactly as before.
    private func handleNumberKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let commandOnly = modifiers.subtracting([.command, .shift]).isEmpty
            && modifiers.contains(.command)
        guard (commandOnly || modifiers.isDisjoint(with: [.command, .option, .control])),
              let character = event.charactersIgnoringModifiers?.first,
              let number = Int(String(character)),
              (1...9).contains(number)
        else { return false }

        if isEditingText, !model.searchText.isEmpty { return false }

        let index = number - 1
        // Past the end of the list: swallow the key so it does not quietly turn
        // into the first character of a search query, but take no action.
        guard model.filteredItems.indices.contains(index) else { return true }

        let item = model.filteredItems[index]
        if commandOnly {
            model.copy(item, paste: true)
        } else {
            model.activate(item)
        }
        return true
    }

    /// True while the search field owns the keyboard (AppKit field editor).
    private var isEditingText: Bool {
        panel.firstResponder is NSTextView
    }

    private func togglePreview() {
        if quickLook.isVisible {
            quickLook.hide()
        } else if let item = model.selectedItem {
            quickLook.show(for: item, beside: panel.frame)
        }
    }

    /// ⌘P: pin the selected row.
    private func pinSelected() {
        guard let item = model.selectedItem, item.hasImage else { return }
        pin(item)
    }

    /// ⌘⇧P: pin the row under the pointer; when the pointer is not over the
    /// list (search field, empty space, outside the panel) fall back to the
    /// selected row. The hovered id is looked up in the *current* filtered list
    /// so a row that got filtered away cannot be pinned stale.
    ///
    /// Callable from the global ⌘⇧P handler as well as the panel's local key
    /// monitor: Carbon consumes the key before the monitor when the panel is
    /// key, so both routes share this method. The short guard keeps a single
    /// key press from pinning twice if both routes ever see it.
    func pinHoveredOrSelected() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPinShortcutTime > 0.25 else { return }
        lastPinShortcutTime = now

        let hovered = hoveredRowItemID.flatMap { id in
            model.filteredItems.first { $0.id == id }
        }
        guard let item = hovered ?? model.selectedItem, item.hasImage else { return }
        DebugLog.log(
            "pinHoveredOrSelected: hovered=\(hoveredRowItemID.map(String.init) ?? "nil") "
                + "target=\(item.id) selected=\(model.selectedItem?.id ?? -1)"
        )
        pin(item)
    }

    private func pin(_ item: ClipItem) {
        model.pinToScreen(item)
        hide(restoreFocus: true)
    }
}

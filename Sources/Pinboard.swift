import AppKit
import Observation
import SwiftUI

/// Geometry + state of one image pinned onto the screen. Persisted as JSON.
struct PinnedImage: Identifiable, Codable, Sendable, Equatable {
    var id: UUID = UUID()
    /// Row in the history database, or `-1` for a pin saved by an older build
    /// that kept its own copy in the pins folder instead.
    var itemID: Int64
    /// File name inside the pins folder. Only set on those legacy records;
    /// current pins always point at a history row.
    var fileName: String?
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var opacity: Double = 1
    var isVisible: Bool = true

    var frame: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set {
            x = newValue.origin.x
            y = newValue.origin.y
            width = newValue.size.width
            height = newValue.size.height
        }
    }
}

/// The opacity ladder of a pinned image, in one place.
///
/// The hover toolbar's `%` chip, its 不透明度 popover and the ⌘+wheel gesture
/// all read this: the popover lists exactly `choices`, and the gesture clamps
/// to `range`, so the number the chip shows can never leave the range the menu
/// offers (20 %–100 %).
enum PinOpacity {
    /// Highest first — the order the popover and the context menu list.
    static let choices: [Double] = [1.0, 0.8, 0.6, 0.4, 0.2]
    static let range: ClosedRange<Double> = 0.2...1.0
    /// One point of wheel travel. `PinnedImagePanel` normalises a line-based
    /// wheel delta into points, so 1 % per point scrubs 100 % → 20 % in one
    /// short two-finger swipe without jumping on the first event.
    static let scrollStepPerPoint: Double = 0.01

    static func clamped(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// The value the chip renders: integer percent, never "0 %" for a pin that
    /// is still on screen.
    static func percent(_ value: Double) -> Int {
        Int((clamped(value) * 100).rounded())
    }

    /// One wheel event's worth of change, clamped into the range.
    static func value(from current: Double, scrollingBy points: CGFloat) -> Double {
        clamped(current + Double(points) * scrollStepPerPoint)
    }
}

/// Live state of one pinned panel, observed by the view hosted inside it.
///
/// The panel's `rootView` is built once, so passing `frame`/`opacity` into the
/// view as plain `let`s froze the toolbar: a scroll-zoom changed the window but
/// never redrew the chips. Geometry and opacity are written here instead, and
/// the SwiftUI view reads them, so the toolbar follows a continuous gesture
/// without rebuilding the view tree on every scroll tick.
@MainActor
@Observable
final class PinPanelState {
    /// Size on screen, in points. `PinnedImageView` divides it by the image's
    /// natural size to show the zoom percentage.
    var displaySize: CGSize
    var opacity: Double

    init(displaySize: CGSize, opacity: Double) {
        self.displaySize = displaySize
        self.opacity = opacity
    }
}

/// Panel that floats above everything and accepts scroll-to-zoom / ⌘-scroll
/// for opacity, plus esc.
final class PinnedImagePanel: NSPanel {
    /// Plain wheel: zoom. Receives points of travel.
    var onScrollZoom: ((CGFloat) -> Void)?
    /// ⌘ + wheel: opacity. Receives points of travel, same sign as the zoom.
    var onScrollOpacity: ((CGFloat) -> Void)?
    var onEscape: (() -> Void)?
    /// 指针反转, read at event time rather than copied when the panel is built.
    ///
    /// A pin created while the setting was off must still flip when the user
    /// turns it on with the pin already on screen — so this is a closure over
    /// the live settings, not a `Bool` snapshot.
    var isScrollInverted: (() -> Bool)?
    /// 设置 → 通用 → 钉图 → ⌘ + 滚轮调整钉图不透明度. Read at event time for the
    /// same reason as `isScrollInverted`: toggling it must reach a pin that is
    /// already on screen without rebuilding the panel.
    var isCommandScrollOpacityEnabled: (() -> Bool)?
    /// 设置 → 通用 → 钉图 → 滚轮缩放钉图.
    ///
    /// Also read at event time, so turning it off makes the wheel inert on a
    /// pin that is *already* on screen. `nil` means "no preference object"
    /// (test harnesses that drive the panel without settings) and keeps the
    /// historical zoom behaviour.
    var isScrollZoomEnabled: (() -> Bool)?
    /// Owned by the panel so its lifetime matches the window's; the hosted view
    /// keeps a reference and re-renders when this changes.
    var pinState: PinPanelState?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Press point of the current left-button gesture, in screen coordinates.
    private var dragStart: NSPoint?
    /// The mouse-down we are holding back until we know whether this is a click
    /// or a drag. See `sendEvent`.
    private var pendingMouseDown: NSEvent?
    /// Once the pointer travels this far the gesture is a window drag.
    private static let dragThreshold: CGFloat = 3

    /// Whole-window dragging with a real click/drag distinction.
    ///
    /// The SwiftUI image fills the borderless panel, so neither
    /// `isMovableByWindowBackground` nor a SwiftUI `DragGesture` reliably gets
    /// the drag (the hosting view keeps the mouse). Handling it at the window
    /// is the only layer that sees every press no matter what is under the
    /// pointer:
    ///
    /// * mouse-down is *held*, not forwarded;
    /// * movement under 3 pt is ignored, so a click stays a click;
    /// * movement of 3 pt or more starts an AppKit window drag — no clamping,
    ///   so a pin can cross a screen edge or move to another display;
    /// * a mouse-up with no drag replays the held pair, which is how buttons,
    ///   the opacity/zoom chips, the context menu and double-click-to-close
    ///   keep receiving normal clicks.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            dragStart = NSEvent.mouseLocation
            pendingMouseDown = event
            return

        case .leftMouseDragged:
            guard let start = dragStart, pendingMouseDown != nil else {
                super.sendEvent(event)
                return
            }
            let point = NSEvent.mouseLocation
            let distance = hypot(point.x - start.x, point.y - start.y)
            guard distance >= Self.dragThreshold else { return }
            dragStart = nil
            pendingMouseDown = nil
            // `performDrag` runs its own loop until mouse-up. Passing the
            // current dragged event (not the held mouse-down) means the first
            // 3 pt past the threshold do not move the window.
            performDrag(with: event)
            return

        case .leftMouseUp:
            if let down = pendingMouseDown {
                // A plain click: deliver the pair now, exactly once.
                super.sendEvent(down)
                super.sendEvent(event)
            }
            dragStart = nil
            pendingMouseDown = nil
            return

        default:
            super.sendEvent(event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // Both gestures work in points: a line-based wheel notch is three
        // points, matching what the zoom's `1 + delta * 0.01` already assumes.
        let raw = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 3
        // 指针反转 flips the wheel here, before either gesture's maths, so the
        // zoom limits, the percentage chips and the opacity ladder all keep
        // working on an ordinary delta.
        let delta = isScrollInverted?() == true ? -raw : raw
        guard delta != 0 else { return }
        // ⌘ takes the wheel for opacity and hands it back the moment the
        // modifier is released — the check happens per event, not per gesture.
        // It comes first so the opacity gesture keeps working even when the
        // plain zoom gesture has been switched off.
        if event.modifierFlags.contains(.command),
           isCommandScrollOpacityEnabled?() == true {
            onScrollOpacity?(delta)
            return
        }
        // 设置 → 通用 → 钉图 → 滚轮缩放钉图: off makes a plain wheel inert on a
        // pin. The event is consumed (not passed to `super`) because a pin has
        // nothing else to scroll; passing it on would let an ancestor scroll
        // view move the pin out from under the pointer.
        guard isScrollZoomEnabled?() != false else { return }
        onScrollZoom?(delta)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // esc
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}

/// Owns every pinned image: creation, geometry, persistence.
@MainActor
@Observable
final class Pinboard {
    private static let storageKey = "pinnedImages"
    private static let minSide: CGFloat = 48
    private static let maxSide: CGFloat = 4000

    private(set) var pins: [PinnedImage] = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var panels: [UUID: PinnedImagePanel] = [:]
    @ObservationIgnored private var moveTokens: [UUID: NSObjectProtocol] = [:]
    @ObservationIgnored private var persistWork: DispatchWorkItem?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([PinnedImage].self, from: data) {
            pins = decoded
        }
    }

    /// Called once by `AppModel` so pins can resolve image bytes and so that
    /// pins persisted from a previous launch come back.
    func attach(model: AppModel) {
        self.model = model
        restorePanels()
    }

    var count: Int { pins.count }

    static var pinsDirectory: URL {
        AppModel.resolveStorageDirectory().appendingPathComponent("pins", isDirectory: true)
    }

    // MARK: - Creating

    /// Resolve the bytes behind a pin, whichever storage it uses: either the
    /// pins folder (legacy pins) or the history database (⌘P pins).
    func imageData(for record: PinnedImage) -> Data? {
        if let fileName = record.fileName {
            return try? Data(contentsOf: Self.pinsDirectory.appendingPathComponent(fileName))
        }
        guard record.itemID > 0 else { return nil }
        return model?.imageData(forItemID: record.itemID)
    }

    @discardableResult
    func pin(_ item: ClipItem) -> Bool {
        guard item.hasImage, let data = model?.fullImage(for: item), let image = NSImage(data: data) else {
            return false
        }
        // Keep the source row from being aged out while it is on screen.
        model?.protectFromTrimming(item)

        let size = Self.initialSize(for: image)
        let origin = nextOrigin(for: size)
        var record = PinnedImage(itemID: item.id, x: 0, y: 0, width: 0, height: 0)
        record.frame = CGRect(origin: origin, size: size)

        pins.append(record)
        persist()
        makePanel(for: record, image: image, show: true)
        DebugLog.log("pinned image for item \(item.id), \(pins.count) pin(s) total")
        return true
    }

    /// Pin a freshly captured screenshot. Captures have no history row yet,
    /// so they use the legacy `fileName` storage: the PNG lives in the pins
    /// folder and the record points at it.
    @discardableResult
    func pinImage(_ image: NSImage, preferredFrame: CGRect? = nil) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let png = representation.representation(using: .png, properties: [:]) else {
            return false
        }

        let directory = Self.pinsDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            DebugLog.log("pinImage: cannot create pins directory: \(error.localizedDescription)")
            return false
        }

        let fileName = "capture-\(UUID().uuidString).png"
        do {
            try png.write(to: directory.appendingPathComponent(fileName))
        } catch {
            DebugLog.log("pinImage: cannot write image: \(error.localizedDescription)")
            return false
        }

        let size = preferredFrame?.size ?? Self.initialSize(for: image)
        let origin = preferredFrame?.origin ?? nextOrigin(for: size)
        var record = PinnedImage(itemID: -1, fileName: fileName, x: 0, y: 0, width: 0, height: 0)
        record.frame = CGRect(origin: origin, size: size)

        pins.append(record)
        persist()
        makePanel(for: record, image: image, show: true)
        DebugLog.log("pinned captured image \(fileName), \(pins.count) pin(s) total")
        return true
    }

    private static func initialSize(for image: NSImage) -> CGSize {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return CGSize(width: 240, height: 240) }
        let longest = max(size.width, size.height)
        let target: CGFloat = longest > 480 ? 360 : longest
        let ratio = target / longest
        return CGSize(width: max(48, size.width * ratio), height: max(48, size.height * ratio))
    }

    private func nextOrigin(for size: CGSize) -> CGPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        // Cascade so repeated pins do not land exactly on top of each other.
        let offset = CGFloat(pins.count % 8) * 26
        var origin = CGPoint(
            x: mouse.x - size.width / 2 + offset,
            y: mouse.y - size.height / 2 - offset
        )
        origin.x = min(max(origin.x, visible.minX + 8), max(visible.minX + 8, visible.maxX - size.width - 8))
        origin.y = min(max(origin.y, visible.minY + 8), max(visible.minY + 8, visible.maxY - size.height - 8))
        return origin
    }

    // MARK: - Panels

    private func restorePanels() {
        var dropped: [UUID] = []
        for record in pins {
            guard let data = imageData(for: record),
                  let image = NSImage(data: data) else {
                dropped.append(record.id)  // source entry was deleted or expired
                continue
            }
            makePanel(for: record, image: image, show: record.isVisible)
        }
        if !dropped.isEmpty {
            pins.removeAll { dropped.contains($0.id) }
            persist()
            DebugLog.log("dropped \(dropped.count) pin(s) whose source entry is gone")
        }
    }

    private func makePanel(for record: PinnedImage, image: NSImage, show: Bool) {
        let panel = PinnedImagePanel(
            contentRect: record.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // The SwiftUI host covers the whole panel, so AppKit's background drag
        // never fires here. `PinnedImageView` owns an explicit 3 pt-threshold
        // drag instead; leaving this on as well would give two competing drag
        // sources and could start a move on a plain click.
        panel.isMovableByWindowBackground = false
        panel.isMovable = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.alphaValue = record.opacity

        let id = record.id
        let state = PinPanelState(displaySize: record.frame.size, opacity: record.opacity)
        panel.pinState = state
        Self.installWheelGestures(
            on: panel,
            settings: model?.settings,
            zoom: { [weak self] delta in self?.zoom(id, by: delta) },
            opacity: { [weak self] delta in self?.adjustOpacity(id, by: delta) }
        )
        panel.onEscape = { [weak self] in self?.unpin(id) }
        panel.contentView = NSHostingView(rootView: PinnedImageView(
            image: image,
            state: state,
            onClose: { [weak self] in self?.unpin(id) },
            onCopy: { [weak self] in self?.copyToPasteboard(id) },
            onSave: { [weak self] in self?.saveToFile(id) },
            onOpacity: { [weak self] value in self?.setOpacity(id, value) },
            onFitToActualSize: { [weak self] in self?.resetToActualSize(id) }
        ))

        panels[id] = panel
        observeMove(of: panel, id: id)

        if show { panel.orderFront(nil) }
        DebugLog.log("pin panel \(id) frame=\(NSStringFromRect(record.frame))")
    }

    /// The one place a pin's wheel is wired to its gestures.
    ///
    /// Kept out of `makePanel` so the self-test can drive a real
    /// `PinnedImagePanel` with a real scrolling event: it proves that
    /// 指针反转 reaches the zoom delta, that ⌘ hands the wheel to opacity,
    /// that 滚轮缩放钉图 gates the plain wheel, and that flipping any of these
    /// settings also changes a pin that is already on screen (the closures read
    /// the live preferences, so no rebuild is needed).
    static func installWheelGestures(
        on panel: PinnedImagePanel,
        settings: AppSettings?,
        zoom: @escaping (CGFloat) -> Void,
        opacity: @escaping (CGFloat) -> Void
    ) {
        panel.isScrollInverted = { [weak settings] in settings?.pinScrollInverted ?? false }
        panel.isCommandScrollOpacityEnabled = { [weak settings] in
            settings?.pinCommandScrollOpacity ?? false
        }
        panel.isScrollZoomEnabled = { [weak settings] in settings?.pinScrollZoom ?? true }
        panel.onScrollZoom = zoom
        panel.onScrollOpacity = opacity
    }

    private func observeMove(of panel: NSWindow, id: UUID) {
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panels[id] else { return }
                self.updateRecord(id: id) { $0.frame = panel.frame }
            }
        }
        moveTokens[id] = token
    }

    private func updateRecord(id: UUID, _ mutate: (inout PinnedImage) -> Void) {
        guard let index = pins.firstIndex(where: { $0.id == id }) else { return }
        mutate(&pins[index])
        schedulePersist()
    }

    private func schedulePersist() {
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.persist() }
        }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(pins) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    // MARK: - Mutating

    func unpin(_ id: UUID) {
        if let token = moveTokens.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(token)
        }
        if let panel = panels.removeValue(forKey: id) {
            panel.orderOut(nil)
        }
        // Captures keep their bytes in the pins folder; drop them with the pin.
        if let record = pins.first(where: { $0.id == id }),
           record.itemID <= 0,
           let fileName = record.fileName {
            try? FileManager.default.removeItem(
                at: Self.pinsDirectory.appendingPathComponent(fileName)
            )
        }
        pins.removeAll { $0.id == id }
        persist()
    }

    func unpinAll() {
        for id in pins.map(\.id) { unpin(id) }
    }

    func setVisible(_ id: UUID, _ visible: Bool) {
        guard let panel = panels[id] else { return }
        if visible {
            panel.orderFront(nil)
        } else {
            panel.orderOut(nil)
        }
        updateRecord(id: id) { $0.isVisible = visible }
    }

    /// One opacity value, clamped to the same 20 %–100 % range the toolbar's
    /// 不透明度 menu offers. The panel's alpha and the chip's `%` are written
    /// together so the number on screen is always the number being shown.
    func setOpacity(_ id: UUID, _ value: Double) {
        let clamped = PinOpacity.clamped(value)
        panels[id]?.alphaValue = clamped
        panels[id]?.pinState?.opacity = clamped
        updateRecord(id: id) { $0.opacity = clamped }
    }

    /// ⌘ + wheel on a pin. `delta` is points of wheel travel in the same
    /// direction as the zoom gesture: scrolling up raises the opacity. The
    /// hover toolbar reads `pinState.opacity` from `body`, so the `%` chip
    /// follows the gesture live — no rebuild of the SwiftUI tree.
    func adjustOpacity(_ id: UUID, by delta: CGFloat) {
        guard let panel = panels[id] else { return }
        let current = panel.pinState?.opacity
            ?? pins.first(where: { $0.id == id })?.opacity
            ?? 1
        setOpacity(id, PinOpacity.value(from: current, scrollingBy: delta))
        DebugLog.log(
            "pin opacity: \(id) \(Int((current * 100).rounded()))% → "
                + "\(PinOpacity.percent(PinOpacity.value(from: current, scrollingBy: delta)))%"
        )
    }

    func zoom(_ id: UUID, by delta: CGFloat) {
        guard let panel = panels[id],
              let record = pins.first(where: { $0.id == id }) else { return }

        let factor = 1 + delta * 0.01
        let newWidth = min(max(record.width * factor, Self.minSide), Self.maxSide)
        let ratio = newWidth / record.width
        let newHeight = record.height * ratio
        let centre = CGPoint(x: record.frame.midX, y: record.frame.midY)
        let frame = CGRect(
            x: centre.x - newWidth / 2,
            y: centre.y - newHeight / 2,
            width: newWidth,
            height: newHeight
        )
        panel.setFrame(frame, display: true)
        panel.pinState?.displaySize = frame.size
        updateRecord(id: id) { $0.frame = frame }
    }

    /// Back to the image's own size — which is also what the toolbar's zoom
    /// chip calls 100%, so the number and this button can never disagree.
    func resetToActualSize(_ id: UUID) {
        guard let panel = panels[id],
              let record = pins.first(where: { $0.id == id }),
              let data = imageData(for: record),
              let image = NSImage(data: data) else { return }
        let size = image.size
        let centre = CGPoint(x: record.frame.midX, y: record.frame.midY)
        let frame = CGRect(
            x: centre.x - size.width / 2,
            y: centre.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: true)
        panel.pinState?.displaySize = frame.size
        updateRecord(id: id) { $0.frame = frame }
    }

    func bringAllToFront() {
        for panel in panels.values where panel.isVisible {
            panel.orderFront(nil)
        }
    }

    /// Test seam: the production panel for a pin, so the harness can send a
    /// real wheel event through the same wiring the app uses.
    func panelForTesting(_ id: UUID) -> PinnedImagePanel? { panels[id] }

    // MARK: - Actions

    private func copyToPasteboard(_ id: UUID) {
        guard let record = pins.first(where: { $0.id == id }),
              let data = imageData(for: record),
              let image = NSImage(data: data) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        model?.syncMonitorChangeCount()
    }

    private func saveToFile(_ id: UUID) {
        guard let record = pins.first(where: { $0.id == id }),
              let data = imageData(for: record) else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "钉图-\(fileNameTimestamp()).png"
        panel.allowedContentTypes = [.png]
        // 设置 → 通用 → 保存位置 is the folder "save as" starts in.
        if let directory = model?.settings.captureDirectory,
           FileManager.default.fileExists(atPath: directory.path) {
            panel.directoryURL = directory
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }
}

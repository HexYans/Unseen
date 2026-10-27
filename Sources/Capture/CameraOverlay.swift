import AppKit
import AVFoundation
import CoreGraphics

/// Camera permission as the UI and the self test see it.
///
/// Access is only requested from an explicit user action (the menu item, the
/// recording auto-start with the setting on, or the settings button). A denied
/// permission therefore never produces a modal alert and never re-prompts.
enum CameraPermission: String, Sendable, Equatable {
    case notDetermined
    case denied
    case restricted
    case authorized

    var isAuthorized: Bool { self == .authorized }

    var title: String {
        switch self {
        case .authorized: "已授权"
        case .notDetermined: "尚未请求"
        case .denied: "未授权"
        case .restricted: "系统限制"
        }
    }

    var subtitle: String {
        switch self {
        case .authorized: "可以把摄像头画面作为录屏画中画"
        case .notDetermined: "第一次开启时会请求系统权限"
        case .denied: "去 系统设置 → 隐私与安全性 → 摄像头 打开授权"
        case .restricted: "此设备或账号被限制使用摄像头"
        }
    }

    static var current: CameraPermission {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    /// Shows the system prompt on the first call only; afterwards it just
    /// reports the standing decision.
    static func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .video) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    static func openSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        )
        if let url {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Which corner the floating camera sits in. Directions are screen directions,
/// independent of AppKit's bottom-left coordinates.
enum CameraPosition: String, CaseIterable, Identifiable, Sendable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topLeft: "左上"
        case .topRight: "右上"
        case .bottomLeft: "左下"
        case .bottomRight: "右下"
        }
    }
}

/// The three offered camera sizes, kept 4:3 so the preview never stretches.
enum CameraSize: String, CaseIterable, Identifiable, Sendable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: "小"
        case .medium: "中"
        case .large: "大"
        }
    }

    var size: CGSize {
        switch self {
        case .small: CGSize(width: 160, height: 120)
        case .medium: CGSize(width: 240, height: 180)
        case .large: CGSize(width: 320, height: 240)
        }
    }
}

/// Pure placement arithmetic, so the self test can assert every corner and the
/// clamping behaviour without a screen or a camera.
enum CameraPlacement {
    static let margin: CGFloat = 24

    /// The panel frame for a screen. The requested size is first reduced to
    /// the screen's own size (a 320 × 240 camera cannot be larger than a tiny
    /// display), then the origin is clamped so the whole panel stays visible.
    static func frame(
        size: CGSize,
        screenFrame: CGRect,
        position: CameraPosition,
        margin: CGFloat = CameraPlacement.margin
    ) -> CGRect {
        let width = max(1, min(max(size.width, 1), screenFrame.width))
        let height = max(1, min(max(size.height, 1), screenFrame.height))

        var x: CGFloat
        var y: CGFloat
        switch position {
        case .topLeft:
            x = screenFrame.minX + margin
            y = screenFrame.maxY - height - margin
        case .topRight:
            x = screenFrame.maxX - width - margin
            y = screenFrame.maxY - height - margin
        case .bottomLeft:
            x = screenFrame.minX + margin
            y = screenFrame.minY + margin
        case .bottomRight:
            x = screenFrame.maxX - width - margin
            y = screenFrame.minY + margin
        }

        // Clamp into the screen even when the margin does not fit (small
        // displays, or a screen frame with an unusual origin).
        let maxX = max(screenFrame.minX, screenFrame.maxX - width)
        let maxY = max(screenFrame.minY, screenFrame.maxY - height)
        x = min(max(x, screenFrame.minX), maxX)
        y = min(max(y, screenFrame.minY), maxY)

        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// The windows that must stay **out** of screenshots and **inside** recordings.
///
/// `ScreenRecorder` subtracts this set from the process's own windows when it
/// builds `SCContentFilter`, so a camera that is already visible when recording
/// starts is not accidentally excluded with the HUDs.
@MainActor
enum CameraOverlayRegistry {
    private(set) static var activeWindowNumbers: Set<CGWindowID> = []

    static func register(_ windowNumber: Int) {
        guard windowNumber > 0 else { return }
        activeWindowNumbers.insert(CGWindowID(windowNumber))
    }

    static func unregister(_ windowNumber: Int) {
        guard windowNumber > 0 else { return }
        activeWindowNumbers.remove(CGWindowID(windowNumber))
    }
}

/// Non-activating floating panel. It never takes key focus away from the app
/// being recorded; dragging is handled by `CameraPreviewView`.
final class CameraOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A session handle that can cross the serial queue boundary. The queue is the
/// only place `startRunning` / `stopRunning` are called.
private final class CameraSessionBox: @unchecked Sendable {
    let session: AVCaptureSession
    init(_ session: AVCaptureSession) { self.session = session }
}

/// The rounded camera preview: live `AVCaptureVideoPreviewLayer`, a resize grip
/// in the bottom-right corner, and drag-to-move anywhere else.
@MainActor
final class CameraPreviewView: NSView {
    static let cornerRadius: CGFloat = 16
    static let gripSide: CGFloat = 22
    static let minimumWidth: CGFloat = 120

    private let previewLayer: AVCaptureVideoPreviewLayer?
    private let borderLayer = CAShapeLayer()
    private let gripLayer = CAShapeLayer()
    private var resizeStartFrame: CGRect?
    private var resizeStartMouse: NSPoint?

    /// Called once a resize drag ends, with the new point size.
    var onResized: ((CGSize) -> Void)?

    init(frame frameRect: NSRect, session: AVCaptureSession?) {
        if let session {
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            previewLayer = layer
        } else {
            previewLayer = nil
        }
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true

        if let previewLayer {
            layer?.addSublayer(previewLayer)
        }

        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.white.withAlphaComponent(0.24).cgColor
        borderLayer.lineWidth = 1
        layer?.addSublayer(borderLayer)

        gripLayer.fillColor = nil
        gripLayer.strokeColor = NSColor.white.withAlphaComponent(0.55).cgColor
        gripLayer.lineWidth = 1.4
        gripLayer.lineCap = .round
        layer?.addSublayer(gripLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
        borderLayer.frame = bounds
        borderLayer.path = CGPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: Self.cornerRadius,
            cornerHeight: Self.cornerRadius,
            transform: nil
        )
        gripLayer.frame = bounds
        gripLayer.path = gripPath()
    }

    private func gripPath() -> CGPath {
        let path = CGMutablePath()
        let inset: CGFloat = 6
        let side = Self.gripSide - 4
        let maxX = bounds.maxX - inset
        let minY = bounds.minY + inset
        // Three nested corner marks: the conventional resize affordance.
        for step in 0..<3 {
            let offset = CGFloat(step) * 5
            path.move(to: CGPoint(x: maxX - side + offset, y: minY))
            path.addLine(to: CGPoint(x: maxX, y: minY + side - offset))
        }
        return path
    }

    // MARK: - Mouse

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    private func isInResizeGrip(_ point: NSPoint) -> Bool {
        let grip = NSRect(
            x: bounds.maxX - Self.gripSide,
            y: bounds.minY,
            width: Self.gripSide,
            height: Self.gripSide
        )
        return grip.contains(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isInResizeGrip(point) {
            resizeStartFrame = window?.frame
            resizeStartMouse = NSEvent.mouseLocation
        } else {
            window?.performDrag(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startFrame = resizeStartFrame,
              let startMouse = resizeStartMouse,
              let window else { return }

        let current = NSEvent.mouseLocation
        // Width drives the resize; 4:3 is preserved and the top-left stays put.
        let dx = current.x - startMouse.x
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1_440, height: 900)

        let maxWidth = min(max(screen.width, Self.minimumWidth), 640)
        let width = min(max(startFrame.width + dx, Self.minimumWidth), maxWidth)
        let height = width * 0.75
        guard height <= screen.height else { return }

        // The grip is bottom-right, so the top-left stays put.
        let origin = CGPoint(x: startFrame.minX, y: startFrame.maxY - height)
        window.setFrame(
            CGRect(x: origin.x, y: origin.y, width: width, height: height),
            display: true
        )
        needsLayout = true
    }

    override func mouseUp(with event: NSEvent) {
        if resizeStartFrame != nil, let window {
            onResized?(window.frame.size)
        }
        resizeStartFrame = nil
        resizeStartMouse = nil
    }
}

/// Owns one camera preview window and its `AVCaptureSession`.
///
/// Lifecycle: configure → show the panel (registers screenshot exclusion and
/// the recording-inclusion registry) → start the session off the main thread.
/// `stop` reverses all of it and is safe to call twice.
@MainActor
final class CameraOverlayController: NSObject {
    private let permissionOverride: CameraPermission?
    private let allowsPermissionRequest: Bool
    private let sessionQueue = DispatchQueue(label: "com.hexyans.unseen.camera")

    private(set) var permission: CameraPermission
    private(set) var lastFailureReason: String?
    private(set) var session: AVCaptureSession?
    private(set) var panel: CameraOverlayPanel?
    private(set) var didRequestPermission = false
    private(set) var isActive = false

    /// Where the panel currently is, in screen points.
    var frame: CGRect { panel?.frame ?? .zero }
    var isSessionRunning: Bool { session?.isRunning ?? false }

    init(permissionOverride: CameraPermission? = nil, allowsPermissionRequest: Bool = true) {
        self.permissionOverride = permissionOverride
        self.allowsPermissionRequest = allowsPermissionRequest
        self.permission = permissionOverride ?? CameraPermission.current
        super.init()
    }

    /// Start the camera and show the floating preview.
    ///
    /// Returns `false` without crashing, showing an alert, or asking again when
    /// permission is missing or there is no usable camera.
    @discardableResult
    func start(position: CameraPosition, size: CameraSize, screenFrame: CGRect) -> Bool {
        if isActive, panel != nil { return true }

        switch permission {
        case .authorized:
            break
        case .notDetermined:
            lastFailureReason = "还没有摄像头权限。到「设置 → 通用 → 摄像头画中画」授权后再试。"
            if allowsPermissionRequest, permissionOverride == nil, !didRequestPermission {
                didRequestPermission = true
                Task { @MainActor [weak self] in
                    let granted = await CameraPermission.requestAccess()
                    self?.permission = granted ? .authorized : CameraPermission.current
                    DebugLog.log("camera: permission prompt result granted=\(granted)")
                }
            }
            DebugLog.log("camera: start refused, permission=\(permission.rawValue)")
            return false
        case .denied:
            lastFailureReason = "摄像头权限未授权。去 系统设置 → 隐私与安全性 → 摄像头 打勾后再试。"
            DebugLog.log("camera: start refused, permission=denied")
            return false
        case .restricted:
            lastFailureReason = "系统限制使用摄像头，无法开启画中画。"
            DebugLog.log("camera: start refused, permission=restricted")
            return false
        }

        guard let device = AVCaptureDevice.default(for: .video) else {
            lastFailureReason = "没有找到可用的摄像头。"
            DebugLog.log("camera: no AVCaptureDevice for video")
            return false
        }

        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .medium
        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            lastFailureReason = "摄像头无法打开。"
            DebugLog.log("camera: could not add input for \(device.localizedName)")
            return false
        }
        session.addInput(input)
        session.commitConfiguration()

        self.session = session
        showPanel(session: session, position: position, size: size, screenFrame: screenFrame)
        isActive = true
        lastFailureReason = nil

        let box = CameraSessionBox(session)
        sessionQueue.async {
            box.session.startRunning()
        }
        DebugLog.log(
            "camera: started device=\(device.localizedName) "
            + "frame=\(NSStringFromRect(panel?.frame ?? .zero)) "
            + "windowNumber=\(panel?.windowNumber ?? 0)"
        )
        return true
    }

    /// Stop the session and close the panel. Idempotent.
    func stop() {
        if let session {
            let box = CameraSessionBox(session)
            sessionQueue.async {
                box.session.stopRunning()
            }
        }
        if let panel {
            let number = panel.windowNumber
            ScreenCapture.includeWindow(number)
            CameraOverlayRegistry.unregister(number)
            panel.orderOut(nil)
            panel.contentView = nil
            self.panel = nil
        }
        session = nil
        isActive = false
        DebugLog.log("camera: stopped")
    }

    /// Follow a settings change without restarting the camera stream.
    func updatePlacement(position: CameraPosition, size: CameraSize, screenFrame: CGRect) {
        guard let panel else { return }
        let frame = CameraPlacement.frame(size: size.size, screenFrame: screenFrame, position: position)
        panel.setFrame(frame, display: true)
    }

    // MARK: - Test hooks

    /// Build and show the panel **without** a capture session, using the exact
    /// production path for placement, window level and ScreenCapture exclusion.
    /// Returns the panel frame. Used by the self test when no camera permission
    /// (and no hardware) is available.
    @discardableResult
    func presentPanelForTesting(
        screenFrame: CGRect,
        position: CameraPosition = .bottomRight,
        size: CameraSize = .medium
    ) -> CGRect {
        showPanel(session: nil, position: position, size: size, screenFrame: screenFrame)
        return panel?.frame ?? .zero
    }

    // MARK: - Panel

    private func showPanel(
        session: AVCaptureSession?,
        position: CameraPosition,
        size: CameraSize,
        screenFrame: CGRect
    ) {
        // One panel per controller; a second start replaces the old one.
        if let panel {
            ScreenCapture.includeWindow(panel.windowNumber)
            CameraOverlayRegistry.unregister(panel.windowNumber)
            panel.orderOut(nil)
            panel.contentView = nil
            self.panel = nil
        }

        let frame = CameraPlacement.frame(
            size: size.size,
            screenFrame: screenFrame,
            position: position
        )
        let panel = CameraOverlayPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = false

        let view = CameraPreviewView(
            frame: CGRect(origin: .zero, size: frame.size),
            session: session
        )
        panel.contentView = view
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        self.panel = panel

        let number = panel.windowNumber
        ScreenCapture.excludeWindow(number)
        CameraOverlayRegistry.register(number)
        DebugLog.log(
            "camera: panel shown position=\(position.rawValue) size=\(size.rawValue) "
            + "frame=\(NSStringFromRect(frame)) windowNumber=\(number) "
            + "excluded=\(ScreenCapture.excludedWindowNumbers.contains(CGWindowID(number)))"
        )
    }
}

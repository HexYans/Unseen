import AppKit

/// Keeps the app's own ordinary windows where the user left them while a
/// capture surface has to activate the app, and hands activation back when the
/// capture is over.
///
/// Why this exists
/// ---------------
/// The capture overlay must hold the keyboard for Escape (cancel), Return
/// (confirm), the digit shortcuts (aspect ratio), ⌘-digits (annotation tools)
/// and the arrow keys (nudge). That is reliable only while the owning app is
/// active, so the overlay asks for `NSApp.activate(ignoringOtherApps: true)`.
///
/// Activating an app raises **every** visible window it owns above the other
/// apps' windows. With the settings page open behind Safari, pressing the
/// capture hotkey therefore brought the settings page to the front — and it
/// stayed in front after the shot, because activation is not undone when the
/// overlay closes. The overlay itself lives at `.screenSaver` level, so it is
/// not the window the user was seeing move.
///
/// What this does
/// --------------
/// `begin()` records the previously frontmost application and the app's own
/// ordinary (`.normal` level) visible windows before the first activation.
/// `activate()` performs the activation and then pushes exactly those recorded
/// windows back to the bottom of their level, i.e. behind the windows of the
/// application that was in front. The capture panels are `.screenSaver` level
/// and were created after `begin()`, so they are never touched and stay on top.
///
/// The finish path needs the same push. Ordering out the capture panel hands
/// key status to the next window this app owns — the settings page — and
/// AppKit orders that window in, which lifts it above the application the user
/// came from and leaves it in the shot the capture is about to take. `sinkSoon`
/// only covers the presentation; `CaptureOverlayController.close()` therefore
/// calls `sinkIfNeeded()` in the same run-loop turn as the order-out, so the
/// window server only ever commits the restored order.
///
/// `restoreIfNeeded()` activates the recorded application again once the shot
/// has been captured and delivered, so the keyboard goes back where the user
/// left it instead of staying with an app that shows no window. Callers invoke
/// it only after the pixels exist: sampling a region or window while this app
/// is active is what gives those windows their inactive title bar, and
/// switching apps first would change the file the user gets.
///
/// Nothing here changes a window's frame, level or key state; only the order
/// of the recorded windows, and only while a capture is presenting.
@MainActor
enum OverlayActivation {
    private struct WeakWindow {
        weak var window: NSWindow?
    }

    private struct Session {
        let wasActive: Bool
        let previousApplication: NSRunningApplication?
        let windows: [WeakWindow]
    }

    private static var session: Session?

    /// Whether a capture is currently holding an activation session.
    static var isArmed: Bool { session != nil }

    /// Record where the user was, before the capture surface activates us.
    ///
    /// When the app is already active there is nothing to protect: no other
    /// application's windows can be in front of ours by definition, so the
    /// session only remembers that and never reorders anything.
    ///
    /// A second capture can begin while an earlier surface's result window is
    /// still on screen (the OCR card, the beautify preview). The first session
    /// is kept in that case: it already names the application the user was in,
    /// and overwriting it would make the earlier surface's close hand focus to
    /// the wrong place.
    static func begin() {
        guard session == nil else {
            DebugLog.log("overlay: activation begin ignored, a session is already armed")
            return
        }
        let wasActive = NSApp.isActive
        let frontmost = NSWorkspace.shared.frontmostApplication
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let previous: NSRunningApplication? = {
            guard !wasActive, let frontmost else { return nil }
            guard frontmost.bundleIdentifier != ownBundleIdentifier else { return nil }
            return frontmost
        }()

        var windows: [WeakWindow] = []
        if !wasActive {
            for window in NSApp.orderedWindows {
                guard window.isVisible,
                      window.windowNumber > 0,
                      window.level == .normal else { continue }
                windows.append(WeakWindow(window: window))
            }
        }

        session = Session(
            wasActive: wasActive,
            previousApplication: previous,
            windows: windows
        )
        DebugLog.log(
            "overlay: activation begin active=\(wasActive) "
            + "previous=\(previous?.localizedName ?? "-") windows=\(windows.count)"
        )
    }

    /// Activate the app for the capture surface, then put the recorded windows
    /// back behind the application the user was in.
    ///
    /// Safe to call when no session is armed (the self test drives the panels
    /// without a session): it degrades to the plain activation.
    static func activate() {
        NSApp.activate(ignoringOtherApps: true)
        sinkSoon()
    }

    /// Send the recorded windows to the back of `.normal` level. Idempotent;
    /// a window that closed in the meantime is skipped.
    static func sinkIfNeeded() {
        guard let session, !session.wasActive, !session.windows.isEmpty else { return }
        var sunk = 0
        for candidate in session.windows {
            guard let window = candidate.window,
                  window.isVisible,
                  window.level == .normal else { continue }
            window.orderBack(nil)
            sunk += 1
        }
        if sunk > 0 {
            DebugLog.log("overlay: sunk \(sunk) own window(s) behind the front app")
        }
    }

    /// Activation lands a run-loop turn (or more) after the request, and the
    /// overlay re-asserts itself a beat later, so sink on both sides of that.
    private static func sinkSoon() {
        guard let session, !session.wasActive, !session.windows.isEmpty else { return }
        Task { @MainActor in
            for delay in [0, 120, 420] as [UInt64] {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay * 1_000_000)
                }
                sinkIfNeeded()
            }
        }
    }

    /// Hand activation back to the application the user was in, then forget
    /// the session. A no-op when the app was already active before the capture
    /// (there is nothing to hand back to), and when the user has meanwhile
    /// switched to a different application by hand — we only give back the
    /// activation we took.
    static func restoreIfNeeded() {
        guard let session else { return }
        // A surface that opened while an earlier result card was still up (and
        // closed after the user started a second capture) must not steal the
        // keyboard from that capture; the second capture restores on its own.
        guard !isCaptureSurfacePresenting else {
            DebugLog.log("overlay: not restoring, a capture surface is still up")
            return
        }
        self.session = nil
        guard !session.wasActive else { return }
        guard isFrontmost else {
            DebugLog.log("overlay: not restoring, another app is already in front")
            return
        }
        guard let previous = session.previousApplication,
              !previous.isTerminated else {
            DebugLog.log("overlay: no previous application to restore")
            return
        }
        DebugLog.log(
            "overlay: restoring activation to \(previous.localizedName ?? "?") "
            + "(pid \(previous.processIdentifier))"
        )
        // `.activateAllWindows` is what raises the window the user left in
        // front: a bare activation only moves the app's activation state, and
        // measured here on macOS 27 the previously sunk settings window could
        // stay composited above the browser even though the browser was the
        // frontmost application. Asking for all windows also covers the case
        // where the user's front window was not the app's main one.
        previous.activate(options: [.activateAllWindows])
    }

    /// True while one of the full-screen capture panels is on screen.
    private static var isCaptureSurfacePresenting: Bool {
        NSApp.windows.contains { $0 is CaptureOverlayPanel && $0.isVisible }
    }

    /// Debug ledger for the finish path: where this process's own windows sit
    /// in the window server's on-screen list (front to back), next to the
    /// frontmost application and the key window.
    ///
    /// Ordering out the key capture panel hands key status to the next window
    /// this app owns, and AppKit orders that window in — which lands the
    /// settings page above the application the user came from. The ledger is
    /// what proves which call did it; nothing here changes the order.
    static func logWindowOrder(_ label: String) {
        guard DebugLog.isEnabled else { return }
        let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        let pid = ProcessInfo.processInfo.processIdentifier
        var own: [String] = []
        for (index, info) in raw.enumerated() {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid else { continue }
            let number = info[kCGWindowNumber as String] as? Int ?? 0
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            let name = info[kCGWindowName as String] as? String ?? ""
            own.append("#\(index)[win \(number) L\(layer) \(name.isEmpty ? "-" : name)]")
        }
        DebugLog.log(
            "overlay: order \(label) active=\(NSApp.isActive) "
            + "front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") "
            + "key=\(NSApp.keyWindow?.windowNumber ?? -1) "
            + "own=\(own.isEmpty ? "-" : own.joined(separator: " "))"
        )
    }

    /// Whether the window server really has this app in front. `NSApp.isActive`
    /// can lag behind the window server while another app holds activation.
    static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
            == ProcessInfo.processInfo.processIdentifier
    }

    /// Forget the session without moving activation. Used by capture paths that
    /// deliberately leave a window of their own on screen (recording, long
    /// screenshot) and will return focus themselves.
    static func end() {
        session = nil
    }
}

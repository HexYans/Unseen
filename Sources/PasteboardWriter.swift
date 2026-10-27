import AppKit
@preconcurrency import ApplicationServices

/// Writes history entries back to the system pasteboard, and optionally
/// synthesises a ⌘V keystroke into the previously active app.
enum PasteboardWriter {
    /// Put a payload on the general pasteboard. Returns the new `changeCount`
    /// so the monitor can ignore its own write.
    @discardableResult
    static func write(_ payload: ClipPayload) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        var objects: [NSPasteboardWriting] = []

        switch payload.kind {
        case .files, .image:
            objects.append(contentsOf: fileObjects(payload))
            if let image = imageObject(payload) { objects.append(image) }
            if let text = payload.text { objects.append(text as NSString) }
        case .text, .richText, .mixed:
            if let text = payload.text { objects.append(text as NSString) }
            objects.append(contentsOf: fileObjects(payload))
            if let image = imageObject(payload) { objects.append(image) }
        }

        if objects.isEmpty, let text = payload.text {
            objects.append(text as NSString)
        }

        pasteboard.writeObjects(objects)
        return pasteboard.changeCount
    }

    private static func fileObjects(_ payload: ClipPayload) -> [NSPasteboardWriting] {
        payload.fileURLs.map { URL(fileURLWithPath: $0) as NSURL }
    }

    private static func imageObject(_ payload: ClipPayload) -> NSPasteboardWriting? {
        guard let data = payload.imagePNG else { return nil }
        return NSImage(data: data)
    }

    // MARK: - Auto paste

    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Ask the system to show the "grant Accessibility access" prompt.
    static func requestAccessibilityAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Post a synthetic ⌘V. No-op unless Accessibility access has been granted.
    @discardableResult
    static func sendCommandV() -> Bool {
        guard isAccessibilityTrusted else { return false }
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }

        let keyV: CGKeyCode = 0x09
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false)
        else { return false }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }
}

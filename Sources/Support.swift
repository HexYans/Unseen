import AppKit
import Carbon.HIToolbox
import Foundation

/// Optional stderr tracing, enabled with `UNSEEN_DEBUG=1` (which also
/// arms the interactive debug probe) or `UNSEEN_TRACE=1` (tracing
/// only, no probe — used for scripted end-to-end checks).
enum DebugLog {
    private static let environment = ProcessInfo.processInfo.environment

    static let isEnabled = environment["UNSEEN_DEBUG"] != nil
        || environment["UNSEEN_TRACE"] != nil

    /// Optional append-only destination. LaunchServices apps have no useful
    /// stderr, so scripted end-to-end runs point this at a file.
    private static let traceFile: FileHandle? = {
        guard let path = environment["UNSEEN_TRACE_FILE"], !path.isEmpty else {
            return nil
        }
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let line = Data("[unseen] \(message())\n".utf8)
        FileHandle.standardError.write(line)
        if let traceFile {
            _ = try? traceFile.seekToEnd()
            try? traceFile.write(contentsOf: line)
        }
    }
}

/// `yyyyMMdd-HHmmss`, the stamp shared by screenshot / pin / beautify file names.
func fileNameTimestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
}

/// Renders Carbon key codes / modifier masks the way macOS displays shortcuts.
enum KeyCodeFormatter {
    private static let specialKeys: [UInt32: String] = [
        UInt32(kVK_Return): "↩",
        UInt32(kVK_ANSI_KeypadEnter): "⌤",
        UInt32(kVK_Tab): "⇥",
        UInt32(kVK_Space): "空格",
        UInt32(kVK_Delete): "⌫",
        UInt32(kVK_ForwardDelete): "⌦",
        UInt32(kVK_Escape): "⎋",
        UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑",
        UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_Home): "↖",
        UInt32(kVK_End): "↘",
        UInt32(kVK_PageUp): "⇞",
        UInt32(kVK_PageDown): "⇟",
        UInt32(kVK_F1): "F1",
        UInt32(kVK_F2): "F2",
        UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5",
        UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7",
        UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10",
        UInt32(kVK_F11): "F11",
        UInt32(kVK_F12): "F12"
    ]

    /// The character `NSMenuItem.keyEquivalent` expects for the keys whose
    /// on-screen form is a glyph, not a character. AppKit renders each of
    /// these back to the same glyph (↩, ⇥, ↑, …), so the menu's right-hand
    /// column reads like the settings page's.
    private static let menuSpecialKeys: [UInt32: String] = [
        UInt32(kVK_Return): "\r",
        UInt32(kVK_ANSI_KeypadEnter): "\u{03}",
        UInt32(kVK_Tab): "\t",
        UInt32(kVK_Space): " ",
        UInt32(kVK_Delete): "\u{08}",
        UInt32(kVK_ForwardDelete): "\u{F728}",
        UInt32(kVK_Escape): "\u{1B}",
        UInt32(kVK_LeftArrow): "\u{F702}",
        UInt32(kVK_RightArrow): "\u{F703}",
        UInt32(kVK_UpArrow): "\u{F700}",
        UInt32(kVK_DownArrow): "\u{F701}",
        UInt32(kVK_Home): "\u{F729}",
        UInt32(kVK_End): "\u{F72B}",
        UInt32(kVK_PageUp): "\u{F72C}",
        UInt32(kVK_PageDown): "\u{F72D}",
        UInt32(kVK_F1): "\u{F704}",
        UInt32(kVK_F2): "\u{F705}",
        UInt32(kVK_F3): "\u{F706}",
        UInt32(kVK_F4): "\u{F707}",
        UInt32(kVK_F5): "\u{F708}",
        UInt32(kVK_F6): "\u{F709}",
        UInt32(kVK_F7): "\u{F70A}",
        UInt32(kVK_F8): "\u{F70B}",
        UInt32(kVK_F9): "\u{F70C}",
        UInt32(kVK_F10): "\u{F70D}",
        UInt32(kVK_F11): "\u{F70E}",
        UInt32(kVK_F12): "\u{F70F}"
    ]

    /// e.g. `⌥⌘V`
    static func display(keyCode: UInt32, modifiers mask: UInt32) -> String {
        modifierSymbols(mask) + keySymbol(keyCode)
    }

    static func modifierSymbols(_ mask: UInt32) -> String {
        var result = ""
        if mask & UInt32(controlKey) != 0 { result += "⌃" }
        if mask & UInt32(optionKey) != 0 { result += "⌥" }
        if mask & UInt32(shiftKey) != 0 { result += "⇧" }
        if mask & UInt32(cmdKey) != 0 { result += "⌘" }
        return result
    }

    static func keySymbol(_ keyCode: UInt32) -> String {
        if let special = specialKeys[keyCode] { return special }
        if let translated = translate(keyCode) { return translated.uppercased() }
        return "键码 \(keyCode)"
    }

    /// Translate NSEvent modifier flags into a Carbon modifier mask.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        return mask
    }

    /// A global hotkey must include at least one of ⌘ / ⌥ / ⌃, otherwise it
    /// swallows ordinary typing in every app.
    static func isUsableGlobalHotKey(_ mask: UInt32) -> Bool {
        mask & UInt32(cmdKey | optionKey | controlKey) != 0
    }

    /// The pair AppKit needs to draw — and match — a shortcut in a menu row.
    ///
    /// `keyEquivalent` is a single character: the unshifted character for a
    /// printable key (AppKit uppercases it on screen whenever ⌘ / ⌥ is held),
    /// the function-key character for the glyph keys, and `nil` for a slot
    /// that is not bound. The mask is the Carbon mask in AppKit's spelling,
    /// which is also the order the system draws the glyphs in: ⌃⌥⇧⌘.
    static func menuKeyEquivalent(
        keyCode: UInt32,
        modifiers: UInt32
    ) -> (key: String, mask: NSEvent.ModifierFlags)? {
        guard modifiers != 0 else { return nil }
        let mask = eventModifiers(modifiers)
        if let special = menuSpecialKeys[keyCode] { return (special, mask) }
        guard let translated = translate(keyCode), translated.count == 1 else { return nil }
        // A shifted letter must be stored as its capital: AppKit compares the
        // event's character (`Z`) with the key equivalent, and draws ⌘⇧Z for
        // an uppercase equivalent.
        return (mask.contains(.shift) ? translated.uppercased() : translated.lowercased(), mask)
    }

    /// Carbon modifier mask → AppKit flags, the two spellings of the same set.
    static func eventModifiers(_ mask: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if mask & UInt32(controlKey) != 0 { flags.insert(.control) }
        if mask & UInt32(optionKey) != 0 { flags.insert(.option) }
        if mask & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if mask & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    /// Ask the current keyboard layout what character a key produces.
    private static func translate(_ keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            var deadKeyState: UInt32 = 0
            var characters = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }
}

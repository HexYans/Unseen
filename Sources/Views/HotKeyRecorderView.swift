import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Click-to-record control for a global hotkey.
///
/// This is the one shortcut slot the whole settings area uses. It has four
/// states:
///
/// * **unbound** — grey 「快捷键」 placeholder; clicking starts recording.
/// * **bound** — the combination in the accent colour (`⌃⌥⌘A`).
/// * **recording** — an accent-filled 「按下快捷键…」 prompt.
/// * **conflict** — red border, red symbols and a warning glyph, because two
///   enabled actions share the same combination.
///
/// The slot is one plain capsule in every state: no inner divider, no trailing
/// glyph. A visible `×` segment lived here between 4336e51 and this change, and
/// the owner asked for the original single-label shape back — it read as an
/// error cross next to the combination.
///
/// Clearing therefore stays keyboard / menu only: Delete (or Forward Delete)
/// while recording, and 清除快捷键 in the slot's context menu. The 快捷键 page
/// prints that in one line under the last card, so the path is still discoverable
/// without a permanent control on every row.
///
/// Recording uses a *local* event monitor, so it only sees keystrokes while
/// this control is armed and never observes other apps.
struct HotKeyRecorderView: View {
    @Binding var keyCode: Int
    @Binding var modifiers: Int
    /// What "恢复默认" resets to. `.unbound` for the shortcuts that ship with
    /// no default (OCR / 取色 / 按键显示 / 套壳).
    var defaultConfiguration: HotKeyConfiguration = .default
    /// e.g. "与「钉图」重复"; non-nil paints the slot as a conflict.
    var conflictLabel: String? = nil
    /// The owning feature switch. Off dims the slot but keeps it editable.
    var isEnabled: Bool = true
    /// The 快捷键 page keeps 默认 in a cell of its own, so its rows carry only
    /// the slot. Every other surface keeps the paired button.
    var showsDefaultButton: Bool = true
    var onChange: () -> Void = {}

    @State private var isRecording = false
    @State private var monitor: Any?
    @Environment(\.colorScheme) private var colorScheme

    /// The label area keeps this width, bound or not; the capsule adds 9 pt of
    /// padding on each side, for the 136 pt column the 快捷键 page reserves.
    /// Both live inside the button, so the whole capsule is clickable — the
    /// pre-`×` shape.
    ///
    /// 92 → 118 in the 2026-10-24 pass: the four-modifier combinations
    /// (⌃⌥⇧⌘ + letter) were touching the capsule's trailing padding, and the
    /// owner asked for the slot to stop feeling cramped. The page's column is
    /// derived from this number, so the two cannot drift.
    private static let slotWidth: CGFloat = 118

    private var configuration: HotKeyConfiguration {
        HotKeyConfiguration(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers))
    }

    private var isBound: Bool { configuration.isBound }
    private var isConflicting: Bool { conflictLabel != nil && !isRecording }

    private var labelText: String {
        if isRecording { return "按下快捷键…" }
        return isBound ? configuration.displayString : "快捷键"
    }

    var body: some View {
        Group {
            if showsDefaultButton {
                // 8 pt keeps the 默认 button clear of the key slot; the button
                // itself uses the same neutral capsule as every other settings
                // control.
                HStack(spacing: 8) {
                    keySlot
                    pairedButton
                }
            } else {
                keySlot
            }
        }
        .opacity(isEnabled ? 1 : 0.6)
        // 恢复默认 lives in the page's own 默认 cell, outside this view, so
        // an external reset has to end an armed recording by itself — otherwise
        // the slot would keep saying 按下快捷键… with a fresh binding behind it.
        .onChange(of: keyCode) { stopRecording() }
        .onChange(of: modifiers) { stopRecording() }
        .onDisappear { stopRecording() }
    }

    /// The button that sits beside the slot everywhere except the 快捷键 page.
    @ViewBuilder
    private var pairedButton: some View {
        if isRecording {
            NeutralCapsuleButton(
                title: "取消",
                height: NeutralControlMetrics.compactHeight,
                width: 46
            ) {
                stopRecording()
            }
        } else {
            NeutralCapsuleButton(
                title: "默认",
                height: NeutralControlMetrics.compactHeight,
                width: 46,
                help: defaultConfiguration.isBound
                    ? "恢复默认快捷键（\(defaultConfiguration.displayString)）"
                    : "清除快捷键（这一项没有默认键位）"
            ) {
                applyDefault()
            }
        }
    }

    /// `⌃⌥⌘A` while bound, `快捷键` while empty. Both variants occupy the same
    /// 118 pt + 18 pt padding capsule, and the button's label *is* that capsule.
    private var keySlot: some View {
        Button {
            isRecording ? stopRecording() : startRecording()
        } label: {
            HStack(spacing: 5) {
                if isConflicting {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .bold))
                }
                Text(labelText)
                    .font(.system(
                        size: 12,
                        weight: isBound || isRecording ? .semibold : .regular,
                        design: .rounded
                    ))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .foregroundStyle(foreground)
            .frame(minWidth: Self.slotWidth, minHeight: 22)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(border, lineWidth: isConflicting ? 1.2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(buttonHelp)
        .contextMenu {
            Button("重新录制") { startRecording() }
                .disabled(isRecording)
            Button("恢复默认") {
                applyDefault()
            }
            .disabled(defaultConfiguration == configuration)
            Button("清除快捷键", role: .destructive) { clearBinding() }
                .disabled(!isBound)
        }
    }

    private var foreground: Color {
        if isRecording { return .white }
        if isConflicting { return .red }
        guard isBound else { return .secondary }
        // The sRGB accent at 12 pt over its own 12 % fill measures ~2.8:1 on
        // the dark ground (it is ~3.1:1 in light). Lifting the ink 25 % towards
        // white keeps the accent state while restoring the contrast; the fill
        // and hairline stay the user's accent.
        guard colorScheme == .dark,
              let lifted = NSColor.controlAccentColor
                  .blended(withFraction: 0.25, of: .white)
        else { return .accentColor }
        return Color(nsColor: lifted)
    }

    private var background: Color {
        if isRecording { return .accentColor }
        if isConflicting { return Color.red.opacity(0.10) }
        return isBound ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04)
    }

    private var border: Color {
        if isConflicting { return Color.red.opacity(0.55) }
        return isBound ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.12)
    }

    private var buttonHelp: String {
        if isRecording { return "按下组合键；Esc 取消，Delete 清除" }
        if let conflictLabel { return "\(conflictLabel)，先改掉其中一个" }
        return isBound ? "点击重新录制；右键可清除" : "点击录制快捷键"
    }

    private func startRecording() {
        stopRecording()
        isRecording = true

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            guard event.type == .keyDown else { return nil }  // swallow modifier-only presses

            if Int(event.keyCode) == kVK_Escape {
                MainActor.assumeIsolated { stopRecording() }
                return nil
            }

            // Delete / Backspace clears the slot: the only placeholder is the
            // grey 「快捷键」, and this is the keyboard path the 快捷键 page's
            // closing line points at now that the slot has no `×` (the
            // context-menu item is the pointer path).
            if Int(event.keyCode) == kVK_Delete || Int(event.keyCode) == kVK_ForwardDelete {
                MainActor.assumeIsolated { clearBinding() }
                return nil
            }

            let mask = KeyCodeFormatter.carbonModifiers(from: event.modifierFlags)
            guard KeyCodeFormatter.isUsableGlobalHotKey(mask) else {
                NSSound.beep()  // need at least one of ⌘ / ⌥ / ⌃
                return nil
            }

            let code = Int(event.keyCode)
            let carbon = Int(mask)
            MainActor.assumeIsolated {
                keyCode = code
                modifiers = carbon
                stopRecording()
                onChange()
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private func applyDefault() {
        keyCode = Int(defaultConfiguration.keyCode)
        modifiers = Int(defaultConfiguration.modifiers)
        stopRecording()
        onChange()
    }

    private func clearBinding() {
        keyCode = Int(HotKeyConfiguration.unbound.keyCode)
        modifiers = Int(HotKeyConfiguration.unbound.modifiers)
        stopRecording()
        onChange()
    }
}

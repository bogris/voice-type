import Foundation

/// A shortcut is accepted on release, keeping dictation suspended for its entire press.
public struct ShortcutRecording {
    public enum Outcome: Equatable { case waiting, invalid, cancelled, captured(KeyboardShortcut) }
    private var candidate: KeyboardShortcut?
    public init() {}
    public mutating func handle(_ kind: HotkeyState.EventKind, keycode: Int64, flags: UInt64) -> Outcome {
        switch kind {
        case .flagsChanged: return .waiting
        case .keyDown:
            if candidate != nil { return .waiting }
            if keycode == 53 && flags & KeyboardShortcut.modifierMask == 0 { return .cancelled }
            let shortcut = KeyboardShortcut(keycode: keycode, modifiers: flags)
            guard shortcut.isValid else { return .invalid }
            candidate = shortcut
            return .waiting
        case .keyUp:
            guard let candidate, candidate.keycode == keycode else { return .waiting }
            self.candidate = nil
            return .captured(candidate)
        }
    }
}

/// Avoid opening AUHAL while the OS is still waiting for microphone permission.
public struct MicrophonePermissionGate {
    public enum Action: Equatable { case start, request, wait }
    private var requested = false
    public init() {}
    public mutating func next(state: String) -> Action {
        if state == "allowed" { return .start }
        if state == "not_asked" && !requested { requested = true; return .request }
        return .wait
    }
}

public enum MenuText {
    /// Full diagnostics belong in tooltips and the log, not in the menu's width calculation.
    public static func compact(_ text: String) -> String {
        let line = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return line.count > 64 ? String(line.prefix(63)) + "…" : line
    }
}

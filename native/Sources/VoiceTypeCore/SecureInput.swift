import Foundation

/// The app holding macOS Secure Input, as IOConsoleUsers' kCGSSessionSecureInputPID names it.
///
/// While any app holds Secure Input (a focused password box, Terminal's Secure Keyboard
/// Entry), macOS sends no key events to session event taps. F12 then goes straight to the
/// front app, which usually beeps, and Voice Type can't tell a press happened. It can only
/// watch for Secure Input and say who has it.
public struct SecureInputHolder: Equatable, Sendable, CustomStringConvertible {
    public var pid: Int32?
    public var name: String?

    public init(pid: Int32?, name: String?) {
        self.pid = pid
        self.name = name
    }

    /// For the log: "Google Chrome (pid 3177)".
    public var description: String {
        switch (name, pid) {
        case let (name?, pid?): return "\(name) (pid \(pid))"
        case let (name?, nil): return name
        case let (nil, pid?): return "pid \(pid)"
        default: return "an unknown app"
        }
    }

    /// For the menu and the status file.
    public var blocking: String { "\(name ?? "Another app") is blocking keys (a password box has focus)" }
}

/// Remembers who held Secure Input at the last check, so the log gets one line each time it
/// turns on, passes to another app, or turns off, rather than one per check.
public struct SecureInputWatch: Sendable {
    public private(set) var holder: SecureInputHolder?

    public init() {}

    /// Returns a line to log when something changed since the last check.
    public mutating func update(_ now: SecureInputHolder?) -> String? {
        defer { holder = now }
        switch (holder, now) {
        case (nil, let now?):
            return "Secure Input turned on by \(now): the keyboard tap gets no keys, so F12 and Right Control go to the front app until it lets go."
        case (_?, nil):
            return "Secure Input turned off; F12 and Right Control reach Voice Type again."
        case let (was?, now?) where was != now:
            return "Secure Input passed to \(now)."
        default:
            return nil
        }
    }
}

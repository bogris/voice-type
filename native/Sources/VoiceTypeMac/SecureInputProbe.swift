import AppKit
import Carbon
import IOKit
import VoiceTypeCore

/// Who holds macOS Secure Input right now, or nil. Cheap enough to call every second: a
/// HIToolbox flag, then (only while it's on) one IORegistry property.
enum SecureInputProbe {
    static func holder() -> SecureInputHolder? {
        let pid = secureInputPID()
        // The flag can lag the registry by a moment either way, so either one counts.
        guard IsSecureEventInputEnabled() || pid != nil else { return nil }
        let name = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
        return SecureInputHolder(pid: pid, name: name)
    }

    /// The same value `ioreg -l -w 0 | grep kCGSSessionSecureInputPID` shows: the root's
    /// IOConsoleUsers lists each login session, and this user's carries the holder's pid.
    private static func secureInputPID() -> Int32? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard let users = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [[String: Any]] else { return nil }
        let uid = Int(getuid())
        for session in users where (session["kCGSSessionUserIDKey"] as? Int) == uid {
            if let pid = session["kCGSSessionSecureInputPID"] as? Int, pid > 0 { return Int32(pid) }
        }
        return nil
    }
}

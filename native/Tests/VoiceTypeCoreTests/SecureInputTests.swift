import Foundation
import Testing
@testable import VoiceTypeCore

// macOS Secure Input: while an app holds it (a password box with focus), the keyboard tap
// sees no keys, F12 goes to the front app and it beeps. Voice Type says who's holding it.

struct SecureInputTests {
    private let chrome = SecureInputHolder(pid: 3177, name: "Google Chrome")

    @Test func logsOnceWhenItTurnsOnAndOnceWhenItTurnsOff() {
        var watch = SecureInputWatch()
        #expect(watch.update(nil) == nil)
        #expect(watch.update(chrome) == "Secure Input turned on by Google Chrome (pid 3177): the keyboard tap gets no keys, so F12 and Right Control go to the front app until it lets go.")
        #expect(watch.update(chrome) == nil)
        #expect(watch.holder == chrome)
        #expect(watch.update(nil) == "Secure Input turned off; F12 and Right Control reach Voice Type again.")
        #expect(watch.update(nil) == nil)
        #expect(watch.holder == nil)
    }

    @Test func logsWhenAnotherAppTakesItOver() {
        var watch = SecureInputWatch()
        _ = watch.update(chrome)
        let terminal = SecureInputHolder(pid: 900, name: "Terminal")
        #expect(watch.update(terminal) == "Secure Input passed to Terminal (pid 900).")
        #expect(watch.holder == terminal)
    }

    @Test func namesTheAppForTheMenu() {
        #expect(chrome.blocking == "Google Chrome is blocking keys (a password box has focus)")
        #expect(SecureInputHolder(pid: nil, name: nil).blocking == "Another app is blocking keys (a password box has focus)")
        #expect(SecureInputHolder(pid: 12, name: nil).description == "pid 12")
        #expect(SecureInputHolder(pid: nil, name: nil).description == "an unknown app")
    }

    @Test func statusFileCarriesItWithoutChangingTheState() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("secure-input-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("native-status.json")
        var status = NativeStatus(pid: 77, state: "idle", modelStatus: "ready", hotkeyListener: "event-tap", holdsLock: true)
        try status.write(to: url)
        // Absent when nothing holds it, so the file reads as it always did.
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("keys_blocked_by"))
        status.keysBlockedBy = chrome.blocking
        try status.write(to: url)
        let read = try #require(NativeStatus.read(from: url))
        #expect(read.keysBlockedBy == chrome.blocking)
        // Still ready: `restart` waiting for it mustn't time out because a password box is up.
        #expect(read.isReady)
    }
}

import Testing
@testable import VoiceTypeCore

struct SetupInteractionTests {
    @Test func shortcutRecorderKeepsPressModifiersUntilMainKeyRelease() {
        var recorder = ShortcutRecording()
        #expect(recorder.handle(.keyDown, keycode: 2, flags: KeyboardShortcut.command | KeyboardShortcut.shift) == .waiting)
        #expect(recorder.handle(.flagsChanged, keycode: 56, flags: 0) == .waiting)
        #expect(recorder.handle(.keyUp, keycode: 2, flags: 0) == .captured(.init(keycode: 2, modifiers: KeyboardShortcut.command | KeyboardShortcut.shift)))
    }
    @Test func recorderRejectsPlainTypingAndEscapeCancels() {
        var recorder = ShortcutRecording()
        #expect(recorder.handle(.keyDown, keycode: 0, flags: 0) == .invalid)
        #expect(recorder.handle(.keyDown, keycode: 53, flags: 0) == .cancelled)
    }
    @Test func microphonePermissionGateRequestsOnceAndNeverStartsWhileDenied() {
        var gate = MicrophonePermissionGate()
        #expect(gate.next(state: "not_asked") == .request)
        #expect(gate.next(state: "not_asked") == .wait)
        #expect(gate.next(state: "denied") == .wait)
        #expect(gate.next(state: "allowed") == .start)
    }
    @Test func longDiagnosticDoesNotWidenMenu() {
        let reason = String(repeating: "Opening microphone hung inside Core Audio. ", count: 10)
        #expect(MenuText.compact(reason).count <= 64)
        #expect(MenuText.compact(reason).hasSuffix("…"))
        #expect(MenuText.compact("Ready") == "Ready")
    }
}

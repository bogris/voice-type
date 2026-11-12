import Foundation
import Testing
@testable import VoiceTypeCore

struct ShortcutTests {
    @Test func requiresExactModifiersOnPressButAlwaysHandlesRelease() {
        var keys = HotkeyState(shortcuts: [.init(keycode: 2, modifiers: KeyboardShortcut.command | KeyboardShortcut.shift)])
        #expect(keys.handle(.keyDown, keycode: 2, flags: KeyboardShortcut.command, swallowing: true) == .notOurs)
        #expect(keys.handle(.keyDown, keycode: 2, flags: KeyboardShortcut.command | KeyboardShortcut.shift, swallowing: true) == .swallow)
        #expect(keys.isDown)
        // Releasing modifiers before D must not leave recording stuck.
        #expect(keys.handle(.keyUp, keycode: 2, flags: 0, swallowing: false) == .swallow)
        #expect(!keys.isDown)
    }

    @Test func rejectsCollisionsAndPlainTypingKeys() {
        let plain = KeyboardShortcut(keycode: 0, modifiers: 0)
        #expect(!plain.isValid)
        let chord = KeyboardShortcut(keycode: 0, modifiers: KeyboardShortcut.option)
        #expect(chord.isValid)
        #expect(!ShortcutConfiguration(microphone: chord, meeting: chord).isValid)
        #expect(ShortcutConfiguration.defaults.isValid)
    }

    @Test func persistsAndKeepsLegacyDefaults() {
        var file = SettingsFile(url: URL(fileURLWithPath: "/unused"), json: .object([]))
        #expect(file.shortcuts == .defaults)
        let custom = ShortcutConfiguration(microphone: .init(keycode: 2, modifiers: KeyboardShortcut.command | KeyboardShortcut.shift),
                                           meeting: .init(keycode: 40, modifiers: KeyboardShortcut.option), rightControl: false)
        file.setNative("shortcuts", custom.json)
        #expect(file.shortcuts == custom)
        file.setNative("shortcuts", .object([]))
        #expect(file.shortcuts == .defaults)
    }

    @Test func repeatsAndPausedPressesKeepOriginalDisposition() {
        var keys = HotkeyState(shortcuts: [.init(keycode: 40, modifiers: KeyboardShortcut.option)])
        #expect(keys.handle(.keyDown, keycode: 40, flags: KeyboardShortcut.option, swallowing: false) == .passThrough)
        #expect(keys.handle(.keyDown, keycode: 40, flags: 0, swallowing: true) == .passThrough)
        #expect(keys.handle(.keyUp, keycode: 40, flags: 0, swallowing: true) == .passThrough)
    }
    @Test func editingShortcutsDefersBothAssignmentsUntilRelease() {
        var bindings = ShortcutBindings()
        _ = bindings.microphone.handle(.keyDown, keycode: HotkeyState.f12, flags: 0)
        let swapped = ShortcutConfiguration(microphone: .init(keycode: HotkeyState.f11), meeting: .init(keycode: HotkeyState.f12))
        bindings.update(swapped)
        bindings.prepareForEvent()
        #expect(bindings.microphone.isDown)
        #expect(bindings.meeting.handle(.keyDown, keycode: HotkeyState.f12, flags: 0, swallowing: true) == .notOurs)
        _ = bindings.microphone.handle(.keyUp, keycode: HotkeyState.f12, flags: 0)
        bindings.prepareForEvent()
        #expect(bindings.meeting.handle(.keyDown, keycode: HotkeyState.f12, flags: 0, swallowing: true) == .swallow)
    }

}

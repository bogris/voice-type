import Foundation
import Testing
@testable import VoiceTypeCore

struct MeetingAudioTests {
    @Test func meetingShortcutIsIndependentAndKeepsPressDisposition() {
        var mic = HotkeyState()
        var meeting = HotkeyState(meeting: true)
        #expect(mic.handle(.keyDown, keycode: HotkeyState.f11, flags: 0, swallowing: true) == .notOurs)
        #expect(meeting.handle(.keyDown, keycode: HotkeyState.f11, flags: 0, swallowing: true) == .swallow)
        #expect(meeting.isDown)
        #expect(meeting.handle(.keyUp, keycode: HotkeyState.f11, flags: 0, swallowing: false) == .swallow)
        #expect(!meeting.isDown)
        #expect(!mic.isDown)
    }

    @Test func capturesOnlyMeetingAudioAndIgnoresOtherShortcutRelease() throws {
        let h = try ControllerHarness(meeting: true)
        h.startAndBecomeReady()
        h.controller.hotkeyChanged(down: true, source: .systemAudio)
        h.executor.drain()
        #expect(h.phase == .recording)
        #expect(!h.factory.events.contains { $0.hasPrefix("start") })
        h.meetingFactory.deliver(ControllerHarness.speech(seconds: 1))
        h.executor.drain()
        #expect(h.pill.last == "rec:Meeting audio")
        h.press()
        h.release()
        #expect(h.phase == .recording)
        h.controller.hotkeyChanged(down: false, source: .systemAudio)
        h.executor.drain()
        #expect(h.phase == .idle)
        #expect(h.paster.pasted.count == 1)
        #expect(h.recordingEntries().first?["audio_source"] == .string("system_audio"))
        #expect(h.probe.probed.count == 1)
    }

    @Test func meetingStartFailureDoesNotReconnectMicrophone() throws {
        let h = try ControllerHarness(meeting: true)
        h.startAndBecomeReady()
        h.meetingFactory.failOpen = true
        h.controller.hotkeyChanged(down: true, source: .systemAudio)
        h.executor.drain()
        #expect(h.phase == .idle)
        #expect(h.restarts.isEmpty)
        #expect(h.probe.probed.count == 1)
        #expect(h.pill.last?.contains("System Audio Recording") == true)
    }
    @Test func meetingSilenceDoesNotRunMicrophoneReadinessAgain() throws {
        let h = try ControllerHarness(meeting: true)
        h.startAndBecomeReady()
        h.controller.hotkeyChanged(down: true, source: .systemAudio)
        h.executor.drain()
        h.meetingFactory.deliver([Float](repeating: 0, count: 16000))
        h.controller.hotkeyChanged(down: false, source: .systemAudio)
        h.executor.drain()
        #expect(h.phase == .idle)
        #expect(h.probe.probed.count == 1)
        #expect(h.paster.pasted.isEmpty)
        #expect(h.pill.last?.contains("No meeting audio") == true)
        h.press()
        #expect(h.phase == .recording)
        h.release()
    }

    @Test func meetingCaptureHasTheSameSafetyCap() throws {
        let h = try ControllerHarness(meeting: true)
        h.startAndBecomeReady()
        h.controller.hotkeyChanged(down: true, source: .systemAudio)
        h.executor.drain()
        h.meetingFactory.deliver(ControllerHarness.speech(seconds: 1))
        h.executor.advance(Deadlines.maxRecording)
        #expect(h.phase == .idle)
        #expect(h.paster.pasted.count == 1)
        h.controller.hotkeyChanged(down: false, source: .systemAudio)
        h.executor.drain()
        #expect(h.paster.pasted.count == 1)
    }

    @Test func meetingSourceDefaultsToAllAndSavesWithoutChangingMicrophone() {
        var settings = SettingsFile(url: URL(fileURLWithPath: "/unused"), json: .object([("microphone_name", .string("My mic"))]))
        #expect(settings.meetingAppBundleID.isEmpty)
        settings.setNative("meeting_app_bundle_id", .string("us.zoom.xos"))
        #expect(settings.meetingAppBundleID == "us.zoom.xos")
        #expect(settings.microphoneName == "My mic")
    }

}

import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import Synchronization
import VoiceTypeCore

/// A separate input source; never added to the system's default inputs or outputs.
final class SystemAudioCatalog: AudioDeviceCatalog, @unchecked Sendable {
    func inputDevices() -> [InputDevice] { [InputDevice(id: 0, name: "Meeting audio")] }
    func defaultInputDevice() -> InputDevice? { inputDevices().first }
}

final class SystemAudioStreamFactory: AudioStreamFactory, @unchecked Sendable {
    func open(_ device: InputDevice, onAudio: @escaping @Sendable ([Float]) -> Void,
              onError: @escaping @Sendable (String) -> Void) throws -> AudioInputStream {
        try SystemAudioInputStream(bundleID: SettingsFile.load().meetingAppBundleID, onAudio: onAudio, onError: onError)
    }
}

/// An unmuted process tap copies playback. It neither redirects nor replays the sound.
final class SystemAudioInputStream: AudioInputStream, @unchecked Sendable {
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "voice-type.meeting-audio-drain", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var resampler: Resampler!
    private var ring: SampleRing!
    private let onAudio: @Sendable ([Float]) -> Void
    private let onError: @Sendable (String) -> Void
    private var running = false
    private var closed = false
    private let abandoned = Atomic<Bool>(false)
    private static let quarantine = Mutex<[SystemAudioInputStream]>([])

    init(bundleID: String, onAudio: @escaping @Sendable ([Float]) -> Void,
         onError: @escaping @Sendable (String) -> Void) throws {
        self.onAudio = onAudio
        self.onError = onError
        var ok = false
        defer { if !ok { close() } }
        let description = CATapDescription()
        description.name = "Voice Type Native meeting audio"
        description.isPrivate = true
        description.isMixdown = true
        description.isMono = true
        description.muteBehavior = .unmuted
        description.isExclusive = bundleID.isEmpty
        description.bundleIDs = bundleID.isEmpty ? ["com.mikerosoft.voice-type-native"] : [bundleID]
        description.isProcessRestoreEnabled = true
        try Self.check(AudioHardwareCreateProcessTap(description, &tap), "Create system audio tap")

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        try Self.check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format), "Read system audio format")
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32, format.mChannelsPerFrame == 1, format.mSampleRate > 0 else {
            throw MicrophoneUnavailable("Unsupported system audio format")
        }
        ring = SampleRing(capacity: Int(format.mSampleRate * 5))
        resampler = Resampler(inputRate: format.mSampleRate)
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Voice Type Native meeting capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                             kAudioSubTapDriftCompensationKey: true]]
        ]
        try Self.check(AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregate), "Create system audio capture device")
        let ring = self.ring!
        try Self.check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, nil) { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            // The tap is explicitly mono float32. No allocation, locks or conversion here.
            for buffer in buffers {
                if let data = buffer.mData {
                    ring.write(data.assumingMemoryBound(to: Float.self), count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
                }
            }
        }, "Create system audio callback")
        ok = true
    }

    deinit { close() }

    func start() throws {
        queue.sync { _ = ring.readAll(); resampler.reset() }
        try Self.check(AudioDeviceStart(aggregate, ioProc), "Start system audio capture (allow System Audio Recording)")
        running = true
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.drain(final: false) }
        self.timer = timer
        timer.resume()
    }

    func stop() throws {
        guard running else { return }
        let status = AudioDeviceStop(aggregate, ioProc)
        running = false
        timer?.cancel()
        timer = nil
        queue.sync { drain(final: true) }
        try Self.check(status, "Stop system audio capture")
    }

    func close() {
        guard !closed, !abandoned.load(ordering: .relaxed) else { return }
        closed = true
        try? stop()
        if let ioProc { AudioDeviceDestroyIOProcID(aggregate, ioProc); self.ioProc = nil }
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
    }

    func abandon() {
        guard !abandoned.exchange(true, ordering: .relaxed) else { return }
        Self.quarantine.withLock { $0.append(self) }
    }

    private func drain(final: Bool) {
        let raw = ring.readAll()
        if ring.takeDropped() > 0 { onError("System audio capture dropped samples") }
        let samples = final ? resampler.finish(raw) : resampler.process(raw)
        if !samples.isEmpty { onAudio(samples) }
    }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        if status != noErr { throw CoreAudioError.status(operation, status) }
    }
}

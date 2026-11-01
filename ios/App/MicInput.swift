import AVFoundation
import VoiceTypeCore
import VoiceTypeLink

/// The mic, running for the whole session. iOS won't let a background app start recording, only
/// keep going, so "listening" just means keeping the samples rather than throwing them away.
final class MicInput: @unchecked Sendable {
    enum Failure: Error { case noMicrophone, session(String), engine(String) }

    var onLevel: (@Sendable (Float) -> Void)?
    /// A phone call or Siri took the audio.
    var onInterrupted: (@Sendable () -> Void)?

    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "voicetype.mic", qos: .userInteractive)
    private let lock = NSLock()
    private var kept: [Float] = []     // lock
    private var preroll: [Float] = []  // lock
    private var keeping = false        // lock
    private var running = false        // queue
    private var converter: AVAudioConverter?
    private var observers: [NSObjectProtocol] = []
    private static let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.queue.async { self?.restart() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            self?.onInterrupted?()
        })
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    try startOnQueue()
                    done.resume()
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        queue.async { [self] in
            running = false
            if engine.isRunning { engine.stop() }
            engine.inputNode.removeTap(onBus: 0)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func beginKeeping() {
        lock.withLock {
            kept = preroll
            keeping = true
        }
    }

    func endKeeping() -> [Float] {
        lock.withLock {
            keeping = false
            defer { kept = [] }
            return kept
        }
    }

    var keptSeconds: Double { lock.withLock { Double(kept.count) / 16_000 } }

    private func startOnQueue() throws {
        guard !running else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            // Mixes, so a podcast keeps playing. No HFP on purpose: the keyboard is in your hand,
            // so the phone's mic is right there, and HFP would drop AirPods to call quality for
            // the whole session.
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            throw Failure.session(error.localizedDescription)
        }
        // The format can lag a moment behind the session, and a tap in a format the hardware isn't
        // running at is an uncatchable exception (it crashed Threadbear's Ask twice).
        var attempts = 0
        while true {
            let output = engine.inputNode.outputFormat(forBus: 0)
            guard output.sampleRate > 0, output.channelCount > 0 else { throw Failure.noMicrophone }
            if engine.inputNode.inputFormat(forBus: 0).sampleRate == output.sampleRate { break }
            attempts += 1
            if attempts > 20 { throw Failure.engine("the mic's format never settled") }
            Thread.sleep(forTimeInterval: 0.05)
        }
        try installTap()
        engine.prepare()
        do { try engine.start() } catch { throw Failure.engine(error.localizedDescription) }
        running = true
    }

    private func installTap() throws {
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: format, to: Self.target) else { throw Failure.engine("no converter") }
        self.converter = converter
        engine.inputNode.removeTap(onBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 1600, format: format) { [weak self] buffer, _ in
            self?.handle(buffer, converter: converter)
        }
    }

    /// A route change stops the engine and may change the format.
    private func restart() {
        guard running else { return }
        running = false
        do {
            try startOnQueue()
        } catch {
            onInterrupted?()
        }
    }

    private func handle(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: capacity) else { return }
        var served = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if served {
                status.pointee = .noDataNow
                return nil
            }
            served = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
        let isKeeping = lock.withLock {
            if keeping {
                kept += samples
            } else {
                preroll += samples
                let limit = Int(Capture.prerollSeconds * 16_000)
                if preroll.count > limit { preroll.removeFirst(preroll.count - limit) }
            }
            return keeping
        }
        if isKeeping, !samples.isEmpty {
            let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
            // Roughly -50 to -10 dB onto 0 to 1, about where a voice moves.
            let db = 20 * log10(max(rms, 1e-5))
            onLevel?(min(max((db + 50) / 40, 0), 1))
        }
    }
}

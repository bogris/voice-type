import AVFoundation
import Observation
import UIKit
import VoiceTypeCore
import VoiceTypeLink
import VoiceTypeWhisper

/// A session: the mic running and the model in memory, so the keyboard can dictate with no trip
/// to the app. Everything here runs on the main thread except whisper, which has its own queue.
@MainActor @Observable final class SessionEngine {
    static let shared = SessionEngine()

    private(set) var phase: LinkState.Phase = .off
    private(set) var sessionUntil: Date?
    private(set) var modelLoaded = false
    private(set) var problem: String?
    private(set) var history: [LinkResult] = []

    /// How long a session stays up after its last dictation.
    var minutes: Int {
        get { UserDefaults.standard.object(forKey: "sessionMinutes") as? Int ?? 15 }
        set { UserDefaults.standard.set(newValue, forKey: "sessionMinutes") }
    }

    @ObservationIgnored private let mic = MicInput()
    @ObservationIgnored private let store = LinkStore.shared() ?? LinkStore(folder: URL.documentsDirectory.appendingPathComponent("link"))
    @ObservationIgnored private let whisperQueue = DispatchQueue(label: "voicetype.whisper", qos: .userInitiated)
    @ObservationIgnored private nonisolated(unsafe) var engine: WhisperEngine?
    @ObservationIgnored private var beat: Timer?
    @ObservationIgnored private var capTimer: Timer?
    @ObservationIgnored private var request: UUID?
    @ObservationIgnored private var lastLevelWrite = Date.distantPast

    var keyboardSeen: Bool { store.keyboardSeen }

    private init() {
        history = store.history
        // A session can't outlive the process, so whatever the file says from last time is over.
        store.save(LinkState())
        LinkPing.start.observe { Task { @MainActor in SessionEngine.shared.beginListening() } }
        LinkPing.stop.observe { Task { @MainActor in SessionEngine.shared.finishListening() } }
        mic.onLevel = { [store] level in store.save(level: level) }
        mic.onInterrupted = { Task { @MainActor in SessionEngine.shared.endSession(because: "Audio was interrupted") } }
        recoverPending()
    }

    // MARK: Session

    func startSession() async {
        guard phase == .off else {
            extend()
            return
        }
        problem = nil
        guard await AVAudioApplication.requestRecordPermission() else {
            problem = "Microphone access is off"
            return
        }
        guard ModelStore.isInstalled else {
            problem = "The model isn't downloaded yet"
            return
        }
        do {
            try await mic.start()
        } catch {
            problem = "\(error)"
            return
        }
        phase = .ready
        extend()
        loadModel()
        beat?.invalidate()
        // The common run loop mode, so a scrolling list in the app doesn't stop the heartbeat.
        let timer = Timer(timeInterval: 1, repeats: true) { _ in Task { @MainActor in SessionEngine.shared.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        beat = timer
        publish()
    }

    func endSession(because reason: String? = nil) {
        guard phase != .off else { return }
        // Whatever was being said still gets transcribed: the model unloads when it's done.
        if phase == .listening { finishListening() }
        beat?.invalidate()
        beat = nil
        capTimer?.invalidate()
        mic.stop()
        phase = .off
        sessionUntil = nil
        problem = reason
        publish()
        whisperQueue.async { [self] in
            engine = nil
            DispatchQueue.main.async { self.modelLoaded = false }
        }
    }

    private func extend() {
        sessionUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
        publish()
    }

    private func tick() {
        if let sessionUntil, Date() > sessionUntil, phase == .ready {
            endSession()
            return
        }
        publish()
    }

    private func publish() {
        store.save(LinkState(phase: phase, heartbeat: phase == .off ? .distantPast : Date(), sessionUntil: sessionUntil, problem: problem))
        LinkPing.state.post()
    }

    private func loadModel() {
        whisperQueue.async { [self] in
            guard engine == nil else { return }
            do {
                // No GPU: iOS refuses GPU work from the background, and that's where this runs.
                // The Core ML encoder beside the weights takes the heavy step to the Neural Engine.
                let loaded = try WhisperEngine(modelPath: ModelStore.weightsURL.path, useGPU: false, threads: Self.threads)
                engine = loaded
                DispatchQueue.main.async { self.modelLoaded = true }
            } catch {
                let text = "\(error)"
                DispatchQueue.main.async {
                    self.problem = text
                    self.publish()
                }
            }
        }
    }

    /// The A17 Pro has two fast cores and four slow ones, and whisper's threads wait for the
    /// slowest, so two should beat more. Two is measured (0.9 s on short clips, 1 Nov 2026);
    /// more threads haven't been timed against it.
    private nonisolated static let threads: Int32 = 2

    // MARK: Listening

    func beginListening() {
        guard phase == .ready else { return }
        request = store.request?.id
        mic.beginKeeping()
        phase = .listening
        publish()
        capTimer?.invalidate()
        let timer = Timer(timeInterval: Capture.maxSeconds, repeats: false) { _ in Task { @MainActor in SessionEngine.shared.finishListening() } }
        RunLoop.main.add(timer, forMode: .common)
        capTimer = timer
    }

    func finishListening() {
        guard phase == .listening else { return }
        capTimer?.invalidate()
        let samples = mic.endKeeping()
        store.save(level: 0)
        phase = .transcribing
        extend()
        let request = request
        spool(samples)
        transcribe(samples, request: request)
    }

    private func transcribe(_ samples: [Float], request: UUID?) {
        let settings = Words.load()
        whisperQueue.async { [self] in
            let started = Date()
            var text = ""
            var failure: String?
            if let engine {
                do {
                    let options = TranscribeOptions(promptTokens: engine.promptTokens(for: settings.vocabularyPrompt))
                    text = try DictationPipeline(engine: engine, settings: settings, options: options).run(samples).text
                } catch {
                    failure = "\(error)"
                }
            } else {
                failure = "The model isn't loaded"
            }
            let took = Date().timeIntervalSince(started)
            DispatchQueue.main.async { self.finished(text: text, failure: failure, samples: samples, took: took, request: request) }
        }
    }

    private func finished(text: String, failure: String?, samples: [Float], took: TimeInterval, request: UUID?) {
        if failure == nil { clearSpool() }
        problem = failure
        if !text.isEmpty {
            store.append(LinkResult(request: request, text: text, seconds: Double(samples.count) / 16_000, transcribeSeconds: took))
            history = store.history
        }
        if phase == .transcribing { phase = .ready }
        publish()
        LinkPing.result.post()
    }

    // MARK: Not losing words

    private var spoolFile: URL { URL.documentsDirectory.appendingPathComponent("pending.f32") }

    /// On disk before whisper starts, as this is the moment iOS is likeliest to kill the app: it
    /// has just asked for a lot of memory from the background.
    private func spool(_ samples: [Float]) {
        samples.withUnsafeBytes { try? Data($0).write(to: spoolFile, options: .atomic) }
    }

    private func clearSpool() {
        try? FileManager.default.removeItem(at: spoolFile)
    }

    /// Anything left from a run that died goes into the history next time, never into a field.
    private func recoverPending() {
        guard let data = try? Data(contentsOf: spoolFile), !data.isEmpty, ModelStore.isInstalled else { return }
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        loadModel()
        transcribe(samples, request: nil)
    }

    func refreshHistory() {
        history = store.history
    }

    func clearHistory() {
        store.clearHistory()
        history = []
    }
}

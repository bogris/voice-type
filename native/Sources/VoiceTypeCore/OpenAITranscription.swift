import Foundation

/// Transport boundary: tests use scripted events and never connect to the network.
public protocol TranscriptionSocket: AnyObject {
    func send(_ event: [String: Any]) throws
    func receive() throws -> [String: Any]
    func close()
}

public enum OpenAITranscriptionError: LocalizedError {
    case missingKey, failed, timeout, invalidEvent
    public var errorDescription: String? {
        switch self {
        case .missingKey: return "Add an OpenAI API key in Settings > General."
        case .failed: return "OpenAI transcription failed. Check your API key, account credits and model access."
        case .timeout: return "OpenAI transcription timed out. Check your internet connection."
        case .invalidEvent: return "OpenAI returned an invalid transcription event."
        }
    }
}

/// Uses the Realtime transcription protocol for one push-to-talk clip after release.
/// Deliberately disables repeated preview uploads. No audio leaves the Mac in local mode.
public final class OpenAITranscriptionEngine: DictationEngine {
    public static let model = "gpt-live-transcribe"
    public var supportsPreviews: Bool { false }
    public var transcriptionEngineName: String { Self.model }
    private let apiKey: () throws -> String
    private let connect: (String) throws -> TranscriptionSocket

    public init(apiKey: @escaping () throws -> String,
                connect: @escaping (String) throws -> TranscriptionSocket = { try OpenAIWebSocket(apiKey: $0) }) {
        self.apiKey = apiKey
        self.connect = connect
    }

    public func promptTokens(for prompt: String?) -> [Int32] { (prompt ?? "").utf8.map { Int32($0) } }
    public func transcribe(_ samples: [Float], options: TranscribeOptions) throws -> Transcript {
        try transcribe(samples, options: options, abort: nil)
    }
    public func transcribe(_ samples: [Float], options: TranscribeOptions, abort: AbortFlag?) throws -> Transcript {
        // A wake-up probe must neither upload silence nor depend on connectivity.
        guard !samples.isEmpty, samples.contains(where: { $0 != 0 }), abort?.isSet != true else { return Transcript(segments: []) }
        let key = try apiKey().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw OpenAITranscriptionError.missingKey }
        let socket = try connect(key)
        defer { socket.close() }
        var transcription: [String: Any] = ["model": Self.model]
        let prompt = String(decoding: options.promptTokens.compactMap { UInt8(exactly: $0) }, as: UTF8.self)
        if !prompt.isEmpty { transcription["prompt"] = prompt }
        try socket.send(["type": "session.update", "session": ["type": "transcription", "audio": ["input": [
            "format": ["type": "audio/pcm", "rate": 24000], "transcription": transcription, "turn_detection": NSNull()
        ]]]])
        while true {
            let event = try socket.receive()
            try Self.check(event)
            if event["type"] as? String == "session.updated" { break }
        }
        // Capture is mono float32 at 16 kHz. Resample to the API's mono PCM16 at 24 kHz.
        let count = samples.count * 3 / 2
        var pcm = Data(capacity: count * 2)
        for index in 0..<count {
            let position = Double(index) * 2 / 3
            let left = min(Int(position), samples.count - 1)
            let right = min(left + 1, samples.count - 1)
            let fraction = Float(position - Double(left))
            let value = samples[left] + (samples[right] - samples[left]) * fraction
            let finite = value.isFinite ? value : 0
            let integer = Int16((min(1, max(-1, finite)) * 32767).rounded())
            let bits = UInt16(bitPattern: integer)
            pcm.append(UInt8(truncatingIfNeeded: bits))
            pcm.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        for start in stride(from: 0, to: pcm.count, by: 9600) {
            try socket.send(["type": "input_audio_buffer.append", "audio": pcm.subdata(in: start..<min(start + 9600, pcm.count)).base64EncodedString()])
        }
        try socket.send(["type": "input_audio_buffer.commit"])
        var itemID: String?
        while true {
            let event = try socket.receive()
            try Self.check(event)
            let type = event["type"] as? String
            if type == "input_audio_buffer.committed" { itemID = event["item_id"] as? String }
            if type == "conversation.item.input_audio_transcription.completed", let itemID,
               event["item_id"] as? String == itemID, let text = event["transcript"] as? String {
                return Transcript(segments: [.init(text: text, startSec: 0, endSec: Double(samples.count) / 16000,
                                                   noSpeechProb: 0, tokenProbs: [])])
            }
        }
    }
    private static func check(_ event: [String: Any]) throws {
        let type = event["type"] as? String
        if type == "error" || type == "conversation.item.input_audio_transcription.failed" {
            // Do not log server payloads, which can contain audio context or credentials.
            throw OpenAITranscriptionError.failed
        }
    }
}

/// One bounded connection per clip, closed on success, failure or timeout.
public final class OpenAIWebSocket: TranscriptionSocket {
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    // Finish before the controller's minimum 30-second finalisation watchdog.
    private let deadline = Date(timeIntervalSinceNow: 20)
    public init(apiKey: String) throws {
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
        task = session.webSocketTask(with: request)
        task.resume()
    }
    public func send(_ event: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: event)
        let message = String(decoding: data, as: UTF8.self)
        let task = task
        let _: Bool = try wait { try await task.send(.string(message)); return true }
    }
    public func receive() throws -> [String: Any] {
        let task = task
        let message = try wait { try await task.receive() }
        let data: Data
        switch message {
        case .data(let bytes): data = bytes
        case .string(let string): data = Data(string.utf8)
        @unknown default: throw OpenAITranscriptionError.invalidEvent
        }
        guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OpenAITranscriptionError.invalidEvent }
        return event
    }
    public func close() { task.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
    private final class ResultBox<T>: @unchecked Sendable {
        let lock = NSLock()
        var value: Result<T, Error>?
        func set(_ result: Result<T, Error>) { lock.withLock { value = result } }
        func get() -> Result<T, Error>? { lock.withLock { value } }
    }
    private func wait<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let result = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        let work = Task {
            do { result.set(.success(try await operation())) } catch { result.set(.failure(error)) }
            done.signal()
        }
        guard done.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .success else {
            work.cancel()
            close()
            throw OpenAITranscriptionError.timeout
        }
        return try result.get()!.get()
    }
}

import Foundation
import Testing
@testable import VoiceTypeCore

private final class FakeTranscriptionSocket: TranscriptionSocket {
    var sent: [[String: Any]] = []
    var events: [[String: Any]] = []
    var closed = false
    func send(_ event: [String: Any]) throws { sent.append(event) }
    func receive() throws -> [String: Any] { events.removeFirst() }
    func close() { closed = true }
}

struct OpenAITranscriptionTests {
    @Test func defaultsToLocalAndPreservesOtherSettings() throws {
        var file = SettingsFile(url: URL(fileURLWithPath: "/unused"), json: .object([("legacy", .string("keep"))]))
        #expect(file.transcriptionProvider == .whisper)
        file.setNative("transcription_provider", .string("openai"))
        #expect(file.transcriptionProvider == .openai)
        #expect(file.json["legacy"] == .string("keep"))
        file.setNative("transcription_provider", .string("unknown"))
        #expect(file.transcriptionProvider == .whisper)
    }

    @Test func sendsPCMAndWaitsForMatchingFinalTranscript() throws {
        let socket = FakeTranscriptionSocket()
        socket.events = [["type": "session.created"], ["type": "session.updated"],
                         ["type": "input_audio_buffer.committed", "item_id": "ours"],
                         ["type": "conversation.item.input_audio_transcription.completed", "item_id": "other", "transcript": "wrong"],
                         ["type": "conversation.item.input_audio_transcription.completed", "item_id": "ours", "transcript": "Salut, hello!"]]
        let engine = OpenAITranscriptionEngine(apiKey: { "test-key" }, connect: { _ in socket })
        let result = try engine.transcribe([Float](repeating: 0.5, count: 16000), options: .init())
        #expect(result.text == "Salut, hello!")
        #expect(result.segments.first?.endSec == 1)
        #expect(socket.closed)
        #expect(socket.sent.first?["type"] as? String == "session.update")
        let chunks = socket.sent.filter { $0["type"] as? String == "input_audio_buffer.append" }
        let bytes = chunks.reduce(0) { $0 + Data(base64Encoded: $1["audio"] as! String)!.count }
        #expect(bytes == 48000)
        #expect(socket.sent.last?["type"] as? String == "input_audio_buffer.commit")
    }

    @Test func silentWarmUpDoesNotConnect() throws {
        let engine = OpenAITranscriptionEngine(apiKey: { "" }, connect: { _ in
            Issue.record("A wake probe must stay offline")
            return FakeTranscriptionSocket()
        })
        #expect(try engine.transcribe([Float](repeating: 0, count: 8000), options: .init()).text.isEmpty)
    }

    @Test func missingKeyDoesNotConnect() {
        let engine = OpenAITranscriptionEngine(apiKey: { " " }, connect: { _ in
            Issue.record("Should not connect without a key")
            return FakeTranscriptionSocket()
        })
        #expect(throws: OpenAITranscriptionError.self) { try engine.transcribe([0.1], options: .init()) }
    }

    @Test func reportsFailureAndClosesConnection() {
        let socket = FakeTranscriptionSocket()
        socket.events = [["type": "error"]]
        let engine = OpenAITranscriptionEngine(apiKey: { "test" }, connect: { _ in socket })
        #expect(throws: OpenAITranscriptionError.self) { try engine.transcribe([0.1], options: .init()) }
        #expect(socket.closed)
    }
}

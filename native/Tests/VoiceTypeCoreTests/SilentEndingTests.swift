import Testing
@testable import VoiceTypeCore

/// AudioGate.droppingSilentEnding, with levels taken from real dictations that ended in a
/// made-up "Thank you." or "Okay." (24 October to 4 November 2026).
struct SilentEndingTests {
    /// `seconds` of a tone peaking at `peak`, the stand-in for speech or room noise.
    func tone(_ seconds: Double, peak: Float) -> [Float] {
        (0..<Int(seconds * Double(sampleRate))).map { $0 % 2 == 0 ? peak : -peak }
    }

    func segment(_ text: String, _ start: Double, _ end: Double, firstProb: Double) -> TranscriptSegment {
        TranscriptSegment(text: text, startSec: start, endSec: end, noSpeechProb: 0, tokenProbs: [firstProb, 0.99])
    }

    @Test func dropsThankYouOverTheSilenceAfterThirtySeconds() {
        // 20261104T014326: speech to 30 s at 0.095, then room noise; Whisper 33% sure.
        let samples = tone(30, peak: 0.095) + tone(2.16, peak: 0.0027)
        let whole = Transcript(segments: [
            segment(" So I'll have to fly from Perth again.", 0, 29.8, firstProb: 0.98),
            segment(" Thank you.", 30, 32.14, firstProb: 0.33),
        ])
        let (kept, dropped) = AudioGate.droppingSilentEnding(whole, samples: samples)
        #expect(kept.text == "So I'll have to fly from Perth again.")
        #expect(dropped.map(\.text) == [" Thank you."])
    }

    @Test func looksPastTheEndOfTheRealSentenceForStockPhrases() {
        // 20261030T015756: Whisper starts "Okay." at 17.5 s, where "together." is still
        // finishing (0.049 for 0.1 s), then 1.4 s of room.
        let samples = tone(17.6, peak: 0.099) + tone(1.42, peak: 0.003)
        let whole = Transcript(segments: [
            segment(" I think maybe we merge them together.", 0, 17.5, firstProb: 0.9),
            segment(" Okay.", 17.5, 19.02, firstProb: 0.51),
        ])
        #expect(AudioGate.droppingSilentEnding(whole, samples: samples).kept.text == "I think maybe we merge them together.")
    }

    @Test func dropsAnySilentLowConfidenceEnding() {
        // 20261029T055633: "Yeah." over 1.5 s of room. Not a stock phrase, so no grace.
        let samples = tone(9.38, peak: 0.057) + tone(1.5, peak: 0.0021)
        let whole = Transcript(segments: [
            segment(" Can you check it?", 0, 3.38, firstProb: 0.95),
            segment(" Yeah.", 9.38, 10.88, firstProb: 0.2),
        ])
        #expect(AudioGate.droppingSilentEnding(whole, samples: samples).dropped.count == 1)
    }

    @Test func keepsARealQuietYeah() {
        // 20261026T232208: a real "Yeah." at 0.04 after speech at 0.059, Whisper 31% sure.
        let samples = tone(5.24, peak: 0.059) + tone(0.52, peak: 0.04)
        let whole = Transcript(segments: [
            segment(" Ship it.", 0, 5.24, firstProb: 0.95),
            segment(" Yeah.", 5.24, 5.76, firstProb: 0.31),
        ])
        #expect(AudioGate.droppingSilentEnding(whole, samples: samples).dropped.isEmpty)
    }

    @Test func keepsAnEndingWhisperIsSureOf() {
        let samples = tone(5, peak: 0.1) + tone(1, peak: 0.002)
        let whole = Transcript(segments: [
            segment(" Merge them all.", 0, 5, firstProb: 0.99),
            segment(" Thank you.", 5, 6, firstProb: 0.9),
        ])
        #expect(AudioGate.droppingSilentEnding(whole, samples: samples).dropped.isEmpty)
    }

    @Test func keepsASaidOkayAfterTheGrace() {
        // A real "Okay." goes on past the first 0.2 s at speaking level.
        let samples = tone(5, peak: 0.1) + tone(0.5, peak: 0.06) + tone(0.5, peak: 0.002)
        let whole = Transcript(segments: [
            segment(" That looks right.", 0, 5, firstProb: 0.99),
            segment(" Okay.", 5, 6, firstProb: 0.4),
        ])
        #expect(AudioGate.droppingSilentEnding(whole, samples: samples).dropped.isEmpty)
    }

    @Test func keepsTheEndingOnAQuietMicrophone() {
        // Under 0.008, but not much quieter than the speech, so it's real speech turned down.
        let samples = tone(5, peak: 0.02) + tone(1, peak: 0.006)
        let whole = Transcript(segments: [
            segment(" Same here.", 0, 5, firstProb: 0.99),
            segment(" Yes.", 5, 6, firstProb: 0.4),
        ])
        #expect(AudioGate.droppingSilentEnding(whole, samples: samples).dropped.isEmpty)
    }

    @Test func neverDropsTheOnlySegment() {
        // A whole silent clip is isLongNearSilentClip's job.
        let whole = Transcript(segments: [segment(" Thank you.", 0, 2, firstProb: 0.2)])
        #expect(AudioGate.droppingSilentEnding(whole, samples: tone(2, peak: 0.002)).dropped.isEmpty)
    }

    @Test func pipelineTypesTheSentenceButKeepsWhatWhisperSaid() throws {
        let engine = SegmentEngine([
            segment(" Potentially discuss.", 0, 79.8, firstProb: 0.97),
            segment(" Thank you.", 79.98, 80.48, firstProb: 0.24),
        ])
        let pipeline = DictationPipeline(engine: engine, settings: VoiceTypeSettings(vocabulary: [], corrections: .pythonDefaults), options: TranscribeOptions())
        let result = try pipeline.run(tone(79.98, peak: 0.178) + tone(0.5, peak: 0.0044))
        #expect(result.text == "Potentially discuss.")
        #expect(result.rawTranscript == "Potentially discuss. Thank you.")
        #expect(result.transcript?.segments.count == 1)
        #expect(result.droppedEnding.map(\.text) == [" Thank you."])
    }
}

final class SegmentEngine: SpeechEngine {
    let segments: [TranscriptSegment]
    init(_ segments: [TranscriptSegment]) { self.segments = segments }
    func transcribe(_ samples: [Float], options: TranscribeOptions) throws -> Transcript { Transcript(segments: segments) }
}

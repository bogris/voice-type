import AVFoundation
import Foundation
import os
import UIKit
import VoiceTypeCore
import VoiceTypeWhisper

/// Timing runs on the real phone, driven from the Mac:
///   devicectl device process launch ... com.mikecann.voicetype -- --bench
/// Reads Documents/bench/*.wav and writes Documents/bench-results.json. Recordings get copied in
/// by hand and are never in the repo.
enum Bench {
    static var isRequested: Bool { CommandLine.arguments.contains("--bench") }

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    private static func arg(_ name: String) -> String? {
        let args = CommandLine.arguments
        return args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }

    @MainActor private static var keepAlive: AVAudioEngine?

    /// Plays silence, which is what entitles the app to keep running behind other apps, the way
    /// the mic does in a real session. So these timings are real background ones, and no mic
    /// permission is needed to take them.
    @MainActor private static func stayAwake() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let engine = AVAudioEngine()
        let source = AVAudioSourceNode { _, _, _, list in
            for buffer in UnsafeMutableAudioBufferListPointer(list) { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = 0
        try? engine.start()
        keepAlive = engine
    }

    @MainActor static func run() {
        stayAwake()
        let threads = Int32(arg("--threads") ?? "") ?? 4
        let gpu = CommandLine.arguments.contains("--gpu")
        let tag = arg("--tag") ?? "run"
        let delay = Double(arg("--delay") ?? "") ?? 0
        let folder = URL.documentsDirectory.appendingPathComponent("bench")
        let out = URL.documentsDirectory.appendingPathComponent("bench-results-\(tag).json")
        var report: [String: Any] = ["threads": threads, "gpu": gpu, "started": Date().timeIntervalSince1970]
        func save() {
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: out, options: .atomic)
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Time for the Mac to push the app behind another, to measure the background.
                Thread.sleep(forTimeInterval: delay)
                report["footprintBeforeMB"] = footprintMB()
                let engine = try WhisperEngine(modelPath: ModelStore.weightsURL.path, useGPU: gpu, threads: threads)
                report["loadMs"] = engine.loadMilliseconds
                report["footprintLoadedMB"] = footprintMB()
                save()
                let settings = Words.load()
                let options = TranscribeOptions(promptTokens: engine.promptTokens(for: settings.vocabularyPrompt))
                var rows: [[String: Any]] = []
                let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
                    .filter { $0.pathExtension == "wav" }.sorted { $0.path < $1.path } ?? []
                for file in files {
                    let samples = try WAVReader.read(file)
                    let started = DispatchTime.now()
                    let text = try engine.transcribe(samples, options: options).text
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
                    let state = DispatchQueue.main.sync { UIApplication.shared.applicationState == .background ? "background" : "foreground" }
                    rows.append(["state": state, "file": file.lastPathComponent, "audioSec": Double(samples.count) / 16_000, "ms": ms, "text": text])
                    report["rows"] = rows
                    report["footprintMB"] = footprintMB()
                    save()
                }
                report["finished"] = true
            } catch {
                report["error"] = "\(error)"
            }
            save()
        }
    }
}

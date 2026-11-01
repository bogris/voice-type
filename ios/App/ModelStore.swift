import CryptoKit
import Foundation
import Observation
import VoiceTypeLink

/// The two model files, from Hugging Face at a pinned commit. Whisper's weights are what the
/// Mac runs; the Core ML encoder lets whisper.cpp run its slowest step on the Neural Engine,
/// which is what works from the background, where iOS forbids the GPU.
@Observable final class ModelStore: NSObject, @unchecked Sendable, URLSessionDownloadDelegate {
    static let shared = ModelStore()
    private static let commit = "5359861c739e955e79d9a303bcbc70fb988958b1"
    private static let base = "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(commit)/"

    struct File: Sendable {
        let remote: String
        let sha256: String
        let bytes: Int64
    }

    static let weights = File(remote: "ggml-large-v3-turbo-q8_0.bin", sha256: "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1", bytes: 874_188_075)
    static let encoder = File(remote: "ggml-large-v3-turbo-encoder.mlmodelc.zip", sha256: "84bedfe895bd7b5de6e8e89a0803dfc5addf8c0c5bc4c937451716bf7cf7988a", bytes: 1_173_393_014)

    static var folder: URL {
        let url = URL.documentsDirectory.appendingPathComponent("models")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var weightsURL: URL { folder.appendingPathComponent(weights.remote) }
    /// whisper.cpp looks for this name beside the weights, with the "-q8_0" dropped.
    static var encoderURL: URL { folder.appendingPathComponent("ggml-large-v3-turbo-encoder.mlmodelc") }
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: weightsURL.path) && FileManager.default.fileExists(atPath: encoderURL.path)
    }

    private(set) var installed = ModelStore.isInstalled
    private(set) var progress: Double?
    private(set) var problem: String?
    @ObservationIgnored var backgroundCompletion: (() -> Void)?

    @ObservationIgnored private var received: [String: Int64] = [:]
    @ObservationIgnored private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.mikecann.voicetype.models")
        // Two gigabytes shouldn't go over mobile data unasked.
        config.allowsCellularAccess = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func refresh() {
        installed = Self.isInstalled
    }

    func download() {
        problem = nil
        progress = 0
        session.getAllTasks { [self] tasks in
            let running = Set(tasks.compactMap { $0.taskDescription })
            if !FileManager.default.fileExists(atPath: Self.weightsURL.path), !running.contains(Self.weights.remote) { start(Self.weights) }
            if !FileManager.default.fileExists(atPath: Self.encoderURL.path), !running.contains(Self.encoder.remote) { start(Self.encoder) }
        }
    }

    private func start(_ file: File) {
        let task = session.downloadTask(with: URL(string: Self.base + file.remote)!)
        task.taskDescription = file.remote
        task.resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten written: Int64, totalBytesExpectedToWrite _: Int64) {
        guard let name = downloadTask.taskDescription else { return }
        let total = Double(Self.weights.bytes + Self.encoder.bytes)
        DispatchQueue.main.async { [self] in
            received[name] = written
            let already = (FileManager.default.fileExists(atPath: Self.weightsURL.path) ? Self.weights.bytes : 0)
                + (FileManager.default.fileExists(atPath: Self.encoderURL.path) ? Self.encoder.bytes : 0)
            progress = min(Double(already + received.values.reduce(0, +)) / total, 1)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file vanishes when this returns, so it moves before anything else happens.
        let held = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard let name = downloadTask.taskDescription, (try? FileManager.default.moveItem(at: location, to: held)) != nil else { return }
        defer { try? FileManager.default.removeItem(at: held) }
        do {
            let file = name == Self.weights.remote ? Self.weights : Self.encoder
            guard try Self.sha256(of: held) == file.sha256 else { throw CocoaError(.fileReadCorruptFile) }
            if file.remote == Self.weights.remote {
                try FileManager.default.moveItem(at: held, to: Self.weightsURL)
            } else {
                try MiniUnzip.extract(held, to: Self.folder)
            }
            excludeFromBackup()
        } catch {
            DispatchQueue.main.async { self.problem = "\(name): \(error.localizedDescription)" }
        }
        DispatchQueue.main.async { [self] in
            refresh()
            if installed { progress = nil }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        DispatchQueue.main.async { [self] in
            problem = error.localizedDescription
            progress = nil
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [self] in
            backgroundCompletion?()
            backgroundCompletion = nil
        }
    }

    /// Reconnects to a download still running from before the app last quit.
    func reconnect() {
        _ = session
    }

    /// Two gigabytes that can always be fetched again don't belong in an iCloud backup.
    func excludeFromBackup() {
        var folder = Self.folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

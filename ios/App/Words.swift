import Foundation
import VoiceTypeCore

/// The word list and corrections, in the app's Documents. Not in the repo, which is public:
/// `scripts/push-data.sh` copies them over from the Mac's settings.json.
enum Words {
    static var settingsFile: URL { URL.documentsDirectory.appendingPathComponent("settings.json") }

    /// The Mac's parser, so the phone reads settings.json the same way, defaults included.
    static func load() -> VoiceTypeSettings { VoiceTypeSettings.load(from: settingsFile) }

    static var list: [String] { load().vocabulary ?? [] }

    /// Rewrites the word list and leaves everything else in the file as it was.
    static func save(_ words: [String]) {
        var json = (try? Data(contentsOf: settingsFile)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        json["vocabulary"] = words
        if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) {
            try? data.write(to: settingsFile, options: .atomic)
        }
    }
}

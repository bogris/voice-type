import Foundation

/// The App Group folder, and reading and writing what's in it.
public struct LinkStore: Sendable {
    public static let groupID = "group.com.mikecann.voicetype"
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Nil when the keyboard doesn't have Full Access, which is what the group folder needs.
    public static func shared() -> LinkStore? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID).map(LinkStore.init(folder:))
    }

    private var stateFile: URL { folder.appendingPathComponent("state.json") }
    private var requestFile: URL { folder.appendingPathComponent("request.json") }
    private var historyFile: URL { folder.appendingPathComponent("history.json") }
    private var levelFile: URL { folder.appendingPathComponent("level") }
    private var pendingFile: URL { folder.appendingPathComponent("autostart") }
    private var seenFile: URL { folder.appendingPathComponent("keyboard-seen") }

    private func read<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, _ url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        // Atomic, as the other process can read at any moment.
        if let data = try? encoder.encode(value) { try? data.write(to: url, options: .atomic) }
    }

    public var state: LinkState { read(LinkState.self, stateFile) ?? LinkState() }
    public func save(_ state: LinkState) { write(state, stateFile) }

    public var request: LinkRequest? { read(LinkRequest.self, requestFile) }
    public func save(_ request: LinkRequest) { write(request, requestFile) }

    // MARK: History

    public static let historyLimit = 100
    public var history: [LinkResult] { read([LinkResult].self, historyFile) ?? [] }

    /// Newest first. It's also how a result reaches the keyboard, so nothing said is ever only in memory.
    public func append(_ result: LinkResult) {
        write(Array(([result] + history).prefix(Self.historyLimit)), historyFile)
    }

    public func clearHistory() { write([LinkResult](), historyFile) }

    // MARK: Level

    /// 0 to 1. Rewritten ten times a second while listening, so not atomic and not JSON: a torn
    /// read is one wrong bar on the meter.
    public var level: Float {
        guard let data = try? Data(contentsOf: levelFile), data.count == 4 else { return 0 }
        return data.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
    }

    public func save(level: Float) {
        var value = level
        try? Data(bytes: &value, count: 4).write(to: levelFile)
    }

    // MARK: Start after the trip to the app

    /// The mic was tapped with no session, so the keyboard went to the app. Start listening when it comes back.
    public func markAutostart(at now: Date = Date()) { write(now, pendingFile) }

    /// True once, and only if the tap was recent: returning an hour later shouldn't turn the mic on.
    public func takeAutostart(now: Date = Date(), within: TimeInterval = 60) -> Bool {
        guard let at = read(Date.self, pendingFile) else { return false }
        try? FileManager.default.removeItem(at: pendingFile)
        return now.timeIntervalSince(at) < within
    }

    // MARK: Setup

    /// iOS won't tell an app whether its keyboard has been added, so the keyboard reports in.
    public func markKeyboardSeen() {
        if !FileManager.default.fileExists(atPath: seenFile.path) { write(Date(), seenFile) }
    }

    public var keyboardSeen: Bool { FileManager.default.fileExists(atPath: seenFile.path) }
}

/// Pings between the app and the keyboard. Darwin notifications carry no data, the store does.
public enum LinkPing: String, CaseIterable, Sendable {
    case start = "com.mikecann.voicetype.start"
    case stop = "com.mikecann.voicetype.stop"
    case state = "com.mikecann.voicetype.state"
    case result = "com.mikecann.voicetype.result"

    public func post() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(rawValue as CFString), nil, nil, true)
    }

    /// Watching lasts for the life of the process, which is all either side needs.
    public func observe(_ handler: @escaping @Sendable () -> Void) {
        let box = Unmanaged.passRetained(PingBox(handler)).toOpaque()
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), box, { _, observer, _, _, _ in
            guard let observer else { return }
            Unmanaged<PingBox>.fromOpaque(observer).takeUnretainedValue().handler()
        }, rawValue as CFString, nil, .deliverImmediately)
    }
}

private final class PingBox: Sendable {
    let handler: @Sendable () -> Void
    init(_ handler: @escaping @Sendable () -> Void) { self.handler = handler }
}

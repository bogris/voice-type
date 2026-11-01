import Foundation

/// What the app tells the keyboard, as one small file in the App Group folder.
///
/// A file and not UserDefaults, as a suite's values can be stale across processes, and a keyboard
/// that believes a dead session is alive would swallow a tap.
public struct LinkState: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        /// No session: the mic is off and the model isn't loaded.
        case off
        /// The mic is running but its audio is thrown away, apart from a short pre-roll.
        case ready
        case listening
        case transcribing
    }

    public var phase: Phase
    /// Written every second while a session is on. If the app is killed the writes stop, which
    /// is the only way the keyboard can tell.
    public var heartbeat: Date
    public var sessionUntil: Date?
    public var problem: String?

    public init(phase: Phase = .off, heartbeat: Date = .distantPast, sessionUntil: Date? = nil, problem: String? = nil) {
        self.phase = phase
        self.heartbeat = heartbeat
        self.sessionUntil = sessionUntil
        self.problem = problem
    }

    /// A few missed beats, not one: the app can stall for a moment while whisper is busy.
    public static let heartbeatTimeout: TimeInterval = 4

    /// Whether the app is alive and holding the mic. iOS won't let an app start the mic from the
    /// background, so when this is false the only way forward is a trip to the app.
    public func isLive(at now: Date) -> Bool {
        guard phase != .off, now.timeIntervalSince(heartbeat) < Self.heartbeatTimeout else { return false }
        return true
    }
}

/// A finished dictation. `request` says which mic tap it answers, so a keyboard only types what
/// it asked for and a late result can't land in a field the user has since moved to.
public struct LinkResult: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var request: UUID?
    public var text: String
    public var at: Date
    public var seconds: Double
    public var transcribeSeconds: Double

    public init(id: UUID = UUID(), request: UUID?, text: String, at: Date = Date(), seconds: Double, transcribeSeconds: Double) {
        self.id = id
        self.request = request
        self.text = text
        self.at = at
        self.seconds = seconds
        self.transcribeSeconds = transcribeSeconds
    }
}

/// What the keyboard asks of the app, read when the matching ping arrives.
public struct LinkRequest: Codable, Equatable, Sendable {
    public var id: UUID
    public var at: Date

    public init(id: UUID = UUID(), at: Date = Date()) {
        self.id = id
        self.at = at
    }
}

/// What a press on the mic should do. Pure so the odd cases can be tested without a keyboard.
public enum MicDecision: Equatable, Sendable {
    case openApp
    case startListening
    case stopListening
    case ignore

    public static func onTap(state: LinkState, now: Date) -> MicDecision {
        guard state.isLive(at: now) else { return .openApp }
        switch state.phase {
        case .ready: return .startListening
        case .listening: return .stopListening
        case .transcribing, .off: return .ignore
        }
    }
}

/// How dictated text joins what's already in the field.
public enum Insertion {
    /// A space when the text would otherwise run into the word before it. Whisper's own text
    /// has no leading space, and nothing else adds one.
    public static func text(_ text: String, after before: String?) -> String {
        guard let last = before?.last, !last.isWhitespace, !text.isEmpty else { return text }
        if let first = text.first, first.isPunctuation { return text }
        // After an opening bracket or quote the next word belongs up against it.
        if "([{\"'“‘".contains(last) { return text }
        return " " + text
    }
}

/// Pre-roll and cap, in one place so the app and tests agree.
public enum Capture {
    /// Audio kept from before the tap. The first word often starts as the finger lands.
    public static let prerollSeconds = 0.4
    /// The same cap as the Mac. Reaching it stops and transcribes, it doesn't throw anything away.
    public static let maxSeconds = 120.0
}

/// Held longer than this, the mic works as push to talk: letting go stops. Shorter is a tap.
public enum Press {
    public static let holdThreshold: TimeInterval = 0.35
}

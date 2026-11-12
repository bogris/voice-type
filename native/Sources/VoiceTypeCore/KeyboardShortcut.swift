/// Physical Mac key codes plus the four ordinary shortcut modifiers. Fn is ignored because
/// it is needed just to produce function-key events on many MacBook keyboards.
public struct KeyboardShortcut: Sendable, Equatable {
    public static let command: UInt64 = 1 << 20
    public static let option: UInt64 = 1 << 19
    public static let control: UInt64 = 1 << 18
    public static let shift: UInt64 = 1 << 17
    public static let modifierMask = command | option | control | shift
    public var keycode: Int64
    public var modifiers: UInt64
    public init(keycode: Int64, modifiers: UInt64 = 0) {
        self.keycode = keycode
        self.modifiers = modifiers & Self.modifierMask
    }
    public static let keys: [(code: Int64, title: String)] = [
        (0,"A"),(11,"B"),(8,"C"),(2,"D"),(14,"E"),(3,"F"),(5,"G"),(4,"H"),(34,"I"),(38,"J"),(40,"K"),(37,"L"),(46,"M"),
        (45,"N"),(31,"O"),(35,"P"),(12,"Q"),(15,"R"),(1,"S"),(17,"T"),(32,"U"),(9,"V"),(13,"W"),(7,"X"),(16,"Y"),(6,"Z"),
        (18,"1"),(19,"2"),(20,"3"),(21,"4"),(23,"5"),(22,"6"),(26,"7"),(28,"8"),(25,"9"),(29,"0"),(49,"Space"),
        (122,"F1"),(120,"F2"),(99,"F3"),(118,"F4"),(96,"F5"),(97,"F6"),(98,"F7"),(100,"F8"),(101,"F9"),(109,"F10"),
        (103,"F11"),(111,"F12"),(105,"F13"),(107,"F14"),(113,"F15"),(106,"F16"),(64,"F17"),(79,"F18"),(80,"F19"),(90,"F20")
    ]
    public var isValid: Bool {
        guard let key = Self.keys.first(where: { $0.code == keycode }) else { return false }
        // A bare letter or Space must never replace normal typing. Shift alone is typing too.
        return key.title.hasPrefix("F") && key.title.count > 1 || modifiers & (Self.command | Self.option | Self.control) != 0
    }
    public var title: String {
        (modifiers & Self.control != 0 ? "⌃" : "") + (modifiers & Self.option != 0 ? "⌥" : "") +
        (modifiers & Self.shift != 0 ? "⇧" : "") + (modifiers & Self.command != 0 ? "⌘" : "") +
        (Self.keys.first { $0.code == keycode }?.title ?? "Unknown")
    }
    var json: JSONValue { .object([("keycode", .int(Int(keycode))), ("modifiers", .int(Int(modifiers)))]) }
    init?(json: JSONValue?) {
        guard case let .number(codeText)? = json?["keycode"], let code = Int64(codeText),
              case let .number(flagsText)? = json?["modifiers"], let flags = UInt64(flagsText) else { return nil }
        self.init(keycode: code, modifiers: flags)
        guard isValid else { return nil }
    }
}

public struct ShortcutConfiguration: Sendable, Equatable {
    public var microphone: KeyboardShortcut
    public var meeting: KeyboardShortcut
    public var rightControl: Bool
    public init(microphone: KeyboardShortcut, meeting: KeyboardShortcut, rightControl: Bool = true) {
        self.microphone = microphone; self.meeting = meeting; self.rightControl = rightControl
    }
    public static let defaults = ShortcutConfiguration(microphone: .init(keycode: HotkeyState.f12), meeting: .init(keycode: HotkeyState.f11))
    public var isValid: Bool { microphone.isValid && meeting.isValid && microphone != meeting }
    public var json: JSONValue { .object([("microphone", microphone.json), ("meeting", meeting.json), ("right_control", .bool(rightControl))]) }
    public init?(json: JSONValue?) {
        guard let microphone = KeyboardShortcut(json: json?["microphone"]), let meeting = KeyboardShortcut(json: json?["meeting"]) else { return nil }
        self.init(microphone: microphone, meeting: meeting, rightControl: json?["right_control"]?.isTruthy ?? true)
        guard isValid else { return nil }
    }
}

/// Keep both assignments together until all old presses have ended. Updating one source
/// early could let its new shortcut steal the other source's release.
public struct ShortcutBindings: Sendable {
    public var microphone: HotkeyState
    public var meeting: HotkeyState
    private var pending: ShortcutConfiguration?
    public init(_ configuration: ShortcutConfiguration = .defaults) {
        microphone = HotkeyState(shortcuts: [configuration.microphone], rightControl: configuration.rightControl)
        meeting = HotkeyState(shortcuts: [configuration.meeting])
    }
    public mutating func update(_ configuration: ShortcutConfiguration) {
        guard configuration.isValid else { return }
        pending = configuration
    }
    public mutating func prepareForEvent() {
        guard !microphone.isDown, !meeting.isDown, let pending else { return }
        self = ShortcutBindings(pending)
    }
}

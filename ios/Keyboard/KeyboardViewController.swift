import SwiftUI
import UIKit
import VoiceTypeLink

/// The keyboard: a mic, and only what you need around it. No microphone is allowed in a keyboard
/// extension, so it asks the app to do the listening and types what comes back.
final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.controller = self
        let host = UIHostingController(rootView: KeyboardView(model: model))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.heightAnchor.constraint(equalToConstant: 240),
        ])
        host.didMove(toParent: self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.appeared(fullAccess: hasFullAccess, needsGlobe: needsInputModeSwitchKey)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        model.disappeared()
    }

    /// iOS blocks extensions from opening URLs, apart from via the app object up the responder
    /// chain, which is how every keyboard of this kind reaches its app.
    func openApp() {
        guard let url = URL(string: "voicetype://session") else { return }
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = current.next
        }
    }

    func insert(_ text: String) {
        textDocumentProxy.insertText(Insertion.text(text, after: textDocumentProxy.documentContextBeforeInput))
    }

    func deleteBackward() { textDocumentProxy.deleteBackward() }
    func insertRaw(_ text: String) { textDocumentProxy.insertText(text) }
}

@MainActor @Observable final class KeyboardModel {
    weak var controller: KeyboardViewController?
    var phase: LinkState.Phase = .off
    var level: Float = 0
    var fullAccess = true
    var needsGlobe = false
    /// A finished dictation that didn't get typed, ready to be dropped in with a tap.
    var waiting: LinkResult?
    var lastInserted: String?

    private let store = LinkStore.shared()
    private var activeRequest: UUID?
    private var handled: Set<UUID> = []
    private var timer: Timer?
    private var pressedAt: Date?
    private var pressStarted = false
    private var observing = false

    func appeared(fullAccess: Bool, needsGlobe: Bool) {
        self.fullAccess = fullAccess
        self.needsGlobe = needsGlobe
        guard let store, fullAccess else { return }
        store.markKeyboardSeen()
        if !observing {
            observing = true
            LinkPing.state.observe { Task { @MainActor [weak self] in self?.refresh() } }
            LinkPing.result.observe { Task { @MainActor [weak self] in self?.resultArrived() } }
        }
        // Anything that finished while this keyboard wasn't looking is offered, not typed.
        waiting = store.history.first.flatMap { Date().timeIntervalSince($0.at) < 120 ? $0 : nil }
        handled.formUnion(store.history.prefix(5).map(\.id))
        refresh()
        startPolling()
        // Back from the trip to the app: carry on with what the tap asked for.
        if store.takeAutostart(), store.state.isLive(at: Date()) { startListening() }
    }

    func disappeared() {
        // Never throw speech away. It finishes, lands in the history and is offered next time.
        if phase == .listening { LinkPing.stop.post() }
        timer?.invalidate()
        timer = nil
    }

    private func startPolling() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in Task { @MainActor [weak self] in self?.poll() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        if phase == .listening { level = store?.level ?? 0 }
        refresh()
    }

    private func refresh() {
        guard let store else { return }
        let state = store.state
        phase = state.isLive(at: Date()) ? state.phase : .off
    }

    private func startListening() {
        guard let store else { return }
        let request = LinkRequest()
        activeRequest = request.id
        store.save(request)
        LinkPing.start.post()
        waiting = nil
        phase = .listening
    }

    private func resultArrived() {
        guard let store, let result = store.history.first, !handled.contains(result.id) else { return }
        handled.insert(result.id)
        if result.request != nil, result.request == activeRequest {
            activeRequest = nil
            type(result)
        } else {
            waiting = result
        }
    }

    private func type(_ result: LinkResult) {
        controller?.insert(result.text)
        lastInserted = result.text
        waiting = nil
    }

    // MARK: Mic

    func micDown() {
        pressedAt = Date()
        pressStarted = false
        guard let store else { return }
        let state = store.state
        switch MicDecision.onTap(state: state, now: Date()) {
        case .openApp:
            store.markAutostart()
            controller?.openApp()
        case .startListening:
            pressStarted = true
            startListening()
        case .stopListening:
            LinkPing.stop.post()
        case .ignore:
            break
        }
    }

    /// A long press that started the mic is push to talk, so letting go stops it. A tap leaves it on.
    func micUp() {
        defer { pressedAt = nil }
        guard pressStarted, let pressedAt, Date().timeIntervalSince(pressedAt) >= Press.holdThreshold else { return }
        LinkPing.stop.post()
    }

    func dropInWaiting() {
        if let waiting { type(waiting) }
    }

    /// Takes the last dictation back out, one character at a time, as that's all a keyboard can do.
    func undo() {
        guard let lastInserted else { return }
        // The join may have added a space, and it should go too.
        let before = controller?.textDocumentProxy.documentContextBeforeInput ?? ""
        let extra = before.hasSuffix(" " + lastInserted) ? 1 : 0
        for _ in 0..<(lastInserted.count + extra) { controller?.deleteBackward() }
        self.lastInserted = nil
    }

    func globe() { controller?.advanceToNextInputMode() }
    func key(_ text: String) {
        lastInserted = nil
        controller?.insertRaw(text)
    }

    func backspace() {
        lastInserted = nil
        controller?.deleteBackward()
    }
}

struct KeyboardView: View {
    @Bindable var model: KeyboardModel

    var body: some View {
        VStack(spacing: 8) {
            if model.fullAccess { mic } else { fullAccessHint }
            HStack(spacing: 6) {
                if model.needsGlobe {
                    KeyButton(system: "globe") { model.globe() }
                }
                if model.lastInserted != nil {
                    KeyButton(system: "arrow.uturn.backward") { model.undo() }
                } else if model.waiting != nil {
                    KeyButton(system: "text.badge.plus") { model.dropInWaiting() }
                }
                KeyButton(label: ",") { model.key(",") }
                KeyButton(label: ".") { model.key(".") }
                KeyButton(system: "space") { model.key(" ") }.frame(maxWidth: .infinity)
                RepeatingKey(system: "delete.left") { model.backspace() }
                KeyButton(system: "return") { model.key("\n") }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fullAccessHint: some View {
        Image(systemName: "lock.fill")
            .font(.largeTitle)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Turn on Allow Full Access for Voice Type in Settings")
    }

    private var mic: some View {
        ZStack {
            // Grows with your voice, so you can see it's hearing you.
            if model.phase == .listening {
                Circle()
                    .fill(Color.red.opacity(0.2))
                    .frame(width: 96 + CGFloat(model.level) * 70, height: 96 + CGFloat(model.level) * 70)
                    .animation(.linear(duration: 0.1), value: model.level)
            }
            Circle()
                .fill(model.phase == .listening ? Color.red : Color.accentColor)
                .frame(width: 96, height: 96)
            if model.phase == .transcribing {
                ProgressView().tint(.white).controlSize(.large)
            } else {
                Image(systemName: model.phase == .listening ? "stop.fill" : "mic.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressing { pressing = true; model.micDown() } }
                .onEnded { _ in pressing = false; model.micUp() }
        )
        .accessibilityLabel(model.phase == .listening ? "Stop" : "Dictate")
        .accessibilityAddTraits(.isButton)
    }

    @State private var pressing = false
}

private struct KeyButton: View {
    var system: String?
    var label: String?
    let action: () -> Void

    init(system: String, action: @escaping () -> Void) {
        self.system = system
        self.action = action
    }

    init(label: String, action: @escaping () -> Void) {
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) { KeyFace(system: system, label: label) }
            .buttonStyle(.plain)
    }
}

/// Delete repeats while it's held, like the system keyboard's.
private struct RepeatingKey: View {
    let system: String
    let action: () -> Void
    @State private var timer: Timer?

    var body: some View {
        KeyFace(system: system, label: nil)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard timer == nil else { return }
                        action()
                        let started = Date()
                        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                            if Date().timeIntervalSince(started) > 0.4 { Task { @MainActor in action() } }
                        }
                    }
                    .onEnded { _ in
                        timer?.invalidate()
                        timer = nil
                    }
            )
            .accessibilityLabel("Delete")
            .accessibilityAddTraits(.isButton)
    }
}

private struct KeyFace: View {
    let system: String?
    let label: String?

    var body: some View {
        Group {
            if let system { Image(systemName: system) } else { Text(label ?? "") }
        }
        .font(.system(size: 18))
        .foregroundStyle(.primary)
        .frame(minWidth: 40, maxWidth: .infinity, minHeight: 44)
        .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
}

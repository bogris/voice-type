import AppKit
import Combine
import SwiftUI
import VoiceTypeCore

/// What the settings window shows and changes. Main thread. Every change goes to
/// settings.json through `Actions.update`, which the app runs on one queue, so the window and
/// the menu can't overwrite each other's edits.
final class SettingsModel: ObservableObject {
    enum Tab: Hashable { case general, words, permissions }

    struct Actions {
        var setEnabled: (Bool) -> Void
        var chooseMicrophone: (String) -> Void
        /// Changes settings.json on the app's settings queue, then hands the saved file back
        /// on the main thread.
        var update: (@escaping (inout SettingsFile) -> Void, ((SettingsFile) -> Void)?) -> Void
        var openLog: () -> Void
        var openDataFolder: () -> Void
        var restart: () -> Void
    }

    struct Microphone: Identifiable, Hashable {
        var name: String
        var title: String
        var id: String { name.lowercased() }
    }

    struct Word: Identifiable, Equatable {
        let id = UUID()
        var text: String
    }

    struct Correction: Identifiable, Equatable {
        let id = UUID()
        var heard: String
        var typed: String
    }

    struct PermissionRow: Identifiable, Equatable {
        var permission: Permission
        var state: String
        var id: String { permission.rawValue }
        var satisfied: Bool { permission.isSatisfied(state) }

        var stateText: String {
            switch state {
            case "allowed": return "Allowed"
            case "ask": return "Asks each time"
            case "not_asked": return "Not asked yet"
            default: return "Not allowed"
            }
        }

        var buttonTitle: String {
            if permission == .pasteFromOtherApps && state == "not_asked" { return "Check Now" }
            if permission == .microphone && state == "not_asked" { return "Ask Now" }
            return "Open System Settings"
        }
    }

    private let actions: Actions
    private let catalog: AudioDeviceCatalog
    private var pendingWordsSave: DispatchWorkItem?
    /// The lists as settings.json last had them, so a save only applies what the window
    /// changed and keeps anything added to the file from outside meanwhile.
    private var savedWords: [String] = []
    private var savedCorrections: [(heard: String, typed: String)] = []

    @Published var tab: Tab = .general
    @Published var dictationOn = true
    @Published var microphone = ""
    @Published var microphones: [Microphone] = []
    @Published var keepRecordings = true
    @Published var drawOnScreen = true
    struct MeetingApp: Identifiable {
        var id: String
        var title: String
    }
    @Published var shortcuts = ShortcutConfiguration.defaults
    @Published var shortcutMessage = ""
    @Published var meetingApp = ""
    @Published var meetingApps: [MeetingApp] = []
    @Published var provider = SettingsFile.TranscriptionProvider.whisper
    @Published var apiKey = ""
    @Published var keyMessage = ""
    @Published var accurateMarkers = true
    @Published var words: [Word] = []
    @Published var corrections: [Correction] = []
    @Published var permissions: [PermissionRow] = []

    init(actions: Actions, catalog: AudioDeviceCatalog) {
        self.actions = actions
        self.catalog = catalog
    }

    /// Fills the window from settings.json and the app's status, when it opens.
    func reload(status: NativeStatus) {
        let file = SettingsFile.load()
        provider = file.transcriptionProvider
        shortcuts = file.shortcuts
        meetingApp = file.meetingAppBundleID
        refreshMeetingApps()
        keepRecordings = file.audioRecordingEnabled
        drawOnScreen = file.drawOnScreenEnabled
        accurateMarkers = file.markerTimings == .accurate
        showLists(file)
        update(status: status)
        refreshMicrophones()
        refreshPermissions()
    }

    func update(status: NativeStatus) {
        dictationOn = status.enabled
        if microphone.caseInsensitiveCompare(status.preferredMicrophone) != .orderedSame {
            microphone = status.preferredMicrophone
            refreshMicrophones()
        }
    }

    private func showLists(_ file: SettingsFile) {
        savedWords = file.vocabularyWords
        savedCorrections = file.correctionPairs
        words = savedWords.map { Word(text: $0) }
        corrections = savedCorrections.map { Correction(heard: $0.heard, typed: $0.typed) }
    }

    /// The same list as the menu's: System Default, every input, and the chosen one even
    /// when it's unplugged.
    func refreshMicrophones() {
        let live = catalog.inputDevices().map(\.name)
        var names = [""] + live
        if !microphone.isEmpty && !names.contains(where: { $0.caseInsensitiveCompare(microphone) == .orderedSame }) { names.append(microphone) }
        var seen = Set<String>()
        microphones = names.filter { seen.insert($0.lowercased()).inserted }.map { name in
            let present = name.isEmpty || live.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            return Microphone(name: name, title: name.isEmpty ? "System Default" : present ? name : "\(name) (unavailable)")
        }
        // The picker matches exactly, so use the list's spelling of the chosen name.
        if let match = microphones.first(where: { $0.name.caseInsensitiveCompare(microphone) == .orderedSame }) { microphone = match.name }
    }

    func refreshPermissions() {
        let rows = Permission.allCases.map { PermissionRow(permission: $0, state: $0.state) }
        if rows != permissions { permissions = rows }
    }

    // MARK: Changes

    func setDictationOn(_ on: Bool) {
        dictationOn = on
        actions.setEnabled(on)
    }

    func chooseMicrophone(_ name: String) {
        microphone = name
        actions.chooseMicrophone(name)
    }

    func saveShortcuts() {
        guard shortcuts.isValid else {
            shortcutMessage = "Choose different shortcuts. Letters, numbers and Space need Command, Option or Control."
            return
        }
        let selected = shortcuts
        actions.update({ $0.setNative("shortcuts", selected.json) }, { [weak self] saved in
            self?.shortcutMessage = saved.shortcuts == selected ? "Shortcuts saved. No restart needed." : "Could not save shortcuts."
        })
    }

    func refreshMeetingApps() {
        var apps = NSWorkspace.shared.runningApplications.compactMap { app -> MeetingApp? in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier,
                  id != Bundle.main.bundleIdentifier else { return nil }
            return MeetingApp(id: id, title: app.localizedName ?? id)
        }
        var seen = Set<String>()
        apps = apps.filter { seen.insert($0.id).inserted }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        if !meetingApp.isEmpty && !apps.contains(where: { $0.id == meetingApp }) {
            apps.append(MeetingApp(id: meetingApp, title: meetingApp + " (not running)"))
        }
        meetingApps = [MeetingApp(id: "", title: "All system audio")] + apps
    }

    func chooseMeetingApp(_ id: String) {
        meetingApp = id
        actions.update({ $0.setNative("meeting_app_bundle_id", .string(id)) }, nil)
    }

    func openSystemAudioSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func chooseProvider(_ provider: SettingsFile.TranscriptionProvider) {
        self.provider = provider
        actions.update({ $0.setNative("transcription_provider", .string(provider.rawValue)) }, nil)
    }

    func saveAPIKey() {
        do {
            try OpenAIKeychain.save(apiKey)
            keyMessage = apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "API key removed." : "API key saved in Keychain."
            apiKey = ""
        } catch { keyMessage = "Could not save the API key in Keychain." }
    }

    func setKeepRecordings(_ on: Bool) {
        keepRecordings = on
        actions.update({ $0.set("audio_recording_enabled", .bool(on)) }, nil)
    }

    func setDrawOnScreen(_ on: Bool) {
        drawOnScreen = on
        actions.update({ $0.set("draw_on_screen_enabled", .bool(on)) }, nil)
    }

    func setAccurateMarkers(_ accurate: Bool) {
        accurateMarkers = accurate
        let value = accurate ? SettingsFile.MarkerTimings.accurate : .rough
        actions.update({ $0.setNative("marker_timings", .string(value.rawValue)) }, nil)
    }

    /// Adds a word typed into the box, unless it's blank or already there.
    func addWord(_ text: String) {
        let word = PythonText.strip(text)
        guard !word.isEmpty, !words.contains(where: { $0.text == word }) else { return }
        words.append(Word(text: word))
    }

    func removeWord(_ id: UUID) {
        words.removeAll { $0.id == id }
        saveWordsSoon()
    }

    func addCorrection() -> UUID {
        let row = Correction(heard: "", typed: "")
        corrections.append(row)
        return row.id
    }

    func removeCorrection(_ id: UUID) {
        corrections.removeAll { $0.id == id }
        saveWordsSoon()
    }

    /// Typing saves half a second after the last key, rather than on every one.
    func saveWordsSoon() {
        pendingWordsSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveWordsNow() }
        pendingWordsSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    /// Writes the word list and corrections now, if anything's waiting (the window closing).
    func saveWordsNow() {
        guard let pending = pendingWordsSave else { return }
        pending.cancel()
        pendingWordsSave = nil
        let words = self.words.map(\.text)
        let corrections = self.corrections.map { (heard: $0.heard, typed: $0.typed) }
        let (baseWords, baseCorrections) = (savedWords, savedCorrections)
        actions.update({ file in
            file.applyVocabularyEdit(from: baseWords, to: words)
            file.applyCorrectionsEdit(from: baseCorrections, to: corrections)
        }, { [weak self] saved in
            guard let self else { return }
            let outside = saved.vocabularyWords != words.map(PythonText.strip).filter { !$0.isEmpty }
                || saved.correctionPairs.map(\.heard) != corrections.map { PythonText.strip($0.heard) }.filter { !$0.isEmpty }
            // Someone else changed the file too: show the merged lists, unless more typing
            // is already waiting to be saved.
            if outside && self.pendingWordsSave == nil {
                self.showLists(saved)
            } else {
                self.savedWords = saved.vocabularyWords
                self.savedCorrections = saved.correctionPairs
            }
        })
    }

    func grant(_ permission: Permission) {
        if permission == .pasteFromOtherApps && permission.state != "not_asked" {
            NSWorkspace.shared.open(permission.settingsURL)
        } else {
            permission.request()
        }
        refreshPermissions()
    }

    func openLog() { actions.openLog() }
    func openDataFolder() { actions.openDataFolder() }
    func restart() { actions.restart() }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView(selection: $model.tab) {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsModel.Tab.general)
            WordSettings(model: model)
                .tabItem { Label("Words", systemImage: "text.book.closed") }
                .tag(SettingsModel.Tab.words)
            PermissionSettings(model: model)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
                .tag(SettingsModel.Tab.permissions)
        }
        .padding(.top, 8)
        .frame(minWidth: 460, minHeight: 400)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var model: SettingsModel
    @State private var confirmRestart = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { model.dictationOn }, set: { model.setDictationOn($0) })) {
                    HStack(spacing: 4) {
                        Text("Dictation")
                        InfoButton(text: "Hold your microphone shortcut and speak; let go to type it. While it's off, those keys work as normal.")
                    }
                }
                Picker("Microphone", selection: Binding(get: { model.microphone }, set: { model.chooseMicrophone($0) })) {
                    ForEach(model.microphones) { Text($0.title).tag($0.name) }
                }
            }
            Section {
                ShortcutEditor(title: "Microphone", shortcut: $model.shortcuts.microphone)
                ShortcutEditor(title: "Meeting audio", shortcut: $model.shortcuts.meeting)
                Toggle("Also use Right Control for microphone", isOn: $model.shortcuts.rightControl)
                HStack {
                    Button("Save Shortcuts") { model.saveShortcuts() }
                    Button("Restore Defaults") { model.shortcuts = .defaults; model.saveShortcuts() }
                }
                Text("Hold the shortcut to record, then release its main key to paste. Function keys may need Fn/🌐 on a MacBook. Choose combinations unused by your other apps.").font(.caption).foregroundStyle(.secondary)
                if !model.shortcutMessage.isEmpty { Text(model.shortcutMessage).font(.caption) }
            }
            Section {
                Picker("Transcription", selection: Binding(get: { model.provider }, set: { model.chooseProvider($0) })) {
                    Text("Whisper (local)").tag(SettingsFile.TranscriptionProvider.whisper)
                    Text("GPT Live Transcribe (OpenAI)").tag(SettingsFile.TranscriptionProvider.openai)
                }
                Text("Restart Voice Type after changing the transcription provider.").font(.caption).foregroundStyle(.secondary)
                if model.provider == .openai {
                    Text("Uploads audio to OpenAI after you release the key. Requires internet and a paid OpenAI API account. Live previews are unavailable.").font(.caption)
                    SecureField("OpenAI API key", text: $model.apiKey)
                    Button(model.apiKey.isEmpty ? "Remove Saved Key" : "Save API Key") { model.saveAPIKey() }
                    if !model.keyMessage.isEmpty { Text(model.keyMessage).font(.caption) }
                }
            }
            Section {
                Text("Hold your meeting audio shortcut to transcribe. Release to paste into the text box you focused before pressing it.").font(.caption)
                Picker("Meeting audio source", selection: Binding(get: { model.meetingApp }, set: { model.chooseMeetingApp($0) })) {
                    ForEach(model.meetingApps) { Text($0.title).tag($0.id) }
                }
                HStack {
                    Button("Refresh Apps") { model.refreshMeetingApps() }
                    Button("System Audio Permission") { model.openSystemAudioSettings() }
                }
                Text("You keep hearing playback normally. macOS asks for System Audio Recording permission the first time. Browser capture may include other tabs. The selected transcription provider also handles meeting audio.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: Binding(get: { model.keepRecordings }, set: { model.setKeepRecordings($0) })) {
                    HStack(spacing: 4) {
                        Text("Keep recordings")
                        InfoButton(text: "Keeps each dictation's audio on this Mac for 30 days, for History's play button and Fix it. It's also written to disk while you talk, so a crash can't lose it.")
                    }
                }
                Toggle(isOn: Binding(get: { model.drawOnScreen }, set: { model.setDrawOnScreen($0) })) {
                    HStack(spacing: 4) {
                        Text("Draw on screen")
                        InfoButton(text: "While holding the key, drag or click to mark the screen. A screenshot of each window you marked is pasted after the words, with [1], [2] where you drew.")
                    }
                }
                Picker(selection: Binding(get: { model.accurateMarkers }, set: { model.setAccurateMarkers($0) })) {
                    Text("Accurate").tag(true)
                    Text("Rough").tag(false)
                } label: {
                    HStack(spacing: 4) {
                        Text("Marker timing")
                        InfoButton(text: "Accurate puts [1] after the word you were saying as you drew, using a second copy of the speech model (about 1 GB) while you draw and for 5 minutes after. Rough uses no extra memory, but the markers can land a few words out.")
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!model.drawOnScreen)
            }
            Section {
                HStack {
                    Button("Open Log") { model.openLog() }
                    Button("Open Data Folder") { model.openDataFolder() }
                    Spacer()
                    Button("Restart...") { confirmRestart = true }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Restart Voice Type Native?", isPresented: $confirmRestart) {
            Button("Restart") { model.restart() }
        } message: {
            Text("It reloads the speech model, which takes a few seconds. A dictation in progress finishes first.")
        }
    }
}

private struct WordSettings: View {
    @ObservedObject var model: SettingsModel
    @FocusState private var focused: UUID?
    @State private var newWord = ""

    var body: some View {
        Form {
            Section {
                FlowLayout(spacing: 6) {
                    ForEach(model.words) { word in
                        WordChip(text: word.text) { model.removeWord(word.id) }
                    }
                }
                .padding(.vertical, 2)
                TextField("Add a word", text: $newWord, prompt: Text("Add a word or name"))
                    .labelsHidden()
                    .onSubmit {
                        model.addWord(newWord)
                        newWord = ""
                    }
            } header: {
                HStack(spacing: 4) {
                    Text("Words to listen for")
                    InfoButton(text: "Whisper is told to expect these, so names and jargon come out spelled your way. Used from the next dictation.")
                }
            }
            Section {
                ForEach($model.corrections) { $row in
                    HStack {
                        TextField("Heard", text: $row.heard, prompt: Text("Heard"))
                            .labelsHidden()
                            .focused($focused, equals: row.id)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("Typed", text: $row.typed, prompt: Text("Typed"))
                            .labelsHidden()
                        RemoveButton { model.removeCorrection(row.id) }
                    }
                }
                Button { focused = model.addCorrection() } label: { Label("Add Correction", systemImage: "plus") }
                    .buttonStyle(.borderless)
            } header: {
                HStack(spacing: 4) {
                    Text("Corrections")
                    InfoButton(text: "After every dictation, each word or phrase on the left is replaced with the one on the right: whole words, in any case, in this order.")
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.words) { model.saveWordsSoon() }
        .onChange(of: model.corrections) { model.saveWordsSoon() }
    }
}

/// One word in the list, with an x to take it out.
private struct WordChip: View {
    let text: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
            Button(action: remove) { Image(systemName: "xmark").font(.caption2.weight(.semibold)) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove \(text)")
        }
        .padding(.leading, 9)
        .padding(.trailing, 7)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
    }
}

/// Lays its views out in rows, wrapping like words in a paragraph.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var items: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !row.items.isEmpty && row.width + spacing + size.width > width {
                rows.append(row)
                row = Row(y: row.y + row.height + spacing)
            }
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

private struct RemoveButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove")
    }
}

private struct PermissionSettings: View {
    @ObservedObject var model: SettingsModel
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                ForEach(model.permissions) { row in
                    HStack(spacing: 8) {
                        Image(systemName: row.satisfied ? "checkmark.circle" : "exclamationmark.circle.fill")
                            .foregroundStyle(row.satisfied ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                        Text(row.permission.title)
                        InfoButton(text: row.permission.why)
                        Spacer()
                        if row.state == "allowed" {
                            Text(row.stateText).foregroundStyle(.secondary)
                        } else {
                            if row.state == "ask" { Text(row.stateText).foregroundStyle(.secondary) }
                            Button(row.buttonTitle) { model.grant(row.permission) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(tick) { _ in model.refreshPermissions() }
    }
}

/// Explicit key and modifier choices also work on MacBooks without right-side Control.
private struct ShortcutEditor: View {
    var title: String
    @Binding var shortcut: VoiceTypeCore.KeyboardShortcut

    private func modifier(_ mask: UInt64) -> Binding<Bool> {
        Binding(get: { shortcut.modifiers & mask != 0 }, set: { on in
            if on { shortcut.modifiers |= mask } else { shortcut.modifiers &= ~mask }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(title, selection: $shortcut.keycode) {
                ForEach(VoiceTypeCore.KeyboardShortcut.keys, id: \.code) { key in Text(key.title).tag(key.code) }
            }
            HStack {
                Toggle("⌘", isOn: modifier(VoiceTypeCore.KeyboardShortcut.command)).help("Command")
                Toggle("⌥", isOn: modifier(VoiceTypeCore.KeyboardShortcut.option)).help("Option")
                Toggle("⌃", isOn: modifier(VoiceTypeCore.KeyboardShortcut.control)).help("Control")
                Toggle("⇧", isOn: modifier(VoiceTypeCore.KeyboardShortcut.shift)).help("Shift")
                Spacer()
                Text(shortcut.title).foregroundStyle(.secondary)
            }.toggleStyle(.checkbox)
        }
    }
}

import AVFoundation
import SwiftUI
import UIKit

struct ContentView: View {
    @Binding var cameFromKeyboard: Bool
    @State private var session = SessionEngine.shared
    @State private var models = ModelStore.shared
    @State private var micGranted = AVAudioApplication.shared.recordPermission == .granted
    @State private var showWords = false
    @State private var tryText = ""
    @Environment(\.scenePhase) private var scenePhase

    private var ready: Bool { models.installed && micGranted && session.keyboardSeen }

    var body: some View {
        NavigationStack {
            List {
                if !ready { setup }
                sessionSection
                Section {
                    TextField("Try the keyboard here", text: $tryText, axis: .vertical)
                }
                if !session.history.isEmpty { history }
            }
            .navigationTitle("Voice Type")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Words", systemImage: "text.book.closed") { showWords = true }
                }
            }
            .sheet(isPresented: $showWords) { WordsView() }
            .overlay { if cameFromKeyboard, session.phase != .off { swipeBack } }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else {
                if phase == .background { cameFromKeyboard = false }
                return
            }
            models.refresh()
            session.refreshHistory()
            micGranted = AVAudioApplication.shared.recordPermission == .granted
        }
    }

    /// Shown if the automatic return doesn't happen.
    private var swipeBack: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            Image(systemName: "arrow.left.circle.fill")
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(.tint)
                .accessibilityLabel("Go back to your app")
        }
        // Tapping it should take you back, not just hide it and leave the "◀" link to find.
        .onTapGesture {
            ReturnToPreviousApp.go()
            cameFromKeyboard = false
        }
    }

    private var setup: some View {
        Section {
            row("Microphone", done: micGranted) {
                Task {
                    micGranted = await AVAudioApplication.requestRecordPermission()
                    if !micGranted, let url = URL(string: UIApplication.openSettingsURLString) { await UIApplication.shared.open(url) }
                }
            }
            row("Keyboard and Full Access", done: session.keyboardSeen) {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            if let progress = models.progress {
                VStack(alignment: .leading) {
                    Text("Model")
                    ProgressView(value: progress)
                }
            } else {
                row("Model, 2 GB over wifi", done: models.installed) { models.download() }
            }
            if let problem = models.problem {
                Text(problem).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private func row(_ title: String, done: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                Image(systemName: done ? "checkmark.circle.fill" : "chevron.right")
                    .foregroundStyle(done ? Color.green : Color.secondary)
            }
        }
        .disabled(done)
    }

    private var sessionSection: some View {
        Section {
            Toggle("Mic on", isOn: Binding(
                get: { session.phase != .off },
                set: { on in
                    if on {
                        Task { await session.startSession() }
                    } else {
                        session.endSession()
                    }
                }
            ))
            .disabled(!models.installed)
            Picker("Stay on for", selection: Binding(get: { session.minutes }, set: { session.minutes = $0 })) {
                Text("5 min").tag(5)
                Text("15 min").tag(15)
                Text("1 hour").tag(60)
            }
            if session.phase != .off, !session.modelLoaded {
                HStack {
                    Text("Loading model")
                    Spacer()
                    ProgressView()
                }
            }
            if let problem = session.problem {
                Text(problem).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private var history: some View {
        Section {
            ForEach(session.history) { item in
                Button {
                    UIPasteboard.general.string = item.text
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.text).foregroundStyle(.primary)
                        Text("\(item.seconds, format: .number.precision(.fractionLength(1))) s, took \(item.transcribeSeconds, format: .number.precision(.fractionLength(1))) s")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct WordsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = Words.list.joined(separator: "\n")

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .padding(.horizontal)
                .autocorrectionDisabled()
                .navigationTitle("Words")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            Words.save(text.split(separator: "\n").map(String.init))
                            dismiss()
                        }
                    }
                }
        }
    }
}

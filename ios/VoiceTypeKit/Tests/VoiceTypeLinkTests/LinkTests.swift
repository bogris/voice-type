import Foundation
import Testing
@testable import VoiceTypeLink

private let now = Date(timeIntervalSince1970: 1_000_000)
private func temp() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func aTapWithNoSessionGoesToTheApp() {
    #expect(MicDecision.onTap(state: LinkState(), now: now) == .openApp)
}

@Test func aSessionWhoseHeartbeatStoppedCountsAsDead() {
    // The state file still says ready, as it would after iOS killed the app.
    let state = LinkState(phase: .ready, heartbeat: now.addingTimeInterval(-LinkState.heartbeatTimeout - 1))
    #expect(MicDecision.onTap(state: state, now: now) == .openApp)
}

@Test func aLiveSessionStartsStopsAndIgnoresTapsWhileBusy() {
    func decide(_ phase: LinkState.Phase) -> MicDecision {
        MicDecision.onTap(state: LinkState(phase: phase, heartbeat: now), now: now)
    }
    #expect(decide(.ready) == .startListening)
    #expect(decide(.listening) == .stopListening)
    #expect(decide(.transcribing) == .ignore)
}

@Test(arguments: [
    (nil as String?, "Hello", "Hello"),
    ("", "Hello", "Hello"),
    ("one", "two", " two"),
    ("one ", "two", "two"),
    ("one\n", "two", "two"),
    ("one", ", two", ", two"),
    ("(", "two", "two"),
    ("one", "", ""),
])
func insertedTextJoinsWhatsThere(before: String?, text: String, expected: String) {
    #expect(Insertion.text(text, after: before) == expected)
}

@Test func historyIsNewestFirstAndCapped() {
    let store = LinkStore(folder: temp())
    for i in 0..<(LinkStore.historyLimit + 5) {
        store.append(LinkResult(request: nil, text: "\(i)", seconds: 1, transcribeSeconds: 1))
    }
    #expect(store.history.count == LinkStore.historyLimit)
    #expect(store.history.first?.text == "\(LinkStore.historyLimit + 4)")
}

@Test func autostartFiresOnceAndOnlyWhenRecent() {
    let store = LinkStore(folder: temp())
    store.markAutostart(at: now)
    #expect(store.takeAutostart(now: now.addingTimeInterval(5)))
    #expect(!store.takeAutostart(now: now.addingTimeInterval(5)))
    store.markAutostart(at: now)
    #expect(!store.takeAutostart(now: now.addingTimeInterval(3600)))
}

@Test func stateRoundTripsWithItsDates() {
    let store = LinkStore(folder: temp())
    let state = LinkState(phase: .listening, heartbeat: now, sessionUntil: now.addingTimeInterval(900))
    store.save(state)
    #expect(store.state == state)
}

@Test func levelRoundTrips() {
    let store = LinkStore(folder: temp())
    store.save(level: 0.5)
    #expect(store.level == 0.5)
}

private func zip(_ folder: URL, _ args: [String]) throws -> URL {
    let out = temp().appendingPathComponent("t.zip")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.currentDirectoryURL = folder
    process.arguments = ["-q"] + args + [out.path, "-r", "."]
    try process.run()
    process.waitUntilExit()
    return out
}

@Test(arguments: [["-0"], ["-9"]])
func unzipsStoredAndDeflatedFolders(flags: [String]) throws {
    let source = temp()
    let nested = source.appendingPathComponent("enc.mlmodelc/weights")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    // Bigger than the read chunk, and compressible, to go round the inflate loop more than once.
    let big = Data((0..<3_000_000).map { UInt8(($0 / 7) % 251) })
    try big.write(to: nested.appendingPathComponent("weight.bin"))
    try Data("{}".utf8).write(to: source.appendingPathComponent("enc.mlmodelc/metadata.json"))
    try Data().write(to: source.appendingPathComponent("empty"))

    let out = temp()
    try MiniUnzip.extract(try zip(source, flags), to: out)
    #expect(try Data(contentsOf: out.appendingPathComponent("enc.mlmodelc/weights/weight.bin")) == big)
    #expect(try Data(contentsOf: out.appendingPathComponent("enc.mlmodelc/metadata.json")) == Data("{}".utf8))
    #expect(try Data(contentsOf: out.appendingPathComponent("empty")).isEmpty)
}

@Test func refusesAFileThatIsntAZip() throws {
    let file = temp().appendingPathComponent("x")
    try Data(repeating: 1, count: 100).write(to: file)
    #expect(throws: MiniUnzip.Failure.notAZip) { try MiniUnzip.extract(file, to: temp()) }
}

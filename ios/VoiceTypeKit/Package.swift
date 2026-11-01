// swift-tools-version: 6.0
import PackageDescription

// What the app and the keyboard both need. The keyboard extension links this and not whisper,
// because iOS kills keyboard extensions at around 70 MB.
let package = Package(
    name: "VoiceTypeKit",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [.library(name: "VoiceTypeLink", targets: ["VoiceTypeLink"])],
    targets: [
        .target(name: "VoiceTypeLink"),
        .testTarget(name: "VoiceTypeLinkTests", dependencies: ["VoiceTypeLink"]),
    ]
)

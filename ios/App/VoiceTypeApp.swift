import AVFoundation
import SwiftUI
import UIKit

@main
struct VoiceTypeApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var cameFromKeyboard = false

    var body: some Scene {
        WindowGroup {
            ContentView(cameFromKeyboard: $cameFromKeyboard)
                .onOpenURL { url in
                    guard url.scheme == "voicetype", url.host == "session" else { return }
                    cameFromKeyboard = true
                    Task {
                        await SessionEngine.shared.startSession()
                        // Only back to where you were if it worked; otherwise the problem shows here.
                        if SessionEngine.shared.phase != .off { ReturnToPreviousApp.go() }
                    }
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if Bench.isRequested { Bench.run() }
        ModelStore.shared.reconnect()
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        ModelStore.shared.backgroundCompletion = completionHandler
        ModelStore.shared.reconnect()
    }
}

/// The trip to the app is the one rough edge of a dictation keyboard: iOS only lets an app start
/// the mic while it's in front. There's no public way back, so this presses the "◀ Messages" link
/// in the status bar through its private API. An App Store build would need this taken out, and
/// the swipe-back hint already on screen is what's left then.
enum ReturnToPreviousApp {
    @MainActor static func go() {
        let action = NSSelectorFromString(["_system", "Navigation", "Action"].joined())
        let send = NSSelectorFromString(["send", "Response", "For", "Destination:"].joined())
        guard UIApplication.shared.responds(to: action),
              let navigation = UIApplication.shared.perform(action)?.takeUnretainedValue() as? NSObject,
              navigation.responds(to: send),
              let method = navigation.method(for: send) else { return }
        typealias Send = @convention(c) (AnyObject, Selector, UInt) -> Void
        // Destination 0 is the app you came from.
        unsafeBitCast(method, to: Send.self)(navigation, send, 0)
    }
}

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
                        if SessionEngine.shared.phase != .off { await ReturnToPreviousApp.goSoon() }
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
    /// On a cold start onOpenURL fires before the app is active, and the "◀ Messages" link isn't
    /// wired up yet, so one early try does nothing and leaves you on the arrow. Keep trying for a
    /// moment until it takes (the app stops being active once it has).
    @MainActor static func goSoon() async {
        for delay in [0, 150, 300, 500, 800, 1200] {
            try? await Task.sleep(for: .milliseconds(delay))
            guard UIApplication.shared.applicationState == .active else {
                if UIApplication.shared.applicationState == .background { return }
                continue
            }
            if go() { try? await Task.sleep(for: .milliseconds(300)) }
            if UIApplication.shared.applicationState != .active { return }
        }
    }

    /// Returns whether the private call was made, not whether iOS acted on it.
    @discardableResult @MainActor static func go() -> Bool {
        let action = NSSelectorFromString(["_system", "Navigation", "Action"].joined())
        let send = NSSelectorFromString(["send", "Response", "For", "Destination:"].joined())
        // Older iOS keeps it on the app; scene-based apps may only have it on the window scene.
        let owners: [NSObject] = [UIApplication.shared]
            + UIApplication.shared.connectedScenes.compactMap { $0 as NSObject }
        for owner in owners where owner.responds(to: action) {
            guard let navigation = owner.perform(action)?.takeUnretainedValue() as? NSObject,
                  navigation.responds(to: send),
                  let method = navigation.method(for: send) else { continue }
            typealias Send = @convention(c) (AnyObject, Selector, UInt) -> Void
            // Destination 0 is the app you came from.
            unsafeBitCast(method, to: Send.self)(navigation, send, 0)
            return true
        }
        return false
    }
}

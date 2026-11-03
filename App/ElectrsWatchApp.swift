import SwiftUI
import UIKit

@main
struct ElectrsWatchApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(Appearance.storageKey) private var appearance = Appearance.dark

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .modifier(PrivacyCovered())
                .tint(Theme.accent)
                // Applies to the whole window, sheets included.
                .preferredColorScheme(appearance.colorScheme)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { model.lock() }
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Third-party keyboards can log what's typed, so this app only allows the system keyboard.
    func application(
        _ application: UIApplication,
        shouldAllowExtensionPointIdentifier extensionPointIdentifier: UIApplication.ExtensionPointIdentifier
    ) -> Bool {
        extensionPointIdentifier != .keyboard
    }
}

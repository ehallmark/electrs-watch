import SwiftUI

/// Night-sky styling. The flavor stays on greetings and titles: errors, warnings
/// and security prompts keep plain wording, so a clever line never hides a real problem.
enum Theme {
    /// Moonlit blue. Dark enough for white button text, and readable on both black and white.
    static let accent = Color(red: 0x2F / 255, green: 0x86 / 255, blue: 0xB3 / 255)
    static let tagline = "Your coins, kept in view."
    static let lockedLine = "Resting. Unlock to check."
}

/// The Settings choice for light or dark. Kept in the app's preferences, not the Keychain, because it's needed
/// on the lock screen before Face ID and says nothing about your coins or server.
enum Appearance: String, CaseIterable {
    case dark
    case light
    case system

    static let storageKey = "appearance"

    var label: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .system: "System"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }
}

/// The app icon as an image inside the app.
struct Emblem: View {
    var size: CGFloat = 120

    var body: some View {
        Image("Emblem")
            .resizable()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.224, style: .continuous))
            .accessibilityHidden(true)
    }
}

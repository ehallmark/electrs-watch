import SwiftUI

/// Night's Watch styling. The flavor stays on greetings and titles: errors, warnings
/// and security prompts keep plain wording, so a clever line never hides a real problem.
enum Theme {
    /// Cold blue from the Wall. Dark enough for white button text and for links on black.
    static let ice = Color(red: 0x2F / 255, green: 0x86 / 255, blue: 0xB3 / 255)
    static let tagline = "And now my watch begins."
    static let lockedLine = "Winter is coming."
}

/// The app icon as an image inside the app.
struct Crest: View {
    var size: CGFloat = 120

    var body: some View {
        Image("Crest")
            .resizable()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.224, style: .continuous))
            .accessibilityHidden(true)
    }
}

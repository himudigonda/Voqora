import Foundation

enum OnboardingCopy {
    static let welcomeTitle = "Welcome to Voqora"
    static let welcomeBody = "Hear any text on your Mac read aloud with natural voices."
    struct Feature {
        let systemImage: String
        let title: String
        let body: String
    }

    static let features = [
        Feature(systemImage: "text.cursor", title: "Listen to Any Text", body: "Select text in any app and press a shortcut to hear it."),
        Feature(systemImage: "books.vertical", title: "Make Audiobooks", body: "Turn PDFs, Word documents, and text files into audiobooks you can follow line by line."),
        Feature(systemImage: "lock", title: "Runs on Your Mac", body: "Narration is generated right on your Mac, not in the cloud."),
    ]

    static let hotkeyTitle = "Speak From Any App"
    static let hotkeyBody = "Select text, then press ⌘⇧. to hear it. You can change the shortcut in Preferences."

    static let axTitle = "Allow Accessibility"
    static let axBody = "Voqora needs Accessibility access to read the text you select."
    static let axGrantButton = "Open System Settings"
    static let axGrantedLabel = "Allowed"
    static let axPendingLabel = "Waiting for access…"
    static let axContinueWithoutButton = "Not Now"

    static let notifTitle = "Notifications"
    static let notifBody = "Get notified when an audiobook is ready or an export finishes."
    static let notifGrantButton = "Turn On Notifications"
    static let notifOpenSettingsButton = "Open Notification Settings"
    static let notifGrantedLabel = "On"
    static let notifDeniedLabel = "Off. You can turn them on in System Settings."

    static let identityTitle = "About You"
    static let identityNamePlaceholder = "Name"
    static let identityPlaceholder = "Email"

    static let customizeTitle = "Personalize"
    static let customizeAccentLabel = "Accent Color"
    static let customizeIconLabel = "App Icon"

    static let doneTitle = "You're All Set"
    static let doneBody = "Select text in any app and press ⌘⇧. to hear it. Add documents in Library to make audiobooks."
    static let doneSampleButton = "Hear a Sample"
    static let sampleText = "Hi, I'm Voqora. Select text in any app, press your Voqora shortcut, and I'll read it aloud. "
        + "You can also turn documents into audiobooks and follow along, line by line."

    static let nextButton = "Continue"
    static let backButton = "Back"
    static let doneButton = "Get Started"
}

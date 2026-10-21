import Foundation

enum OnboardingCopy {
    static let welcomeTitle = "Welcome to Voqora"
    static let welcomeBody = "Hear any text on your Mac read aloud with natural voices, and turn documents into audiobooks. Setup takes about two minutes."
    struct Feature {
        let systemImage: String
        let title: String
        let body: String
    }

    static let features = [
        Feature(systemImage: "text.cursor", title: "Listen to Any Text", body: "Select text in any app and press a shortcut to hear it."),
        Feature(systemImage: "books.vertical", title: "Make Audiobooks", body: "Turn PDFs, EPUBs, Word documents and web pages into audiobooks you can follow line by line."),
        Feature(systemImage: "waveform.badge.mic", title: "Design Your Own Voices", body: "Blend voices, or describe and clone new ones with Ming."),
        Feature(systemImage: "lock", title: "Runs on Your Mac", body: "Narration is generated right on your Mac, not in the cloud."),
    ]

    static let privacyTitle = "Your Privacy"
    static let privacyBody = "Voqora keeps your text, documents and audio on your Mac. Everything on this page is optional."
    static let privacyLocalNote = "Narration is generated on your Mac. Your text, documents and audio never leave it."
    static let analyticsFooter = "Off by default and stays off unless you switch it on. You can change this any time in Settings › Privacy & Data."
    static let privacyPolicyTitle = "Privacy Policy"
    static let privacyPolicyURL = URL(string: "https://github.com/himudigonda/Voqora/blob/main/PRIVACY.md")!
    static let privacySkipButton = "Skip for Now"

    static let permissionsTitle = "Allow Access"
    static let permissionsBody = "Voqora asks only for what a feature needs. Accessibility lets it read the text you select in other apps."
    static let accessibilityFooter = "Without Accessibility, Voqora cannot read your selection or paste dictation into other apps."
    static let notificationsFooter = "Get told when an audiobook is ready or an export finishes."
    static let axContinueWithoutButton = "Not Now"
    static let axSteps = [
        "Click Open System Settings.",
        "Turn on Voqora in the Accessibility list.",
        "Come back here. Voqora notices the change on its own.",
    ]

    static let shortcutsTitle = "Speak From Any App"
    static let shortcutsBody = "Select text anywhere, then press your shortcut to hear it. Press it again to stop."
    static let shortcutsFooter = "Click a shortcut to record a new one. All ten shortcuts live in Settings › Shortcuts."
    static let hotkeyTips = [
        Feature(systemImage: "pause.circle", title: "Pause and Resume", body: "Use the floating player or the menu bar icon while Voqora speaks."),
        Feature(systemImage: "keyboard", title: "Change It Any Time", body: "Pick different shortcuts in Settings › Shortcuts."),
    ]

    static let dictationTitle = "Dictate Anywhere"
    static let dictationBody = "Optional. Speak instead of typing in any app. Allow the microphone and speech recognition to start."
    static let dictationServerNote = "Server recognition stays off. You can allow it in Settings › Dictation."

    static let engineTitle = "Choose a Speech Engine"
    static let engineBody = "Engines turn text into speech on your Mac. Pick the one Voqora uses by default. You can mix engines later, per voice."
    static let engineLoading = "Loading speech engines…"
    static let engineOffline = "Speech engines appear once Voqora has started. You can continue and choose later in Settings › Engines."
    static let engineRecommendedBadge = "Recommended"

    static func enginePurpose(_ id: String) -> String {
        switch id {
        case SpeechEngineID.kokoro: "Fast, natural voices that come with Voqora. Always available, even offline."
        case SpeechEngineID.supertonic: "A lightweight engine with extra voices in more languages."
        case SpeechEngineID.ming: "The most expressive engine. Design voices from a description or clone one from a short clip."
        default: "An optional speech engine."
        }
    }

    static func engineSpeed(_ id: String) -> String {
        switch id {
        case SpeechEngineID.kokoro: "Real time"
        case SpeechEngineID.supertonic: "Real time"
        case SpeechEngineID.ming: "Slower than real time"
        default: ""
        }
    }

    static let voiceTitle = "Pick Your Voice"
    static let voiceBody = "This voice reads the text you select. Play a sample, then tune how it sounds."

    static let audiobooksTitle = "Audiobook Defaults"
    static let audiobooksBody = "Optional. New audiobooks start with these settings. You can change them for each book when you create it."

    static let aiTitle = "Connect an AI Provider"
    static let aiBody = "Optional. An AI provider tidies messy PDFs, reads scanned pages and powers summaries, quizzes and translation. "
        + "Narration always stays on your Mac."
    static let aiPrivacyNote = "Keys are stored in your Keychain. Local providers like Ollama and LM Studio keep everything on your Mac."
    static let aiChooseLabel = "Choose a provider"
    static let aiSkipButton = "Skip for Now"

    static let appearanceTitle = "Make It Yours"
    static let appearanceBody = "Choose how Voqora looks. Every change previews instantly."

    static let doneTitle = "You're All Set"
    static let doneBody = "Here's how Voqora is set up. You can change any of this in Settings."
    static let checklistTitle = "Still to do"
    static let checklistFooter = "Each item opens the Settings page where you can finish it."
    static let checklistEmpty = "Everything is set up."
    static let integrationsTitle = "Connect apps and AI tools"
    static let integrationsBody = "Optional. Turn on the local API or MCP server in Settings › Integrations."
    static let doneSampleButton = "Hear a Sample"
    static let sampleText = "Hi, I'm Voqora. Select text in any app, press your Voqora shortcut, and I'll read it aloud. "
        + "You can also turn documents into audiobooks and follow along, line by line."

    static let nextButton = "Continue"
    static let backButton = "Back"
    static let doneButton = "Get Started"
}

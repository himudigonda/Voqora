import Foundation

/// Onboarding copy lives in code constants so the wording can be edited
/// without view churn.
enum OnboardingCopy {
    // MARK: - Step 1 — Welcome

    static let welcomeTitle = "Welcome to Voqora"
    static let welcomeBody = """
    Voqora reads any selected text aloud — fast, on-device, with neural \
    voices in 8 languages (English, Spanish, French, Italian, Portuguese, \
    Hindi & more). No cloud, no upload, no waiting on a server. Press a \
    global hotkey and the next sentence starts before the first one \
    finishes rendering.
    """

    // MARK: - Step 2 — The hotkey

    static let hotkeyTitle = "Cmd ⇧ . anywhere"
    static let hotkeyBody = """
    Select text in any app — a PDF, a webpage, your editor — then press \
    Cmd ⇧ . (period). Voqora speaks the selection. Press it again to \
    interrupt and read something new. The shortcut is rebindable in \
    Preferences.
    """

    // MARK: - Step 3 — Accessibility permission (required)

    static let axTitle = "Grant Accessibility Access"
    static let axBody = """
    macOS needs to give Voqora permission to listen for the global \
    hotkey and read the currently selected text. Without it, the hotkey \
    won't work — but no other Voqora feature depends on this.

    Click the button below. macOS will open the Accessibility pane in \
    System Settings. Toggle Voqora on, then come back to this window.
    """
    static let axGrantButton = "Open System Settings"
    static let axGrantedLabel = "Granted"
    static let axPendingLabel = "Waiting for you to grant access…"

    // MARK: - Step 4 — Notifications (optional)

    static let notifTitle = "Allow notifications (optional)"
    static let notifBody = """
    Voqora can show small system notifications when a long audiobook \
    finishes rendering or when an export completes. Entirely optional — \
    skip this step and nothing else changes.
    """
    static let notifGrantButton = "Allow notifications"
    static let notifSkipButton = "Skip"
    static let notifGrantedLabel = "Allowed"
    static let notifDeniedLabel = "Disabled (you can change this in System Settings)"

    // MARK: - Step — Voice & language (personalization)

    static let voiceTitle = "Pick your voice"
    static let voiceBody = """
    Voqora speaks 8 languages on-device. Choose the voice it uses by \
    default, press Hear a sample to listen, and set your speed. You can \
    change any of this later in Preferences.
    """
    static let voiceSampleButton = "Hear a sample"
    static let voiceStopButton = "Stop"
    static let voiceSpeedLabel = "Speed"
    static let voiceAutoDetectTitle = "Auto-detect language"
    static let voiceAutoDetectBody = "Automatically match the voice to the text's language."

    // MARK: - Step 5 — Identity (optional email)

    static let identityTitle = "Optional email"
    static let identityBody = """
    Voqora works fully without an account. If you choose to add an email, \
    we use it only to recognise voluntary returning installs in aggregate \
    adoption metrics. There is no password and no sign-in. We never read \
    your text or files.

    Totally optional. You can stay anonymous or remove your email later in \
    Preferences.
    """
    static let identityPlaceholder = "you@example.com"
    static let identitySaveButton = "Save email"
    static let identitySkipButton = "Skip"
    static let identitySavedLabel = "Got it — thank you!"
    /// Friendly, non-alarming message when the optional email couldn't be saved.
    static let identityServerError = "Couldn't reach the server right now — no worries, this step is optional. You can skip it."

    // MARK: - Step 6 — Privacy + done

    static let privacyTitle = "You're all set"
    static let privacyBody = """
    Voqora runs fully on your Mac. Your text never leaves this machine. \
    We collect counts only: launches, characters generated, audio seconds — \
    nothing about the content itself. You can disable analytics anytime in \
    Preferences.
    """

    // MARK: - Buttons

    static let nextButton = "Next"
    static let backButton = "Back"
    static let doneButton = "Get started"
    static let skipButton = "Skip for now"
}

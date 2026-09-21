import Foundation

/// Onboarding copy lives in code constants so the wording can be edited
/// without view churn.
enum OnboardingCopy {
    // MARK: - Step 1 — Welcome

    static let welcomeTitle = "Welcome to Voqora"
    static let welcomeBody = """
    Voqora reads selected text aloud — fast, on-device, with neural voices. \
    Normal speech stays on your Mac; your text is not sent to a cloud speech \
    service. Press a global hotkey and listening begins while the rest of the \
    passage is still rendering.
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
    static let axContinueWithoutButton = "Continue without access"
    static let axContinueWithoutHelp = "You can still use audiobooks and enable selected-text reading later in Preferences."

    // MARK: - Step 4 — Notifications (optional)

    static let notifTitle = "Allow notifications"
    static let notifBody = """
    Voqora can show small system notifications when a long audiobook \
    finishes rendering or when an export completes.
    """
    static let notifGrantButton = "Allow notifications"
    static let notifOpenSettingsButton = "Open Notification Settings"
    static let notifGrantedLabel = "Allowed"
    static let notifDeniedLabel = "Disabled (you can change this in System Settings)"

    // MARK: - Step 5 — Identity (required)

    static let identityTitle = "Create your identity"
    static let identityBody = """
    Voqora needs your name and email to continue. There is no password and \
    no sign-in — this identifies your activity in adoption metrics. We \
    never read your text or files.
    """
    static let identityNamePlaceholder = "Full name"
    static let identityPlaceholder = "you@example.com"
    static let identitySaveButton = "Save"
    static let identitySavedLabel = "Saved. Thanks!"

    // MARK: - Step 6 — Customize

    static let customizeTitle = "Make it yours"
    static let customizeBody = """
    Pick an accent color and an app icon. You can change these anytime in \
    Preferences.
    """
    static let customizeAccentLabel = "Accent Color"
    static let customizeIconLabel = "App Icon"

    // MARK: - Step 7 — Privacy + done

    static let privacyTitle = "You're all set"
    static let privacyBody = """
    Normal speech runs on your Mac. If you later choose Gemini cleanup for a \
    document, Voqora tells you before document material leaves the Mac. Voqora \
    always shares anonymous usage counts — never your text or files — to help \
    improve the product.
    """

    // MARK: - Buttons

    static let nextButton = "Next"
    static let backButton = "Back"
    static let doneButton = "Get started"
}

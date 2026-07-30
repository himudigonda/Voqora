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

    // MARK: - Step 5 — Identity (optional email)

    static let identityTitle = "Help us count returning users"
    static let identityBody = """
    Voqora is free and we'd love to know if real people keep using it. \
    Drop your email so anonymous usage counts can be attributed to a \
    person instead of a random UUID. That's it — no marketing email, no \
    account, no password. We never read your text or files.

    Totally optional. Skip if you'd rather stay completely anonymous.
    """
    static let identityPlaceholder = "you@example.com"
    static let identitySaveButton = "Save email"
    static let identitySkipButton = "Skip"
    static let identitySavedLabel = "Saved. Thanks!"

    // MARK: - Step 6 — Privacy + done

    static let privacyTitle = "You're all set"
    static let privacyBody = """
    Normal speech runs on your Mac. If you later choose Gemini cleanup for a \
    document, Voqora tells you before document material leaves the Mac. Anonymous \
    analytics contain counts only — never your text or files — and can be \
    disabled in Preferences.
    """

    // MARK: - Buttons

    static let nextButton = "Next"
    static let backButton = "Back"
    static let doneButton = "Get started"
    static let skipButton = "Skip for now"
}

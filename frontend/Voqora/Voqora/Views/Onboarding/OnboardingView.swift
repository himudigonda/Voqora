import AppKit
import SwiftUI

/// Six-step first-launch wizard.
///
/// Steps:
///   1. Welcome
///   2. Hotkey explanation
///   3. Accessibility permission (required for selected-text reading)
///   4. Notifications permission (optional)
///   5. Identity / email (optional)
///   6. Privacy + done
///
/// Presented full-window via `.fullScreenCover`-style overlay (not `.sheet`)
/// so the user can't dismiss it by clicking outside.
struct OnboardingView: View {
    /// Shared bounding box for every step's hero icon (app icon image or SF
    /// Symbol glyph) so they read as the same size as the wizard pages by,
    /// rather than each icon's own intrinsic/font-implied size.
    static let heroIconSize: CGFloat = 64

    @EnvironmentObject var coordinator: OnboardingCoordinator
    @EnvironmentObject var permissions: PermissionsService
    @EnvironmentObject var identity: IdentityService
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @State private var step: Int = 0
    @State private var emailDraft: String = ""
    @State private var emailSubmitting: Bool = false
    @State private var emailError: String?
    @State private var emailSaved: Bool = false
    /// Reads the same `UserDefaults` key `DashboardViewModel.accentColorID`
    /// writes — `@AppStorage` needs no environment object to do that, so
    /// this stays correct if the compiled default ever changes again
    /// without this view needing `DashboardViewModel` threaded into it.
    @AppStorage("accentColorID") private var accentColorID: AccentColorOption = .clay
    /// Same reasoning as `accentColorID` above, for the same reason: every
    /// body-text `.font()` call in this file was hardcoded to
    /// `.system(..., design: .rounded)`, ignoring whatever font the user
    /// actually has selected in Preferences → Typography — the only screen
    /// in the app that did. `DashboardViewModel.appFont(size:weight:)` has
    /// the real weight-mapping logic (Poppins/Google Sans ship discrete
    /// static weight files rather than a variable font, so `.weight(_)`
    /// can't synthesize on top of them); mirrored here rather than threading
    /// `DashboardViewModel` into this view's environment.
    @AppStorage("selectedFontName") private var selectedFontName: String = "Google Sans"

    private let stepCount = 6

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 0) {
                progressBar
                Spacer(minLength: 24)
                content
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 40)
                Spacer(minLength: 24)
                footer
            }
            .padding(.top, 28)
            .padding(.bottom, 28)
        }
        .frame(minWidth: 720, minHeight: 560)
        .onAppear {
            emailDraft = identity.email ?? ""
            // Resume where a previous session left off instead of replaying
            // already-granted permission steps from scratch.
            step = min(max(0, coordinator.resumeStep), stepCount - 1)
            permissions.startPolling()
        }
        .onDisappear {
            permissions.stopPolling()
        }
        .onChange(of: step) { _, newValue in
            coordinator.recordStep(newValue)
        }
    }

    // MARK: - Chrome

    /// `DashboardViewModel` isn't reachable from this view's environment
    /// (see `VoqoraWindow.swift`, where `OnboardingView()` is only handed
    /// `coordinator`/`permissions`/`identity`), so this reads `Palette`
    /// directly with the `@AppStorage`-backed `accentColorID` above rather
    /// than routing through `vm.accentColor`.
    private var accentColor: Color {
        Palette.accentColors(
            for: accentColorID,
            appearance: colorScheme,
            increaseContrast: colorSchemeContrast == .increased
        ).accent
    }

    private var backdrop: some View {
        LinearGradient(
            colors: [Palette.surfaceSunken, Palette.surfaceBase],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var progressBar: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< stepCount, id: \.self) { idx in
                Capsule()
                    .fill(idx <= step ? accentColor : Palette.separator)
                    .frame(height: 4)
                    .animation(.spring(response: 0.3), value: step)
            }
        }
        .frame(maxWidth: 480)
        // Step position was conveyed purely by capsule fill color, which
        // VoiceOver can't perceive — a VoiceOver user got no "step 3 of 6"
        // announcement at all from this custom-drawn control.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue("Step \(step + 1) of \(stepCount)")
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: stepWelcome
        case 1: stepHotkey
        case 2: stepAccessibility
        case 3: stepNotifications
        case 4: stepIdentity
        default: stepDone
        }
    }

    private var footer: some View {
        HStack {
            if step > 0 {
                Button(OnboardingCopy.backButton) { withAnimation { step -= 1 } }
                    .buttonStyle(.bordered)
            } else {
                Spacer().frame(width: 80)
            }
            Spacer()
            if step == 2, !permissions.accessibilityGranted {
                // Do not turn a denied or unavailable macOS permission into a
                // dead-end product. Selected-text reading stays unavailable
                // until it is granted, but local audiobooks and the in-app
                // experience remain usable with the persistent dashboard cue.
                Button(OnboardingCopy.axContinueWithoutButton) {
                    withAnimation { step += 1 }
                }
                .buttonStyle(.bordered)
                .help(OnboardingCopy.axContinueWithoutHelp)
            }
            if step == stepCount - 1 {
                Button(OnboardingCopy.doneButton) { coordinator.markCompleted() }
                    .buttonStyle(.borderedProminent)
                    .tint(accentColor)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(OnboardingCopy.nextButton) { withAnimation { step += 1 } }
                    .buttonStyle(.borderedProminent)
                    .tint(accentColor)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdvance)
                    .help(advanceBlockedReason ?? "")
            }
        }
        .padding(.horizontal, 40)
    }

    /// Step-specific Next-button gating. Accessibility gets a dedicated,
    /// explicit continue-without-access path rather than making the whole app
    /// unusable when the user declines it.
    private var canAdvance: Bool {
        switch step {
        case 2: permissions.accessibilityGranted
        default: true
        }
    }

    private var advanceBlockedReason: String? {
        if step == 2, !permissions.accessibilityGranted {
            return "Grant Accessibility access to continue"
        }
        return nil
    }

    // MARK: - Step views

    private var stepWelcome: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: Self.heroIconSize, height: Self.heroIconSize)
            Text(OnboardingCopy.welcomeTitle)
                .font(appFont(size: 32, weight: .bold))
                .foregroundStyle(Palette.textPrimary)
                .multilineTextAlignment(.center)
            Text(OnboardingCopy.welcomeBody)
                .font(appFont(size: 15))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stepHotkey: some View {
        VStack(spacing: 22) {
            HStack(spacing: 10) {
                kbd("⌘"); kbd("⇧"); kbd(".")
            }
            Text(OnboardingCopy.hotkeyTitle)
                .font(appFont(size: 26, weight: .bold))
                .foregroundStyle(Palette.textPrimary)
            Text(OnboardingCopy.hotkeyBody)
                .font(appFont(size: 15))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stepAccessibility: some View {
        VStack(spacing: 22) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 52))
                .foregroundStyle(accentColor)
                .frame(width: Self.heroIconSize, height: Self.heroIconSize)
            Text(OnboardingCopy.axTitle)
                .font(appFont(size: 24, weight: .bold))
                .foregroundStyle(Palette.textPrimary)
            Text(OnboardingCopy.axBody)
                .font(appFont(size: 14))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                Button {
                    permissions.requestAccessibility()
                } label: {
                    Label(OnboardingCopy.axGrantButton, systemImage: "gear")
                        .frame(minWidth: 220)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(accentColor)
                .disabled(permissions.accessibilityGranted)

                statusRow(
                    isGranted: permissions.accessibilityGranted,
                    grantedLabel: OnboardingCopy.axGrantedLabel,
                    pendingLabel: OnboardingCopy.axPendingLabel
                )
            }
        }
    }

    private var stepNotifications: some View {
        VStack(spacing: 22) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 52))
                .foregroundStyle(accentColor)
                .frame(width: Self.heroIconSize, height: Self.heroIconSize)
            Text(OnboardingCopy.notifTitle)
                .font(appFont(size: 24, weight: .bold))
                .foregroundStyle(Palette.textPrimary)
            Text(OnboardingCopy.notifBody)
                .font(appFont(size: 14))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                Button {
                    // Once macOS has denied notifications, it will never
                    // re-prompt from `requestNotifications()` (see
                    // `PermissionsService`'s own comment on that) — that
                    // left this button a silent no-op with no way inside
                    // the wizard to reach the Notifications pane, unlike
                    // the Accessibility step just before it. Mirrors that
                    // step's own pattern: open the settings pane directly.
                    if permissions.notificationsStatus == .denied {
                        permissions.openNotificationSettings()
                    } else {
                        Task { await permissions.requestNotifications() }
                    }
                } label: {
                    Label(
                        permissions.notificationsStatus == .denied ? OnboardingCopy.notifOpenSettingsButton : OnboardingCopy.notifGrantButton,
                        systemImage: permissions.notificationsStatus == .denied ? "gear" : "bell"
                    )
                    .frame(minWidth: 220)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(accentColor)
                .disabled(permissions.notificationsStatus == .authorized)

                notificationsStatusLabel
            }
        }
    }

    @ViewBuilder
    private var notificationsStatusLabel: some View {
        switch permissions.notificationsStatus {
        case .authorized:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.success)
                Text(OnboardingCopy.notifGrantedLabel).foregroundStyle(Palette.success)
            }.font(appFont(size: 12))
        case .denied:
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.warning)
                Text(OnboardingCopy.notifDeniedLabel).foregroundStyle(Palette.textSecondary)
            }.font(appFont(size: 12))
        default:
            Text(" ").font(appFont(size: 12))
        }
    }

    private var stepIdentity: some View {
        VStack(spacing: 18) {
            Image(systemName: "envelope.fill")
                .font(.system(size: 52))
                .foregroundStyle(accentColor)
                .frame(width: Self.heroIconSize, height: Self.heroIconSize)
            Text(OnboardingCopy.identityTitle)
                .font(appFont(size: 22, weight: .bold))
                .foregroundStyle(Palette.textPrimary)
                .multilineTextAlignment(.center)
            Text(OnboardingCopy.identityBody)
                .font(appFont(size: 14))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField(OnboardingCopy.identityPlaceholder, text: $emailDraft)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .frame(maxWidth: 280)
                Button {
                    submitEmail()
                } label: {
                    if emailSubmitting {
                        ProgressView().scaleEffect(0.6).frame(width: 80)
                    } else {
                        Text(OnboardingCopy.identitySaveButton).frame(width: 80)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(accentColor)
                .disabled(!canSaveEmail || emailSubmitting)
                .help(canSaveEmail ? "Save this optional email" : "Enter a valid email to enable Save")
            }

            if let err = emailError {
                Text(err).font(appFont(size: 11)).foregroundStyle(Palette.danger)
            } else if emailSaved {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.success)
                    Text(OnboardingCopy.identitySavedLabel).foregroundStyle(Palette.success)
                }.font(appFont(size: 12))
            } else {
                Text(emailDraft.isEmpty || canSaveEmail ? " " : "Enter a valid email to enable Save")
                    .font(appFont(size: 12))
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private var canSaveEmail: Bool {
        IdentityService.looksLikeEmail(emailDraft.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var stepDone: some View {
        VStack(spacing: 22) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(Palette.success)
                .frame(width: Self.heroIconSize, height: Self.heroIconSize)
            Text(OnboardingCopy.privacyTitle)
                .font(appFont(size: 28, weight: .bold))
                .foregroundStyle(Palette.textPrimary)
            Text(OnboardingCopy.privacyBody)
                .font(appFont(size: 15))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Helpers

    private func submitEmail() {
        emailError = nil
        emailSaved = false
        let candidate = emailDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }
        emailSubmitting = true
        Task {
            defer { emailSubmitting = false }
            do {
                try await identity.submitEmail(candidate)
                emailSaved = true
            } catch {
                emailError = (error as? IdentityService.IdentityError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func statusRow(isGranted: Bool, grantedLabel: String, pendingLabel: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "clock.fill")
                .foregroundStyle(isGranted ? Palette.success : Palette.warning)
            Text(isGranted ? grantedLabel : pendingLabel)
                .foregroundStyle(isGranted ? Palette.success : Palette.textSecondary)
        }
        .font(appFont(size: 12))
    }

    private func kbd(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 26, weight: .bold, design: .monospaced))
            .foregroundStyle(Palette.textPrimary)
            .frame(width: 56, height: 56)
            .voqoraSurface(.raised, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
    }
}

/// Split out of the struct body to keep it under SwiftLint's
/// `type_body_length` — plain private members, not a separate API surface.
/// Same pattern already used for this reason in `VoqoraWindow.swift`.
private extension OnboardingView {
    func appFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch selectedFontName {
        case "System Rounded":
            .system(size: size, weight: weight, design: .rounded)
        case "System Mono":
            .system(size: size, weight: weight, design: .monospaced)
        case "System Serif":
            .system(size: size, weight: weight, design: .serif)
        case "System Standard":
            .system(size: size, weight: weight, design: .default)
        case "Poppins":
            .custom(Self.poppinsPostScriptName(for: weight), size: size)
        case "Google Sans":
            .custom(Self.googleSansPostScriptName(for: weight), size: size)
        default:
            .custom(selectedFontName, size: size).weight(weight)
        }
    }

    static func poppinsPostScriptName(for weight: Font.Weight) -> String {
        switch weight {
        case .black, .heavy: "Poppins-Black"
        case .bold: "Poppins-Bold"
        case .semibold, .medium: "Poppins-Medium"
        case .light, .thin, .ultraLight: "Poppins-Light"
        default: "Poppins-Regular"
        }
    }

    static func googleSansPostScriptName(for weight: Font.Weight) -> String {
        switch weight {
        case .black, .heavy: "GoogleSansFlex24pt-Black"
        case .bold: "GoogleSans17pt-Bold"
        case .semibold, .medium: "GoogleSans17pt-Medium"
        case .light, .thin, .ultraLight: "GoogleSansFlex24pt-Light"
        default: "GoogleSans17pt-Regular"
        }
    }
}

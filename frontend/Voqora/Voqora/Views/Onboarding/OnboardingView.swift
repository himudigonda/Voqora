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
            if step == 2 && !permissions.accessibilityGranted {
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
        case 2: return permissions.accessibilityGranted
        default: return true
        }
    }

    private var advanceBlockedReason: String? {
        if step == 2 && !permissions.accessibilityGranted {
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
                .frame(width: 76, height: 76)
            Text(OnboardingCopy.welcomeTitle)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.textPrimary)
                .multilineTextAlignment(.center)
            Text(OnboardingCopy.welcomeBody)
                .font(.system(size: 15, design: .rounded))
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
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.textPrimary)
            Text(OnboardingCopy.hotkeyBody)
                .font(.system(size: 15, design: .rounded))
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
            Text(OnboardingCopy.axTitle)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.textPrimary)
            Text(OnboardingCopy.axBody)
                .font(.system(size: 14, design: .rounded))
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
            Text(OnboardingCopy.notifTitle)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.textPrimary)
            Text(OnboardingCopy.notifBody)
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                Button {
                    Task { await permissions.requestNotifications() }
                } label: {
                    Label(OnboardingCopy.notifGrantButton, systemImage: "bell")
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
            }.font(.system(size: 12, design: .rounded))
        case .denied:
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.warning)
                Text(OnboardingCopy.notifDeniedLabel).foregroundStyle(Palette.textSecondary)
            }.font(.system(size: 12, design: .rounded))
        default:
            Text(" ").font(.system(size: 12, design: .rounded))
        }
    }

    private var stepIdentity: some View {
        VStack(spacing: 18) {
            Image(systemName: "envelope.fill")
                .font(.system(size: 52))
                .foregroundStyle(accentColor)
            Text(OnboardingCopy.identityTitle)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.textPrimary)
                .multilineTextAlignment(.center)
            Text(OnboardingCopy.identityBody)
                .font(.system(size: 14, design: .rounded))
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
                Text(err).font(.system(size: 11, design: .rounded)).foregroundStyle(Palette.danger)
            } else if emailSaved {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.success)
                    Text(OnboardingCopy.identitySavedLabel).foregroundStyle(Palette.success)
                }.font(.system(size: 12, design: .rounded))
            } else {
                Text(emailDraft.isEmpty || canSaveEmail ? " " : "Enter a valid email to enable Save")
                    .font(.system(size: 12, design: .rounded))
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
            Text(OnboardingCopy.privacyTitle)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.textPrimary)
            Text(OnboardingCopy.privacyBody)
                .font(.system(size: 15, design: .rounded))
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
        .font(.system(size: 12, design: .rounded))
    }

    private func kbd(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 26, weight: .bold, design: .monospaced))
            .foregroundStyle(Palette.textPrimary)
            .frame(width: 56, height: 56)
            .voqoraSurface(.raised, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
    }
}

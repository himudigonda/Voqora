import AppKit
import SwiftUI

/// Seven-step first-launch wizard.
///
/// Steps:
///   1. Welcome
///   2. Hotkey explanation
///   3. Accessibility permission (required for selected-text reading)
///   4. Notifications permission
///   5. Identity — name and email (required)
///   6. Customize — accent color and app icon
///   7. Privacy + done
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
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @State private var step: Int = 0
    @State private var nameDraft: String = ""
    @State private var emailDraft: String = ""
    @State private var identitySubmitting: Bool = false
    @State private var identityError: String?
    @State private var identitySaved: Bool = false

    private let stepCount = 7

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
            nameDraft = identity.name ?? ""
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

    private var accentColor: Color {
        vm.accentColor(scheme: colorScheme, contrast: colorSchemeContrast)
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
        case 5: stepCustomize
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
    /// unusable when the user declines it. Identity has no such bypass — a
    /// name and email must be saved locally (delivery to the server is
    /// queued and retried independently) before advancing.
    private var canAdvance: Bool {
        switch step {
        case 2: permissions.accessibilityGranted
        case 4: identity.hasIdentity
        default: true
        }
    }

    private var advanceBlockedReason: String? {
        if step == 2, !permissions.accessibilityGranted {
            return "Grant Accessibility access to continue"
        }
        if step == 4, !identity.hasIdentity {
            return "Save your name and email to continue"
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

            VStack(spacing: 8) {
                TextField(OnboardingCopy.identityNamePlaceholder, text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                TextField(OnboardingCopy.identityPlaceholder, text: $emailDraft)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .frame(maxWidth: 280)
                Button {
                    submitIdentity()
                } label: {
                    if identitySubmitting {
                        ProgressView().scaleEffect(0.6).frame(width: 80)
                    } else {
                        Text(OnboardingCopy.identitySaveButton).frame(width: 80)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(accentColor)
                .disabled(!canSaveIdentity || identitySubmitting)
            }

            if let err = identityError {
                Text(err).font(appFont(size: 11)).foregroundStyle(Palette.danger)
            } else if identitySaved || identity.hasIdentity {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.success)
                    Text(OnboardingCopy.identitySavedLabel).foregroundStyle(Palette.success)
                }.font(appFont(size: 12))
            } else {
                Text(" ")
                    .font(appFont(size: 12))
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private var canSaveIdentity: Bool {
        IdentityService.looksLikeName(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)) &&
            IdentityService.looksLikeEmail(emailDraft.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var stepCustomize: some View {
        VStack(spacing: 22) {
            Image(systemName: "paintpalette.fill")
                .font(.system(size: 52))
                .foregroundStyle(accentColor)
                .frame(width: Self.heroIconSize, height: Self.heroIconSize)
            Text(OnboardingCopy.customizeTitle)
                .font(appFont(size: 24, weight: .bold))
                .foregroundStyle(Palette.textPrimary)
            Text(OnboardingCopy.customizeBody)
                .font(appFont(size: 14))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                Text(OnboardingCopy.customizeAccentLabel)
                    .font(appFont(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                HStack(spacing: 14) {
                    ForEach(AccentColorOption.allCases, id: \.self) { option in
                        AccentSwatchButton(option: option, isSelected: vm.accentColorID == option) {
                            vm.accentColorID = option
                        }
                    }
                }
            }

            VStack(spacing: 10) {
                Text(OnboardingCopy.customizeIconLabel)
                    .font(appFont(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                HStack(spacing: 16) {
                    ForEach(AppIconOption.allCases) { option in
                        AppIconChoiceButton(option: option, isSelected: vm.appIconID == option) {
                            vm.appIconID = option
                        }
                    }
                }
            }
        }
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

    private func submitIdentity() {
        identityError = nil
        identitySaved = false
        guard canSaveIdentity else { return }
        identitySubmitting = true
        Task {
            defer { identitySubmitting = false }
            do {
                try await identity.submitIdentity(name: nameDraft, email: emailDraft)
                identitySaved = true
            } catch {
                identityError = (error as? IdentityService.IdentityError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func appFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        vm.appFont(size: size, weight: weight)
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

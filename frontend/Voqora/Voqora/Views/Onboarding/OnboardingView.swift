import AppKit
import SwiftUI

/// Six-step first-launch wizard.
///
/// Steps:
///   1. Welcome
///   2. Hotkey explanation
///   3. Accessibility permission (REQUIRED — blocks Next)
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

    @State private var step: Int = 0
    @State private var emailDraft: String = ""
    @State private var emailSubmitting: Bool = false
    @State private var emailError: String?
    @State private var emailSaved: Bool = false

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
            permissions.startPolling()
        }
        .onDisappear {
            permissions.stopPolling()
        }
    }

    // MARK: - Chrome

    private var backdrop: some View {
        LinearGradient(
            colors: [Color(nsColor: .windowBackgroundColor), Color(nsColor: .controlBackgroundColor)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var progressBar: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< stepCount, id: \.self) { idx in
                Capsule()
                    .fill(idx <= step ? Color.cyan : Color.secondary.opacity(0.25))
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
            if step == stepCount - 1 {
                Button(OnboardingCopy.doneButton) { coordinator.markCompleted() }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(OnboardingCopy.nextButton) { withAnimation { step += 1 } }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdvance)
                    .help(advanceBlockedReason ?? "")
            }
        }
        .padding(.horizontal, 40)
    }

    /// Step-specific Next-button gating.
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
                .font(.system(size: 32, weight: .bold))
                .multilineTextAlignment(.center)
            Text(OnboardingCopy.welcomeBody)
                .font(.system(size: 15))
                .foregroundStyle(.primary.opacity(0.78))
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
                .font(.system(size: 26, weight: .bold))
            Text(OnboardingCopy.hotkeyBody)
                .font(.system(size: 15))
                .foregroundStyle(.primary.opacity(0.78))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stepAccessibility: some View {
        VStack(spacing: 22) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 52))
                .foregroundStyle(.cyan.gradient)
            Text(OnboardingCopy.axTitle)
                .font(.system(size: 24, weight: .bold))
            Text(OnboardingCopy.axBody)
                .font(.system(size: 14))
                .foregroundStyle(.primary.opacity(0.78))
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
                .tint(.cyan)
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
                .foregroundStyle(.cyan.gradient)
            Text(OnboardingCopy.notifTitle)
                .font(.system(size: 24, weight: .bold))
            Text(OnboardingCopy.notifBody)
                .font(.system(size: 14))
                .foregroundStyle(.primary.opacity(0.78))
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
                .tint(.cyan)
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
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(OnboardingCopy.notifGrantedLabel).foregroundStyle(.green)
            }.font(.system(size: 12))
        case .denied:
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
                Text(OnboardingCopy.notifDeniedLabel).foregroundStyle(.secondary)
            }.font(.system(size: 12))
        default:
            Text(" ").font(.system(size: 12))
        }
    }

    private var stepIdentity: some View {
        VStack(spacing: 18) {
            Image(systemName: "envelope.fill")
                .font(.system(size: 52))
                .foregroundStyle(.cyan.gradient)
            Text(OnboardingCopy.identityTitle)
                .font(.system(size: 22, weight: .bold))
                .multilineTextAlignment(.center)
            Text(OnboardingCopy.identityBody)
                .font(.system(size: 14))
                .foregroundStyle(.primary.opacity(0.78))
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
                .tint(.cyan)
                .disabled(!canSaveEmail || emailSubmitting)
                .help(canSaveEmail ? "Save this optional email" : "Enter a valid email to enable Save")
            }

            if let err = emailError {
                Text(err).font(.system(size: 11)).foregroundStyle(.red)
            } else if emailSaved {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text(OnboardingCopy.identitySavedLabel).foregroundStyle(.green)
                }.font(.system(size: 12))
            } else {
                Text(emailDraft.isEmpty || canSaveEmail ? " " : "Enter a valid email to enable Save")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
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
                .foregroundStyle(.green.gradient)
            Text(OnboardingCopy.privacyTitle)
                .font(.system(size: 28, weight: .bold))
            Text(OnboardingCopy.privacyBody)
                .font(.system(size: 15))
                .foregroundStyle(.primary.opacity(0.78))
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
                .foregroundStyle(isGranted ? .green : .orange)
            Text(isGranted ? grantedLabel : pendingLabel)
                .foregroundStyle(isGranted ? .green : .secondary)
        }
        .font(.system(size: 12))
    }

    private func kbd(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 26, weight: .bold, design: .monospaced))
            .frame(width: 56, height: 56)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.background.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.secondary.opacity(0.5), lineWidth: 1)
            )
    }
}

import AppKit
import SwiftUI

struct OnboardingView: View {
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
                Button(OnboardingCopy.axContinueWithoutButton) {
                    withAnimation { step += 1 }
                }
                .buttonStyle(.bordered)
            }
            if step == stepCount - 1 {
                Button(OnboardingCopy.doneButton) { coordinator.markCompleted() }
                    .buttonStyle(.borderedProminent)
                    .tint(accentColor)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(OnboardingCopy.nextButton) { advance() }
                    .buttonStyle(.borderedProminent)
                    .tint(accentColor)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdvance)
            }
        }
        .padding(.horizontal, 40)
    }

    private var canAdvance: Bool {
        switch step {
        case 2: permissions.accessibilityGranted
        case 4: canSaveIdentity
        default: true
        }
    }

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
            VStack(alignment: .leading, spacing: 16) {
                ForEach(OnboardingCopy.features, id: \.title) { feature in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: feature.systemImage)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(accentColor)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(feature.title)
                                .font(appFont(size: 14, weight: .semibold))
                                .foregroundStyle(Palette.textPrimary)
                            Text(feature.body)
                                .font(appFont(size: 13))
                                .foregroundStyle(Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxWidth: 420, alignment: .leading)
            .padding(.top, 6)
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

            VStack(spacing: 8) {
                TextField(OnboardingCopy.identityNamePlaceholder, text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                TextField(OnboardingCopy.identityPlaceholder, text: $emailDraft)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .frame(maxWidth: 280)
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
            Text(OnboardingCopy.doneTitle)
                .font(appFont(size: 28, weight: .bold))
                .foregroundStyle(Palette.textPrimary)
            Text(OnboardingCopy.doneBody)
                .font(appFont(size: 15))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await vm.speak(text: OnboardingCopy.sampleText) }
            } label: {
                Label(OnboardingCopy.doneSampleButton, systemImage: "play.fill")
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .disabled(!vm.isBackendOnline)
        }
    }

    private func advance() {
        guard step == 4 else {
            withAnimation { step += 1 }
            return
        }
        Task {
            try? await identity.submitIdentity(name: nameDraft, email: emailDraft)
            withAnimation { step += 1 }
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

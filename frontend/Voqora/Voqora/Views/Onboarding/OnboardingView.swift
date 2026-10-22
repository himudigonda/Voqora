import AppKit
import SwiftUI

struct OnboardingView: View {
    static let heroSymbolSize: CGFloat = 56
    static let railWidth: CGFloat = 248
    static let railBreakpoint: CGFloat = 860

    var snapshotStep: Int?

    @EnvironmentObject var coordinator: OnboardingCoordinator
    @EnvironmentObject var permissions: PermissionsService
    @EnvironmentObject var identity: IdentityService
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var providers: LLMProviderStore
    @Environment(\.voqoraTheme) private var theme

    @State private var step: OnboardingStep = .welcome
    @State private var furthest: OnboardingStep = .welcome
    @State private var identityDraft = IdentityDraft()

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                if proxy.size.width >= Self.railBreakpoint {
                    rail
                }
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Space.section) {
                            header
                            content
                        }
                        .frame(maxWidth: 680, alignment: .leading)
                        .padding(.horizontal, Theme.Space.gutter)
                        .padding(.top, 56)
                        .padding(.bottom, Theme.Space.section)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .id(step)
                    footer
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.surface.ignoresSafeArea())
        .frame(minWidth: 720, minHeight: 560)
        .onAppear {
            let start = startingStep
            step = start
            furthest = snapshotStep == nil ? start : .done
            permissions.startPolling()
        }
        .onDisappear { permissions.stopPolling() }
        .onChange(of: snapshotStep) { _, newValue in
            if let newValue {
                step = OnboardingStep.clamped(newValue)
            }
        }
        .onChange(of: step) { oldValue, newValue in
            if oldValue == .privacy, snapshotStep == nil {
                savePrivacyChoices()
            }
            if newValue.rawValue > furthest.rawValue {
                furthest = newValue
            }
            if snapshotStep == nil {
                coordinator.recordStep(key: newValue.key)
            }
        }
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: Theme.Space.card) {
            HStack(spacing: Theme.Space.item) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Voqora")
                        .voqoraFont(.titleSmall)
                        .foregroundStyle(theme.onSurface)
                    Text("Setup")
                        .voqoraFont(.labelSmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                }
            }
            .padding(.horizontal, Theme.Space.item)
            ForEach(OnboardingStep.groups, id: \.self) { group in
                VStack(alignment: .leading, spacing: Theme.Space.listGap) {
                    Text(group)
                        .voqoraFont(.labelSmall)
                        .foregroundStyle(theme.onSurfaceMuted)
                        .padding(.horizontal, Theme.Space.item)
                        .padding(.bottom, 4)
                    ForEach(OnboardingStep.allCases.filter { $0.group == group }) { item in
                        railItem(item)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 56)
        .padding(.horizontal, Theme.Space.item)
        .padding(.bottom, Theme.Space.card)
        .frame(width: Self.railWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.surfaceContainerLow.ignoresSafeArea())
    }

    private func railItem(_ item: OnboardingStep) -> some View {
        let isCurrent = item == step
        let isSeen = coordinator.seenStepKeys.contains(item.key)
        let isDone = (item.rawValue < furthest.rawValue || isSeen) && !isCurrent && item != .done
        let isReachable = item.rawValue <= furthest.rawValue || isSeen
        return Button {
            go(to: item)
        } label: {
            HStack(spacing: Theme.Space.item) {
                Image(systemName: isDone ? "checkmark" : item.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isCurrent ? theme.onPrimary : (isDone ? theme.onPrimaryContainer : theme.onSurfaceVariant))
                    .frame(width: 26, height: 26)
                    .background(isCurrent ? theme.primary : (isDone ? theme.primaryContainer : theme.surfaceContainerHigh), in: Circle())
                Text(item.railTitle)
                    .voqoraFont(isCurrent ? .titleSmall : .label)
                    .foregroundStyle(isReachable ? theme.onSurface : theme.onSurfaceMuted)
                Spacer(minLength: 0)
                if item.isOptional {
                    Text("Optional")
                        .voqoraFont(.labelSmall)
                        .foregroundStyle(theme.onSurfaceMuted)
                }
            }
            .padding(.horizontal, Theme.Space.item)
            .frame(height: 38)
            .background(isCurrent ? theme.primaryContainer.opacity(0.7) : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isReachable)
        .animation(Theme.Motion.selection, value: step)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityValue(isDone ? "Done" : "")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.item + 4) {
            hero
            VStack(alignment: .leading, spacing: Theme.Space.item) {
                Text(title)
                    .voqoraFont(.display)
                    .foregroundStyle(theme.onSurface)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let body = subtitle {
                    Text(body)
                        .voqoraFont(.body)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var hero: some View {
        if step == .welcome {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
        } else {
            Image(systemName: step.systemImage)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(theme.onPrimaryContainer)
                .frame(width: Self.heroSymbolSize, height: Self.heroSymbolSize)
                .background(theme.primaryContainer, in: RoundedRectangle(cornerRadius: Theme.Shape.lg, style: .continuous))
                .accessibilityHidden(true)
        }
    }

    private var title: String {
        switch step {
        case .welcome: OnboardingCopy.welcomeTitle
        case .privacy: OnboardingCopy.privacyTitle
        case .permissions: OnboardingCopy.permissionsTitle
        case .engine: OnboardingCopy.engineTitle
        case .voice: OnboardingCopy.voiceTitle
        case .shortcuts: OnboardingCopy.shortcutsTitle
        case .dictation: OnboardingCopy.dictationTitle
        case .audiobooks: OnboardingCopy.audiobooksTitle
        case .ai: OnboardingCopy.aiTitle
        case .appearance: OnboardingCopy.appearanceTitle
        case .done: OnboardingCopy.doneTitle
        }
    }

    private var subtitle: String? {
        switch step {
        case .welcome: OnboardingCopy.welcomeBody
        case .privacy: OnboardingCopy.privacyBody
        case .permissions: OnboardingCopy.permissionsBody
        case .engine: OnboardingCopy.engineBody
        case .voice: OnboardingCopy.voiceBody
        case .shortcuts: OnboardingCopy.shortcutsBody
        case .dictation: OnboardingCopy.dictationBody
        case .audiobooks: OnboardingCopy.audiobooksBody
        case .ai: OnboardingCopy.aiBody
        case .appearance: OnboardingCopy.appearanceBody
        case .done: OnboardingCopy.doneBody
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcome
        case .privacy: OnboardingPrivacyStep(identityDraft: $identityDraft)
        case .permissions: OnboardingPermissionsStep()
        case .engine: OnboardingEngineStep()
        case .voice: SpeakingVoiceSections()
        case .shortcuts: OnboardingShortcutsStep()
        case .dictation: OnboardingDictationStep()
        case .audiobooks: AudiobookDefaultsSections()
        case .ai: OnboardingAIStep()
        case .appearance:
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                AppearancePreviewCard()
                AppearanceLookSection()
            }
        case .done: OnboardingSummaryStep(jump: go(to:), openSettings: finish(openingTab:))
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.item) {
            if step != .welcome {
                Button(OnboardingCopy.backButton) { go(to: OnboardingStep.clamped(step.rawValue - 1)) }
                    .buttonStyle(.voqoraText)
            }
            Spacer()
            Text("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
                .voqoraFont(.labelSmall)
                .foregroundStyle(theme.onSurfaceMuted)
            if step == .permissions, !permissions.accessibilityGranted {
                Button(OnboardingCopy.axContinueWithoutButton) { advance() }
                    .buttonStyle(.voqoraText)
            }
            if step == .done {
                Button(OnboardingCopy.doneButton) { finish(openingTab: nil) }
                    .buttonStyle(.voqoraFilled)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(primaryTitle) { advance() }
                    .buttonStyle(.voqoraFilled)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdvance)
            }
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.vertical, Theme.Space.card)
        .background(theme.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.outlineVariant.opacity(0.6)).frame(height: 1)
        }
    }

    private var primaryTitle: String {
        if step == .ai, providers.connectedProviders.isEmpty {
            return OnboardingCopy.aiSkipButton
        }
        if step == .privacy, identityDraft.validation != .valid {
            return OnboardingCopy.privacySkipButton
        }
        return OnboardingCopy.nextButton
    }

    private var canAdvance: Bool {
        switch step {
        case .permissions: permissions.accessibilityGranted
        default: true
        }
    }

    private var startingStep: OnboardingStep {
        if let snapshotStep {
            return OnboardingStep.clamped(snapshotStep)
        }
        if let key = coordinator.resumeStepKey, let resumed = OnboardingStep(key: key) {
            return resumed
        }
        return OnboardingStep.firstUnseen(in: coordinator.seenStepKeys)
    }

    private func go(to target: OnboardingStep) {
        withAnimation(Theme.Motion.selection) { step = target }
    }

    private func finish(openingTab tab: String?) {
        if let tab {
            vm.selectedTab = tab
        }
        coordinator.markCompleted()
    }

    private func advance() {
        guard snapshotStep == nil else {
            go(to: step.nextUnseen(in: coordinator.seenStepKeys))
            return
        }
        coordinator.markSeen(key: step.key)
        go(to: step.nextUnseen(in: coordinator.seenStepKeys))
    }

    private func savePrivacyChoices() {
        if !SetupChecklist.analyticsDecided() {
            UserDefaults.standard.set(false, forKey: MetricsService.analyticsEnabledKey)
        }
        let draft = identityDraft
        guard draft.validation == .valid else { return }
        Task { _ = try? await draft.commit(to: identity) }
    }

    private var welcome: some View {
        Grid(horizontalSpacing: Theme.Space.item, verticalSpacing: Theme.Space.item) {
            ForEach(Array(stride(from: 0, to: OnboardingCopy.features.count, by: 2)), id: \.self) { index in
                GridRow {
                    featureCard(OnboardingCopy.features[index])
                    if index + 1 < OnboardingCopy.features.count {
                        featureCard(OnboardingCopy.features[index + 1])
                    }
                }
            }
        }
    }

    private func featureCard(_ feature: OnboardingCopy.Feature) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            ListItemIcon(systemImage: feature.systemImage)
            Text(feature.title)
                .voqoraFont(.titleSmall)
                .foregroundStyle(theme.onSurface)
            Text(feature.body)
                .voqoraFont(.body)
                .foregroundStyle(theme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.card)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.surfaceContainer, in: RoundedRectangle(cornerRadius: Theme.Shape.lg, style: .continuous))
    }
}

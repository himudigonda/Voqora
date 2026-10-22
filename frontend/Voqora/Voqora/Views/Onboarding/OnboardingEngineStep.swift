import SwiftUI

nonisolated enum OnboardingEngineChoice {
    static let kokoroDefaultVoice = "af_bella"

    static func voice(switching current: String, to engineID: String, in engines: [SpeechEngine]) -> String? {
        if SpeechEngineID.engine(forVoice: current) == engineID {
            return current
        }
        if engineID == SpeechEngineID.kokoro {
            return kokoroDefaultVoice
        }
        guard let engine = engines.first(where: { $0.id == engineID }), engine.installed else { return nil }
        let builtIn = engine.voices.filter { !$0.custom }
        return (builtIn.first { $0.lang.lowercased().hasPrefix("en") } ?? builtIn.first ?? engine.voices.first)?.id
    }
}

struct OnboardingEngineStep: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @Environment(\.voqoraTheme) private var theme
    @ObservedObject private var store = SpeechEngineStore.shared
    @State private var pendingEngine: String?

    private var selectedEngine: String {
        SpeechEngineID.engine(forVoice: vm.selectedVoice)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.card) {
            OnboardingCallout(systemImage: "bolt.fill", text: SharedSettingsCopy.engineRecommendation)
            if store.engines.isEmpty {
                VoqoraCard {
                    HStack(spacing: Theme.Space.item) {
                        if vm.isBackendOnline {
                            ProgressView().controlSize(.small)
                        }
                        Text(vm.isBackendOnline ? OnboardingCopy.engineLoading : OnboardingCopy.engineOffline)
                            .voqoraFont(.body)
                            .foregroundStyle(theme.onSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: Theme.Space.item) {
                    ForEach(orderedEngines) { engine in
                        OnboardingEngineCard(
                            engine: engine,
                            isSelected: engine.id == selectedEngine,
                            isOnline: vm.isBackendOnline,
                            select: { select(engine) },
                            install: { install(engine) }
                        )
                    }
                }
            }
            if let message = store.actionError {
                SettingsNoticeRow(text: message, kind: .danger)
            }
        }
        .task(id: vm.isBackendOnline) {
            if vm.isBackendOnline {
                await store.refresh()
            }
        }
        .onChange(of: store.revision) { _, _ in
            guard let pending = pendingEngine, let engine = store.engine(id: pending), engine.installed else { return }
            pendingEngine = nil
            select(engine)
        }
    }

    private var orderedEngines: [SpeechEngine] {
        let order = [SpeechEngineID.kokoro, SpeechEngineID.ming, SpeechEngineID.supertonic]
        return store.engines.sorted { (order.firstIndex(of: $0.id) ?? order.count) < (order.firstIndex(of: $1.id) ?? order.count) }
    }

    private func select(_ engine: SpeechEngine) {
        guard engine.installed else {
            install(engine)
            return
        }
        if pendingEngine != engine.id {
            pendingEngine = nil
        }
        guard let voice = OnboardingEngineChoice.voice(switching: vm.selectedVoice, to: engine.id, in: store.engines) else { return }
        bookVM.defaultBookVoice = VoiceSync.bookVoice(current: bookVM.defaultBookVoice, previousSpeaking: vm.selectedVoice, newSpeaking: voice)
        vm.selectedVoice = voice
    }

    private func install(_ engine: SpeechEngine) {
        pendingEngine = engine.id
        Task { await store.install(engine.id) }
    }
}

private struct OnboardingEngineCard: View {
    let engine: SpeechEngine
    let isSelected: Bool
    let isOnline: Bool
    let select: () -> Void
    let install: () -> Void

    @Environment(\.voqoraTheme) private var theme
    @State private var isHovering = false

    private var isRecommended: Bool {
        engine.id == SpeechEngineID.kokoro
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.card) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(isSelected ? theme.primary : theme.onSurfaceMuted)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.item) {
                HStack(spacing: Theme.Space.item) {
                    Text(engine.name)
                        .voqoraFont(.title)
                        .foregroundStyle(theme.onSurface)
                    if isRecommended {
                        StatusChip(text: OnboardingCopy.engineRecommendedBadge, kind: .success, systemImage: "star.fill")
                    }
                    Spacer(minLength: Theme.Space.item)
                    trailing
                }
                Text(OnboardingCopy.enginePurpose(engine.id))
                    .voqoraFont(.body)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Space.section) {
                    fact("Speed", OnboardingCopy.engineSpeed(engine.id))
                    if !engine.voices.isEmpty {
                        fact("Voices", "\(engine.voices.count)")
                    }
                    if !engine.languages.isEmpty {
                        fact("Languages", "\(engine.languages.count)")
                    }
                    fact("Download", engine.isBuiltIn ? "Built in" : (engine.sizeDescription ?? "Optional"))
                }
                if engine.downloading {
                    HStack(spacing: Theme.Space.item) {
                        ProgressView(value: engine.clampedProgress)
                            .tint(theme.primary)
                        Text(SpeechEngineRowText.percent(engine.progress))
                            .voqoraFont(.label)
                            .monospacedDigit()
                            .foregroundStyle(theme.onSurfaceVariant)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Downloading \(engine.name)")
                    .accessibilityValue(SpeechEngineRowText.percent(engine.progress))
                }
                if let error = engine.error, !engine.installed, !engine.downloading {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .voqoraFont(.bodySmall)
                        .foregroundStyle(theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Theme.Space.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: Theme.Shape.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Shape.lg, style: .continuous)
                .strokeBorder(isSelected ? theme.primary : .clear, lineWidth: 2)
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.Shape.lg, style: .continuous))
        .onTapGesture {
            if engine.installed {
                select()
            }
        }
        .onHover { isHovering = $0 }
        .animation(Theme.Motion.hover, value: isHovering)
        .animation(Theme.Motion.selection, value: isSelected)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var background: Color {
        if isSelected {
            return theme.secondaryContainer
        }
        return isHovering && engine.installed ? theme.surfaceContainerHigh : theme.surfaceContainer
    }

    @ViewBuilder
    private var trailing: some View {
        if engine.downloading {
            StatusChip(text: "Downloading", kind: .info)
        } else if engine.installed {
            if isSelected {
                StatusChip(text: "Selected", kind: .success, systemImage: "checkmark.circle.fill")
            } else {
                Button("Use \(engine.name)", action: select)
                    .buttonStyle(.voqoraTonal)
            }
        } else {
            Button(action: install) {
                Label(engine.error == nil ? "Download" : "Try Again", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.voqoraFilled)
            .disabled(!isOnline)
        }
    }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .voqoraFont(.labelSmall)
                .foregroundStyle(theme.onSurfaceMuted)
            Text(value)
                .voqoraFont(.label)
                .foregroundStyle(theme.onSurface)
                .lineLimit(1)
        }
    }
}

struct OnboardingCallout: View {
    let systemImage: String
    let text: String

    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.item) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.onPrimaryContainer)
                .frame(width: 32, height: 32)
                .background(theme.primaryContainer, in: Circle())
                .accessibilityHidden(true)
            Text(text)
                .voqoraFont(.body)
                .foregroundStyle(theme.onSurface)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        }
        .padding(Theme.Space.item + 4)
        .background(theme.primaryContainer.opacity(0.35), in: RoundedRectangle(cornerRadius: Theme.Shape.lg, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

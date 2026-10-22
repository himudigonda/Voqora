import SwiftUI

struct SpeechEnginesSection: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    @ObservedObject var store: SpeechEngineStore
    @State private var pendingRemoval: SpeechEngine?

    @MainActor
    init(store: SpeechEngineStore? = nil) {
        self.store = store ?? .shared
    }

    static let licenseNote = "Supertonic's code is MIT licensed. Its voice model is released under OpenRAIL-M, which includes " +
        "use restrictions. Both are listed in the app's third-party notices."

    static let mingLicenseNote = "Ming-3.0-tts is released under the MIT license."

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            if store.engines.isEmpty {
                EmptyStateView(
                    symbol: "cpu",
                    title: vm.isBackendOnline ? "Loading speech engines" : "Speech engines are not ready",
                    message: vm.isBackendOnline ? "This only takes a moment." : "Speech engines appear once Voqora has started."
                )
            } else {
                ForEach(store.engines) { engine in
                    EngineCard(engine: engine, isOnline: vm.isBackendOnline, install: { install(engine) }, remove: { pendingRemoval = engine })
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
        .confirmationDialog(
            "Remove \(pendingRemoval?.name ?? "engine")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: {
                if !$0 {
                    pendingRemoval = nil
                }
            }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { engine in
            Button("Remove \(engine.name)", role: .destructive) { remove(engine) }
        } message: { engine in
            Text("Anything set to a \(engine.name) voice switches to Bella. You can download it again at any time.")
        }
    }

    private func install(_ engine: SpeechEngine) {
        Task { await store.install(engine.id) }
    }

    private func remove(_ engine: SpeechEngine) {
        Task { await store.uninstall(engine.id) }
    }
}

private struct EngineCard: View {
    let engine: SpeechEngine
    let isOnline: Bool
    let install: () -> Void
    let remove: () -> Void

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        VoqoraCard {
            VStack(alignment: .leading, spacing: Theme.Space.item + 4) {
                HStack(alignment: .top, spacing: Theme.Space.item) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: Theme.Space.item) {
                            Text(engine.name)
                                .voqoraFont(.title)
                                .foregroundStyle(theme.onSurface)
                            statusChip
                        }
                        Text(Self.purpose(for: engine))
                            .voqoraFont(.body)
                            .foregroundStyle(theme.onSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Theme.Space.card)
                    actions
                }
                facts
                if engine.downloading {
                    progress
                }
                if let error = engine.error, !engine.installed, !engine.downloading {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .voqoraFont(.bodySmall)
                        .foregroundStyle(theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let notice = engine.trimmedNotice {
                    Label(notice, systemImage: "hourglass")
                        .voqoraFont(.bodySmall)
                        .foregroundStyle(theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = licenseNote {
                    Text(note)
                        .voqoraFont(.bodySmall)
                        .foregroundStyle(theme.onSurfaceMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var licenseNote: String? {
        switch engine.id {
        case SpeechEngineID.supertonic: SpeechEnginesSection.licenseNote
        case SpeechEngineID.ming: SpeechEnginesSection.mingLicenseNote
        default: nil
        }
    }

    @ViewBuilder
    private var statusChip: some View {
        if engine.isBuiltIn {
            StatusChip(text: "Built in", kind: .success, systemImage: "checkmark.circle.fill")
        } else if engine.downloading {
            StatusChip(text: "Downloading \(SpeechEngineRowText.percent(engine.progress))", kind: .info)
        } else if engine.installed {
            StatusChip(text: "Installed", kind: .success, systemImage: "checkmark.circle.fill")
        } else if engine.error != nil {
            StatusChip(text: "Failed", kind: .danger)
        } else {
            StatusChip(text: "Not installed", kind: .neutral)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if engine.isBuiltIn {
            EmptyView()
        } else if engine.downloading {
            ProgressView()
                .controlSize(.small)
        } else if engine.installed {
            HStack(spacing: Theme.Space.item) {
                if engine.id == SpeechEngineID.ming {
                    Button {
                        vm.selectedTab = VoicesPage.myVoices.tab
                    } label: {
                        Label("Create Ming Voices", systemImage: "waveform.badge.mic")
                    }
                    .buttonStyle(.voqoraTonal)
                }
                Button("Remove", action: remove)
                    .buttonStyle(.voqoraOutlined)
                    .disabled(!isOnline)
            }
        } else {
            Button(action: install) {
                Label(engine.error == nil ? "Install" : "Try Again", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.voqoraFilled)
            .disabled(!isOnline)
        }
    }

    private var facts: some View {
        HStack(alignment: .top, spacing: Theme.Space.section) {
            if let size = engine.sizeDescription {
                fact("Size", size)
            }
            if !engine.license.isEmpty {
                fact("License", engine.license)
            }
            if !engine.languages.isEmpty {
                fact("Languages", "\(engine.languages.count)")
            }
            if !engine.voices.isEmpty {
                fact("Voices", "\(engine.voices.count)")
            }
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

    private var progress: some View {
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

    private static func purpose(for engine: SpeechEngine) -> String {
        switch engine.id {
        case SpeechEngineID.kokoro: "Fast, natural voices that come with Voqora. Always available, even offline."
        case SpeechEngineID.supertonic: "A lightweight engine with extra voices in many languages."
        case SpeechEngineID.ming: "An expressive engine that can design and clone voices. It runs slower than real time."
        default: SpeechEngineRowText.subtitle(for: engine)
        }
    }
}

nonisolated enum SpeechEngineRowText {
    static func subtitle(for engine: SpeechEngine) -> String {
        if engine.isBuiltIn {
            return "Included with Voqora. Fast, with \(engine.voices.count) voices in \(engine.languages.count) languages."
        }
        var parts = ["Optional"]
        if let size = engine.sizeDescription {
            parts.append(size)
        }
        if !engine.languages.isEmpty {
            parts.append("\(engine.languages.count) languages")
        }
        if !engine.voices.isEmpty {
            parts.append("\(engine.voices.count) voices")
        }
        parts.append(engine.license)
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func percent(_ progress: Double) -> String {
        "\(Int((min(max(progress, 0), 1) * 100).rounded()))%"
    }
}

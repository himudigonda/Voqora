import SwiftUI

struct SpeechEnginesSection: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ObservedObject var store: SpeechEngineStore
    @State private var pendingRemoval: SpeechEngine?

    init(store: SpeechEngineStore = .shared) {
        self.store = store
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if store.engines.isEmpty {
                placeholder
            } else {
                ForEach(Array(store.engines.enumerated()), id: \.element.id) { index, engine in
                    if index > 0 {
                        Divider()
                    }
                    SpeechEngineRow(engine: engine, accent: accent, install: { install(engine) }, remove: { pendingRemoval = engine })
                }
            }
            if let message = store.actionError {
                Text(message)
                    .font(vm.font(.rowSubtitle))
                    .foregroundStyle(Palette.danger)
            }
            Text(Self.licenseNote)
                .font(vm.font(.rowSubtitle))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
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

    static let licenseNote = "Supertonic's code is MIT licensed. Its voice model is released under OpenRAIL-M, which includes " +
        "use restrictions. Both are listed in the app's third-party notices."

    private var accent: Color {
        vm.accentColor(scheme: colorScheme, contrast: contrast)
    }

    private var placeholder: some View {
        Text(vm.isBackendOnline ? "Loading speech engines..." : "Speech engines appear once Voqora has started.")
            .font(vm.font(.rowSubtitle))
            .foregroundStyle(Palette.textSecondary)
    }

    private func install(_ engine: SpeechEngine) {
        Task { await store.install(engine.id) }
    }

    private func remove(_ engine: SpeechEngine) {
        Task { await store.uninstall(engine.id) }
    }
}

private struct SpeechEngineRow: View {
    @EnvironmentObject var vm: DashboardViewModel
    let engine: SpeechEngine
    let accent: Color
    let install: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(engine.name)
                    .font(vm.font(.rowTitle))
                Text(SpeechEngineRowText.subtitle(for: engine))
                    .font(vm.font(.rowSubtitle))
                    .foregroundStyle(Palette.textSecondary)
                if let error = engine.error, !engine.installed, !engine.downloading {
                    Text(error)
                        .font(vm.font(.rowSubtitle))
                        .foregroundStyle(Palette.danger)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var trailing: some View {
        if engine.isBuiltIn {
            Label("Built in", systemImage: "checkmark.circle.fill")
                .font(vm.font(.rowSubtitle))
                .foregroundStyle(Palette.textSecondary)
        } else if engine.downloading {
            HStack(spacing: 10) {
                ProgressView(value: engine.clampedProgress)
                    .tint(accent)
                    .frame(width: 110)
                Text(SpeechEngineRowText.percent(engine.progress))
                    .font(vm.appFont(size: 12, weight: .bold).monospaced())
                    .foregroundStyle(accent)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Downloading \(engine.name)")
            .accessibilityValue(SpeechEngineRowText.percent(engine.progress))
        } else if engine.installed {
            Button("Remove", action: remove)
                .buttonStyle(.voqoraSecondary)
                .disabled(!vm.isBackendOnline)
        } else {
            Button(action: install) {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.voqoraPrimary)
            .disabled(!vm.isBackendOnline)
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

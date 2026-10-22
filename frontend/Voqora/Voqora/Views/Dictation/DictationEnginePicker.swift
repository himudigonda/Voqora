import SwiftUI

nonisolated enum DictationEngineCopy {
    static func detail(_ engine: DictationEngineChoice) -> String {
        switch engine {
        case .apple: "Built into macOS. Many languages. Needs Speech Recognition access."
        case .parakeet: "NVIDIA Parakeet on this Mac. 25 European languages."
        case .bark: "Underdog Bark on this Mac. English only. Keeps every word, including \u{201C}um\u{201D} and repeats."
        case .barkClean: "Bark that leaves out \u{201C}um\u{201D}, \u{201C}uh\u{201D}, false starts and repeats, so the text reads cleanly. English only."
        }
    }

    static func systemImage(_ engine: DictationEngineChoice) -> String {
        switch engine {
        case .apple: "apple.logo"
        case .parakeet: "bird"
        case .bark: "waveform"
        case .barkClean: "wand.and.sparkles"
        }
    }

    static let recommended: DictationEngineChoice = .barkClean

    static let footer = "Parakeet, Bark and Bark Clean download once from Hugging Face, then run fully on this Mac. Until the one you pick is installed, dictation uses Apple."

    static func footer(engine: DictationEngineChoice, localeIdentifier: String) -> String {
        guard engine == .bark || engine == .barkClean, !isEnglish(localeIdentifier) else { return footer }
        return "\(engine.title) understands English only, and your dictation language isn't English. Pick Apple or Parakeet for other languages. " + footer
    }

    static func isEnglish(_ localeIdentifier: String) -> Bool {
        let locale = localeIdentifier.isEmpty ? Locale.current : Locale(identifier: localeIdentifier)
        return locale.language.languageCode?.identifier == "en"
    }
}

struct DictationEnginePicker: View {
    @AppStorage(DictationPreferences.engineKey) private var engine: DictationEngineChoice = .apple
    @AppStorage(DictationPreferences.localeKey) private var localeIdentifier = ""

    var body: some View {
        SettingsSection(title: "Recognition engine", footer: DictationEngineCopy.footer(engine: engine, localeIdentifier: localeIdentifier)) {
            DictationAppleEngineRow(selection: $engine)
            ForEach(LocalSpeechModel.allCases) { model in
                DictationLocalEngineRow(model: model, models: .store(for: model), selection: $engine)
            }
        }
    }
}

private struct DictationAppleEngineRow: View {
    @Binding var selection: DictationEngineChoice

    var body: some View {
        SettingsRowShell(
            title: DictationEngineChoice.apple.title,
            detail: DictationEngineCopy.detail(.apple),
            systemImage: DictationEngineCopy.systemImage(.apple),
            isInteractive: selection != .apple
        ) {
            DictationEngineSelectControl(isSelected: selection == .apple) { selection = .apple }
        }
        .onTapGesture { selection = .apple }
        .accessibilityAddTraits(selection == .apple ? .isSelected : [])
    }
}

private struct DictationLocalEngineRow: View {
    let model: LocalSpeechModel
    @ObservedObject var models: LocalSpeechModelStore
    @Binding var selection: DictationEngineChoice
    @State private var installedBytes: Int64?
    @State private var removalFailure: String?

    private var choice: DictationEngineChoice {
        DictationEngineChoice.allCases.first { $0.localModel == model } ?? .apple
    }

    private var isSelected: Bool {
        selection == choice
    }

    var body: some View {
        SettingsRowShell(title: model.title, detail: detail, systemImage: DictationEngineCopy.systemImage(choice), isInteractive: !isSelected) {
            HStack(spacing: Theme.Space.item) {
                if choice == DictationEngineCopy.recommended, !isSelected {
                    StatusChip(text: "Recommended", kind: .success, systemImage: "star.fill")
                }
                trailing
            }
        }
        .onTapGesture(perform: choose)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onAppear { models.refresh() }
        .task(id: models.state) { installedBytes = await Self.byteCount(of: models.directory, installed: models.isInstalled) }
    }

    @ViewBuilder
    private var trailing: some View {
        switch models.state {
        case .notInstalled, .failed:
            Button(action: download) {
                Label(models.state == .notInstalled ? "Download" : "Try Again", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.voqoraTonal)
        case let .downloading(fraction):
            if let fraction {
                ProgressView(value: fraction).frame(width: 96)
            } else {
                ProgressView().controlSize(.small)
            }
        case .installed:
            if models.isPreparing {
                ProgressView().controlSize(.small)
            } else {
                Button("Remove", action: remove)
                    .buttonStyle(.voqoraText)
            }
            DictationEngineSelectControl(isSelected: isSelected, action: choose)
        }
    }

    private var detail: String {
        let summary = DictationEngineCopy.detail(choice)
        switch models.state {
        case .notInstalled:
            return "\(summary) Downloads \(model.downloadDescription) once."
        case let .downloading(fraction):
            return fraction.map { "Downloading… \(Int($0 * 100))%" } ?? "Downloading…"
        case let .failed(message):
            return "Download failed. \(message)"
        case .installed:
            if models.isPreparing {
                return "Getting ready for first use. This can take a minute or two."
            }
            if let removalFailure {
                return removalFailure
            }
            guard let installedBytes else { return summary }
            return "\(summary) Installed, \(ByteCountFormatter.string(fromByteCount: installedBytes, countStyle: .file))."
        }
    }

    private func choose() {
        selection = choice
        if models.state == .notInstalled {
            download()
        }
    }

    private func download() {
        removalFailure = nil
        selection = choice
        Task { await models.download() }
    }

    private func remove() {
        do {
            try models.remove()
            removalFailure = nil
        } catch {
            removalFailure = "Couldn't remove the model. \(error.localizedDescription)"
        }
    }

    private static func byteCount(of directory: URL, installed: Bool) async -> Int64? {
        guard installed else { return nil }
        return await Task.detached {
            let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            var total: Int64 = 0
            while let url = files?.nextObject() as? URL {
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
            return total > 0 ? total : nil
        }.value
    }
}

private struct DictationEngineSelectControl: View {
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        if isSelected {
            StatusChip(text: "Selected", kind: .success, systemImage: "checkmark.circle.fill")
        } else {
            Button("Use", action: action)
                .buttonStyle(.voqoraTonal)
        }
    }
}

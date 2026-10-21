import SwiftUI

struct DescribeVoiceSheet: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: SpeechEngineStore
    @ObservedObject var model: MingVoiceStudioModel

    static let examples: [(title: String, description: String)] = [
        ("Warm baritone", "A warm, unhurried baritone with a slight rasp"),
        ("Bright and friendly", "A bright, friendly young woman who sounds like she is smiling"),
        ("Calm narrator", "A calm documentary narrator with a deep, measured voice"),
        ("Energetic host", "An energetic podcast host, quick and upbeat"),
    ]

    private var languages: [String] {
        MingVoiceLanguage.options(from: store.engine(id: SpeechEngineID.ming))
    }

    private var isInstalled: Bool {
        !store.mingNeedsInstall
    }

    private var primaryTitle: String? {
        guard isInstalled else { return nil }
        if model.lastCreated != nil {
            return "Done"
        }
        return model.work == .designing ? "Designing…" : "Create Voice"
    }

    private var canSubmit: Bool {
        model.lastCreated != nil || (model.designDraft.isValid && !model.isWorking && vm.isBackendOnline)
    }

    var body: some View {
        VoqoraSheet(
            title: "Describe a voice",
            supporting: "Type what it should sound like. Ming designs a new voice from your words.",
            primaryTitle: primaryTitle,
            isPrimaryEnabled: canSubmit,
            width: 600,
            onPrimary: primaryAction,
            onClose: close
        ) {
            MingInstallGate(store: store) {
                VStack(alignment: .leading, spacing: Theme.Space.card) {
                    if let created = model.lastCreated {
                        VoiceResultRow(voice: created, model: model)
                    } else {
                        form
                    }
                    if let message = model.errorMessage {
                        VoicesBanner(message: message)
                    }
                }
                .padding(.bottom, Theme.Space.unit)
            }
        }
        .onAppear { model.clearResult() }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Theme.Space.card) {
            VoiceTextField(title: "Name", prompt: "Late-night narrator", text: $model.designDraft.name)
            VoiceLanguageMenu(selection: $model.designDraft.language, options: languages)
            VoiceTextField(
                title: "What should it sound like?",
                prompt: "A warm, unhurried baritone with a slight rasp",
                text: $model.designDraft.description,
                lines: 3 ... 5
            )
            WrapLayout(spacing: 8) {
                ForEach(Self.examples, id: \.title) { example in
                    AssistChip(title: example.title, systemImage: "sparkles") {
                        model.designDraft.description = example.description
                    }
                }
            }
            VoiceTextField(title: "Sample sentence (optional)", prompt: "Used to preview the voice", text: $model.designDraft.sampleText, lines: 1 ... 3)
            if model.work == .designing {
                VoiceProgressNote(text: "Designing… this takes about a minute")
            }
        }
        .disabled(model.isWorking)
    }

    private func primaryAction() {
        if model.lastCreated != nil {
            close()
        } else {
            Task { await model.submitDesign() }
        }
    }

    private func close() {
        model.clearResult()
        dismiss()
    }
}

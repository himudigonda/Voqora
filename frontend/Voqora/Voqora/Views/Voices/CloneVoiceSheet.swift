import SwiftUI

struct CloneVoiceSheet: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: SpeechEngineStore
    @ObservedObject var model: MingVoiceStudioModel
    @State private var choosingFile = false

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
        return model.work == .cloning ? "Cloning…" : "Clone Voice"
    }

    private var canSubmit: Bool {
        model.lastCreated != nil || (model.cloneDraft.isValid && !model.isWorking && vm.isBackendOnline)
    }

    var body: some View {
        VoqoraSheet(
            title: "Clone a voice",
            supporting: "Use a 3–30 second recording of a voice you have the right to use.",
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
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: MingVoiceAudio.importTypes) { result in
            if case let .success(url) = result {
                model.chooseRecording(url)
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Theme.Space.card) {
            VoiceTextField(title: "Name", prompt: "My voice", text: $model.cloneDraft.name)
            VoiceLanguageMenu(selection: $model.cloneDraft.language, options: languages)
            VoiceFormField(title: "Recording") {
                recordingRow
            }
            VoiceTextField(
                title: "What is said in the recording",
                prompt: "Type the words exactly as spoken",
                text: $model.cloneDraft.transcript,
                lines: 2 ... 4
            )
            Toggle(isOn: $model.cloneDraft.hasRights) {
                Text("I have the right to use this voice")
                    .font(vm.font(.body))
                    .foregroundStyle(theme.onSurface)
            }
            .toggleStyle(.checkbox)
            .tint(theme.primary)
            if model.work == .cloning {
                VoiceProgressNote(text: "Cloning… this can take a little while")
            }
        }
        .disabled(model.isWorking)
    }

    private var recordingRow: some View {
        HStack(spacing: Theme.Space.item) {
            if let url = model.cloneDraft.fileURL {
                VoicePlayButton(
                    name: url.lastPathComponent,
                    isPlaying: model.playingID == MingVoiceStudioModel.recordingPreviewID,
                    isLoading: model.loadingSampleID == MingVoiceStudioModel.recordingPreviewID
                ) {
                    model.toggleRecordingPreview()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .font(vm.font(.body))
                        .foregroundStyle(theme.onSurface)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(durationNote)
                        .font(vm.font(.bodySmall))
                        .foregroundStyle(isDurationOutOfRange ? theme.warning : theme.onSurfaceVariant)
                }
            } else {
                Text("WAV, FLAC, AIFF or MP3")
                    .font(vm.font(.bodySmall))
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            Spacer(minLength: 0)
            Button {
                choosingFile = true
            } label: {
                Label(model.cloneDraft.fileURL == nil ? "Choose Recording…" : "Change…", systemImage: "waveform")
            }
            .buttonStyle(.voqoraTonal)
        }
    }

    private var isDurationOutOfRange: Bool {
        guard let seconds = model.recordingDuration else { return false }
        return seconds < 5 || seconds > 30
    }

    private var durationNote: String {
        guard let seconds = model.recordingDuration else { return "Reading recording…" }
        let label = Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
        return isDurationOutOfRange ? "\(label) · works best between 5 and 30 seconds" : label
    }

    private func primaryAction() {
        if model.lastCreated != nil {
            close()
        } else {
            Task { await model.submitClone() }
        }
    }

    private func close() {
        model.clearResult()
        dismiss()
    }
}

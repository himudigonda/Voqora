import SwiftUI

struct PronunciationTestCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    @ObservedObject var store: PronunciationStore
    @Binding var text: String

    var body: some View {
        VoqoraCard {
            VStack(alignment: .leading, spacing: Theme.Space.item) {
                Text("Test your rules")
                    .font(vm.font(.titleSmall))
                    .foregroundStyle(theme.onSurface)
                HStack(spacing: Theme.Space.item) {
                    TextField("Type a sentence to hear how Voqora says it", text: $text)
                        .textFieldStyle(.plain)
                        .font(vm.font(.body))
                        .foregroundStyle(theme.onSurface)
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .background(theme.surfaceContainerHigh, in: Capsule())
                        .onSubmit(run)
                        .accessibilityLabel("Test sentence")
                    Button(action: run) {
                        if store.isTesting {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Play", systemImage: "play.fill")
                        }
                    }
                    .buttonStyle(.voqoraFilled)
                    .disabled(store.isTesting || !vm.isBackendOnline)
                    .help(vm.isBackendOnline ? "Hear this sentence with your pronunciations" : "Voqora is still starting.")
                }
                if let error = store.testError {
                    Text(error)
                        .font(vm.font(.bodySmall))
                        .foregroundStyle(theme.danger)
                } else if let result = store.testResult {
                    resultView(result)
                }
            }
        }
    }

    private func resultView(_ result: PronunciationTestResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Voqora will say")
                .font(vm.font(.bodySmall))
                .foregroundStyle(theme.onSurfaceVariant)
            Text(result.spoken.isEmpty ? "Nothing. Every word in this sentence is skipped." : result.spoken)
                .font(vm.font(.body))
                .foregroundStyle(theme.onSurface)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(Self.replacementSummary(result.replacements))
                    .font(vm.font(.bodySmall))
                    .foregroundStyle(theme.onSurfaceMuted)
                Spacer()
                if let sentence = Self.playbackText(for: result) {
                    Button {
                        play(sentence)
                    } label: {
                        Label("Play Again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.voqoraTonal)
                    .disabled(!vm.isBackendOnline)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func playbackText(for result: PronunciationTestResult) -> String? {
        result.spoken.isEmpty ? nil : result.text
    }

    static func replacementSummary(_ count: Int) -> String {
        switch count {
        case 0: "No pronunciations matched."
        case 1: "1 replacement."
        default: "\(count) replacements."
        }
    }

    private func run() {
        guard !store.isTesting else { return }
        Task {
            await store.runTest(text)
            if let sentence = store.testResult.flatMap(Self.playbackText(for:)) {
                play(sentence)
            }
        }
    }

    private func play(_ sentence: String) {
        Task { await SpeechSource.$current.withValue(.sample) { await vm.speak(text: sentence, bookID: store.bookID) } }
    }
}

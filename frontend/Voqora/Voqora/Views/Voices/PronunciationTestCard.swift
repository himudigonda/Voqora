import SwiftUI

struct PronunciationTestCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    @ObservedObject var store: PronunciationStore
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            PaneSectionHeader(title: "Test")
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                HStack(spacing: DesignTokens.Spacing.md) {
                    TextField("Type a sentence to hear how Voqora says it", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .font(vm.font(.rowTitle))
                        .onSubmit(run)
                        .accessibilityLabel("Test sentence")
                    Button(action: run) {
                        if store.isTesting {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Test", systemImage: "play.fill")
                        }
                    }
                    .buttonStyle(.voqoraPrimary)
                    .disabled(store.isTesting || !vm.isBackendOnline)
                    .help(vm.isBackendOnline ? "Hear this sentence with your pronunciations" : "Voqora is still starting.")
                }
                if let error = store.testError {
                    Text(error)
                        .font(vm.font(.rowSubtitle))
                        .foregroundStyle(Palette.danger)
                } else if let result = store.testResult {
                    resultView(result)
                }
            }
            .padding(DesignTokens.Layout.cardInset)
            .voqoraSurface(.raised, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xLarge, style: .continuous))
        }
    }

    private func resultView(_ result: PronunciationTestResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Voqora will say")
                .font(vm.font(.rowSubtitle))
                .foregroundStyle(Palette.textSecondary)
            Text(result.spoken.isEmpty ? "Nothing. Every word in this sentence is skipped." : result.spoken)
                .font(vm.appFont(size: 14, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(Self.replacementSummary(result.replacements))
                    .font(vm.font(.caption))
                    .foregroundStyle(Palette.textTertiary)
                Spacer()
                if !result.spoken.isEmpty {
                    Button {
                        play(result.spoken)
                    } label: {
                        Label("Play Again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.voqoraSecondary)
                    .disabled(!vm.isBackendOnline)
                }
            }
        }
        .accessibilityElement(children: .combine)
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
            if let spoken = store.testResult?.spoken, !spoken.isEmpty {
                play(spoken)
            }
        }
    }

    private func play(_ spoken: String) {
        Task { await vm.speak(text: spoken) }
    }
}

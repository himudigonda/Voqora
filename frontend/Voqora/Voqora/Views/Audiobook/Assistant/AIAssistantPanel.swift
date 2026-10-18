import SwiftUI

struct AIAssistantPanel: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var providers: LLMProviderStore
    @ObservedObject var model: AIAssistantViewModel
    let onCitation: (AICitation) -> Void

    var body: some View {
        if providers.activeProvider == nil {
            AIConnectProviderState()
        } else {
            VStack(spacing: DesignTokens.Spacing.md) {
                Picker("Assistant Tool", selection: $model.tab) {
                    ForEach(AIAssistantViewModel.Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
                .accessibilityLabel("Assistant Tool")

                Group {
                    switch model.tab {
                    case .summary: AISummaryTab(model: model.summary)
                    case .ask: AIAskTab(model: model.ask, onCitation: onCitation)
                    case .quiz: AIQuizTab(model: model.quiz)
                    case .flashcards: AIFlashcardsTab(model: model.flashcards)
                    }
                }
                .frame(maxWidth: 640, maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, 20)
            .padding(.top, DesignTokens.Spacing.xs)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

struct AISummaryTab: View {
    @EnvironmentObject var vm: DashboardViewModel
    @ObservedObject var model: AISummaryModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                AIOptionsCard {
                    Picker("Length", selection: $model.length) {
                        ForEach(AISummaryLength.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Language", selection: $model.language) {
                        Text("Same as Book").tag(AILanguage?.none)
                        Divider()
                        ForEach(AILanguage.allCases) { Text($0.displayName).tag(AILanguage?.some($0)) }
                    }
                    HStack {
                        Spacer()
                        Button(model.state.value == nil ? "Summarize Book" : "Summarize Again") { model.generate() }
                            .buttonStyle(.voqoraPrimary)
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(model.state.isLoading)
                    }
                }
                content
            }
            .padding(.vertical, DesignTokens.Spacing.sm)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            Text("Choose a length and language, then summarize. Long books can take a few minutes.")
                .font(vm.font(.rowSubtitle))
                .foregroundStyle(Palette.textSecondary)
        case .loading:
            AIProgressState(title: "Summarizing…") { model.cancel() }
                .frame(minHeight: 160)
        case let .failed(error):
            AIErrorBanner(error: error) { model.generate() }
        case let .loaded(result):
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                Text(result.summary)
                    .font(vm.appFont(size: 15))
                    .foregroundStyle(Palette.textPrimary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                AIResultActions(text: result.summary, language: model.resultLanguage)
                AIUsageFootnote(usage: result.usage)
            }
        }
    }
}

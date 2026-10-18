import SwiftUI

struct AIQuizTab: View {
    @EnvironmentObject var vm: DashboardViewModel
    @ObservedObject var model: AIQuizModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                AIOptionsCard {
                    Picker("Difficulty", selection: $model.difficulty) {
                        ForEach(AIQuizDifficulty.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Stepper(value: $model.count, in: AIReadingLimits.quizCounts) {
                        Text("\(model.count) questions")
                            .font(vm.font(.rowTitle))
                    }
                    .accessibilityValue("\(model.count) questions")
                    HStack {
                        Spacer()
                        Button(model.state.value == nil ? "Create Quiz" : "New Quiz") { model.generate() }
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
            Text("Test what you remember with multiple choice questions about this book.")
                .font(vm.font(.rowSubtitle))
                .foregroundStyle(Palette.textSecondary)
        case .loading:
            AIProgressState(title: "Writing questions…") { model.cancel() }
                .frame(minHeight: 160)
        case let .failed(error):
            AIErrorBanner(error: error) { model.generate() }
        case let .loaded(quiz):
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                scoreHeader
                ForEach(Array(model.session.questions.enumerated()), id: \.offset) { index, question in
                    AIQuizQuestionCard(
                        number: index + 1,
                        question: question,
                        selected: model.session.choice(for: index)
                    ) { choice in
                        model.select(choice, for: index)
                    }
                }
                AIUsageFootnote(usage: quiz.usage)
            }
        }
    }

    private var scoreHeader: some View {
        let session = model.session
        return HStack {
            Text(session.isComplete
                ? "You scored \(session.score) of \(session.questions.count)"
                : "\(session.answeredCount) of \(session.questions.count) answered")
                .font(vm.font(.sectionTitle))
                .foregroundStyle(Palette.textPrimary)
                .contentTransition(.numericText())
            Spacer()
            if session.answeredCount > 0 {
                Button("Retake") { model.restart() }
                    .buttonStyle(.voqoraSecondary)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct AIQuizQuestionCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    let number: Int
    let question: AIQuizQuestion
    let selected: Int?
    let onSelect: (Int) -> Void

    var body: some View {
        AIOptionsCard {
            Text("\(number). \(question.question)")
                .font(vm.font(.rowTitle).weight(.semibold))
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: DesignTokens.Spacing.xs) {
                ForEach(Array(question.choices.enumerated()), id: \.offset) { index, choice in
                    choiceRow(index: index, text: choice)
                }
            }
            if let selected {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    Label(
                        selected == question.answerIndex ? "Correct" : "Not quite",
                        systemImage: selected == question.answerIndex ? "checkmark.circle.fill" : "xmark.circle.fill"
                    )
                    .font(vm.font(.rowSubtitle).weight(.semibold))
                    .foregroundStyle(selected == question.answerIndex ? Palette.success : Palette.danger)
                    if !question.explanation.isEmpty {
                        Text(question.explanation)
                            .font(vm.font(.rowSubtitle))
                            .foregroundStyle(Palette.textSecondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                AIResultActions(text: resultText, language: nil)
            }
        }
    }

    private var resultText: String {
        let answer = question.choices.indices.contains(question.answerIndex) ? question.choices[question.answerIndex] : ""
        return [question.question, answer, question.explanation]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func choiceRow(index: Int, text: String) -> some View {
        let answered = selected != nil
        let isAnswer = index == question.answerIndex
        let isPicked = index == selected
        let tint: Color = answered && isAnswer ? Palette.success : (isPicked ? Palette.danger : Palette.textTertiary)
        let symbol = answered && isAnswer ? "checkmark.circle.fill" : (isPicked ? "xmark.circle.fill" : "circle")
        return Button {
            onSelect(index)
        } label: {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(text)
                    .font(vm.font(.rowTitle))
                    .foregroundStyle(Palette.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xs + 2)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.xs, style: .continuous)
                    .fill(isPicked || (answered && isAnswer) ? Palette.controlFill : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(answered)
        .accessibilityLabel(text)
        .accessibilityValue(answered ? (isAnswer ? "Correct answer" : (isPicked ? "Your answer, incorrect" : "")) : "")
        .accessibilityAddTraits(isPicked ? [.isSelected] : [])
    }
}

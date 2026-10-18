import SwiftUI

struct AIFlashcardsTab: View {
    @EnvironmentObject var vm: DashboardViewModel
    @ObservedObject var model: AIFlashcardsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                AIOptionsCard {
                    Stepper(value: $model.count, in: AIReadingLimits.flashcardCounts) {
                        Text("\(model.count) cards")
                            .font(vm.font(.rowTitle))
                    }
                    .accessibilityValue("\(model.count) cards")
                    HStack {
                        Spacer()
                        Button(model.state.value == nil ? "Create Flashcards" : "New Deck") { model.generate() }
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
            Text("Study key ideas from this book with flip cards. Mark the ones you know to skip them.")
                .font(vm.font(.rowSubtitle))
                .foregroundStyle(Palette.textSecondary)
        case .loading:
            AIProgressState(title: "Writing flashcards…") { model.cancel() }
                .frame(minHeight: 160)
        case let .failed(error):
            AIErrorBanner(error: error) { model.generate() }
        case let .loaded(deck):
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                AIFlashcardDeckView(model: model)
                AIUsageFootnote(usage: deck.usage)
            }
        }
    }
}

private struct AIFlashcardDeckView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: AIFlashcardsModel

    var body: some View {
        let session = model.session
        VStack(spacing: DesignTokens.Spacing.md) {
            HStack {
                Text("Card \(session.index + 1) of \(session.cards.count)")
                    .font(vm.font(.rowSubtitle).weight(.semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .monospacedDigit()
                Spacer()
                Text(session.isComplete ? "You know every card" : "\(session.knownCount) known")
                    .font(vm.font(.rowSubtitle))
                    .foregroundStyle(session.isComplete ? Palette.success : Palette.textSecondary)
            }
            if let card = session.current {
                cardFace(card, flipped: session.isFlipped, known: session.isCurrentKnown)
                AIResultActions(text: session.isFlipped ? card.back : card.front, language: nil)
            }
            HStack(spacing: DesignTokens.Spacing.sm) {
                Button {
                    model.previous()
                } label: {
                    Label("Previous", systemImage: "chevron.left")
                }
                .buttonStyle(.voqoraSecondary)
                .disabled(!session.canGoBack)
                .keyboardShortcut(.leftArrow, modifiers: .command)
                Spacer()
                Button {
                    model.toggleKnown()
                } label: {
                    Label(session.isCurrentKnown ? "Known" : "Mark Known", systemImage: session.isCurrentKnown ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .buttonStyle(.voqoraSecondary)
                .keyboardShortcut("k", modifiers: .command)
                .accessibilityAddTraits(session.isCurrentKnown ? [.isSelected] : [])
                if session.knownCount > 0 {
                    Button("Start Over") { model.restart() }
                        .buttonStyle(.voqoraSecondary)
                }
                Spacer()
                Button {
                    model.next()
                } label: {
                    Label("Next", systemImage: "chevron.right")
                }
                .buttonStyle(.voqoraSecondary)
                .disabled(!session.canGoForward)
                .keyboardShortcut(.rightArrow, modifiers: .command)
            }
        }
    }

    private func cardFace(_ card: AIFlashcard, flipped: Bool, known: Bool) -> some View {
        let text = flipped ? card.back : card.front
        return Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85)) { model.flip() }
        } label: {
            VStack(spacing: DesignTokens.Spacing.md) {
                Text(flipped ? "Answer" : "Question")
                    .font(vm.font(.sectionHeader))
                    .foregroundStyle(Palette.textTertiary)
                    .textCase(.uppercase)
                Text(text)
                    .font(vm.appFont(size: flipped ? 15 : 18, weight: flipped ? .regular : .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(flipped ? "Click to see the question" : "Click to reveal the answer")
                    .font(vm.font(.caption))
                    .foregroundStyle(Palette.textTertiary)
            }
            .padding(DesignTokens.Spacing.xl)
            .frame(maxWidth: .infinity, minHeight: 200)
            .voqoraSurface(.raised, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xLarge, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if known {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Palette.success)
                        .padding(DesignTokens.Spacing.md)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(flipped ? "Answer: \(card.back)" : "Question: \(card.front)")
        .accessibilityHint(flipped ? "Shows the question" : "Shows the answer")
        .accessibilityAddTraits(known ? [.isSelected] : [])
    }
}

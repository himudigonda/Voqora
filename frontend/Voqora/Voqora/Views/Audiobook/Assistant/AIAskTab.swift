import SwiftUI

struct AIAskTab: View {
    @EnvironmentObject var vm: DashboardViewModel
    @ObservedObject var model: AIAskModel
    let onCitation: (AICitation) -> Void
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                        if model.messages.isEmpty {
                            emptyState
                        }
                        ForEach(model.messages) { message in
                            AIChatBubble(message: message, onCitation: onCitation)
                                .id(message.id)
                        }
                        if model.isSending {
                            HStack(spacing: DesignTokens.Spacing.sm) {
                                ProgressView().controlSize(.small)
                                Text("Reading the book…")
                                    .font(vm.font(.rowSubtitle))
                                    .foregroundStyle(Palette.textSecondary)
                                Button("Cancel") { model.cancel() }
                                    .buttonStyle(.borderless)
                                    .font(vm.font(.rowSubtitle))
                            }
                            .id("ai-ask-progress")
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.vertical, DesignTokens.Spacing.sm)
                }
                .onChange(of: model.messages.count) { _, _ in
                    guard let last = model.messages.last else { return }
                    withAnimation(DesignTokens.Animation.standard) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            if let error = model.error {
                AIErrorBanner(error: error) { model.send() }
            }
            composer
        }
        .padding(.bottom, DesignTokens.Spacing.md)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("Ask about this book")
                .font(vm.font(.sectionTitle))
                .foregroundStyle(Palette.textPrimary)
            Text("Answers come from the book's text. Tap a citation to jump to that passage.")
                .font(vm.font(.rowSubtitle))
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(.top, DesignTokens.Spacing.sm)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: DesignTokens.Spacing.sm) {
            TextField("Ask a question", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(vm.font(.rowTitle))
                .lineLimit(1 ... 4)
                .focused($composerFocused)
                .onSubmit { model.send() }
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, DesignTokens.Spacing.sm)
                .voqoraSurface(.control, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
                .accessibilityLabel("Question")
            Button {
                model.send()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
            }
            .buttonStyle(.voqoraPrimary)
            .disabled(!model.canSend)
            .accessibilityLabel("Send Question")
            .help("Send")
            if !model.messages.isEmpty {
                Button {
                    model.clear()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                }
                .buttonStyle(.voqoraSecondary)
                .accessibilityLabel("Clear Conversation")
                .help("Clear Conversation")
            }
        }
        .onAppear { composerFocused = true }
    }
}

private struct AIChatBubble: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    let message: AIAskModel.Message
    let onCitation: (AICitation) -> Void

    private var isUser: Bool {
        message.role == .user
    }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: DesignTokens.Spacing.sm) {
            Text(message.text)
                .font(vm.font(.rowTitle))
                .foregroundStyle(isUser ? vm.onAccentColor(scheme: colorScheme, contrast: contrast) : Palette.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, DesignTokens.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                        .fill(isUser ? vm.accentColor(scheme: colorScheme, contrast: contrast) : Palette.surfaceRaised)
                )
                .accessibilityLabel(isUser ? "You asked: \(message.text)" : "Answer: \(message.text)")
            if !message.citations.isEmpty {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    ForEach(Array(message.citations.enumerated()), id: \.offset) { index, citation in
                        AICitationButton(number: index + 1, citation: citation) { onCitation(citation) }
                    }
                }
            }
            if !isUser {
                AIResultActions(text: message.text, language: nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }
}

private struct AICitationButton: View {
    @EnvironmentObject var vm: DashboardViewModel
    let number: Int
    let citation: AICitation
    let action: () -> Void
    @State private var hovering = false

    private var location: String {
        let section = citation.sectionTitle.map(AudiobookImportStaging.displayName(from:))
        guard let section, !section.isEmpty else { return "Page \(citation.page)" }
        return "\(section), page \(citation.page)"
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                Text("\(number)")
                    .font(vm.font(.caption).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Palette.controlFill))
                VStack(alignment: .leading, spacing: 2) {
                    Text(location)
                        .font(vm.font(.rowSubtitle).weight(.semibold))
                        .foregroundStyle(Palette.textPrimary)
                    if !citation.quote.isEmpty {
                        Text("\u{201C}\(citation.quote)\u{201D}")
                            .font(vm.font(.rowSubtitle))
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.forward.circle")
                    .foregroundStyle(Palette.textTertiary)
            }
            .padding(DesignTokens.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                    .fill(hovering ? Palette.controlFill : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Citation \(number), \(location)")
        .accessibilityHint("Plays the book from this passage")
    }
}

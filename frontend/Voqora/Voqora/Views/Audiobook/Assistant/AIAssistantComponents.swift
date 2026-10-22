import AppKit
import SwiftUI

struct AIConnectProviderState: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    @EnvironmentObject var providers: LLMProviderStore
    @State private var addingProvider = false

    private var needsChoice: Bool {
        !providers.connectedProviders.isEmpty
    }

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: "sparkles")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(theme.onPrimaryContainer)
                .frame(width: 64, height: 64)
                .background(theme.primaryContainer.opacity(0.65), in: Circle())
                .accessibilityHidden(true)
            Text(needsChoice ? "Choose an AI Provider" : "Connect an AI Provider")
                .font(vm.font(.title))
                .foregroundStyle(theme.onSurface)
            Text(
                needsChoice
                    ? "Pick which connected provider Voqora uses in Settings > AI."
                    : "Summaries, questions, quizzes and flashcards use an AI provider you connect. Local providers keep the book on your Mac."
            )
            .font(vm.font(.body))
            .foregroundStyle(theme.onSurfaceVariant)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 360)
            HStack(spacing: DesignTokens.Spacing.sm) {
                if !needsChoice {
                    Button("Connect a Provider…") { addingProvider = true }
                        .buttonStyle(.voqoraFilled)
                }
                Button("Open Settings > AI") { AppWindows.openSettings(tab: .ai) }
                    .buttonStyle(.voqoraTonal)
            }
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $addingProvider) {
            AddProviderSheet()
                .environmentObject(vm)
                .environmentObject(providers)
        }
    }
}

struct AIProgressState: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    let title: String
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            ProgressView().controlSize(.small)
            Text(title)
                .font(vm.font(.body))
                .foregroundStyle(theme.onSurfaceVariant)
            Button("Cancel", action: onCancel)
                .buttonStyle(.voqoraTonal)
                .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

struct AIErrorBanner: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    let error: AIReadingError
    let onRetry: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Text(error.message)
                    .font(vm.font(.body))
                    .foregroundStyle(theme.onSurface)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DesignTokens.Spacing.sm) {
                    if let onRetry, error.isRetryable {
                        Button("Try Again", action: onRetry)
                            .buttonStyle(.voqoraTonal)
                    }
                    if error.kind == .providerRequired || error.kind == .providerSettings || error.kind == .provider {
                        Button("Open Settings > AI") { AppWindows.openSettings(tab: .ai) }
                            .buttonStyle(.voqoraTonal)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DesignTokens.Spacing.md)
        .background(theme.surfaceContainer, in: RoundedRectangle(cornerRadius: Theme.Shape.lg, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

struct AIResultActions: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    let text: String
    let language: AILanguage?
    @State private var copied = false

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Button {
                AIResultActions.copy(text)
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.voqoraTonal)
            .accessibilityLabel(copied ? "Copied" : "Copy to clipboard")
            Button {
                speak()
            } label: {
                Label("Speak", systemImage: "speaker.wave.2")
            }
            .buttonStyle(.voqoraTonal)
            .accessibilityLabel("Speak aloud")
            .help("Speak aloud with your current voice. The audiobook pauses; Continue Listening picks it up where you left off.")
        }
        .onChange(of: text) { _, _ in copied = false }
    }

    private func speak() {
        let voice = language.map { AIVoiceMatcher.voice(for: $0, current: vm.selectedVoice) }
            ?? LanguageDetector.voiceForText(text, fallback: vm.selectedVoice)
        Task { await vm.speakAIResult(text: text, voice: voice) }
    }

    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

struct AIUsageFootnote: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    let usage: AIUsage

    var body: some View {
        Text(AIUsageFormatter.summary(usage))
            .font(vm.font(.labelSmall))
            .foregroundStyle(theme.onSurfaceVariant)
    }
}

nonisolated enum AIUsageFormatter {
    static func summary(_ usage: AIUsage) -> String {
        let provider = LLMProvider(rawValue: usage.provider)?.displayName ?? usage.provider
        var parts = [usage.model.isEmpty ? provider : "\(provider) · \(usage.model)"]
        if usage.tokens > 0 {
            let tokens = usage.tokens.formatted(.number)
            parts.append(usage.tokensEstimated ? "about \(tokens) tokens" : "\(tokens) tokens")
        }
        if let cost = usage.costUSD, cost > 0 {
            parts.append(cost < 0.01 ? "under $0.01" : cost.formatted(.currency(code: "USD")))
        }
        return parts.joined(separator: " · ")
    }
}

struct AIOptionsCard<Content: View>: View {
    @Environment(\.voqoraTheme) private var theme
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            content()
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceContainer, in: RoundedRectangle(cornerRadius: Theme.Shape.lg, style: .continuous))
    }
}

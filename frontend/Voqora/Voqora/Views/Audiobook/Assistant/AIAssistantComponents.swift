import AppKit
import SwiftUI

struct AIConnectProviderState: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var providers: LLMProviderStore
    @State private var addingProvider = false

    private var needsChoice: Bool {
        !providers.connectedProviders.isEmpty
    }

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: "sparkles")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Palette.textSecondary)
                .accessibilityHidden(true)
            Text(needsChoice ? "Choose an AI Provider" : "Connect an AI Provider")
                .font(vm.font(.sectionTitle))
                .foregroundStyle(Palette.textPrimary)
            Text(
                needsChoice
                    ? "Pick which connected provider Voqora uses in Preferences > AI."
                    : "Summaries, questions, quizzes and flashcards use an AI provider you connect. Local providers keep the book on your Mac."
            )
            .font(vm.font(.rowTitle))
            .foregroundStyle(Palette.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 360)
            HStack(spacing: DesignTokens.Spacing.sm) {
                if !needsChoice {
                    Button("Connect a Provider…") { addingProvider = true }
                        .buttonStyle(.voqoraPrimary)
                }
                Button("Open Preferences > AI") { vm.selectedTab = "preferences" }
                    .buttonStyle(.voqoraSecondary)
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
    let title: String
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            ProgressView().controlSize(.small)
            Text(title)
                .font(vm.font(.rowTitle))
                .foregroundStyle(Palette.textSecondary)
            Button("Cancel", action: onCancel)
                .buttonStyle(.voqoraSecondary)
                .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

struct AIErrorBanner: View {
    @EnvironmentObject var vm: DashboardViewModel
    let error: AIReadingError
    let onRetry: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Text(error.message)
                    .font(vm.font(.rowTitle))
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DesignTokens.Spacing.sm) {
                    if let onRetry, error.isRetryable {
                        Button("Try Again", action: onRetry)
                            .buttonStyle(.voqoraSecondary)
                    }
                    if error.kind == .providerRequired || error.kind == .providerSettings || error.kind == .provider {
                        Button("Open Preferences > AI") { vm.selectedTab = "preferences" }
                            .buttonStyle(.voqoraSecondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DesignTokens.Spacing.md)
        .voqoraSurface(.raised, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

struct AIResultActions: View {
    @EnvironmentObject var vm: DashboardViewModel
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
            .buttonStyle(.voqoraSecondary)
            .accessibilityLabel(copied ? "Copied" : "Copy to clipboard")
            Button {
                speak()
            } label: {
                Label("Speak", systemImage: "speaker.wave.2")
            }
            .buttonStyle(.voqoraSecondary)
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
    let usage: AIUsage

    var body: some View {
        Text(AIUsageFormatter.summary(usage))
            .font(vm.font(.caption))
            .foregroundStyle(Palette.textTertiary)
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
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            content()
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .voqoraSurface(.raised, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large, style: .continuous))
    }
}

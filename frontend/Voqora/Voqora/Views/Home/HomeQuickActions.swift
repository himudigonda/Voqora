import KeyboardShortcuts
import SwiftUI

struct HomeQuickActions: View {
    @EnvironmentObject var vm: DashboardViewModel

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: Theme.Space.item + 4, alignment: .top)]

    private var readShortcut: String {
        KeyboardShortcuts.getShortcut(for: .playText)?.description ?? "⌘⇧."
    }

    private var dictationShortcut: String {
        DictationController.shortcutLabel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            HomeSectionHeader(title: "Quick actions")
            LazyVGrid(columns: columns, spacing: Theme.Space.item + 4) {
                ReadSelectedTextCard(shortcut: readShortcut)
                OptionCard(
                    title: "New Audiobook",
                    supporting: "Turn a document, web page, or pasted text into audio.",
                    systemImage: "book.closed"
                ) {
                    vm.selectedTab = TabKey.createAudiobook
                }
                OptionCard(
                    title: "New Podcast",
                    supporting: "Generate a two-host conversation about a book or text.",
                    systemImage: "waveform.and.mic"
                ) {
                    vm.selectedTab = TabKey.createPodcast
                }
                OptionCard(
                    title: "Dictate",
                    supporting: "Press \(dictationShortcut) anywhere, speak, and Voqora types it.",
                    systemImage: "mic",
                    badge: dictationShortcut
                ) {
                    vm.selectedTab = TabKey.dictation
                }
            }
        }
    }
}

struct HomeSectionHeader: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    let title: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack {
            Text(title)
                .font(vm.font(.title))
                .foregroundStyle(theme.onSurface)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.voqoraText)
            }
        }
    }
}

private struct ReadSelectedTextCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    let shortcut: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            HStack(alignment: .top) {
                Image(systemName: "text.cursor")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(theme.onPrimaryContainer)
                    .frame(width: 52, height: 52)
                    .background(theme.primaryContainer.opacity(0.65), in: Circle())
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                StatusChip(text: shortcut, kind: .info)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Read selected text")
                    .font(vm.font(.title))
                    .foregroundStyle(theme.onSurface)
                Text("Select text in any app, then press \(shortcut).")
                    .font(vm.font(.body))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Hear a Sample") {
                Task { await SpeechSource.$current.withValue(.sample) { await vm.speak(text: OnboardingCopy.sampleText) } }
            }
            .buttonStyle(.voqoraTonal)
            .disabled(!vm.isBackendOnline)
        }
        .padding(Theme.Space.card)
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
        .voqoraCardBackground(.filled)
    }
}

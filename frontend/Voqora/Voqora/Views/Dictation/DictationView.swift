import AppKit
import KeyboardShortcuts
import SwiftUI

struct DictationView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var dictation: DictationController
    @EnvironmentObject var transcripts: DictationTranscriptStore
    @ObservedObject private var permissions = PermissionsService.shared
    @Environment(\.voqoraTheme) private var theme
    @AppStorage(DictationPreferences.localeKey) private var localeIdentifier = ""
    @State private var searchText = ""
    @State private var confirmingClear = false
    @State private var microphone = DictationPermissionStatus.granted
    @State private var speechRecognition = DictationPermissionStatus.granted

    private var gaps: [DictationAccessGap] {
        DictationAccessGaps.make(microphone: microphone, speechRecognition: speechRecognition, accessibilityGranted: permissions.accessibilityGranted)
    }

    private var languageLabel: String {
        localeIdentifier.isEmpty ? "System language" : (Locale.current.localizedString(forIdentifier: localeIdentifier) ?? localeIdentifier)
    }

    var body: some View {
        let matches = DictationTranscriptStore.matching(transcripts.transcripts, query: searchText)
        PageScaffold(
            title: "Dictation",
            subtitle: "Speak in any app and Voqora types what you said at your cursor."
        ) {
            DictationHeroCard(languageLabel: languageLabel) {
                vm.selectedTab = TabKey.settings(.dictation)
            }
            if !gaps.isEmpty {
                DictationPermissionCard(gaps: gaps, permissions: permissions)
            }
            if dictation.phase == .idle, let issue = dictation.issue, issue.settingsPane == nil {
                DictationNoteCard(message: issue.message)
            }
            transcriptSection(matches)
        }
        .navigationTitle("Dictation")
        .onAppear(perform: refreshAccess)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshAccess() }
        .confirmationDialog("Clear Transcripts?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear Transcripts", role: .destructive) { transcripts.clear() }
        } message: {
            Text("This removes every saved dictation transcript from this Mac.")
        }
    }

    private func refreshAccess() {
        let authorizer = SystemDictationAuthorizer()
        microphone = authorizer.microphoneStatus()
        speechRecognition = authorizer.speechRecognitionStatus()
        permissions.refreshAccessibility()
    }

    private func transcriptSection(_ matches: [DictationTranscript]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            HStack(spacing: Theme.Space.item) {
                Text("Recent transcripts")
                    .font(vm.font(.title))
                    .foregroundStyle(theme.onSurface)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Theme.Space.item)
                SearchField(text: $searchText, prompt: "Search transcripts")
                    .frame(width: 240)
                PageActionsMenu {
                    Button("Clear Transcripts…", role: .destructive) { confirmingClear = true }
                        .disabled(transcripts.transcripts.isEmpty)
                }
            }
            if let persistenceError = transcripts.persistenceError {
                DictationNoteCard(message: persistenceError, actionTitle: "Try Again") { transcripts.retryPersistence() }
            }
            if matches.isEmpty {
                EmptyStateView(
                    symbol: transcripts.transcripts.isEmpty ? "text.quote" : "magnifyingglass",
                    title: transcripts.transcripts.isEmpty ? "No transcripts yet" : "No matches",
                    message: emptyMessage
                )
            } else {
                ListGroup {
                    ForEach(matches) { transcript in
                        DictationTranscriptRow(transcript: transcript)
                    }
                }
            }
        }
    }

    private var emptyMessage: String {
        guard transcripts.transcripts.isEmpty else {
            return "No transcripts match “\(searchText)”."
        }
        return "What you dictate appears here. Voqora keeps the last \(DictationTranscriptStore.capacity) transcripts on this Mac."
    }
}

private struct DictationHeroCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var dictation: DictationController
    @Environment(\.voqoraTheme) private var theme
    let languageLabel: String
    let openSettings: () -> Void

    private var keycaps: [String] {
        DictationStateLabel.keycaps(from: KeyboardShortcuts.getShortcut(for: .toggleDictation).map { "\($0)" })
    }

    private var isActive: Bool {
        dictation.phase != .idle
    }

    var body: some View {
        VoqoraCard {
            HStack(alignment: .center, spacing: Theme.Space.section) {
                VStack(alignment: .leading, spacing: Theme.Space.item) {
                    Text("Your shortcut")
                        .font(vm.font(.label))
                        .foregroundStyle(theme.onSurfaceVariant)
                    HStack(spacing: 8) {
                        if keycaps.isEmpty {
                            Text("Not set")
                                .font(vm.font(.title))
                                .foregroundStyle(theme.onSurfaceMuted)
                        }
                        ForEach(Array(keycaps.enumerated()), id: \.offset) { _, key in
                            Keycap(label: key)
                        }
                    }
                    Text("Try it: click into any text field, press the shortcut, say something, then press it again.")
                        .font(vm.font(.bodySmall))
                        .foregroundStyle(theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Space.card)
                VStack(alignment: .trailing, spacing: Theme.Space.item) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(isActive ? theme.primary : theme.success)
                            .frame(width: 10, height: 10)
                        Text(DictationStateLabel.title(for: dictation.phase, isTidying: dictation.isTidying))
                            .font(vm.font(.title))
                            .foregroundStyle(theme.onSurface)
                    }
                    .accessibilityElement(children: .combine)
                    StatusChip(text: languageLabel, kind: .info, systemImage: "globe")
                    Button(action: openSettings) {
                        Label("Dictation settings", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.voqoraTonal)
                }
            }
        }
    }
}

private struct Keycap: View {
    let label: String

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        Text(label)
            .font(vm.appFont(size: label.count > 1 ? 18 : 28, weight: .semibold))
            .foregroundStyle(theme.onPrimaryContainer)
            .frame(minWidth: 56, minHeight: 56)
            .padding(.horizontal, label.count > 1 ? 10 : 0)
            .background(theme.primaryContainer, in: RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 0, y: 2)
            .accessibilityHidden(true)
    }
}

private struct DictationPermissionCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    let gaps: [DictationAccessGap]
    @ObservedObject var permissions: PermissionsService

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            Label("Dictation needs a little access", systemImage: "lock.shield")
                .font(vm.font(.titleSmall))
                .foregroundStyle(theme.onSurface)
            VStack(spacing: Theme.Space.listGap) {
                ForEach(gaps) { gap in
                    ListItem(
                        title: gap.title,
                        supporting: gap.detail,
                        leading: { ListItemIcon(systemImage: "exclamationmark.triangle", tint: theme.warning) },
                        trailing: {
                            Button(actionTitle(for: gap)) { open(gap) }
                                .buttonStyle(.voqoraFilled)
                        }
                    )
                }
            }
            .padding(Theme.Space.listGap)
            .background(theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Shape.lg, style: .continuous))
        }
    }

    private func actionTitle(for gap: DictationAccessGap) -> String {
        gap.pane == .accessibility ? "Allow Accessibility" : "Open System Settings"
    }

    private func open(_ gap: DictationAccessGap) {
        if gap.pane == .accessibility {
            permissions.requestAccessibility()
        } else if let url = gap.pane.url {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct DictationNoteCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: Theme.Space.item) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.warning)
                .accessibilityHidden(true)
            Text(message)
                .font(vm.font(.body))
                .foregroundStyle(theme.onSurface)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.voqoraTonal)
            }
        }
        .padding(Theme.Space.item + 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous))
    }
}

struct DictationTranscriptRow: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var transcripts: DictationTranscriptStore
    @Environment(\.voqoraTheme) private var theme
    let transcript: DictationTranscript
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.item + 4) {
            VStack(alignment: .leading, spacing: 4) {
                Text(transcript.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(vm.font(.bodySmall))
                    .foregroundStyle(theme.onSurfaceVariant)
                Text(transcript.text)
                    .font(vm.font(.body))
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: copy) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.voqoraIcon)
            .help("Copy")
            .accessibilityLabel("Copy transcript")
            Button { transcripts.delete(transcript) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.voqoraIcon)
            .help("Delete")
            .accessibilityLabel("Delete transcript")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isHovering ? theme.surfaceContainerHigh : theme.surfaceContainer,
            in: RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous)
        )
        .animation(Theme.Motion.hover, value: isHovering)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Copy", action: copy)
            Divider()
            Button("Delete", role: .destructive) { transcripts.delete(transcript) }
        }
    }

    private func copy() {
        SystemPasteboard().write(transcript.text, transient: false)
    }
}

struct PageSectionHeader: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    let title: String

    var body: some View {
        Text(title)
            .font(vm.font(.titleSmall))
            .foregroundStyle(theme.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

import SwiftUI

struct InboxItemRow: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var inbox: InboxViewModel
    @Environment(\.voqoraTheme) private var theme
    let item: InboxItem
    let speed: Double
    @State private var hovering = false

    private var isListening: Bool {
        inbox.listeningItemID == item.id
    }

    private var listeningTime: String {
        InboxListeningTime.label(wordCount: item.wordCount, speed: speed)
    }

    private var supporting: String {
        [item.siteLabel, listeningTime].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 16) {
            SiteAvatar(label: item.siteLabel)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(vm.font(.body))
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(2)
                    .help(item.title)
                HStack(spacing: 8) {
                    Text(supporting)
                        .lineLimit(1)
                    status
                }
                .font(vm.font(.bodySmall))
                .foregroundStyle(theme.onSurfaceVariant)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 72)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? theme.surfaceContainerHigh : theme.surfaceContainer, in: RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous))
        .animation(Theme.Motion.hover, value: hovering)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Listen Now") { inbox.listen(to: item) }
            Button("Make Audiobook") { makeAudiobook() }
            Divider()
            actionItems
        }
    }

    @ViewBuilder
    private var status: some View {
        if item.isFinished {
            StatusChip(text: "Finished", kind: .success)
        } else if item.progress > 0 {
            StatusChip(text: "\(Int((item.progress * 100).rounded()))% listened", kind: .info)
        }
        if item.isArchived {
            StatusChip(text: "Archived")
        }
    }

    private var trailing: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                listenButton
                Button("Make Audiobook") { makeAudiobook() }
                    .buttonStyle(.voqoraText)
                moreMenu
            }
            HStack(spacing: 8) {
                listenButton
                PlayerCircleButton(systemName: "books.vertical", label: "Make Audiobook") { makeAudiobook() }
                moreMenu
            }
        }
        .fixedSize()
    }

    private var listenButton: some View {
        Button {
            inbox.listen(to: item)
        } label: {
            Label(isListening ? "Playing" : "Listen", systemImage: isListening ? "waveform" : "play.fill")
        }
        .buttonStyle(.voqoraTonal)
        .help("Listen Now")
    }

    private var moreMenu: some View {
        Menu {
            actionItems
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.onSurfaceVariant)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More Actions")
        .accessibilityLabel("More actions for \(item.title)")
    }

    @ViewBuilder
    private var actionItems: some View {
        Button("Open Original") { inbox.openOriginal(item) }
        Button("Copy Text") { inbox.copyText(of: item) }
        Button(item.isArchived ? "Move to Inbox" : "Archive") { inbox.toggleArchived(item) }
        Divider()
        Button("Delete", role: .destructive) { inbox.delete(item) }
    }

    private func makeAudiobook() {
        AudiobookCreateRequest.shared.pending = .link(item.url)
        vm.selectedTab = TabKey.createAudiobook
    }

    private var accessibilitySummary: String {
        var parts = [item.title, supporting]
        if item.isFinished {
            parts.append("Finished")
        } else if item.progress > 0 {
            parts.append("\(Int((item.progress * 100).rounded())) percent listened")
        }
        if item.isArchived {
            parts.append("Archived")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

private struct SiteAvatar: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    let label: String

    private var initial: String {
        label.first(where: \.isLetter).map { String($0).uppercased() } ?? "#"
    }

    var body: some View {
        Text(initial)
            .font(vm.font(.titleSmall))
            .foregroundStyle(theme.onPrimaryContainer)
            .frame(width: 40, height: 40)
            .background(theme.primaryContainer.opacity(0.65), in: Circle())
            .accessibilityHidden(true)
    }
}

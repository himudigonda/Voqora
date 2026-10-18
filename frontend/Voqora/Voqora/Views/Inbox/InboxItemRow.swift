import SwiftUI

struct InboxItemRow: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var inbox: InboxViewModel
    let item: InboxItem
    let speed: Double
    @State private var hovering = false

    private var isListening: Bool {
        inbox.listeningItemID == item.id
    }

    private var listeningTime: String {
        InboxListeningTime.label(wordCount: item.wordCount, speed: speed)
    }

    private var subtitle: String {
        [item.siteLabel, item.byline].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.md) {
            PlayerCircleButton(systemName: isListening ? "waveform" : "play.fill", label: "Listen Now") {
                inbox.listen(to: item)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(vm.appFont(size: 15, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                Text(subtitle)
                    .font(vm.font(.rowSubtitle))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                metadata
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
            Spacer(minLength: 0)
            HStack(spacing: DesignTokens.Spacing.sm) {
                if inbox.isMakingAudiobook(item) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 30, height: 30)
                        .accessibilityLabel("Making audiobook")
                } else {
                    PlayerCircleButton(systemName: "books.vertical", label: "Make Audiobook") {
                        inbox.makeAudiobook(from: item)
                    }
                }
                Menu {
                    actionItems
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.textPrimary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Palette.controlFill))
                        .contentShape(Circle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More Actions")
                .accessibilityLabel("More actions for \(item.title)")
            }
            .opacity(hovering || isListening ? 1 : 0.55)
        }
        .padding(.horizontal, DesignTokens.Layout.cardInset)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Listen Now") { inbox.listen(to: item) }
            Button("Make Audiobook") { inbox.makeAudiobook(from: item) }
                .disabled(inbox.isMakingAudiobook(item))
            Divider()
            actionItems
        }
    }

    private var metadata: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text(listeningTime)
            Text("·")
            Text(item.addedAt, format: .dateTime.month().day())
            if item.isFinished {
                Text("FINISHED")
                    .font(vm.font(.chip))
                    .kerning(0.6)
                    .foregroundStyle(Palette.success)
            } else if item.progress > 0 {
                ProgressView(value: item.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 72)
            }
            if item.isArchived {
                Text("ARCHIVED")
                    .font(vm.font(.chip))
                    .kerning(0.6)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .font(vm.font(.caption))
        .foregroundStyle(Palette.textTertiary)
    }

    @ViewBuilder
    private var actionItems: some View {
        Button("Open Original") { inbox.openOriginal(item) }
        Button("Copy Text") { inbox.copyText(of: item) }
        Button(item.isArchived ? "Move to Inbox" : "Archive") { inbox.toggleArchived(item) }
        Divider()
        Button("Delete", role: .destructive) { inbox.delete(item) }
    }

    private var accessibilitySummary: String {
        var parts = [item.title, subtitle, listeningTime]
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

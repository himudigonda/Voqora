import SwiftUI

struct InboxView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var inbox: InboxViewModel
    @Environment(\.voqoraTheme) private var theme
    @FocusState private var focusedField: Field?
    @State private var hoveringDrop = false

    private enum Field: Hashable {
        case link
        case search
        case pasteTarget
    }

    var body: some View {
        let items = inbox.visibleItems
        PageScaffold(title: "Inbox", subtitle: "Save articles to listen to later.") {
            VStack(alignment: .leading, spacing: Theme.Space.card) {
                addBar
                if let notice = inbox.notice {
                    InboxNoticeBanner(notice: notice)
                }
                if let persistenceError = inbox.store.persistenceError {
                    persistenceBanner(persistenceError)
                }
                if inbox.isEmpty {
                    emptyState
                } else {
                    controls
                    listSection(items)
                }
            }
        }
        .navigationTitle("Inbox")
        .onDrop(of: InboxDropReader.acceptedTypes, isTargeted: $hoveringDrop) { providers in
            inbox.handleDrop(providers)
        }
        .overlay {
            if hoveringDrop {
                RoundedRectangle(cornerRadius: Theme.Shape.lg, style: .continuous)
                    .strokeBorder(theme.primary, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(theme.secondaryContainer.opacity(0.35), in: RoundedRectangle(cornerRadius: Theme.Shape.lg, style: .continuous))
                    .padding(Theme.Space.card)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private var addBar: some View {
        VoqoraCard {
            HStack(spacing: Theme.Space.item) {
                HStack(spacing: 10) {
                    Image(systemName: "link")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(theme.onSurfaceVariant)
                        .accessibilityHidden(true)
                    TextField("Paste a link to an article", text: $inbox.linkDraft)
                        .textFieldStyle(.plain)
                        .font(vm.font(.body))
                        .foregroundStyle(theme.onSurface)
                        .focused($focusedField, equals: .link)
                        .onSubmit { inbox.submitDraft() }
                        .accessibilityLabel("Article link")
                }
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(theme.surfaceContainerHigh, in: Capsule())
                Button {
                    inbox.submitDraft()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.voqoraFilled)
                .disabled(inbox.linkDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Add this link to your Inbox")
            }
        }
    }

    private var controls: some View {
        HStack(spacing: Theme.Space.item) {
            HStack(spacing: 8) {
                ForEach(InboxFilter.allCases) { filter in
                    FilterChip(title: "\(filter.title) \(inbox.count(for: filter))", isSelected: inbox.filter == filter) {
                        inbox.filter = filter
                    }
                }
            }
            Spacer(minLength: 0)
            SearchField(text: $inbox.searchText, prompt: "Search title or site")
                .focused($focusedField, equals: .search)
                .frame(minWidth: 140, maxWidth: 240)
                .accessibilityLabel("Search articles by title or site")
        }
    }

    @ViewBuilder
    private func listSection(_ items: [InboxItem]) -> some View {
        if items.isEmpty, inbox.pendingLinks.isEmpty {
            filteredEmptyState
        } else {
            ListGroup {
                ForEach(inbox.pendingLinks) { link in
                    InboxPendingRow(link: link)
                }
                ForEach(items) { item in
                    InboxItemRow(item: item, speed: vm.speechSpeed)
                }
            }
        }
    }

    private var filteredEmptyState: some View {
        let query = inbox.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = query.isEmpty ? EmptyContent.forFilter(inbox.filter) : EmptyContent.noResults(for: query)
        return EmptyStateView(symbol: content.symbol, title: content.title, message: content.message)
    }

    private var emptyState: some View {
        EmptyStateView(
            symbol: "tray",
            title: "Your Inbox is empty",
            message: "Copy a link to an article, then press ⌘V here or choose Paste Link. You can also drop a link or .webloc file. Voqora keeps up to \(InboxStore.capacity) articles on this Mac.",
            action: EmptyStateAction(title: "Paste Link") {
                inbox.pasteLink(InboxDropReader.pasteboardLink(from: .general))
            }
        )
        .focusable()
        .focused($focusedField, equals: .pasteTarget)
        .focusEffectDisabled()
        .onPasteCommand(of: InboxDropReader.acceptedTypes) { providers in
            inbox.handlePaste(providers)
        }
        .onAppear {
            if focusedField == nil {
                focusedField = .pasteTarget
            }
        }
    }

    private func persistenceBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.warning)
                .accessibilityHidden(true)
            Text(message)
                .font(vm.font(.bodySmall))
                .foregroundStyle(theme.onSurface)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Try Again") { inbox.store.retryPersistence() }
                .buttonStyle(.voqoraTonal)
        }
        .padding(Theme.Space.item + 4)
        .background(theme.warning.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous))
    }
}

struct InboxNoticeBanner: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var inbox: InboxViewModel
    @Environment(\.voqoraTheme) private var theme
    let notice: InboxNotice

    private var tint: Color {
        switch notice.kind {
        case .error: theme.danger
        case .success: theme.success
        case .info: theme.primary
        }
    }

    private var systemImage: String {
        switch notice.kind {
        case .error: "exclamationmark.triangle.fill"
        case .success: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(notice.message)
                .font(vm.font(.bodySmall))
                .foregroundStyle(theme.onSurface)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let action = notice.action {
                Button(action.title) { perform(action) }
                    .buttonStyle(.voqoraTonal)
            }
            Button {
                inbox.dismissNotice()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.voqoraIcon)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, Theme.Space.item + 4)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func perform(_ action: InboxNotice.Action) {
        switch action {
        case let .makeAudiobook(url):
            AudiobookCreateRequest.shared.pending = .link(url)
            vm.selectedTab = TabKey.createAudiobook
            inbox.dismissNotice()
        }
    }
}

struct InboxPendingRow: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    let link: InboxViewModel.PendingLink

    var body: some View {
        HStack(spacing: 16) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 40, height: 40)
            Text("Reading \(InboxLinkParser.displayHost(of: link.url) ?? link.url.absoluteString)…")
                .font(vm.font(.body))
                .foregroundStyle(theme.onSurfaceVariant)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 56)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceContainer, in: RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct EmptyContent {
    let symbol: String
    let title: String
    let message: String

    static func noResults(for query: String) -> EmptyContent {
        EmptyContent(symbol: "magnifyingglass", title: "No Results", message: "No articles match “\(query)”.")
    }

    static func forFilter(_ filter: InboxFilter) -> EmptyContent {
        switch filter {
        case .unread:
            EmptyContent(symbol: "checkmark.circle", title: "You're all caught up", message: "Finished and archived articles are under All.")
        case .archived:
            EmptyContent(symbol: "archivebox", title: "Nothing archived", message: "Articles you archive appear here.")
        case .all:
            EmptyContent(symbol: "tray", title: "Your Inbox is empty", message: "Paste a link above to save an article.")
        }
    }
}

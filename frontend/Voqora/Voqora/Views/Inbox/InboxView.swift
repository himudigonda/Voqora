import SwiftUI

struct InboxView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var inbox: InboxViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @FocusState private var focusedField: Field?
    @State private var hoveringDrop = false

    private enum Field: Hashable {
        case link
        case search
    }

    private var accentColor: Color {
        vm.accentColor(scheme: colorScheme, contrast: colorSchemeContrast)
    }

    var body: some View {
        let items = inbox.visibleItems
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Layout.sectionGap) {
                header
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
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Inbox")
        .onDrop(of: InboxDropReader.acceptedTypes, isTargeted: $hoveringDrop) { providers in
            inbox.handleDrop(providers)
        }
        .overlay {
            if hoveringDrop {
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.overlay, style: .continuous)
                    .strokeBorder(accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .padding(DesignTokens.Spacing.lg)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Inbox")
                .font(vm.font(.pageTitle))
                .foregroundStyle(Palette.textPrimary)
            Text("Save articles to listen to later. Paste a link, drop one here, or choose Save to Voqora Inbox from the Services menu in any app.")
                .font(vm.appFont(size: 14))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var addBar: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            TextField("Paste a link to an article", text: $inbox.linkDraft)
                .textFieldStyle(.roundedBorder)
                .font(vm.font(.rowTitle))
                .focused($focusedField, equals: .link)
                .onSubmit { inbox.submitDraft() }
                .accessibilityLabel("Article link")
            Button {
                inbox.submitDraft()
            } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.voqoraPrimary)
            .disabled(inbox.linkDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Add this link to your Inbox")
        }
    }

    private var controls: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Picker("Show", selection: $inbox.filter) {
                ForEach(InboxFilter.allCases) { filter in
                    Text("\(filter.title) (\(inbox.count(for: filter)))").tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 340)
            .accessibilityLabel("Show articles")
            Spacer(minLength: 0)
            TextField("Search title or site", text: $inbox.searchText)
                .textFieldStyle(.roundedBorder)
                .font(vm.font(.rowTitle))
                .focused($focusedField, equals: .search)
                .frame(maxWidth: 220)
                .accessibilityLabel("Search articles by title or site")
        }
    }

    private func listSection(_ items: [InboxItem]) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            if items.isEmpty, inbox.pendingLinks.isEmpty {
                Text(filteredEmptyMessage)
                    .font(vm.font(.rowTitle))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignTokens.Layout.cardInset)
                    .voqoraSurface(.raised, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xLarge, style: .continuous))
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(inbox.pendingLinks) { link in
                        InboxPendingRow(link: link)
                        Divider()
                    }
                    ForEach(items) { item in
                        InboxItemRow(item: item, speed: vm.speechSpeed)
                        if item.id != items.last?.id {
                            Divider()
                        }
                    }
                }
                .voqoraSurface(.raised, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xLarge, style: .continuous))
            }
        }
    }

    private var filteredEmptyMessage: String {
        let query = inbox.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            return "No articles match “\(query)”."
        }
        switch inbox.filter {
        case .unread: return "You're all caught up. Finished and archived articles are under All."
        case .archived: return "Articles you archive appear here."
        case .all: return "Your Inbox is empty."
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "tray")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Palette.textTertiary)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Your Inbox Is Empty")
                    .font(vm.font(.sectionTitle))
                    .foregroundStyle(Palette.textPrimary)
                Text("Copy a link to an article and press ⌘V here, or drop a link or .webloc file. Voqora keeps up to \(InboxStore.capacity) articles on this Mac.")
                    .font(vm.font(.rowTitle))
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                inbox.pasteLink(InboxDropReader.pasteboardLink(from: .general))
            } label: {
                Label("Paste Link", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.voqoraSecondary)
            .keyboardShortcut("v", modifiers: .command)
            .disabled(focusedField != nil)
            .help("Paste a copied link")
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity)
    }

    private func persistenceBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.warning)
                .accessibilityHidden(true)
            Text(message)
                .font(vm.font(.rowSubtitle))
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Try Again") { inbox.store.retryPersistence() }
                .buttonStyle(.voqoraSecondary)
        }
        .padding(DesignTokens.Layout.cardInset)
        .background(Palette.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium, style: .continuous))
    }
}

struct InboxNoticeBanner: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var inbox: InboxViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    let notice: InboxNotice

    private var tint: Color {
        switch notice.kind {
        case .error: Palette.danger
        case .success: Palette.success
        case .info: vm.accentColor(scheme: colorScheme, contrast: colorSchemeContrast)
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
                .font(vm.font(.rowSubtitle))
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let action = notice.action {
                Button(action.title) { inbox.perform(action) }
                    .buttonStyle(.voqoraSecondary)
            }
            Button {
                inbox.dismissNotice()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(DesignTokens.Layout.cardInset)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

struct InboxPendingRow: View {
    @EnvironmentObject var vm: DashboardViewModel
    let link: InboxViewModel.PendingLink

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            ProgressView()
                .controlSize(.small)
            Text("Reading \(InboxLinkParser.displayHost(of: link.url) ?? link.url.absoluteString)…")
                .font(vm.font(.rowTitle))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignTokens.Layout.cardInset)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }
}

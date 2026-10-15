import SwiftUI

struct StatsView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @EnvironmentObject var stats: UsageStatsStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage("statsRange") private var range: StatsRange = .week
    @State private var confirmingReset = false

    var body: some View {
        let now = Date()
        let theme = StatsTheme(option: vm.accentColorID, scheme: colorScheme, contrast: contrast)
        let summary = UsageSummary.make(ledger: stats.ledger, range: range, now: now, calendar: stats.calendar)
        let library = LibraryStats(books: bookVM.books)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header(summary)
                if let error = stats.persistenceError {
                    StatsInsight(icon: "exclamationmark.triangle", text: error, theme: theme)
                }
                if summary.isEmpty, library.books == 0 {
                    emptyState(theme)
                } else {
                    heroTiles(summary, theme: theme)
                    StatsActivityCard(summary: summary, theme: theme)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 20, alignment: .top)], spacing: 20) {
                        StatsStreakCard(
                            summary: summary,
                            heatmap: UsageSummary.heatmap(ledger: stats.ledger, weeks: 18, now: now, calendar: stats.calendar),
                            theme: theme
                        )
                        StatsRhythmCard(summary: summary, theme: theme)
                        StatsVoicesCard(summary: summary, theme: theme)
                        StatsMilestonesCard(summary: summary, theme: theme)
                    }
                    StatsLibraryCard(
                        summary: summary,
                        library: library,
                        titles: Dictionary(bookVM.books.map { ($0.bookID, $0.displayTitle) }, uniquingKeysWith: { first, _ in first }),
                        theme: theme
                    )
                }
                footer
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 1080)
            .frame(maxWidth: .infinity)
            .animation(DesignTokens.Animation.standard, value: range)
        }
        .confirmationDialog("Reset Stats?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset Stats", role: .destructive) { stats.reset() }
        } message: {
            Text("This clears your listening stats on this Mac. Your history and audiobooks stay as they are.")
        }
    }

    private func header(_ summary: UsageSummary) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom) {
                titleBlock(summary)
                Spacer(minLength: 20)
                rangePicker.frame(width: 340)
            }
            VStack(alignment: .leading, spacing: 16) {
                titleBlock(summary)
                rangePicker
            }
        }
    }

    private func titleBlock(_ summary: UsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Stats")
                .font(vm.font(.pageTitle))
                .foregroundStyle(Palette.textPrimary)
            Text(subtitle(summary))
                .font(vm.appFont(size: 14))
                .foregroundStyle(Palette.textSecondary)
        }
    }

    private func subtitle(_ summary: UsageSummary) -> String {
        guard let first = summary.firstRecorded else {
            return "How you listen with Voqora, counted on this Mac."
        }
        return "How you listen with Voqora, counted on this Mac since \(first.formatted(.dateTime.month(.wide).day().year()))."
    }

    private var rangePicker: some View {
        Picker("Range", selection: $range) {
            ForEach(StatsRange.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private func heroTiles(_ summary: UsageSummary, theme: StatsTheme) -> some View {
        let tiles = heroTileModels(summary)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(tiles.indices, id: \.self) { index in
                    heroTile(tiles[index], summary: summary, theme: theme)
                        .frame(minWidth: 180)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Grid(horizontalSpacing: 16, verticalSpacing: 16) {
                ForEach([0, 2], id: \.self) { row in
                    GridRow {
                        heroTile(tiles[row], summary: summary, theme: theme)
                        heroTile(tiles[row + 1], summary: summary, theme: theme)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func heroTile(_ tile: HeroTileModel, summary: UsageSummary, theme: StatsTheme) -> some View {
        StatsHeroTile(
            title: tile.title,
            value: tile.value,
            icon: tile.icon,
            change: tile.change,
            comparison: summary.range.comparisonLabel,
            footnote: tile.footnote,
            theme: theme
        )
    }

    private func heroTileModels(_ summary: UsageSummary) -> [HeroTileModel] {
        let totals = summary.totals
        let previous = summary.previous
        let rangeDays = max(1, Int((summary.interval.duration / 86400).rounded()))
        let averageWords = totals.speechCount > 0 ? totals.speechWords / totals.speechCount : 0
        let pages = Int((Double(totals.speechWords) / StatsFormat.wordsPerPaperbackPage).rounded())
        return [
            HeroTileModel(
                title: "Listening time",
                value: StatsFormat.duration(totals.totalSeconds),
                icon: "headphones",
                change: UsageSummary.change(totals.totalSeconds, previous?.totalSeconds),
                footnote: "\(StatsFormat.duration(totals.speechSeconds)) selected text · \(StatsFormat.duration(totals.listeningSeconds)) audiobooks"
            ),
            HeroTileModel(
                title: "Words spoken",
                value: StatsFormat.count(totals.speechWords),
                icon: "text.quote",
                change: UsageSummary.change(Double(totals.speechWords), previous.map { Double($0.speechWords) }),
                footnote: pages > 0 ? "About \(pages) paperback \(pages == 1 ? "page" : "pages")" : "Selected text read aloud"
            ),
            HeroTileModel(
                title: "Selections read",
                value: StatsFormat.count(totals.speechCount),
                icon: "text.cursor",
                change: UsageSummary.change(Double(totals.speechCount), previous.map { Double($0.speechCount) }),
                footnote: averageWords > 0 ? "\(averageWords) words on average" : "Select text, then press your shortcut"
            ),
            HeroTileModel(
                title: "Active days",
                value: summary.range.bucket == .day ? "\(totals.activeDays) / \(rangeDays)" : "\(totals.activeDays)",
                icon: "calendar",
                change: UsageSummary.change(Double(totals.activeDays), previous.map { Double($0.activeDays) }),
                footnote: summary.currentStreak > 0
                    ? "\(summary.currentStreak)-day streak going"
                    : "\(totals.documentsAdded) \(totals.documentsAdded == 1 ? "audiobook" : "audiobooks") started"
            ),
        ]
    }

    private func emptyState(_ theme: StatsTheme) -> some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(theme.accent.opacity(0.12))
                    .frame(width: 96, height: 96)
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(theme.accent)
            }
            VStack(spacing: 6) {
                Text("Your Stats Start Here")
                    .font(vm.appFont(size: 20, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text("Listen to selected text or an audiobook, and Voqora will chart your listening time, favorite voices, streaks, and milestones.")
                    .font(vm.appFont(size: 13))
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            HStack(spacing: 12) {
                Button("Hear a Sample") {
                    vm.selectedTab = "home"
                    Task { await vm.speak(text: OnboardingCopy.sampleText) }
                }
                .buttonStyle(.voqoraPrimary)
                .disabled(!vm.isBackendOnline)
                Button("Add a Document…") {
                    bookVM.isImporterPresented = true
                }
                .buttonStyle(.voqoraSecondary)
            }
        }
        .padding(.vertical, 56)
        .frame(maxWidth: .infinity)
        .voqoraSurface(.raised, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xLarge, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
            Text("Stats are counted on this Mac and never leave it. Analytics settings don't affect them.")
                .font(vm.font(.rowSubtitle))
            Spacer()
            Button("Reset Stats…") { confirmingReset = true }
                .buttonStyle(.voqoraSecondary)
                .disabled(stats.ledger.days.isEmpty)
        }
        .foregroundStyle(Palette.textTertiary)
        .padding(.top, 4)
    }
}

private struct HeroTileModel {
    let title: String
    let value: String
    let icon: String
    let change: Double?
    let footnote: String
}

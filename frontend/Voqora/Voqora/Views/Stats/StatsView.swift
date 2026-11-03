import SwiftUI

struct StatsBookInfo: Equatable {
    let title: String
    let totalSeconds: Double
    let progress: Double
}

struct StatsContext {
    let data: StatsAggregates
    let theme: StatsTheme
    let calendar: Calendar
    let books: [String: StatsBookInfo]
    let library: LibraryStats
    var product = StatsProduct.overview

    var current: PeriodAggregate {
        data.current
    }

    var tint: Color {
        product.tint(in: theme)
    }

    func scoped(to product: StatsProduct) -> StatsContext {
        var copy = self
        copy.product = product
        return copy
    }

    func metric(
        _ title: String,
        value: String,
        footnote: String,
        lowerIsBetter: Bool = false,
        change: ((PeriodAggregate) -> Double)? = nil
    ) -> StatsHeroMetricModel {
        StatsHeroMetricModel(
            title: title,
            value: value,
            footnote: footnote,
            change: change.flatMap { data.change($0) },
            lowerIsBetter: lowerIsBetter
        )
    }

    func rangeCaption() -> String {
        StatsFormat.rangeCaption(data.interval, range: data.range)
    }
}

struct StatsView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @EnvironmentObject var stats: UsageStatsStore
    @Environment(\.voqoraTheme) private var baseTheme
    @AppStorage("statsRange") private var range: StatsRange = .week
    @State private var product = StatsProduct.initial
    @State private var confirmingReset = false

    var body: some View {
        let theme = StatsTheme(base: baseTheme)
        let data = StatsAggregates.make(ledger: stats.ledger, range: range, now: Date(), calendar: stats.calendar)
        let context = StatsContext(data: data, theme: theme, calendar: stats.calendar, books: bookInfo(), library: LibraryStats(books: bookVM.books))
        PageScaffold(
            title: "Stats",
            subtitle: subtitle(data),
            accessory: {
                HStack(spacing: Theme.Space.item) {
                    SegmentedTabs(selection: $range, options: StatsRange.allCases, title: { $0.shortTitle })
                    PageActionsMenu {
                        Button("Reset Stats…", role: .destructive) { confirmingReset = true }
                            .disabled(stats.ledger.days.isEmpty)
                    }
                }
            },
            tabs: { StatsProductRail(selection: $product, current: data.current, theme: theme) },
            content: {
                if let error = stats.persistenceError {
                    StatsInsight(icon: "exclamationmark.triangle", text: error, theme: theme)
                }
                if !data.lifetime.hasActivity, bookVM.books.isEmpty {
                    emptyState
                } else {
                    sectionContent(context)
                }
                footer(theme)
            }
        )
        .animation(Theme.Motion.selection, value: range)
        .animation(Theme.Motion.selection, value: product)
        .navigationTitle("Stats")
        .confirmationDialog("Reset Stats?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset Stats", role: .destructive) { stats.reset() }
        } message: {
            Text("This clears your usage stats on this Mac. Your history and audiobooks stay as they are.")
        }
    }

    @ViewBuilder
    private func sectionContent(_ context: StatsContext) -> some View {
        let scoped = context.scoped(to: product)
        switch product {
        case .overview: StatsOverviewSection(context: scoped, onSelect: { product = $0 })
        case .readAloud: StatsReadAloudSection(context: scoped)
        case .dictation: StatsDictationSection(context: scoped)
        case .audiobooks: StatsAudiobooksSection(context: scoped)
        case .podcasts: StatsPodcastsSection(context: scoped)
        case .ai: StatsAISection(context: scoped)
        }
    }

    private func bookInfo() -> [String: StatsBookInfo] {
        var info = Dictionary(
            bookVM.books.map { ($0.bookID, StatsBookInfo(title: $0.displayTitle, totalSeconds: $0.totalAudioSeconds, progress: bookVM.listenedFraction(for: $0))) },
            uniquingKeysWith: { first, _ in first }
        )
        #if DEBUG
            if stats.isDemo {
                info.merge(UsageStatsDemo.books, uniquingKeysWith: { first, _ in first })
            }
        #endif
        return info
    }

    private func subtitle(_ data: StatsAggregates) -> String {
        guard let first = data.firstRecorded else {
            return "Counted on this Mac."
        }
        return "Counted on this Mac since \(first.formatted(.dateTime.month(.abbreviated).day().year()))."
    }

    private var emptyState: some View {
        EmptyStateView(
            symbol: "chart.bar.xaxis",
            title: "Your stats start here",
            message: "Listen to selected text, dictate a note, or create an audiobook, and Voqora will chart your time saved, favorite voices, streaks, and more.",
            action: EmptyStateAction(title: "Hear a Sample") {
                vm.selectedTab = TabKey.home
                Task { await vm.speak(text: OnboardingCopy.sampleText) }
            }
        )
    }

    private func footer(_ theme: StatsTheme) -> some View {
        HStack(spacing: Theme.Space.unit * 2) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .accessibilityHidden(true)
            Text("Stats are counted on this Mac and never leave it. Analytics settings don't affect them.")
                .font(vm.font(.bodySmall))
        }
        .foregroundStyle(theme.tertiaryText)
    }
}

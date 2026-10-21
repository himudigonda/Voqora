import SwiftUI

enum StatsSection: String, CaseIterable, Identifiable {
    case overview
    case listen
    case dictate
    case create
    case ai
    case engines

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .listen: "Listen"
        case .dictate: "Dictate"
        case .create: "Create"
        case .ai: "AI"
        case .engines: "Engines"
        }
    }

    static var initial: StatsSection {
        #if DEBUG
            if let raw = ProcessInfo.processInfo.environment["VOQORA_STATS_SECTION"], let section = StatsSection(rawValue: raw) {
                return section
            }
        #endif
        return .overview
    }
}

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

    var current: PeriodAggregate {
        data.current
    }

    func tile(
        _ title: String,
        value: String,
        icon: String,
        change: Double? = nil,
        footnote: String,
        tint: Color? = nil
    ) -> StatsHeroTile {
        StatsHeroTile(
            title: title,
            value: value,
            icon: icon,
            change: change,
            comparison: data.comparison,
            footnote: footnote,
            theme: theme,
            tint: tint
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
    @State private var section = StatsSection.initial
    @State private var confirmingReset = false

    var body: some View {
        let theme = StatsTheme(base: baseTheme)
        let data = StatsAggregates.make(ledger: stats.ledger, range: range, now: Date(), calendar: stats.calendar)
        let context = StatsContext(data: data, theme: theme, calendar: stats.calendar, books: bookInfo(), library: LibraryStats(books: bookVM.books))
        PageScaffold(
            title: "Stats",
            subtitle: subtitle(data),
            accessory: {
                PageActionsMenu {
                    Button("Reset Stats…", role: .destructive) { confirmingReset = true }
                        .disabled(stats.ledger.days.isEmpty)
                }
            },
            tabs: { controls },
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
        .navigationTitle("Stats")
        .confirmationDialog("Reset Stats?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset Stats", role: .destructive) { stats.reset() }
        } message: {
            Text("This clears your usage stats on this Mac. Your history and audiobooks stay as they are.")
        }
    }

    private var controls: some View {
        let sections = SegmentedTabs(selection: $section, options: StatsSection.allCases, title: { $0.title })
        let ranges = SegmentedTabs(selection: $range, options: StatsRange.allCases, title: { $0.title })
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.card) {
                sections
                Spacer(minLength: Theme.Space.item)
                ranges
            }
            VStack(alignment: .leading, spacing: Theme.Space.item) {
                sections
                ranges
            }
            VStack(alignment: .leading, spacing: Theme.Space.item) {
                ScrollView(.horizontal, showsIndicators: false) { sections }
                ScrollView(.horizontal, showsIndicators: false) { ranges }
            }
        }
    }

    @ViewBuilder
    private func sectionContent(_ context: StatsContext) -> some View {
        switch section {
        case .overview: StatsOverviewSection(context: context)
        case .listen: StatsListenSection(context: context)
        case .dictate: StatsDictateSection(context: context)
        case .create: StatsCreateSection(context: context)
        case .ai: StatsAISection(context: context)
        case .engines: StatsEnginesSection(context: context)
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
            return "How you listen, dictate, and create with Voqora, counted on this Mac."
        }
        return "How you listen, dictate, and create with Voqora, counted on this Mac since \(first.formatted(.dateTime.month(.wide).day().year()))."
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

import SwiftUI

struct StatsAudiobooksSection: View {
    let context: StatsContext

    private enum Lens: String, StatsLens {
        case trend
        case books
        case generation
        case library
        case rhythm

        var title: String {
            switch self {
            case .trend: "Trend"
            case .books: "Books"
            case .generation: "Generation"
            case .library: "Library"
            case .rhythm: "Rhythm"
            }
        }

        var icon: String {
            switch self {
            case .trend: "chart.bar.fill"
            case .books: "book.fill"
            case .generation: "bolt.fill"
            case .library: "books.vertical.fill"
            case .rhythm: "clock.fill"
            }
        }

        var subtitle: String {
            switch self {
            case .trend: "What you listened to and generated over time"
            case .books: ""
            case .generation: "How fast Voqora narrates your documents"
            case .library: "What is on this Mac and what you imported"
            case .rhythm: "When you listen to audiobooks"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            StatsProductHero(context: context, metrics: metrics)
            StatsLensCard(context: context) { (lens: Lens) in
                switch lens {
                case .trend:
                    StatsTrendLens(
                        context: context,
                        metrics: [
                            .minutes("listened", "Listened") { $0.listeningMinutes },
                            .minutes("rendering", "Rendering") { $0.creatingMinutes },
                            .count("generated", "Generated") { $0.booksGenerated },
                            .count("exports", "Exports") { $0.m4bExports },
                        ],
                        emptyText: "Listen to an audiobook or generate one and it charts here."
                    )
                case .books:
                    StatsBooksCard(context: context)
                case .generation:
                    VStack(alignment: .leading, spacing: Theme.Space.card) {
                        StatsRenderCard(context: context)
                        generationStats
                    }
                case .library:
                    AdaptiveGrid(minColumnWidth: 280, maxColumns: 2) {
                        StatsLibraryCard(context: context)
                        StatsImportsCard(context: context)
                    }
                case .rhythm:
                    StatsRhythmLens(matrix: context.data.audiobookHourWeekday, tint: context.tint, noun: "listen")
                }
            }
        }
    }

    private var generationStats: some View {
        let creation = context.current.creation
        let data = context.data
        return HStack(alignment: .top, spacing: Theme.Space.card) {
            StatsMiniStat(
                label: "Chapters",
                value: creation.chaptersGenerated.formatted(),
                detail: creation.booksGenerated > 0 ? "\(creation.chaptersGenerated / creation.booksGenerated) per book" : "None generated in this period",
                theme: context.theme,
                change: data.change { Double($0.creation.chaptersGenerated) }
            )
            StatsMiniStat(
                label: "M4B exports",
                value: creation.m4bExports.formatted(),
                detail: "Chaptered audiobooks saved",
                theme: context.theme,
                change: data.change { Double($0.creation.m4bExports) }
            )
        }
    }

    private var metrics: [StatsHeroMetricModel] {
        let current = context.current
        let creation = current.creation
        return [
            context.metric(
                "Time listened",
                value: StatsFormat.duration(current.listeningSeconds),
                footnote: "\(creation.booksFinished.formatted()) finished",
                change: { $0.listeningSeconds }
            ),
            context.metric(
                "Audiobooks generated",
                value: creation.booksGenerated.formatted(),
                footnote: creation.booksGenerated > 0 ? "\(creation.chaptersGenerated.formatted()) chapters, \(creation.chaptersGenerated / creation.booksGenerated) per book" : "None in this period",
                change: { Double($0.creation.booksGenerated) }
            ),
            context.metric(
                "Audio generated",
                value: StatsFormat.hours(creation.bookAudioSeconds),
                footnote: "Rendered audiobook narration",
                change: { $0.creation.bookAudioSeconds }
            ),
            context.metric(
                "Render speed",
                value: current.renderSpeed.map { StatsFormat.factor($0) } ?? "—",
                footnote: "Audio per second rendered",
                change: { $0.renderSpeed ?? 0 }
            ),
        ]
    }
}

struct StatsBooksCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    let context: StatsContext

    private var rows: [(id: String, seconds: Double)] {
        context.current.books
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(8)
            .map { (id: $0.key, seconds: $0.value) }
    }

    var body: some View {
        let theme = context.theme
        StatsCard("Audiobooks listened", subtitle: "Time listened in this period and overall progress", theme: theme) {
            if rows.isEmpty {
                StatsEmptyNote(icon: "book.closed", title: "No audiobook listening yet", text: "Play an audiobook and it lands here with your progress.", theme: theme)
            } else {
                let peak = max(rows.first?.seconds ?? 1, 1)
                Grid(alignment: .leading, horizontalSpacing: Theme.Space.card, verticalSpacing: 12) {
                    GridRow {
                        header("Audiobook")
                        header("Listened")
                            .gridColumnAlignment(.trailing)
                        header("Progress")
                        header("")
                    }
                    Divider().gridCellColumns(4)
                    ForEach(rows, id: \.id) { row in
                        let info = context.books[row.id]
                        GridRow {
                            Text(info?.title ?? "Removed audiobook")
                                .font(vm.font(.label))
                                .foregroundStyle(info == nil ? theme.tertiaryText : theme.text)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 10) {
                                StatsShareBar(fraction: row.seconds / peak, tint: context.tint, track: theme.track)
                                    .frame(width: 70)
                                Text(StatsFormat.duration(row.seconds))
                                    .font(vm.font(.bodySmall).monospacedDigit())
                                    .foregroundStyle(theme.secondaryText)
                                    .fixedSize()
                                    .frame(minWidth: 62, alignment: .trailing)
                            }
                            StatsShareBar(fraction: info?.progress ?? 0, tint: theme.ramp(context.tint, 2), track: theme.track)
                                .frame(width: 110)
                            Text(info.map { StatsFormat.percent($0.progress) } ?? "—")
                                .font(vm.font(.bodySmall).monospacedDigit())
                                .foregroundStyle(theme.secondaryText)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(vm.font(.labelSmall))
            .foregroundStyle(context.theme.tertiaryText)
    }
}

struct StatsRenderCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    let context: StatsContext

    var body: some View {
        let theme = context.theme
        let creation = context.current.creation
        StatsCard("Generation speed", subtitle: "Audiobook audio vs time spent rendering", theme: theme) {
            if creation.bookAudioSeconds <= 0 {
                StatsEmptyNote(icon: "bolt", title: "No renders yet", text: "Generate an audiobook to see how fast Voqora narrates.", theme: theme)
            } else {
                let peak = max(creation.bookAudioSeconds, creation.bookRenderSeconds, 1)
                bar("Audio created", creation.bookAudioSeconds, peak: peak, color: context.tint)
                bar("Time rendering", creation.bookRenderSeconds, peak: peak, color: theme.ramp(context.tint, 2))
                if let speed = context.current.renderSpeed {
                    StatsInsight(icon: "bolt.fill", text: "Voqora narrates about \(StatsFormat.factor(speed)) faster than real time.", theme: theme)
                }
            }
        }
    }

    private func bar(_ label: String, _ seconds: Double, peak: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                    .font(vm.font(.label))
                    .foregroundStyle(context.theme.text)
                Spacer()
                Text(StatsFormat.duration(seconds))
                    .font(vm.font(.label).monospacedDigit())
                    .foregroundStyle(context.theme.secondaryText)
            }
            StatsShareBar(fraction: seconds / peak, tint: color, track: context.theme.track)
        }
        .accessibilityElement(children: .combine)
    }
}

struct StatsImportsCard: View {
    let context: StatsContext

    private var slices: [StatsDonutSlice] {
        let theme = context.theme
        let sorted = context.current.creation.imports.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        var result = sorted.prefix(6).enumerated().map { index, entry in
            StatsDonutSlice(id: entry.key, label: StatsLabels.importKind(entry.key), value: Double(entry.value), color: theme.ramp(context.tint, index))
        }
        let rest = sorted.dropFirst(6).reduce(0) { $0 + $1.value }
        if rest > 0 {
            result.append(StatsDonutSlice(id: "other", label: "Other", value: Double(rest), color: theme.other))
        }
        return result
    }

    var body: some View {
        StatsCard("Imports", subtitle: "What you brought into Voqora", theme: context.theme) {
            if slices.isEmpty {
                StatsEmptyNote(icon: "square.and.arrow.down", title: "No imports yet", text: "PDFs, EPUBs, web pages, and pasted text are counted by type.", theme: context.theme)
            } else {
                StatsDonut(
                    slices: slices,
                    theme: context.theme,
                    unit: "imports",
                    summary: "Imports by kind: " + slices.map { "\($0.label) \(Int($0.value))" }.joined(separator: ", ")
                )
            }
        }
    }
}

struct StatsLibraryCard: View {
    let context: StatsContext

    var body: some View {
        let theme = context.theme
        let library = context.library
        StatsCard("Your library", subtitle: "Everything on this Mac, all time", theme: theme) {
            if library.books == 0 {
                StatsEmptyNote(icon: "books.vertical", title: "Your library is empty", text: "Turn a PDF, Word, text, or Markdown file into an audiobook to see it here.", theme: theme)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 18) {
                    GridRow {
                        StatsMiniStat(
                            label: "Books",
                            value: "\(library.books)",
                            detail: library.inProgress > 0 ? "\(library.ready) ready, \(library.inProgress) in progress" : "\(library.ready) ready",
                            theme: theme
                        )
                        StatsMiniStat(
                            label: "Audio",
                            value: StatsFormat.duration(library.audioSeconds),
                            detail: library.longest.map { "Longest \(StatsFormat.duration($0.seconds))" },
                            theme: theme
                        )
                    }
                    GridRow {
                        StatsMiniStat(label: "Pages", value: StatsFormat.count(library.pages), detail: "\(StatsFormat.count(library.words)) words", theme: theme)
                        StatsMiniStat(
                            label: "AI cleanup",
                            value: StatsFormat.currency(library.cleanupCostUsd),
                            detail: library.tokens > 0 ? "\(StatsFormat.count(library.tokens)) tokens" : "\(library.cleanedBooks) books",
                            theme: theme
                        )
                    }
                }
            }
        }
    }
}

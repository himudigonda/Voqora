import Charts
import SwiftUI

struct StatsCreateSection: View {
    let context: StatsContext

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.card) {
            tiles
            AdaptiveGrid(minColumnWidth: 400) {
                StatsCreationTimelineCard(context: context).statsSpan(2)
                StatsRenderCard(context: context)
                StatsPodcastCard(context: context)
                StatsImportsCard(context: context)
                StatsLibraryCard(context: context)
            }
        }
    }

    private var tiles: some View {
        let data = context.data
        let creation = data.current.creation
        let theme = context.theme
        return AdaptiveGrid(minColumnWidth: 148, spacing: Theme.Space.item, maxColumns: 6, balanced: true) {
            context.tile(
                "Audiobooks generated",
                value: creation.booksGenerated.formatted(),
                icon: "books.vertical.fill",
                change: data.change { Double($0.creation.booksGenerated) },
                footnote: "\(creation.booksFinished.formatted()) finished listening",
                tint: theme.series(0)
            )
            context.tile(
                "Chapters",
                value: creation.chaptersGenerated.formatted(),
                icon: "list.bullet.rectangle",
                change: data.change { Double($0.creation.chaptersGenerated) },
                footnote: creation.booksGenerated > 0 ? "\(creation.chaptersGenerated / creation.booksGenerated) per book" : "Per audiobook",
                tint: theme.series(1)
            )
            context.tile(
                "Audio generated",
                value: StatsFormat.hours(creation.bookAudioSeconds),
                icon: "waveform",
                change: data.change { $0.creation.bookAudioSeconds },
                footnote: "Rendered audiobook narration",
                tint: theme.series(2)
            )
            context.tile(
                "Render speed",
                value: data.current.renderSpeed.map { StatsFormat.factor($0) } ?? "—",
                icon: "bolt.fill",
                change: data.change { $0.renderSpeed ?? 0 },
                footnote: "Audio made per second of rendering",
                tint: theme.series(3)
            )
            context.tile(
                "Podcasts rendered",
                value: creation.podcastRenders.formatted(),
                icon: "mic.badge.plus",
                change: data.change { Double($0.creation.podcastRenders) },
                footnote: "\(creation.podcastScripts.formatted()) \(creation.podcastScripts == 1 ? "script" : "scripts") written",
                tint: theme.series(4)
            )
            context.tile(
                "M4B exports",
                value: creation.m4bExports.formatted(),
                icon: "square.and.arrow.up",
                change: data.change { Double($0.creation.m4bExports) },
                footnote: "Chaptered audiobooks saved"
            )
        }
    }
}

struct StatsCreationTimelineCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    let context: StatsContext
    @State private var selection: Date?

    private struct Series: Identifiable {
        let id: String
        let color: Color
        let value: (TimelinePoint) -> Int
    }

    private var series: [Series] {
        let theme = context.theme
        return [
            Series(id: "Audiobooks", color: theme.series(0), value: { $0.booksGenerated }),
            Series(id: "Podcasts", color: theme.series(1), value: { $0.podcastRenders }),
            Series(id: "M4B exports", color: theme.series(2), value: { $0.m4bExports }),
        ]
    }

    private var unit: Calendar.Component {
        context.data.trendUnit
    }

    private var selectedPoint: TimelinePoint? {
        guard let selection else { return nil }
        return context.data.trend.min { abs($0.date.timeIntervalSince(selection)) < abs($1.date.timeIntervalSince(selection)) }
    }

    private var hasCreations: Bool {
        context.data.trend.contains { $0.booksGenerated + $0.podcastRenders + $0.m4bExports > 0 }
    }

    var body: some View {
        let theme = context.theme
        StatsCard("Creation over time", subtitle: "Items created per \(context.data.trendUnitName), \(context.rangeCaption())", theme: theme) {
            if hasCreations {
                StatsLegend(items: series.map { StatsLegendItem(id: $0.id, label: $0.id, color: $0.color) }, theme: theme)
                chart
            } else {
                StatsEmptyNote(
                    icon: "books.vertical",
                    title: "Nothing created in this period",
                    text: "Turn a document into an audiobook or render a podcast and it shows up here.",
                    theme: theme,
                    minHeight: 200
                )
            }
        }
    }

    private var chart: some View {
        let theme = context.theme
        return Chart {
            ForEach(series) { item in
                ForEach(context.data.trend) { point in
                    BarMark(x: .value("Date", point.date, unit: unit), y: .value("Items", item.value(point)))
                        .foregroundStyle(by: .value("Type", item.id))
                        .cornerRadius(3)
                }
            }
            if let point = selectedPoint {
                RuleMark(x: .value("Selected", point.date, unit: unit))
                    .foregroundStyle(theme.separator)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .overlay, alignment: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        StatsCallout(
                            title: StatsFormat.pointCaption(point.date, range: context.data.range, unit: context.data.trendUnit),
                            rows: series.map { StatsCalloutRow(color: $0.color, label: $0.id, value: "\($0.value(point))") },
                            theme: theme
                        )
                    }
            }
        }
        .chartForegroundStyleScale(domain: series.map(\.id), range: series.map(\.color))
        .chartLegend(.hidden)
        .chartXSelection(value: $selection)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    .foregroundStyle(theme.separator)
                AxisValueLabel {
                    if let count = value.as(Int.self) {
                        Text("\(count)")
                            .font(vm.font(.bodySmall))
                            .foregroundStyle(theme.tertiaryText)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: context.data.range == .week ? 7 : 6)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(StatsFormat.axisLabel(date, range: context.data.range))
                            .font(vm.font(.bodySmall))
                            .foregroundStyle(theme.tertiaryText)
                    }
                }
            }
        }
        .frame(height: 220)
        .accessibilityLabel("Stacked bar chart of audiobooks, podcasts and M4B exports created per \(unit == .day ? "day" : "month")")
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
                bar("Audio created", creation.bookAudioSeconds, peak: peak, color: theme.series(0))
                bar("Time rendering", creation.bookRenderSeconds, peak: peak, color: theme.series(1))
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

struct StatsPodcastCard: View {
    let context: StatsContext

    var body: some View {
        let creation = context.current.creation
        let theme = context.theme
        StatsCard("Podcasts", subtitle: "Scripts and rendered episodes", theme: theme) {
            if creation.podcastScripts == 0, creation.podcastRenders == 0 {
                StatsEmptyNote(icon: "mic.badge.plus", title: "No podcasts yet", text: "Draft a script with AI, then render it with multiple voices.", theme: theme)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 18) {
                    GridRow {
                        StatsMiniStat(label: "Scripts", value: creation.podcastScripts.formatted(), detail: "written", theme: theme)
                        StatsMiniStat(label: "Renders", value: creation.podcastRenders.formatted(), detail: "episodes", theme: theme)
                    }
                    GridRow {
                        StatsMiniStat(label: "Audio", value: StatsFormat.duration(creation.podcastAudioSeconds), detail: "rendered", theme: theme)
                        StatsMiniStat(
                            label: "Speakers",
                            value: creation.podcastRenders > 0 ? (Double(creation.podcastSpeakers) / Double(creation.podcastRenders)).formatted(.number.precision(.fractionLength(1))) : "—",
                            detail: "per episode",
                            theme: theme
                        )
                    }
                }
            }
        }
    }
}

struct StatsImportsCard: View {
    let context: StatsContext

    private var slices: [StatsDonutSlice] {
        let theme = context.theme
        let sorted = context.current.creation.imports.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        var result = sorted.prefix(6).enumerated().map { index, entry in
            StatsDonutSlice(id: entry.key, label: StatsLabels.importKind(entry.key), value: Double(entry.value), color: theme.series(index))
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

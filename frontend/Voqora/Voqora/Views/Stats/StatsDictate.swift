import Charts
import SwiftUI

struct StatsDictationSection: View {
    let context: StatsContext

    private enum Lens: String, StatsLens {
        case pace
        case outcomes
        case places
        case rhythm

        var title: String {
            switch self {
            case .pace: "Pace"
            case .outcomes: "Outcomes"
            case .places: "Places"
            case .rhythm: "Rhythm"
            }
        }

        var icon: String {
            switch self {
            case .pace: "speedometer"
            case .outcomes: "arrow.right.doc.on.clipboard"
            case .places: "macwindow"
            case .rhythm: "clock.fill"
            }
        }

        var subtitle: String {
            switch self {
            case .pace: ""
            case .outcomes: "What happened to your words, and how long sessions run"
            case .places: "Where your words landed, and in which languages"
            case .rhythm: "When you dictate"
            }
        }
    }

    private var hasDictation: Bool {
        let dictation = context.current.dictation
        return dictation.sessions > 0 || dictation.cancelled > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            StatsProductHero(context: context, metrics: metrics)
            if hasDictation {
                StatsLensCard(context: context) { (lens: Lens) in
                    switch lens {
                    case .pace:
                        StatsDictationPaceLens(context: context)
                    case .outcomes:
                        outcomes
                    case .places:
                        AdaptiveGrid(minColumnWidth: 280, maxColumns: 2) {
                            StatsDictationAppsCard(context: context)
                            StatsLanguagesCard(context: context)
                        }
                    case .rhythm:
                        StatsRhythmLens(matrix: context.data.dictationHourWeekday, tint: context.tint, noun: "dictate")
                    }
                }
            } else {
                EmptyStateView(
                    symbol: "mic",
                    title: context.data.lifetime.dictation.sessions > 0 ? "No dictation in this period" : "No dictation yet",
                    message: "Press \(DictationController.shortcutLabel) anywhere, speak, and Voqora types it for you. Your words, pace, and favorite apps show up here."
                )
                .frame(maxWidth: .infinity)
                .background(context.theme.base.surfaceContainer, in: RoundedRectangle(cornerRadius: Theme.Shape.lg, style: .continuous))
            }
        }
    }

    private var outcomes: some View {
        let current = context.current
        let dictation = current.dictation
        return VStack(alignment: .leading, spacing: Theme.Space.card) {
            AdaptiveGrid(minColumnWidth: 280, maxColumns: 2) {
                StatsOutcomesCard(context: context)
                StatsLengthCard(context: context)
            }
            Divider()
            HStack(alignment: .top, spacing: Theme.Space.card) {
                StatsMiniStat(
                    label: "Tidied with AI",
                    value: current.tidiedShare.map { StatsFormat.percent($0) } ?? "—",
                    detail: "\(dictation.tidied.formatted()) of \(dictation.sessions.formatted()) sessions",
                    theme: context.theme
                )
                StatsMiniStat(
                    label: "Cancelled",
                    value: dictation.cancelled.formatted(),
                    detail: "Started but not inserted",
                    theme: context.theme,
                    change: context.data.change { Double($0.dictation.cancelled) },
                    lowerIsBetter: true
                )
            }
        }
    }

    private var metrics: [StatsHeroMetricModel] {
        let current = context.current
        let dictation = current.dictation
        return [
            context.metric(
                "Words dictated",
                value: StatsFormat.count(dictation.words),
                footnote: "\(dictation.chars.formatted()) characters",
                change: { Double($0.dictation.words) }
            ),
            context.metric(
                "Sessions",
                value: dictation.sessions.formatted(),
                footnote: dictation.sessions > 0 ? "\(dictation.words / dictation.sessions) words on average" : "No finished sessions",
                change: { Double($0.dictation.sessions) }
            ),
            context.metric(
                "Words per minute",
                value: dictation.wordsPerMinute.map { "\(Int($0.rounded()))" } ?? "—",
                footnote: "Speaking pace, timed sessions",
                change: { $0.dictation.wordsPerMinute ?? 0 }
            ),
            context.metric(
                "Time saved",
                value: StatsFormat.duration(current.dictationSavedSeconds),
                footnote: "vs typing at \(Int(StatsAssumptions.typingWordsPerMinute)) wpm",
                change: { $0.dictationSavedSeconds }
            ),
        ]
    }
}

struct StatsDictationPaceLens: View {
    let context: StatsContext
    @State private var view = PaceView.pace

    private enum PaceView: String, CaseIterable {
        case pace = "Pace"
        case words = "Words"
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            switch view {
            case .pace:
                StatsWPMCard(context: context)
            case .words:
                StatsTrendLens(
                    context: context,
                    metrics: [.count("words", "Words") { $0.dictationWords }],
                    emptyText: "Dictate a note and your words chart here."
                )
                .padding(.top, Theme.Space.card + Theme.Space.item)
            }
            StatsMetricToggle(selection: $view, options: PaceView.allCases, title: { $0.rawValue }, theme: context.theme)
        }
    }
}

struct StatsWPMCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    let context: StatsContext
    @State private var selection: Date?

    private var points: [TimelinePoint] {
        context.data.trend.filter { $0.wordsPerMinute != nil }
    }

    private var selectedPoint: TimelinePoint? {
        guard let selection else { return nil }
        return points.min { abs($0.date.timeIntervalSince(selection)) < abs($1.date.timeIntervalSince(selection)) }
    }

    var body: some View {
        let theme = context.theme
        let average = context.current.dictation.wordsPerMinute
        StatsCard("Speaking pace", subtitle: "Words per minute by \(context.data.trendUnitName), \(context.rangeCaption())", theme: theme) {
            if let average {
                StatsLegend(
                    items: [
                        StatsLegendItem(id: "wpm", label: "Words per minute", color: context.tint),
                        StatsLegendItem(id: "avg", label: "Period average (\(Int(average.rounded())))", color: theme.ramp(context.tint, 2)),
                    ],
                    theme: theme
                )
                chart(average: average)
            } else {
                StatsEmptyNote(icon: "speedometer", title: "No pace data yet", text: "Timed dictation sessions chart your words per minute here.", theme: theme, minHeight: 200)
            }
        }
    }

    private func chart(average: Double) -> some View {
        let theme = context.theme
        let unit = context.data.trendUnit
        let bounds = wpmBounds(average: average)
        return Chart {
            ForEach(points) { point in
                LineMark(x: .value("Date", point.date, unit: unit), y: .value("WPM", point.wordsPerMinute ?? 0))
                    .foregroundStyle(context.tint)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                PointMark(x: .value("Date", point.date, unit: unit), y: .value("WPM", point.wordsPerMinute ?? 0))
                    .foregroundStyle(context.tint)
                    .symbolSize(points.count > 40 ? 18 : 42)
            }
            RuleMark(y: .value("Average", average))
                .foregroundStyle(theme.ramp(context.tint, 2))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            if let point = selectedPoint {
                RuleMark(x: .value("Selected", point.date, unit: unit))
                    .foregroundStyle(theme.separator)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .overlay, alignment: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        StatsCallout(
                            title: StatsFormat.pointCaption(point.date, range: context.data.range, unit: context.data.trendUnit),
                            rows: [
                                StatsCalloutRow(color: context.tint, label: "Pace", value: "\(Int((point.wordsPerMinute ?? 0).rounded())) wpm"),
                                StatsCalloutRow(color: theme.ramp(context.tint, 2), label: "Words", value: point.dictationWords.formatted()),
                            ],
                            theme: theme
                        )
                    }
            }
        }
        .chartXSelection(value: $selection)
        .chartLegend(.hidden)
        .chartYScale(domain: bounds)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    .foregroundStyle(theme.separator)
                AxisValueLabel {
                    if let wpm = value.as(Double.self) {
                        Text("\(Int(wpm))")
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
        .frame(height: 200)
        .onAppear { selection = StatsDebug.selection(in: points) }
        .accessibilityLabel("Line chart of dictation words per minute. Average \(Int(average.rounded())).")
    }

    private func wpmBounds(average: Double) -> ClosedRange<Double> {
        let values = points.compactMap(\.wordsPerMinute) + [average]
        let low = (values.min() ?? 0)
        let high = (values.max() ?? 1)
        let pad = max(8, (high - low) * 0.25)
        return max(0, (low - pad).rounded(.down)) ... (high + pad).rounded(.up)
    }
}

struct StatsOutcomesCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    let context: StatsContext

    private struct Segment: Identifiable {
        let id: String
        let label: String
        let count: Int
        let color: Color
    }

    private var segments: [Segment] {
        let theme = context.theme
        let outcomes = context.current.dictation.outcomes
        let order: [(key: String, color: Color)] = [
            ("pasted", theme.ramp(context.tint, 0)),
            ("copied", theme.ramp(context.tint, 1)),
            ("copied_needs_accessibility", theme.ramp(context.tint, 2)),
            ("copied_app_changed", theme.ramp(context.tint, 3)),
            ("cancelled", theme.ramp(context.tint, 4)),
        ]
        var result = order.compactMap { entry -> Segment? in
            let count = outcomes[entry.key] ?? 0
            return count > 0 ? Segment(id: entry.key, label: StatsLabels.outcome(entry.key), count: count, color: entry.color) : nil
        }
        let known = Set(order.map(\.key))
        let other = outcomes.filter { !known.contains($0.key) }.reduce(0) { $0 + $1.value }
        if other > 0 {
            result.append(Segment(id: "other", label: "Other", count: other, color: theme.other))
        }
        return result
    }

    var body: some View {
        let theme = context.theme
        let total = max(1, segments.reduce(0) { $0 + $1.count })
        StatsCard("What happened to your words", subtitle: "Dictation outcomes", theme: theme) {
            if segments.isEmpty {
                StatsEmptyNote(icon: "arrow.right.doc.on.clipboard", title: "No outcomes yet", text: "After you dictate, you'll see how often text was pasted or copied.", theme: theme)
            } else {
                Chart(segments) { segment in
                    BarMark(x: .value("Sessions", segment.count), y: .value("Outcome", "Outcomes"), stacking: .normalized)
                        .foregroundStyle(segment.color)
                        .cornerRadius(5)
                }
                .chartLegend(.hidden)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 34)
                .accessibilityLabel("Dictation outcomes: " + segments.map { "\($0.label) \($0.count)" }.joined(separator: ", "))
                VStack(spacing: 8) {
                    ForEach(segments) { segment in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(segment.color).frame(width: 10, height: 10)
                            Text(segment.label)
                                .font(vm.font(.label))
                                .foregroundStyle(theme.text)
                            Spacer(minLength: 8)
                            Text(segment.count.formatted())
                                .font(vm.font(.bodySmall).monospacedDigit())
                                .foregroundStyle(theme.secondaryText)
                            Text(StatsFormat.percent(Double(segment.count) / Double(total)))
                                .font(vm.font(.bodySmall).monospacedDigit())
                                .foregroundStyle(theme.tertiaryText)
                                .frame(width: 38, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }
}

struct StatsLengthCard: View {
    let context: StatsContext

    var body: some View {
        let lengths = context.current.dictation.lengths
        StatsCard("Session length", subtitle: "Sessions by words dictated", theme: context.theme) {
            if lengths.allSatisfy({ $0 == 0 }) {
                StatsEmptyNote(icon: "chart.bar", title: "No sessions yet", text: "Short notes and long drafts are counted here.", theme: context.theme)
            } else {
                let bins = Array(zip(DictationLengthBuckets.labels, lengths)).map { (label: $0.0, value: Double($0.1)) }
                StatsHistogram(
                    bins: bins,
                    highlight: nil,
                    tint: context.tint,
                    theme: context.theme,
                    summary: "Dictation sessions by word count: " + bins.map { "\($0.label) words \(Int($0.value))" }.joined(separator: ", ")
                )
            }
        }
    }
}

struct StatsLanguagesCard: View {
    let context: StatsContext

    private var items: [StatsBarItem] {
        context.current.dictation.languages
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(6)
            .enumerated()
            .map { index, entry in
                StatsBarItem(label: StatsLabels.language(entry.key), value: Double(entry.value), color: context.theme.ramp(context.tint, index == 0 ? 0 : 2))
            }
    }

    var body: some View {
        StatsCard("Languages", subtitle: "Sessions by spoken language", theme: context.theme) {
            if items.isEmpty {
                StatsEmptyNote(icon: "globe", title: "No languages yet", text: "Dictate in any supported language and it is counted here.", theme: context.theme)
            } else {
                StatsHBars(items: items, theme: context.theme, summary: "Sessions by language: " + items.map { "\($0.label) \(Int($0.value))" }.joined(separator: ", "))
            }
        }
    }
}

struct StatsDictationAppsCard: View {
    let context: StatsContext

    private var items: [StatsBarItem] {
        context.current.dictation.apps
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(6)
            .enumerated()
            .map { index, entry in
                StatsBarItem(label: entry.key, value: Double(entry.value), color: context.theme.ramp(context.tint, index == 0 ? 0 : 2))
            }
    }

    var body: some View {
        StatsCard("Target apps", subtitle: "Where your words landed", theme: context.theme) {
            if items.isEmpty {
                StatsEmptyNote(icon: "macwindow", title: "No apps yet", text: "The apps you dictate into are ranked here.", theme: context.theme)
            } else {
                StatsHBars(items: items, theme: context.theme, summary: "Sessions by app: " + items.map { "\($0.label) \(Int($0.value))" }.joined(separator: ", "))
            }
        }
    }
}

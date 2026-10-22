import Charts
import SwiftUI

struct StatsOverviewSection: View {
    let context: StatsContext

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.card) {
            StatsTimeSavedCard(context: context)
            kpiTiles
            AdaptiveGrid(minColumnWidth: 400) {
                StatsActivityAreaCard(context: context).statsSpan(2)
                StatsNarrativeCard(context: context)
                StatsStreakCard(context: context)
                StatsContributionCard(context: context)
                StatsRhythmCard(context: context)
            }
        }
    }

    private var kpiTiles: some View {
        let data = context.data
        let current = data.current
        let theme = context.theme
        let dayCount = data.dayCount
        return AdaptiveGrid(minColumnWidth: 148, spacing: Theme.Space.item, maxColumns: 6, balanced: true) {
            context.tile(
                "Listening time",
                value: StatsFormat.duration(current.heardSeconds),
                icon: "headphones",
                change: data.change { $0.heardSeconds },
                footnote: "\(StatsFormat.duration(current.speechSeconds)) read aloud · \(StatsFormat.duration(current.listeningSeconds)) audiobooks",
                tint: theme.series(0)
            )
            context.tile(
                "Words spoken",
                value: StatsFormat.count(current.speechWords),
                icon: "text.quote",
                change: data.change { Double($0.speechWords) },
                footnote: "\(current.speechCount.formatted()) \(current.speechCount == 1 ? "selection" : "selections") read",
                tint: theme.series(1)
            )
            context.tile(
                "Words dictated",
                value: StatsFormat.count(current.dictation.words),
                icon: "mic.fill",
                change: data.change { Double($0.dictation.words) },
                footnote: "\(current.dictation.sessions.formatted()) \(current.dictation.sessions == 1 ? "session" : "sessions")",
                tint: theme.series(2)
            )
            context.tile(
                "Audiobooks generated",
                value: current.creation.booksGenerated.formatted(),
                icon: "books.vertical.fill",
                change: data.change { Double($0.creation.booksGenerated) },
                footnote: "\(current.creation.chaptersGenerated.formatted()) chapters, \(StatsFormat.hours(current.creation.bookAudioSeconds)) of audio",
                tint: theme.series(3)
            )
            context.tile(
                "AI requests",
                value: current.ai.totalRequests.formatted(),
                icon: "sparkles",
                change: data.change { Double($0.ai.totalRequests) },
                footnote: current.aiSuccessRate.map { "\(StatsFormat.percent($0)) succeeded" } ?? "Ask AI about selected text",
                tint: theme.series(4)
            )
            context.tile(
                "Active days",
                value: data.range.bucket == .day ? "\(current.activeDays) / \(dayCount)" : "\(current.activeDays)",
                icon: "calendar",
                change: data.change { Double($0.activeDays) },
                footnote: data.currentStreak > 0 ? "\(data.currentStreak)-day streak going" : "Longest streak \(data.longestStreak) \(data.longestStreak == 1 ? "day" : "days")"
            )
        }
    }
}

struct StatsTimeSavedCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    let context: StatsContext

    var body: some View {
        let theme = context.theme
        let current = context.current
        let ink = theme.base.onPrimaryContainer
        VStack(alignment: .leading, spacing: Theme.Space.card) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 36) {
                    headline(current: current, ink: ink)
                        .frame(width: 210, alignment: .leading)
                    listeningSaving(current: current, ink: ink)
                    dictationSaving(current: current, ink: ink)
                }
                VStack(alignment: .leading, spacing: Theme.Space.card) {
                    headline(current: current, ink: ink)
                    listeningSaving(current: current, ink: ink)
                    dictationSaving(current: current, ink: ink)
                }
            }
        }
        .padding(Theme.Space.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.base.primaryContainer.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Shape.xl, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func headline(current: PeriodAggregate, ink: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Time saved")
                    .font(vm.font(.label))
                    .foregroundStyle(ink.opacity(0.8))
                StatsHelpButton("How time saved is estimated", theme: context.theme) { formula }
            }
            Text(current.totalSavedSeconds >= 1 ? StatsFormat.duration(current.totalSavedSeconds) : "0m")
                .font(vm.font(.display).monospacedDigit())
                .foregroundStyle(ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(StatsFormat.rangeCaption(context.data.interval, range: context.data.range))
                .font(vm.font(.bodySmall))
                .foregroundStyle(ink.opacity(0.7))
            if let label = StatsFormat.change(context.data.change { $0.totalSavedSeconds }), let comparison = context.data.comparison {
                HStack(spacing: 6) {
                    StatsChangeChip(label: label, change: context.data.change { $0.totalSavedSeconds } ?? 0, theme: context.theme)
                    Text(comparison)
                        .font(vm.font(.labelSmall))
                        .foregroundStyle(ink.opacity(0.8))
                }
                .padding(.top, 2)
            }
        }
    }

    private func listeningSaving(current: PeriodAggregate, ink: Color) -> some View {
        saving(
            SavingModel(
                title: "Listening",
                icon: "headphones",
                wouldTake: current.readingEquivalentSeconds,
                took: current.speechSeconds,
                saved: current.listeningSavedSeconds,
                wouldTakeLabel: "Reading \(StatsFormat.count(current.speechWords)) words",
                tookLabel: "Listening",
                isEmpty: current.speechWords == 0,
                emptyText: "Read some text aloud to see this."
            ),
            ink: ink
        )
    }

    private func dictationSaving(current: PeriodAggregate, ink: Color) -> some View {
        saving(
            SavingModel(
                title: "Dictation",
                icon: "mic.fill",
                wouldTake: current.typingEquivalentSeconds,
                took: current.dictation.seconds,
                saved: current.dictationSavedSeconds,
                wouldTakeLabel: "Typing \(StatsFormat.count(current.dictation.timedWords)) words",
                tookLabel: "Dictating",
                isEmpty: current.dictation.timedWords == 0,
                emptyText: "Dictate a note to see this."
            ),
            ink: ink
        )
    }

    private struct SavingModel {
        let title: String
        let icon: String
        let wouldTake: Double
        let took: Double
        let saved: Double
        let wouldTakeLabel: String
        let tookLabel: String
        let isEmpty: Bool
        let emptyText: String
    }

    private func saving(_ model: SavingModel, ink: Color) -> some View {
        let peak = max(model.wouldTake, model.took, 1)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: model.icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(model.title)
                    .font(vm.font(.label))
                Spacer(minLength: 8)
                if !model.isEmpty {
                    Text(model.saved >= 60 ? "saved \(StatsFormat.duration(model.saved))" : "about even")
                        .font(vm.font(.label).monospacedDigit())
                }
            }
            .foregroundStyle(ink)
            if model.isEmpty {
                Text(model.emptyText)
                    .font(vm.font(.bodySmall))
                    .foregroundStyle(ink.opacity(0.7))
                    .padding(.vertical, 12)
            } else {
                comparisonBar(label: model.wouldTakeLabel, value: model.wouldTake, fraction: model.wouldTake / peak, fill: ink.opacity(0.32), ink: ink)
                comparisonBar(label: model.tookLabel, value: model.took, fraction: model.took / peak, fill: context.theme.accent, ink: ink)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func comparisonBar(label: String, value: Double, fraction: Double, fill: Color, ink: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(vm.font(.bodySmall))
                    .foregroundStyle(ink.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(StatsFormat.duration(value))
                    .font(vm.font(.bodySmall).monospacedDigit())
                    .foregroundStyle(ink)
            }
            StatsShareBar(fraction: fraction, tint: fill, track: ink.opacity(0.1))
        }
    }

    private var formula: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How time saved is estimated")
                .font(vm.font(.titleSmall))
                .foregroundStyle(context.theme.text)
            formulaLine(
                "Listening",
                "Words read aloud ÷ \(Int(StatsAssumptions.readingWordsPerMinute)) words per minute (average silent reading speed), minus the audio time you listened."
            )
            formulaLine(
                "Dictation",
                "Dictated words ÷ \(Int(StatsAssumptions.typingWordsPerMinute)) words per minute (average typing speed), minus the time you spent speaking. Only timed sessions count."
            )
            Text("Each total is never below zero. Audiobook listening isn't included because Voqora doesn't track the words in those hours.")
                .font(vm.font(.bodySmall))
                .foregroundStyle(context.theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func formulaLine(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(vm.font(.label))
                .foregroundStyle(context.theme.text)
            Text(text)
                .font(vm.font(.bodySmall))
                .foregroundStyle(context.theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct StatsActivityAreaCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    let context: StatsContext
    @State private var selection: Date?

    private struct Series: Identifiable {
        let id: String
        let color: Color
        let value: (TimelinePoint) -> Double
    }

    private var series: [Series] {
        let theme = context.theme
        return [
            Series(id: "Audiobooks", color: theme.series(0), value: { $0.listeningMinutes }),
            Series(id: "Read aloud", color: theme.series(1), value: { $0.speechMinutes }),
            Series(id: "Dictation", color: theme.series(2), value: { $0.dictationMinutes }),
            Series(id: "Creating", color: theme.series(3), value: { $0.creatingMinutes }),
        ]
    }

    private var unit: Calendar.Component {
        context.data.range.bucket
    }

    private var selectedPoint: TimelinePoint? {
        guard let selection else { return nil }
        return context.data.timeline.min { abs($0.date.timeIntervalSince(selection)) < abs($1.date.timeIntervalSince(selection)) }
    }

    private var hasActivity: Bool {
        context.data.timeline.contains { $0.totalMinutes > 0 }
    }

    var body: some View {
        let theme = context.theme
        StatsCard("Activity", subtitle: "Minutes per \(unit == .day ? "day" : "month"), \(context.rangeCaption()). Creating is audiobook render time.", theme: theme) {
            if hasActivity {
                StatsLegend(items: series.map { StatsLegendItem(id: $0.id, label: $0.id, color: $0.color) }, theme: theme)
                chart
                if let busiest = context.data.busiest {
                    StatsInsight(
                        icon: "sparkles",
                        text: busiestText(busiest),
                        theme: theme
                    )
                }
            } else {
                StatsEmptyNote(
                    icon: "chart.xyaxis.line",
                    title: "No activity in this period",
                    text: "Listen, dictate, or create something and your activity charts up here.",
                    theme: theme,
                    minHeight: 220
                )
            }
        }
    }

    private func busiestText(_ busiest: TimelinePoint) -> String {
        let caption = StatsFormat.pointCaption(busiest.date, range: context.data.range)
        return "Busiest \(unit == .day ? "day" : "month"): \(caption) with \(StatsFormat.minutes(busiest.totalMinutes)) active."
    }

    private var chart: some View {
        let theme = context.theme
        return Chart {
            ForEach(series) { item in
                ForEach(context.data.timeline) { point in
                    AreaMark(
                        x: .value("Date", point.date, unit: unit),
                        y: .value("Minutes", item.value(point)),
                        stacking: .standard
                    )
                    .foregroundStyle(by: .value("Activity", item.id))
                    .interpolationMethod(.monotone)
                    .opacity(0.85)
                }
            }
            if let point = selectedPoint {
                RuleMark(x: .value("Selected", point.date, unit: unit))
                    .foregroundStyle(theme.separator)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .overlay, alignment: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        StatsCallout(
                            title: StatsFormat.pointCaption(point.date, range: context.data.range),
                            rows: series.map { StatsCalloutRow(color: $0.color, label: $0.id, value: StatsFormat.minutes($0.value(point))) }
                                + [StatsCalloutRow(color: theme.secondaryText, label: "Total", value: StatsFormat.minutes(point.totalMinutes))],
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
                    if let minutes = value.as(Double.self) {
                        Text(StatsFormat.minutes(minutes))
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
        .frame(height: 250)
        .onAppear { selection = StatsDebug.selection(in: context.data.timeline) }
        .accessibilityLabel("Stacked area chart of minutes per \(unit == .day ? "day" : "month") by activity")
        .accessibilityValue("Total \(StatsFormat.minutes(context.data.timeline.reduce(0) { $0 + $1.totalMinutes })) active")
    }
}

struct StatsNarrativeCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    let context: StatsContext

    var body: some View {
        let theme = context.theme
        StatsCard("This period", subtitle: context.rangeCaption(), theme: theme) {
            Text(context.data.narrative(voiceName: { DashboardViewModel.voiceName(for: $0) }, weekdayName: { StatsFormat.weekdayName($0) }))
                .font(vm.font(.body))
                .foregroundStyle(theme.text)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                Text("Written from your on-device stats")
                    .font(vm.font(.bodySmall))
            }
            .foregroundStyle(theme.tertiaryText)
        }
    }
}

struct StatsStreakCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    let context: StatsContext

    var body: some View {
        let theme = context.theme
        let data = context.data
        StatsCard("Streak", subtitle: "Days in a row with any activity", theme: theme) {
            HStack(alignment: .firstTextBaseline, spacing: 28) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(data.currentStreak > 0 ? theme.accent : theme.tertiaryText)
                            .accessibilityHidden(true)
                        Text("\(data.currentStreak)")
                            .font(vm.font(.display).monospacedDigit())
                            .foregroundStyle(theme.text)
                            .contentTransition(.numericText())
                        Text(data.currentStreak == 1 ? "day" : "days")
                            .font(vm.font(.label))
                            .foregroundStyle(theme.secondaryText)
                    }
                    Text("Current streak")
                        .font(vm.font(.bodySmall))
                        .foregroundStyle(theme.tertiaryText)
                }
                StatsMiniStat(label: "Longest", value: "\(data.longestStreak)d", detail: nil, theme: theme)
                StatsMiniStat(label: "Active days", value: "\(data.lifetime.activeDays)", detail: "all time", theme: theme)
            }
            HStack(spacing: 8) {
                ForEach(Array(zip(0..., data.recentWeek)), id: \.0) { index, active in
                    VStack(spacing: 5) {
                        Circle()
                            .fill(active ? theme.accent : theme.emptyCell)
                            .frame(width: 26, height: 26)
                            .overlay {
                                if active {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(theme.base.onPrimary)
                                }
                            }
                        Text(dayLetter(offset: 6 - index))
                            .font(vm.font(.bodySmall))
                            .foregroundStyle(theme.tertiaryText)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Last 7 days: \(data.recentWeek.filter(\.self).count) active")
            if data.currentStreak > 0, data.currentStreak == data.longestStreak {
                Label("Personal best", systemImage: "trophy.fill")
                    .font(vm.font(.bodySmall))
                    .foregroundStyle(theme.accent)
            }
        }
    }

    private func dayLetter(offset: Int) -> String {
        let date = context.calendar.date(byAdding: .day, value: -offset, to: Date()) ?? Date()
        return date.formatted(Date.FormatStyle(calendar: context.calendar).weekday(.narrow))
    }
}

struct StatsContributionCard: View {
    let context: StatsContext

    var body: some View {
        StatsCard("Contribution map", subtitle: "Daily activity, last \(StatsAggregates.contributionWeeks) weeks", theme: context.theme) {
            if context.data.contributions.activeDays == 0 {
                StatsEmptyNote(icon: "square.grid.3x3", title: "Nothing to map yet", text: "Each day you use Voqora lights up a square.", theme: context.theme)
            } else {
                StatsContributionHeatmap(contributions: context.data.contributions, theme: context.theme)
                let contributions = context.data.contributions
                VStack(alignment: .leading, spacing: 6) {
                    StatsInsight(icon: "calendar.badge.checkmark", text: "\(contributions.activeDays) active days in the last \(contributions.weeks) weeks.", theme: context.theme)
                    if let best = contributions.cells.max(by: { $0.minutes < $1.minutes }), best.minutes > 0 {
                        StatsInsight(
                            icon: "trophy",
                            text: "Most active day: \(best.date.formatted(.dateTime.month(.abbreviated).day())) with \(StatsFormat.minutes(best.minutes)).",
                            theme: context.theme
                        )
                    }
                }
            }
        }
    }
}

struct StatsRhythmCard: View {
    let context: StatsContext

    var body: some View {
        let data = context.data
        StatsCard("When you're active", subtitle: "Hour of day by weekday, \(context.rangeCaption())", theme: context.theme) {
            if data.hourWeekdayPeak <= 0 {
                StatsEmptyNote(icon: "clock", title: "No rhythm yet", text: "Your daily rhythm appears after a few sessions.", theme: context.theme)
            } else {
                StatsHourWeekdayHeatmap(matrix: data.hourWeekday, peak: data.hourWeekdayPeak, theme: context.theme)
                VStack(alignment: .leading, spacing: 6) {
                    if let hour = data.peakHour {
                        StatsInsight(icon: "sun.max", text: "Most active around \(StatsFormat.hour(hour)).", theme: context.theme)
                    }
                    if let day = data.peakWeekday {
                        StatsInsight(icon: "calendar", text: "\(StatsFormat.weekdayName(day))s are your busiest day.", theme: context.theme)
                    }
                }
            }
        }
    }
}

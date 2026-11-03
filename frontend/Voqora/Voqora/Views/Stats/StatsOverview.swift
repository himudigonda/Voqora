import Charts
import SwiftUI

struct StatsOverviewSection: View {
    let context: StatsContext
    let onSelect: (StatsProduct) -> Void

    private enum Lens: String, StatsLens {
        case activity
        case calendar
        case rhythm
        case summary

        var title: String {
            switch self {
            case .activity: "Activity"
            case .calendar: "Calendar"
            case .rhythm: "Rhythm"
            case .summary: "Summary"
            }
        }

        var icon: String {
            switch self {
            case .activity: "chart.xyaxis.line"
            case .calendar: "calendar"
            case .rhythm: "clock.fill"
            case .summary: "text.alignleft"
            }
        }

        var subtitle: String {
            switch self {
            case .activity: ""
            case .calendar: "Your streak and the days you showed up"
            case .rhythm: "When you use Voqora"
            case .summary: "This period in a few sentences"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            StatsTimeSavedCard(context: context, onSelect: onSelect)
            StatsLensCard(context: context) { (lens: Lens) in
                switch lens {
                case .activity:
                    StatsActivityAreaCard(context: context)
                case .calendar:
                    AdaptiveGrid(minColumnWidth: 280, maxColumns: 2) {
                        StatsContributionCard(context: context)
                        StatsStreakCard(context: context)
                    }
                case .rhythm:
                    StatsOverviewRhythm(context: context)
                case .summary:
                    StatsNarrativeLines(context: context, onSelect: onSelect)
                }
            }
        }
    }
}

struct StatsTimeSavedCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    let context: StatsContext
    let onSelect: (StatsProduct) -> Void

    var body: some View {
        let theme = context.theme
        let current = context.current
        let ink = theme.base.onPrimaryContainer
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: Theme.Space.card) {
                    headline(current: current, ink: ink)
                        .frame(width: 190, alignment: .leading)
                    readAloudSaving(current: current, ink: ink)
                    dictationSaving(current: current, ink: ink)
                }
                VStack(alignment: .leading, spacing: Theme.Space.item) {
                    headline(current: current, ink: ink)
                    HStack(alignment: .top, spacing: Theme.Space.card) {
                        readAloudSaving(current: current, ink: ink)
                            .frame(minWidth: 200)
                        dictationSaving(current: current, ink: ink)
                            .frame(minWidth: 200)
                    }
                }
                VStack(alignment: .leading, spacing: Theme.Space.item) {
                    headline(current: current, ink: ink)
                    readAloudSaving(current: current, ink: ink)
                    dictationSaving(current: current, ink: ink)
                }
            }
            definition(ink: ink)
        }
        .padding(.horizontal, Theme.Space.card)
        .padding(.vertical, Theme.Space.item + 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.base.primaryContainer.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Shape.xl, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func definition(ink: Color) -> some View {
        (
            Text(StatsProduct.overview.definition)
                + Text(context.data.previousPeriodName.map { " Changes compare to the \($0)." } ?? "")
        )
        .font(vm.font(.bodySmall))
        .foregroundStyle(ink.opacity(0.75))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func headline(current: PeriodAggregate, ink: Color) -> some View {
        let change = context.data.change { $0.totalSavedSeconds }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("Time saved")
                    .font(vm.font(.label))
                    .foregroundStyle(ink.opacity(0.8))
                StatsHelpButton("How time saved is estimated", theme: context.theme) { formula }
            }
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.unit * 2) {
                Text(current.totalSavedSeconds >= 1 ? StatsFormat.duration(current.totalSavedSeconds) : "0m")
                    .font(vm.font(.display).monospacedDigit())
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let label = StatsFormat.change(change) {
                    StatsChangeChip(label: label, change: change ?? 0, theme: context.theme)
                        .fixedSize()
                }
            }
            Text(StatsFormat.rangeCaption(context.data.interval, range: context.data.range))
                .font(vm.font(.bodySmall))
                .foregroundStyle(ink.opacity(0.7))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Time saved, \(StatsFormat.duration(current.totalSavedSeconds))\(StatsFormat.change(change).map { ", \($0) \(context.data.comparison ?? "")" } ?? "")")
    }

    private func readAloudSaving(current: PeriodAggregate, ink: Color) -> some View {
        saving(
            SavingModel(
                product: .readAloud,
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
                product: .dictation,
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
        let product: StatsProduct
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
        let tint = model.product.tint(in: context.theme)
        return Button {
            onSelect(model.product)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: model.product.icon)
                        .font(vm.font(.labelSmall))
                        .foregroundStyle(tint)
                        .frame(width: 22, height: 22)
                        .background(tint.opacity(0.22), in: Circle())
                        .accessibilityHidden(true)
                    Text(model.product.title)
                        .font(vm.font(.label))
                    Spacer(minLength: 8)
                    if !model.isEmpty {
                        Text(model.saved >= 60 ? "saved \(StatsFormat.duration(model.saved))" : "about even")
                            .font(vm.font(.label).monospacedDigit())
                    }
                    Image(systemName: "chevron.right")
                        .font(vm.font(.labelSmall))
                        .foregroundStyle(ink.opacity(0.5))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(ink)
                if model.isEmpty {
                    Text(model.emptyText)
                        .font(vm.font(.bodySmall))
                        .foregroundStyle(ink.opacity(0.7))
                        .padding(.vertical, Theme.Space.unit * 2)
                } else {
                    comparisonBar(label: model.wouldTakeLabel, value: model.wouldTake, fraction: model.wouldTake / peak, fill: ink.opacity(0.32), ink: ink)
                    comparisonBar(label: model.tookLabel, value: model.took, fraction: model.took / peak, fill: tint, ink: ink)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(model.product.title)")
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens \(model.product.title)")
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
                "Read Aloud",
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
    @State private var isolated: String?

    private struct Series: Identifiable {
        let id: String
        let color: Color
        let value: (TimelinePoint) -> Double
    }

    private var series: [Series] {
        [
            Series(id: "Read aloud", color: StatsPalette.readAloud, value: { $0.speechMinutes }),
            Series(id: "Audiobook listening", color: StatsPalette.audiobooks, value: { $0.listeningMinutes }),
            Series(id: "Dictation", color: StatsPalette.dictation, value: { $0.dictationMinutes }),
            Series(id: "Audiobook rendering", color: StatsPalette.audiobookRendering, value: { $0.creatingMinutes }),
        ]
    }

    private var visibleSeries: [Series] {
        guard let isolated else { return series }
        return series.filter { $0.id == isolated }
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
        StatsCard(
            "Minutes by product",
            subtitle: "Minutes per \(unit == .day ? "day" : "month"), \(context.rangeCaption()). Podcasts and AI are counted in items rather than minutes, so they are not plotted.",
            theme: theme
        ) {
            if hasActivity {
                StatsLegend(items: series.map { StatsLegendItem(id: $0.id, label: $0.id, color: $0.color) }, theme: theme, isolated: $isolated)
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
            ForEach(visibleSeries) { item in
                ForEach(context.data.timeline) { point in
                    AreaMark(
                        x: .value("Date", point.date, unit: unit),
                        y: .value("Minutes", item.value(point)),
                        stacking: .standard
                    )
                    .foregroundStyle(by: .value("Activity", item.id))
                    .interpolationMethod(.monotone)
                }
            }
            if let point = selectedPoint {
                RuleMark(x: .value("Selected", point.date, unit: unit))
                    .foregroundStyle(theme.separator)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .overlay, alignment: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        StatsCallout(
                            title: StatsFormat.pointCaption(point.date, range: context.data.range),
                            rows: visibleSeries.map { StatsCalloutRow(color: $0.color, label: $0.id, value: StatsFormat.minutes($0.value(point))) }
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
        .frame(height: 200)
        .onAppear {
            selection = StatsDebug.selection(in: context.data.timeline)
            isolated = StatsDebug.isolatedSeries
        }
        .accessibilityLabel("Stacked area chart of minutes per \(unit == .day ? "day" : "month") by product")
        .accessibilityValue("Total \(StatsFormat.minutes(context.data.timeline.reduce(0) { $0 + $1.totalMinutes })) active")
    }
}

struct StatsNarrativeLines: View {
    @EnvironmentObject var vm: DashboardViewModel
    let context: StatsContext
    let onSelect: (StatsProduct) -> Void

    var body: some View {
        let theme = context.theme
        let lines = context.data.narrativeLines(voiceName: { DashboardViewModel.voiceName(for: $0) }, weekdayName: { StatsFormat.weekdayName($0) })
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            ForEach(lines) { line in
                row(line)
            }
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(vm.font(.labelSmall))
                    .accessibilityHidden(true)
                Text("Written from your on-device stats")
                    .font(vm.font(.bodySmall))
            }
            .foregroundStyle(theme.tertiaryText)
        }
    }

    @ViewBuilder
    private func row(_ line: StatsNarrativeLine) -> some View {
        if let product = line.product {
            Button {
                onSelect(product)
            } label: {
                content(line, icon: product.icon, tint: product.tint(in: context.theme))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(product.title)")
            .accessibilityHint("Opens \(product.title)")
        } else {
            content(line, icon: "calendar", tint: context.theme.accent)
        }
    }

    private func content(_ line: StatsNarrativeLine, icon: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.item) {
            Image(systemName: icon)
                .font(vm.font(.labelSmall))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.18), in: Circle())
                .accessibilityHidden(true)
            Text(line.text)
                .font(vm.font(.body))
                .foregroundStyle(context.theme.text)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
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

struct StatsOverviewRhythm: View {
    let context: StatsContext
    @State private var filter = Filter.all

    private enum Filter: String, CaseIterable {
        case all = "All"
        case readAloud = "Read Aloud"
        case dictation = "Dictation"
        case audiobooks = "Audiobooks"
    }

    private var matrix: [[Double]] {
        switch filter {
        case .all: context.data.hourWeekday
        case .readAloud: context.data.readAloudHourWeekday
        case .dictation: context.data.dictationHourWeekday
        case .audiobooks: context.data.audiobookHourWeekday
        }
    }

    private var tint: Color {
        switch filter {
        case .all: context.theme.accent
        case .readAloud: StatsProduct.readAloud.tint(in: context.theme)
        case .dictation: StatsProduct.dictation.tint(in: context.theme)
        case .audiobooks: StatsProduct.audiobooks.tint(in: context.theme)
        }
    }

    private var noun: String {
        switch filter {
        case .all: "are active"
        case .readAloud: "have text read aloud"
        case .dictation: "dictate"
        case .audiobooks: "listen"
        }
    }

    var body: some View {
        StatsRhythmLens(matrix: matrix, tint: tint, noun: noun) {
            StatsMetricToggle(selection: $filter, options: Filter.allCases, title: { $0.rawValue }, theme: context.theme)
        }
    }
}

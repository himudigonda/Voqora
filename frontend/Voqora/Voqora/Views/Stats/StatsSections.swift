import Charts
import SwiftUI

struct StatsActivityCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    let summary: UsageSummary
    let theme: StatsTheme
    @State private var selection: Date?

    private var unit: Calendar.Component {
        summary.range.bucket
    }

    private var selectedPoint: ActivityPoint? {
        guard let selection else { return nil }
        return summary.series.first { point in
            Calendar.current.isDate(point.date, equalTo: selection, toGranularity: unit)
        }
    }

    private var hasActivity: Bool {
        summary.series.contains { $0.totalMinutes > 0 }
    }

    var body: some View {
        StatsCard(
            "Activity",
            subtitle: StatsFormat.rangeCaption(summary.interval, range: summary.range),
            icon: "chart.bar.xaxis",
            theme: theme
        ) {
            HStack(spacing: 14) {
                legendDot(theme.strong, "Selected Text")
                legendDot(theme.muted, "Audiobooks")
            }
        } content: {
            ZStack {
                Chart {
                    ForEach(summary.series) { point in
                        BarMark(
                            x: .value("Date", point.date, unit: unit),
                            y: .value("Minutes", point.speechMinutes)
                        )
                        .foregroundStyle(theme.strong)
                        .cornerRadius(3)
                        BarMark(
                            x: .value("Date", point.date, unit: unit),
                            y: .value("Minutes", point.listeningMinutes)
                        )
                        .foregroundStyle(theme.muted)
                        .cornerRadius(3)
                    }
                    if let point = selectedPoint {
                        RuleMark(x: .value("Selected", point.date, unit: unit))
                            .foregroundStyle(Palette.separator)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                tooltip(for: point)
                            }
                    }
                }
                .chartXSelection(value: $selection)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                            .foregroundStyle(Palette.separator)
                        AxisValueLabel {
                            if let minutes = value.as(Double.self) {
                                Text(StatsFormat.minutes(minutes))
                                    .font(vm.font(.caption))
                                    .foregroundStyle(Palette.textTertiary)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: summary.range == .month ? 6 : 7)) { value in
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(axisLabel(date))
                                    .font(vm.font(.caption))
                                    .foregroundStyle(Palette.textTertiary)
                            }
                        }
                    }
                }
                .frame(height: 220)
                .opacity(hasActivity ? 1 : 0.35)
                .accessibilityLabel("Minutes listened per \(unit == .day ? "day" : "month")")

                if !hasActivity {
                    Text("No listening in this period yet")
                        .font(vm.appFont(size: 13, weight: .medium))
                        .foregroundStyle(Palette.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                }
            }
            if let busiest = summary.busiestDay {
                StatsInsight(
                    icon: "sparkles",
                    text: "Busiest day: \(busiest.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) with \(StatsFormat.minutes(busiest.minutes)) of listening.",
                    theme: theme
                )
            }
        }
    }

    private func axisLabel(_ date: Date) -> String {
        switch summary.range {
        case .week: date.formatted(.dateTime.weekday(.abbreviated))
        case .month: date.formatted(.dateTime.month(.abbreviated).day())
        case .year, .all: date.formatted(.dateTime.month(.narrow))
        }
    }

    private func tooltip(for point: ActivityPoint) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(unit == .day
                ? point.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
                : point.date.formatted(.dateTime.month(.wide).year()))
                .font(vm.appFont(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
            tooltipRow(theme.strong, "Selected Text", point.speechMinutes)
            tooltipRow(theme.muted, "Audiobooks", point.listeningMinutes)
        }
        .padding(10)
        .voqoraSurface(.floating, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func tooltipRow(_ color: Color, _ label: String, _ minutes: Double) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
            Spacer(minLength: 12)
            Text(StatsFormat.minutes(minutes)).monospacedDigit()
        }
        .font(vm.appFont(size: 11))
        .foregroundStyle(Palette.textSecondary)
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(vm.font(.caption))
                .foregroundStyle(Palette.textSecondary)
        }
    }
}

struct StatsRhythmCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    let summary: UsageSummary
    let theme: StatsTheme

    var body: some View {
        StatsCard("Rhythm", subtitle: "When you listen", icon: "clock", theme: theme) {
            if summary.peakHour == nil {
                StatsEmptyNote(text: "Your daily rhythm appears after a few sessions.")
            } else {
                hourChart
                weekdayStrip
                VStack(alignment: .leading, spacing: 6) {
                    if let hour = summary.peakHour {
                        StatsInsight(icon: "sun.max", text: "You listen most around \(StatsFormat.hour(hour)).", theme: theme)
                    }
                    if let day = summary.peakWeekday {
                        StatsInsight(icon: "calendar", text: "\(StatsFormat.weekdayName(day))s are your busiest day.", theme: theme)
                    }
                }
            }
        }
    }

    private var hourChart: some View {
        let peak = summary.peakHour
        return Chart {
            ForEach(0 ..< 24, id: \.self) { hour in
                BarMark(x: .value("Hour", hour), y: .value("Minutes", summary.hours[hour] / 60), width: .fixed(9))
                    .foregroundStyle(hour == peak ? theme.strong : theme.muted.opacity(0.75))
                    .cornerRadius(2)
            }
        }
        .chartXScale(domain: -0.5 ... 23.5)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18]) { value in
                AxisValueLabel {
                    if let hour = value.as(Int.self) {
                        Text(StatsFormat.hour(hour))
                            .font(vm.font(.caption))
                            .foregroundStyle(Palette.textTertiary)
                    }
                }
            }
        }
        .frame(height: 96)
        .accessibilityLabel("Listening by hour of day")
    }

    private var weekdayStrip: some View {
        let peak = max(summary.weekdays.max() ?? 0, 1)
        return HStack(spacing: 6) {
            ForEach(0 ..< 7, id: \.self) { day in
                let level = summary.weekdays[day] / peak
                VStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(level > 0 ? theme.accent.opacity(0.18 + 0.82 * level) : Palette.controlFill)
                        .frame(height: 26)
                    Text(StatsFormat.weekdayName(day, short: true))
                        .font(vm.font(.caption))
                        .foregroundStyle(day == summary.peakWeekday ? Palette.textPrimary : Palette.textTertiary)
                }
                .help("\(StatsFormat.weekdayName(day)): \(StatsFormat.duration(summary.weekdays[day]))")
            }
        }
    }
}

struct StatsStreakCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    let summary: UsageSummary
    let heatmap: [[HeatmapDay]]
    let theme: StatsTheme

    private var peakMinutes: Double {
        max(heatmap.joined().map(\.minutes).max() ?? 0, 1)
    }

    var body: some View {
        StatsCard("Consistency", subtitle: "Last \(heatmap.count) weeks", icon: "flame", theme: theme) {
            HStack(alignment: .firstTextBaseline, spacing: 28) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(summary.currentStreak)")
                            .font(vm.appFont(size: 34, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(summary.currentStreak > 0 ? theme.accent : Palette.textPrimary)
                            .contentTransition(.numericText())
                        Text(summary.currentStreak == 1 ? "day" : "days")
                            .font(vm.appFont(size: 14, weight: .medium))
                            .foregroundStyle(Palette.textSecondary)
                    }
                    Text("Current streak")
                        .font(vm.font(.rowSubtitle))
                        .foregroundStyle(Palette.textTertiary)
                }
                StatsMiniStat(label: "Longest streak", value: "\(summary.longestStreak)d", detail: nil)
                StatsMiniStat(label: "Active days", value: "\(summary.lifetime.activeDays)", detail: nil)
            }
            heatmapGrid
            HStack(spacing: 4) {
                Text("Less")
                ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(cellColor(level: level, active: level > 0))
                        .frame(width: 10, height: 10)
                }
                Text("More")
                Spacer()
                if summary.currentStreak > 0, summary.currentStreak == summary.longestStreak {
                    Label("Personal best", systemImage: "trophy.fill")
                        .foregroundStyle(theme.accent)
                }
            }
            .font(vm.font(.caption))
            .foregroundStyle(Palette.textTertiary)
        }
    }

    private var heatmapGrid: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 3
            let columns = CGFloat(heatmap.count)
            let side = min(16, (proxy.size.width - spacing * (columns - 1)) / columns)
            HStack(alignment: .top, spacing: spacing) {
                ForEach(Array(heatmap.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: spacing) {
                        ForEach(week) { day in
                            RoundedRectangle(cornerRadius: max(2, side * 0.22), style: .continuous)
                                .fill(day.isFuture ? Color.clear : cellColor(level: day.minutes / peakMinutes, active: day.isActive))
                                .frame(width: side, height: side)
                                .help(day.isFuture ? "" : "\(day.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())): \(StatsFormat.minutes(day.minutes))")
                        }
                    }
                }
            }
        }
        .frame(height: 7 * 16 + 6 * 3)
        .accessibilityLabel("Daily activity over the last \(heatmap.count) weeks")
    }

    private func cellColor(level: Double, active: Bool) -> Color {
        guard active || level > 0 else { return Palette.controlFill }
        return theme.accent.opacity(0.22 + 0.78 * min(1, max(0, level)))
    }
}

struct StatsVoicesCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    let summary: UsageSummary
    let theme: StatsTheme

    var body: some View {
        StatsCard("Voices", subtitle: "Selected text, by narrator", icon: "person.wave.2", theme: theme) {
            if summary.voices.isEmpty {
                StatsEmptyNote(text: "Speak some selected text to see your favorite voices.")
            } else {
                VStack(spacing: 14) {
                    ForEach(Array(summary.voices.prefix(5).enumerated()), id: \.element.id) { index, voice in
                        voiceRow(voice, rank: index)
                    }
                }
                if let speed = summary.favoriteSpeed {
                    StatsInsight(icon: "gauge.with.needle", text: "Favorite speed: \(StatsFormat.speed(speed))", theme: theme)
                }
            }
        }
    }

    private func voiceRow(_ voice: RankedVoice, rank: Int) -> some View {
        let name = DashboardViewModel.voiceName(for: voice.voice)
        return HStack(spacing: 12) {
            Text(String(name.prefix(1)))
                .font(vm.appFont(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(
                    LinearGradient(colors: [theme.strong, theme.muted], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .opacity(rank == 0 ? 1 : 0.7),
                    in: Circle()
                )
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(name)
                        .font(vm.appFont(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                    Text(StatsFormat.voiceDetail(voice.voice))
                        .font(vm.font(.caption))
                        .foregroundStyle(Palette.textTertiary)
                    Spacer()
                    Text("\(voice.usage.uses) \(voice.usage.uses == 1 ? "time" : "times")")
                        .font(vm.appFont(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Palette.textSecondary)
                }
                StatsShareBar(fraction: voice.share, tint: rank == 0 ? theme.accent : theme.muted)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(Int((voice.share * 100).rounded())) percent, \(voice.usage.uses) uses")
    }
}

struct StatsLibraryCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    let summary: UsageSummary
    let library: LibraryStats
    let titles: [String: String]
    let theme: StatsTheme

    var body: some View {
        StatsCard("Audiobooks", subtitle: "Your library on this Mac", icon: "books.vertical", theme: theme) {
            if library.books == 0, summary.books.isEmpty {
                StatsEmptyNote(text: "Turn a PDF, Word, text, or Markdown file into an audiobook to see it here.")
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 18) {
                    GridRow {
                        StatsMiniStat(
                            label: "Books",
                            value: "\(library.books)",
                            detail: library.inProgress > 0 ? "\(library.ready) ready · \(library.inProgress) in progress" : "\(library.ready) ready"
                        )
                        StatsMiniStat(label: "Audio created", value: StatsFormat.duration(library.audioSeconds), detail: library.longest.map { "Longest: \(StatsFormat.duration($0.seconds))" })
                        StatsMiniStat(label: "Pages", value: StatsFormat.count(library.pages), detail: "\(StatsFormat.count(library.words)) words")
                    }
                    GridRow {
                        StatsMiniStat(label: "Processing time", value: StatsFormat.duration(library.processingSeconds), detail: nil)
                        StatsMiniStat(
                            label: "AI cleanup",
                            value: StatsFormat.currency(library.cleanupCostUsd),
                            detail: library.tokens > 0 ? "\(StatsFormat.count(library.tokens)) tokens" : "\(library.cleanedBooks) books"
                        )
                        StatsMiniStat(label: "Listened", value: StatsFormat.duration(summary.totals.listeningSeconds), detail: summary.range.title)
                    }
                }
                if !summary.books.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("MOST LISTENED")
                            .font(vm.font(.sectionHeader))
                            .kerning(0.6)
                            .foregroundStyle(Palette.textTertiary)
                        let top = summary.books.prefix(3)
                        let peak = max(top.first?.seconds ?? 1, 1)
                        ForEach(Array(top)) { book in
                            HStack(spacing: 12) {
                                Text(titles[book.bookID] ?? "Removed audiobook")
                                    .font(vm.appFont(size: 13, weight: .medium))
                                    .foregroundStyle(titles[book.bookID] == nil ? Palette.textTertiary : Palette.textPrimary)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                StatsShareBar(fraction: book.seconds / peak, tint: theme.muted)
                                    .frame(width: 80)
                                Text(StatsFormat.duration(book.seconds))
                                    .font(vm.appFont(size: 12, weight: .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(Palette.textSecondary)
                                    .frame(width: 58, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct StatsMilestonesCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    let summary: UsageSummary
    let theme: StatsTheme

    private var words: Milestone {
        UsageSummary.milestone(title: "Words spoken", value: Double(summary.lifetime.speechWords), ladder: UsageSummary.wordMilestones)
    }

    private var hours: Milestone {
        UsageSummary.milestone(title: "Hours listened", value: summary.lifetime.totalSeconds / 3600, ladder: UsageSummary.hourMilestones)
    }

    var body: some View {
        StatsCard("Milestones", subtitle: "All time", icon: "trophy", theme: theme) {
            VStack(spacing: 18) {
                milestoneRow(words, format: { StatsFormat.count(Int($0)) })
                milestoneRow(hours, format: { value in
                    value < 10 ? value.formatted(.number.precision(.fractionLength(0 ... 1))) : "\(Int(value))"
                })
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                ForEach(facts, id: \.self) { fact in
                    StatsInsight(icon: "lightbulb", text: fact, theme: theme)
                }
            }
        }
    }

    private var facts: [String] {
        let lifetime = summary.lifetime
        var lines: [String] = []
        let novels = Double(lifetime.speechWords) / StatsFormat.wordsPerNovel
        if novels >= 0.1 {
            lines.append("You've heard about \(novels.formatted(.number.precision(.fractionLength(novels < 10 ? 1 : 0)))) novels' worth of selected text.")
        } else if lifetime.speechWords > 0 {
            let pages = max(1, Int((Double(lifetime.speechWords) / StatsFormat.wordsPerPaperbackPage).rounded()))
            lines.append("That's about \(pages) paperback \(pages == 1 ? "page" : "pages") read aloud.")
        }
        if lifetime.speechCount > 0 {
            lines.append("On average, each selection is \(lifetime.speechWords / max(1, lifetime.speechCount)) words long.")
        }
        if lifetime.exports > 0 {
            lines.append("You've saved \(lifetime.exports) \(lifetime.exports == 1 ? "clip" : "clips") to your Desktop.")
        }
        if lifetime.launches > 0 {
            lines.append("Voqora has opened \(lifetime.launches) \(lifetime.launches == 1 ? "time" : "times").")
        }
        if lines.isEmpty {
            lines.append("Listen to something to unlock your first milestone.")
        }
        return lines
    }

    private func milestoneRow(_ milestone: Milestone, format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(milestone.title)
                    .font(vm.appFont(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
                Text("\(format(milestone.current)) of \(format(milestone.target))")
                    .font(vm.appFont(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Palette.textSecondary)
            }
            StatsShareBar(fraction: milestone.progress, tint: theme.accent)
            if !milestone.reached.isEmpty {
                HStack(spacing: 6) {
                    ForEach(milestone.reached.suffix(4), id: \.self) { value in
                        Label(format(value), systemImage: "checkmark.seal.fill")
                            .font(vm.font(.caption))
                            .foregroundStyle(theme.accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(theme.accent.opacity(0.12), in: Capsule())
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

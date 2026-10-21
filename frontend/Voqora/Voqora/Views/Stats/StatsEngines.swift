import Charts
import SwiftUI

struct StatsEnginesSection: View {
    let context: StatsContext

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.card) {
            AdaptiveGrid(minColumnWidth: 400) {
                StatsEngineTableCard(context: context).statsSpan(2)
                StatsLatencyCard(context: context)
                StatsEngineShareCard(context: context)
            }
        }
    }
}

enum StatsEngineColors {
    static func color(for id: String, in rows: [EngineRow], theme: StatsTheme) -> Color {
        let index = rows.firstIndex { $0.id == id } ?? 0
        return theme.series(index)
    }
}

struct StatsEngineTableCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    let context: StatsContext

    var body: some View {
        let theme = context.theme
        let rows = context.data.engines
        StatsCard("Engines", subtitle: "How each speech engine performed, \(context.rangeCaption())", theme: theme) {
            if rows.isEmpty {
                StatsEmptyNote(icon: "cpu", title: "No engine data yet", text: "Read some text aloud and each engine's speed and reliability is compared here.", theme: theme, minHeight: 180)
            } else {
                Grid(alignment: .leading, horizontalSpacing: Theme.Space.card, verticalSpacing: 12) {
                    GridRow {
                        header("Engine")
                        header("Uses").gridColumnAlignment(.trailing)
                        header("Audio").gridColumnAlignment(.trailing)
                        header("First audio").gridColumnAlignment(.trailing)
                        header("Real-time").gridColumnAlignment(.trailing)
                        header("Failures").gridColumnAlignment(.trailing)
                    }
                    Divider().gridCellColumns(6)
                    ForEach(rows) { row in
                        GridRow {
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(StatsEngineColors.color(for: row.id, in: rows, theme: theme))
                                    .frame(width: 10, height: 10)
                                Text(row.name)
                                    .font(vm.font(.label))
                                    .foregroundStyle(theme.text)
                                    .lineLimit(1)
                            }
                            cell(row.usage.uses.formatted())
                            cell(row.usage.audioSeconds > 0 ? StatsFormat.duration(row.usage.audioSeconds) : "—")
                            cell(row.usage.averageFirstAudioMs.map { StatsFormat.latency($0) } ?? "—")
                            cell(row.usage.realTimeFactor.map { StatsFormat.factor($0) + " real time" } ?? "—")
                            cell(row.failureRate.map { StatsFormat.percent($0) } ?? "—", warn: (row.failureRate ?? 0) >= 0.05)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                note(rows: rows)
            }
        }
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(vm.font(.labelSmall))
            .foregroundStyle(context.theme.tertiaryText)
    }

    private func cell(_ text: String, warn: Bool = false) -> some View {
        Text(text)
            .font(vm.font(.bodySmall).monospacedDigit())
            .foregroundStyle(warn ? context.theme.base.warning : context.theme.secondaryText)
            .lineLimit(1)
    }

    @ViewBuilder
    private func note(rows _: [EngineRow]) -> some View {
        let comparable = context.data.enginesWithRealTime
        if let fastest = context.data.fastestEngine, let factor = fastest.usage.realTimeFactor {
            let others = comparable.filter { $0.id != fastest.id }
            let runnerUp = others.max { ($0.usage.realTimeFactor ?? 0) < ($1.usage.realTimeFactor ?? 0) }
            let comparison = runnerUp.flatMap { other in
                other.usage.realTimeFactor.map { " That's ahead of \(other.name) at \(StatsFormat.factor($0))." }
            } ?? ""
            let quickest = context.data.quickestStartEngine?.id == fastest.id ? " It also starts speaking soonest." : ""
            let kokoroNote = fastest.id == SpeechEngineID.kokoro && !others.isEmpty
                ? "Kokoro is the fastest real-time engine on your Mac: \(StatsFormat.factor(factor)) real time."
                : "\(fastest.name) is your fastest real-time engine: \(StatsFormat.factor(factor)) real time."
            StatsInsight(icon: "bolt.fill", text: kokoroNote + comparison + quickest, theme: context.theme)
        }
    }
}

struct StatsLatencyCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    let context: StatsContext

    private struct Bar: Identifiable {
        let bucket: String
        let engine: String
        let count: Int

        var id: String {
            bucket + engine
        }
    }

    private var bars: [Bar] {
        context.data.engines.flatMap { row in
            zip(LatencyBuckets.labels, row.usage.firstAudioBuckets).map { Bar(bucket: $0.0, engine: row.name, count: $0.1) }
        }
    }

    var body: some View {
        let theme = context.theme
        let rows = context.data.engines.filter { $0.usage.firstAudioCount > 0 }
        StatsCard("First-audio latency", subtitle: "How long until you hear the first word", theme: theme) {
            if rows.isEmpty {
                StatsEmptyNote(icon: "timer", title: "No latency data yet", text: "Time to first audio is measured on every read.", theme: theme, minHeight: 180)
            } else {
                StatsLegend(items: rows.map { StatsLegendItem(id: $0.id, label: $0.name, color: StatsEngineColors.color(for: $0.id, in: context.data.engines, theme: theme)) }, theme: theme)
                Chart(bars.filter { bar in rows.contains { $0.name == bar.engine } }) { bar in
                    BarMark(x: .value("Latency", bar.bucket), y: .value("Reads", bar.count))
                        .position(by: .value("Engine", bar.engine))
                        .foregroundStyle(by: .value("Engine", bar.engine))
                        .cornerRadius(3)
                }
                .chartForegroundStyleScale(
                    domain: rows.map(\.name),
                    range: rows.map { StatsEngineColors.color(for: $0.id, in: context.data.engines, theme: theme) }
                )
                .chartXScale(domain: LatencyBuckets.labels)
                .chartLegend(.hidden)
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
                    AxisMarks { _ in
                        AxisValueLabel()
                            .font(vm.font(.labelSmall))
                            .foregroundStyle(theme.tertiaryText)
                    }
                }
                .frame(height: 220)
                .accessibilityLabel("Grouped bar chart of first-audio latency by engine")
            }
        }
    }
}

struct StatsEngineShareCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    let context: StatsContext
    @State private var selection: Date?

    private struct Bar: Identifiable {
        let date: Date
        let engine: String
        let uses: Int

        var id: String {
            "\(date.timeIntervalSince1970)-\(engine)"
        }
    }

    private var unit: Calendar.Component {
        context.data.trendUnit
    }

    private var bars: [Bar] {
        context.data.trend.flatMap { point in
            context.data.engines.map { Bar(date: point.date, engine: $0.name, uses: point.engineUses[$0.id] ?? 0) }
        }
    }

    private var selectedPoint: TimelinePoint? {
        guard let selection else { return nil }
        return context.data.trend.min { abs($0.date.timeIntervalSince(selection)) < abs($1.date.timeIntervalSince(selection)) }
    }

    var body: some View {
        let theme = context.theme
        let rows = context.data.engines
        StatsCard("Engine share over time", subtitle: "Reads per \(context.data.trendUnitName) by engine", theme: theme) {
            if rows.isEmpty || !bars.contains(where: { $0.uses > 0 }) {
                StatsEmptyNote(icon: "chart.bar.xaxis", title: "No engine history yet", text: "See how your engine mix shifts as you try new voices.", theme: theme, minHeight: 180)
            } else {
                StatsLegend(items: rows.map { StatsLegendItem(id: $0.id, label: $0.name, color: StatsEngineColors.color(for: $0.id, in: rows, theme: theme)) }, theme: theme)
                Chart {
                    ForEach(bars) { bar in
                        BarMark(x: .value("Date", bar.date, unit: unit), y: .value("Reads", bar.uses))
                            .foregroundStyle(by: .value("Engine", bar.engine))
                            .cornerRadius(2)
                    }
                    if let point = selectedPoint {
                        RuleMark(x: .value("Selected", point.date, unit: unit))
                            .foregroundStyle(theme.separator)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .annotation(position: .overlay, alignment: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                                StatsCallout(
                                    title: StatsFormat.pointCaption(point.date, range: context.data.range, unit: context.data.trendUnit),
                                    rows: rows.map { StatsCalloutRow(color: StatsEngineColors.color(for: $0.id, in: rows, theme: theme), label: $0.name, value: "\(point.engineUses[$0.id] ?? 0)") },
                                    theme: theme
                                )
                            }
                    }
                }
                .chartForegroundStyleScale(domain: rows.map(\.name), range: rows.map { StatsEngineColors.color(for: $0.id, in: rows, theme: theme) })
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
                    AxisMarks(values: .automatic(desiredCount: context.data.range == .week ? 7 : 5)) { value in
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
                .onAppear { selection = StatsDebug.selection(in: context.data.trend) }
                .accessibilityLabel("Stacked bar chart of reads per engine over time")
            }
        }
    }
}

import Charts
import SwiftUI

struct StatsAISection: View {
    let context: StatsContext

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.card) {
            tiles
            AdaptiveGrid(minColumnWidth: 400) {
                StatsAIToolsCard(context: context)
                StatsAIProvidersCard(context: context)
                StatsAIReliabilityCard(context: context)
                StatsAILatencyCard(context: context)
                StatsAITimelineCard(context: context).statsSpan(2)
            }
        }
    }

    private var tiles: some View {
        let data = context.data
        let ai = data.current.ai
        let theme = context.theme
        return AdaptiveGrid(minColumnWidth: 200, spacing: Theme.Space.item, maxColumns: 4, balanced: true) {
            context.tile(
                "AI requests",
                value: ai.totalRequests.formatted(),
                icon: "sparkles",
                change: data.change { Double($0.ai.totalRequests) },
                footnote: "\(ai.requests.count) \(ai.requests.count == 1 ? "tool" : "tools") used",
                tint: theme.series(0)
            )
            context.tile(
                "Success rate",
                value: data.current.aiSuccessRate.map { StatsFormat.percent($0) } ?? "—",
                icon: "checkmark.seal.fill",
                change: data.change { $0.aiSuccessRate ?? 0 },
                footnote: "\(ai.totalFailures.formatted()) failed",
                tint: theme.series(1)
            )
            context.tile(
                "Average latency",
                value: ai.averageLatencyMs.map { StatsFormat.latency($0) } ?? "—",
                icon: "timer",
                change: data.change { $0.ai.averageLatencyMs ?? 0 },
                footnote: "Time to a finished answer",
                tint: theme.series(2)
            )
            context.tile(
                "Words processed",
                value: StatsFormat.count(ai.wordsIn),
                icon: "text.alignleft",
                change: data.change { Double($0.ai.wordsIn) },
                footnote: "\(StatsFormat.count(ai.wordsOut)) words written back",
                tint: theme.series(3)
            )
        }
    }
}

struct StatsAIToolsCard: View {
    let context: StatsContext

    private var items: [StatsBarItem] {
        context.current.ai.requests
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(7)
            .enumerated()
            .map { index, entry in
                StatsBarItem(label: StatsLabels.tool(entry.key), value: Double(entry.value), color: index == 0 ? context.theme.series(0) : context.theme.series(0).opacity(0.55))
            }
    }

    var body: some View {
        StatsCard("Requests by tool", subtitle: "What you ask AI to do", theme: context.theme) {
            if items.isEmpty {
                StatsEmptyNote(icon: "sparkles", title: "No AI requests yet", text: "Summarize, translate, or ask about selected text and the tools are ranked here.", theme: context.theme)
            } else {
                StatsHBars(items: items, theme: context.theme, summary: "AI requests by tool: " + items.map { "\($0.label) \(Int($0.value))" }.joined(separator: ", "))
            }
        }
    }
}

struct StatsAIProvidersCard: View {
    let context: StatsContext

    private var slices: [StatsDonutSlice] {
        let theme = context.theme
        let sorted = context.current.ai.providers.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        var result = sorted.prefix(6).enumerated().map { index, entry in
            StatsDonutSlice(id: entry.key, label: StatsLabels.provider(entry.key), value: Double(entry.value), color: theme.series(index))
        }
        let rest = sorted.dropFirst(6).reduce(0) { $0 + $1.value }
        if rest > 0 {
            result.append(StatsDonutSlice(id: "other", label: "Other", value: Double(rest), color: theme.other))
        }
        return result
    }

    var body: some View {
        StatsCard("Provider share", subtitle: "Which provider answered", theme: context.theme) {
            if slices.isEmpty {
                StatsEmptyNote(icon: "server.rack", title: "No providers yet", text: "Connect a provider in Settings, then ask AI something.", theme: context.theme)
            } else {
                StatsDonut(
                    slices: slices,
                    theme: context.theme,
                    unit: "requests",
                    summary: "AI requests by provider: " + slices.map { "\($0.label) \(Int($0.value))" }.joined(separator: ", ")
                )
            }
        }
    }
}

struct StatsAIReliabilityCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    let context: StatsContext

    var body: some View {
        let theme = context.theme
        let ai = context.current.ai
        StatsCard("Reliability", subtitle: "Requests that finished without an error", theme: theme) {
            if let rate = context.current.aiSuccessRate {
                HStack(spacing: Theme.Space.card + 8) {
                    ZStack {
                        Gauge(value: rate, in: 0 ... 1) {
                            Text("Success rate")
                        }
                        .gaugeStyle(.accessoryCircularCapacity)
                        .tint(rate >= 0.9 ? theme.base.success : (rate >= 0.7 ? theme.base.warning : theme.base.danger))
                        .scaleEffect(2.3)
                        Text(StatsFormat.percent(rate))
                            .font(vm.font(.title).monospacedDigit())
                            .foregroundStyle(theme.text)
                    }
                    .frame(width: 118, height: 118)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Success rate")
                    .accessibilityValue(StatsFormat.percent(rate))
                    VStack(alignment: .leading, spacing: 10) {
                        StatsMiniStat(label: "Succeeded", value: (ai.totalRequests - ai.totalFailures).formatted(), detail: nil, theme: theme)
                        StatsMiniStat(label: "Failed", value: ai.totalFailures.formatted(), detail: failedTools(ai), theme: theme)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                StatsEmptyNote(icon: "checkmark.seal", title: "No reliability data yet", text: "Your success rate appears after your first AI request.", theme: theme)
            }
        }
    }

    private func failedTools(_ ai: AIActivity) -> String? {
        guard let worst = ai.failures.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) else { return nil }
        return "Most in \(StatsLabels.tool(worst.key))"
    }
}

struct StatsAILatencyCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    let context: StatsContext

    var body: some View {
        let theme = context.theme
        let ai = context.current.ai
        StatsCard("Latency", subtitle: "Average time to a finished answer", theme: theme) {
            if let latency = ai.averageLatencyMs {
                VStack(alignment: .leading, spacing: Theme.Space.item) {
                    Text(StatsFormat.latency(latency))
                        .font(vm.font(.display).monospacedDigit())
                        .foregroundStyle(theme.text)
                    Text("across \(ai.latencyCount.formatted()) successful \(ai.latencyCount == 1 ? "request" : "requests")")
                        .font(vm.font(.bodySmall))
                        .foregroundStyle(theme.tertiaryText)
                    Divider()
                    HStack(spacing: Theme.Space.card) {
                        StatsMiniStat(label: "Words in", value: StatsFormat.count(ai.wordsIn), detail: "sent to AI", theme: theme)
                        StatsMiniStat(label: "Words out", value: StatsFormat.count(ai.wordsOut), detail: "written back", theme: theme)
                    }
                }
            } else {
                StatsEmptyNote(icon: "timer", title: "No latency data yet", text: "Response times are measured on every successful request.", theme: theme)
            }
        }
    }
}

struct StatsAITimelineCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    let context: StatsContext
    @State private var selection: Date?

    private var unit: Calendar.Component {
        context.data.trendUnit
    }

    private var selectedPoint: TimelinePoint? {
        guard let selection else { return nil }
        return context.data.trend.min { abs($0.date.timeIntervalSince(selection)) < abs($1.date.timeIntervalSince(selection)) }
    }

    var body: some View {
        let theme = context.theme
        StatsCard("Requests over time", subtitle: "AI requests per \(context.data.trendUnitName), \(context.rangeCaption())", theme: theme) {
            if context.data.trend.contains(where: { $0.aiRequests > 0 }) {
                Chart {
                    ForEach(context.data.trend) { point in
                        BarMark(x: .value("Date", point.date, unit: unit), y: .value("Requests", point.aiRequests))
                            .foregroundStyle(theme.series(0))
                            .cornerRadius(3)
                    }
                    if let point = selectedPoint {
                        RuleMark(x: .value("Selected", point.date, unit: unit))
                            .foregroundStyle(theme.separator)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .annotation(position: .overlay, alignment: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                                StatsCallout(
                                    title: StatsFormat.pointCaption(point.date, range: context.data.range, unit: context.data.trendUnit),
                                    rows: [StatsCalloutRow(color: theme.series(0), label: "Requests", value: "\(point.aiRequests)")],
                                    theme: theme
                                )
                            }
                    }
                }
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
                .frame(height: 200)
                .accessibilityLabel("Bar chart of AI requests per \(context.data.trendUnitName)")
            } else {
                StatsEmptyNote(icon: "chart.bar", title: "No AI requests in this period", text: "Requests per day chart here once you start using AI.", theme: theme, minHeight: 180)
            }
        }
    }
}

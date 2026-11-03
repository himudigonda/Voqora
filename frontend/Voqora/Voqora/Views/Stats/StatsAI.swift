import SwiftUI

struct StatsAISection: View {
    let context: StatsContext

    private enum Lens: String, StatsLens {
        case trend
        case tools
        case providers
        case quality

        var title: String {
            switch self {
            case .trend: "Trend"
            case .tools: "Tools"
            case .providers: "Providers"
            case .quality: "Quality"
            }
        }

        var icon: String {
            switch self {
            case .trend: "chart.bar.fill"
            case .tools: "wand.and.stars"
            case .providers: "server.rack"
            case .quality: "checkmark.seal.fill"
            }
        }

        var subtitle: String {
            switch self {
            case .trend: "How many requests you sent over time"
            case .tools: ""
            case .providers: ""
            case .quality: "How often requests succeed and how long they take"
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
                        metrics: [.count("requests", "Requests") { $0.aiRequests }],
                        emptyText: "Summarize, translate, or ask about your books and requests chart here."
                    )
                case .tools:
                    StatsAIToolsCard(context: context)
                case .providers:
                    StatsAIProvidersCard(context: context)
                case .quality:
                    AdaptiveGrid(minColumnWidth: 280, maxColumns: 2) {
                        StatsAIReliabilityCard(context: context)
                        StatsAILatencyCard(context: context)
                    }
                }
            }
        }
    }

    private var metrics: [StatsHeroMetricModel] {
        let ai = context.current.ai
        return [
            context.metric(
                "Requests",
                value: ai.totalRequests.formatted(),
                footnote: "\(ai.requests.count) \(ai.requests.count == 1 ? "tool" : "tools") used",
                change: { Double($0.ai.totalRequests) }
            ),
            context.metric(
                "Success rate",
                value: context.current.aiSuccessRate.map { StatsFormat.percent($0) } ?? "—",
                footnote: "\(ai.totalFailures.formatted()) failed",
                change: { $0.aiSuccessRate ?? 0 }
            ),
            context.metric(
                "Average latency",
                value: ai.averageLatencyMs.map { StatsFormat.latency($0) } ?? "—",
                footnote: "Time to a finished answer",
                lowerIsBetter: true,
                change: { $0.ai.averageLatencyMs ?? 0 }
            ),
            context.metric(
                "Words processed",
                value: ai.wordsIn > 0 ? StatsFormat.count(ai.wordsIn) : "—",
                footnote: ai.wordsIn > 0 ? "\(StatsFormat.count(ai.wordsOut)) words written back" : "Not measured for live requests",
                change: { Double($0.ai.wordsIn) }
            ),
        ]
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
                StatsBarItem(label: StatsLabels.tool(entry.key), value: Double(entry.value), color: context.theme.ramp(context.tint, index == 0 ? 0 : 2))
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
            StatsDonutSlice(id: entry.key, label: StatsLabels.provider(entry.key), value: Double(entry.value), color: theme.ramp(context.tint, index))
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
                        Circle()
                            .stroke(theme.track, lineWidth: 10)
                        Circle()
                            .trim(from: 0, to: rate)
                            .stroke(rate >= 0.9 ? theme.base.success : (rate >= 0.7 ? theme.base.warning : theme.base.danger), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                            .rotationEffect(.degrees(-90))
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

import SwiftUI

struct StatsReadAloudSection: View {
    let context: StatsContext

    private enum Lens: String, StatsLens {
        case trend
        case voices
        case sources
        case engines
        case rhythm

        var title: String {
            switch self {
            case .trend: "Trend"
            case .voices: "Voices"
            case .sources: "Sources"
            case .engines: "Engines"
            case .rhythm: "Rhythm"
            }
        }

        var icon: String {
            switch self {
            case .trend: "chart.bar.fill"
            case .voices: "person.wave.2.fill"
            case .sources: "text.cursor"
            case .engines: "cpu"
            case .rhythm: "clock.fill"
            }
        }

        var subtitle: String {
            switch self {
            case .trend: "How much you had read aloud over time"
            case .voices: "Who reads to you, and how fast"
            case .sources: "Where the text came from, and which apps and agents sent it"
            case .engines: ""
            case .rhythm: "When you have text read aloud"
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
                            .minutes("time", "Time") { $0.speechMinutes },
                            .count("words", "Words") { $0.speechWords },
                            .count("reads", "Reads") { $0.speechCount },
                        ],
                        emptyText: "Select text and press your shortcut, and your reads chart here."
                    )
                case .voices:
                    AdaptiveGrid(minColumnWidth: 280, maxColumns: 2) {
                        StatsVoicesCard(context: context)
                        StatsSpeedCard(context: context)
                    }
                case .sources:
                    AdaptiveGrid(minColumnWidth: 280, maxColumns: 2) {
                        StatsSourcesCard(context: context)
                        StatsRelayCard(context: context)
                    }
                case .engines:
                    StatsEnginesLens(context: context)
                case .rhythm:
                    StatsRhythmLens(matrix: context.data.readAloudHourWeekday, tint: context.tint, noun: "have text read aloud")
                }
            }
        }
    }

    private func paperbackPages(_ words: Int) -> Int {
        Int((Double(words) / StatsFormat.wordsPerPaperbackPage).rounded())
    }

    private var metrics: [StatsHeroMetricModel] {
        let current = context.current
        return [
            context.metric(
                "Time read aloud",
                value: StatsFormat.duration(current.speechSeconds),
                footnote: "Audiobooks are counted separately",
                change: { $0.speechSeconds }
            ),
            context.metric(
                "Words spoken",
                value: StatsFormat.count(current.speechWords),
                footnote: current.speechWords > 0 ? "About \(paperbackPages(current.speechWords).formatted()) paperback pages" : "Select text, then press your shortcut",
                change: { Double($0.speechWords) }
            ),
            context.metric(
                "Selections read",
                value: current.speechCount.formatted(),
                footnote: current.speechCount > 0 ? "\(current.averageSelectionWords) words on average" : "Nothing read aloud yet",
                change: { Double($0.speechCount) }
            ),
            context.metric(
                "Time saved",
                value: StatsFormat.duration(current.listeningSavedSeconds),
                footnote: "vs reading at \(Int(StatsAssumptions.readingWordsPerMinute)) wpm",
                change: { $0.listeningSavedSeconds }
            ),
        ]
    }
}

struct StatsSourcesCard: View {
    let context: StatsContext

    private var slices: [StatsDonutSlice] {
        let theme = context.theme
        let sorted = context.current.speech.sources.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        let top = sorted.prefix(6)
        var result = top.enumerated().map { index, entry in
            StatsDonutSlice(id: entry.key, label: StatsLabels.source(entry.key), value: Double(entry.value), color: theme.ramp(context.tint, index))
        }
        let rest = sorted.dropFirst(6).reduce(0) { $0 + $1.value }
        if rest > 0 {
            result.append(StatsDonutSlice(id: "other", label: "Other", value: Double(rest), color: theme.other))
        }
        return result
    }

    var body: some View {
        StatsCard("Where text came from", subtitle: "Reads by source", theme: context.theme) {
            if slices.isEmpty {
                StatsEmptyNote(icon: "text.cursor", title: "No source data yet", text: "New reads are tagged by where they started: selection, clipboard, shortcuts, agents.", theme: context.theme)
            } else {
                StatsDonut(
                    slices: slices,
                    theme: context.theme,
                    unit: "reads",
                    summary: "Reads by source: " + slices.map { "\($0.label) \(Int($0.value))" }.joined(separator: ", ")
                )
            }
        }
    }
}

struct StatsVoicesCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    let context: StatsContext

    private var voices: [(id: String, usage: VoiceUsage)] {
        context.current.voices
            .sorted { ($0.value.uses, $0.value.seconds, $1.key) > ($1.value.uses, $1.value.seconds, $0.key) }
            .prefix(6)
            .map { (id: $0.key, usage: $0.value) }
    }

    var body: some View {
        let theme = context.theme
        let total = max(1, context.current.voices.values.reduce(0) { $0 + $1.uses })
        StatsCard("Top voices", subtitle: "Most used narrators", theme: theme) {
            if voices.isEmpty {
                StatsEmptyNote(icon: "person.wave.2", title: "No voices yet", text: "Speak some text to see your favorite narrators.", theme: theme)
            } else {
                VStack(spacing: 14) {
                    ForEach(Array(voices.enumerated()), id: \.element.id) { index, voice in
                        row(voice, rank: index, total: total)
                    }
                }
            }
        }
    }

    private func row(_ voice: (id: String, usage: VoiceUsage), rank: Int, total: Int) -> some View {
        let theme = context.theme
        let name = DashboardViewModel.voiceName(for: voice.id)
        let share = Double(voice.usage.uses) / Double(total)
        return HStack(spacing: 12) {
            VoiceInitialsAvatar(name: name, size: 38)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name)
                            .font(vm.font(.label))
                            .foregroundStyle(theme.text)
                            .lineLimit(1)
                        Text(StatsFormat.voiceSubtitle(voice.id))
                            .font(vm.font(.bodySmall))
                            .foregroundStyle(theme.tertiaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(voice.usage.uses.formatted()) \(voice.usage.uses == 1 ? "read" : "reads")")
                            .font(vm.font(.bodySmall).monospacedDigit())
                            .foregroundStyle(theme.secondaryText)
                        Text(voice.usage.seconds >= 1 ? StatsFormat.duration(voice.usage.seconds) : StatsFormat.percent(share))
                            .font(vm.font(.bodySmall).monospacedDigit())
                            .foregroundStyle(theme.tertiaryText)
                    }
                }
                StatsShareBar(fraction: share, tint: rank == 0 ? context.tint : theme.ramp(context.tint, 2), track: theme.track)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(StatsFormat.voiceSubtitle(voice.id)), \(StatsFormat.percent(share)), \(voice.usage.uses) reads")
    }
}

struct StatsSpeedCard: View {
    let context: StatsContext

    private var bins: [(label: String, value: Double)] {
        context.current.speeds
            .compactMap { key, count in Double(key).map { (speed: $0, count: count) } }
            .sorted { $0.speed < $1.speed }
            .map { (label: StatsFormat.speed($0.speed), value: Double($0.count)) }
    }

    var body: some View {
        let favorite = context.current.speeds.max { ($0.value, $1.key) < ($1.value, $0.key) }.flatMap { Double($0.key) }
        StatsCard("Listening speed", subtitle: "Reads by playback speed", theme: context.theme) {
            if bins.isEmpty {
                StatsEmptyNote(icon: "gauge.with.needle", title: "No speed data yet", text: "Your favorite playback speed shows up after a few reads.", theme: context.theme)
            } else {
                StatsHistogram(
                    bins: bins,
                    highlight: favorite.map { StatsFormat.speed($0) },
                    tint: context.tint,
                    theme: context.theme,
                    summary: "Reads by speed: " + bins.map { "\($0.label) \(Int($0.value))" }.joined(separator: ", ")
                )
                if let favorite {
                    StatsInsight(icon: "gauge.with.needle", text: "Favorite speed: \(StatsFormat.speed(favorite)).", theme: context.theme)
                }
            }
        }
    }
}

struct StatsRelayCard: View {
    let context: StatsContext

    private var items: [StatsBarItem] {
        context.current.speech.relayClients
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(6)
            .enumerated()
            .map { index, entry in StatsBarItem(label: entry.key, value: Double(entry.value), color: context.theme.ramp(context.tint, index == 0 ? 0 : 2)) }
    }

    var body: some View {
        StatsCard("Apps & agents", subtitle: "Requests sent to Voqora's local speech API", theme: context.theme) {
            if items.isEmpty {
                StatsEmptyNote(
                    icon: "app.connected.to.app.below.fill",
                    title: "No apps or agents yet",
                    text: "Tools like Claude Code or Cursor that read through Voqora appear here.",
                    theme: context.theme
                )
            } else {
                StatsHBars(
                    items: items,
                    theme: context.theme,
                    summary: "Requests by app: " + items.map { "\($0.label) \(Int($0.value))" }.joined(separator: ", ")
                )
            }
        }
    }
}

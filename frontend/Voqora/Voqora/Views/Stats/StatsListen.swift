import Charts
import SwiftUI

struct StatsListenSection: View {
    let context: StatsContext

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.card) {
            tiles
            AdaptiveGrid(minColumnWidth: 400) {
                StatsSourcesCard(context: context)
                StatsVoicesCard(context: context)
                StatsSpeedCard(context: context)
                StatsRelayCard(context: context)
                StatsBooksCard(context: context).statsSpan(2)
            }
        }
    }

    private func paperbackPages(_ words: Int) -> Int {
        Int((Double(words) / StatsFormat.wordsPerPaperbackPage).rounded())
    }

    private var tiles: some View {
        let data = context.data
        let current = data.current
        let theme = context.theme
        let favorite = current.speeds.max { ($0.value, $1.key) < ($1.value, $0.key) }
        return AdaptiveGrid(minColumnWidth: 200, spacing: Theme.Space.item, maxColumns: 4, balanced: true) {
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
                footnote: current.speechWords > 0 ? "About \(paperbackPages(current.speechWords).formatted()) paperback pages" : "Select text, then press your shortcut",
                tint: theme.series(1)
            )
            context.tile(
                "Selections read",
                value: current.speechCount.formatted(),
                icon: "text.cursor",
                change: data.change { Double($0.speechCount) },
                footnote: current.speechCount > 0 ? "\(current.averageSelectionWords) words on average" : "Nothing read aloud yet",
                tint: theme.series(2)
            )
            context.tile(
                "Favorite speed",
                value: favorite.flatMap { Double($0.key) }.map { StatsFormat.speed($0) } ?? "—",
                icon: "gauge.with.needle",
                footnote: favorite.map { "Used \($0.value.formatted()) \($0.value == 1 ? "time" : "times")" } ?? "Appears after your first read",
                tint: theme.series(3)
            )
        }
    }
}

struct StatsSourcesCard: View {
    let context: StatsContext

    private var slices: [StatsDonutSlice] {
        let theme = context.theme
        let sorted = context.current.speech.sources.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        let top = sorted.prefix(6)
        var result = top.enumerated().map { index, entry in
            StatsDonutSlice(id: entry.key, label: StatsLabels.source(entry.key), value: Double(entry.value), color: theme.series(index))
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
                StatsShareBar(fraction: share, tint: rank == 0 ? theme.accent : theme.muted, track: theme.track)
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
                    tint: context.theme.series(1),
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
            .map { index, entry in StatsBarItem(label: entry.key, value: Double(entry.value), color: index == 0 ? context.theme.series(0) : context.theme.series(0).opacity(0.55)) }
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
                                StatsShareBar(fraction: row.seconds / peak, tint: theme.series(0), track: theme.track)
                                    .frame(width: 70)
                                Text(StatsFormat.duration(row.seconds))
                                    .font(vm.font(.bodySmall).monospacedDigit())
                                    .foregroundStyle(theme.secondaryText)
                                    .fixedSize()
                                    .frame(minWidth: 62, alignment: .trailing)
                            }
                            StatsShareBar(fraction: info?.progress ?? 0, tint: theme.series(1), track: theme.track)
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

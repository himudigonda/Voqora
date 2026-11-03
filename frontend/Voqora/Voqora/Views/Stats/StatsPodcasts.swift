import SwiftUI

struct StatsPodcastsSection: View {
    let context: StatsContext

    private enum Lens: String, StatsLens {
        case trend

        var title: String {
            "Episodes over time"
        }

        var icon: String {
            "chart.bar.fill"
        }

        var subtitle: String {
            "Episodes rendered and scripts written"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            StatsProductHero(context: context, metrics: metrics)
            StatsLensCard(context: context) { (_: Lens) in
                StatsTrendLens(
                    context: context,
                    metrics: [
                        .count("episodes", "Episodes") { $0.podcastRenders },
                        .count("scripts", "Scripts") { $0.podcastScripts },
                    ],
                    emptyText: "Draft a script with AI, then render it with multiple voices."
                )
            }
        }
    }

    private var metrics: [StatsHeroMetricModel] {
        let creation = context.current.creation
        return [
            context.metric(
                "Episodes rendered",
                value: creation.podcastRenders.formatted(),
                footnote: "Multi-voice episodes",
                change: { Double($0.creation.podcastRenders) }
            ),
            context.metric(
                "Scripts written",
                value: creation.podcastScripts.formatted(),
                footnote: "Drafted with your AI provider",
                change: { Double($0.creation.podcastScripts) }
            ),
            context.metric(
                "Audio rendered",
                value: StatsFormat.duration(creation.podcastAudioSeconds),
                footnote: "Total episode length",
                change: { $0.creation.podcastAudioSeconds }
            ),
            context.metric(
                "Speakers per episode",
                value: creation.podcastRenders > 0 ? (Double(creation.podcastSpeakers) / Double(creation.podcastRenders)).formatted(.number.precision(.fractionLength(1))) : "—",
                footnote: "Average voices per episode"
            ),
        ]
    }
}

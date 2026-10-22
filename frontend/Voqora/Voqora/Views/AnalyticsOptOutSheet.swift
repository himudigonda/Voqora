import SwiftUI

enum AnalyticsOptOut {
    static let title = "Stop sharing anonymous usage analytics?"
    static let collected = "Voqora shares only counts, durations, the speech engine and built-in voice, and the names of features you use: " +
        "reading, dictation, AI tools, audiobooks, podcasts, imports, and exports, plus how long each took and whether it worked."
    static let neverCollected = "It never shares your text, documents, audio, file names, titles, app names, the names of apps that " +
        "send speech to Voqora, API keys, or the voices you recorded."
    static let footer = "Counts and durations only. Never your text, documents, audio, file names, app names, client names, " +
        "API keys, or voices you recorded."
    static let note = collected + " " + neverCollected
    static let contact: AttributedString = (try? AttributedString(
        markdown: "Questions or concerns? Reach out at [himudigonda.me](https://himudigonda.me) " +
            "or file an issue on [GitHub](https://github.com/himudigonda/Voqora/issues)."
    )) ?? AttributedString("Questions or concerns? Reach out at himudigonda.me or file an issue on GitHub.")
    static let confirmTitle = "Stop Analytics"

    static func confirm(defaults: UserDefaults = .standard, discardPending: () -> Void = { MetricsService.shared.flush() }) {
        defaults.set(false, forKey: MetricsService.analyticsEnabledKey)
        discardPending()
    }
}

struct AnalyticsOptOutSheet: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        VoqoraSheet(title: AnalyticsOptOut.title, width: 500) {
            VStack(alignment: .leading, spacing: Theme.Space.card) {
                Text(AnalyticsOptOut.note)
                    .voqoraFont(.body)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.surfaceContainerHighest, in: RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous))
                Text(AnalyticsOptOut.contact)
                    .voqoraFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .tint(theme.primary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Space.item) {
                    Spacer(minLength: 0)
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.voqoraText)
                        .keyboardShortcut(.defaultAction)
                    Button(AnalyticsOptOut.confirmTitle) {
                        AnalyticsOptOut.confirm()
                        dismiss()
                    }
                    .buttonStyle(.voqoraDangerFilled)
                }
            }
        }
        .voqoraTheme()
    }
}

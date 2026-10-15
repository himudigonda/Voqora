import SwiftUI

enum AnalyticsOptOut {
    static let title = "Stop sharing anonymous usage analytics?"
    static let note = "Analytics never include your text, documents, audio, or API keys. They only count app launches, " +
        "the voice, speed, and length of generated audio, audiobook pages and file type, listening time, exports, and update events."
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(AnalyticsOptOut.title)
                .font(vm.appFont(size: 17, weight: .bold))
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(AnalyticsOptOut.note)
                .font(vm.appFont(size: 14))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .voqoraSurface(.control, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium, style: .continuous))

            Text(AnalyticsOptOut.contact)
                .font(vm.appFont(size: 13))
                .foregroundStyle(Palette.textSecondary)
                .tint(vm.accentColor(scheme: colorScheme, contrast: colorSchemeContrast))
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack(spacing: 12) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.voqoraSecondary)
                    .keyboardShortcut(.defaultAction)
                Button {
                    AnalyticsOptOut.confirm()
                    dismiss()
                } label: {
                    Text(AnalyticsOptOut.confirmTitle)
                        .font(vm.font(.button))
                        .padding(.horizontal, DesignTokens.Spacing.md)
                        .padding(.vertical, DesignTokens.Spacing.xs + 2)
                        .background(Palette.danger, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(28)
        .frame(width: 460)
        .voqoraSurface(.floating, in: Rectangle())
    }
}

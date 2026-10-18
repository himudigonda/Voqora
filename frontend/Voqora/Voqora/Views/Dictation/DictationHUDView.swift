import SwiftUI

struct DictationHUDView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var dictation: DictationController
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var accentColor: Color {
        vm.accentColor(scheme: colorScheme, contrast: colorSchemeContrast)
    }

    var body: some View {
        content
            .padding(DesignTokens.Layout.cardInset)
            .frame(width: DictationHUDLayout.cardWidth, alignment: .leading)
            .voqoraSurface(.floating, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xLarge, style: .continuous))
            .padding(DictationHUDLayout.shadowInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(DesignTokens.Animation.quick, value: dictation.phase)
    }

    @ViewBuilder
    private var content: some View {
        if dictation.phase == .idle, let issue = dictation.issue {
            DictationMessageRow(
                systemImage: "exclamationmark.triangle.fill",
                tint: Palette.warning,
                message: issue.message,
                settingsPane: issue.settingsPane
            )
        } else if dictation.phase == .idle, let outcome = dictation.outcome {
            DictationMessageRow(
                systemImage: "checkmark.circle.fill",
                tint: Palette.success,
                message: outcome.message,
                settingsPane: outcome.settingsPane
            )
        } else {
            liveContent
        }
    }

    private var liveContent: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: dictation.phase == .listening ? "mic.fill" : "waveform")
                    .font(vm.font(.button))
                    .foregroundStyle(accentColor)
                Text(statusTitle)
                    .font(vm.font(.button))
                    .foregroundStyle(Palette.textPrimary)
                Spacer(minLength: 0)
                DictationLevelMeter(level: dictation.phase == .listening ? dictation.level : 0, color: accentColor)
            }
            Text(dictation.liveTranscript.isEmpty ? placeholder : dictation.liveTranscript)
                .font(vm.appFont(size: 15, weight: .medium))
                .foregroundStyle(dictation.liveTranscript.isEmpty ? Palette.textTertiary : Palette.textPrimary)
                .lineLimit(3)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusTitle: String {
        switch dictation.phase {
        case .idle, .preparing: "Getting ready…"
        case .listening: "Listening"
        case .finishing: "Finishing…"
        case .inserting: "Inserting…"
        }
    }

    private var placeholder: String {
        "Start speaking. Press \(DictationController.shortcutLabel) when you're done."
    }
}

struct DictationMessageRow: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var dictation: DictationController
    let systemImage: String
    let tint: Color
    let message: String
    let settingsPane: PrivacySettingsPane?

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            Image(systemName: systemImage)
                .font(vm.font(.button))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Text(message)
                    .font(vm.font(.rowTitle))
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let settingsPane {
                    Button("Open System Settings") {
                        dictation.openSystemSettings(settingsPane)
                    }
                    .buttonStyle(.voqoraSecondary)
                }
            }
            Spacer(minLength: 0)
            Button {
                dictation.dismissMessage()
            } label: {
                Image(systemName: "xmark")
                    .font(vm.font(.caption))
                    .foregroundStyle(Palette.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
            .help("Dismiss")
        }
    }
}

struct DictationLevelMeter: View {
    private static let barCount = 12

    let level: Float
    let color: Color

    var body: some View {
        let lit = Int((Double(min(1, max(0, level))) * Double(Self.barCount)).rounded())
        HStack(alignment: .center, spacing: 2) {
            ForEach(0 ..< Self.barCount, id: \.self) { index in
                Capsule()
                    .fill(index < lit ? color : Palette.separator)
                    .frame(width: 3, height: 6 + CGFloat(index % 4) * 3)
            }
        }
        .frame(height: 16)
        .animation(DesignTokens.Animation.quick, value: lit)
        .accessibilityHidden(true)
    }
}

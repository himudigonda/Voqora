import SwiftUI

struct DictationHUDView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var dictation: DictationController

    private var theme: Theme {
        vm.theme
    }

    var body: some View {
        content
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(width: DictationHUDLayout.cardWidth, alignment: .leading)
            .voqoraCardBackground(.elevated, radius: Theme.Shape.xl)
            .padding(DictationHUDLayout.shadowInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(Theme.Motion.selection, value: dictation.phase)
            .voqoraTheme()
    }

    @ViewBuilder
    private var content: some View {
        if dictation.phase == .idle, let issue = dictation.issue {
            DictationMessageRow(
                systemImage: "exclamationmark.triangle.fill",
                tint: theme.warning,
                message: issue.message,
                settingsPane: issue.settingsPane
            )
        } else if dictation.phase == .idle, let message = dictation.outcomeMessage {
            DictationMessageRow(
                systemImage: dictation.tidyFailure == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                tint: dictation.tidyFailure == nil ? theme.success : theme.warning,
                message: message,
                settingsPane: dictation.outcome?.settingsPane
            )
        } else {
            liveContent
        }
    }

    private var liveContent: some View {
        HStack(alignment: .center, spacing: Theme.Space.item + 4) {
            DictationLiveDot(level: dictation.phase == .listening ? dictation.level : 0, color: theme.primary)
            VStack(alignment: .leading, spacing: 4) {
                Text(DictationStateLabel.title(for: dictation.phase, isTidying: dictation.isTidying))
                    .font(vm.font(.labelSmall))
                    .foregroundStyle(theme.onSurfaceVariant)
                if dictation.liveTranscript.isEmpty, let model = DictationPreferences(defaults: .standard).engine.localModel {
                    DictationLocalPlaceholder(phase: dictation.phase, models: .store(for: model))
                } else {
                    Text(dictation.liveTranscript.isEmpty ? placeholder(isWarmingUp: false) : dictation.liveTranscript)
                        .font(vm.font(.body))
                        .foregroundStyle(dictation.liveTranscript.isEmpty ? theme.onSurfaceMuted : theme.onSurface)
                        .lineLimit(3)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            DictationLevelMeter(level: dictation.phase == .listening ? dictation.level : 0, color: theme.primary, track: theme.outlineVariant)
        }
        .accessibilityElement(children: .combine)
    }

    private func placeholder(isWarmingUp: Bool) -> String {
        DictationStateLabel.placeholder(for: dictation.phase, shortcut: DictationController.shortcutLabel, isWarmingUp: isWarmingUp)
    }
}

private struct DictationLocalPlaceholder: View {
    @EnvironmentObject var vm: DashboardViewModel
    let phase: DictationPhase
    @ObservedObject var models: LocalSpeechModelStore

    var body: some View {
        Text(DictationStateLabel.placeholder(for: phase, shortcut: DictationController.shortcutLabel, isWarmingUp: models.isPreparing))
            .font(vm.font(.body))
            .foregroundStyle(vm.theme.onSurfaceMuted)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        HStack(alignment: .top, spacing: Theme.Space.item + 4) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.item) {
                Text(message)
                    .font(vm.font(.body))
                    .foregroundStyle(vm.theme.onSurface)
                    .fixedSize(horizontal: false, vertical: true)
                if let settingsPane {
                    Button("Open System Settings") {
                        dictation.openSystemSettings(settingsPane)
                    }
                    .buttonStyle(.voqoraTonal)
                }
            }
            Spacer(minLength: 0)
            Button {
                dictation.dismissMessage()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(vm.theme.onSurfaceVariant)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
            .help("Dismiss")
        }
    }
}

struct DictationLiveDot: View {
    let level: Float
    let color: Color

    var body: some View {
        let clamped = CGFloat(min(1, max(0, level)))
        ZStack {
            Circle()
                .fill(color.opacity(0.18))
                .frame(width: 36, height: 36)
                .scaleEffect(0.7 + clamped * 0.3)
            Circle()
                .fill(color)
                .frame(width: 14, height: 14)
                .scaleEffect(1 + clamped * 0.35)
        }
        .frame(width: 36, height: 36)
        .animation(Theme.Motion.hover, value: clamped)
        .accessibilityHidden(true)
    }
}

struct DictationLevelMeter: View {
    private static let barCount = 10

    let level: Float
    let color: Color
    let track: Color

    var body: some View {
        let lit = Int((Double(min(1, max(0, level))) * Double(Self.barCount)).rounded())
        HStack(alignment: .center, spacing: 2) {
            ForEach(0 ..< Self.barCount, id: \.self) { index in
                Capsule()
                    .fill(index < lit ? color : track)
                    .frame(width: 3, height: 6 + CGFloat(index % 4) * 3)
            }
        }
        .frame(height: 16)
        .animation(Theme.Motion.hover, value: lit)
        .accessibilityHidden(true)
    }
}

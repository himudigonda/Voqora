import SwiftUI

struct PauseLengthControl: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    @Binding var value: Double
    let accentColor: Color
    var compact = false
    var onCommit: ((Double) -> Void)?

    var body: some View {
        if compact {
            compactBody
        } else {
            SettingsRowShell(
                title: "Pause Length",
                detail: "How long Voqora pauses between sentences and paragraphs.",
                systemImage: "pause.circle"
            ) {
                HStack(spacing: 12) {
                    slider.frame(minWidth: 140, maxWidth: 260)
                    valueBadge
                }
            }
        }
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Pause Length", systemImage: "pause.circle")
                    .font(vm.font(.labelSmall))
                    .foregroundStyle(theme.onSurfaceVariant)
                Spacer()
                valueBadge
            }
            slider
        }
    }

    private var slider: some View {
        Slider(value: $value, in: PauseScale.range, step: PauseScale.step, onEditingChanged: { editing in
            if !editing {
                onCommit?(PauseScale.clamped(value))
            }
        })
        .tint(accentColor)
        .accessibilityLabel("Pause Length")
        .accessibilityValue("\(PauseScale.label(value)), \(PauseScale.description(value))")
    }

    private var valueBadge: some View {
        Text(PauseScale.label(value))
            .font(vm.font(.label))
            .monospacedDigit()
            .foregroundStyle(theme.onPrimaryContainer)
            .frame(minWidth: 44)
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .background(theme.primaryContainer.opacity(0.65), in: Capsule())
    }
}

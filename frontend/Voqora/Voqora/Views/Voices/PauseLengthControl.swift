import SwiftUI

struct PauseLengthControl: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Binding var value: Double
    let accentColor: Color
    var compact = false
    var onCommit: ((Double) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 12) {
            HStack {
                Label("Pause Length", systemImage: "pause.circle")
                    .font(compact ? vm.appFont(size: 11) : vm.font(.rowTitle))
                    .foregroundStyle(compact ? Palette.textSecondary : Palette.textPrimary)
                Spacer()
                Text(PauseScale.label(value))
                    .font(vm.appFont(size: compact ? 12 : 14, weight: .bold).monospaced())
                    .foregroundStyle(accentColor)
            }
            Slider(value: $value, in: PauseScale.range, step: PauseScale.step, onEditingChanged: { editing in
                if !editing {
                    onCommit?(PauseScale.clamped(value))
                }
            })
            .tint(accentColor)
            .accessibilityLabel("Pause Length")
            .accessibilityValue("\(PauseScale.label(value)), \(PauseScale.description(value))")
            if !compact {
                Text("How long Voqora pauses between sentences and paragraphs.")
                    .font(vm.font(.rowSubtitle))
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }
}

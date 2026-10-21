import SwiftUI

struct VoqoraSwitchStyle: ToggleStyle {
    @Environment(\.voqoraTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            track(isOn: configuration.isOn)
        }
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
        .accessibilityElement(children: .combine)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { configuration.isOn.toggle() }
        .opacity(isEnabled ? 1 : 0.5)
    }

    private func track(isOn: Bool) -> some View {
        Capsule()
            .fill(isOn ? theme.primary : theme.surfaceContainerHighest)
            .overlay(Capsule().strokeBorder(isOn ? theme.primary : theme.outline, lineWidth: 2))
            .frame(width: 52, height: 32)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(isOn ? theme.onPrimary : theme.outline)
                    .frame(width: isOn ? 24 : 16, height: isOn ? 24 : 16)
                    .padding(.horizontal, isOn ? 4 : 8)
            }
            .animation(Theme.Motion.selection, value: isOn)
            .contentShape(Capsule())
    }
}

extension ToggleStyle where Self == VoqoraSwitchStyle {
    static var voqoraSwitch: VoqoraSwitchStyle {
        VoqoraSwitchStyle()
    }
}

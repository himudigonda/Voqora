import SwiftUI

struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var content: Content

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(vm.font(.titleSmall))
                .foregroundStyle(theme.primary)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
            ListGroup {
                content
            }
            if let footer {
                Text(footer)
                    .font(vm.font(.bodySmall))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SettingsRowShell<Control: View>: View {
    let title: String
    var detail: String?
    var systemImage: String?
    var isInteractive = false
    @ViewBuilder var control: Control

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 16) {
            if let systemImage {
                ListItemIcon(systemImage: systemImage)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(vm.font(.body))
                    .foregroundStyle(theme.onSurface)
                if let detail {
                    Text(detail)
                        .font(vm.font(.bodySmall))
                        .foregroundStyle(theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: detail == nil ? 56 : 64)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isInteractive && isHovering ? theme.surfaceContainerHigh : theme.surfaceContainer,
            in: RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous))
        .animation(Theme.Motion.hover, value: isHovering)
        .onHover { isHovering = $0 }
    }
}

struct SettingsSwitchRow: View {
    let title: String
    var detail: String?
    var systemImage: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingsRowShell(title: title, detail: detail, systemImage: systemImage) {
            Toggle(isOn: $isOn) { EmptyView() }
                .toggleStyle(.voqoraSwitch)
                .accessibilityLabel(title)
        }
    }
}

typealias SettingsToggleRow = SettingsSwitchRow

struct SettingsPickerRow<Options: View>: View {
    let title: String
    var detail: String?
    var systemImage: String?
    let valueLabel: String
    @ViewBuilder var options: Options

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        SettingsRowShell(title: title, detail: detail, systemImage: systemImage) {
            Menu {
                options
            } label: {
                HStack(spacing: 6) {
                    Text(valueLabel)
                        .font(vm.font(.label))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(theme.onPrimaryContainer)
                .padding(.horizontal, 14)
                .frame(minHeight: 32)
                .background(theme.primaryContainer.opacity(0.65), in: Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(title)
            .accessibilityValue(valueLabel)
        }
    }
}

struct SettingsSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let valueLabel: String
    var detail: String?

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        SettingsRowShell(title: title, detail: detail) {
            HStack(spacing: 12) {
                Slider(value: $value, in: range, step: step)
                    .tint(theme.primary)
                    .frame(minWidth: 140, maxWidth: 260)
                    .accessibilityLabel(title)
                    .accessibilityValue(valueLabel)
                Text(valueLabel)
                    .font(vm.font(.label))
                    .monospacedDigit()
                    .foregroundStyle(theme.onPrimaryContainer)
                    .frame(minWidth: 44)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 28)
                    .background(theme.primaryContainer.opacity(0.65), in: Capsule())
            }
        }
    }
}

struct SettingsNavigationRow: View {
    let title: String
    var detail: String?
    var systemImage: String?
    var valueLabel: String?
    let action: () -> Void

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        Button(action: action) {
            SettingsRowShell(title: title, detail: detail, systemImage: systemImage, isInteractive: true) {
                HStack(spacing: 8) {
                    if let valueLabel {
                        Text(valueLabel)
                            .font(vm.font(.body))
                            .foregroundStyle(theme.onSurfaceVariant)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.onSurfaceMuted)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct SettingsStepperRow: View {
    let title: String
    var detail: String?
    var systemImage: String?
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    var valueLabel: String?

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        SettingsRowShell(title: title, detail: detail, systemImage: systemImage) {
            HStack(spacing: 8) {
                Button {
                    value = max(range.lowerBound, value - step)
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.voqoraIconTonal)
                .disabled(value <= range.lowerBound)
                .accessibilityLabel("Decrease \(title)")
                Text(valueLabel ?? "\(value)")
                    .font(vm.font(.label))
                    .monospacedDigit()
                    .foregroundStyle(theme.onSurface)
                    .frame(minWidth: 48)
                Button {
                    value = min(range.upperBound, value + step)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.voqoraIconTonal)
                .disabled(value >= range.upperBound)
                .accessibilityLabel("Increase \(title)")
            }
        }
    }
}

struct SettingsButtonRow: View {
    let title: String
    var detail: String?
    var systemImage: String?
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        SettingsRowShell(title: title, detail: detail, systemImage: systemImage) {
            Button(buttonTitle, action: action)
                .buttonStyle(.voqoraTonal)
        }
    }
}

import SwiftUI

struct SettingsPage<Accessory: View, Content: View>: View {
    let tab: SettingsTab
    let accessory: Accessory
    let content: Content

    init(
        _ tab: SettingsTab,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.tab = tab
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        PageScaffold(title: tab.title, subtitle: tab.summary, accessory: { accessory }) {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                content
            }
        }
    }
}

extension SettingsPage where Accessory == EmptyView {
    init(_ tab: SettingsTab, @ViewBuilder content: () -> Content) {
        self.init(tab, accessory: { EmptyView() }, content: content)
    }
}

private struct FieldChrome: ViewModifier {
    var width: CGFloat?

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(vm.font(.body))
            .foregroundStyle(theme.onSurface)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .frame(width: width)
            .background(theme.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: Theme.Shape.sm, style: .continuous))
    }
}

extension View {
    func settingsField(width: CGFloat? = nil) -> some View {
        modifier(FieldChrome(width: width))
    }
}

struct TonalMenu<Options: View>: View {
    let valueLabel: String
    var title: String?
    @ViewBuilder var options: Options

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
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
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(title ?? valueLabel)
        .accessibilityValue(valueLabel)
    }
}

struct SettingsSegmentedRow<Value: Hashable>: View {
    let title: String
    var detail: String?
    var systemImage: String?
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String

    var body: some View {
        SettingsRowShell(title: title, detail: detail, systemImage: systemImage) {
            SegmentedTabs(selection: $selection, options: options, title: label, systemImage: nil)
        }
    }
}

struct SettingsValueRow<Control: View>: View {
    let title: String
    var detail: String?
    var systemImage: String?
    @ViewBuilder var control: Control

    var body: some View {
        SettingsRowShell(title: title, detail: detail, systemImage: systemImage) {
            control
        }
    }
}

struct SettingsVoiceCardRow: View {
    let title: String
    @Binding var voiceID: String

    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        VoicePickerCard(title: title, voiceID: $voiceID)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surfaceContainer, in: RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous))
    }
}

struct SettingsTextValue: View {
    let text: String

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        Text(text)
            .font(vm.font(.body))
            .foregroundStyle(theme.onSurfaceVariant)
            .lineLimit(1)
    }
}

struct SettingsNoticeRow: View {
    let text: String
    var kind: StatusChipKind = .info
    var systemImage: String?

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage ?? defaultImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(vm.font(.bodySmall))
                .foregroundStyle(kind == .neutral || kind == .info ? theme.onSurfaceVariant : tint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceContainer, in: RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch kind {
        case .neutral, .info: theme.onSurfaceVariant
        case .success: theme.success
        case .warning: theme.warning
        case .danger: theme.danger
        }
    }

    private var defaultImage: String {
        switch kind {
        case .neutral, .info: "info.circle"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .danger: "exclamationmark.octagon.fill"
        }
    }
}

enum VoqoraDangerKind {
    case outlined
    case filled
}

struct VoqoraDangerButtonStyle: ButtonStyle {
    let kind: VoqoraDangerKind

    func makeBody(configuration: Configuration) -> some View {
        DangerButtonBody(kind: kind, configuration: configuration)
    }
}

private struct DangerButtonBody: View {
    let kind: VoqoraDangerKind
    let configuration: ButtonStyle.Configuration

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(vm.font(.label))
            .foregroundStyle(kind == .filled ? Color.white : theme.danger)
            .padding(.horizontal, 20)
            .frame(minHeight: 36)
            .background(kind == .filled ? theme.danger : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(kind == .outlined ? theme.danger.opacity(0.7) : .clear, lineWidth: 1))
            .overlay(Capsule().fill(theme.danger.opacity(stateOpacity)).allowsHitTesting(false))
            .opacity(isEnabled ? 1 : 0.38)
            .contentShape(Capsule())
            .animation(Theme.Motion.hover, value: isHovering)
            .onHover { isHovering = $0 }
    }

    private var stateOpacity: Double {
        if configuration.isPressed {
            return 0.16
        }
        return isHovering && isEnabled ? 0.08 : 0
    }
}

extension ButtonStyle where Self == VoqoraDangerButtonStyle {
    static var voqoraDangerOutlined: VoqoraDangerButtonStyle {
        VoqoraDangerButtonStyle(kind: .outlined)
    }

    static var voqoraDangerFilled: VoqoraDangerButtonStyle {
        VoqoraDangerButtonStyle(kind: .filled)
    }
}

import SwiftUI

struct StatsCard<Content: View, Accessory: View>: View {
    @EnvironmentObject var vm: DashboardViewModel
    let title: String
    let subtitle: String?
    let icon: String
    let theme: StatsTheme
    let accessory: Accessory
    let content: Content

    init(
        _ title: String,
        subtitle: String? = nil,
        icon: String,
        theme: StatsTheme,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.theme = theme
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(vm.font(.sectionTitle))
                        .foregroundStyle(Palette.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(vm.font(.rowSubtitle))
                            .foregroundStyle(Palette.textTertiary)
                    }
                }
                Spacer(minLength: 8)
                accessory
            }
            content
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .voqoraSurface(.raised, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xLarge, style: .continuous))
    }
}

struct StatsHeroTile: View {
    @EnvironmentObject var vm: DashboardViewModel
    let title: String
    let value: String
    let icon: String
    let change: Double?
    let comparison: String?
    let footnote: String
    let theme: StatsTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 32, height: 32)
                    .background(theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Spacer()
                if let label = StatsFormat.change(change) {
                    StatsChangeChip(label: label, change: change ?? 0)
                        .help(comparison ?? "")
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(vm.appFont(size: 30, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.textPrimary)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(title)
                    .font(vm.appFont(size: 13, weight: .medium))
                    .foregroundStyle(Palette.textSecondary)
            }
            Text(footnote)
                .font(vm.font(.rowSubtitle))
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .voqoraSurface(.raised, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xLarge, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct StatsChangeChip: View {
    @EnvironmentObject var vm: DashboardViewModel
    let label: String
    let change: Double

    private var tint: Color {
        if abs(change) < 0.005 {
            return Palette.textTertiary
        }
        return change > 0 ? Palette.success : Palette.warning
    }

    var body: some View {
        HStack(spacing: 3) {
            if abs(change) >= 0.005 {
                Image(systemName: change > 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 9, weight: .bold))
            }
            Text(label)
                .font(vm.appFont(size: 11, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

struct StatsMiniStat: View {
    @EnvironmentObject var vm: DashboardViewModel
    let label: String
    let value: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(vm.appFont(size: 19, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(vm.appFont(size: 12, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
            if let detail {
                Text(detail)
                    .font(vm.font(.caption))
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct StatsShareBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.controlFill)
                Capsule()
                    .fill(tint)
                    .frame(width: max(6, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

struct StatsInsight: View {
    @EnvironmentObject var vm: DashboardViewModel
    let icon: String
    let text: String
    let theme: StatsTheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.accent)
            Text(text)
                .font(vm.appFont(size: 12))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct StatsEmptyNote: View {
    @EnvironmentObject var vm: DashboardViewModel
    let text: String

    var body: some View {
        Text(text)
            .font(vm.appFont(size: 12))
            .foregroundStyle(Palette.textTertiary)
            .frame(maxWidth: .infinity, minHeight: 80)
            .multilineTextAlignment(.center)
    }
}

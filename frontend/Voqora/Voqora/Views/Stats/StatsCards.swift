import SwiftUI

nonisolated struct StatsSpanKey: LayoutValueKey {
    static let defaultValue = 1
}

extension View {
    func statsSpan(_ columns: Int) -> some View {
        layoutValue(key: StatsSpanKey.self, value: columns)
    }
}

struct AdaptiveGrid: Layout {
    var minColumnWidth: CGFloat = 380
    var spacing: CGFloat = Theme.Space.card
    var maxColumns = 6
    var balanced = false

    private struct Arrangement {
        var frames: [CGRect] = []
        var size: CGSize = .zero
    }

    private func columns(for width: CGFloat, count: Int) -> Int {
        var columns = max(1, min(maxColumns, Int((width + spacing) / (minColumnWidth + spacing))))
        if balanced {
            while columns > 2, count % columns != 0 {
                columns -= 1
            }
        }
        return columns
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> Arrangement {
        let count = columns(for: width, count: subviews.count)
        let columnWidth = (width - spacing * CGFloat(count - 1)) / CGFloat(count)
        var result = Arrangement()
        var rows: [[(index: Int, span: Int)]] = [[]]
        var used = 0
        for (index, subview) in subviews.enumerated() {
            let span = max(1, min(count, subview[StatsSpanKey.self]))
            if used + span > count {
                rows.append([])
                used = 0
            }
            rows[rows.count - 1].append((index, span))
            used += span
        }
        var y: CGFloat = 0
        result.frames = Array(repeating: .zero, count: subviews.count)
        for row in rows where !row.isEmpty {
            let sizes = row.map { item -> CGSize in
                let itemWidth = columnWidth * CGFloat(item.span) + spacing * CGFloat(item.span - 1)
                return subviews[item.index].sizeThatFits(ProposedViewSize(width: itemWidth, height: nil))
            }
            let rowHeight = sizes.map(\.height).max() ?? 0
            var x: CGFloat = 0
            for item in row {
                let itemWidth = columnWidth * CGFloat(item.span) + spacing * CGFloat(item.span - 1)
                result.frames[item.index] = CGRect(x: x, y: y, width: itemWidth, height: rowHeight)
                x += itemWidth + spacing
            }
            y += rowHeight + spacing
        }
        result.size = CGSize(width: width, height: max(0, y - spacing))
        return result
    }

    private func resolvedWidth(_ proposal: ProposedViewSize) -> CGFloat {
        guard let width = proposal.width, width.isFinite else { return minColumnWidth * 2 + spacing }
        return max(width, 1)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        arrange(width: resolvedWidth(proposal), subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let arrangement = arrange(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let frame = arrangement.frames[index]
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }
}

struct StatsFlowLayout: Layout {
    var spacing: CGFloat = 14
    var lineSpacing: CGFloat = 6

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (frames, CGSize(width: maxX, height: y + lineHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let arrangement = arrange(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let frame = arrangement.frames[index]
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading, proposal: .unspecified)
        }
    }
}

struct StatsCard<Content: View, Accessory: View>: View {
    @EnvironmentObject var vm: DashboardViewModel
    let title: String
    let subtitle: String?
    let theme: StatsTheme
    let accessory: Accessory
    let content: Content

    init(
        _ title: String,
        subtitle: String? = nil,
        theme: StatsTheme,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.theme = theme
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.card) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.item) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(vm.font(.titleSmall))
                        .foregroundStyle(theme.text)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle)
                            .font(vm.font(.bodySmall))
                            .foregroundStyle(theme.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Theme.Space.item)
                accessory
            }
            content
        }
        .padding(Theme.Space.card)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .voqoraCardBackground()
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
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            HStack(alignment: .top) {
                ListItemIcon(systemImage: icon, tint: tint)
                Spacer(minLength: 4)
                if let label = StatsFormat.change(change) {
                    StatsChangeChip(label: label, change: change ?? 0, theme: theme)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(vm.font(.headline).monospacedDigit())
                    .foregroundStyle(theme.text)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(title)
                    .font(vm.font(.label))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 2) {
                if change != nil, let comparison {
                    Text(comparison)
                        .font(vm.font(.labelSmall))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Text(footnote)
                    .font(vm.font(.bodySmall))
                    .foregroundStyle(theme.tertiaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Space.item + 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.base.surfaceContainer, in: RoundedRectangle(cornerRadius: Theme.Shape.lg, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct StatsChangeChip: View {
    @EnvironmentObject var vm: DashboardViewModel
    let label: String
    let change: Double
    let theme: StatsTheme

    private var tint: Color {
        if abs(change) < 0.005 {
            return theme.tertiaryText
        }
        return change > 0 ? theme.base.success : theme.base.warning
    }

    var body: some View {
        HStack(spacing: 3) {
            if abs(change) >= 0.005 {
                Image(systemName: change > 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 10, weight: .bold))
            }
            Text(label)
                .font(vm.font(.labelSmall).monospacedDigit())
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .frame(minHeight: 22)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

struct StatsMiniStat: View {
    @EnvironmentObject var vm: DashboardViewModel
    let label: String
    let value: String
    let detail: String?
    let theme: StatsTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(vm.font(.title).monospacedDigit())
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(vm.font(.label))
                .foregroundStyle(theme.secondaryText)
            if let detail {
                Text(detail)
                    .font(vm.font(.bodySmall))
                    .foregroundStyle(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct StatsShareBar: View {
    let fraction: Double
    let tint: Color
    let track: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule()
                    .fill(tint)
                    .frame(width: max(6, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 8)
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
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.accent)
            Text(text)
                .font(vm.font(.bodySmall))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct StatsEmptyNote: View {
    @EnvironmentObject var vm: DashboardViewModel
    let icon: String
    let title: String
    let text: String
    let theme: StatsTheme
    var minHeight: CGFloat = 140

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(theme.base.onPrimaryContainer)
                .frame(width: 40, height: 40)
                .background(theme.base.primaryContainer.opacity(0.65), in: Circle())
                .accessibilityHidden(true)
            Text(title)
                .font(vm.font(.label))
                .foregroundStyle(theme.secondaryText)
            Text(text)
                .font(vm.font(.bodySmall))
                .foregroundStyle(theme.tertiaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: minHeight)
        .accessibilityElement(children: .combine)
    }
}

struct StatsLegendItem: Identifiable, Equatable {
    let id: String
    let label: String
    let color: Color
}

struct StatsLegend: View {
    @EnvironmentObject var vm: DashboardViewModel
    let items: [StatsLegendItem]
    let theme: StatsTheme

    var body: some View {
        StatsFlowLayout(spacing: 14, lineSpacing: 4) {
            ForEach(items) { item in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(item.color).frame(width: 10, height: 10)
                    Text(item.label)
                        .font(vm.font(.bodySmall))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
                .fixedSize()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Legend: " + items.map(\.label).joined(separator: ", "))
    }
}

struct StatsHelpButton<Content: View>: View {
    let label: String
    let theme: StatsTheme
    let content: Content
    @State private var showing = false

    init(_ label: String, theme: StatsTheme, @ViewBuilder content: () -> Content) {
        self.label = label
        self.theme = theme
        self.content = content()
    }

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            content
                .padding(Theme.Space.card)
                .frame(width: 340, alignment: .leading)
        }
    }
}

struct StatsCalloutRow {
    let color: Color
    let label: String
    let value: String
}

struct StatsCallout: View {
    @EnvironmentObject var vm: DashboardViewModel
    let title: String
    let rows: [StatsCalloutRow]
    let theme: StatsTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(vm.font(.labelSmall))
                .foregroundStyle(theme.text)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    Circle().fill(row.color).frame(width: 7, height: 7)
                    Text(row.label)
                    Spacer(minLength: 14)
                    Text(row.value).monospacedDigit()
                }
                .font(vm.font(.labelSmall))
                .foregroundStyle(theme.secondaryText)
            }
        }
        .padding(10)
        .frame(minWidth: 150)
        .background(theme.base.surfaceContainerHighest, in: RoundedRectangle(cornerRadius: Theme.Shape.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Shape.sm, style: .continuous).strokeBorder(theme.separator.opacity(0.6), lineWidth: 1))
        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
    }
}

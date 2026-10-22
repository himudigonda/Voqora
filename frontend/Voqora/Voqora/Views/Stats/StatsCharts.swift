import Charts
import SwiftUI

struct WidthDrivenHeight: Layout {
    let height: (CGFloat) -> CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews _: Subviews, cache _: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 400
        return CGSize(width: width, height: height(width))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

struct StatsDonutSlice: Identifiable, Equatable {
    let id: String
    let label: String
    let value: Double
    let color: Color
}

struct StatsDonut: View {
    @EnvironmentObject var vm: DashboardViewModel
    let slices: [StatsDonutSlice]
    let theme: StatsTheme
    let unit: String
    let summary: String
    @State private var selectedAngle: Double?

    private var total: Double {
        slices.reduce(0) { $0 + $1.value }
    }

    private var selected: StatsDonutSlice? {
        guard let selectedAngle else { return nil }
        var running = 0.0
        for slice in slices {
            running += slice.value
            if selectedAngle <= running {
                return slice
            }
        }
        return nil
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Theme.Space.card) {
                donut
                legend.frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: Theme.Space.item) {
                donut.frame(maxWidth: .infinity)
                legend
            }
        }
    }

    private var donut: some View {
        Chart(slices) { slice in
            SectorMark(angle: .value("Count", slice.value), innerRadius: .ratio(0.64), angularInset: 1.5)
                .cornerRadius(4)
                .foregroundStyle(slice.color)
                .opacity(selected == nil || selected?.id == slice.id ? 1 : 0.4)
        }
        .chartAngleSelection(value: $selectedAngle)
        .chartLegend(.hidden)
        .chartBackground { proxy in
            GeometryReader { geometry in
                if let frame = proxy.plotFrame {
                    let rect = geometry[frame]
                    VStack(spacing: 1) {
                        Text(selected.map { Int($0.value).formatted() } ?? Int(total).formatted())
                            .font(vm.font(.title).monospacedDigit())
                            .foregroundStyle(theme.text)
                        Text(selected?.label ?? unit)
                            .font(vm.font(.labelSmall))
                            .foregroundStyle(theme.tertiaryText)
                            .lineLimit(1)
                    }
                    .frame(width: rect.width * 0.56)
                    .position(x: rect.midX, y: rect.midY)
                }
            }
        }
        .frame(width: 168, height: 168)
        .accessibilityLabel(summary)
    }

    private var legend: some View {
        VStack(spacing: 8) {
            ForEach(slices) { slice in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(slice.color).frame(width: 10, height: 10)
                    Text(slice.label)
                        .font(vm.font(.label))
                        .foregroundStyle(selected == nil || selected?.id == slice.id ? theme.text : theme.tertiaryText)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Int(slice.value).formatted())
                        .font(vm.font(.bodySmall).monospacedDigit())
                        .foregroundStyle(theme.secondaryText)
                    Text(StatsFormat.percent(total > 0 ? slice.value / total : 0))
                        .font(vm.font(.bodySmall).monospacedDigit())
                        .foregroundStyle(theme.tertiaryText)
                        .frame(width: 38, alignment: .trailing)
                }
            }
        }
        .frame(minWidth: 190)
    }
}

struct StatsBarItem: Identifiable, Equatable {
    let label: String
    let value: Double
    let color: Color

    var id: String {
        label
    }
}

struct StatsHBars: View {
    @EnvironmentObject var vm: DashboardViewModel
    let items: [StatsBarItem]
    let theme: StatsTheme
    let summary: String
    var format: (Double) -> String = { Int($0).formatted() }

    var body: some View {
        let peak = max(items.map(\.value).max() ?? 1, 1)
        VStack(spacing: 14) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.label)
                            .font(vm.font(.label))
                            .foregroundStyle(theme.text)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(format(item.value))
                            .font(vm.font(.bodySmall).monospacedDigit())
                            .foregroundStyle(theme.secondaryText)
                    }
                    Chart {
                        BarMark(x: .value("Value", item.value))
                            .foregroundStyle(item.color)
                            .cornerRadius(5)
                    }
                    .chartXScale(domain: 0 ... peak)
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .chartPlotStyle { plot in
                        plot.background(theme.track.opacity(0.6), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .frame(height: 10)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(summary)
    }
}

struct StatsHistogram: View {
    @EnvironmentObject var vm: DashboardViewModel
    let bins: [(label: String, value: Double)]
    let highlight: String?
    let tint: Color
    let theme: StatsTheme
    let summary: String
    var height: CGFloat = 170

    var body: some View {
        let peak = max(bins.map(\.value).max() ?? 1, 1)
        Chart {
            ForEach(bins, id: \.label) { bin in
                BarMark(x: .value("Bucket", bin.label), y: .value("Count", bin.value))
                    .foregroundStyle(highlight == nil || bin.label == highlight ? tint : tint.opacity(0.5))
                    .cornerRadius(5)
                    .annotation(position: .top, spacing: 3) {
                        if bin.value > 0 {
                            Text(Int(bin.value).formatted())
                                .font(vm.font(.labelSmall).monospacedDigit())
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
            }
        }
        .chartXScale(domain: bins.map(\.label))
        .chartYScale(domain: 0 ... peak * 1.2)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel()
                    .font(vm.font(.bodySmall))
                    .foregroundStyle(theme.tertiaryText)
            }
        }
        .frame(height: height)
        .accessibilityLabel(summary)
    }
}

struct StatsHourBars: View {
    @EnvironmentObject var vm: DashboardViewModel
    let hours: [Double]
    let tint: Color
    let theme: StatsTheme
    let summary: String

    var body: some View {
        let peak = hours.max() ?? 0
        Chart {
            ForEach(0 ..< 24, id: \.self) { hour in
                BarMark(x: .value("Hour", hour), y: .value("Minutes", hours[hour] / 60), width: .fixed(16))
                    .foregroundStyle(hour == hours.firstIndex(of: peak) ? tint : tint.opacity(0.5))
                    .cornerRadius(2)
            }
        }
        .chartXScale(domain: -0.5 ... 23.5)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                AxisValueLabel {
                    if let hour = value.as(Int.self) {
                        Text(StatsFormat.hour(hour))
                            .font(vm.font(.bodySmall))
                            .foregroundStyle(theme.tertiaryText)
                    }
                }
            }
        }
        .frame(height: 130)
        .accessibilityLabel(summary)
    }
}

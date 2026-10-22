import Charts
import SwiftUI

struct StatsHeatLegend: View {
    @EnvironmentObject var vm: DashboardViewModel
    let theme: StatsTheme

    var body: some View {
        HStack(spacing: 4) {
            Text("Less")
            ForEach(0 ..< 5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(theme.heat(level: level))
                    .frame(width: 12, height: 12)
            }
            Text("More")
        }
        .font(vm.font(.bodySmall))
        .foregroundStyle(theme.tertiaryText)
        .accessibilityHidden(true)
    }
}

struct StatsContributionHeatmap: View {
    @EnvironmentObject var vm: DashboardViewModel
    let contributions: Contributions
    let theme: StatsTheme
    @State private var hovered: ContributionCell?

    private static let weekdayRows: [Double: String] = [6: "Mon", 4: "Wed", 2: "Fri"]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            WidthDrivenHeight(height: { width in
                let cell = max(4, (width - 38) / CGFloat(max(contributions.weeks, 1)))
                return cell * 7 + 26
            }) {
                chart
            }
            HStack {
                Text(hoverText)
                    .font(vm.font(.bodySmall))
                    .foregroundStyle(hovered == nil ? theme.tertiaryText : theme.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                StatsHeatLegend(theme: theme)
            }
        }
    }

    private var hoverText: String {
        guard let hovered else { return "Hover a day for details" }
        let day = hovered.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
        return hovered.level == 0 ? "\(day) · no activity" : "\(day) · \(StatsFormat.minutes(hovered.minutes)) active"
    }

    private var chart: some View {
        Chart(contributions.cells) { cell in
            RectangleMark(
                xStart: .value("Week", Double(cell.week) - 0.43),
                xEnd: .value("Week end", Double(cell.week) + 0.43),
                yStart: .value("Day", Double(6 - cell.weekday) - 0.43),
                yEnd: .value("Day end", Double(6 - cell.weekday) + 0.43)
            )
            .cornerRadius(3)
            .foregroundStyle(cell.isFuture ? Color.clear : theme.heat(level: cell.level))
        }
        .chartXScale(domain: -0.5 ... Double(contributions.weeks) - 0.5)
        .chartYScale(domain: -0.5 ... 6.5)
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: contributions.monthLabels.map { Double($0.week) }) { value in
                AxisValueLabel(anchor: .topLeading) {
                    if let week = value.as(Double.self), let label = contributions.monthLabels.first(where: { Double($0.week) == week }) {
                        Text(label.text)
                            .font(vm.font(.bodySmall))
                            .foregroundStyle(theme.tertiaryText)
                            .fixedSize()
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: Array(Self.weekdayRows.keys.sorted())) { value in
                AxisValueLabel {
                    if let row = value.as(Double.self), let name = Self.weekdayRows[row] {
                        Text(name)
                            .font(vm.font(.bodySmall))
                            .foregroundStyle(theme.tertiaryText)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(point):
                            guard let frame = proxy.plotFrame else { return }
                            let origin = geometry[frame].origin
                            guard let week: Double = proxy.value(atX: point.x - origin.x),
                                  let row: Double = proxy.value(atY: point.y - origin.y)
                            else {
                                hovered = nil
                                return
                            }
                            let match = contributions.cells.first { $0.week == Int(week.rounded()) && $0.weekday == 6 - Int(row.rounded()) }
                            hovered = match?.isFuture == true ? nil : match
                        case .ended:
                            hovered = nil
                        }
                    }
            }
        }
        .accessibilityLabel("Daily activity over the last \(contributions.weeks) weeks. \(contributions.activeDays) active days.")
    }
}

struct StatsHourWeekdayHeatmap: View {
    @EnvironmentObject var vm: DashboardViewModel
    let matrix: [[Double]]
    let peak: Double
    let theme: StatsTheme
    @State private var hovered: (weekday: Int, hour: Int)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            WidthDrivenHeight(height: { width in
                let cell = max(4, (width - 38) / 24)
                return cell * 7 + 26
            }) {
                chart
            }
            HStack {
                Text(hoverText)
                    .font(vm.font(.bodySmall))
                    .foregroundStyle(hovered == nil ? theme.tertiaryText : theme.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                StatsHeatLegend(theme: theme)
            }
        }
    }

    private var hoverText: String {
        guard let hovered else { return "Hover a cell for details" }
        let minutes = matrix[hovered.weekday][hovered.hour]
        let slot = "\(StatsFormat.weekdayName(hovered.weekday)) \(StatsFormat.hour(hovered.hour))"
        return minutes > 0 ? "\(slot) · \(StatsFormat.minutes(minutes)) active" : "\(slot) · no activity"
    }

    private struct Cell: Identifiable {
        let weekday: Int
        let hour: Int
        let level: Int

        var id: Int {
            weekday * 24 + hour
        }
    }

    private var cells: [Cell] {
        (0 ..< 7).flatMap { weekday in
            (0 ..< 24).map { hour in
                let minutes = matrix[weekday][hour]
                return Cell(weekday: weekday, hour: hour, level: Contributions.level(minutes: minutes, isActive: minutes > 0, peak: peak))
            }
        }
    }

    private var chart: some View {
        Chart(cells) { cell in
            RectangleMark(
                xStart: .value("Hour", Double(cell.hour) - 0.43),
                xEnd: .value("Hour end", Double(cell.hour) + 0.43),
                yStart: .value("Day", Double(6 - cell.weekday) - 0.43),
                yEnd: .value("Day end", Double(6 - cell.weekday) + 0.43)
            )
            .cornerRadius(3)
            .foregroundStyle(theme.heat(level: cell.level))
        }
        .chartXScale(domain: -0.5 ... 23.5)
        .chartYScale(domain: -0.5 ... 6.5)
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: [0.0, 6.0, 12.0, 18.0]) { value in
                AxisValueLabel(anchor: .topLeading) {
                    if let hour = value.as(Double.self) {
                        Text(StatsFormat.hour(Int(hour)))
                            .font(vm.font(.bodySmall))
                            .foregroundStyle(theme.tertiaryText)
                            .fixedSize()
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [6.0, 4.0, 2.0, 0.0]) { value in
                AxisValueLabel {
                    if let row = value.as(Double.self) {
                        Text(StatsFormat.weekdayName(6 - Int(row), short: true))
                            .font(vm.font(.bodySmall))
                            .foregroundStyle(theme.tertiaryText)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(point):
                            guard let frame = proxy.plotFrame else { return }
                            let origin = geometry[frame].origin
                            guard let hour: Double = proxy.value(atX: point.x - origin.x),
                                  let row: Double = proxy.value(atY: point.y - origin.y)
                            else {
                                hovered = nil
                                return
                            }
                            let weekday = 6 - Int(row.rounded())
                            let hourIndex = Int(hour.rounded())
                            hovered = (0 ..< 7).contains(weekday) && (0 ..< 24).contains(hourIndex) ? (weekday, hourIndex) : nil
                        case .ended:
                            hovered = nil
                        }
                    }
            }
        }
        .accessibilityLabel("Activity by hour of day and weekday")
    }
}

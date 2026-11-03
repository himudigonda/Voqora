import Charts
import SwiftUI

enum StatsProduct: String, CaseIterable, Identifiable {
    case overview
    case readAloud
    case dictation
    case audiobooks
    case podcasts
    case ai

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .readAloud: "Read Aloud"
        case .dictation: "Dictation"
        case .audiobooks: "Audiobooks"
        case .podcasts: "Podcasts"
        case .ai: "AI"
        }
    }

    var kind: String {
        switch self {
        case .overview: "All of Voqora"
        case .readAloud: "Text to speech"
        case .dictation: "Speech to text"
        case .audiobooks: "Listen and generate"
        case .podcasts: "Multi-voice episodes"
        case .ai: "Ask and summarize"
        }
    }

    var icon: String {
        switch self {
        case .overview: "square.grid.2x2.fill"
        case .readAloud: "speaker.wave.2.fill"
        case .dictation: "mic.fill"
        case .audiobooks: "books.vertical.fill"
        case .podcasts: "waveform"
        case .ai: "sparkles"
        }
    }

    var definition: String {
        switch self {
        case .overview:
            "Every Voqora product in one place. Pick a product above to see only its numbers."
        case .readAloud:
            "Text to speech: Voqora speaks text you select or copy, or text sent by shortcuts, apps and agents. Audiobook listening is counted under Audiobooks."
        case .dictation:
            "Speech to text: you speak and Voqora types into any app."
        case .audiobooks:
            "Documents turned into narrated books: what you listened to and what Voqora generated."
        case .podcasts:
            "Scripted, multi-voice episodes rendered on this Mac."
        case .ai:
            "Requests sent to your AI provider: summaries and translations of selected text; summaries, questions, quizzes and flashcards for your audiobooks; "
                + "and dictation tidy-ups. Podcast scripts are counted under Podcasts."
        }
    }

    func tint(in theme: StatsTheme) -> Color {
        switch self {
        case .overview: theme.accent
        case .readAloud: theme.series(1)
        case .dictation: theme.series(2)
        case .audiobooks: theme.series(3)
        case .podcasts: theme.series(7)
        case .ai: theme.series(4)
        }
    }

    func railValue(_ current: PeriodAggregate) -> (value: String, unit: String) {
        switch self {
        case .overview: (StatsFormat.duration(current.totalSavedSeconds), "saved")
        case .readAloud: (StatsFormat.duration(current.speechSeconds), "read aloud")
        case .dictation: (StatsFormat.count(current.dictation.words), "words")
        case .audiobooks: (StatsFormat.duration(current.listeningSeconds), "listened")
        case .podcasts: (StatsFormat.count(current.creation.podcastRenders), "episodes")
        case .ai: (StatsFormat.count(current.ai.totalRequests), "requests")
        }
    }

    static var initial: StatsProduct {
        #if DEBUG
            if let raw = ProcessInfo.processInfo.environment["VOQORA_STATS_SECTION"], let product = StatsProduct(rawValue: raw) {
                return product
            }
        #endif
        return .overview
    }
}

struct StatsProductRail: View {
    @Binding var selection: StatsProduct
    let current: PeriodAggregate
    let theme: StatsTheme

    private static let tileSpacing = Theme.Space.unit * 2
    private static let minimumTileWidth: CGFloat = 140

    var body: some View {
        AdaptiveGrid(minColumnWidth: Self.minimumTileWidth, spacing: Self.tileSpacing, maxColumns: StatsProduct.allCases.count, balanced: true) {
            ForEach(StatsProduct.allCases) { product in
                StatsProductTile(product: product, current: current, theme: theme, isSelected: product == selection) { select(product) }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func select(_ product: StatsProduct) {
        withAnimation(Theme.Motion.selection) { selection = product }
    }
}

private struct StatsProductTile: View {
    @EnvironmentObject var vm: DashboardViewModel
    let product: StatsProduct
    let current: PeriodAggregate
    let theme: StatsTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let tint = product.tint(in: theme)
        let reading = product.railValue(current)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Space.unit) {
                    Image(systemName: product.icon)
                        .font(vm.font(.labelSmall))
                        .foregroundStyle(tint)
                        .accessibilityHidden(true)
                    Text(product.title)
                        .font(vm.font(.label))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Text(product.kind)
                    .font(vm.font(.labelSmall))
                    .foregroundStyle(theme.tertiaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.Space.unit)
                valueLine(reading)
            }
            .padding(.horizontal, Theme.Space.item - 2)
            .padding(.vertical, Theme.Space.item - 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(isSelected ? tint.opacity(0.16) : theme.base.surfaceContainer, in: shape)
            .overlay { shape.strokeBorder(isSelected ? tint : .clear, lineWidth: 1.5) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(product.title), \(product.kind), \(reading.value) \(reading.unit)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Shape.lg, style: .continuous)
    }

    private func valueLine(_ reading: (value: String, unit: String)) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.unit) {
                value(reading.value)
                unit(reading.unit)
            }
            VStack(alignment: .leading, spacing: 0) {
                value(reading.value)
                unit(reading.unit)
            }
        }
    }

    private func value(_ text: String) -> some View {
        Text(text)
            .font(vm.font(.titleSmall).monospacedDigit())
            .foregroundStyle(theme.text)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .contentTransition(.numericText())
    }

    private func unit(_ text: String) -> some View {
        Text(text)
            .font(vm.font(.labelSmall))
            .foregroundStyle(theme.secondaryText)
            .lineLimit(1)
    }
}

struct StatsHeroMetricModel: Identifiable {
    let title: String
    let value: String
    let footnote: String
    var change: Double?
    var lowerIsBetter = false

    var id: String {
        title
    }
}

struct StatsProductHero: View {
    @EnvironmentObject var vm: DashboardViewModel
    let context: StatsContext
    let metrics: [StatsHeroMetricModel]

    var body: some View {
        let theme = context.theme
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            definition
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Theme.Space.item) {
                    ForEach(metrics) { metric in
                        StatsHeroMetric(model: metric, comparison: context.data.comparison, theme: theme)
                            .frame(minWidth: 140, idealWidth: 140, maxWidth: .infinity, alignment: .leading)
                    }
                }
                Grid(alignment: .topLeading, horizontalSpacing: Theme.Space.item, verticalSpacing: Theme.Space.item) {
                    ForEach(Array(stride(from: 0, to: metrics.count, by: 2)), id: \.self) { start in
                        GridRow {
                            ForEach(metrics[start ..< min(start + 2, metrics.count)]) { metric in
                                StatsHeroMetric(model: metric, comparison: context.data.comparison, theme: theme)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Space.card)
        .padding(.vertical, Theme.Space.item + 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(context.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: Theme.Shape.xl, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var definition: some View {
        let theme = context.theme
        return (
            Text(context.product.definition).foregroundStyle(theme.secondaryText)
                + Text(context.data.previousPeriodName.map { " Changes compare to the \($0)." } ?? "").foregroundStyle(theme.tertiaryText)
        )
        .font(vm.font(.bodySmall))
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct StatsHeroMetric: View {
    @EnvironmentObject var vm: DashboardViewModel
    let model: StatsHeroMetricModel
    let comparison: String?
    let theme: StatsTheme

    private var spokenChange: String {
        guard let label = StatsFormat.change(model.change) else { return "" }
        return ", \(label)" + (comparison.map { " \($0)" } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.unit * 2) {
                Text(model.value)
                    .font(vm.font(.headline).monospacedDigit())
                    .foregroundStyle(theme.text)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let label = StatsFormat.change(model.change) {
                    StatsChangeChip(label: label, change: model.change ?? 0, theme: theme, lowerIsBetter: model.lowerIsBetter)
                        .fixedSize()
                }
            }
            Text(model.title)
                .font(vm.font(.label))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
            Text(model.footnote)
                .font(vm.font(.bodySmall))
                .foregroundStyle(theme.tertiaryText)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help("\(model.title): \(model.value). \(model.footnote)" + (StatsFormat.change(model.change).map { ". \($0)" + (comparison.map { " \($0)" } ?? "") } ?? ""))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(model.title), \(model.value), \(model.footnote)\(spokenChange)")
    }
}

protocol StatsLens: CaseIterable, Hashable, RawRepresentable where RawValue == String {
    var title: String { get }
    var icon: String { get }
    var subtitle: String { get }
}

extension StatsLens {
    static var initial: Self {
        allCases[allCases.startIndex]
    }
}

struct StatsLensCard<Lens: StatsLens, Content: View>: View {
    @EnvironmentObject var vm: DashboardViewModel
    let context: StatsContext
    let content: (Lens) -> Content
    @AppStorage private var lens: Lens

    init(context: StatsContext, @ViewBuilder content: @escaping (Lens) -> Content) {
        self.context = context
        self.content = content
        _lens = AppStorage(wrappedValue: Lens.initial, "statsLens.\(context.product.rawValue)")
    }

    var body: some View {
        let theme = context.theme
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            if Lens.allCases.count > 1 {
                chips
            }
            if Lens.allCases.count == 1 {
                Text(lens.title)
                    .font(vm.font(.titleSmall))
                    .foregroundStyle(theme.text)
                    .accessibilityAddTraits(.isHeader)
            }
            if !lens.subtitle.isEmpty {
                Text(lens.subtitle)
                    .font(vm.font(.bodySmall))
                    .foregroundStyle(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content(lens)
                .environment(\.statsCardChrome, false)
                .environment(\.statsTint, context.tint)
        }
        .padding(Theme.Space.card)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .voqoraCardBackground()
        .animation(Theme.Motion.selection, value: lens)
        .onAppear {
            #if DEBUG
                if let raw = ProcessInfo.processInfo.environment["VOQORA_STATS_LENS"], let forced = Lens(rawValue: raw) {
                    lens = forced
                }
            #endif
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.unit * 2) {
                ForEach(Array(Lens.allCases), id: \.self) { option in
                    chip(option)
                }
            }
        }
    }

    private func chip(_ option: Lens) -> some View {
        let theme = context.theme
        let isSelected = option == lens
        return Button {
            withAnimation(Theme.Motion.selection) { lens = option }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: option.icon)
                    .font(vm.font(.labelSmall))
                    .accessibilityHidden(true)
                Text(option.title)
                    .font(vm.font(.label))
            }
            .foregroundStyle(isSelected ? theme.text : theme.secondaryText)
            .padding(.horizontal, Theme.Space.item)
            .frame(minHeight: 30)
            .background(isSelected ? context.tint.opacity(0.2) : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(theme.separator.opacity(isSelected ? 0 : 0.7), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct StatsTrendMetric: Identifiable {
    let id: String
    let label: String
    let value: (TimelinePoint) -> Double
    let format: (Double) -> String
    var isCount = false

    func amount(_ value: Double) -> String {
        guard isCount else { return format(value) }
        let noun = label.lowercased()
        return "\(format(value)) \(value == 1 && noun.hasSuffix("s") ? String(noun.dropLast()) : noun)"
    }

    static func minutes(_ id: String, _ label: String, _ value: @escaping (TimelinePoint) -> Double) -> StatsTrendMetric {
        StatsTrendMetric(id: id, label: label, value: value, format: { StatsFormat.minutes($0) })
    }

    static func count(_ id: String, _ label: String, _ value: @escaping (TimelinePoint) -> Int) -> StatsTrendMetric {
        StatsTrendMetric(id: id, label: label, value: { Double(value($0)) }, format: { Int($0.rounded()).formatted() }, isCount: true)
    }
}

struct StatsTrendLens: View {
    @EnvironmentObject var vm: DashboardViewModel
    let context: StatsContext
    let metrics: [StatsTrendMetric]
    let emptyText: String
    @State private var metricID: String?
    @State private var selection: Date?

    private var metric: StatsTrendMetric {
        metrics.first { $0.id == metricID } ?? metrics[0]
    }

    private var trend: [TimelinePoint] {
        context.data.trend
    }

    private var average: Double {
        trend.isEmpty ? 0 : trend.reduce(0) { $0 + metric.value($1) } / Double(trend.count)
    }

    private var selectedPoint: TimelinePoint? {
        guard let selection else { return nil }
        return trend.min { abs($0.date.timeIntervalSince(selection)) < abs($1.date.timeIntervalSince(selection)) }
    }

    var body: some View {
        let theme = context.theme
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            if metrics.count > 1 {
                HStack {
                    Spacer(minLength: 0)
                    StatsMetricToggle(
                        selection: Binding(get: { metric.id }, set: { metricID = $0 }),
                        options: metrics.map(\.id),
                        title: { id in metrics.first { $0.id == id }?.label ?? id },
                        theme: theme
                    )
                }
            }
            if trend.contains(where: { metric.value($0) > 0 }) {
                chart
                if let best = trend.max(by: { metric.value($0) < metric.value($1) }) {
                    let unitName = context.data.trendUnitName
                    let caption = StatsFormat.pointCaption(best.date, range: context.data.range, unit: context.data.trendUnit)
                    StatsInsight(
                        icon: "sparkles",
                        text: "Best \(unitName): \(caption) with \(metric.amount(metric.value(best))). The dashed line is the average, \(metric.format(average)) per \(unitName).",
                        theme: theme
                    )
                }
            } else {
                StatsEmptyNote(icon: "chart.bar", title: "Nothing in this period", text: emptyText, theme: theme, minHeight: 200)
            }
        }
    }

    private var chart: some View {
        let theme = context.theme
        let unit = context.data.trendUnit
        let tint = context.tint
        return Chart {
            ForEach(trend) { point in
                BarMark(x: .value("Date", point.date, unit: unit), y: .value(metric.label, metric.value(point)))
                    .foregroundStyle(selectedPoint == nil || selectedPoint?.date == point.date ? tint : tint.opacity(0.55))
                    .cornerRadius(3)
            }
            RuleMark(y: .value("Average", average))
                .foregroundStyle(theme.secondaryText.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            if let point = selectedPoint {
                RuleMark(x: .value("Selected", point.date, unit: unit))
                    .foregroundStyle(theme.separator)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .overlay, alignment: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        StatsCallout(
                            title: StatsFormat.pointCaption(point.date, range: context.data.range, unit: unit),
                            rows: metrics.map { StatsCalloutRow(color: $0.id == metric.id ? tint : theme.ramp(tint, 3), label: $0.label, value: $0.format($0.value(point))) },
                            theme: theme
                        )
                    }
            }
        }
        .chartXSelection(value: $selection)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    .foregroundStyle(theme.separator)
                AxisValueLabel {
                    if let amount = value.as(Double.self), !metric.isCount || amount == amount.rounded() {
                        Text(metric.format(amount))
                            .font(vm.font(.bodySmall))
                            .foregroundStyle(theme.tertiaryText)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: context.data.range == .week ? 7 : 6)) { value in
                AxisValueLabel(centered: true) {
                    if let date = value.as(Date.self) {
                        Text(StatsFormat.axisLabel(date, range: context.data.range))
                            .font(vm.font(.bodySmall))
                            .foregroundStyle(theme.tertiaryText)
                    }
                }
            }
        }
        .frame(height: 200)
        .onAppear { selection = StatsDebug.selection(in: trend) }
        .accessibilityLabel("Bar chart of \(metric.label.lowercased()) per \(context.data.trendUnitName)")
        .accessibilityValue("Average \(metric.format(average)) per \(context.data.trendUnitName)")
    }
}

struct StatsRhythmLens<Leading: View>: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var baseTheme
    let matrix: [[Double]]
    let tint: Color
    let noun: String
    let leading: Leading
    @State private var mode = Mode.grid

    private enum Mode: String, CaseIterable {
        case grid = "Week grid"
        case hours = "By hour"
    }

    init(matrix: [[Double]], tint: Color, noun: String, @ViewBuilder leading: () -> Leading = { EmptyView() }) {
        self.matrix = matrix
        self.tint = tint
        self.noun = noun
        self.leading = leading()
    }

    var body: some View {
        let theme = StatsTheme(base: baseTheme)
        let peak = matrix.matrixPeak
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            HStack {
                leading
                Spacer(minLength: Theme.Space.item)
                if peak > 0 {
                    StatsMetricToggle(selection: $mode, options: Mode.allCases, title: { $0.rawValue }, theme: theme)
                }
            }
            if peak <= 0 {
                StatsEmptyNote(icon: "clock", title: "No rhythm yet", text: "Your daily rhythm appears after a few sessions.", theme: theme, minHeight: 180)
            } else {
                switch mode {
                case .grid:
                    StatsHourWeekdayHeatmap(matrix: matrix, peak: peak, theme: theme, tint: tint)
                case .hours:
                    StatsHourBars(hours: matrix.hourColumnTotals.map { $0 * 60 }, tint: tint, theme: theme, summary: "Active minutes by hour of day")
                }
                insights(theme)
            }
        }
    }

    private func insights(_ theme: StatsTheme) -> some View {
        let hours = matrix.hourColumnTotals
        let weekdays = matrix.weekdayRowTotals
        return VStack(alignment: .leading, spacing: 6) {
            if let top = hours.max(), top > 0, let hour = hours.firstIndex(of: top) {
                StatsInsight(icon: "sun.max", text: "You \(noun) most around \(StatsFormat.hour(hour)).", theme: theme)
            }
            if let top = weekdays.max(), top > 0, let day = weekdays.firstIndex(of: top) {
                StatsInsight(icon: "calendar", text: "\(StatsFormat.weekdayName(day))s are your busiest day.", theme: theme)
            }
        }
    }
}

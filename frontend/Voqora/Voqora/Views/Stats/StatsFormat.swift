import AppKit
import Foundation
import SwiftUI

struct StatsTheme {
    let base: Theme

    private static let hueOffsets: [Double] = [0, 180, 90, 270, 45, 225, 135, 315]

    var accent: Color {
        base.primary
    }

    var strong: Color {
        base.primary
    }

    var muted: Color {
        base.primary.opacity(0.4)
    }

    var track: Color {
        base.primaryContainer
    }

    var emptyCell: Color {
        base.surfaceContainerHighest
    }

    var text: Color {
        base.onSurface
    }

    var secondaryText: Color {
        base.onSurfaceVariant
    }

    var tertiaryText: Color {
        base.onSurfaceMuted
    }

    var separator: Color {
        base.outlineVariant
    }

    var other: Color {
        base.outline
    }

    func series(_ index: Int) -> Color {
        Self.rotated(base.primary, degrees: Self.hueOffsets[index % Self.hueOffsets.count])
    }

    func heat(level: Int) -> Color {
        switch level {
        case ...0: emptyCell
        case 1: accent.opacity(0.32)
        case 2: accent.opacity(0.55)
        case 3: accent.opacity(0.78)
        default: accent
        }
    }

    private static func rotated(_ color: Color, degrees: Double) -> Color {
        guard degrees != 0 else { return color }
        let source = NSColor(color)
        return Color(nsColor: NSColor(name: nil) { appearance in
            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            var brightness: CGFloat = 0
            var alpha: CGFloat = 0
            appearance.performAsCurrentDrawingAppearance {
                (source.usingColorSpace(.sRGB) ?? source).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            }
            let shifted = (Double(hue) + degrees / 360).truncatingRemainder(dividingBy: 1)
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(
                hue: CGFloat(shifted),
                saturation: max(saturation, isDark ? 0.5 : 0.6),
                brightness: isDark ? max(brightness, 0.82) : min(max(brightness, 0.5), 0.72),
                alpha: 1
            )
        })
    }
}

enum StatsFormat {
    static let wordsPerPaperbackPage = 275.0
    static let wordsPerNovel = 90000.0

    static func duration(_ seconds: Double) -> String {
        guard seconds >= 60 else { return seconds >= 1 ? "\(Int(seconds.rounded()))s" : "0m" }
        let minutes = Int((seconds / 60).rounded(.down))
        let hours = minutes / 60
        if hours >= 100 {
            return "\(hours)h"
        }
        return hours > 0 ? "\(hours)h \(minutes % 60)m" : "\(minutes)m"
    }

    static func minutes(_ minutes: Double) -> String {
        duration(minutes * 60)
    }

    static func hours(_ seconds: Double) -> String {
        let value = seconds / 3600
        return value.formatted(.number.precision(.fractionLength(value < 10 ? 1 : 0))) + "h"
    }

    static func count(_ value: Int) -> String {
        value >= 10000 ? value.formatted(.number.notation(.compactName).precision(.fractionLength(0 ... 1))) : value.formatted()
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    static func latency(_ milliseconds: Double) -> String {
        milliseconds < 1000
            ? "\(Int(milliseconds.rounded())) ms"
            : (milliseconds / 1000).formatted(.number.precision(.fractionLength(1))) + " s"
    }

    static func factor(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(value < 10 ? 1 : 0))) + "×"
    }

    static func change(_ value: Double?) -> String? {
        guard let value else { return nil }
        let percent = Int((abs(value) * 100).rounded())
        guard percent > 0 else { return "No change" }
        return percent >= 1000 ? "\(value > 0 ? "+" : "-")999%+" : "\(value > 0 ? "+" : "-")\(percent)%"
    }

    static func currency(_ value: Double) -> String {
        value < 0.01 && value > 0 ? "< $0.01" : value.formatted(.currency(code: "USD"))
    }

    static func hour(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        let date = Calendar.current.date(from: components) ?? Date()
        return date.formatted(.dateTime.hour())
    }

    static func weekdayName(_ index: Int, short: Bool = false) -> String {
        let symbols = short ? Calendar.current.shortStandaloneWeekdaySymbols : Calendar.current.standaloneWeekdaySymbols
        return symbols[(index + 1) % 7]
    }

    static func speed(_ speed: Double) -> String {
        speed.formatted(.number.precision(.fractionLength(speed == speed.rounded() ? 1 : 2))) + "×"
    }

    static func voiceSubtitle(_ id: String) -> String {
        let descriptor = VoicePickerCatalog.descriptor(forVoice: id, blends: [])
        let language = descriptor.languageLabel.lowercased() == "multi" ? "Multilingual" : descriptor.languageLabel
        var parts = [descriptor.engineName, language]
        let letters = Array(id)
        if descriptor.engineName == "Kokoro", letters.count > 2, letters[2] == "_" {
            parts.append(letters[1] == "f" ? "Female" : letters[1] == "m" ? "Male" : "")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func rangeCaption(_ interval: DateInterval, range: StatsRange) -> String {
        let end = interval.end.addingTimeInterval(-1)
        switch range {
        case .week, .month, .quarter:
            return "\(interval.start.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.month(.abbreviated).day()))"
        case .year, .all:
            return "\(interval.start.formatted(.dateTime.month(.abbreviated).year())) – \(end.formatted(.dateTime.month(.abbreviated).year()))"
        }
    }

    static func axisLabel(_ date: Date, range: StatsRange) -> String {
        switch range {
        case .week: date.formatted(.dateTime.weekday(.abbreviated))
        case .month, .quarter: date.formatted(.dateTime.month(.abbreviated).day())
        case .year, .all: date.formatted(.dateTime.month(.abbreviated))
        }
    }

    static func pointCaption(_ date: Date, range: StatsRange, unit: Calendar.Component? = nil) -> String {
        switch unit ?? range.bucket {
        case .weekOfYear: "Week of " + date.formatted(.dateTime.month(.abbreviated).day())
        case .day: date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        default: date.formatted(.dateTime.month(.wide).year())
        }
    }
}

enum StatsDebug {
    static func selection(in points: [TimelinePoint]) -> Date? {
        #if DEBUG
            guard ProcessInfo.processInfo.environment["VOQORA_STATS_HOVER"] == "1", points.count > 2 else { return nil }
            return points[points.count * 2 / 3].date
        #else
            return nil
        #endif
    }
}

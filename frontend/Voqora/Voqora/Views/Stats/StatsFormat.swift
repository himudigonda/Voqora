import AppKit
import Foundation
import SwiftUI

enum StatsPalette {
    private static func tone(hue: Double, light: Double, dark: Double) -> Color {
        Theme.fixedTone(hue: hue, lightLightness: light, darkLightness: dark, chroma: 0.14)
    }

    static let readAloud = tone(hue: 250, light: 0.48, dark: 0.50)
    static let dictation = tone(hue: 150, light: 0.56, dark: 0.62)
    static let audiobooks = tone(hue: 318, light: 0.62, dark: 0.66)
    static let audiobookRendering = tone(hue: 318, light: 0.46, dark: 0.50)
    static let podcasts = tone(hue: 15, light: 0.50, dark: 0.62)
    static let ai = tone(hue: 75, light: 0.60, dark: 0.66)
}

struct StatsTheme {
    let base: Theme

    var accent: Color {
        base.primary
    }

    var strong: Color {
        base.primary
    }

    var track: Color {
        base.surfaceContainerHighest
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

    private static let rampOpacities: [Double] = [1, 0.72, 0.5, 0.34, 0.22, 0.14]

    func ramp(_ tint: Color, _ index: Int) -> Color {
        tint.opacity(Self.rampOpacities[min(max(index, 0), Self.rampOpacities.count - 1)])
    }

    func heat(level: Int, tint: Color? = nil) -> Color {
        let color = tint ?? accent
        switch level {
        case ...0: return emptyCell
        case 1: return color.opacity(0.32)
        case 2: return color.opacity(0.55)
        case 3: return color.opacity(0.78)
        default: return color
        }
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

    static var isolatedSeries: String? {
        #if DEBUG
            ProcessInfo.processInfo.environment["VOQORA_STATS_ISOLATE"]
        #else
            nil
        #endif
    }
}

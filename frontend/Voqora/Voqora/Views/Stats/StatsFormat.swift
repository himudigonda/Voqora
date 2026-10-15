import Foundation
import SwiftUI

struct StatsTheme {
    let accent: Color
    let strong: Color
    let muted: Color
    let subtle: Color

    @MainActor
    init(option: AccentColorOption, scheme: ColorScheme, contrast: ColorSchemeContrast) {
        let ramp = Palette.accentRamp(for: option, appearance: scheme, increaseContrast: contrast == .increased)
        accent = Color(ramp.base)
        strong = Color(ramp.strong)
        muted = Color(ramp.muted)
        subtle = Color(ramp.subtle)
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

    static func count(_ value: Int) -> String {
        value >= 10000 ? value.formatted(.number.notation(.compactName).precision(.fractionLength(0 ... 1))) : value.formatted()
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
        let symbols = short ? Calendar.current.veryShortStandaloneWeekdaySymbols : Calendar.current.standaloneWeekdaySymbols
        return symbols[(index + 1) % 7]
    }

    static func speed(_ speed: Double) -> String {
        speed.formatted(.number.precision(.fractionLength(speed == speed.rounded() ? 1 : 2))) + "×"
    }

    static func voiceDetail(_ id: String) -> String {
        let prefix = Array(id.prefix(2))
        guard prefix.count == 2 else { return "Voice" }
        let language: String? = switch prefix[0] {
        case "a": "American"
        case "b": "British"
        case "e": "Spanish"
        case "f": "French"
        case "h": "Hindi"
        case "i": "Italian"
        case "j": "Japanese"
        case "p": "Portuguese"
        case "z": "Mandarin"
        default: nil
        }
        let gender: String? = switch prefix[1] {
        case "f": "Female"
        case "m": "Male"
        default: nil
        }
        return [language, gender].compactMap(\.self).joined(separator: " · ").ifEmpty("Voice")
    }

    static func rangeCaption(_ interval: DateInterval, range: StatsRange) -> String {
        let end = interval.end.addingTimeInterval(-1)
        switch range {
        case .week, .month:
            return "\(interval.start.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.month(.abbreviated).day()))"
        case .year, .all:
            return "\(interval.start.formatted(.dateTime.month(.abbreviated).year())) – \(end.formatted(.dateTime.month(.abbreviated).year()))"
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}

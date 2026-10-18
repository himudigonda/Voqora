import Foundation

nonisolated enum PauseScale {
    static let minimum = 0.5
    static let maximum = 2.0
    static let standard = 1.0
    static let step = 0.05
    static let range: ClosedRange<Double> = minimum ... maximum

    static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return standard }
        return min(maximum, max(minimum, value))
    }

    static func label(_ value: Double) -> String {
        String(format: "%g", (clamped(value) * 100).rounded() / 100) + "×"
    }

    static func description(_ value: Double) -> String {
        let clampedValue = clamped(value)
        if abs(clampedValue - standard) < 0.001 {
            return "Natural pauses"
        }
        return clampedValue < standard ? "Shorter pauses" : "Longer pauses"
    }
}

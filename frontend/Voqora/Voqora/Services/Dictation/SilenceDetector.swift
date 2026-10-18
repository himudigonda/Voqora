import Foundation

nonisolated struct SilenceDetector: Equatable, Sendable {
    static let defaultThreshold: Float = 0.3
    static let defaultInitialGrace: TimeInterval = 6
    static let minimumTimeout: TimeInterval = 0.1

    let timeout: TimeInterval
    let threshold: Float
    let initialGrace: TimeInterval
    private let startedAt: TimeInterval
    private var lastActivity: TimeInterval?

    init(
        timeout: TimeInterval,
        startedAt: TimeInterval,
        threshold: Float = SilenceDetector.defaultThreshold,
        initialGrace: TimeInterval = SilenceDetector.defaultInitialGrace
    ) {
        self.timeout = max(Self.minimumTimeout, timeout)
        self.startedAt = startedAt
        self.threshold = min(1, max(0, threshold))
        self.initialGrace = max(0, initialGrace)
    }

    var hasHeardSpeech: Bool {
        lastActivity != nil
    }

    mutating func registerActivity(at time: TimeInterval) {
        lastActivity = max(lastActivity ?? time, time)
    }

    mutating func process(level: Float, at time: TimeInterval) -> Bool {
        if level >= threshold {
            registerActivity(at: time)
            return false
        }
        guard let lastActivity else {
            return time - startedAt >= max(timeout, initialGrace)
        }
        return time - lastActivity >= timeout
    }
}

nonisolated enum AudioLevel {
    static let floorDecibels: Float = -50

    static func rms(_ samples: some Collection<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sumOfSquares / Float(samples.count)).squareRoot()
    }

    static func normalized(rms: Float) -> Float {
        guard rms.isFinite, rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels - floorDecibels) / -floorDecibels))
    }
}

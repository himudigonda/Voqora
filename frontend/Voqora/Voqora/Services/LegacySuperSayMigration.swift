import AppKit
import Combine
import Foundation

private let legacySuperSayBundleIdentifier = "com.himudigonda.SuperSay"

/// A deliberately narrow, local-only bridge from the retired SuperSay app.
///
/// The user must explicitly ask to import compatible preferences. Voqora never
/// copies documents, audio, history, credentials, email, shortcuts, or privacy
/// choices, and it never removes SuperSay automatically.
@MainActor
final class LegacySuperSayMigration: ObservableObject {
    enum Event: Equatable {
        case detected
        case completed
        case removed
    }

    static let legacyBundleIdentifier = legacySuperSayBundleIdentifier

    private enum Key {
        static let wasDetected = "legacySuperSayWasDetected"
        static let noticeSeen = "legacySuperSayNoticeSeen"
        static let importRecorded = "legacySuperSayImportRecorded"
        static let removalRecorded = "legacySuperSayRemovalRecorded"
    }

    @Published private(set) var legacyAppURL: URL?
    @Published var shouldPresentNotice = false
    @Published private(set) var lastImportedCount = 0

    private let defaults: UserDefaults
    private let legacyDefaults: UserDefaults?
    private let locateLegacyApp: () -> URL?
    private let recordEvent: ((Event) -> Void)?

    init(
        defaults: UserDefaults = .standard,
        legacyDefaults: UserDefaults? = nil,
        locateLegacyApp: (() -> URL?)? = nil,
        recordEvent: ((Event) -> Void)? = nil
    ) {
        self.defaults = defaults
        self.legacyDefaults = legacyDefaults ?? UserDefaults(suiteName: Self.legacyBundleIdentifier)
        self.locateLegacyApp = locateLegacyApp ?? Self.findLegacyApp
        self.recordEvent = recordEvent
    }

    var isLegacyInstalled: Bool { legacyAppURL != nil }

    func evaluate() {
        if let appURL = locateLegacyApp() {
            legacyAppURL = appURL
            if !defaults.bool(forKey: Key.wasDetected) {
                defaults.set(true, forKey: Key.wasDetected)
                record(.detected)
            }
            shouldPresentNotice = !defaults.bool(forKey: Key.noticeSeen)
            return
        }

        legacyAppURL = nil
        shouldPresentNotice = false
        if defaults.bool(forKey: Key.wasDetected), !defaults.bool(forKey: Key.removalRecorded) {
            defaults.set(true, forKey: Key.removalRecorded)
            record(.removed)
        }
    }

    func deferNotice() {
        defaults.set(true, forKey: Key.noticeSeen)
        shouldPresentNotice = false
    }

    /// Copies only compatible appearance and playback preferences after an
    /// explicit user action. Returns how many values were actually imported.
    @discardableResult
    func importCompatiblePreferences() -> Int {
        // Choosing import is also an explicit acknowledgement of the notice.
        defaults.set(true, forKey: Key.noticeSeen)
        shouldPresentNotice = false
        guard let legacyDefaults else {
            lastImportedCount = 0
            return 0
        }

        var imported = 0

        if let voice = legacyDefaults.string(forKey: "selectedVoice"),
           Self.supportedVoices.contains(voice) {
            defaults.set(voice, forKey: "selectedVoice")
            imported += 1
        }
        imported += copyFiniteDouble("speechSpeed", range: 0.5...2.0, from: legacyDefaults)
        imported += copyFiniteDouble("speechVolume", range: 0.0...1.5, from: legacyDefaults)
        imported += copyBoolean("enableDucking", from: legacyDefaults)
        imported += copyBoolean("cleanURLs", from: legacyDefaults)

        if let theme = legacyDefaults.string(forKey: "appTheme"),
           ["system", "light", "dark"].contains(theme) {
            defaults.set(theme, forKey: "appTheme")
            imported += 1
        }
        if let font = legacyDefaults.string(forKey: "selectedFontName"),
           Self.supportedFonts.contains(font) {
            defaults.set(font, forKey: "selectedFontName")
            imported += 1
        }

        lastImportedCount = imported
        if imported > 0, !defaults.bool(forKey: Key.importRecorded) {
            defaults.set(true, forKey: Key.importRecorded)
            record(.completed)
        }
        return imported
    }

    func showLegacyAppInFinder() {
        guard let legacyAppURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([legacyAppURL])
    }

    private func copyFiniteDouble(_ key: String, range: ClosedRange<Double>, from source: UserDefaults) -> Int {
        guard let number = source.object(forKey: key) as? NSNumber else { return 0 }
        let value = number.doubleValue
        guard value.isFinite, range.contains(value) else { return 0 }
        defaults.set(value, forKey: key)
        return 1
    }

    private func copyBoolean(_ key: String, from source: UserDefaults) -> Int {
        guard let value = source.object(forKey: key) as? Bool else { return 0 }
        defaults.set(value, forKey: key)
        return 1
    }

    private static let supportedVoices: Set<String> = [
        "af_bella", "af_sarah", "am_adam", "am_michael",
        "bf_emma", "bf_isabella", "bm_george", "bm_lewis",
    ]

    private static let supportedFonts: Set<String> = [
        "System Rounded", "System Standard", "System Mono", "System Serif", "Poppins",
    ]

    private static func findLegacyApp() -> URL? {
        let locations = [
            URL(fileURLWithPath: "/Applications/SuperSay.app"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/SuperSay.app"),
        ]
        return locations.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    private func record(_ event: Event) {
        if let recordEvent {
            recordEvent(event)
        } else {
            Self.recordMetricsEvent(event)
        }
    }

    private static func recordMetricsEvent(_ event: Event) {
        switch event {
        case .detected: MetricsService.shared.trackMigrationDetected()
        case .completed: MetricsService.shared.trackMigrationCompleted()
        case .removed: MetricsService.shared.trackLegacyAppRemoved()
        }
    }
}

import Foundation

enum RuntimeEnvironment {
    /// A local verification run may exercise the actual GUI without writing
    /// a synthetic adoption event into production analytics. This is an
    /// explicit developer-only override; normal shipped runs remain opt-out
    /// through the visible preference.
    nonisolated static func disablesTelemetry(in environment: [String: String]) -> Bool {
        environment["VOQORA_DISABLE_TELEMETRY"] == "1"
    }

    nonisolated static var disablesTelemetry: Bool {
        disablesTelemetry(in: ProcessInfo.processInfo.environment)
    }

    /// XCTest's configuration path is present in most local runs. GitHub's
    /// macOS host can launch the app test bundle without forwarding that
    /// environment value, so also detect the loaded XCTest runtime.
    nonisolated static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    /// The app target hosts its unit tests. Keep test-only state out of the
    /// user's Voqora preferences, without changing the production default.
    nonisolated static func testDefaults() -> UserDefaults {
        let suite = "com.himudigonda.Voqora.tests.\(ProcessInfo.processInfo.processIdentifier)"
        return UserDefaults(suiteName: suite)!
    }
}

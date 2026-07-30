import Foundation

enum RuntimeEnvironment {
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

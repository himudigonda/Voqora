import Foundation

enum RuntimeEnvironment {
    nonisolated static func disablesTelemetry(in environment: [String: String]) -> Bool {
        environment["VOQORA_DISABLE_TELEMETRY"] == "1"
    }

    nonisolated static var disablesTelemetry: Bool {
        disablesTelemetry(in: ProcessInfo.processInfo.environment)
    }

    nonisolated static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    nonisolated static func testDefaults() -> UserDefaults {
        let suite = "com.himudigonda.Voqora.tests.\(ProcessInfo.processInfo.processIdentifier)"
        return UserDefaults(suiteName: suite)!
    }
}

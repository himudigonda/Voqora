import Foundation

enum RuntimeEnvironment {
    /// XCTest's configuration path is present in most local runs. GitHub's
    /// macOS host can launch the app test bundle without forwarding that
    /// environment value, so also detect the loaded XCTest runtime.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}

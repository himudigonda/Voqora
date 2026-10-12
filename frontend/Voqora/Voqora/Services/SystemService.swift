import AppKit
import Foundation

final nonisolated class SystemService: @unchecked Sendable {
    private static let emptyProbeWindow: TimeInterval = 10
    private static let duckableApps: [(name: String, bundleID: String)] = [
        ("Music", "com.apple.Music"),
        ("Spotify", "com.spotify.client"),
    ]

    private let queue = DispatchQueue(label: "com.himudigonda.Voqora.ducking")
    private let runScript: (String) -> (output: String?, failed: Bool)
    private let now: () -> Date
    private let installedApps: () -> [String]
    private var savedVolumes: [String: Int] = [:]
    private var isDucked = false
    private var lastEmptyProbe: Date?

    init(
        runScript: @escaping (String) -> (output: String?, failed: Bool) = SystemService.runAppleScript,
        now: @escaping () -> Date = Date.init,
        installedApps: @escaping () -> [String] = SystemService.defaultInstalledDuckableApps
    ) {
        self.runScript = runScript
        self.now = now
        self.installedApps = installedApps
    }

    static func runAppleScript(_ source: String) -> (output: String?, failed: Bool) {
        guard let appleScript = NSAppleScript(source: source) else { return (nil, true) }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        return (result.stringValue, error != nil)
    }

    static func defaultInstalledDuckableApps() -> [String] {
        duckableApps
            .filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
            .map(\.name)
    }

    func beginDucking(onFailure: @escaping @MainActor (String) -> Void) {
        queue.async { [weak self] in
            guard let self, !self.isDucked else { return }
            if let lastEmptyProbe, now() < lastEmptyProbe + Self.emptyProbeWindow {
                return
            }
            let apps = installedApps()
            guard !apps.isEmpty else { return }
            let perAppScript = apps.map { app in
                """
                set \(app)Volume to -1
                tell application "System Events"
                    set \(app)Running to exists process "\(app)"
                end tell
                if \(app)Running then
                    try
                        tell application "\(app)"
                            set \(app)Volume to sound volume
                            set sound volume to 10
                        end tell
                    end try
                end if
                """
            }.joined(separator: "\n")
            let returnExpr = apps.map { "\"\($0)=\" & (\($0)Volume as text)" }.joined(separator: " & \";\" & ")
            let script = perAppScript + "\nreturn " + returnExpr
            let probe = runScript(script)
            guard !probe.failed else {
                Task { @MainActor in onFailure("Voqora needs Automation permission to duck \(apps.joined(separator: " or ")).") }
                return
            }
            var snapshot: [String: Int] = [:]
            for entry in probe.output?.split(separator: ";") ?? [] {
                let parts = entry.split(separator: "=", maxSplits: 1)
                guard parts.count == 2, let volume = Int(parts[1]), volume >= 0 else { continue }
                snapshot[String(parts[0])] = volume
            }
            savedVolumes = snapshot
            isDucked = !snapshot.isEmpty
            lastEmptyProbe = snapshot.isEmpty ? now() : nil
        }
    }

    func endDucking() {
        queue.async { [weak self] in
            guard let self, isDucked else { return }
            let volumes = savedVolumes
            savedVolumes = [:]
            isDucked = false
            for (application, volume) in volumes {
                _ = runScript("""
                try
                    tell application "\(application)" to set sound volume to \(volume)
                end try
                """)
            }
        }
    }

    #if DEBUG
        func waitUntilIdleForTesting() {
            queue.sync {}
        }
    #endif
}

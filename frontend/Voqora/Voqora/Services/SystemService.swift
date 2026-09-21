import AppKit
import Foundation

/// Opt-in media ducking which restores each player's *actual* prior volume.
/// The work stays on one queue because playback notifications can arrive in
/// rapid stop/start succession and AppleScript must not race its snapshots.
final class SystemService {
    private let queue = DispatchQueue(label: "com.himudigonda.Voqora.ducking")
    private var savedVolumes: [String: Int] = [:]
    private var isDucked = false

    /// Naming an uninstalled app anywhere in the AppleScript source pops "Where is <App>?" at compile time, even inside a never-executed `tell` block.
    private static let duckableApps: [(name: String, bundleID: String)] = [
        ("Music", "com.apple.Music"),
        ("Spotify", "com.spotify.client"),
    ]

    private func installedDuckableApps() -> [String] {
        Self.duckableApps
            .filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
            .map(\.name)
    }

    func beginDucking(onFailure: @escaping @MainActor (String) -> Void) {
        queue.async { [weak self] in
            guard let self, !self.isDucked else { return }
            let apps = installedDuckableApps()
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
            guard let appleScript = NSAppleScript(source: script) else {
                Task { @MainActor in onFailure("Voqora could not prepare media ducking.") }
                return
            }
            var error: NSDictionary?
            let result = appleScript.executeAndReturnError(&error)
            guard error == nil else {
                Task { @MainActor in onFailure("Voqora needs Automation permission to duck \(apps.joined(separator: " or ")).") }
                return
            }
            var snapshot: [String: Int] = [:]
            for entry in result.stringValue?.split(separator: ";") ?? [] {
                let parts = entry.split(separator: "=", maxSplits: 1)
                guard parts.count == 2, let volume = Int(parts[1]), volume >= 0 else { continue }
                snapshot[String(parts[0])] = volume
            }
            savedVolumes = snapshot
            isDucked = !snapshot.isEmpty
        }
    }

    func endDucking() {
        queue.async { [weak self] in
            guard let self, isDucked else { return }
            let volumes = savedVolumes
            savedVolumes = [:]
            isDucked = false
            for (application, volume) in volumes {
                let script = """
                try
                    tell application "\(application)" to set sound volume to \(volume)
                end try
                """
                guard let appleScript = NSAppleScript(source: script) else { continue }
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
            }
        }
    }
}

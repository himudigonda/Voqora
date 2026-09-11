import AppKit
import Foundation

/// Opt-in media ducking which restores each player's *actual* prior volume.
/// The work stays on one queue because playback notifications can arrive in
/// rapid stop/start succession and AppleScript must not race its snapshots.
final class SystemService {
    private let queue = DispatchQueue(label: "com.himudigonda.Voqora.ducking")
    private var savedVolumes: [String: Int] = [:]
    private var isDucked = false

    func beginDucking(onFailure: @escaping @MainActor (String) -> Void) {
        queue.async { [weak self] in
            guard let self, !self.isDucked else { return }
            let script = """
            set musicVolume to -1
            set spotifyVolume to -1
            tell application "System Events"
                set musicRunning to exists process "Music"
                set spotifyRunning to exists process "Spotify"
            end tell
            if musicRunning then
                try
                    tell application "Music"
                        set musicVolume to sound volume
                        set sound volume to 10
                    end tell
                end try
            end if
            if spotifyRunning then
                try
                    tell application "Spotify"
                        set spotifyVolume to sound volume
                        set sound volume to 10
                    end tell
                end try
            end if
            return (musicVolume as text) & "," & (spotifyVolume as text)
            """
            guard let appleScript = NSAppleScript(source: script) else {
                Task { @MainActor in onFailure("Voqora could not prepare media ducking.") }
                return
            }
            var error: NSDictionary?
            let result = appleScript.executeAndReturnError(&error)
            guard error == nil else {
                Task { @MainActor in onFailure("Voqora needs Automation permission to duck Music or Spotify.") }
                return
            }
            let volumes = result.stringValue?
                .split(separator: ",")
                .compactMap { Int($0) } ?? []
            var snapshot: [String: Int] = [:]
            if volumes.indices.contains(0), volumes[0] >= 0 { snapshot["Music"] = volumes[0] }
            if volumes.indices.contains(1), volumes[1] >= 0 { snapshot["Spotify"] = volumes[1] }
            self.savedVolumes = snapshot
            self.isDucked = !snapshot.isEmpty
        }
    }

    func endDucking() {
        queue.async { [weak self] in
            guard let self, self.isDucked else { return }
            let volumes = self.savedVolumes
            self.savedVolumes = [:]
            self.isDucked = false
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

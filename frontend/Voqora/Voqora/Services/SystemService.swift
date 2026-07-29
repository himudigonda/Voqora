import AppKit
import Foundation

class SystemService {
    func setMusicVolume(ducked: Bool) {
        let targetVol = ducked ? 10 : 85
        let script = """
        set targetVol to \(targetVol)

        -- Check for Music
        tell application "System Events" to set musicRunning to exists (processes where name is "Music")
        if musicRunning then
            run script "tell application \\"Music\\" to set sound volume to " & targetVol
        end if

        -- Check for Spotify
        tell application "System Events" to set spotifyRunning to exists (processes where name is "Spotify")
        if spotifyRunning then
            run script "tell application \\"Spotify\\" to set sound volume to " & targetVol
        end if
        """

        // Run in background to avoid UI blocking
        DispatchQueue.global(qos: .userInitiated).async {
            if let scriptObject = NSAppleScript(source: script) {
                var error: NSDictionary?
                scriptObject.executeAndReturnError(&error)
            }
        }
    }

    func requestPermissions() {
        // Accessibility
        // We only check the prompt option if we are NOT trusted.
        // If we are already trusted, we do nothing.
        // If we are not trusted, we check, forcing the prompt ONLY if the system hasn't already decided.

        let trusted = AXIsProcessTrusted()
        print("Accessibility Access: \(trusted)")

        if !trusted {
            // This will trigger the prompt if not already denied
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            AXIsProcessTrustedWithOptions(options as CFDictionary)
        }
    }
}

import AppKit
import SwiftUI

struct DictationEngineSettingsSection: View {
    @AppStorage(DictationPreferences.liveInsertionKey) private var livesInsertion = false
    @AppStorage(DictationPreferences.playsSoundsKey) private var playsSounds = true
    @AppStorage(DictationTrace.defaultsKey) private var savesDebugTraces = false

    var body: some View {
        SettingsSection(
            title: "While you dictate",
            footer: "Tap the shortcut to start and stop. Hold it to talk, and release to insert. Press Esc to cancel."
        ) {
            SettingsSwitchRow(
                title: "Insert as you speak",
                detail: "Pastes each finished phrase into your app while you talk. Works with Paste into App and skips Tidy with AI.",
                systemImage: "text.cursor",
                isOn: $livesInsertion
            )
            SettingsSwitchRow(
                title: "Play sounds",
                detail: "Short cues when dictation starts, stops and inserts, and when speech or an audiobook is ready.",
                systemImage: "speaker.wave.2",
                isOn: $playsSounds
            )
        }
        SettingsSection(title: "Troubleshooting") {
            #if !DEBUG
                SettingsSwitchRow(
                    title: "Save debug traces",
                    detail: "Records timing and word counts for each dictation on this Mac, never your words. Off by default.",
                    systemImage: "ladybug",
                    isOn: $savesDebugTraces
                )
            #endif
            SettingsButtonRow(
                title: "Debug Traces",
                detail: "Open the folder where Voqora keeps the most recent traces.",
                systemImage: "folder",
                buttonTitle: "Show Traces in Finder",
                action: showTracesInFinder
            )
        }
    }

    private func showTracesInFinder() {
        let directory = DictationTraceWriter.defaultDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }
}

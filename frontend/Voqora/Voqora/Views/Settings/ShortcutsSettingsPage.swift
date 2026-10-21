import KeyboardShortcuts
import SwiftUI

struct ShortcutsSettingsPage: View {
    @AppStorage(NowPlayingPreferences.respondToMediaKeysKey) private var respondToMediaKeys = true

    var body: some View {
        SettingsPage(.shortcuts) {
            SettingsSection(title: "Speaking", footer: "Shortcuts are global and work from any app.") {
                ShortcutRow(title: "Speak Selection", systemImage: "text.cursor", name: .playText)
                ShortcutRow(title: "Pause / Resume", systemImage: "playpause", name: .togglePause)
                ShortcutRow(title: "Stop Playback", systemImage: "stop", name: .stopText)
                ShortcutRow(title: "Speak Text on Screen", systemImage: "text.viewfinder", name: .speakScreenText)
                ShortcutRow(title: "Speak Clipboard", systemImage: "doc.on.clipboard", name: .speakClipboard)
                ShortcutRow(title: "Export to Desktop", systemImage: "square.and.arrow.down", name: .exportAudio)
            }
            SettingsSection(title: "Dictation and AI") {
                ShortcutRow(title: "Start / Finish Dictation", systemImage: "mic", name: .toggleDictation)
                ShortcutRow(title: "Paste Last Dictation", systemImage: "text.insert", name: .pasteLastDictation)
                ShortcutRow(title: "Summarize Selection and Speak", systemImage: "text.badge.checkmark", name: .summarizeSelection)
                ShortcutRow(title: "Translate Selection and Speak", systemImage: "character.bubble", name: .translateSelection)
            }
            SettingsSection(title: "Keyboard and headphones") {
                SettingsSwitchRow(
                    title: "Respond to Media Keys",
                    detail: "Play, pause and skip Voqora from your keyboard's media keys, headphone controls and Control Center.",
                    systemImage: "playpause.circle",
                    isOn: $respondToMediaKeys
                )
                SettingsButtonRow(
                    title: "Reset Shortcuts",
                    detail: "Restore every shortcut above to its default.",
                    systemImage: "arrow.counterclockwise",
                    buttonTitle: "Reset to Defaults",
                    action: resetShortcuts
                )
            }
        }
    }

    private func resetShortcuts() {
        for name in KeyboardShortcuts.Name.allCases {
            KeyboardShortcuts.reset(name)
        }
    }
}

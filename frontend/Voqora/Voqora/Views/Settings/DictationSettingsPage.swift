import SwiftUI

struct DictationSettingsPage: View {
    @AppStorage(DictationPreferences.allowsServerRecognitionKey) private var allowsServerRecognition = false
    @AppStorage(DictationPreferences.tidiesWithAIKey) private var tidiesWithAI = false

    var body: some View {
        SettingsPage(.dictation) {
            DictationEnginePicker()
            DictationPermissionRows()
            DictationCaptureSection()
            SettingsSection(title: "Cleanup") {
                SettingsSwitchRow(
                    title: "Tidy with AI",
                    detail: "Off by default. When on, each transcript goes to your AI provider to fix punctuation and filler words first. If that fails, Voqora inserts your original words.",
                    systemImage: "sparkles",
                    isOn: $tidiesWithAI
                )
            }
            DictationEngineSettingsSection()
            SettingsSection(title: "Privacy") {
                SettingsSwitchRow(
                    title: "Allow Server Recognition",
                    detail: "Off by default. When on, languages without on-device support send your audio to Apple to be transcribed.",
                    systemImage: "network",
                    isOn: $allowsServerRecognition
                )
            }
        }
    }
}

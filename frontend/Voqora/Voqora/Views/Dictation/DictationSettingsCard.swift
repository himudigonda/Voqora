import KeyboardShortcuts
import SwiftUI

struct DictationSettingsCard: View {
    @AppStorage(DictationPreferences.localeKey) private var localeIdentifier = ""
    @AppStorage(DictationPreferences.insertionModeKey) private var insertionMode: DictationInsertionMode = .paste
    @AppStorage(DictationPreferences.silenceTimeoutKey) private var silenceTimeout = DictationPreferences.defaultSilenceTimeout
    @AppStorage(DictationPreferences.allowsServerRecognitionKey) private var allowsServerRecognition = false
    @AppStorage(DictationPreferences.tidiesWithAIKey) private var tidiesWithAI = false
    @State private var localeOptions: [DictationLocaleOption] = []
    @State private var localeSupport: DictationLocaleSupport = .onDevice

    private var languageLabel: String {
        guard !localeIdentifier.isEmpty else { return "System Default" }
        return localeOptions.first { $0.id == localeIdentifier }?.name ?? localeIdentifier
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            SettingsSection(title: "Start and finish") {
                SettingsRowShell(title: "Shortcut", detail: "Press once to start listening and again to finish.") {
                    KeyboardShortcuts.Recorder(for: .toggleDictation)
                }
                SettingsPickerRow(
                    title: "Language",
                    detail: localeSupport.note(allowsServerRecognition: allowsServerRecognition),
                    valueLabel: languageLabel
                ) {
                    Button("System Default") { localeIdentifier = "" }
                    Divider()
                    ForEach(localeOptions) { option in
                        Button(option.name) { localeIdentifier = option.id }
                    }
                }
                SettingsPickerRow(
                    title: "Auto-Stop",
                    detail: "Stops listening after a pause of this length.",
                    valueLabel: DictationPreferences.silenceLabel(for: silenceTimeout)
                ) {
                    ForEach(DictationPreferences.silenceTimeoutOptions, id: \.self) { seconds in
                        Button(DictationPreferences.silenceLabel(for: seconds)) { silenceTimeout = seconds }
                    }
                }
            }
            SettingsSection(title: "After you speak") {
                SettingsPickerRow(title: "After Dictation", detail: insertionMode.detail, valueLabel: insertionMode.title) {
                    ForEach(DictationInsertionMode.allCases) { mode in
                        Button(mode.title) { insertionMode = mode }
                    }
                }
                SettingsSwitchRow(
                    title: "Tidy with AI",
                    detail: "Off by default. When on, each transcript goes to your AI provider to fix punctuation and filler words first. If that fails, Voqora inserts your original words.",
                    isOn: $tidiesWithAI
                )
            }
            SettingsSection(title: "Privacy") {
                SettingsSwitchRow(
                    title: "Allow Server Recognition",
                    detail: "Off by default. When on, languages without on-device support send your audio to Apple to be transcribed.",
                    isOn: $allowsServerRecognition
                )
            }
        }
        .onAppear(perform: loadOptions)
        .task(id: localeIdentifier) {
            localeSupport = DictationLocaleCatalog.support(forLocaleIdentifier: localeIdentifier.isEmpty ? nil : localeIdentifier)
        }
    }

    private func loadOptions() {
        localeOptions = DictationLocaleCatalog.supportedOptions()
        localeIdentifier = DictationLocaleCatalog.validatedSelection(localeIdentifier, among: localeOptions)
        silenceTimeout = DictationPreferences.silenceOption(closestTo: silenceTimeout)
    }
}

import KeyboardShortcuts
import SwiftUI

struct DictationCaptureSection: View {
    @AppStorage(DictationPreferences.localeKey) private var localeIdentifier = ""
    @AppStorage(DictationPreferences.insertionModeKey) private var insertionMode: DictationInsertionMode = .paste
    @AppStorage(DictationPreferences.silenceTimeoutKey) private var silenceTimeout = DictationPreferences.defaultSilenceTimeout
    @AppStorage(DictationPreferences.allowsServerRecognitionKey) private var allowsServerRecognition = false
    @State private var localeOptions: [DictationLocaleOption] = []
    @State private var localeSupport: DictationLocaleSupport = .onDevice

    private var localeLabel: String {
        localeOptions.first { $0.id == localeIdentifier }?.name ?? "System Default"
    }

    var body: some View {
        SettingsSection(title: "Capture") {
            SettingsRowShell(
                title: "Shortcut",
                detail: "Press once to start listening and again to finish.",
                systemImage: "keyboard"
            ) {
                KeyboardShortcuts.Recorder(for: .toggleDictation)
            }
            SettingsPickerRow(
                title: "Language",
                detail: localeSupport.note(allowsServerRecognition: allowsServerRecognition),
                systemImage: "globe",
                valueLabel: localeLabel
            ) {
                Picker("Language", selection: $localeIdentifier) {
                    Text("System Default").tag("")
                    Divider()
                    ForEach(localeOptions) { option in
                        Text(option.name).tag(option.id)
                    }
                }
                .pickerStyle(.inline)
            }
            SettingsPickerRow(
                title: "Auto-Stop",
                detail: "Stops listening after a pause of this length.",
                systemImage: "timer",
                valueLabel: DictationPreferences.silenceLabel(for: silenceTimeout)
            ) {
                Picker("Auto-Stop", selection: $silenceTimeout) {
                    ForEach(DictationPreferences.silenceTimeoutOptions, id: \.self) { seconds in
                        Text(DictationPreferences.silenceLabel(for: seconds)).tag(seconds)
                    }
                }
                .pickerStyle(.inline)
            }
            SettingsSegmentedRow(
                title: "After Dictation",
                detail: insertionMode.detail,
                systemImage: "text.insert",
                selection: $insertionMode,
                options: Array(DictationInsertionMode.allCases),
                label: { $0.title }
            )
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

struct DictationPermissionRows: View {
    @AppStorage(DictationPreferences.engineKey) private var engine: DictationEngineChoice = .apple

    var kinds: [PermissionKind] {
        Self.kinds(for: engine)
    }

    var body: some View {
        SettingsSection(
            title: "Permissions",
            footer: "Without Accessibility, dictation is copied to the clipboard instead of pasted into the app you are using."
        ) {
            ForEach(kinds) { kind in
                PermissionRow(kind: kind)
            }
        }
    }

    static func kinds(for engine: DictationEngineChoice) -> [PermissionKind] {
        switch engine {
        case .apple: [.microphone, .speechRecognition, .accessibility]
        case .parakeet, .bark, .barkClean: [.microphone, .accessibility]
        }
    }
}

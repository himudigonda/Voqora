import KeyboardShortcuts
import SwiftUI

struct DictationSettingsCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    @AppStorage(DictationPreferences.localeKey) private var localeIdentifier = ""
    @AppStorage(DictationPreferences.insertionModeKey) private var insertionMode: DictationInsertionMode = .paste
    @AppStorage(DictationPreferences.silenceTimeoutKey) private var silenceTimeout = DictationPreferences.defaultSilenceTimeout
    @AppStorage(DictationPreferences.allowsServerRecognitionKey) private var allowsServerRecognition = false
    @State private var localeOptions: [DictationLocaleOption] = []
    @State private var localeSupport: DictationLocaleSupport = .onDevice

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            DictationSettingRow(title: "Shortcut", icon: "keyboard") {
                KeyboardShortcuts.Recorder(for: .toggleDictation)
            }
            caption("Press once to start listening and again to finish.")

            Divider()

            DictationSettingRow(title: "Language", icon: "globe") {
                Picker("Language", selection: $localeIdentifier) {
                    Text("System Default").tag("")
                    Divider()
                    ForEach(localeOptions) { option in
                        Text(option.name).tag(option.id)
                    }
                }
                .labelsHidden()
                .frame(width: 240)
            }
            caption(localeSupport.note(allowsServerRecognition: allowsServerRecognition))

            Divider()

            DictationSettingRow(title: "After Dictation", icon: "text.cursor") {
                Picker("After Dictation", selection: $insertionMode) {
                    ForEach(DictationInsertionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
            }
            caption(insertionMode.detail)

            Divider()

            DictationSettingRow(title: "Auto-Stop", icon: "timer") {
                Picker("Auto-Stop", selection: $silenceTimeout) {
                    ForEach(DictationPreferences.silenceTimeoutOptions, id: \.self) { seconds in
                        Text(DictationPreferences.silenceLabel(for: seconds)).tag(seconds)
                    }
                }
                .labelsHidden()
                .frame(width: 240)
            }
            caption("Stops listening after a pause of this length.")

            Divider()

            Toggle(isOn: $allowsServerRecognition) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow Server Recognition")
                        .font(vm.font(.rowTitle))
                    Text("Off by default. When on, languages without on-device support send your audio to Apple to be transcribed.")
                        .font(vm.font(.rowSubtitle))
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
        }
        .padding(20)
        .voqoraSurface(.raised, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xLarge, style: .continuous))
        .onAppear(perform: loadOptions)
        .task(id: localeIdentifier) {
            localeSupport = DictationLocaleCatalog.support(forLocaleIdentifier: localeIdentifier.isEmpty ? nil : localeIdentifier)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(vm.font(.rowSubtitle))
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadOptions() {
        localeOptions = DictationLocaleCatalog.supportedOptions()
        localeIdentifier = DictationLocaleCatalog.validatedSelection(localeIdentifier, among: localeOptions)
        silenceTimeout = DictationPreferences.silenceOption(closestTo: silenceTimeout)
    }
}

struct DictationSettingRow<Control: View>: View {
    @EnvironmentObject var vm: DashboardViewModel
    let title: String
    let icon: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack {
            Label(title, systemImage: icon)
                .font(vm.font(.rowTitle))
            Spacer()
            control
        }
    }
}

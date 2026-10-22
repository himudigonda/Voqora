import SwiftUI

struct SpeechSettingsPage: View {
    @EnvironmentObject var vm: DashboardViewModel
    var body: some View {
        SettingsPage(.speech) {
            SpeakingVoiceSections(includesVolume: true)
            SettingsSection(title: "Voices") {
                SettingsNavigationRow(
                    title: "Manage voices and pronunciations",
                    detail: "Browse voices, build blends, and fix how words are spoken.",
                    systemImage: "waveform.badge.mic"
                ) {
                    vm.selectedTab = VoicesPage.myVoices.tab
                }
            }
            SettingsSection(title: "Audio environment") {
                SettingsSwitchRow(
                    title: "Music Ducking",
                    detail: "Lowers Music and Spotify while Voqora speaks, then restores their volume. macOS may ask for Automation permission.",
                    systemImage: "music.note",
                    isOn: $vm.enableDucking
                )
                SettingsSwitchRow(
                    title: "Sanitize Links",
                    detail: "Removes complex URLs and handles from spoken text.",
                    systemImage: "link",
                    isOn: $vm.cleanURLs
                )
            }
        }
    }
}

struct MingDeliverySettingsSection: View {
    @EnvironmentObject var vm: DashboardViewModel
    @ObservedObject var engineStore: SpeechEngineStore

    @MainActor
    init(engineStore: SpeechEngineStore? = nil) {
        self.engineStore = engineStore ?? .shared
    }

    private var showsDialect: Bool {
        engineStore.voice(id: vm.selectedVoice)?.isChinese ?? false
    }

    private var dialectReplacesOthers: Bool {
        showsDialect && !vm.mingDialect.isEmpty
    }

    private var footer: String {
        let hint = MingParalinguisticTags.hint
        return dialectReplacesOthers ? "Dialect replaces the other delivery settings. " + hint : hint
    }

    var body: some View {
        SettingsSection(title: "Ming delivery", footer: footer) {
            SettingsPickerRow(
                title: "Emotion",
                systemImage: "face.smiling",
                valueLabel: MingEmotion(rawValue: vm.mingEmotion)?.label ?? "Default"
            ) {
                Picker("Emotion", selection: $vm.mingEmotion) {
                    Text("Default").tag("")
                    ForEach(MingEmotion.allCases, id: \.rawValue) { emotion in
                        Text(emotion.label).tag(emotion.rawValue)
                    }
                }
                .pickerStyle(.inline)
            }
            .disabled(dialectReplacesOthers)
            SettingsRowShell(title: "Style", detail: "Describe how it should sound.", systemImage: "wand.and.stars") {
                HStack(spacing: 8) {
                    TextField("Style", text: $vm.mingStyle, prompt: Text("Warm and unhurried"))
                        .labelsHidden()
                        .settingsField(width: 240)
                        .onChange(of: vm.mingStyle) { _, value in
                            let capped = SpeechDelivery.cappedStyle(value)
                            if capped != value {
                                vm.mingStyle = capped
                            }
                        }
                        .accessibilityLabel("Delivery style")
                    TonalMenu(valueLabel: "Presets") {
                        ForEach(MingStylePreset.allCases) { preset in
                            Button(preset.rawValue) { vm.mingStyle = preset.rawValue }
                        }
                        Divider()
                        Button("Clear") { vm.mingStyle = "" }
                    }
                }
            }
            .disabled(dialectReplacesOthers)
            SettingsSegmentedRow(
                title: "Pace",
                selection: $vm.mingPace,
                options: MingPace.allCases.map { $0 == .normal ? "" : $0.rawValue },
                label: { $0.isEmpty ? "Normal" : $0.capitalized }
            )
            .disabled(dialectReplacesOthers)
            SettingsSegmentedRow(
                title: "Pitch",
                selection: $vm.mingPitch,
                options: MingPitch.allCases.map { $0 == .normal ? "" : $0.rawValue },
                label: { $0.isEmpty ? "Normal" : $0.capitalized }
            )
            .disabled(dialectReplacesOthers)
            if showsDialect {
                SettingsPickerRow(
                    title: "Dialect",
                    systemImage: "globe",
                    valueLabel: MingDialect(rawValue: vm.mingDialect)?.label ?? "Standard"
                ) {
                    Picker("Dialect", selection: $vm.mingDialect) {
                        Text("Standard").tag("")
                        ForEach(MingDialect.allCases, id: \.rawValue) { dialect in
                            Text(dialect.label).tag(dialect.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                }
            }
        }
    }
}

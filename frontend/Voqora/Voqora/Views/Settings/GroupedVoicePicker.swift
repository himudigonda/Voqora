import SwiftUI

struct GroupedVoicePicker: View {
    let title: String
    @Binding var selection: String
    var includesBlends = true
    @ObservedObject private var blendStore = VoiceBlendStore.shared
    @ObservedObject private var engineStore = SpeechEngineStore.shared

    private var showsUnknownBlend: Bool {
        includesBlends && VoiceBlendRules.isBlendID(selection) && blendStore.blend(id: selection) == nil
    }

    private var showsUnavailableSupertonicVoice: Bool {
        includesBlends && SpeechEngineID.isSupertonicVoice(selection) && !engineStore.supertonicVoices.contains { $0.id == selection }
    }

    private var showsUnavailableMingVoice: Bool {
        includesBlends && SpeechEngineID.isMingVoice(selection) && !engineStore.mingVoices.contains { $0.id == selection }
    }

    private func mingVoices(in group: MingVoiceGroup) -> [SpeechEngineVoice] {
        engineStore.mingVoices.filter { $0.mingGroup == group }
    }

    private var selectionName: String {
        if VoiceBlendRules.isBlendID(selection) {
            return blendStore.displayName(for: selection)
        }
        return DashboardViewModel.voiceName(for: selection)
    }

    var body: some View {
        TonalMenu(valueLabel: selectionName, title: title) {
            Picker(title, selection: $selection) {
                options
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    @ViewBuilder
    private var options: some View {
        if includesBlends, !blendStore.blends.isEmpty || showsUnknownBlend {
            Section("My Voices") {
                ForEach(blendStore.blends) { blend in
                    Text(blend.name).tag(blend.id)
                }
                if showsUnknownBlend {
                    Text(blendStore.displayName(for: selection)).tag(selection)
                }
            }
        }
        if includesBlends, !engineStore.supertonicVoices.isEmpty || showsUnavailableSupertonicVoice {
            Section("Supertonic") {
                ForEach(engineStore.supertonicVoices) { voice in
                    Text(voice.name).tag(voice.id)
                }
                if showsUnavailableSupertonicVoice {
                    Text(DashboardViewModel.voiceName(for: selection)).tag(selection)
                }
            }
        }
        if includesBlends {
            ForEach(MingVoiceGroup.allCases, id: \.self) { group in
                let voices = mingVoices(in: group)
                if !voices.isEmpty {
                    Section(group.title) {
                        ForEach(voices) { voice in
                            Text(voice.name).tag(voice.id)
                        }
                    }
                }
            }
            if showsUnavailableMingVoice {
                Section("Ming") {
                    Text(DashboardViewModel.voiceName(for: selection)).tag(selection)
                }
            }
        }
        ForEach(DashboardViewModel.languageGroups) { group in
            Section(group.beta ? "\(group.id) (Beta)" : group.id) {
                ForEach(group.voices) { voice in
                    Text(voice.display).tag(voice.id)
                }
            }
        }
    }
}

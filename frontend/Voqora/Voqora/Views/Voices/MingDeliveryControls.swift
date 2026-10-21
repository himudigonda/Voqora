import SwiftUI

struct MingDeliveryControls: View {
    @EnvironmentObject var vm: DashboardViewModel
    @ObservedObject var engineStore: SpeechEngineStore

    @MainActor
    init(engineStore: SpeechEngineStore? = nil) {
        self.engineStore = engineStore ?? .shared
    }

    private var voice: SpeechEngineVoice? {
        engineStore.voice(id: vm.selectedVoice)
    }

    private var showsDialect: Bool {
        voice?.isChinese ?? false
    }

    private var dialectReplacesOthers: Bool {
        showsDialect && !vm.mingDialect.isEmpty
    }

    var body: some View {
        Picker("Emotion", selection: $vm.mingEmotion) {
            Text("Default").tag("")
            ForEach(MingEmotion.allCases, id: \.rawValue) { emotion in
                Text(emotion.label).tag(emotion.rawValue)
            }
        }
        .disabled(dialectReplacesOthers)

        LabeledContent("Style") {
            HStack(spacing: DesignTokens.Spacing.sm) {
                TextField("Style", text: $vm.mingStyle, prompt: Text("Describe how it should sound"))
                    .labelsHidden()
                    .frame(minWidth: 220)
                    .onChange(of: vm.mingStyle) { _, value in
                        let capped = SpeechDelivery.cappedStyle(value)
                        if capped != value {
                            vm.mingStyle = capped
                        }
                    }
                    .accessibilityLabel("Delivery style")
                Menu("Presets") {
                    ForEach(MingStylePreset.allCases) { preset in
                        Button(preset.rawValue) { vm.mingStyle = preset.rawValue }
                    }
                    Divider()
                    Button("Clear") { vm.mingStyle = "" }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .disabled(dialectReplacesOthers)

        Picker("Pace", selection: $vm.mingPace) {
            ForEach(MingPace.allCases, id: \.rawValue) { pace in
                Text(pace.label).tag(pace == .normal ? "" : pace.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .disabled(dialectReplacesOthers)

        Picker("Pitch", selection: $vm.mingPitch) {
            ForEach(MingPitch.allCases, id: \.rawValue) { pitch in
                Text(pitch.label).tag(pitch == .normal ? "" : pitch.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .disabled(dialectReplacesOthers)

        if showsDialect {
            Picker("Dialect", selection: $vm.mingDialect) {
                Text("Standard").tag("")
                ForEach(MingDialect.allCases, id: \.rawValue) { dialect in
                    Text(dialect.label).tag(dialect.rawValue)
                }
            }
        }

        if dialectReplacesOthers {
            Text("Dialect replaces the other delivery settings.")
                .font(vm.font(.rowSubtitle))
                .foregroundStyle(.secondary)
        }

        Text(MingParalinguisticTags.hint)
            .font(vm.font(.rowSubtitle))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

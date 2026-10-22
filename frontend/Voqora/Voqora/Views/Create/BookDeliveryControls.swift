import SwiftUI

struct BookDeliveryControls: View {
    @Binding var delivery: SpeechDelivery
    let showsDialect: Bool

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    private var dialectReplacesOthers: Bool {
        showsDialect && delivery.dialect != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.card) {
            labeled("Emotion", isEnabled: !dialectReplacesOthers) {
                FlowLayout {
                    FilterChip(title: "Default", isSelected: delivery.emotion == nil) { delivery.emotion = nil }
                    ForEach(MingEmotion.allCases, id: \.rawValue) { emotion in
                        FilterChip(title: emotion.label, isSelected: delivery.emotion == emotion) {
                            delivery.emotion = emotion
                        }
                    }
                }
            }
            labeled("Style", isEnabled: !dialectReplacesOthers) { styleField }
            HStack(alignment: .top, spacing: Theme.Space.section) {
                labeled("Pace", isEnabled: !dialectReplacesOthers) {
                    SegmentedTabs(
                        selection: Binding(get: { delivery.pace ?? .normal }, set: { delivery.pace = $0 == .normal ? nil : $0 }),
                        options: MingPace.allCases,
                        title: { $0.label }
                    )
                }
                labeled("Pitch", isEnabled: !dialectReplacesOthers) {
                    SegmentedTabs(
                        selection: Binding(get: { delivery.pitch ?? .normal }, set: { delivery.pitch = $0 == .normal ? nil : $0 }),
                        options: MingPitch.allCases,
                        title: { $0.label }
                    )
                }
            }
            if showsDialect {
                labeled("Dialect") {
                    SegmentedTabs(
                        selection: $delivery.dialect,
                        options: [nil] + MingDialect.allCases.map(Optional.some),
                        title: { $0?.label ?? "Standard" }
                    )
                }
            }
            if dialectReplacesOthers {
                Text("Dialect replaces the other delivery settings.")
                    .voqoraFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            Text(MingParalinguisticTags.hint)
                .voqoraFont(.bodySmall)
                .foregroundStyle(theme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private var styleField: some View {
        HStack(spacing: Theme.Space.item) {
            TextField("Describe how it should sound", text: styleBinding)
                .textFieldStyle(.plain)
                .voqoraFont(.body)
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(theme.surfaceContainerHigh, in: Capsule())
                .accessibilityLabel("Delivery style")
            Menu {
                ForEach(MingStylePreset.allCases) { preset in
                    Button(preset.rawValue) { delivery.style = preset.rawValue }
                }
                Divider()
                Button("Clear") { delivery.style = nil }
            } label: {
                Text("Presets")
                    .voqoraFont(.label)
                    .foregroundStyle(theme.onPrimaryContainer)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 32)
                    .background(theme.primaryContainer.opacity(0.65), in: Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var styleBinding: Binding<String> {
        Binding(
            get: { delivery.style ?? "" },
            set: { delivery.style = $0.isEmpty ? nil : SpeechDelivery.cappedStyle($0) }
        )
    }

    private func labeled(_ title: String, isEnabled: Bool = true, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .voqoraFont(.label)
                .foregroundStyle(theme.onSurfaceVariant)
            content()
        }
        .opacity(isEnabled ? 1 : 0.5)
        .allowsHitTesting(isEnabled)
    }
}

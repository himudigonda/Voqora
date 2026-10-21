import SwiftUI

struct VoiceTextField: View {
    let title: String
    var prompt = ""
    @Binding var text: String
    var lines: ClosedRange<Int> = 1 ... 1

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        VoiceFormField(title: title) {
            TextField(prompt, text: $text, axis: .vertical)
                .lineLimit(lines)
                .textFieldStyle(.plain)
                .font(vm.font(.body))
                .foregroundStyle(theme.onSurface)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.surfaceContainerHighest, in: RoundedRectangle(cornerRadius: Theme.Shape.sm, style: .continuous))
                .accessibilityLabel(title)
        }
    }
}

struct VoiceFormField<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(vm.font(.label))
                .foregroundStyle(theme.onSurfaceVariant)
            content
        }
    }
}

struct VoiceLanguageMenu: View {
    @Binding var selection: String
    let options: [String]

    var body: some View {
        VoiceFormField(title: "Language") {
            Menu {
                ForEach(options, id: \.self) { code in
                    Button(MingVoiceLanguage.label(code)) { selection = code }
                }
            } label: {
                TonalMenuLabel(text: MingVoiceLanguage.label(selection), systemImage: "globe")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Language")
            .accessibilityValue(MingVoiceLanguage.label(selection))
        }
    }
}

struct VoiceProgressNote: View {
    let text: String

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        HStack(spacing: Theme.Space.item) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(vm.font(.body))
                .foregroundStyle(theme.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.item + 4)
        .background(theme.surfaceContainer, in: RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous))
    }
}

struct VoiceResultRow: View {
    let voice: SpeechEngineVoice
    @ObservedObject var model: MingVoiceStudioModel

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        HStack(spacing: Theme.Space.item) {
            VoiceInitialsAvatar(name: voice.name)
            VStack(alignment: .leading, spacing: 2) {
                Text(voice.name)
                    .font(vm.font(.titleSmall))
                    .foregroundStyle(theme.onSurface)
                Text("Saved to My Voices. Play a sample to hear it.")
                    .font(vm.font(.bodySmall))
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            Spacer(minLength: 0)
            StatusChip(text: MyVoiceItems.kind(of: voice).title, kind: .success, systemImage: "checkmark")
            VoicePlayButton(
                name: voice.name,
                isPlaying: model.playingID == voice.id,
                isLoading: model.loadingSampleID == voice.id,
                isEnabled: vm.isBackendOnline
            ) {
                model.toggleSample(voice)
            }
        }
        .padding(Theme.Space.item + 4)
        .background(theme.surfaceContainer, in: RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

struct WrapLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        return arrange(width: width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}

struct MingInstallGate<Content: View>: View {
    @ObservedObject var store: SpeechEngineStore
    @ViewBuilder var content: Content

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    private var ming: SpeechEngine? {
        store.engine(id: SpeechEngineID.ming)
    }

    var body: some View {
        if ming?.installed == true {
            content
        } else if let ming {
            VStack(alignment: .leading, spacing: Theme.Space.item) {
                Text("This needs the Ming engine. Install it once, then come back to finish.")
                    .font(vm.font(.body))
                    .foregroundStyle(theme.onSurfaceVariant)
                EngineInstallCard(engine: ming) {
                    Task { await store.install(ming.id) }
                }
                if let message = store.actionError {
                    VoicesBanner(message: message)
                }
            }
            .padding(.bottom, Theme.Space.unit)
        } else {
            VoicesLoadingRow(text: vm.isBackendOnline ? "Checking the Ming engine…" : "Voqora is still starting.")
        }
    }
}

extension SpeechEngineStore {
    var mingNeedsInstall: Bool {
        engine(id: SpeechEngineID.ming)?.installed != true
    }

    var mingSizeLabel: String {
        engine(id: SpeechEngineID.ming)?.sizeDescription ?? "3.5 GB"
    }
}

import SwiftUI

struct StudioView: View {
    static let tab = "studio"

    @EnvironmentObject var studio: StudioViewModel
    @EnvironmentObject var vm: DashboardViewModel

    var body: some View {
        Group {
            switch studio.route {
            case .home:
                StudioHomeView(drafts: studio.drafts)
            case .newPodcast:
                if let model = studio.briefModel {
                    NewPodcastView(model: model)
                } else {
                    StudioHomeView(drafts: studio.drafts)
                }
            case .editor:
                if let editor = studio.editor {
                    PodcastScriptEditorView(editor: editor)
                        .id(editor.id)
                } else {
                    StudioHomeView(drafts: studio.drafts)
                }
            }
        }
        .navigationTitle("Studio")
        .task(id: vm.isBackendOnline) {
            if vm.isBackendOnline {
                await studio.loadBlends()
            }
        }
        .onDisappear { studio.previewer.stop() }
    }
}

struct StudioBanner: View {
    @EnvironmentObject var vm: DashboardViewModel
    let message: String
    var tint: Color?
    var systemImage = "exclamationmark.triangle.fill"
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            Image(systemName: systemImage)
                .foregroundStyle(resolvedTint)
                .accessibilityHidden(true)
            Text(message)
                .font(vm.font(.rowTitle))
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(vm.font(.rowSubtitle))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.textSecondary)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(DesignTokens.Layout.cardInset)
        .background(resolvedTint.opacity(0.12), in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var resolvedTint: Color {
        tint ?? Palette.warning
    }
}

struct StudioPageHeader<Trailing: View>: View {
    @EnvironmentObject var vm: DashboardViewModel
    let title: String
    let subtitle: String
    var onBack: (() -> Void)?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: 6) {
                if let onBack {
                    Button(action: onBack) {
                        Label("Studio", systemImage: "chevron.left")
                            .font(vm.font(.rowTitle))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.textSecondary)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Back to Studio")
                }
                Text(title)
                    .font(vm.font(.pageTitle))
                    .foregroundStyle(Palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(vm.appFont(size: 14))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DesignTokens.Spacing.md)
            trailing
        }
    }
}

struct StudioVoicePicker: View {
    let title: String
    @Binding var selection: String
    let groups: [StudioVoiceGroup]
    let blends: [PodcastVoiceBlend]

    var body: some View {
        Picker(title, selection: $selection) {
            if !containsSelection {
                Text(StudioVoiceCatalog.displayName(for: selection, blends: blends)).tag(selection)
            }
            ForEach(groups) { group in
                Section(group.id) {
                    ForEach(group.voices) { voice in
                        Text(voice.name).tag(voice.id)
                    }
                }
            }
        }
        .labelsHidden()
        .accessibilityLabel(title)
    }

    private var containsSelection: Bool {
        groups.contains { group in group.voices.contains { $0.id == selection } }
    }
}

struct StudioPreviewButton: View {
    @ObservedObject var previewer: StudioVoicePreviewer
    let voice: String
    let speakerName: String

    var body: some View {
        Button {
            previewer.toggle(voice: voice)
        } label: {
            Group {
                if previewer.loadingVoice == voice {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: previewer.playingVoice == voice ? "stop.fill" : "play.fill")
                }
            }
            .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .disabled(voice.isEmpty)
        .help(previewer.playingVoice == voice ? "Stop preview" : "Preview this voice")
        .accessibilityLabel(previewer.playingVoice == voice ? "Stop preview for \(speakerName)" : "Preview voice for \(speakerName)")
    }
}

import SwiftUI

nonisolated enum VoiceAvatarStyle {
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).filter { $0.first?.isLetter == true || $0.first?.isNumber == true }
        let letters = words.prefix(2).compactMap(\.first)
        return String(letters).uppercased()
    }

    static func hue(for name: String) -> Double {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in name.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return Double(hash % 360) / 360
    }
}

struct VoiceInitialsAvatar: View {
    let name: String
    var size: CGFloat = 44

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let hue = VoiceAvatarStyle.hue(for: name)
        let isDark = colorScheme == .dark
        Text(VoiceAvatarStyle.initials(name))
            .font(vm.font(.titleSmall))
            .foregroundStyle(Color(hue: hue, saturation: isDark ? 0.35 : 0.6, brightness: isDark ? 0.95 : 0.36))
            .frame(width: size, height: size)
            .background(Color(hue: hue, saturation: isDark ? 0.45 : 0.28, brightness: isDark ? 0.42 : 0.92), in: Circle())
            .accessibilityHidden(true)
    }
}

struct TonalMenuLabel: View {
    let text: String
    var systemImage: String?
    var minWidth: CGFloat?

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
            }
            Text(text)
                .font(vm.font(.label))
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .semibold))
        }
        .frame(minWidth: minWidth, alignment: .leading)
        .foregroundStyle(theme.onPrimaryContainer)
        .padding(.horizontal, 14)
        .frame(minHeight: 32)
        .background(theme.primaryContainer.opacity(0.65), in: Capsule())
        .contentShape(Capsule())
    }
}

struct VoiceUseMenu: View {
    let voiceID: String
    let name: String

    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel

    private var isSpeechVoice: Bool {
        vm.selectedVoice == voiceID
    }

    private var isBookVoice: Bool {
        bookVM.defaultBookVoice == voiceID
    }

    var body: some View {
        Menu {
            Button {
                vm.selectedVoice = voiceID
            } label: {
                if isSpeechVoice {
                    Label("For Speech", systemImage: "checkmark")
                } else {
                    Text("For Speech")
                }
            }
            .disabled(isSpeechVoice)
            Button {
                bookVM.defaultBookVoice = voiceID
            } label: {
                if isBookVoice {
                    Label("For Audiobooks", systemImage: "checkmark")
                } else {
                    Text("For Audiobooks")
                }
            }
            .disabled(isBookVoice)
        } label: {
            TonalMenuLabel(text: "Use")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Use \(name) for speech or audiobooks")
        .accessibilityLabel("Use \(name)")
    }
}

struct VoiceDefaultChips: View {
    let voiceID: String
    var compact = false

    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel

    var body: some View {
        if vm.selectedVoice == voiceID {
            chip(text: "Speech default", systemImage: "waveform")
        }
        if bookVM.defaultBookVoice == voiceID {
            chip(text: "Audiobook default", systemImage: "books.vertical")
        }
    }

    @ViewBuilder
    private func chip(text: String, systemImage: String) -> some View {
        if compact {
            VoiceIconChip(systemImage: systemImage, help: text)
        } else {
            StatusChip(text: text, kind: .info, systemImage: "checkmark")
        }
    }
}

struct VoiceIconChip: View {
    let systemImage: String
    let help: String

    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.onPrimaryContainer)
            .frame(width: 26, height: 22)
            .background(theme.primaryContainer.opacity(0.65), in: Capsule())
            .help(help)
            .accessibilityLabel(help)
    }
}

struct VoicePlayButton: View {
    let name: String
    let isPlaying: Bool
    let isLoading: Bool
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(width: 40, height: 40)
                .accessibilityLabel("Loading \(name) sample")
        } else {
            Button(action: action) {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.voqoraIconTonal)
            .disabled(!isEnabled)
            .help(isPlaying ? "Stop \(name) sample" : "Play \(name) sample")
            .accessibilityLabel(isPlaying ? "Stop \(name) sample" : "Play \(name) sample")
        }
    }
}

struct VoicesSectionHeader: View {
    let title: String
    var trailing: String?

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.item) {
            Text(title)
                .font(vm.font(.titleSmall))
                .foregroundStyle(theme.primary)
                .accessibilityAddTraits(.isHeader)
            if let trailing {
                Text(trailing)
                    .font(vm.font(.bodySmall))
                    .foregroundStyle(theme.onSurfaceMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.unit)
    }
}

struct VoicesBanner: View {
    let message: String
    var systemImage = "exclamationmark.triangle.fill"
    var isError = true
    var actionTitle: String?
    var action: (() -> Void)?

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        let tint = isError ? theme.danger : theme.success
        HStack(spacing: Theme.Space.item) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(message)
                .font(vm.font(.body))
                .foregroundStyle(theme.onSurface)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.voqoraTonal)
            }
        }
        .padding(Theme.Space.item + 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous))
    }
}

struct VoicesLoadingRow: View {
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
    }
}

nonisolated enum EngineInstallCopy {
    static func strength(forEngine id: String) -> String {
        switch id {
        case SpeechEngineID.supertonic: "Fast, lightweight voices that sound natural and run entirely on your Mac."
        case SpeechEngineID.ming: "Expressive voices with emotion and style control. Also lets you design or clone your own."
        default: "Adds more voices to Voqora."
        }
    }

    static func caption(for engine: SpeechEngine) -> String {
        let strength = strength(forEngine: engine.id)
        guard !engine.voices.isEmpty else { return strength }
        return "\(strength) Adds \(engine.voices.count) voices."
    }
}

struct EngineInstallCard: View {
    let engine: SpeechEngine
    let install: () -> Void

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        VoqoraCard {
            HStack(alignment: .center, spacing: Theme.Space.card) {
                ListItemIcon(systemImage: "arrow.down.circle")
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Install \(engine.name)")
                            .font(vm.font(.titleSmall))
                            .foregroundStyle(theme.onSurface)
                        if let size = engine.sizeDescription {
                            StatusChip(text: size)
                        }
                        if !engine.license.isEmpty {
                            StatusChip(text: engine.license)
                        }
                    }
                    Text(EngineInstallCopy.caption(for: engine))
                        .font(vm.font(.bodySmall))
                        .foregroundStyle(theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                    if let notice = engine.trimmedNotice {
                        Label(notice, systemImage: "hourglass")
                            .font(vm.font(.bodySmall))
                            .foregroundStyle(theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let error = engine.error, !engine.downloading {
                        Text(error)
                            .font(vm.font(.bodySmall))
                            .foregroundStyle(theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Theme.Space.item)
                trailing
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if engine.downloading {
            HStack(spacing: 10) {
                ProgressView(value: engine.clampedProgress)
                    .tint(theme.primary)
                    .frame(width: 110)
                Text(SpeechEngineRowText.percent(engine.progress))
                    .font(vm.font(.label).monospacedDigit())
                    .foregroundStyle(theme.primary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Downloading \(engine.name)")
            .accessibilityValue(SpeechEngineRowText.percent(engine.progress))
        } else {
            Button(action: install) {
                Label("Install", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.voqoraFilled)
            .disabled(!vm.isBackendOnline)
            .accessibilityLabel("Install \(engine.name)")
        }
    }
}

extension View {
    func voqoraSheetContent(_ vm: DashboardViewModel) -> some View {
        environmentObject(vm).voqoraTheme()
    }
}

struct PageActionsMenu<Content: View>: View {
    var label = "More actions"
    @ViewBuilder var content: Content

    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.onPrimaryContainer)
                .frame(width: 40, height: 40)
                .background(theme.primaryContainer.opacity(0.65), in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(label)
        .accessibilityLabel(label)
    }
}

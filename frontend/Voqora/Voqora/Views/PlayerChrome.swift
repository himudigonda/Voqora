import SwiftUI

struct PlayerTitle: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    let title: String
    let subtitle: String
    var byline: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(vm.font(.headline))
                .foregroundStyle(theme.onSurface)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .help(title)
            if let byline {
                Text(byline)
                    .font(vm.font(.label))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .lineLimit(1)
                    .help(byline)
            }
            Text(subtitle)
                .font(vm.font(.body))
                .foregroundStyle(theme.onSurfaceVariant)
                .lineLimit(1)
                .contentTransition(.opacity)
                .animation(Theme.Motion.selection, value: subtitle)
                .help(subtitle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PlayerPlayButton: View {
    @Environment(\.voqoraTheme) private var theme
    let isPlaying: Bool
    let isLoading: Bool
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(theme.primary)
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(theme.onPrimary)
                } else {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: size * 0.38, weight: .bold))
                        .foregroundStyle(theme.onPrimary)
                        .offset(x: isPlaying ? 0 : size * 0.03)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
        .help(isPlaying ? "Pause" : "Play")
    }
}

struct TransportGlyph: View {
    @Environment(\.voqoraTheme) private var theme
    let systemName: String
    let label: String
    var size: CGFloat = 18
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(theme.onSurface)
                .frame(width: size * 2.2, height: size * 2.2)
                .background(theme.onSurface.opacity(hovering ? 0.08 : 0), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleButtonStyle())
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: hovering)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct PressScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(Theme.Motion.selection, value: configuration.isPressed)
    }
}

struct PlayerCircleButton: View {
    let systemName: String
    let label: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PlayerCircleIcon(systemName: systemName)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct PlayerCircleMenu<Content: View>: View {
    let systemName: String
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu(content: content) {
            PlayerCircleIcon(systemName: systemName)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct PlayerCircleIcon: View {
    @Environment(\.voqoraTheme) private var theme
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(theme.onPrimaryContainer)
            .frame(width: 32, height: 32)
            .background(theme.primaryContainer.opacity(0.65), in: Circle())
            .contentShape(Circle())
    }
}

struct PlayerActionLabel<Icon: View, Caption: View>: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    var isActive = false
    let icon: Icon
    let caption: Caption

    init(isActive: Bool = false, @ViewBuilder icon: () -> Icon, @ViewBuilder caption: () -> Caption) {
        self.isActive = isActive
        self.icon = icon()
        self.caption = caption()
    }

    var body: some View {
        VStack(spacing: 6) {
            icon
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(theme.onPrimaryContainer)
                .frame(width: 60, height: 36)
                .background(isActive ? theme.primaryContainer : theme.primaryContainer.opacity(0.55), in: Capsule())
            caption
                .font(vm.font(.labelSmall))
                .foregroundStyle(theme.onSurfaceVariant)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(minWidth: 64)
        .contentShape(Rectangle())
    }
}

extension PlayerActionLabel where Icon == Image, Caption == Text {
    init(systemImage: String, title: String, isActive: Bool = false) {
        self.init(isActive: isActive, icon: { Image(systemName: systemImage) }, caption: { Text(title) })
    }
}

extension PlayerActionLabel where Icon == Image {
    init(systemImage: String, isActive: Bool = false, @ViewBuilder caption: () -> Caption) {
        self.init(isActive: isActive, icon: { Image(systemName: systemImage) }, caption: caption)
    }
}

struct PlayerSpeedMenu: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    static let options = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    let speed: Double
    var showsCaption = false
    let onSelect: (Double) -> Void

    var body: some View {
        Menu {
            ForEach(Self.options, id: \.self) { option in
                Button {
                    onSelect(option)
                } label: {
                    if abs(speed - option) < 0.01 {
                        Label(Self.label(option), systemImage: "checkmark")
                    } else {
                        Text(Self.label(option))
                    }
                }
            }
        } label: {
            if showsCaption {
                PlayerActionLabel(systemImage: "speedometer", title: Self.label(speed))
            } else {
                Text(Self.label(speed))
                    .font(vm.font(.label))
                    .monospacedDigit()
                    .foregroundStyle(theme.onPrimaryContainer)
                    .padding(.horizontal, 12)
                    .frame(minWidth: 48, minHeight: 32)
                    .background(theme.primaryContainer.opacity(0.65), in: Capsule())
                    .contentShape(Capsule())
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Playback Speed")
        .accessibilityLabel("Playback Speed")
        .accessibilityValue(Self.label(speed))
    }

    static func label(_ speed: Double) -> String {
        String(format: "%g", (speed * 100).rounded() / 100) + "×"
    }
}

struct PlayerVolumeControl: View {
    @EnvironmentObject var audio: AudioService
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 12))
                .foregroundStyle(theme.onSurfaceVariant)
            Slider(value: Binding(get: { Double(audio.volume) }, set: { audio.setVolume(Float($0)) }), in: 0 ... 1.5)
                .controlSize(.small)
                .frame(width: 140)
                .accessibilityLabel("Volume")
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 12))
                .foregroundStyle(theme.onSurfaceVariant)
        }
    }
}

struct PlayerVolumeButton: View {
    @EnvironmentObject var audio: AudioService
    @State private var showing = false

    private var symbol: String {
        switch audio.volume {
        case 0: "speaker.slash"
        case ..<0.5: "speaker.wave.1"
        case ..<1.1: "speaker.wave.2"
        default: "speaker.wave.3"
        }
    }

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            PlayerActionLabel(systemImage: symbol, title: "Volume")
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            PlayerVolumeControl()
                .padding(Theme.Space.card)
        }
        .help("Volume")
        .accessibilityLabel("Volume")
    }
}

struct PlayerProgressBar: View {
    @Environment(\.voqoraTheme) private var theme
    let fraction: Double
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.onSurface.opacity(0.12))
                Capsule()
                    .fill(theme.primary)
                    .frame(width: geometry.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((min(1, max(0, fraction)) * 100).rounded())) percent")
    }
}

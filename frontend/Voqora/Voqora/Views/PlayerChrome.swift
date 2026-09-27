import SwiftUI

struct PlayerScaffold<Artwork: View, Header: View, Controls: View, Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    var tint: Color?
    @ViewBuilder let artwork: (CGFloat) -> Artwork
    @ViewBuilder let header: (HorizontalAlignment) -> Header
    @ViewBuilder let controls: (Bool) -> Controls
    @ViewBuilder let content: (CGFloat) -> Content

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                background
                if AudiobookPlayerLayout.columnVisibility(for: geometry.size.width).showCover {
                    wide(height: geometry.size.height)
                } else {
                    compact
                }
            }
        }
        .frame(minWidth: AudiobookPlayerLayout.minWidth, minHeight: 480)
    }

    private var background: some View {
        ZStack {
            Palette.surfaceBase
            if let tint {
                RadialGradient(
                    colors: [tint.opacity(colorScheme == .dark ? 0.22 : 0.12), .clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: 900
                )
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
    }

    private func wide(height: CGFloat) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 22) {
                Spacer(minLength: 0)
                artwork(AudiobookPlayerLayout.artworkHeight(forAvailableHeight: height))
                header(.center)
                controls(false)
                Spacer(minLength: 0)
            }
            .frame(width: AudiobookPlayerLayout.controlsColumnWidth)
            .padding(.leading, 40)
            .padding(.trailing, 16)
            .padding(.vertical, 24)

            content(26)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.trailing, 16)
        }
    }

    private var compact: some View {
        VStack(spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                artwork(84)
                header(.leading)
                Spacer(minLength: 0)
            }
            controls(true)
            content(22)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
    }
}

struct PlayerTitle: View {
    @EnvironmentObject var vm: DashboardViewModel
    let title: String
    let subtitle: String
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(title)
                .font(vm.appFont(size: alignment == .center ? 19 : 16, weight: .bold))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(alignment == .center ? .center : .leading)
                .help(title)
            Text(subtitle)
                .font(vm.appFont(size: 13, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: subtitle)
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
    }
}

struct PlayerPlayButton: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    let isPlaying: Bool
    let isLoading: Bool
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(vm.accentColor(scheme: colorScheme, contrast: contrast))
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(vm.onAccentColor(scheme: colorScheme, contrast: contrast))
                } else {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: size * 0.36, weight: .bold))
                        .foregroundStyle(vm.onAccentColor(scheme: colorScheme, contrast: contrast))
                        .offset(x: isPlaying ? 0 : size * 0.03)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
        .help(isPlaying ? "Pause" : "Play")
    }
}

struct TransportGlyph: View {
    let systemName: String
    let label: String
    var size: CGFloat = 18
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Palette.textPrimary.opacity(hovering ? 1 : 0.8))
                .frame(width: size * 2.2, height: size * 2.2)
                .background(Circle().fill(hovering ? Palette.controlFill : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleButtonStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct PressScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct PlayerCircleButton: View {
    let systemName: String
    let label: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Palette.controlFill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct PlayerVolumeControl: View {
    @EnvironmentObject var audio: AudioService

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 10))
                .foregroundStyle(Palette.textSecondary)
            Slider(value: Binding(get: { Double(audio.volume) }, set: { audio.setVolume(Float($0)) }), in: 0 ... 1.5)
                .controlSize(.mini)
                .frame(maxWidth: 110)
                .accessibilityLabel("Volume")
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 10))
                .foregroundStyle(Palette.textSecondary)
        }
    }
}

struct PlayerSegmentedHeader<Selection: Hashable & Identifiable & RawRepresentable & CaseIterable>: View
    where Selection.RawValue == String, Selection.AllCases: RandomAccessCollection
{
    @Binding var selection: Selection

    var body: some View {
        Picker("View", selection: $selection) {
            ForEach(Selection.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 220)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }
}

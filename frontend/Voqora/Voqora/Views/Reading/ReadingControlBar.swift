import AppKit
import SwiftUI

struct ReadingControlBar: View {
    @EnvironmentObject private var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    @ObservedObject var preferences: ReadingPreferences
    let isPlayable: Bool
    let onClose: () -> Void
    @State private var showsSettings = false

    var body: some View {
        HStack(spacing: Theme.Space.unit + 2) {
            ReadingPlayButton(isEnabled: isPlayable) { vm.togglePlayback() }
            separator
            ReadingBarButton(
                systemName: "textformat.size.smaller",
                label: "Smaller Text",
                isEnabled: preferences.typography.canDecreaseFontSize
            ) {
                preferences.typography = preferences.typography.adjustingFontSize(by: -ReadingTypography.fontSizeStep)
            }
            ReadingBarButton(
                systemName: "textformat.size.larger",
                label: "Larger Text",
                isEnabled: preferences.typography.canIncreaseFontSize
            ) {
                preferences.typography = preferences.typography.adjustingFontSize(by: ReadingTypography.fontSizeStep)
            }
            ReadingBarButton(
                systemName: preferences.showsRuler ? "ruler.fill" : "ruler",
                label: preferences.showsRuler ? "Hide Reading Ruler" : "Show Reading Ruler",
                isOn: preferences.showsRuler
            ) {
                preferences.showsRuler.toggle()
            }
            ReadingThemeMenu(preferences: preferences)
            ReadingBarButton(systemName: "slider.horizontal.3", label: "Reading Settings", isOn: showsSettings) {
                showsSettings.toggle()
            }
            .popover(isPresented: $showsSettings, arrowEdge: .top) {
                ScrollView {
                    ReadingSettingsSections(preferences: preferences, showsPreview: false)
                        .padding(Theme.Space.card)
                }
                .scrollIndicators(.never)
                .environmentObject(vm)
                .voqoraTheme()
                .frame(width: 520, height: 560)
                .background(theme.surface)
            }
            separator
            ReadingBarButton(systemName: "arrow.up.left.and.arrow.down.right", label: "Toggle Full Screen") {
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
            ReadingBarButton(systemName: "xmark", label: "Close Reading Mode", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, Theme.Space.item)
        .padding(.vertical, Theme.Space.unit + 2)
        .background(theme.surfaceContainerHigh, in: Capsule())
        .overlay(Capsule().strokeBorder(theme.outlineVariant, lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 14, y: 5)
    }

    private var separator: some View {
        Rectangle()
            .fill(theme.outlineVariant)
            .frame(width: 1, height: 20)
            .padding(.horizontal, 2)
            .accessibilityHidden(true)
    }
}

private struct ReadingBarButton: View {
    let systemName: String
    let label: String
    var isEnabled = true
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
        }
        .buttonStyle(VoqoraButtonStyle(kind: isOn ? .iconTonal : .icon))
        .disabled(!isEnabled)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct ReadingPlayButton: View {
    @EnvironmentObject private var audio: AudioService
    @Environment(\.voqoraTheme) private var theme
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.onPrimary)
                .frame(width: 40, height: 40)
                .background(theme.primary, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.38)
        .help(audio.isPlaying ? "Pause" : "Play")
        .accessibilityLabel(audio.isPlaying ? "Pause" : "Play")
    }
}

private struct ReadingThemeMenu: View {
    @ObservedObject var preferences: ReadingPreferences
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        Menu {
            Picker("Theme", selection: $preferences.theme) {
                ForEach(ReadingTheme.allCases) { theme in
                    Text(theme.displayName).tag(theme)
                }
            }
            .pickerStyle(.inline)
            Picker("Tint", selection: $preferences.tint) {
                ForEach(ReadingTint.allCases) { tint in
                    Text(tint.displayName).tag(tint)
                }
            }
            .pickerStyle(.inline)
            .disabled(preferences.theme == .highContrast)
        } label: {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(theme.onSurfaceVariant)
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Reading Theme")
        .accessibilityLabel("Reading Theme")
        .accessibilityValue(preferences.theme.displayName)
    }
}

struct ReadingWindowAppearance: NSViewRepresentable {
    let isDark: Bool

    func makeNSView(context _: Context) -> ReadingAppearanceView {
        let view = ReadingAppearanceView(frame: .zero)
        view.isDark = isDark
        return view
    }

    func updateNSView(_ view: ReadingAppearanceView, context _: Context) {
        view.isDark = isDark
    }
}

final class ReadingAppearanceView: NSView {
    var isDark = false {
        didSet {
            guard isDark != oldValue else { return }
            DispatchQueue.main.async { [weak self] in
                self?.applyAppearance()
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyAppearance()
    }

    private func applyAppearance() {
        window?.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }
}

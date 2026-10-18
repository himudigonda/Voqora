import AppKit
import SwiftUI

struct ReadingControlBar: View {
    @EnvironmentObject private var vm: DashboardViewModel
    @ObservedObject var preferences: ReadingPreferences
    let isPlayable: Bool
    let onClose: () -> Void
    @State private var showsSettings = false

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            ReadingPlayButton(isEnabled: isPlayable) { vm.togglePlayback() }
            separator
            PlayerCircleButton(
                systemName: "textformat.size.smaller",
                label: "Smaller Text",
                isEnabled: preferences.typography.canDecreaseFontSize
            ) {
                preferences.typography = preferences.typography.adjustingFontSize(by: -ReadingTypography.fontSizeStep)
            }
            PlayerCircleButton(
                systemName: "textformat.size.larger",
                label: "Larger Text",
                isEnabled: preferences.typography.canIncreaseFontSize
            ) {
                preferences.typography = preferences.typography.adjustingFontSize(by: ReadingTypography.fontSizeStep)
            }
            PlayerCircleButton(
                systemName: preferences.showsRuler ? "ruler.fill" : "ruler",
                label: preferences.showsRuler ? "Hide Reading Ruler" : "Show Reading Ruler"
            ) {
                preferences.showsRuler.toggle()
            }
            ReadingThemeMenu(preferences: preferences)
            PlayerCircleButton(systemName: "slider.horizontal.3", label: "Reading Settings") {
                showsSettings.toggle()
            }
            .popover(isPresented: $showsSettings, arrowEdge: .top) {
                ScrollView {
                    ReadingSettingsForm(preferences: preferences, showsPreview: false)
                        .padding(DesignTokens.Spacing.xl)
                        .environmentObject(vm)
                }
                .frame(width: 400, height: 520)
            }
            separator
            PlayerCircleButton(systemName: "arrow.up.left.and.arrow.down.right", label: "Toggle Full Screen") {
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
            PlayerCircleButton(systemName: "xmark", label: "Close Reading Mode", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Palette.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }

    private var separator: some View {
        Rectangle()
            .fill(Palette.separator)
            .frame(width: 1, height: 18)
            .accessibilityHidden(true)
    }
}

private struct ReadingPlayButton: View {
    @EnvironmentObject private var audio: AudioService
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        PlayerCircleButton(
            systemName: audio.isPlaying ? "pause.fill" : "play.fill",
            label: audio.isPlaying ? "Pause" : "Play",
            isEnabled: isEnabled,
            action: action
        )
    }
}

private struct ReadingThemeMenu: View {
    @ObservedObject var preferences: ReadingPreferences

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
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Palette.controlFill))
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

    func makeNSView(context _: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context _: Context) {
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        DispatchQueue.main.async {
            view.window?.appearance = appearance
        }
    }
}

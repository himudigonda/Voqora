import SwiftUI

struct MainDashboardView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var audio: AudioService
    @EnvironmentObject var permissions: PermissionsService
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.colorSchemeContrast) var colorSchemeContrast

    // Local state
    @State private var localProgress: Double = 0
    @State private var isEditingSlider = false

    /// The app's accent, resolved once per body pass — matches
    /// `VoqoraWindow`'s own `accentColor` pattern.
    private var accentColor: Color {
        vm.accentColor(scheme: colorScheme, contrast: colorSchemeContrast)
    }

    /// A faint, OPAQUE accent wash for the visualizer's ambience glow —
    /// deliberately `subtle` rather than a translucent `Color.cyan.opacity`,
    /// so the glow reads the same regardless of what's behind it.
    private var ambienceGlow: Color {
        Color(
            Palette.accentRamp(
                for: vm.accentColorID,
                appearance: colorScheme,
                increaseContrast: colorSchemeContrast == .increased
            ).subtle
        )
    }

    var body: some View {
        ZStack {
            // AMBIENCE
            Circle()
                .fill(vm.status == .speaking ? AnyShapeStyle(ambienceGlow) : AnyShapeStyle(Color.clear))
                .frame(width: 450, height: 450)
                .blur(radius: 90)
                .animation(.easeInOut(duration: 1.2), value: vm.status)

            VStack(spacing: 0) {
                headerSection
                if !permissions.accessibilityGranted {
                    accessibilityBanner
                }
                Spacer()
                visualizerSection
                Spacer()
                footerSection
            }
        }
    }

    private var accessibilityBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 18))
                .foregroundStyle(Palette.warning)

            VStack(alignment: .leading, spacing: 3) {
                Text("Accessibility Access Required")
                    .font(vm.appFont(size: 12, weight: .bold))
                    .foregroundStyle(Palette.warning)
                // NOT `.fixedSize(horizontal: false, vertical: true)`. That
                // modifier here — a wrapping `Text` inside an `HStack` that
                // also holds a `Spacer()`, itself nested inside
                // `NavigationSplitView` — was found to corrupt the height
                // NavigationSplitView computes for the ENTIRE window: the
                // sidebar's branding/nav and this screen's own header/footer
                // all got pushed off the top and bottom of the visible
                // window, while only content between two `Spacer()`s (the
                // audio visualizer) stayed on-screen. Reproduced identically
                // regardless of window size, display scaling, or Debug vs
                // Release. `Text` already wraps within the width `HStack`
                // gives it without this modifier; it bought nothing here
                // that was worth the layout corruption.
                Text("Voqora needs Accessibility permission to read your selected text. Without it, Cmd+Shift+. won't work.")
                    .font(vm.appFont(size: 11))
                    .foregroundStyle(Palette.textSecondary)
            }

            Spacer()

            Button("Open Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.warning)
            .font(vm.appFont(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Palette.surfaceRaised)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Palette.separator), alignment: .bottom)
    }

    private var headerSection: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("VOQORA")
                    .font(vm.font(.sectionHeader))
                    .kerning(0.6)
                    .foregroundStyle(Palette.textSecondary)

                HStack(spacing: 6) {
                    if vm.isBackendOnline {
                        Circle()
                            .fill(Palette.success)
                            .frame(width: 6, height: 6)
                        Text("SYSTEM ONLINE")
                            .font(vm.font(.chip))
                            .foregroundStyle(Palette.success)
                    } else if vm.isBackendInitializing {
                        Circle()
                            .fill(Palette.warning)
                            .frame(width: 6, height: 6)
                        Text("INITIALIZING...")
                            .font(vm.font(.chip))
                            .foregroundStyle(Palette.warning)
                    } else {
                        Circle()
                            .fill(Palette.danger)
                            .frame(width: 6, height: 6)
                        Text(vm.backendRecoveryMessage == nil ? "OFFLINE" : "RETRYING LOCAL ENGINE")
                            .font(vm.font(.chip))
                            .foregroundStyle(Palette.danger)
                    }
                }
                .id("\(vm.isBackendOnline)-\(vm.isBackendInitializing)")

                if let recovery = vm.backendRecoveryMessage {
                    Text(recovery + " Voqora is retrying automatically.")
                        .font(vm.appFont(size: 10))
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            HStack(spacing: 12) {
                // Falls back to the connectivity state instead of the default
                // "Ready" whenever the backend isn't actually online — this
                // badge used to show "READY" at the same time the indicator
                // to its left showed red "OFFLINE", which read as contradictory.
                Text((vm.actionFeedback ?? (vm.isBackendOnline ? vm.status.message : (vm.backendRecoveryMessage == nil ? "Offline" : "Retrying"))).uppercased())
                    .font(vm.font(.chip))
                    .kerning(0.6)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .foregroundStyle(
                        vm.actionFeedback != nil ? AnyShapeStyle(Palette.success)
                            : !vm.isBackendOnline ? AnyShapeStyle(Palette.danger)
                            : AnyShapeStyle(Palette.textPrimary)
                    )
                    .background(Capsule().stroke(Palette.separator, lineWidth: 1))

                if audio.canExportLastClip {
                    Button {
                        vm.exportLastClip()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.down.fill")
                            Text("SAVE")
                                .font(vm.font(.chip))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(accentColor)
                        .foregroundStyle(vm.onAccentColor(scheme: colorScheme, contrast: colorSchemeContrast))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Export Last Clip to Desktop (Cmd+Shift+M)")
                }
            }
        }
        .padding(40)
    }

    private var visualizerSection: some View {
        VStack(spacing: 30) {
            ZStack {
                Circle().stroke(lineWidth: 1).foregroundStyle(Palette.separator).frame(width: 260, height: 260)

                Circle()
                    .stroke(lineWidth: 1.5)
                    .foregroundStyle(vm.status == .speaking ? AnyShapeStyle(accentColor) : AnyShapeStyle(Palette.separator))
                    .frame(width: 200, height: 200)
                    .scaleEffect(vm.status == .speaking ? 1.08 : 1.0)
                    .animation(
                        vm.status == .speaking
                            ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                            : .easeInOut(duration: 0.3),
                        value: vm.status == .speaking
                    )

                Image(systemName: "waveform")
                    .font(.system(size: 80, weight: .ultraLight))
                    .symbolEffect(.bounce, value: vm.status == .speaking)
            }

            VStack(spacing: 12) {
                Text(vm.currentVoiceDisplay.uppercased()) // Simplified display logic
                    .font(vm.appFont(size: 14, weight: .bold))
                    .foregroundStyle(Palette.textSecondary)

                let total = audio.duration
                let current = isEditingSlider ? localProgress * total : audio.currentTime
                Text(formatTime(current))
                    .font(vm.appFont(size: 32, weight: .thin))
                    .contentTransition(.numericText())
            }
        }
    }

    private var footerSection: some View {
        VStack(spacing: 30) {
            if vm.status == .speaking || vm.status == .paused || audio.duration > 0 {
                // Slider Logic (same as before but using 'audio' environment object)
                Slider(value: $localProgress, in: 0 ... 1, onEditingChanged: { editing in
                    isEditingSlider = editing
                    audio.isDragging = editing
                    if !editing {
                        audio.seek(to: localProgress)
                    }
                })
                .onReceive(audio.$progress) { p in
                    if !isEditingSlider {
                        localProgress = p
                    }
                }
                .padding(.horizontal, 100)
            }

            HStack(spacing: 60) {
                TransportButton(icon: "backward.fill", size: 20, accessibilityLabel: "Back 10 seconds") {
                    let target = max(0, audio.currentTime - 10)
                    audio.seek(to: audio.duration > 0 ? target / audio.duration : 0)
                }

                Button { vm.togglePlayback() } label: {
                    ZStack {
                        Circle().fill(colorScheme == .dark ? Color.white : Color.black).frame(width: 72, height: 72)
                        Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                            .foregroundStyle(colorScheme == .dark ? .black : .white)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(audio.isPlaying ? "Pause" : "Play")
                .help(audio.isPlaying ? "Pause" : "Play")

                TransportButton(icon: "forward.fill", size: 20, accessibilityLabel: "Forward 10 seconds") {
                    let target = min(audio.duration, audio.currentTime + 10)
                    audio.seek(to: audio.duration > 0 ? target / audio.duration : 1)
                }
            }
        }
        .padding(.bottom, 40)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let mins = Int(time) / 60
        let secs = Int(time) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

struct TransportButton: View {
    @EnvironmentObject var vm: DashboardViewModel
    let icon: String
    let size: CGFloat
    var accessibilityLabel: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(vm.appFont(size: size, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
        }
        .buttonStyle(.plain)
        .modifier(OptionalAccessibilityLabel(label: accessibilityLabel))
    }
}

/// Applies `.accessibilityLabel`/`.help` only when a label is provided, so
/// call sites without one (if any remain) don't regress to an empty label.
private struct OptionalAccessibilityLabel: ViewModifier {
    let label: String?

    func body(content: Content) -> some View {
        if let label {
            content.accessibilityLabel(label).help(label)
        } else {
            content
        }
    }
}

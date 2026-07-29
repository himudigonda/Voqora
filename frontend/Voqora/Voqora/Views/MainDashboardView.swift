import ApplicationServices
import SwiftUI

struct MainDashboardView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var audio: AudioService
    @Environment(\.colorScheme) var colorScheme

    // Local state
    @State private var localProgress: Double = 0
    @State private var isEditingSlider = false
    @State private var hasAccessibilityPermission: Bool = AXIsProcessTrusted()

    var body: some View {
        // GeometryReader-driven adaptive sizing (the v1.1 design notes Sprint 6, T6.4) —
        // same "no rigid element fighting for space" principle as
        // AudiobookPlayerLayout, applied to the dashboard's fixed
        // circles/paddings so nothing crowds at narrow widths.
        GeometryReader { geo in
            let metrics = MainDashboardLayout.metrics(for: geo.size.width)
            ZStack {
                // AMBIENCE
                Circle()
                    .fill(vm.status == .speaking ? AnyShapeStyle(Color.cyan.opacity(colorScheme == .dark ? 0.12 : 0.08)) : AnyShapeStyle(Color.clear))
                    .frame(width: metrics.ambientCircleSize, height: metrics.ambientCircleSize)
                    .blur(radius: 90)
                    .animation(.easeInOut(duration: 1.2), value: vm.status)

                VStack(spacing: 0) {
                    headerSection(padding: metrics.headerPadding)
                    if !hasAccessibilityPermission {
                        accessibilityBanner
                    }
                    Spacer()
                    visualizerSection(outerSize: metrics.outerRingSize, innerSize: metrics.innerRingSize)
                    Spacer()
                    footerSection(sliderPadding: metrics.sliderHorizontalPadding)
                }
            }
            .clipped()
        }
        .onAppear { hasAccessibilityPermission = AXIsProcessTrusted() }
    }

    private var accessibilityBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 18))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 3) {
                Text("Accessibility Access Required")
                    .font(vm.appFont(size: 12, weight: .bold))
                    .foregroundStyle(.primary)
                Text("Voqora needs Accessibility permission to read your selected text. Without it, Cmd+Shift+. won't work.")
                    .font(vm.appFont(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button("Open Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .font(vm.appFont(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.orange.opacity(colorScheme == .dark ? 0.12 : 0.08))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.orange.opacity(0.25)), alignment: .bottom)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasAccessibilityPermission = AXIsProcessTrusted()
        }
    }

    private func headerSection(padding: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("VOQORA")
                    .font(vm.appFont(size: 11, weight: .black))
                    .kerning(3)
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    if vm.isBackendOnline {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text("SYSTEM ONLINE")
                            .font(vm.appFont(size: 9, weight: .bold))
                            .foregroundStyle(.green)
                    } else if vm.isBackendInitializing {
                        Circle()
                            .fill(Color.yellow)
                            .frame(width: 6, height: 6)
                        Text("INITIALIZING...")
                            .font(vm.appFont(size: 9, weight: .bold))
                            .foregroundStyle(.yellow)
                    } else {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 6, height: 6)
                        Text("OFFLINE")
                            .font(vm.appFont(size: 9, weight: .bold))
                            .foregroundStyle(.red)
                    }
                }
                .id("\(vm.isBackendOnline)-\(vm.isBackendInitializing)")
            }

            Spacer()

            HStack(spacing: 12) {
                Text(vm.status.message.uppercased())
                    .font(vm.appFont(size: 10, weight: .bold))
                    .kerning(1.5)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .foregroundStyle(.primary)
                    .background(Capsule().stroke(lineWidth: 1).foregroundStyle(.primary.opacity(0.1)))

                if audio.duration > 0 {
                    Button {
                        audio.exportToDesktop()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.down.fill")
                            Text("SAVE")
                                .font(vm.appFont(size: 10, weight: .black))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.cyan)
                        .foregroundStyle(.black)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Export Last Clip to Desktop (Cmd+Shift+M)")
                }
            }
        }
        .padding(padding)
    }

    private func visualizerSection(outerSize: CGFloat, innerSize: CGFloat) -> some View {
        VStack(spacing: 30) {
            ZStack {
                Circle().stroke(lineWidth: 1).foregroundStyle(.primary.opacity(0.05)).frame(width: outerSize, height: outerSize)

                Circle()
                    .stroke(lineWidth: 1.5)
                    .foregroundStyle(vm.status == .speaking ? AnyShapeStyle(Color.cyan.opacity(0.6)) : AnyShapeStyle(Color.primary.opacity(0.05)))
                    .frame(width: innerSize, height: innerSize)
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
                // Show errors (e.g. "enable Accessibility", "nothing to play") in
                // place of the voice name so failures aren't silent; otherwise the
                // current voice. (Previously the label was always the voice name,
                // so status errors never reached the user.)
                if case let .error(msg) = vm.status {
                    Text(msg)
                        .font(vm.appFont(size: 13, weight: .semibold))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24)
                } else {
                    Text(vm.currentVoiceDisplay.uppercased())
                        .font(vm.appFont(size: 14, weight: .bold))
                        .foregroundStyle(.secondary)
                }

                let total = audio.duration
                let current = isEditingSlider ? localProgress * total : audio.currentTime
                Text(formatTime(current))
                    .font(vm.appFont(size: 32, weight: .thin))
                    .contentTransition(.numericText())
            }
        }
    }

    private func footerSection(sliderPadding: CGFloat) -> some View {
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
                .onReceive(audio.$progress) {
                    p in if !isEditingSlider {
                        localProgress = p
                    }
                }
                .padding(.horizontal, sliderPadding)
            }

            HStack(spacing: 60) {
                TransportButton(icon: "backward.fill", size: 20) {
                    let target = max(0, audio.currentTime - 10)
                    audio.seek(to: audio.duration > 0 ? target / audio.duration : 0)
                }

                Button { vm.togglePlayback() } label: {
                    ZStack {
                        Circle().fill(colorScheme == .dark ? Color.white : Color.black).frame(width: 72, height: 72)
                        Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                            .foregroundStyle(colorScheme == .dark ? .black : .white)
                    }
                }.buttonStyle(.plain)

                TransportButton(icon: "forward.fill", size: 20) {
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(vm.appFont(size: size, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }
}

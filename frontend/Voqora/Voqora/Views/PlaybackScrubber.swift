import SwiftUI

struct PlaybackScrubber: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var audio: AudioService
    var markers: [TimeInterval] = []
    var isEnabled = true
    let onScrub: (TimeInterval?) -> Void
    let onCommit: (TimeInterval) -> Void
    @State private var dragFraction: Double?
    @State private var hovering = false

    private var duration: TimeInterval {
        isEnabled ? audio.duration : 0
    }

    private var fraction: Double {
        dragFraction ?? (isEnabled ? audio.progress : 0)
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                let width = max(1, geometry.size.width)
                let expanded = hovering || dragFraction != nil
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.textPrimary.opacity(0.14))
                    Capsule()
                        .fill(Palette.textPrimary.opacity(expanded ? 0.9 : 0.7))
                        .frame(width: width * fraction)
                    ForEach(markers.filter { $0 > 0 && $0 < duration }, id: \.self) { time in
                        Rectangle()
                            .frame(width: 2)
                            .offset(x: width * time / max(1, duration) - 1)
                            .blendMode(.destinationOut)
                    }
                }
                .compositingGroup()
                .frame(height: expanded ? 8 : 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .animation(.easeOut(duration: 0.15), value: expanded)
                .onHover { hovering = isEnabled && $0 }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0 else { return }
                            let next = min(1, max(0, value.location.x / width))
                            dragFraction = next
                            audio.isDragging = true
                            onScrub(next * duration)
                        }
                        .onEnded { value in
                            guard duration > 0 else { return }
                            let target = min(1, max(0, value.location.x / width)) * duration
                            audio.isDragging = false
                            onCommit(target)
                            onScrub(nil)
                            dragFraction = nil
                        }
                )
            }
            .frame(height: 20)
            .accessibilityElement()
            .accessibilityLabel("Playback position")
            .accessibilityValue(DurationFormatter.clock(fraction * duration))
            .accessibilityAdjustableAction { direction in
                guard duration > 0 else { return }
                let step: TimeInterval = direction == .increment ? 15 : -15
                onCommit(min(duration, max(0, fraction * duration + step)))
            }

            HStack {
                Text(DurationFormatter.clock(fraction * duration))
                Spacer(minLength: 8)
                Text("-" + DurationFormatter.clock(max(0, duration - fraction * duration)))
            }
            .font(vm.appFont(size: 11, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(Palette.textSecondary)
        }
        .opacity(isEnabled ? 1 : 0.5)
        .allowsHitTesting(isEnabled)
    }
}

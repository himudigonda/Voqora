import SwiftUI

struct PlaybackScrubber: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var audio: AudioService
    var markers: [TimeInterval] = []
    var isEnabled = true
    var chapterTitle: (TimeInterval) -> String? = { _ in nil }
    let onScrub: (TimeInterval?) -> Void
    let onCommit: (TimeInterval) -> Void
    @State private var dragFraction: Double?
    @State private var hoverFraction: Double?

    private var duration: TimeInterval {
        isEnabled ? audio.duration : 0
    }

    private var fraction: Double {
        dragFraction ?? (isEnabled ? audio.progress : 0)
    }

    private var availableFraction: Double {
        duration > 0 ? min(1, audio.availableDuration / duration) : 0
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                let width = max(1, geometry.size.width)
                let expanded = hoverFraction != nil || dragFraction != nil
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.textPrimary.opacity(0.14))
                    if availableFraction < 1 {
                        Capsule()
                            .fill(Palette.textPrimary.opacity(0.14))
                            .frame(width: width * availableFraction)
                    }
                    Capsule()
                        .fill(Palette.textPrimary.opacity(expanded ? 0.9 : 0.7))
                        .frame(width: width * fraction)
                        .animation(dragFraction == nil && audio.isPlaying ? .linear(duration: 0.1) : nil, value: fraction)
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
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(location):
                        hoverFraction = isEnabled && duration > 0 ? min(availableFraction, max(0, location.x / width)) : nil
                    case .ended:
                        hoverFraction = nil
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0 else { return }
                            let next = min(availableFraction, max(0, value.location.x / width))
                            dragFraction = next
                            audio.isDragging = true
                            onScrub(next * duration)
                        }
                        .onEnded { value in
                            guard duration > 0 else { return }
                            let target = min(availableFraction, max(0, value.location.x / width)) * duration
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
                onCommit(min(audio.availableDuration, max(0, fraction * duration + step)))
            }

            timeRow
                .font(vm.appFont(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Palette.textSecondary)
                .frame(height: 14)
        }
        .opacity(isEnabled ? 1 : 0.5)
        .allowsHitTesting(isEnabled)
    }

    @ViewBuilder
    private var timeRow: some View {
        if let time = previewTime {
            HStack(spacing: 6) {
                Text(DurationFormatter.clock(time))
                    .foregroundStyle(Palette.textPrimary)
                if let title = chapterTitle(time) {
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            HStack {
                Text(DurationFormatter.clock(fraction * duration))
                Spacer(minLength: 8)
                Text("-" + DurationFormatter.clock(max(0, duration - fraction * duration)))
            }
        }
    }

    private var previewTime: TimeInterval? {
        guard duration > 0 else { return nil }
        if let dragFraction {
            return dragFraction * duration
        }
        return hoverFraction.map { $0 * duration }
    }
}

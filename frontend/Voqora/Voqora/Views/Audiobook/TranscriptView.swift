import AppKit
import SwiftUI

struct TranscriptView: View {
    @EnvironmentObject private var vm: DashboardViewModel
    @ObservedObject var follower: TranscriptFollower
    var fontSize: CGFloat = 26
    var anchor: CGFloat = 0.3
    let onSelect: (TranscriptLine) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isFollowing = true
    @State private var resumeTask: Task<Void, Never>?
    @State private var recenterRequest = 0
    @State private var hoveredLineID: Int?

    static let resumeDelay: Duration = .seconds(5)

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: geometry.size.height * anchor)
                        ForEach(follower.document.lines) { line in
                            row(for: line)
                                .id(line.id)
                        }
                        Color.clear.frame(height: geometry.size.height * (1 - anchor))
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, 28)
                    .frame(maxWidth: .infinity)
                    .background(ScrollInteractionMonitor(onUserScroll: userDidScroll))
                }
                .scrollIndicators(isFollowing ? .hidden : .automatic)
                .mask(edgeFade)
                .onAppear { recenter(proxy, animated: false, settle: true) }
                .onChange(of: follower.revision) { _, _ in recenter(proxy, animated: false, settle: true) }
                .onChange(of: follower.activeIndex) { old, new in
                    activeLineChanged(proxy, from: old, to: new)
                }
                .onChange(of: follower.isScrubbing) { _, scrubbing in
                    if scrubbing {
                        engageFollowing()
                    }
                }
                .onChange(of: recenterRequest) { _, _ in recenter(proxy, animated: true) }
                .overlay(alignment: .bottom) {
                    if !isFollowing, follower.activeIndex != nil {
                        currentLineButton
                            .padding(.bottom, 18)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.9), value: isFollowing)
            }
        }
        .onDisappear { resumeTask?.cancel() }
    }

    private func row(for line: TranscriptLine) -> some View {
        let lines = follower.document.lines
        let distance = follower.activeIndex.map { abs($0 - line.id) } ?? Int.max
        let previous = line.id > 0 ? lines[line.id - 1] : nil
        let startsBlock = previous?.block != line.block
        let startsUnnarratedPage = !line.isNarrated && previous.map { $0.page != line.page || $0.isNarrated } ?? true
        return VStack(alignment: .leading, spacing: 8) {
            if startsUnnarratedPage {
                Label("Not narrated", systemImage: "speaker.slash")
                    .font(vm.appFont(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.textTertiary)
            }
            TranscriptLineRow(
                line: line,
                isActive: distance == 0,
                blur: rowBlur(distance: distance),
                isHovered: hoveredLineID == line.id,
                font: vm.appFont(size: line.isHeading ? fontSize * 0.62 : fontSize, weight: .bold),
                progress: distance == 0 && line.isExactlyTimed ? follower.lineProgress : nil,
                animation: reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.9),
                onSelect: { select(line) }
            )
            .onHover { hovering in
                if hovering {
                    hoveredLineID = line.id
                } else if hoveredLineID == line.id {
                    hoveredLineID = nil
                }
            }
        }
        .padding(.top, startsBlock ? (line.isHeading ? 34 : 22) : 2)
    }

    private func rowBlur(distance: Int) -> CGFloat {
        guard isFollowing, !reduceMotion else { return 0 }
        switch distance {
        case 0, 1: return 0
        case 2: return 0.6
        case 3: return 1.2
        default: return 1.8
        }
    }

    private var edgeFade: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.08),
                .init(color: .black, location: 0.9),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var currentLineButton: some View {
        Button {
            engageFollowing()
        } label: {
            Label("Current Line", systemImage: "text.line.first.and.arrowtriangle.forward")
                .font(vm.appFont(size: 12, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(Palette.separator, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.textPrimary)
        .help("Scroll back to the line being read")
    }

    private func select(_ line: TranscriptLine) {
        engageFollowing()
        onSelect(line)
    }

    private func userDidScroll() {
        if isFollowing {
            isFollowing = false
        }
        resumeTask?.cancel()
        resumeTask = Task { @MainActor in
            try? await Task.sleep(for: Self.resumeDelay)
            guard !Task.isCancelled else { return }
            engageFollowing()
        }
    }

    private func engageFollowing() {
        resumeTask?.cancel()
        resumeTask = nil
        if !isFollowing {
            isFollowing = true
            recenterRequest &+= 1
        }
    }

    private func activeLineChanged(_ proxy: ScrollViewProxy, from old: Int?, to new: Int?) {
        guard let new else { return }
        if let old, abs(new - old) > 1 {
            engageFollowing()
        }
        guard isFollowing else { return }
        let isJump = old.map { abs(new - $0) > 40 } ?? true
        recenter(proxy, animated: !isJump, settle: isJump)
    }

    private func recenter(_ proxy: ScrollViewProxy, animated: Bool, settle: Bool = false) {
        guard isFollowing, let index = follower.activeIndex else { return }
        let target = UnitPoint(x: 0, y: anchor)
        if animated, !reduceMotion {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.88)) {
                proxy.scrollTo(index, anchor: target)
            }
        } else {
            proxy.scrollTo(index, anchor: target)
        }
        if settle {
            DispatchQueue.main.async {
                proxy.scrollTo(index, anchor: target)
            }
        }
    }
}

private struct TranscriptLineRow: View {
    let line: TranscriptLine
    let isActive: Bool
    let blur: CGFloat
    let isHovered: Bool
    let font: Font
    let progress: LineProgress?
    let animation: Animation?
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Group {
                if isActive, let progress {
                    SpokenLineText(text: line.text, progress: progress)
                } else {
                    Text(line.text)
                }
            }
            .font(font)
            .lineSpacing(3)
            .italic(!line.isNarrated)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(Palette.textPrimary)
            .opacity(opacity)
            .blur(radius: blur)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                    .fill(isHovered && !isActive ? Palette.controlFill : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -10)
        .animation(animation, value: isActive)
        .animation(animation, value: blur)
        .accessibilityLabel(line.text)
        .accessibilityHint("Plays from this line")
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .contextMenu {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(line.text, forType: .string)
            }
        }
    }

    private var opacity: Double {
        if isActive {
            return 1
        }
        if isHovered {
            return 0.6
        }
        return line.isNarrated ? 0.3 : 0.2
    }
}

private struct SpokenLineText: View {
    let text: String
    @ObservedObject var progress: LineProgress

    var body: some View {
        let split = Self.splitIndex(in: text, fraction: progress.fraction)
        return Text(text[..<split])
            + Text(text[split...]).foregroundStyle(Palette.textPrimary.opacity(0.45))
    }

    static func splitIndex(in text: String, fraction: Double) -> String.Index {
        guard fraction > 0 else { return text.startIndex }
        guard fraction < 1 else { return text.endIndex }
        let target = text.index(text.startIndex, offsetBy: Int((Double(text.count) * fraction).rounded(.up)))
        return text[target...].firstIndex(of: " ") ?? text.endIndex
    }
}

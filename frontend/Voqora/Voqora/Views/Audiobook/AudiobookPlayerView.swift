import AppKit
import SwiftUI

struct AudiobookPlayerView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @Environment(\.colorScheme) private var colorScheme

    let book: Audiobook
    @State private var panel: Panel = .transcript
    @State private var tint: Color?

    enum Panel: String, CaseIterable, Identifiable {
        case transcript = "Transcript"
        case sections = "Sections"

        var id: String {
            rawValue
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = AudiobookPlayerLayout.columnVisibility(for: geometry.size.width).showCover
            ZStack {
                background
                if wide {
                    wideLayout(height: geometry.size.height)
                } else {
                    compactLayout
                }
            }
        }
        .frame(minWidth: AudiobookPlayerLayout.minWidth, minHeight: 520)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) { bookVM.togglePlayback(); return .handled }
        .onKeyPress(.leftArrow) { bookVM.skip(by: -15); return .handled }
        .onKeyPress(.rightArrow) { bookVM.skip(by: 30); return .handled }
        .onKeyPress("j") { bookVM.skip(by: -15); return .handled }
        .onKeyPress("l") { bookVM.skip(by: 30); return .handled }
        .onKeyPress("n") { bookVM.jumpToNextSection(in: book); return .handled }
        .onKeyPress("p") { bookVM.jumpToPreviousSection(in: book); return .handled }
        .onKeyPress("[") { bookVM.setSpeed(bookVM.audio.playbackRate.asDouble - 0.25); return .handled }
        .onKeyPress("]") { bookVM.setSpeed(bookVM.audio.playbackRate.asDouble + 0.25); return .handled }
        .onAppear {
            bookVM.isPlayerViewActive = true
            if bookVM.nowPlaying?.bookID != book.bookID {
                bookVM.play(book)
            } else if bookVM.transcriptState == .unavailable || bookVM.transcriptState == .idle {
                bookVM.loadTranscript(for: book.bookID)
            }
        }
        .onDisappear {
            bookVM.isPlayerViewActive = false
        }
        .task(id: book.bookID) {
            let color = await CoverColorExtractor.shared.dominantColor(forBackendPath: "audiobook/\(book.bookID)/cover")
            withAnimation(.easeInOut(duration: 0.6)) {
                tint = color
            }
        }
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
            }
        }
        .ignoresSafeArea()
    }

    private func wideLayout(height: CGFloat) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 22) {
                Spacer(minLength: 0)
                PlayerArtwork(book: book, height: AudiobookPlayerLayout.artworkHeight(forAvailableHeight: height))
                PlayerTitleBlock(book: book, alignment: .center)
                PlayerScrubber(book: book)
                PlayerTransport(book: book, compact: false)
                PlayerSecondaryControls(book: book)
                Spacer(minLength: 0)
            }
            .frame(width: AudiobookPlayerLayout.controlsColumnWidth)
            .padding(.leading, 36)
            .padding(.trailing, 12)
            .padding(.vertical, 24)

            contentPanel(fontSize: 26)
                .padding(.trailing, 12)
        }
    }

    private var compactLayout: some View {
        VStack(spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                PlayerArtwork(book: book, height: 84)
                PlayerTitleBlock(book: book, alignment: .leading)
                Spacer(minLength: 0)
            }
            PlayerScrubber(book: book)
            PlayerTransport(book: book, compact: true)
            PlayerSecondaryControls(book: book)
                .frame(maxWidth: 420)
            contentPanel(fontSize: 22)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
    }

    private func contentPanel(fontSize: CGFloat) -> some View {
        VStack(spacing: 0) {
            Picker("View", selection: $panel) {
                ForEach(Panel.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .padding(.top, 16)
            .padding(.bottom, 4)

            switch panel {
            case .transcript:
                transcript(fontSize: fontSize)
            case .sections:
                PlayerSectionsList(book: book)
                    .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func transcript(fontSize: CGFloat) -> some View {
        let isCurrentBook = bookVM.nowPlaying?.bookID == book.bookID
        switch (isCurrentBook, bookVM.transcriptState) {
        case (true, .loaded):
            TranscriptView(follower: bookVM.follower, fontSize: fontSize) { line in
                bookVM.play(fromLine: line)
            }
        case (true, .unavailable):
            VStack(spacing: 12) {
                Text("Transcript Unavailable")
                    .font(vm.appFont(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                Button("Try Again") { bookVM.loadTranscript(for: book.bookID) }
                    .buttonStyle(.voqoraSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private extension Float {
    var asDouble: Double {
        Double(self)
    }
}

private struct PlayerArtwork: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var audio: AudioService
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let book: Audiobook
    let height: CGFloat

    private var width: CGFloat {
        height * AudiobookCardView.coverAspectRatio
    }

    private var radius: CGFloat {
        height > 120 ? 14 : 8
    }

    var body: some View {
        let playing = audio.isPlaying
        AuthenticatedBackendImage(path: "audiobook/\(book.bookID)/cover") { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                Palette.surfaceRaised
                Image(systemName: "book.closed.fill")
                    .font(.system(size: height * 0.18))
                    .foregroundStyle(vm.accentColor(scheme: colorScheme, contrast: contrast).opacity(0.7))
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Palette.separator, lineWidth: 1))
        .shadow(color: .black.opacity(playing ? 0.35 : 0.2), radius: playing ? 24 : 12, y: playing ? 12 : 6)
        .scaleEffect(playing || height <= 120 ? 1 : 0.94)
        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.8), value: playing)
        .accessibilityHidden(true)
    }
}

private struct PlayerTitleBlock: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var audio: AudioService
    let book: Audiobook
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(book.displayTitle)
                .font(vm.appFont(size: alignment == .center ? 19 : 16, weight: .bold))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(3)
                .multilineTextAlignment(alignment == .center ? .center : .leading)
                .help(book.displayTitle)
            Text(book.subtitle(at: audio.currentTime))
                .font(vm.appFont(size: 13, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: book.subtitle(at: audio.currentTime))
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
    }
}

private struct PlayerScrubber: View {
    @EnvironmentObject var bookVM: AudiobookViewModel
    let book: Audiobook

    var body: some View {
        PlaybackScrubber(
            markers: book.sortedSections.map(\.startTime),
            isEnabled: bookVM.nowPlaying?.bookID == book.bookID,
            onScrub: { bookVM.follower.scrub(to: $0) },
            onCommit: { bookVM.seek(toSeconds: $0) }
        )
    }
}

private struct PlayerTransport: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @EnvironmentObject var audio: AudioService
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    let book: Audiobook
    let compact: Bool

    private var isCurrentBook: Bool {
        bookVM.nowPlaying?.bookID == book.bookID
    }

    var body: some View {
        HStack(spacing: compact ? 14 : 22) {
            TransportGlyph(systemName: "backward.end.fill", label: "Previous Section") {
                bookVM.jumpToPreviousSection(in: book)
            }
            TransportGlyph(systemName: "gobackward.15", label: "Back 15 Seconds") {
                bookVM.skip(by: -15)
            }
            playButton
            TransportGlyph(systemName: "goforward.30", label: "Forward 30 Seconds") {
                bookVM.skip(by: 30)
            }
            TransportGlyph(systemName: "forward.end.fill", label: "Next Section") {
                bookVM.jumpToNextSection(in: book)
            }
        }
        .disabled(!isCurrentBook && bookVM.isLoadingAudio)
    }

    private var playButton: some View {
        let playing = isCurrentBook && audio.isPlaying
        let size: CGFloat = compact ? 48 : 64
        return Button {
            if isCurrentBook {
                bookVM.togglePlayback()
            } else {
                bookVM.play(book)
            }
        } label: {
            ZStack {
                Circle().fill(vm.accentColor(scheme: colorScheme, contrast: contrast))
                if bookVM.isLoadingAudio {
                    ProgressView()
                        .controlSize(.small)
                        .tint(vm.onAccentColor(scheme: colorScheme, contrast: contrast))
                } else {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: size * 0.36, weight: .bold))
                        .foregroundStyle(vm.onAccentColor(scheme: colorScheme, contrast: contrast))
                        .offset(x: playing ? 0 : size * 0.03)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel(playing ? "Pause" : "Play")
        .help(playing ? "Pause" : "Play")
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

private struct PlayerSecondaryControls: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @EnvironmentObject var audio: AudioService
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    let book: Audiobook
    var showsVolume = true
    @State private var isExporting = false

    private var accent: Color {
        vm.accentColor(scheme: colorScheme, contrast: contrast)
    }

    var body: some View {
        HStack(spacing: 10) {
            speedMenu
            if showsVolume {
                Spacer(minLength: 0)
                volume
                Spacer(minLength: 0)
            }
            sleepMenu
            exportButton
        }
    }

    private var speedMenu: some View {
        Menu {
            ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { speed in
                Button {
                    bookVM.setSpeed(speed)
                } label: {
                    if abs(Double(audio.playbackRate) - speed) < 0.01 {
                        Label(Self.speedLabel(speed), systemImage: "checkmark")
                    } else {
                        Text(Self.speedLabel(speed))
                    }
                }
            }
        } label: {
            Text(Self.speedLabel(Double(audio.playbackRate)))
                .font(vm.appFont(size: 12, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Palette.textPrimary)
                .frame(minWidth: 44, minHeight: 30)
                .background(Capsule().fill(Palette.controlFill))
                .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Playback Speed")
        .accessibilityLabel("Playback Speed")
    }

    static func speedLabel(_ speed: Double) -> String {
        let formatted = speed.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", speed)
            : String(format: "%g", speed)
        return formatted + "×"
    }

    private var volume: some View {
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

    private var sleepIsArmed: Bool {
        bookVM.sleepTimerEndsAt != nil || bookVM.sleepUntilEndOfBook
    }

    private var sleepMenu: some View {
        Menu {
            ForEach(AudiobookViewModel.SleepDuration.allCases) { option in
                Button(option.menuTitle) { bookVM.startSleepTimer(option, currentBook: book) }
            }
            if sleepIsArmed {
                Divider()
                Button("Turn Off Sleep Timer") { bookVM.cancelSleepTimer() }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: sleepIsArmed ? "moon.zzz.fill" : "moon.zzz")
                    .font(.system(size: 13, weight: .medium))
                if let endsAt = bookVM.sleepTimerEndsAt {
                    Text(timerInterval: Date() ... max(Date(), endsAt), countsDown: true)
                        .font(vm.appFont(size: 11, weight: .semibold))
                        .monospacedDigit()
                } else if bookVM.sleepUntilEndOfBook {
                    Text("End")
                        .font(vm.appFont(size: 11, weight: .semibold))
                }
            }
            .foregroundStyle(sleepIsArmed ? accent : Palette.textPrimary)
            .padding(.horizontal, sleepIsArmed ? 10 : 0)
            .frame(minWidth: 30, minHeight: 30)
            .background(Capsule().fill(Palette.controlFill))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sleep Timer")
        .accessibilityLabel("Sleep Timer")
    }

    private var exportButton: some View {
        Button(action: export) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Palette.controlFill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isExporting || book.status != "done")
        .opacity(book.status == "done" ? 1 : 0.4)
        .help("Export Audio…")
        .accessibilityLabel("Export Audio")
    }

    private func export() {
        guard !isExporting else { return }
        isExporting = true
        Task { @MainActor in
            defer { isExporting = false }
            do {
                let source = try await bookVM.validatedAudioURL(for: book)
                let panel = NSSavePanel()
                panel.title = "Export Audio"
                panel.nameFieldStringValue = "\(book.displayTitle).wav"
                panel.canCreateDirectories = true
                guard panel.runModal() == .OK, let destination = panel.url else { return }
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: source, to: destination)
                bookVM.showToast("Exported \(destination.lastPathComponent)", kind: .success)
            } catch {
                bookVM.showToast("Couldn't export this audiobook.", kind: .error)
            }
        }
    }
}

private struct PlayerSectionsList: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @EnvironmentObject var audio: AudioService
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    let book: Audiobook
    @State private var hoveredID: AudiobookSection.ID?

    var body: some View {
        let sections = book.sortedSections
        let currentID = bookVM.nowPlaying?.bookID == book.bookID ? book.section(at: audio.currentTime)?.id : nil
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    row(section, number: index + 1, isCurrent: section.id == currentID)
                }
            }
            .frame(maxWidth: 640)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        }
        .overlay {
            if sections.isEmpty {
                Text("No Sections")
                    .font(vm.appFont(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private func row(_ section: AudiobookSection, number: Int, isCurrent: Bool) -> some View {
        let accent = vm.accentColor(scheme: colorScheme, contrast: contrast)
        return Button {
            if bookVM.nowPlaying?.bookID == book.bookID {
                bookVM.seek(toSeconds: section.startTime)
                if !audio.isPlaying {
                    audio.resume()
                }
            }
        } label: {
            HStack(spacing: 14) {
                Group {
                    if isCurrent, audio.isPlaying {
                        Image(systemName: "waveform")
                            .symbolEffect(.variableColor.iterative, isActive: true)
                            .foregroundStyle(accent)
                    } else {
                        Text("\(number)")
                            .foregroundStyle(isCurrent ? accent : Palette.textTertiary)
                    }
                }
                .font(vm.appFont(size: 12, weight: .semibold))
                .monospacedDigit()
                .frame(width: 24)
                Text(AudiobookImportStaging.strippingSupportedExtension(from: section.title))
                    .font(vm.appFont(size: 14, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? accent : Palette.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 12)
                Text(DurationFormatter.clock(section.startTime))
                    .font(vm.appFont(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Palette.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                    .fill(hoveredID == section.id ? Palette.controlFill : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hoveredID = $0 ? section.id : (hoveredID == section.id ? nil : hoveredID) }
        .accessibilityLabel("\(section.title), \(DurationFormatter.clock(section.startTime))")
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }
}

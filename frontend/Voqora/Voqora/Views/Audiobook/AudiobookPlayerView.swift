import AppKit
import NaturalLanguage
import SwiftUI

struct AudiobookPlayerView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    // T-11: real reactive source for live playback state — replaces a
    // decoupled 0.25s ticker that forced full-body re-evaluation without
    // actually subscribing to anything. Safe: this view is a descendant of
    // VoqoraApp.swift's `.environmentObject(audio)` on the root VoqoraWindow.
    @EnvironmentObject var audio: AudioService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let book: Audiobook
    @State private var localScrub: Double = 0
    @State private var dragging = false
    @State private var playerSpeed: Double = 1.0
    // T-22: a collapsible transcript (closed by default, then opened by
    // default in T-21) still left a "closed" state that was mostly dead
    // space at any window size, and Sections was a separate rail that simply
    // vanished below 1000pt with no replacement. Both problems had the same
    // root cause: a piece of content that could be entirely absent. Fixed by
    // making Transcript/Sections two tabs of one panel that is *always*
    // present and always fills the remaining space — there is no longer a
    // state where the lower half of the player is empty.
    @State private var panelTab: ContentTab = .transcript
    /// Neutral placeholder until `CoverColorExtractor` samples the actual
    /// cover art in `.onAppear` below — the old neon `.cyan` default briefly
    /// flashed on every player open before the real sample arrived.
    @State private var dominantColor: Color = .gray
    // T-13: last time the user manually scrolled the transcript; suppresses
    // the auto-scroll-on-page-change effect for a short window afterward.
    @State private var userScrolledAt: Date? = nil
    // T-12: per-transcript/per-book sort caches. Reference types held in
    // `@State` so refreshing them during body evaluation mutates their own
    // storage in place rather than reassigning the `@State` property itself
    // — SwiftUI only treats the latter as a state change, so this never
    // triggers an extra render; the freshly-computed values are simply read
    // in the same pass that refreshed them.
    @State private var transcriptCache = TranscriptPageCache()
    @State private var sectionsCache = SectionsCache()
    @State private var highlightCache = HighlightCache()
    @State private var isExporting = false

    /// The app's accent, resolved once per body pass — every hardcoded
    /// `.cyan` in this view reads through this instead.
    private var accentColor: Color {
        vm.accentColor(scheme: colorScheme, contrast: colorSchemeContrast)
    }

    /// The ink for text/icons drawn ON an `accentColor` fill (e.g. the play
    /// button). Not `.white`/`.black` — the dark ramp can put `base` at a
    /// light OKLCH lightness where a fixed ink fails contrast.
    private var onAccentColor: Color {
        vm.onAccentColor(scheme: colorScheme, contrast: colorSchemeContrast)
    }

    var body: some View {
        GeometryReader { geometry in
            let visibility = AudiobookPlayerLayout.columnVisibility(for: geometry.size.width)
            ZStack(alignment: .topTrailing) {
                background
                // T-22: capped and centered, not just `maxWidth: .infinity` —
                // on an ultra-wide window an unbounded scrubber/content panel
                // stretched edge to edge, which is both ugly and imprecise
                // to click. The cap grows to fit the cover column only when
                // it's actually showing.
                HStack(alignment: .top, spacing: 28) {
                    if visibility.showCover {
                        coverColumn
                    }
                    mainColumn(showCover: visibility.showCover)
                }
                .frame(maxWidth: AudiobookPlayerLayout.maxContentWidth + (visibility.showCover ? 268 : 0))
                .frame(maxWidth: .infinity)
                .padding(28)

                HStack(spacing: 8) {
                    exportButton
                    sleepTimerMenu
                }
                .padding(.top, 16)
                .padding(.trailing, 20)
            }
            .clipped()
        }
        .frame(minWidth: AudiobookPlayerLayout.minWidth, minHeight: 580)
        .focusable()
        // Real .onKeyPress modifiers live on the focused root — no hidden
        // buttons. Works because the NavigationStack pushes us into the
        // detail pane, which receives focus by default.
        .onKeyPress(.space) { bookVM.togglePlayback(); return .handled }
        .onKeyPress(.leftArrow) { bookVM.skip(by: -15); return .handled }
        .onKeyPress(.rightArrow) { bookVM.skip(by: 30); return .handled }
        .onKeyPress("j") { bookVM.skip(by: -15); return .handled }
        .onKeyPress("l") { bookVM.skip(by: 30); return .handled }
        .onKeyPress("n") { bookVM.jumpToNextSection(in: book); return .handled }
        .onKeyPress("p") { bookVM.jumpToPreviousSection(in: book); return .handled }
        .onKeyPress("[") { adjustSpeed(-0.25); return .handled }
        .onKeyPress("]") { adjustSpeed(0.25); return .handled }
        .onKeyPress(",") {
            if let s = currentSection() {
                bookVM.seek(toSeconds: s.startTime)
            }
            return .handled
        }
        .onKeyPress(".") { bookVM.jumpToNextSection(in: book); return .handled }
        // T-11: the ticker's one non-cosmetic side effect (cancelling a
        // "sleep until end of book" timer once playback naturally
        // completes) now runs off the real `audio.playbackCompleted`
        // publisher instead of a 0.25s poke.
        .onChange(of: audio.playbackCompleted) { _, completed in
            if completed, bookVM.sleepUntilEndOfBook {
                bookVM.cancelSleepTimer()
            }
        }
        .onAppear {
            // Navigation into this view is the actual source of truth for
            // whether the full player is visible. The window uses this to
            // avoid rendering a second player bar underneath it.
            bookVM.isPlayerViewActive = true
            playerSpeed = bookVM.defaultBookSpeed
            audio.setPlaybackRate(Float(playerSpeed))
            if bookVM.nowPlaying?.bookID != book.bookID {
                bookVM.play(book)
            }
            // Sample dominant cover color for the ambient gradient.
            Task {
                let color = await CoverColorExtractor.shared.dominantColor(
                    forBackendPath: "audiobook/\(book.bookID)/cover"
                )
                dominantColor = color
            }
        }
        .onDisappear {
            bookVM.isPlayerViewActive = false
        }
    }

    // MARK: - Background

    /// NOT a `dominantColor`-tinted, blurred ambient-glow ZStack — that
    /// per-cover "mood lighting" predates the flat GRiT/Anthropic redesign
    /// and reads as a different, inconsistent design language next to every
    /// other screen's plain `Palette` surface. `dominantColor` is still used
    /// for the cover's own play-state shadow tint below, just not to light
    /// up the whole background.
    private var background: some View {
        Palette.surfaceBase
            .ignoresSafeArea()
    }

    // MARK: - Cover column

    private var coverColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Palette.surfaceRaised)
                    .frame(width: 240, height: 336)
                AuthenticatedBackendImage(path: "audiobook/\(book.bookID)/cover") { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "book.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(accentColor.opacity(0.6))
                }
                .frame(width: 240, height: 336)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Palette.separator, lineWidth: 1)
            )
            .shadow(
                color: audio.isPlaying ? dominantColor.opacity(0.45) : .black.opacity(0.45),
                radius: audio.isPlaying ? 42 : 30,
                y: audio.isPlaying ? 20 : 16
            )
            .scaleEffect(audio.isPlaying ? 1.0 : 0.97)
            .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: audio.isPlaying)

            VStack(alignment: .leading, spacing: 6) {
                Text(currentSectionLabel)
                    .font(vm.font(.sectionHeader))
                    .kerning(0.6)
                    .foregroundStyle(accentColor)
                Text(prettyTitle)
                    .font(vm.appFont(size: 22, weight: .bold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                    .frame(width: 240, alignment: .leading)
            }
        }
    }

    private var currentSectionLabel: String {
        if let s = currentSection() {
            return s.title.uppercased()
        }
        return "AUDIOBOOK"
    }

    // MARK: - Main column

    /// T-22: replaces the old vertically-`Spacer`-centered layout, which
    /// left a growing dead zone above/below a fixed-size control cluster as
    /// the window got taller — the layout simply never used the extra
    /// space. Now every section stacks top-down with no absorbing `Spacer`,
    /// and only `contentPanel` (the last element) is allowed to grow, so a
    /// taller window always turns directly into more usable content instead
    /// of more empty air.
    private func mainColumn(showCover: Bool) -> some View {
        VStack(spacing: 22) {
            if !showCover {
                compactHeader
            }
            VStack(spacing: 24) {
                scrubberSection
                transportSection
            }
            speedAndSleep
            contentPanel
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// T-22: shown in place of `coverColumn` below `coverColumnBreakpoint`.
    /// The old layout simply dropped the cover art *and* the title/chapter
    /// label together below that width — there was no way to tell what you
    /// were listening to without widening the window. This keeps that
    /// information always visible, just compact.
    private var compactHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.surfaceRaised)
                AuthenticatedBackendImage(path: "audiobook/\(book.bookID)/cover") { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "book.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(accentColor.opacity(0.6))
                }
            }
            .frame(width: 40, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Palette.separator, lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(currentSectionLabel)
                    .font(vm.font(.sectionHeader))
                    .kerning(0.6)
                    .foregroundStyle(accentColor)
                    .lineLimit(1)
                Text(prettyTitle)
                    .font(vm.appFont(size: 15, weight: .bold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var scrubberSection: some View {
        VStack(spacing: 10) {
            // Custom progress bar — explicit 20pt height so no GeometryReader expansion.
            GeometryReader { geo in
                let w = geo.size.width
                let progress = displayProgress
                ZStack(alignment: .leading) {
                    // Track
                    Capsule()
                        .fill(Palette.controlFill)
                        .frame(height: 4)
                    // Filled portion
                    Capsule()
                        .fill(accentColor)
                        .frame(width: max(0, w * progress), height: 4)
                    // Section-boundary ticks
                    ForEach(book.sections) { section in
                        let total = max(1.0, book.totalAudioSeconds)
                        Capsule()
                            .fill(Palette.controlBorder)
                            .frame(width: 2, height: 10)
                            .offset(x: w * (section.startTime / total) - 1, y: -3)
                    }
                    // Thumb
                    Circle()
                        .fill(Palette.surfaceRaised)
                        .frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                        .overlay(Circle().stroke(Palette.separator, lineWidth: 0.5))
                        .offset(x: max(0, w * progress - 7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            guard w > 0 else { return }
                            localScrub = max(0, min(1, v.location.x / w))
                            dragging = true
                        }
                        .onEnded { _ in
                            bookVM.seek(percentage: localScrub)
                            dragging = false
                        }
                )
            }
            .frame(height: 20)

            HStack {
                Text(DurationFormatter.clock(audio.currentTime))
                Spacer()
                if let remain = bookVM.sleepRemainingSeconds {
                    Label("Sleep in \(DurationFormatter.clock(remain))", systemImage: "moon.zzz.fill")
                        .font(vm.appFont(size: 10, weight: .bold).monospaced())
                        .foregroundStyle(accentColor)
                } else if bookVM.sleepUntilEndOfBook {
                    Label("Until end of book", systemImage: "moon.zzz.fill")
                        .font(vm.appFont(size: 10, weight: .bold))
                        .foregroundStyle(accentColor)
                }
                Spacer()
                Text("-" + DurationFormatter.clock(max(0, audio.duration - audio.currentTime)))
            }
            .font(vm.appFont(size: 11, weight: .medium).monospaced())
            .foregroundStyle(Palette.textSecondary)
        }
    }

    private var displayProgress: Double {
        if dragging {
            return localScrub
        }
        return audio.progress
    }

    private var transportSection: some View {
        HStack(spacing: 28) {
            transportSmall(systemName: "backward.end.fill", help: "Previous section (P)") {
                bookVM.jumpToPreviousSection(in: book)
            }
            transportSmall(systemName: "gobackward.15", help: "Back 15s (J)") {
                bookVM.skip(by: -15)
            }
            playButton
            transportSmall(systemName: "goforward.30", help: "Forward 30s (L)") {
                bookVM.skip(by: 30)
            }
            transportSmall(systemName: "forward.end.fill", help: "Next section (N)") {
                bookVM.jumpToNextSection(in: book)
            }
        }
    }

    private var playButton: some View {
        Button { bookVM.togglePlayback() } label: {
            ZStack {
                Circle().fill(accentColor).frame(width: 72, height: 72)
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
                    .overlay(Circle().stroke(Palette.separator, lineWidth: 0.5))
                Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26, weight: .black))
                    .foregroundStyle(onAccentColor)
                    .offset(x: audio.isPlaying ? 0 : 2)
            }
        }
        .buttonStyle(.plain)
        .shadow(color: accentColor.opacity(0.4), radius: 18)
        .accessibilityLabel(audio.isPlaying ? "Pause" : "Play")
        .help(audio.isPlaying ? "Pause (Space)" : "Play (Space)")
    }

    private func transportSmall(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 44, height: 44)
                .background(Palette.controlFill, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        // `.help()` alone only surfaces as a hover tooltip, not a VoiceOver
        // name — every transport control (previous/back/forward/next
        // section) was accessibility-unlabeled despite being some of the
        // feature's most-used controls.
        .accessibilityLabel(help)
    }

    private var speedAndSleep: some View {
        HStack(spacing: 16) {
            Menu {
                ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0] as [Double], id: \.self) { s in
                    Button(String(format: "%.2gx", s)) {
                        playerSpeed = s
                        bookVM.defaultBookSpeed = s
                        audio.setPlaybackRate(Float(s))
                    }
                }
            } label: {
                Text(String(format: "%.2gx", playerSpeed))
                    .font(vm.appFont(size: 12, weight: .bold).monospaced())
                    .foregroundStyle(accentColor)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().stroke(accentColor.opacity(0.45), lineWidth: 1))
            }
            .buttonStyle(.plain)

            Spacer()

            HStack(spacing: 8) {
                Image(systemName: audio.volume < 0.05 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(Palette.textSecondary)
                    .font(.system(size: 12))
                Slider(value: Binding(
                    get: { Double(audio.volume) },
                    set: { audio.setVolume(Float($0)) }
                ), in: 0 ... 1.5)
                    .tint(accentColor)
                    .frame(width: 110)
            }

            if bookVM.sleepRemainingSeconds != nil || bookVM.sleepUntilEndOfBook {
                Button { bookVM.cancelSleepTimer() } label: {
                    Label("Cancel Sleep", systemImage: "moon.zzz.fill")
                        .font(vm.appFont(size: 11, weight: .bold))
                        .foregroundStyle(accentColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().stroke(accentColor.opacity(0.45), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Sleep timer menu (toolbar-area, top-right)

    private var sleepTimerMenu: some View {
        Menu {
            ForEach(AudiobookViewModel.SleepDuration.allCases) { option in
                Button(option.rawValue) {
                    bookVM.startSleepTimer(option, currentBook: book)
                }
            }
            if bookVM.sleepRemainingSeconds != nil || bookVM.sleepUntilEndOfBook {
                Divider()
                Button("Cancel sleep timer") { bookVM.cancelSleepTimer() }
            }
        } label: {
            Image(systemName: "moon.zzz")
                .font(.system(size: 16))
                .foregroundStyle(bookVM.sleepRemainingSeconds == nil && !bookVM.sleepUntilEndOfBook ? Palette.textSecondary : accentColor)
                .frame(width: 32, height: 32)
                .voqoraSurface(.floating, in: Circle())
        }
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
        .help("Sleep timer")
        .accessibilityLabel("Sleep timer")
    }

    private var exportButton: some View {
        Button(action: exportAudiobook) {
            Image(systemName: isExporting ? "hourglass" : "square.and.arrow.down")
                .font(.system(size: 16))
                .foregroundStyle(book.status == "done" ? Palette.textSecondary : Palette.textTertiary)
                .frame(width: 32, height: 32)
                .voqoraSurface(.floating, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(isExporting || book.status != "done")
        .help(book.status == "done" ? "Export audiobook…" : "Finish generating this audiobook before exporting")
        .accessibilityLabel("Export audiobook")
    }

    /// Copy a verified, on-disk audiobook through a normal macOS save panel.
    /// This has no relationship to Dashboard's clip export: a book is never
    /// represented by transient clip PCM, and the source is first validated
    /// by AudiobookService's authenticated WAV cache path.
    private func exportAudiobook() {
        guard !isExporting else { return }
        isExporting = true
        Task { @MainActor in
            defer { isExporting = false }
            do {
                let source = try await bookVM.validatedAudioURL(for: book)
                let panel = NSSavePanel()
                panel.title = "Export Audiobook"
                panel.message = "Save a copy of the completed audiobook audio."
                panel.nameFieldStringValue = "\(prettyTitle).wav"
                panel.canCreateDirectories = true
                guard panel.runModal() == .OK, let destination = panel.url else { return }
                let destinationAccess = destination.startAccessingSecurityScopedResource()
                defer {
                    if destinationAccess {
                        destination.stopAccessingSecurityScopedResource()
                    }
                }
                try FileManager.default.copyItem(at: source, to: destination)
                bookVM.showToast("Exported \(destination.lastPathComponent).", kind: .success)
            } catch {
                bookVM.showToast("Could not export this audiobook.", kind: .error)
            }
        }
    }

    // MARK: - Content panel (Transcript / Sections)

    private enum ContentTab: String, CaseIterable, Identifiable {
        case transcript = "Transcript"
        case sections = "Sections"
        var id: String {
            rawValue
        }
    }

    /// T-22: the single always-present, always-space-filling panel that
    /// replaced the old collapsible transcript strip and the separate
    /// width-gated sections rail. Both tabs share one card chrome and one
    /// `maxHeight: .infinity`, so switching tabs never changes how much of
    /// the window the panel claims — only what's inside it.
    private var contentPanel: some View {
        VStack(spacing: 12) {
            Picker("", selection: $panelTab) {
                ForEach(ContentTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 260)

            Group {
                switch panelTab {
                case .transcript: transcriptPanel
                case .sections: sectionsListContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .voqoraSurface(.raised, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
        }
        .frame(minHeight: 220, maxHeight: .infinity)
    }

    @ViewBuilder
    private var transcriptPanel: some View {
        if let transcript = bookVM.currentTranscript {
            ScrollViewReader { proxy in
                ScrollView {
                    // T-21: an unbounded reading width made the transcript
                    // stretch edge-to-edge in a wide window — lines far
                    // longer than comfortable reading measure, another
                    // shape of "doesn't adapt well to window size." Capped
                    // and centered instead, like any real reading surface.
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(orderedPages(transcript), id: \.page) { entry in
                            let isCurrent = isCurrentPage(entry.page, in: transcript)
                            transcriptRow(entry, isCurrent: isCurrent, in: transcript)
                                .id(entry.page)
                        }
                    }
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                    .padding(24)
                    // T-13 fix: the real signal for "the user is manually
                    // scrolling" is AppKit's willStartLiveScrollNotification
                    // (trackpad/wheel/scrollbar), bridged via LiveScrollDetector
                    // above. Placed on the scrollable content itself (not the
                    // ScrollView container) so it becomes a descendant of the
                    // real underlying NSScrollView and enclosingScrollView
                    // resolves correctly.
                    .background(
                        LiveScrollDetector(onLiveScroll: { userScrolledAt = Date() })
                    )
                }
                // Kept as a supplementary fallback for a direct click-drag
                // on the content (not the common case on macOS, but harmless
                // to also catch).
                .simultaneousGesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { _ in userScrolledAt = Date() }
                )
                // T-13: scroll to the current page immediately the first
                // time this branch mounts — i.e. the first time the panel
                // is shown with a transcript already loaded, or the first
                // time a transcript arrives while the panel is already
                // open. SwiftUI preserves this branch's identity (no
                // re-mount, no re-fire) while `bookVM.currentTranscript`
                // stays non-nil, so this does not re-trigger just because
                // the transcript's content changes mid-session.
                .onAppear {
                    if let page = currentPageID(in: transcript) {
                        proxy.scrollTo(page, anchor: .center)
                    }
                }
                // S8/T-12: only scroll when the *current page* changes,
                // not on every render. T-13: suppressed for a short
                // window after a detected manual scroll so auto-scroll
                // doesn't fight a user reading ahead/back.
                // Fires whenever the *paragraph* being narrated changes —
                // every few seconds — rather than only at page boundaries
                // two to three minutes apart, so the highlighted sentence
                // stays on screen instead of drifting off it. Still
                // suppressed for a window after a detected manual scroll so
                // auto-scroll doesn't fight a reader who has moved away.
                .onChange(of: currentScrollAnchor(in: transcript)) { _, newAnchor in
                    guard let newAnchor else { return }
                    guard Self.shouldAutoScroll(userScrolledAt: userScrolledAt, now: Date()) else { return }
                    withAnimation(.easeOut(duration: 0.4)) {
                        proxy.scrollTo(newAnchor, anchor: .center)
                    }
                }
            }
        } else {
            ProgressView().tint(accentColor).padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A page whose `status` is set means its transcript text doesn't match
    /// its audio (TTS/cleaning failed and it was replaced with silence, or
    /// it's a byte-identical duplicate that was never narrated) — mark it
    /// distinctly instead of rendering it identically to a normally-narrated
    /// page. See jira-audiobook-quality.md T-1.
    private func transcriptRow(_ entry: PageEntry, isCurrent: Bool, in t: AudiobookService.Transcript) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let status = entry.status {
                Label(Self.pageStatusCaption(for: status), systemImage: Self.pageStatusIcon(for: status))
                    .font(vm.appFont(size: 10, weight: .bold))
                    .foregroundStyle(Palette.warning)
            }
            if isCurrent, entry.status == nil {
                // Only the playing page pays for sentence splitting — a
                // reader isn't watching every other page tick in real time.
                // One view per paragraph so each is an addressable scroll
                // target; see ParagraphAnchor.
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(currentPageParagraphs(entry, in: t).enumerated()), id: \.offset) { index, paragraph in
                        paragraph
                            .lineSpacing(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(ParagraphAnchor(page: entry.page, paragraph: index))
                    }
                }
            } else {
                // T-21: was `Text(entry.text)` verbatim — any single line
                // break the cleanup pass left in the raw string (a soft wrap,
                // a source line that never got reflowed) rendered as a
                // mid-sentence break, and pages with no separators at all
                // rendered as one dense, "raw"-looking wall of text. Reflowing
                // through the same paragraph grouping the highlighted page
                // uses keeps every page in the transcript consistently
                // formatted, whether or not it's currently playing.
                // Rendered per paragraph, like the playing page, so headings
                // get heading typography everywhere rather than only on the one
                // row that happens to be playing.
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(Self.splitIntoParagraphs(entry.text).enumerated()), id: \.offset) { _, paragraph in
                        let heading = entry.status == nil && Self.isHeadingLike(paragraph)
                        Text(paragraph)
                            .font(vm.appFont(size: heading ? 17 : 14, weight: heading ? .bold : .regular))
                            .lineSpacing(6)
                            .foregroundStyle(
                                entry.status != nil
                                    ? Palette.textTertiary
                                    : (heading ? Palette.textPrimary : Palette.textSecondary)
                            )
                            .italic(entry.status != nil)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Highlights only the sentence estimated to be playing right now,
    /// instead of bolding the whole page. Only a per-page start timestamp
    /// exists (no per-sentence timing from the backend), so the sentence is
    /// estimated by interpolating playback progress through the page's time
    /// window proportionally across its sentences' character lengths — an
    /// estimate, not exact, but far tighter than "the whole paragraph."
    /// T-21: previously flattened the whole page into one sentence array via
    /// `splitIntoSentences(entry.text)` and rejoined every sentence with a
    /// single space, unconditionally — throwing away every paragraph break
    /// the cleanup pass had produced. That made the one page a reader is
    /// actually looking at (the currently-playing one) the *worst*-formatted
    /// row in the transcript: a single dense run-on block regardless of how
    /// well-structured the source text was. Now sentences are split per
    /// paragraph (`Self.splitIntoParagraphs`) and paragraph breaks are
    /// re-inserted between blocks, while the current-sentence index is still
    /// computed over the full flattened list so timing/highlight behavior
    /// (and its existing test coverage) is unchanged.
    /// Scroll target inside the transcript: one paragraph of one page.
    ///
    /// Auto-scroll used to anchor to whole pages. A page is ~400 words — two
    /// to three minutes of audio — while the highlight advances sentence by
    /// sentence, so on any page taller than the viewport the highlighted
    /// sentence drifted off screen within seconds and nothing brought it back
    /// until the next page boundary minutes later. That is what "auto-scroll
    /// doesn't work" meant in practice: it was working exactly as written, at
    /// a granularity far too coarse to be useful.
    struct ParagraphAnchor: Hashable {
        let page: Int
        let paragraph: Int
    }

    /// Populates `highlightCache` for `entry` if it isn't already current.
    ///
    /// `text` is part of the key, not just `(bookID, page)`: a page's text can
    /// be rewritten under the same identity — a retried page, or one
    /// re-cleaned while the book is still generating — and keying on identity
    /// alone pinned the stale sentence split forever.
    private func refreshHighlightCacheIfNeeded(_ entry: PageEntry, in t: AudiobookService.Transcript) {
        guard highlightCache.bookID != t.bookID
            || highlightCache.page != entry.page
            || highlightCache.text != entry.text
        else { return }
        highlightCache.bookID = t.bookID
        highlightCache.page = entry.page
        highlightCache.text = entry.text
        // Split paragraph -> line -> sentence, not paragraph -> sentence. The
        // cleanup pass puts list items and table rows on deliberate separate
        // lines; flattening a paragraph straight to sentences threw those line
        // breaks away, so a table rebuilt here rendered as one run-on line even
        // though the stored text and splitIntoParagraphs had both preserved it.
        highlightCache.linesByParagraph = Self.splitIntoParagraphs(entry.text).map { paragraph in
            paragraph.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { Self.splitIntoSentences($0) }
        }
        highlightCache.sentencesByParagraph = highlightCache.linesByParagraph.map { $0.flatMap(\.self) }
        highlightCache.allSentences = highlightCache.sentencesByParagraph.flatMap(\.self)
        highlightCache.lastCurrentIndex = nil
        highlightCache.cachedParagraphs = nil
    }

    /// Index of the sentence estimated to be playing right now, or nil when
    /// this page has no usable timing to interpolate through.
    private func currentSentence(_ entry: PageEntry, in t: AudiobookService.Transcript) -> Int? {
        refreshHighlightCacheIfNeeded(entry, in: t)
        guard highlightCache.allSentences.count > 1,
              let window = pageTimeWindow(for: entry.page, in: t) else { return nil }
        return Self.currentSentenceIndex(
            in: highlightCache.allSentences,
            pageStart: window.start,
            pageEnd: window.end,
            at: audio.currentTime
        )
    }

    /// The playing page as one `Text` per paragraph, with only the sentence
    /// estimated to be playing right now emphasized.
    ///
    /// Returns an array rather than one concatenated `Text` so each paragraph
    /// can carry its own `.id` and therefore be a scroll target — a single
    /// `Text` is one view and can only be scrolled to as a whole, which is
    /// what limited auto-scroll to page granularity.
    ///
    /// Only a per-page start timestamp exists (no per-sentence timing from the
    /// backend), so the sentence is estimated by interpolating playback
    /// progress through the page's time window proportionally across its
    /// sentences' character lengths — an estimate, but far tighter than
    /// highlighting the whole paragraph. Memoized so a 0.1s playback tick only
    /// rebuilds when the highlighted sentence actually moves.
    private func currentPageParagraphs(_ entry: PageEntry, in t: AudiobookService.Transcript) -> [Text] {
        refreshHighlightCacheIfNeeded(entry, in: t)
        guard let current = currentSentence(entry, in: t) else {
            return [
                Text(Self.reflowedText(entry.text))
                    .font(vm.appFont(size: 15, weight: .bold))
                    .foregroundStyle(accentColor),
            ]
        }
        if let cached = highlightCache.cachedParagraphs, highlightCache.lastCurrentIndex == current {
            return cached
        }

        var built: [Text] = []
        var globalIndex = 0
        for (paragraphIndex, sentences) in highlightCache.sentencesByParagraph.enumerated() {
            let joined = sentences.joined(separator: " ")
            if Self.isHeadingLike(joined) {
                // Rendered whole rather than per sentence: a heading is one
                // short phrase, and an outer .font() cannot override the fonts
                // already baked into concatenated Text pieces.
                let isCurrentHeading = (globalIndex ... globalIndex + sentences.count).contains(current)
                built.append(
                    Text(joined)
                        .font(vm.appFont(size: 17, weight: .bold))
                        .foregroundStyle(isCurrentHeading ? accentColor : Palette.textPrimary)
                )
                globalIndex += sentences.count
                continue
            }
            var paragraph: Text?
            for line in highlightCache.linesByParagraph[paragraphIndex] {
                var isFirstOfLine = true
                for sentence in line {
                    let isCurrentSentence = globalIndex == current
                    let piece = Text(sentence)
                        .font(vm.appFont(size: 14, weight: isCurrentSentence ? .bold : .regular))
                        .foregroundStyle(isCurrentSentence ? accentColor : Palette.textSecondary)
                    if paragraph == nil {
                        paragraph = piece
                    } else {
                        // Newline between lines, space within one -- this is what
                        // keeps a list item or table row on its own row.
                        paragraph = paragraph! + Text(isFirstOfLine ? "\n" : " ") + piece
                    }
                    isFirstOfLine = false
                    globalIndex += 1
                }
            }
            if let paragraph {
                built.append(paragraph)
            }
        }
        if built.isEmpty {
            built = [Text(Self.reflowedText(entry.text))]
        }
        highlightCache.lastCurrentIndex = current
        highlightCache.cachedParagraphs = built
        return built
    }

    /// The paragraph the reader should be looking at right now — the auto-scroll
    /// target. Falls back to the page's first paragraph when the current page
    /// has no usable timing or is a failed page (which renders as a single
    /// block with no per-paragraph anchors).
    private func currentScrollAnchor(in t: AudiobookService.Transcript) -> ParagraphAnchor? {
        guard let page = currentPageID(in: t) else { return nil }
        guard let entry = orderedPages(t).first(where: { $0.page == page }),
              entry.status == nil,
              let sentence = currentSentence(entry, in: t)
        else { return ParagraphAnchor(page: page, paragraph: 0) }
        return ParagraphAnchor(
            page: page,
            paragraph: Self.paragraphIndex(forSentence: sentence, in: highlightCache.sentencesByParagraph)
        )
    }

    /// Which paragraph a flat sentence index falls in. Pure — the sentence
    /// index is computed over every sentence on the page flattened together,
    /// so it has to be walked back to a paragraph to scroll to.
    static func paragraphIndex(forSentence sentence: Int, in sentencesByParagraph: [[String]]) -> Int {
        var remaining = sentence
        for (index, sentences) in sentencesByParagraph.enumerated() {
            if remaining < sentences.count {
                return index
            }
            remaining -= sentences.count
        }
        return max(0, sentencesByParagraph.count - 1)
    }

    /// The playing page's [start, end) time window: `end` is the next page
    /// chronologically (by start time, not necessarily page number + 1), or
    /// nil if this is the last page — callers fall back to `audio.duration`.
    private func pageTimeWindow(for page: Int, in t: AudiobookService.Transcript) -> (start: Double, end: Double?)? {
        refreshTranscriptCacheIfNeeded(t)
        let sorted = transcriptCache.sortedPageTimes
        guard let idx = sorted.firstIndex(where: { $0.page == page }) else { return nil }
        let start = sorted[idx].time
        let next = idx + 1 < sorted.count ? sorted[idx + 1].time : audio.duration
        return (start, next > start ? next : nil)
    }

    // MARK: - Transcript memoization (T-12)

    //
    // `orderedPages`/`currentPageID`/`currentSection` used to re-sort the
    // whole transcript (or `book.sections`) from scratch on every render.
    // `pages`/`pageToTime`/`sections` are static for a given loaded
    // transcript/book — only `audio.currentTime` changes per tick — so the
    // sort is cached (`transcriptCache`/`sectionsCache`, refreshed only when
    // the underlying data actually changes) and the current position is
    // found via binary search against that cached, sorted array.

    private func orderedPages(_ t: AudiobookService.Transcript) -> [PageEntry] {
        refreshTranscriptCacheIfNeeded(t)
        return transcriptCache.orderedPages
    }

    private func currentPageID(in t: AudiobookService.Transcript) -> Int? {
        refreshTranscriptCacheIfNeeded(t)
        return Self.currentPageID(in: transcriptCache.sortedPageTimes, at: audio.currentTime)
    }

    private func isCurrentPage(_ page: Int, in t: AudiobookService.Transcript) -> Bool {
        currentPageID(in: t) == page
    }

    // Keyed on the transcript's *content*, not just its book identity, the way
    // refreshSectionsCacheIfNeeded already compares `sourceSections`. Guarding
    // on bookID alone meant the cache never refreshed while a book was still
    // generating: pages stream in under the same bookID, so the panel froze at
    // whatever subset had arrived when it first rendered and never showed the
    // rest. Comparing counts (not the full dictionaries) keeps this cheap
    // enough to run on every render, which is the point of the cache.
    private func refreshTranscriptCacheIfNeeded(_ t: AudiobookService.Transcript) {
        guard transcriptCache.bookID != t.bookID
            || transcriptCache.pageCount != t.pages.count
            || transcriptCache.timeCount != t.pageToTime.count
        else { return }
        transcriptCache.bookID = t.bookID
        transcriptCache.pageCount = t.pages.count
        transcriptCache.timeCount = t.pageToTime.count
        transcriptCache.orderedPages = Self.sortPages(t.pages, pageStatus: t.pageStatus)
        transcriptCache.sortedPageTimes = Self.sortPageTimes(t.pageToTime)
    }

    // `bookVM.currentSection(in:)` already implements this lookup, but it
    // lives in AudiobookViewModel.swift, which is out of scope for this
    // task (owned by a parallel work stream in this sprint) — so the
    // memoized version is kept local to this view rather than editing that
    // file. `book.sections` is small, so re-comparing it per render (to
    // decide whether the cache needs a refresh) is cheap; the win is
    // avoiding the re-sort + linear scan on every tick.
    private func currentSection() -> AudiobookSection? {
        refreshSectionsCacheIfNeeded()
        return Self.currentSection(in: sectionsCache.sortedSections, at: audio.currentTime)
    }

    private func refreshSectionsCacheIfNeeded() {
        guard sectionsCache.sourceSections != book.sections else { return }
        sectionsCache.sourceSections = book.sections
        sectionsCache.sortedSections = Self.sortSections(book.sections)
    }

    // MARK: - Sections tab

    /// T-22: was a separate fixed-260pt rail that vanished entirely below
    /// 1000pt with no replacement — Sections was simply unreachable at any
    /// window narrower than that. Now one tab of `contentPanel`, always
    /// reachable regardless of width, sharing the panel's chrome instead of
    /// carrying its own.
    private var sectionsListContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SECTIONS")
                    .font(vm.font(.sectionHeader))
                    .kerning(0.6)
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
                Text("\(book.sections.count)")
                    .font(vm.appFont(size: 11, weight: .bold).monospaced())
                    .foregroundStyle(accentColor)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(book.sections.sorted(by: { $0.startTime < $1.startTime })) { section in
                        sectionRow(section)
                    }
                    if book.sections.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "list.bullet.rectangle")
                                .font(.system(size: 28))
                                .foregroundStyle(Palette.textTertiary)
                            Text("No sections")
                                .font(vm.appFont(size: 11))
                                .foregroundStyle(Palette.textSecondary)
                        }
                        .padding(.top, 60)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func sectionRow(_ section: AudiobookSection) -> some View {
        let isCurrent = currentSection()?.id == section.id
        return HStack(spacing: 10) {
            Rectangle()
                .fill(isCurrent ? accentColor : Color.clear)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                    .font(vm.appFont(size: 12, weight: isCurrent ? .bold : .medium))
                    .foregroundStyle(isCurrent ? accentColor : Palette.textPrimary)
                    .lineLimit(2)
                Text("\(DurationFormatter.clock(section.startTime))  •  pp. \(section.startPage)–\(section.endPage)")
                    .font(vm.appFont(size: 9, weight: .medium).monospaced())
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isCurrent ? accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { bookVM.seek(toSeconds: section.startTime) }
    }

    private func adjustSpeed(_ delta: Double) {
        let raw = ((playerSpeed + delta) * 100).rounded() / 100
        let clamped = min(2.0, max(0.75, raw))
        playerSpeed = clamped
        bookVM.defaultBookSpeed = clamped
        audio.setPlaybackRate(Float(clamped))
    }

    private var prettyTitle: String {
        book.displayTitle
    }
}

// MARK: - Pure, testable logic (T-12, T-13)

///
/// Extracted as `internal` static members (rather than `private`) so
/// `VoqoraTests` can exercise them directly via `@testable import Voqora`,
/// matching the `AudiobookViewModel.libraryPollInterval`/
/// `DashboardViewModel.heartbeatDelay` extraction precedent.
extension AudiobookPlayerView {
    /// One transcript page's number and clean text, sorted ascending by
    /// page number. `status` mirrors the backend's `page_status` map
    /// ("tts_failed" / "cleaning_failed" / "duplicate") — nil for a
    /// normally-narrated page. See jira-audiobook-quality.md T-1.
    struct PageEntry: Equatable {
        let page: Int
        let text: String
        let status: String?

        init(page: Int, text: String, status: String? = nil) {
            self.page = page
            self.text = text
            self.status = status
        }
    }

    /// One transcript page's number and audio start time, sorted ascending
    /// by `time` so `currentPageID(in:at:)` can binary-search it.
    struct PageTimeEntry: Equatable {
        let page: Int
        let time: Double
    }

    /// Reference type holding the memoized per-transcript sort. Held in
    /// `@State` as a class (not a struct) so refreshing it in place during
    /// body evaluation never reassigns the `@State` property itself — only
    /// that reassignment is what SwiftUI treats as a state change worth an
    /// extra render.
    final class TranscriptPageCache {
        var bookID: String?
        var pageCount: Int = -1
        var timeCount: Int = -1
        var orderedPages: [PageEntry] = []
        var sortedPageTimes: [PageTimeEntry] = []
    }

    /// Reference type holding the memoized `book.sections` sort. Same
    /// in-place-mutation rationale as `TranscriptPageCache`.
    final class SectionsCache {
        var sourceSections: [AudiobookSection] = []
        var sortedSections: [AudiobookSection] = []
    }

    /// Memoizes `currentPageParagraphs`' paragraph/sentence split (depends only on
    /// the page's text) and its built `Text` tree (depends on the estimated
    /// current-sentence index, which advances far slower than the 0.1s
    /// playback tick that used to rebuild it every time). Same
    /// in-place-mutated-@State-class rationale as `TranscriptPageCache`.
    final class HighlightCache {
        var bookID: String?
        var page: Int?
        var text: String = ""
        var linesByParagraph: [[[String]]] = []
        var sentencesByParagraph: [[String]] = []
        var allSentences: [String] = []
        var lastCurrentIndex: Int?
        var cachedParagraphs: [Text]?
    }

    /// Sorted ascending by page number. Pure — the transcript's `pages`
    /// dict keys are page numbers as strings; a key that isn't a valid
    /// `Int` is dropped rather than crashing on malformed data. `pageStatus`
    /// is optional/additive (nil for transcripts from before T-1 shipped).
    static func sortPages(_ pages: [String: String], pageStatus: [String: String]? = nil) -> [PageEntry] {
        pages
            .compactMap { key, text -> PageEntry? in
                Int(key).map { PageEntry(page: $0, text: text, status: pageStatus?[key]) }
            }
            .sorted { $0.page < $1.page }
    }

    /// Sorted ascending by `time`, as required by `currentPageID(in:at:)`'s
    /// binary search.
    static func sortPageTimes(_ pageToTime: [String: Double]) -> [PageTimeEntry] {
        pageToTime
            .compactMap { key, time -> PageTimeEntry? in Int(key).map { PageTimeEntry(page: $0, time: time) } }
            .sorted { $0.time < $1.time }
    }

    static func sortSections(_ sections: [AudiobookSection]) -> [AudiobookSection] {
        sections.sorted { $0.startTime < $1.startTime }
    }

    /// User-facing caption for a marked page's backend `page_status` value.
    /// Falls back to a generic message for a status string this build
    /// doesn't recognize, rather than showing nothing.
    static func pageStatusCaption(for status: String) -> String {
        switch status {
        case "tts_failed": "Audio unavailable for this page"
        case "cleaning_failed": "This page could not be cleaned"
        case "duplicate": "Duplicate page (not narrated)"
        default: "This page was not narrated normally"
        }
    }

    static func pageStatusIcon(for status: String) -> String {
        switch status {
        case "duplicate": "doc.on.doc"
        default: "exclamationmark.triangle.fill"
        }
    }

    /// The page whose narration is currently playing: the last page (by
    /// start time) at or before `time`. `sortedTimes` must already be
    /// sorted ascending by `time` (see `sortPageTimes`). O(log n).
    static func currentPageID(in sortedTimes: [PageTimeEntry], at time: Double) -> Int? {
        guard let idx = lastIndex(in: sortedTimes, where: { $0.time }, atOrBefore: time) else { return nil }
        return sortedTimes[idx].page
    }

    /// Splits page text into sentences for within-page highlight
    /// granularity, using NaturalLanguage's sentence tokenizer (handles
    /// abbreviations/decimals/etc. far better than splitting on ". ").
    /// Falls back to the whole string as one "sentence" if tokenization
    /// finds no boundaries (e.g. a page with no terminal punctuation).
    static func splitIntoSentences(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex ..< text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
            return true
        }
        return sentences.isEmpty ? [text] : sentences
    }

    /// Groups a page's raw text into paragraphs: a run of one or more
    /// consecutive non-blank lines, joined with a single space (this also
    /// reflows a soft-wrapped line that never got joined upstream), with any
    /// blank line acting as a paragraph boundary. Falls back to the whole
    /// trimmed string as one paragraph if there's no blank-line structure at
    /// all — text from before the cleanup pass started emitting paragraph
    /// breaks still renders as continuous prose instead of empty.
    /// Whether a block reads as a heading rather than body prose.
    ///
    /// The cleanup pass emits headings as their own short block with a blank
    /// line either side and no terminal punctuation (both the local normalizer
    /// and the Gemini prompt are explicit about this), which is exactly the
    /// shape this matches. Without it every heading rendered in the same size
    /// and weight as body text, so a transcript had no visible structure at all
    /// — just an unbroken column of paragraphs.
    ///
    /// Deliberately conservative: a false negative renders a heading as
    /// ordinary prose, which is merely plain. A false positive would blow up a
    /// real sentence into a title, which looks broken — hence the length cap
    /// and the single-line and no-terminal-punctuation requirements.
    static func isHeadingLike(_ paragraph: String) -> Bool {
        let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 70 else { return false }
        guard !trimmed.contains("\n") else { return false }
        guard let last = trimmed.last, !".!?,;:".contains(last) else { return false }
        // A heading is a title, not a clause — several words at most.
        return trimmed.split(separator: " ").count <= 12
    }

    /// Sentence-ending punctuation, used to tell a soft wrap from a deliberate
    /// line break. Includes closing quotes and brackets so `... end."` counts.
    private static let sentenceEnders: Set<Character> = [".", "!", "?", ":", ";", "\"", "'", ")", "]", "\u{201D}", "\u{2019}"]

    /// Joins a block's lines, preserving *deliberate* line breaks.
    ///
    /// This used to join every line with a space unconditionally, which fixed
    /// mid-sentence breaks from a source document's hard wrapping but also
    /// flattened structure the cleanup pass had put there on purpose — a
    /// five-item list and every row of a table collapsed into one dense blob,
    /// which is the opposite of following along.
    ///
    /// The two cases are told apart the same way the backend's reflow does it:
    /// a line broken mid-sentence ends on a word or a comma, a complete one
    /// ends on terminal punctuation. So lines are joined with a space only when
    /// the previous one did not finish a sentence, and kept on separate lines
    /// otherwise. Applies to transcripts written before this change too, whose
    /// soft wraps still join correctly.
    static func joinLines(_ lines: [String]) -> String {
        var result = ""
        for line in lines {
            guard let last = result.last else {
                result = line
                continue
            }
            result += sentenceEnders.contains(last) ? "\n" : " "
            result += line
        }
        return result
    }

    static func splitIntoParagraphs(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var paragraphs: [String] = []
        var current: [String] = []
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !current.isEmpty {
                    paragraphs.append(Self.joinLines(current))
                    current = []
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty {
            paragraphs.append(Self.joinLines(current))
        }
        if paragraphs.isEmpty {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        return paragraphs
    }

    /// A page's text reflowed into blank-line-separated paragraphs, for
    /// display. Idempotent on text that's already well-formatted.
    static func reflowedText(_ text: String) -> String {
        splitIntoParagraphs(text).joined(separator: "\n\n")
    }

    /// Estimates which sentence within a page is currently being spoken by
    /// interpolating `time`'s position across [pageStart, pageEnd)
    /// proportionally over the sentences' character lengths. This is an
    /// estimate — only a page-start timestamp exists, not per-sentence ones
    /// — but it tracks TTS pacing far more tightly than highlighting the
    /// whole page for its entire duration.
    static func currentSentenceIndex(
        in sentences: [String],
        pageStart: Double,
        pageEnd: Double?,
        at time: Double
    ) -> Int? {
        guard !sentences.isEmpty else { return nil }
        guard sentences.count > 1 else { return 0 }
        guard let pageEnd, pageEnd > pageStart else { return 0 }

        let progress = min(max((time - pageStart) / (pageEnd - pageStart), 0), 1)
        let charCounts = sentences.map(\.count)
        let totalChars = charCounts.reduce(0, +)
        guard totalChars > 0 else { return 0 }

        let target = progress * Double(totalChars)
        var cumulative = 0.0
        for (idx, count) in charCounts.enumerated() {
            cumulative += Double(count)
            if target < cumulative {
                return idx
            }
        }
        return sentences.count - 1
    }

    /// The section currently playing: the last section (by start time) at
    /// or before `time`. `sortedSections` must already be sorted ascending
    /// by `startTime` (see `sortSections`). O(log n).
    static func currentSection(in sortedSections: [AudiobookSection], at time: Double) -> AudiobookSection? {
        guard let idx = lastIndex(in: sortedSections, where: { $0.startTime }, atOrBefore: time) else { return nil }
        return sortedSections[idx]
    }

    /// Index of the last element whose value (per `keyOf`) is <= `target`,
    /// assuming `array` is sorted ascending by that value — i.e. the
    /// standard "current position in a timeline" binary search. O(log n)
    /// instead of the `sorted().last(where:)` O(n log n + n) it replaces.
    static func lastIndex<T>(in array: [T], where keyOf: (T) -> Double, atOrBefore target: Double) -> Int? {
        var low = 0
        var high = array.count - 1
        var result: Int?
        while low <= high {
            let mid = (low + high) / 2
            if keyOf(array[mid]) <= target {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    /// T-13: how long auto-scroll stays suppressed after a detected manual
    /// scroll. Matches the toast auto-dismiss duration used elsewhere in
    /// this feature, for consistency.
    /// How long a manual scroll suppresses auto-scroll.
    ///
    /// Was 4s, which was harmless when auto-scroll only fired at page
    /// boundaries minutes apart — the window had almost no chance to matter.
    /// Now that scrolling tracks the narrated paragraph and fires every few
    /// seconds, 4s means a reader who scrolls back to re-read something gets
    /// yanked forward again almost immediately. Long enough to read a
    /// paragraph or two undisturbed, short enough that tracking resumes on its
    /// own without the reader having to do anything.
    static let userScrollPauseDuration: TimeInterval = 12

    /// Whether the transcript should auto-scroll to the current page right
    /// now, given when the user last manually scrolled (if ever).
    static func shouldAutoScroll(userScrolledAt: Date?, now: Date) -> Bool {
        guard let userScrolledAt else { return true }
        return now.timeIntervalSince(userScrolledAt) >= userScrollPauseDuration
    }
}

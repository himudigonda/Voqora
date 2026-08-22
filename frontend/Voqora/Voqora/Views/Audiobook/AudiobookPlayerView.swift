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

    let book: Audiobook
    @State private var localScrub: Double = 0
    @State private var dragging = false
    @State private var playerSpeed: Double = 1.0
    @State private var transcriptOpen = false
    @State private var dominantColor: Color = .cyan
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

    private let baseURL = URL(string: "http://127.0.0.1:10101")!

    var body: some View {
        GeometryReader { geometry in
            let visibility = AudiobookPlayerLayout.columnVisibility(for: geometry.size.width)
            ZStack(alignment: .topTrailing) {
                background
                HStack(alignment: .top, spacing: 24) {
                    if visibility.showCover {
                        coverColumn
                    }
                    centerColumn
                    if visibility.showRail {
                        sectionsRail
                    }
                }
                .padding(28)

                sleepTimerMenu
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
        .onKeyPress(.rightArrow) { bookVM.skip(by: 15); return .handled }
        .onKeyPress("j") { bookVM.skip(by: -15); return .handled }
        .onKeyPress("l") { bookVM.skip(by: 15); return .handled }
        .onKeyPress("n") { bookVM.jumpToNextSection(in: book); return .handled }
        .onKeyPress("p") { bookVM.jumpToPreviousSection(in: book); return .handled }
        .onKeyPress("[") { adjustSpeed(-0.25); return .handled }
        .onKeyPress("]") { adjustSpeed(0.25); return .handled }
        .onKeyPress(",") {
            if let s = currentSection() { bookVM.seek(toSeconds: s.startTime) }
            return .handled
        }
        .onKeyPress(".") { bookVM.jumpToNextSection(in: book); return .handled }
        // T-11: the ticker's one non-cosmetic side effect (cancelling a
        // "sleep until end of book" timer once playback naturally
        // completes) now runs off the real `audio.playbackCompleted`
        // publisher instead of a 0.25s poke.
        .onChange(of: audio.playbackCompleted) { _, completed in
            if completed && bookVM.sleepUntilEndOfBook {
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
            let coverURL = baseURL.appendingPathComponent("audiobook/\(book.bookID)/cover")
            Task {
                let color = await CoverColorExtractor.shared.dominantColor(for: coverURL)
                dominantColor = color
            }
        }
        .onDisappear {
            bookVM.isPlayerViewActive = false
        }
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            Color(.windowBackgroundColor)
            Circle()
                .fill(dominantColor.opacity(colorScheme == .dark ? 0.32 : 0.14))
                .frame(width: 450, height: 450)
                .blur(radius: 120)
                .offset(x: -180, y: -120)
            Circle()
                .fill(dominantColor.opacity(colorScheme == .dark ? 0.22 : 0.10))
                .frame(width: 360, height: 360)
                .blur(radius: 100)
                .offset(x: 220, y: 220)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: dominantColor)
    }

    // MARK: - Cover column

    private var coverColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .frame(width: 240, height: 336)
                AsyncImage(url: baseURL.appendingPathComponent("audiobook/\(book.bookID)/cover")) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Image(systemName: "book.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.cyan.opacity(0.6))
                }
                .frame(width: 240, height: 336)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .shadow(
                color: audio.isPlaying ? dominantColor.opacity(0.45) : .black.opacity(0.45),
                radius: audio.isPlaying ? 42 : 30,
                y: audio.isPlaying ? 20 : 16
            )
            .scaleEffect(audio.isPlaying ? 1.0 : 0.97)
            .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: audio.isPlaying)

            VStack(alignment: .leading, spacing: 6) {
                Text(currentSectionLabel)
                    .font(vm.appFont(size: 9, weight: .black))
                    .kerning(2)
                    .foregroundStyle(.cyan)
                Text(prettyTitle)
                    .font(vm.appFont(size: 22, weight: .bold))
                    .foregroundStyle(.primary)
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

    // MARK: - Center column

    private var centerColumn: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 28) {
                scrubberSection
                transportSection
            }
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                speedAndSleep
                if transcriptOpen {
                    transcriptPanel
                        .padding(.top, 16)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                transcriptToggle
                    .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        .fill(Color.primary.opacity(0.12))
                        .frame(height: 4)
                    // Filled portion
                    Capsule()
                        .fill(Color.cyan)
                        .frame(width: max(0, w * progress), height: 4)
                    // Section-boundary ticks
                    ForEach(book.sections) { section in
                        let total = max(1.0, book.totalAudioSeconds)
                        Capsule()
                            .fill(Color.primary.opacity(0.45))
                            .frame(width: 2, height: 10)
                            .offset(x: w * (section.startTime / total) - 1, y: -3)
                    }
                    // Thumb
                    Circle()
                        .fill(Color.white)
                        .frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                        .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
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
                        .foregroundStyle(.cyan)
                } else if bookVM.sleepUntilEndOfBook {
                    Label("Until end of book", systemImage: "moon.zzz.fill")
                        .font(vm.appFont(size: 10, weight: .bold))
                        .foregroundStyle(.cyan)
                }
                Spacer()
                Text("-" + DurationFormatter.clock(max(0, audio.duration - audio.currentTime)))
            }
            .font(vm.appFont(size: 11, weight: .medium).monospaced())
            .foregroundStyle(.secondary)
        }
    }

    private var displayProgress: Double {
        if dragging { return localScrub }
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
                Circle().fill(.white).frame(width: 72, height: 72)
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
                    .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26, weight: .black))
                    .foregroundStyle(.black)
                    .offset(x: audio.isPlaying ? 0 : 2)
            }
        }
        .buttonStyle(.plain)
        .shadow(color: .cyan.opacity(0.4), radius: 18)
    }

    private func transportSmall(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(Color.primary.opacity(0.06), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
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
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().stroke(.cyan.opacity(0.45), lineWidth: 1))
            }
            .buttonStyle(.plain)

            Spacer()

            HStack(spacing: 8) {
                Image(systemName: audio.volume < 0.05 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                Slider(value: Binding(
                    get: { Double(audio.volume) },
                    set: { audio.setVolume(Float($0)) }
                ), in: 0...1.5)
                .tint(.cyan)
                .frame(width: 110)
            }

            if bookVM.sleepRemainingSeconds != nil || bookVM.sleepUntilEndOfBook {
                Button { bookVM.cancelSleepTimer() } label: {
                    Label("Cancel Sleep", systemImage: "moon.zzz.fill")
                        .font(vm.appFont(size: 11, weight: .bold))
                        .foregroundStyle(.cyan)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().stroke(.cyan.opacity(0.45), lineWidth: 1))
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
                .foregroundStyle(bookVM.sleepRemainingSeconds == nil && !bookVM.sleepUntilEndOfBook ? Color.secondary : Color.cyan)
                .frame(width: 32, height: 32)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
        .help("Sleep timer")
    }

    // MARK: - Transcript

    private var transcriptToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.3)) { transcriptOpen.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: transcriptOpen ? "chevron.up.circle" : "text.alignleft")
                    .font(.system(size: 12, weight: .medium))
                Text(transcriptOpen ? "Hide Transcript" : "Show Transcript")
                    .font(vm.appFont(size: 11, weight: .bold))
            }
            .foregroundStyle(transcriptOpen ? Color.cyan : Color.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .stroke(transcriptOpen ? Color.cyan.opacity(0.5) : Color.primary.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: transcriptOpen)
    }

    private var transcriptPanel: some View {
        Group {
            if let transcript = bookVM.currentTranscript {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(orderedPages(transcript), id: \.page) { entry in
                                let isCurrent = isCurrentPage(entry.page, in: transcript)
                                transcriptRow(entry, isCurrent: isCurrent, in: transcript)
                                    .id(entry.page)
                            }
                        }
                        .padding(20)
                    }
                    // T-13: user-scroll detection. macOS deployment target is
                    // 14.0 (below the 15.0 minimum for `.onScrollGeometryChange`),
                    // so a DragGesture is the documented fallback — it catches
                    // direct click-drag scrolling; it will not see a pure
                    // trackpad/scroll-wheel gesture, which AppKit's NSScrollView
                    // handles outside SwiftUI's gesture system. Good enough to
                    // suppress auto-scroll for the common "reading ahead" case.
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
                    .onChange(of: currentPageID(in: transcript)) { _, newPage in
                        guard let newPage else { return }
                        guard Self.shouldAutoScroll(userScrolledAt: userScrolledAt, now: Date()) else { return }
                        withAnimation(.easeOut(duration: 0.4)) {
                            proxy.scrollTo(newPage, anchor: .center)
                        }
                    }
                }
                .frame(height: 220)
                .background(.ultraThinMaterial.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                )
            } else {
                ProgressView().tint(.cyan).padding()
            }
        }
    }

    /// A page whose `status` is set means its transcript text doesn't match
    /// its audio (TTS/cleaning failed and it was replaced with silence, or
    /// it's a byte-identical duplicate that was never narrated) — mark it
    /// distinctly instead of rendering it identically to a normally-narrated
    /// page. See jira-audiobook-quality.md T-1.
    @ViewBuilder
    private func transcriptRow(_ entry: PageEntry, isCurrent: Bool, in t: AudiobookService.Transcript) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let status = entry.status {
                Label(Self.pageStatusCaption(for: status), systemImage: Self.pageStatusIcon(for: status))
                    .font(vm.appFont(size: 10, weight: .bold))
                    .foregroundStyle(.orange)
            }
            if isCurrent, entry.status == nil {
                // Only the playing page pays for sentence splitting — a
                // reader isn't watching every other page tick in real time.
                currentPageText(entry, in: t)
            } else {
                Text(entry.text)
                    .font(vm.appFont(size: 13, weight: .regular))
                    .foregroundStyle(entry.status != nil ? Color.secondary.opacity(0.6) : Color.secondary)
                    .italic(entry.status != nil)
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
    private func currentPageText(_ entry: PageEntry, in t: AudiobookService.Transcript) -> Text {
        let sentences = Self.splitIntoSentences(entry.text)
        guard sentences.count > 1, let window = pageTimeWindow(for: entry.page, in: t) else {
            return Text(entry.text)
                .font(vm.appFont(size: 14, weight: .bold))
                .foregroundStyle(Color.cyan)
        }
        let current = Self.currentSentenceIndex(in: sentences, pageStart: window.start, pageEnd: window.end, at: audio.currentTime)

        return sentences.enumerated().reduce(Text("")) { acc, item in
            let (idx, sentence) = item
            let isCurrentSentence = idx == current
            let piece = Text(sentence)
                .font(vm.appFont(size: 13, weight: isCurrentSentence ? .bold : .regular))
                .foregroundStyle(isCurrentSentence ? Color.cyan : Color.secondary)
            return idx == 0 ? piece : acc + Text(" ") + piece
        }
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

    private func refreshTranscriptCacheIfNeeded(_ t: AudiobookService.Transcript) {
        guard transcriptCache.bookID != t.bookID else { return }
        transcriptCache.bookID = t.bookID
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

    // MARK: - Sections rail

    private var sectionsRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SECTIONS")
                    .font(vm.appFont(size: 11, weight: .black))
                    .kerning(2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(book.sections.count)")
                    .font(vm.appFont(size: 11, weight: .bold).monospaced())
                    .foregroundStyle(.cyan)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

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
                                .foregroundStyle(.tertiary)
                            Text("No sections")
                                .font(vm.appFont(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 60)
                    }
                }
                .padding(.vertical, 10)
            }
        }
        .frame(width: 260)
        .background(.ultraThinMaterial.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func sectionRow(_ section: AudiobookSection) -> some View {
        let isCurrent = currentSection()?.id == section.id
        return HStack(spacing: 10) {
            Rectangle()
                .fill(isCurrent ? Color.cyan : Color.clear)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                    .font(vm.appFont(size: 12, weight: isCurrent ? .bold : .medium))
                    .foregroundStyle(isCurrent ? Color.cyan : Color.primary)
                    .lineLimit(2)
                Text("\(DurationFormatter.clock(section.startTime))  •  pp. \(section.startPage)–\(section.endPage)")
                    .font(vm.appFont(size: 9, weight: .medium).monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isCurrent ? Color.cyan.opacity(0.12) : Color.clear)
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
        let t = book.title
        for ext in [".pdf", ".docx", ".txt", ".md"] {
            if t.lowercased().hasSuffix(ext) { return String(t.dropLast(ext.count)) }
        }
        return t
    }
}

// MARK: - Pure, testable logic (T-12, T-13)
//
// Extracted as `internal` static members (rather than `private`) so
// `VoqoraTests` can exercise them directly via `@testable import Voqora`,
// matching the `AudiobookViewModel.libraryPollInterval`/
// `DashboardViewModel.heartbeatDelay` extraction precedent.
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
        var orderedPages: [PageEntry] = []
        var sortedPageTimes: [PageTimeEntry] = []
    }

    /// Reference type holding the memoized `book.sections` sort. Same
    /// in-place-mutation rationale as `TranscriptPageCache`.
    final class SectionsCache {
        var sourceSections: [AudiobookSection] = []
        var sortedSections: [AudiobookSection] = []
    }

    /// Sorted ascending by page number. Pure — the transcript's `pages`
    /// dict keys are page numbers as strings; a key that isn't a valid
    /// `Int` is dropped rather than crashing on malformed data. `pageStatus`
    /// is optional/additive (nil for transcripts from before T-1 shipped).
    static func sortPages(_ pages: [String: String], pageStatus: [String: String]? = nil) -> [PageEntry] {
        pages
            .compactMap { (key, text) -> PageEntry? in
                Int(key).map { PageEntry(page: $0, text: text, status: pageStatus?[key]) }
            }
            .sorted { $0.page < $1.page }
    }

    /// Sorted ascending by `time`, as required by `currentPageID(in:at:)`'s
    /// binary search.
    static func sortPageTimes(_ pageToTime: [String: Double]) -> [PageTimeEntry] {
        pageToTime
            .compactMap { (key, time) -> PageTimeEntry? in Int(key).map { PageTimeEntry(page: $0, time: time) } }
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
        case "tts_failed": return "Audio unavailable for this page"
        case "cleaning_failed": return "This page could not be cleaned"
        case "duplicate": return "Duplicate page (not narrated)"
        default: return "This page was not narrated normally"
        }
    }

    static func pageStatusIcon(for status: String) -> String {
        switch status {
        case "duplicate": return "doc.on.doc"
        default: return "exclamationmark.triangle.fill"
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
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { sentences.append(sentence) }
            return true
        }
        return sentences.isEmpty ? [text] : sentences
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
            if target < cumulative { return idx }
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
    static let userScrollPauseDuration: TimeInterval = 4

    /// Whether the transcript should auto-scroll to the current page right
    /// now, given when the user last manually scrolled (if ever).
    static func shouldAutoScroll(userScrolledAt: Date?, now: Date) -> Bool {
        guard let userScrolledAt else { return true }
        return now.timeIntervalSince(userScrolledAt) >= userScrollPauseDuration
    }
}

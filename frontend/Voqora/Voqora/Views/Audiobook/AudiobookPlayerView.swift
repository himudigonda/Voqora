import Combine
import SwiftUI

struct AudiobookPlayerView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    let book: Audiobook
    @State private var localScrub: Double = 0
    @State private var dragging = false
    @State private var playerSpeed: Double = 1.0
    @State private var transcriptOpen = false
    @State private var ticker = Date()
    @State private var dominantColor: Color = .cyan

    private let baseURL = URL(string: "http://127.0.0.1:10101")!
    // Hardware-paced timer to push UI updates while audio is playing.
    private let tickerTimer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            background
            HStack(alignment: .top, spacing: 24) {
                coverColumn
                centerColumn
                sectionsRail
            }
            .padding(28)

            sleepTimerMenu
                .padding(.top, 16)
                .padding(.trailing, 20)
        }
        .frame(minWidth: 760, minHeight: 580)
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
            if let s = bookVM.currentSection(in: book) { bookVM.seek(toSeconds: s.startTime) }
            return .handled
        }
        .onKeyPress(".") { bookVM.jumpToNextSection(in: book); return .handled }
        .onReceive(tickerTimer) { now in
            ticker = now
            if bookVM.audio.playbackCompleted && bookVM.sleepUntilEndOfBook {
                bookVM.cancelSleepTimer()
            }
        }
        .onAppear {
            playerSpeed = bookVM.defaultBookSpeed
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
                color: bookVM.audio.isPlaying ? dominantColor.opacity(0.45) : .black.opacity(0.45),
                radius: bookVM.audio.isPlaying ? 42 : 30,
                y: bookVM.audio.isPlaying ? 20 : 16
            )
            .scaleEffect(bookVM.audio.isPlaying ? 1.0 : 0.97)
            .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: bookVM.audio.isPlaying)

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
        if let s = bookVM.currentSection(in: book) {
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
                Text(DurationFormatter.clock(bookVM.audio.currentTime))
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
                Text("-" + DurationFormatter.clock(max(0, bookVM.audio.duration - bookVM.audio.currentTime)))
            }
            .font(vm.appFont(size: 11, weight: .medium).monospaced())
            .foregroundStyle(.secondary)
        }
    }

    private var displayProgress: Double {
        if dragging { return localScrub }
        return bookVM.audio.progress
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
                Image(systemName: bookVM.audio.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26, weight: .black))
                    .foregroundStyle(.black)
                    .offset(x: bookVM.audio.isPlaying ? 0 : 2)
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
                Image(systemName: bookVM.audio.volume < 0.05 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                Slider(value: Binding(
                    get: { Double(bookVM.audio.volume) },
                    set: { bookVM.audio.setVolume(Float($0)) }
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
                            ForEach(orderedPages(transcript), id: \.0) { (pageNum, text) in
                                let isCurrent = isCurrentPage(pageNum, in: transcript)
                                Text(text)
                                    .id(pageNum)
                                    .font(vm.appFont(size: isCurrent ? 14 : 13, weight: isCurrent ? .bold : .regular))
                                    .foregroundStyle(isCurrent ? Color.cyan : Color.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(20)
                    }
                    // S8: only scroll when the *current page* changes, not on
                    // every 0.25 s ticker tick. Avoids the ScrollViewReader
                    // re-layout storm during normal playback.
                    .onChange(of: currentPageID(in: transcript)) { _, newPage in
                        guard let newPage else { return }
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

    private func orderedPages(_ t: AudiobookService.Transcript) -> [(Int, String)] {
        t.pages
            .compactMap { (k, v) -> (Int, String)? in Int(k).map { ($0, v) } }
            .sorted { $0.0 < $1.0 }
    }

    private func currentPageID(in t: AudiobookService.Transcript) -> Int? {
        let now = bookVM.audio.currentTime
        let times = t.pageToTime
            .compactMap { (k, v) -> (Int, Double)? in Int(k).map { ($0, v) } }
            .sorted { $0.1 < $1.1 }
        return times.last(where: { $0.1 <= now })?.0
    }

    private func isCurrentPage(_ page: Int, in t: AudiobookService.Transcript) -> Bool {
        currentPageID(in: t) == page
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
        let isCurrent = bookVM.currentSection(in: book)?.id == section.id
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
    }

    private var prettyTitle: String {
        var t = book.title
        for ext in [".pdf", ".docx", ".txt", ".md"] {
            if t.lowercased().hasSuffix(ext) { return String(t.dropLast(ext.count)) }
        }
        return t
    }
}

import SwiftUI
import UniformTypeIdentifiers

struct VoqoraWindow: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var audio: AudioService
    @EnvironmentObject var history: HistoryManager
    @EnvironmentObject var launchManager: LaunchManager
    @EnvironmentObject var bookVM: AudiobookViewModel
    @EnvironmentObject var onboarding: OnboardingCoordinator
    @EnvironmentObject var identity: IdentityService
    @EnvironmentObject var permissions: PermissionsService
    @Environment(\.colorScheme) var colorScheme
    @State private var globalDropHovering = false
    @State private var showOnboarding = false

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                // APP BRANDING HEADER
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.cyan.gradient)
                            .frame(width: 32, height: 32)
                        Image(systemName: "waveform")
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        Text("Voqora")
                            .font(vm.appFont(size: 16, weight: .bold))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)

                List(selection: $vm.selectedTab) {
                    Section(header: Text("Library").font(vm.appFont(size: 11, weight: .bold))) {
                        NavigationLink(value: "home") {
                            Label("Now Playing", systemImage: "play.circle.fill")
                                .font(vm.appFont(size: 13))
                        }
                        NavigationLink(value: "history") {
                            Label("The Vault", systemImage: "clock.arrow.circlepath")
                                .font(vm.appFont(size: 13))
                        }
                    }
                    Section(header: Text("Audiobooks").font(vm.appFont(size: 11, weight: .bold))) {
                        NavigationLink(value: "books") {
                            Label("Library", systemImage: "books.vertical.fill")
                                .font(vm.appFont(size: 13))
                        }
                        if let resume = bookVM.continueListeningBook {
                            Button {
                                vm.selectedTab = "books"
                                bookVM.play(resume)
                                bookVM.openPlayer(for: resume.bookID)
                            } label: {
                                HStack {
                                    Image(systemName: "play.circle")
                                        .foregroundStyle(.cyan)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text("Continue Listening")
                                            .font(vm.appFont(size: 13))
                                        Text(prettyTitleForResume(resume.title))
                                            .font(vm.appFont(size: 10))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)

                Spacer()

                // SYSTEM / PREFERENCES AT BOTTOM
                VStack(spacing: 8) {
                    Divider().padding(.horizontal, 20).opacity(0.3)

                    Button {
                        vm.selectedTab = "preferences"
                    } label: {
                        HStack {
                            Image(systemName: "gearshape.fill")
                            Text("Preferences")
                                .font(vm.appFont(size: 13, weight: .medium))
                            Spacer()
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(vm.selectedTab == "preferences" ? Color.cyan.opacity(0.15) : Color.clear)
                        .foregroundStyle(vm.selectedTab == "preferences" ? .cyan : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 8)

                // DEVELOPER ATTRIBUTION
                VStack(alignment: .leading, spacing: 6) {
                    Text("DEVELOPED BY")
                        .font(vm.appFont(size: 8, weight: .black))
                        .kerning(1)
                        .foregroundStyle(.secondary.opacity(0.5))

                    Text("Himansh Mudigonda")
                        .font(vm.appFont(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 18) {
                        Link(destination: URL(string: "https://github.com/himudigonda")!) {
                            Image("github") // Explicit Asset
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 36, height: 36)
                        }
                        .help("GitHub")

                        Link(destination: URL(string: "https://www.linkedin.com/in/himudigonda")!) {
                            Image("linkedin") // Explicit Asset
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 36, height: 36)
                        }
                        .help("LinkedIn")

                        Link(destination: URL(string: "https://himudigonda.me")!) {
                            Image(systemName: "globe") // System Icon
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 28, height: 28)
                                .padding(4)
                        }
                        .help("Website")
                    }
                    .foregroundStyle(.cyan)
                }
                .padding(24)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            ZStack(alignment: .bottom) {
                // MAIN CONTENT
                detailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onDrop(of: [.fileURL], isTargeted: $globalDropHovering, perform: handleGlobalPDFDrop)

                // Global drop overlay shown across any non-Audiobooks tab when a PDF is hovering.
                if globalDropHovering && vm.selectedTab != "books" {
                    globalDropOverlay
                        .transition(.opacity)
                }

                // FLOATING MINI PLAYER (Global) - Hide when on main dashboard to avoid duplicate bars
                if vm.status == .speaking || vm.status == .paused, vm.selectedTab != "home" {
                    miniPlayerHUD
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Audiobook now-playing bar — hidden while the player view
                // itself is on screen. Gated on isNowPlayingBarVisible
                // (nowPlaying != nil && !isPlayerViewActive), not just
                // nowPlaying alone: AudiobookPlayerView.onAppear calls
                // bookVM.play(book), so nowPlaying is non-nil for the whole
                // time the player is open — isPlayerViewActive is the real
                // "is the player on screen" signal (the v1.1 design notes Sprint 6, T6.1).
                if bookVM.isNowPlayingBarVisible, let playing = bookVM.nowPlaying {
                    NowPlayingBar(onTap: {
                        vm.selectedTab = "books"
                        bookVM.openPlayer(for: playing.bookID)
                    })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .environmentObject(vm)
                    .environmentObject(bookVM)
                }

                // Toast / banner — top of detail pane.
                VStack {
                    AudiobookToastView()
                        .environmentObject(vm)
                        .environmentObject(bookVM)
                    Spacer()
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: bookVM.toast?.id)
            }
            .background(adaptiveBackdrop)
            // Keyed on the bar's actual visibility (not just nowPlaying's
            // bookID) so the transition also animates when isPlayerViewActive
            // alone flips — e.g. navigating back to the library while the
            // same book keeps playing (the v1.1 design notes Sprint 6, T6.1).
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: bookVM.isNowPlayingBarVisible)
        }
        .frame(minWidth: 800, minHeight: 600)
        .preferredColorScheme(vm.appTheme == "system" ? nil : (vm.appTheme == "dark" ? .dark : .light))
        .sheet(isPresented: $vm.showUpdateSheet) {
            UpdateView()
                .environmentObject(vm)
        }
        .alert(
            "You're Up to Date",
            isPresented: Binding(
                get: { vm.upToDateNotice != nil },
                set: {
                    if !$0 {
                        vm.upToDateNotice = nil
                    }
                }
            ),
            presenting: vm.upToDateNotice
        ) { _ in
            Button("OK", role: .cancel) { vm.upToDateNotice = nil }
        } message: { msg in
            Text(msg)
        }
        .onAppear {
            // Background check for updates on startup
            vm.checkForUpdates(manual: false)

            // Prepare backend if needed
            Task {
                await launchManager.prepare()
            }

            // First-launch onboarding (S1-E1). Defer one runloop so the
            // window has fully appeared before the sheet animates in.
            if onboarding.needsOnboarding {
                DispatchQueue.main.async {
                    showOnboarding = true
                }
            }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView()
                .environmentObject(onboarding)
                .environmentObject(permissions)
                .environmentObject(identity)
                .environmentObject(vm)
                .interactiveDismissDisabled(true)
        }
        .onChange(of: onboarding.version) { _, _ in
            if !onboarding.needsOnboarding {
                showOnboarding = false
            } else {
                showOnboarding = true
            }
        }
        .overlay {
            if !launchManager.isReady {
                ZStack {
                    adaptiveBackdrop

                    VStack(spacing: 20) {
                        if let error = launchManager.error {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 40))
                                .foregroundStyle(.red)
                            Text("Launch Failed").font(vm.appFont(size: 18, weight: .bold))
                            Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)

                            Button("Try Again") {
                                launchManager.error = nil
                                Task { await launchManager.prepare() }
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            ProgressView()
                            Text("Initializing Voqora...").font(vm.appFont(size: 16, weight: .medium))
                        }
                    }
                }
            }
        }
        .animation(.default, value: launchManager.isReady)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch vm.selectedTab {
        case "home": MainDashboardView()
        case "history": VaultView()
        case "books": AudiobookLibraryView()
        case "preferences": PreferencesView()
        default: MainDashboardView()
        }
    }

    private var miniPlayerHUD: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.status == .speaking ? "SPEAKING" : "PAUSED")
                    .font(vm.appFont(size: 8, weight: .black))
                    .foregroundStyle(.cyan)
                Text(history.history.first?.text ?? "Reading...")
                    .font(vm.appFont(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .frame(width: 250, alignment: .leading)

            ProgressView(value: audio.progress)
                .tint(.cyan)
                .scaleEffect(x: 1, y: 0.5)

            HStack(spacing: 12) {
                Button { vm.togglePlayback() } label: {
                    Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                }
                Button { audio.stop() } label: {
                    Image(systemName: "stop.fill")
                }
            }
            .buttonStyle(.plain)
            .font(.title3)
        }
        .padding(.horizontal, 25)
        .padding(.vertical, 15)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .padding(20)
        .shadow(color: .black.opacity(0.1), radius: 10)
        .animation(.spring(), value: audio.progress)
    }

    private func prettyTitleForResume(_ title: String) -> String {
        var t = title
        if t.lowercased().hasSuffix(".pdf") {
            t = String(t.dropLast(4))
        }
        return t
    }

    private func handleGlobalPDFDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let u = item as? URL {
                url = u
            }
            guard let url, url.pathExtension.lowercased() == "pdf" else { return }
            Task { @MainActor in
                vm.selectedTab = "books"
                let voice = bookVM.defaultBookVoice.isEmpty ? vm.selectedVoice : bookVM.defaultBookVoice
                let speed = bookVM.defaultBookSpeed > 0 ? bookVM.defaultBookSpeed : vm.speechSpeed
                bookVM.presentEstimate(
                    for: url,
                    voice: voice,
                    speed: speed,
                    engine: "kokoro"
                )
            }
        }
        return true
    }

    private var globalDropOverlay: some View {
        ZStack {
            Color.primary.opacity(0.18).ignoresSafeArea()
                .background(.ultraThinMaterial)
            VStack(spacing: 22) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 64, weight: .ultraLight))
                    .foregroundStyle(.cyan)
                Text("DROP TO ADD AUDIOBOOK")
                    .font(vm.appFont(size: 13, weight: .black))
                    .kerning(3)
                    .foregroundStyle(.cyan)
                Text("Will switch to Audiobooks and start an estimate.")
                    .font(vm.appFont(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(40)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.cyan.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            )
            .padding(60)
        }
        .animation(.easeInOut(duration: 0.2), value: globalDropHovering)
    }

    private var adaptiveBackdrop: some View {
        Color(.windowBackgroundColor)
            .ignoresSafeArea()
    }
}

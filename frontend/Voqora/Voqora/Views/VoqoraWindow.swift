import AppKit
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
    @EnvironmentObject var legacyMigration: LegacySuperSayMigration
    @Environment(\.colorScheme) var colorScheme
    @State private var globalDropHovering = false
    @State private var showOnboarding = false
    @State private var migrationResultMessage: String?

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                // APP BRANDING HEADER
                HStack(spacing: 12) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 0) {
                        Text("Voqora")
                            .font(vm.appFont(size: 16, weight: .bold))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)

                sidebarNavigation

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
                    .onDrop(of: [.fileURL], isTargeted: $globalDropHovering, perform: handleGlobalDocumentDrop)

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

                // Audiobook now-playing bar — hidden when on the player view (`books` tab when book is open)
                if let playing = bookVM.nowPlaying {
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
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: bookVM.nowPlaying?.bookID)
        }
        .frame(minWidth: 800, minHeight: 600)
        .preferredColorScheme(vm.appTheme == "system" ? nil : (vm.appTheme == "dark" ? .dark : .light))
        .onAppear {
            // Prepare backend if needed
            Task {
                await launchManager.prepare()
                if launchManager.isReady {
                    vm.startBackgroundWork()
                }
            }

            // First-launch onboarding is the highest-priority surface. It
            // must not compete with a backend loading curtain or the legacy
            // migration alert, otherwise a fresh install can look frozen.
            if onboarding.needsOnboarding {
                DispatchQueue.main.async {
                    showOnboarding = true
                }
            } else {
                legacyMigration.evaluate()
            }
        }
        .alert("SuperSay is installed", isPresented: $legacyMigration.shouldPresentNotice) {
            Button("Import preferences") {
                let imported = legacyMigration.importCompatiblePreferences()
                migrationResultMessage = imported > 0
                    ? "Imported \(imported) compatible preference\(imported == 1 ? "" : "s")."
                    : "No compatible SuperSay preferences were found."
            }
            Button("Show in Finder") {
                legacyMigration.showLegacyAppInFinder()
            }
            Button("Not now", role: .cancel) {
                legacyMigration.deferNotice()
            }
        } message: {
            Text("SuperSay is retired. Voqora is its supported successor. You can import compatible preferences, then move SuperSay to Trash when you are ready. Voqora will not remove it for you.")
        }
        .alert("SuperSay migration", isPresented: Binding(
            get: { migrationResultMessage != nil },
            set: { if !$0 { migrationResultMessage = nil } }
        )) {
            Button("OK", role: .cancel) { migrationResultMessage = nil }
        } message: {
            Text(migrationResultMessage ?? "")
        }
        .onChange(of: onboarding.version) { _, _ in
            if !onboarding.needsOnboarding {
                showOnboarding = false
                legacyMigration.evaluate()
            } else {
                showOnboarding = true
            }
        }
        .overlay {
            // Keep onboarding in the same window and above startup state.
            // A native sheet can otherwise be visually hidden by this overlay
            // while the local engine warms up, which is indistinguishable
            // from a frozen first launch.
            if showOnboarding {
                OnboardingView()
                    .environmentObject(onboarding)
                    .environmentObject(permissions)
                    .environmentObject(identity)
                    .transition(.opacity)
            } else if !launchManager.isReady {
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
                                Task {
                                    await launchManager.prepare()
                                    if launchManager.isReady {
                                        vm.startBackgroundWork()
                                    }
                                }
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

    private var sidebarNavigation: some View {
        List(selection: $vm.selectedTab) {
            Section("Library") {
                sidebarLink("Now Playing", icon: "play.circle.fill", value: "home")
                sidebarLink("The Vault", icon: "clock.arrow.circlepath", value: "history")
            }
            Section("Audiobooks") {
                sidebarLink("Library", icon: "books.vertical.fill", value: "books")
                if let resume = bookVM.continueListeningBook {
                    continueListeningButton(for: resume)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    private func sidebarLink(_ title: String, icon: String, value: String) -> some View {
        NavigationLink(value: value) {
            Label(title, systemImage: icon)
                .font(vm.appFont(size: 13))
        }
    }

    private func continueListeningButton(for book: Audiobook) -> some View {
        Button {
            vm.selectedTab = "books"
            bookVM.play(book)
            bookVM.openPlayer(for: book.bookID)
        } label: {
            HStack {
                Image(systemName: "play.circle")
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Continue Listening")
                        .font(vm.appFont(size: 13))
                    Text(prettyTitleForResume(book.title))
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
        if t.lowercased().hasSuffix(".pdf") { t = String(t.dropLast(4)) }
        return t
    }

    private func handleGlobalDocumentDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var url: URL?
            if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
            else if let u = item as? URL { url = u }
            guard let url else {
                Task { @MainActor in
                    bookVM.showToast("Voqora could not read that dropped file.", kind: .error)
                }
                return
            }
            Task { @MainActor in
                guard AudiobookImportStaging.supports(url) else {
                    bookVM.showToast("Voqora audiobooks support \(AudiobookImportStaging.supportedFormatsDescription) files.", kind: .info)
                    return
                }
                do {
                    let stagedURL = try AudiobookImportStaging.stageDocument(from: url)
                    vm.selectedTab = "books"
                    let voice = bookVM.defaultBookVoice.isEmpty ? vm.selectedVoice : bookVM.defaultBookVoice
                    let speed = bookVM.defaultBookSpeed > 0 ? bookVM.defaultBookSpeed : vm.speechSpeed
                    bookVM.presentEstimate(
                        for: stagedURL,
                        voice: voice,
                        speed: speed,
                        engine: "kokoro"
                    )
                } catch {
                    bookVM.showToast("Could not prepare that document: \(error.localizedDescription)", kind: .error)
                }
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
                Text("\(AudiobookImportStaging.supportedFormatsDescription) files will switch to Audiobooks and start an estimate.")
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

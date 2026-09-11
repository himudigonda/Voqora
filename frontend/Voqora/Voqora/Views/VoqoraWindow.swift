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
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.colorSchemeContrast) var colorSchemeContrast
    @State private var globalDropHovering = false
    @State private var showOnboarding = false
    /// Tracked so the startup prepare() work can be cancelled if the window
    /// disappears before it finishes — previously an unstructured `Task` with
    /// no cancellation, harmless only because of downstream idempotency guards.
    @State private var launchTask: Task<Void, Never>?

    /// The app's accent, resolved once per body pass — GRiT's own rows,
    /// buttons and links all read through this same call rather than a
    /// hardcoded `.cyan`.
    private var accentColor: Color {
        vm.accentColor(scheme: colorScheme, contrast: colorSchemeContrast)
    }

    var body: some View {
        NavigationSplitView {
            // A `ZStack` of two independently top/bottom-pinned stacks,
            // NOT a single `VStack` with an interior `Spacer()` — on this
            // machine, `NavigationSplitView`'s sidebar column was observed
            // proposing a wildly-oversized height to its content (an
            // absolute ~1500-1600pt, independent of the column's real
            // on-screen size), which a flexible `Spacer()` dutifully
            // expanded to fill, pushing the branding header off the top of
            // the visible window and the preferences/attribution block off
            // the bottom. Reproduced on unmodified pre-redesign code and
            // across Debug/Release, so it isn't specific to this file's own
            // styling — but pinning each block to its own edge via
            // `.frame(maxHeight: .infinity, alignment:)` instead of relying
            // on `Spacer()` to negotiate the split sidesteps it regardless
            // of root cause.
            ZStack {
                VStack(alignment: .leading, spacing: 0) {
                    // APP BRANDING HEADER
                    HStack(spacing: DesignTokens.Spacing.md) {
                        // NOT `NSApplication.shared.applicationIconImage` —
                        // that property isn't Combine/SwiftUI-observable, so
                        // this row never re-rendered when the user picked a
                        // different icon in Preferences even though the
                        // Dock/Finder icon itself changed correctly. Reading
                        // through `vm.appIconID` (an `@AppStorage` on the
                        // already-observed view model) makes this reactive.
                        Image(nsImage: NSImage(named: vm.appIconID.assetName) ?? NSApplication.shared.applicationIconImage)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 32, height: 32)

                        Text("Voqora")
                            .font(vm.font(.paneTitle))
                            .foregroundStyle(Palette.textPrimary)
                    }
                    .padding(.horizontal, DesignTokens.Layout.paneInset)
                    .padding(.top, DesignTokens.Spacing.xl)
                    .padding(.bottom, DesignTokens.Spacing.lg)

                    sidebarNavigation
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                VStack(spacing: 0) {
                    // SYSTEM / PREFERENCES AT BOTTOM
                    VStack(spacing: DesignTokens.Spacing.xs) {
                        Rectangle()
                            .fill(Palette.separator)
                            .frame(height: 1)
                            .padding(.horizontal, DesignTokens.Layout.paneInset)
                            .padding(.bottom, DesignTokens.Spacing.xs)

                        PaneRow(isSelected: vm.selectedTab == "preferences", action: {
                            vm.selectedTab = "preferences"
                        }) {
                            Image(systemName: "gearshape.fill")
                                .font(vm.font(.rowTitle))
                                .frame(width: 20)
                        } label: {
                            Text("Preferences")
                                .font(vm.font(.rowTitle))
                        }

                        // Replaces the old sidebar-footer "DEVELOPED BY" block
                        // (name, three link icons, cramped into the nav rail)
                        // with a single row into a proper About screen that
                        // carries version/build, an update check, and the
                        // same credit links with room to breathe.
                        PaneRow(isSelected: vm.selectedTab == "about", action: {
                            vm.selectedTab = "about"
                        }) {
                            Image(systemName: "info.circle.fill")
                                .font(vm.font(.rowTitle))
                                .frame(width: 20)
                        } label: {
                            Text("About")
                                .font(vm.font(.rowTitle))
                        }
                    }
                    .padding(.horizontal, DesignTokens.Spacing.sm)
                    .padding(.bottom, DesignTokens.Spacing.sm)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .background(Palette.surfaceSunken)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            ZStack(alignment: .bottom) {
                // MAIN CONTENT
                detailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onDrop(of: [.fileURL], isTargeted: $globalDropHovering, perform: handleGlobalDocumentDrop)

                // Global drop overlay shown across any non-Audiobooks tab when a supported document is hovering.
                if globalDropHovering && vm.selectedTab != "books" {
                    globalDropOverlay
                        .transition(.opacity)
                }

                // FLOATING MINI PLAYER (Global) - Hide when on main dashboard to avoid duplicate bars
                if vm.status == .speaking || vm.status == .paused, vm.selectedTab != "home" {
                    miniPlayerHUD
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // A full player and a compact player bar must never compete
                // for the same audiobook. The view lifecycle, rather than
                // `nowPlaying` alone, tells us whether the full player is up.
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
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: bookVM.isNowPlayingBarVisible)
        }
        .frame(minWidth: 800, minHeight: 600)
        // So standard system controls (Toggle, Slider, focus rings, plain
        // `.buttonStyle(.borderedProminent)` buttons) pick up the chosen
        // accent ramp too, not just views explicitly styled against it.
        .tint(accentColor)
        .preferredColorScheme(vm.appTheme == "system" ? nil : (vm.appTheme == "dark" ? .dark : .light))
        .onAppear {
            // Prepare backend if needed
            launchTask = Task {
                await launchManager.prepare()
                guard !Task.isCancelled else { return }
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
            } else if !permissions.accessibilityGranted {
                // NOT `permissions.requestAccessibility()` — that force-opens
                // System Settings' Accessibility pane, and this branch runs
                // on every single launch a completed setup still lacks the
                // permission, including for someone who deliberately chose
                // "Continue without access" in the wizard on the explicit
                // promise (`OnboardingCopy.swift`) that they could enable it
                // later in Preferences. Doing that unconditionally on every
                // launch broke that promise into a repeating, unprompted
                // System Settings pop-open — exactly the kind of behavior a
                // public release can't ship. `refreshAccessibility()` only
                // updates the published status so the dashboard's own
                // persistent banner (which already owns a manual "Open
                // Settings" button) can react to it; nothing here yanks focus
                // away from the app.
                permissions.refreshAccessibility()
            }

            // A returning user (onboarding already complete) whose bundle
            // version differs from the last one this profile recorded just
            // got updated — land on About so they see what changed and that
            // the credit links still work, same destination first-time users
            // reach right after the wizard closes below. `lastSeenAppVersion`
            // starts empty, so a fresh install's own first launch never
            // matches this — only a version CHANGE does.
            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            if !onboarding.needsOnboarding, !vm.lastSeenAppVersion.isEmpty, vm.lastSeenAppVersion != currentVersion {
                vm.selectedTab = "about"
            }
            if !currentVersion.isEmpty {
                vm.lastSeenAppVersion = currentVersion
            }
        }
        .onDisappear {
            launchTask?.cancel()
            launchTask = nil
        }
        .onChange(of: onboarding.version) { _, _ in
            // NOT `vm.selectedTab = "about"` here — that was sending EVERY
            // first-run completion to the About screen, contradicting the
            // wizard's own "Get started" button (`OnboardingCopy.swift`),
            // which promises entry into the product, not a credits page.
            // The update-detected branch in `.onAppear` above already routes
            // a RETURNING user to About after a version change; a fresh
            // completion should just fall through to `selectedTab`'s
            // existing "home" default.
            if !onboarding.needsOnboarding {
                showOnboarding = false
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

                    VStack(spacing: DesignTokens.Spacing.lg) {
                        if let error = launchManager.error {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 40))
                                .foregroundStyle(Palette.danger)
                            Text("Launch Failed")
                                .font(vm.font(.sectionTitle))
                                .foregroundStyle(Palette.textPrimary)
                            Text(error)
                                .foregroundStyle(Palette.textSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)

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
                            .tint(accentColor)
                        } else {
                            ProgressView()
                                .tint(accentColor)
                            Text("Initializing Voqora...")
                                .font(vm.font(.rowTitle))
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }
                }
            }
        }
        .animation(.default, value: launchManager.isReady)
    }
}

/// Split out of the struct body to keep it under SwiftLint's
/// `type_body_length` — plain private members, not a separate API surface.
private extension VoqoraWindow {
    @ViewBuilder
    var detailContent: some View {
        switch vm.selectedTab {
        case "home": MainDashboardView()
        case "history": VaultView()
        case "books": AudiobookLibraryView()
        case "preferences": PreferencesView()
        case "about": AboutView()
        default: MainDashboardView()
        }
    }

    /// A plain `VStack` of `PaneRow`s rather than a native `List` — a
    /// `List(.sidebar)` paints its own vibrant/translucent material, which is
    /// exactly the "glass" look this design language replaces. Matches
    /// GRiT's own nav rail (`AppSidebarView`) shape for shape.
    private var sidebarNavigation: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Layout.sectionGap) {
            PaneSection("Library") {
                VStack(spacing: DesignTokens.Spacing.xxs) {
                    sidebarLink("Now Playing", icon: "play.circle.fill", value: "home")
                    sidebarLink("The Vault", icon: "clock.arrow.circlepath", value: "history")
                }
            }
            PaneSection("Audiobooks") {
                VStack(spacing: DesignTokens.Spacing.xxs) {
                    sidebarLink("Library", icon: "books.vertical.fill", value: "books")
                    if let resume = bookVM.continueListeningBook {
                        continueListeningButton(for: resume)
                    }
                }
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
    }

    private func sidebarLink(_ title: String, icon: String, value: String) -> some View {
        PaneRow(isSelected: vm.selectedTab == value, action: { vm.selectedTab = value }) {
            Image(systemName: icon)
                .font(vm.font(.rowTitle))
                .frame(width: 20)
        } label: {
            Text(title)
                .font(vm.font(.rowTitle))
        }
    }

    private func continueListeningButton(for book: Audiobook) -> some View {
        Button {
            vm.selectedTab = "books"
            bookVM.play(book)
            bookVM.openPlayer(for: book.bookID)
        } label: {
            HStack(spacing: DesignTokens.Layout.rowIconGap) {
                Image(systemName: "play.circle")
                    .font(vm.font(.rowTitle))
                    .foregroundStyle(accentColor)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Continue Listening")
                        .font(vm.font(.rowTitle))
                    Text(book.displayTitle)
                        .font(vm.font(.caption))
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DesignTokens.Layout.rowInsetHorizontal)
            .padding(.vertical, DesignTokens.Layout.rowInsetVertical)
            .frame(minHeight: DesignTokens.Layout.rowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.textPrimary)
    }

    private var miniPlayerHUD: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.status == .speaking ? "SPEAKING" : "PAUSED")
                    .font(vm.font(.sectionHeader))
                    .kerning(0.6)
                    .foregroundStyle(accentColor)
                Text(history.history.first?.text ?? "Reading...")
                    .font(vm.appFont(size: 11, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
            }
            .frame(width: 250, alignment: .leading)

            ProgressView(value: audio.progress)
                .tint(accentColor)
                .scaleEffect(x: 1, y: 0.5)

            HStack(spacing: 12) {
                Button { vm.togglePlayback() } label: {
                    Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                }
                .accessibilityLabel(audio.isPlaying ? "Pause" : "Play")
                .help(audio.isPlaying ? "Pause" : "Play")
                Button { vm.stopPlayback() } label: {
                    Image(systemName: "stop.fill")
                }
                .accessibilityLabel("Stop")
                .help("Stop")
            }
            .buttonStyle(.plain)
            .font(.title3)
            .foregroundStyle(Palette.textPrimary)
        }
        .padding(.horizontal, 25)
        .padding(.vertical, 15)
        .voqoraSurface(.floating, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
        .padding(20)
        .animation(.spring(), value: audio.progress)
    }

    private func handleGlobalDocumentDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let u = item as? URL {
                url = u
            }
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
        DocumentDropOverlay(
            subtitle: "\(AudiobookImportStaging.supportedFormatsDescription) files will switch to Audiobooks and start an estimate.",
            appFont: vm.appFont
        )
        .animation(.easeInOut(duration: 0.2), value: globalDropHovering)
    }

    private var adaptiveBackdrop: some View {
        Palette.surfaceBase
            .ignoresSafeArea()
    }
}

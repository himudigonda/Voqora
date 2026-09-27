import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct VoqoraWindow: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var launchManager: LaunchManager
    @EnvironmentObject var bookVM: AudiobookViewModel
    @EnvironmentObject var onboarding: OnboardingCoordinator
    @EnvironmentObject var identity: IdentityService
    @EnvironmentObject var permissions: PermissionsService
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.colorSchemeContrast) var colorSchemeContrast
    @State private var globalDropHovering = false
    @State private var showOnboarding = false
    @State private var launchTask: Task<Void, Never>?

    private var accentColor: Color {
        vm.accentColor(scheme: colorScheme, contrast: colorSchemeContrast)
    }

    var body: some View {
        NavigationSplitView {
            ZStack {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: DesignTokens.Spacing.md) {
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
                        .accessibilityLabel("Preferences")
                        .accessibilityAddTraits(vm.selectedTab == "preferences" ? [.isSelected] : [])

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
                        .accessibilityLabel("About")
                        .accessibilityAddTraits(vm.selectedTab == "about" ? [.isSelected] : [])
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
                detailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
                    .onDrop(of: [.fileURL], isTargeted: $globalDropHovering, perform: handleGlobalDocumentDrop)

                if globalDropHovering, vm.selectedTab != "books" {
                    globalDropOverlay
                        .transition(.opacity)
                }

                VStack {
                    AudiobookToastView()
                        .environmentObject(vm)
                        .environmentObject(bookVM)
                    Spacer()
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: bookVM.toast?.id)
            }
            .background(adaptiveBackdrop)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: bookVM.isNowPlayingBarVisible)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: vm.status)
        }
        .frame(minWidth: 800, minHeight: 600)
        .tint(accentColor)
        .preferredColorScheme(vm.appTheme == "system" ? nil : (vm.appTheme == "dark" ? .dark : .light))
        .onAppear {
            launchTask = Task {
                await launchManager.prepare()
                guard !Task.isCancelled else { return }
                if launchManager.isReady {
                    vm.startBackgroundWork()
                }
            }

            if onboarding.needsOnboarding {
                DispatchQueue.main.async {
                    showOnboarding = true
                }
            } else if !permissions.accessibilityGranted {
                permissions.refreshAccessibility()
            }

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
        .task(id: vm.isBackendOnline) {
            if vm.isBackendOnline, !bookVM.hasLoadedOnce || bookVM.loadFailed {
                await bookVM.refresh()
            }
        }
        .onChange(of: onboarding.version) { _, _ in
            if !onboarding.needsOnboarding {
                showOnboarding = false
            } else {
                showOnboarding = true
            }
        }
        .overlay {
            if showOnboarding {
                OnboardingView()
                    .environmentObject(onboarding)
                    .environmentObject(permissions)
                    .environmentObject(identity)
                    .environmentObject(vm)
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
                            Text("Starting Voqora…")
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

private extension VoqoraWindow {
    @ViewBuilder
    var miniPlayer: some View {
        if vm.selectedTab != "home" {
            if let playing = bookVM.nowPlaying {
                if !bookVM.isPlayerViewActive {
                    NowPlayingBar(book: playing)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            } else if vm.spokenText != nil, vm.status == .speaking || vm.status == .paused || vm.status == .thinking {
                SpeechNowPlayingBar()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

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

    private var sidebarNavigation: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Layout.sectionGap) {
            PaneSection {
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
        PaneRow(isSelected: vm.selectedTab == value, action: {
            if value == "books" {
                vm.showLibrary()
            } else {
                vm.selectedTab = value
            }
        }) {
            Image(systemName: icon)
                .font(vm.font(.rowTitle))
                .frame(width: 20)
        } label: {
            Text(title)
                .font(vm.font(.rowTitle))
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(vm.selectedTab == value ? [.isSelected] : [])
    }

    private func continueListeningButton(for book: Audiobook) -> some View {
        Button {
            if bookVM.nowPlaying?.bookID == book.bookID, !bookVM.audio.isPlaying {
                bookVM.togglePlayback()
            }
            vm.openAudiobook(book.bookID)
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
        .accessibilityLabel("Continue Listening: \(book.displayTitle)")
        .accessibilityHint("Resumes this audiobook and opens the player")
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
                    vm.showLibrary()
                    bookVM.presentEstimate(for: stagedURL, defaultVoice: vm.selectedVoice, defaultSpeed: vm.speechSpeed)
                } catch {
                    bookVM.showToast("Could not prepare that document: \(error.localizedDescription)", kind: .error)
                }
            }
        }
        return true
    }

    private var globalDropOverlay: some View {
        DocumentDropOverlay(
            subtitle: "PDF, Word, text, or Markdown",
            appFont: vm.appFont
        )
        .animation(.easeInOut(duration: 0.2), value: globalDropHovering)
    }

    private var adaptiveBackdrop: some View {
        Palette.surfaceBase
            .ignoresSafeArea()
    }
}

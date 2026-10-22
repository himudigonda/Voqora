import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct VoqoraWindow: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var launchManager: LaunchManager
    @EnvironmentObject var bookVM: AudiobookViewModel
    @EnvironmentObject var inbox: InboxViewModel
    @EnvironmentObject var onboarding: OnboardingCoordinator
    @EnvironmentObject var identity: IdentityService
    @EnvironmentObject var permissions: PermissionsService
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.colorSchemeContrast) var colorSchemeContrast
    @Environment(\.openWindow) private var openWindow
    @State private var globalDropHovering = false
    @State private var showOnboarding = false
    #if DEBUG
        @ObservedObject private var snapshotOnboarding = SnapshotOnboarding.shared
    #endif

    private var suppressesOnboarding: Bool {
        #if DEBUG
            SnapshotHarness.isActive
        #else
            false
        #endif
    }

    private var onboardingStep: Int? {
        #if DEBUG
            if let step = snapshotOnboarding.step {
                return step
            }
        #endif
        return showOnboarding && !suppressesOnboarding ? -1 : nil
    }

    private var accentColor: Color {
        vm.accentColor(scheme: colorScheme, contrast: colorSchemeContrast)
    }

    var body: some View {
        NavigationSplitView {
            NavigationDrawerView()
        } detail: {
            ZStack(alignment: .bottom) {
                detailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
                    .onDrop(of: [.fileURL], isTargeted: $globalDropHovering) { providers in
                        if vm.selectedTab == TabKey.inbox {
                            return inbox.handleDrop(providers)
                        }
                        return routeDroppedFiles(providers)
                    }

                if globalDropHovering, ![TabKey.books, TabKey.inbox, TabKey.createAudiobook].contains(vm.selectedTab) {
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
            .background(vm.theme.surface.ignoresSafeArea())
            .navigationTitle(detailTitle)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: bookVM.isNowPlayingBarVisible)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: vm.status)
        }
        .frame(minWidth: 800, minHeight: 600)
        .tint(accentColor)
        .preferredColorScheme(vm.appTheme == "system" ? nil : (vm.appTheme == "dark" ? .dark : .light))
        .onAppear {
            WindowPresenter.shared.openDashboard = { openWindow(id: "dashboard") }
            AppWindows.register(navigate: { vm.selectedTab = $0 })
            if AudiobookCreateRequest.shared.pending != nil {
                vm.selectedTab = TabKey.createAudiobook
            }
            #if DEBUG
                SnapshotHarness.runIfRequested(vm: vm, launchManager: launchManager)
            #endif
            AppPresence.applyActivationPolicy(onboarding: onboarding.needsOnboarding)
            Task {
                await launchManager.prepare()
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
                DispatchQueue.main.async {
                    AppWindows.openAbout()
                }
            }
            if !currentVersion.isEmpty {
                vm.lastSeenAppVersion = currentVersion
            }
        }
        .task(id: vm.isBackendOnline) {
            if vm.isBackendOnline, !bookVM.hasLoadedOnce || bookVM.loadFailed {
                await bookVM.refresh()
            }
        }
        .syncsVoiceBlends()
        .onChange(of: bookVM.pendingSource) { _, source in
            if source != nil, vm.selectedTab != TabKey.createAudiobook {
                vm.selectedTab = TabKey.createAudiobook
            }
        }
        .onChange(of: onboarding.version) { _, _ in
            AppPresence.applyActivationPolicy(onboarding: onboarding.needsOnboarding)
            if !onboarding.needsOnboarding {
                showOnboarding = false
            } else {
                showOnboarding = true
            }
        }
        .overlay {
            if let onboardingStep {
                OnboardingView(snapshotStep: onboardingStep >= 0 ? onboardingStep : nil)
                    .environmentObject(bookVM.providers)
                    .environmentObject(bookVM)
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
        .voqoraTheme()
    }
}

private extension VoqoraWindow {
    @ViewBuilder
    var miniPlayer: some View {
        if vm.selectedTab != TabKey.home {
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
        if let tab = TabKey.settingsTab(for: vm.selectedTab) {
            SettingsDetailView(tab: tab)
        } else if TabKey.isCreate(vm.selectedTab) {
            StudioView()
        } else if let page = vm.selectedTab.flatMap({ VoicesPage(tab: $0) }) {
            VoicesView(page: page)
        } else {
            switch vm.selectedTab {
            case TabKey.history: VaultView()
            case TabKey.stats: StatsView()
            case TabKey.books, TabKey.booksPlayer: AudiobookLibraryView()
            case TabKey.dictation: DictationView()
            case TabKey.inbox: InboxView()
            case TabKey.about, TabKey.feedback: HelpDetailView()
            default: MainDashboardView()
            }
        }
    }

    func openNewAudiobook(with source: AudiobookCreateSource) {
        vm.showNewAudiobook(with: source)
    }

    func routeDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard let first = fileProviders.first else { return false }
        guard fileProviders.count == 1 else {
            guard bookVM.importDroppedDocuments(fileProviders, defaultVoice: vm.selectedVoice, defaultSpeed: vm.speechSpeed) else { return false }
            vm.selectedTab = TabKey.createAudiobook
            return true
        }
        Task {
            guard let url = await AudiobookImportStaging.fileURL(from: first) else {
                bookVM.showToast("Voqora could not read that dropped file.", kind: .error)
                return
            }
            guard AudiobookImportStaging.supports(url) else {
                bookVM.showToast("Voqora audiobooks support \(AudiobookImportStaging.supportedFormatsDescription) files.", kind: .info)
                return
            }
            openNewAudiobook(with: .file(url))
        }
        return true
    }

    var detailTitle: String {
        Self.title(forTab: vm.selectedTab)
    }

    private var globalDropOverlay: some View {
        DocumentDropOverlay(
            subtitle: AudiobookImportStaging.supportedFormatsDescription,
            appFont: vm.appFont
        )
        .animation(.easeInOut(duration: 0.2), value: globalDropHovering)
    }

    private var adaptiveBackdrop: some View {
        vm.theme.surface
            .ignoresSafeArea()
    }
}

extension VoqoraWindow {
    static func title(forTab tab: String?) -> String {
        TabKey.title(for: tab)
    }
}

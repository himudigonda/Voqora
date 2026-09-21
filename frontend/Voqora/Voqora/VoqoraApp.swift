import KeyboardShortcuts
import Sparkle
import SwiftUI

@main
struct VoqoraApp: App {
    /// 0. App Lifecycle Management
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // 1. Single Sources of Truth (Services)
    @StateObject private var audio: AudioService
    @StateObject private var history: HistoryManager
    @StateObject private var launchManager: LaunchManager

    /// 2. Logic Controller (ViewModel)
    @StateObject private var dashboardVM: DashboardViewModel

    /// Audiobook ViewModel (own state)
    @StateObject private var audiobookVM: AudiobookViewModel

    /// First-launch + onboarding state.
    @StateObject private var onboarding: OnboardingCoordinator

    /// Identity (anon_id + required name/email) for analytics.
    @StateObject private var identity: IdentityService

    /// Live AX + Notifications permission status. Observed by onboarding.
    /// Uses the shared singleton so view models can schedule notifications
    /// (audiobook ready, speaking, update available) without needing this
    /// service injected into their initializers.
    @StateObject private var permissions = PermissionsService.shared

    /// Native Sparkle 2 lifecycle. It owns background checks, verified
    /// downloads, replacement, and relaunch instead of the former custom DMG
    /// downloader.
    @StateObject private var updater: AppUpdater

    /// Pre-notarization releases use this explicit, verified Finder handoff.
    @StateObject private var installer: GuidedInstallerService

    /// 3. Backend (Kept private, managed by VM, but we own the instance to stop deinit)
    private let backend: BackendService

    init() {
        let runningTests = RuntimeEnvironment.isRunningTests
        // Before any shared on-disk state is touched: reaching the log
        // redirection below would already have destroyed the original's log.
        if !runningTests, AppDelegate.standDownIfAlreadyRunning() {
            exit(0)
        }
        if !runningTests {
            // 1. REDIRECT FRONTEND LOGS TO FILE
            let bundleID = Bundle.main.bundleIdentifier ?? "com.himudigonda.Voqora"
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(bundleID)

            // Ensure directory exists
            try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

            let logURL = appSupport.appendingPathComponent("frontend.log")

            // "w+" truncates in place. `write(to:atomically:)` renames a temp
            // file over the target, leaving other writers on an unlinked inode.
            freopen(logURL.path, "w+", stdout)
            freopen(logURL.path, "a+", stderr)
            setbuf(stdout, nil)

            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
            let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
            let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
            VoqoraLog.info("VoqoraApp", "Frontend log started", ["version": appVersion, "build": buildNumber, "os": osVersion])
        }

        // Touch AppActivityMonitor.shared as early as possible — it's lazily
        // instantiated, and NotificationCenter doesn't replay missed
        // notifications to a late subscriber. Background work (heartbeat,
        // audiobook poll) doesn't start until deep in an async chain
        // (LaunchManager.prepare() completing), so without this, a
        // didResignActiveNotification firing during that startup window
        // would be silently dropped and isBackgrounded would stay wrong
        // until the next activation transition.
        _ = AppActivityMonitor.shared

        // Create instances
        let audioInstance = AudioService(startingEngine: !runningTests)
        let historyInstance = HistoryManager()
        let launchInstance = LaunchManager()
        let backendInstance = BackendService()
        let systemInstance = SystemService()
        let updaterInstance = AppUpdater()
        let installerInstance = GuidedInstallerService()
        let testDefaults = runningTests ? RuntimeEnvironment.testDefaults() : nil
        let onboardingInstance = OnboardingCoordinator(defaults: testDefaults ?? .standard)
        let identityInstance = runningTests
            ? IdentityService(defaults: testDefaults!)
            : IdentityService.shared

        // Create VM with dependency injection
        let vmInstance = DashboardViewModel(
            backend: backendInstance,
            system: systemInstance,
            audio: audioInstance,
            history: historyInstance,
            // LaunchManager owns unpacking the bundled local server. Starting
            // the health loop before it is ready starts a process which the
            // extractor immediately replaces on fresh installs.
            startsBackgroundWork: false
        )

        // Audiobook VM uses the same shared AudioService for playback
        let audiobookInstance = AudiobookViewModel(audio: audioInstance)

        // Assign to StateObjects
        _audio = StateObject(wrappedValue: audioInstance)
        _history = StateObject(wrappedValue: historyInstance)
        _launchManager = StateObject(wrappedValue: launchInstance)
        _dashboardVM = StateObject(wrappedValue: vmInstance)
        _audiobookVM = StateObject(wrappedValue: audiobookInstance)
        _onboarding = StateObject(wrappedValue: onboardingInstance)
        _identity = StateObject(wrappedValue: identityInstance)
        _updater = StateObject(wrappedValue: updaterInstance)
        _installer = StateObject(wrappedValue: installerInstance)

        // Wire mutual exclusion between TTS hotkey playback and audiobook playback
        vmInstance.audiobookVM = audiobookInstance

        backend = backendInstance
        appDelegate.stopOwnedBackend = { [backendInstance] in
            backendInstance.stop()
        }

        if !runningTests {
            // Don't trigger permission prompts here — the onboarding wizard
            // gates them behind explicit buttons. SystemService still drives
            // ducking + AppleScript permissions on first hotkey use.
            setupShortcuts(vm: vmInstance)

            if !RuntimeEnvironment.disablesTelemetry {
                MetricsService.shared.trackLaunch()
                // Start the periodic flush driver (previously embedded inside the
                // singleton init; now externalized so the actor can stay isolated).
                Task { @MainActor in
                    MetricsFlushDriver.shared.start()
                }
            }
            // A privacy removal made while offline is honoured locally first.
            // Retry the separate server-side contact removal quietly on launch;
            // it never depends on the anonymous-telemetry choice.
            Task { await identityInstance.retryPendingRemoval() }
            // Onboarding's identity save never blocks on the network; retry
            // delivering it here so an offline first launch still reaches the
            // backend once connectivity returns.
            Task { await identityInstance.retryPendingSubmission() }
            // Sparkle stays dormant until Voqora is notarized (see AppUpdater),
            // so this is the only thing that tells an early-access user a
            // newer release exists. It only checks and notifies — never downloads.
            Task { await updaterInstance.checkGitHubReleaseForUpdate() }
            checkRunningLocation()
        }
    }

    private func checkRunningLocation() {
        let path = Bundle.main.bundlePath
        if path.contains("/Volumes/") {
            let alert = NSAlert()
            alert.messageText = "Move to Applications"
            alert.informativeText = "Drag Voqora into Applications in the installer window, then open it from Applications. Running it from the disk image prevents reliable updates."
            alert.addButton(withTitle: "Open Applications")
            alert.addButton(withTitle: "Quit")

            if alert.runModal() == .alertFirstButtonReturn {
                // Open Applications folder so user can drag-and-drop
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
                NSApplication.shared.terminate(nil)
            } else {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func setupShortcuts(vm: DashboardViewModel) {
        VoqoraLog.info("KeyboardShortcuts", "Initializing registration")

        KeyboardShortcuts.onKeyUp(for: .playText) {
            Task { @MainActor in
                guard !Self.focusedTextInputOwnsShortcut() else { return }
                VoqoraLog.info("KeyboardShortcuts", "playText triggered")
                await vm.speakSelection()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .togglePause) {
            Task { @MainActor in
                guard !Self.focusedTextInputOwnsShortcut() else { return }
                VoqoraLog.info("KeyboardShortcuts", "togglePause triggered")
                vm.togglePlayback()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .stopText) {
            Task { @MainActor in
                guard !Self.focusedTextInputOwnsShortcut() else { return }
                VoqoraLog.info("KeyboardShortcuts", "stopText triggered")
                vm.stopPlayback()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .exportAudio) {
            Task { @MainActor in
                guard !Self.focusedTextInputOwnsShortcut() else { return }
                VoqoraLog.info("KeyboardShortcuts", "exportAudio triggered")
                vm.exportLastClip()
            }
        }

        VoqoraLog.info("KeyboardShortcuts", "All shortcuts registered")
    }

    /// Global app actions must never steal normal editing shortcuts. AppKit
    /// exposes a field's active editor as an NSTextView, so walk the responder
    /// chain rather than trying to infer focus from a particular SwiftUI view.
    @MainActor
    static func focusedTextInputOwnsShortcut() -> Bool {
        focusedTextInputOwnsShortcut(responder: NSApp.keyWindow?.firstResponder)
    }

    @MainActor
    static func focusedTextInputOwnsShortcut(responder: NSResponder?) -> Bool {
        var current = responder
        while let responder = current {
            if responder is NSTextView {
                return true
            }
            current = responder.nextResponder
        }
        return false
    }

    @AppStorage("showMenuBarIcon") var showMenuBarIcon = true

    var body: some Scene {
        WindowGroup(id: "dashboard") {
            Group {
                if RuntimeEnvironment.isRunningTests {
                    // The test target is app-hosted so it can import internal
                    // Swift symbols. It must not also run the product window
                    // lifecycle.
                    EmptyView()
                } else {
                    VoqoraWindow()
                        .environmentObject(dashboardVM)
                        .environmentObject(audio)
                        .environmentObject(history)
                        .environmentObject(launchManager)
                        .environmentObject(audiobookVM)
                        .environmentObject(onboarding)
                        .environmentObject(identity)
                        .environmentObject(permissions)
                        .environmentObject(updater)
                        .environmentObject(installer)
                }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .handlesExternalEvents(matching: ["dashboard"])

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            // MARK: Playback

            Button {
                Task { await dashboardVM.speakSelection() }
            } label: {
                Label("Speak Selection", systemImage: "text.bubble")
            }

            Button {
                dashboardVM.togglePlayback()
            } label: {
                switch dashboardVM.status {
                case .speaking:
                    Label("Pause", systemImage: "pause.fill")
                case .paused:
                    Label("Resume", systemImage: "play.fill")
                default:
                    Label("Play", systemImage: "play.fill")
                }
            }
            .disabled(dashboardVM.status != .speaking && dashboardVM.status != .paused)

            Button {
                dashboardVM.stopPlayback()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .disabled(dashboardVM.status != .speaking && dashboardVM.status != .paused && dashboardVM.status != .thinking)

            Divider()

            // MARK: Quick actions

            Button {
                dashboardVM.exportLastClip()
            } label: {
                Label("Save Last Clip to Desktop", systemImage: "square.and.arrow.down")
            }
            .disabled(!dashboardVM.audio.canExportLastClip)

            if let lastEntry = history.history.first {
                Button {
                    history.toggleFavorite(entry: lastEntry)
                } label: {
                    Label(
                        lastEntry.isFavorite ? "Unlike Last Clip" : "Like Last Clip",
                        systemImage: lastEntry.isFavorite ? "heart.fill" : "heart"
                    )
                }
            }

            Divider()

            // MARK: Library

            Menu("Recent") {
                if history.history.isEmpty {
                    Text("No history yet")
                } else {
                    ForEach(history.history.prefix(5)) { entry in
                        let preview = entry.text.count > 60 ? String(entry.text.prefix(60)) + "…" : entry.text
                        Button(preview) {
                            Task { await dashboardVM.speak(text: entry.text) }
                        }
                    }
                    Divider()
                    Button("Clear History") { history.clearHistory() }
                }
            }

            if let book = audiobookVM.continueListeningBook {
                Button {
                    audiobookVM.openPlayer(for: book.bookID)
                    dashboardVM.selectedTab = "books"
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Continue: \(book.displayTitle)", systemImage: "book.fill")
                }
            }

            Button {
                dashboardVM.selectedTab = "books"
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Open Audiobooks", systemImage: "books.vertical")
            }

            Divider()

            // MARK: App

            Button {
                dashboardVM.selectedTab = "home"
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Open Voqora", systemImage: "macwindow")
            }

            Button {
                dashboardVM.selectedTab = "preferences"
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Preferences…", systemImage: "gearshape")
            }

            Button {
                updater.checkForUpdates()
            } label: {
                Label(
                    updater.isCheckingForUpdates ? "Checking for Updates…" : "Check for Updates…",
                    systemImage: "arrow.triangle.2.circlepath"
                )
            }
            .disabled(!updater.canCheckForUpdates || updater.isCheckingForUpdates)

            Toggle(isOn: $launchManager.isLaunchAtLoginEnabled) {
                Label("Launch at Login", systemImage: "power")
            }

            Divider()

            Button("Quit Voqora") {
                dashboardVM.stopHeartbeat()
                // Stop only the child process this app owns before macOS
                // tears the process down. A detached Task can be pre-empted
                // by termination and leave a local server behind.
                backend.stop()
                NSApplication.shared.terminate(nil)
            }
        } label: {
            switch dashboardVM.status {
            case .thinking:
                Label("Processing", systemImage: "waveform.circle")
            case .speaking:
                Label("Speaking", systemImage: "waveform.circle.fill")
            default:
                // The `.thinking`/`.speaking` cases above are `Label`s and so
                // carry a name; the idle case is a bare image and did not.
                Image("MenuBarIcon")
                    .accessibilityLabel("Voqora")
            }
        }
    }
}

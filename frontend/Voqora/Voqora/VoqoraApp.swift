import KeyboardShortcuts
import Sparkle
import SwiftUI

@main
struct VoqoraApp: App {
    // 0. App Lifecycle Management
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

    /// Anonymous identity (anon_id + optional email) for analytics.
    @StateObject private var identity: IdentityService

    /// Live AX + Notifications permission status. Observed by onboarding.
    @StateObject private var permissions = PermissionsService()

    /// Local-only, explicit bridge from the retired SuperSay app.
    @StateObject private var legacyMigration: LegacySuperSayMigration

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
        if !runningTests {
            // 1. REDIRECT FRONTEND LOGS TO FILE
            let bundleID = Bundle.main.bundleIdentifier ?? "com.himudigonda.Voqora"
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(bundleID)

            // Ensure directory exists
            try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

            let logURL = appSupport.appendingPathComponent("frontend.log")

            // Clear old log
            try? "".write(to: logURL, atomically: true, encoding: .utf8)

            // Redirect stdout and stderr to the log file, then disable buffering so every
            // print() line lands immediately (no partial logs on crash or low-volume runs).
            freopen(logURL.path, "a+", stdout)
            freopen(logURL.path, "a+", stderr)
            setbuf(stdout, nil)

            print("--- Voqora Frontend Log Started: \(Date()) ---")
        }

        // Create instances
        let audioInstance = AudioService(startingEngine: !runningTests)
        let historyInstance = HistoryManager()
        let launchInstance = LaunchManager()
        let backendInstance = BackendService()
        let systemInstance = SystemService()
        let updaterInstance = AppUpdater()
        let installerInstance = GuidedInstallerService()
        let legacyMigrationInstance = LegacySuperSayMigration()
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
        _legacyMigration = StateObject(wrappedValue: legacyMigrationInstance)

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
        print("⌨️ KeyboardShortcuts: Initializing registration...")

        KeyboardShortcuts.onKeyUp(for: .playText) {
            print("⌨️ KeyboardShortcuts: playText triggered")
            Task { @MainActor in
                await vm.speakSelection()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .togglePause) {
            print("⌨️ KeyboardShortcuts: togglePause triggered")
            Task { @MainActor in
                vm.togglePlayback()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .stopText) {
            print("⌨️ KeyboardShortcuts: stopText triggered")
            Task { @MainActor in
                vm.stopPlayback()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .exportAudio) {
            print("⌨️ KeyboardShortcuts: exportAudio triggered")
            Task { @MainActor in
                vm.exportLastClip()
            }
        }

        print("⌨️ KeyboardShortcuts: All shortcuts registered.")
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
                        .environmentObject(legacyMigration)
                }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .handlesExternalEvents(matching: ["dashboard"])

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            Button("Speak Selection") { Task { await dashboardVM.speakSelection() } }
            Button("Stop") { dashboardVM.stopPlayback() }
            Button("Quit") {
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
                Image("MenuBarIcon")
            }
        }
    }
}

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
    @StateObject private var onboarding = OnboardingCoordinator()

    /// Anonymous identity (anon_id + optional email) for analytics.
    @StateObject private var identity = IdentityService.shared

    /// Live AX + Notifications permission status. Observed by onboarding.
    @StateObject private var permissions = PermissionsService()

    /// Local-only, explicit bridge from the retired SuperSay app.
    @StateObject private var legacyMigration: LegacySuperSayMigration

    /// Native Sparkle 2 lifecycle. It owns background checks, verified
    /// downloads, replacement, and relaunch instead of the former custom DMG
    /// downloader.
    @StateObject private var updater: AppUpdater

    /// 3. Backend (Kept private, managed by VM, but we own the instance to stop deinit)
    private let backend: BackendService

    init() {
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
        setbuf(stderr, nil)

        print("--- Voqora Frontend Log Started: \(Date()) ---")

        // Create instances
        let audioInstance = AudioService()
        let historyInstance = HistoryManager()
        let launchInstance = LaunchManager()
        let backendInstance = BackendService()
        let systemInstance = SystemService()
        let updaterInstance = AppUpdater()
        let legacyMigrationInstance = LegacySuperSayMigration()

        // Create VM with dependency injection
        let vmInstance = DashboardViewModel(
            backend: backendInstance,
            system: systemInstance,
            audio: audioInstance,
            history: historyInstance,
            startsBackgroundWork: !RuntimeEnvironment.isRunningTests
        )

        // Audiobook VM uses the same shared AudioService for playback
        let audiobookInstance = AudiobookViewModel(audio: audioInstance)

        // Assign to StateObjects
        _audio = StateObject(wrappedValue: audioInstance)
        _history = StateObject(wrappedValue: historyInstance)
        _launchManager = StateObject(wrappedValue: launchInstance)
        _dashboardVM = StateObject(wrappedValue: vmInstance)
        _audiobookVM = StateObject(wrappedValue: audiobookInstance)
        _updater = StateObject(wrappedValue: updaterInstance)
        _legacyMigration = StateObject(wrappedValue: legacyMigrationInstance)

        // Wire mutual exclusion between TTS hotkey playback and audiobook playback
        vmInstance.audiobookVM = audiobookInstance

        backend = backendInstance

        // Don't trigger permission prompts here — the onboarding wizard
        // gates them behind explicit buttons. SystemService still drives
        // ducking + AppleScript permissions on first hotkey use.
        setupShortcuts(vm: vmInstance, audio: audioInstance)

        MetricsService.shared.trackLaunch()
        // Start the periodic flush driver (previously embedded inside the
        // singleton init; now externalized so the actor can stay isolated).
        Task { @MainActor in
            MetricsFlushDriver.shared.start()
        }
        registerCustomFonts()
        checkRunningLocation()
    }

    private func checkRunningLocation() {
        let path = Bundle.main.bundlePath
        if path.contains("/Volumes/") {
            let alert = NSAlert()
            alert.messageText = "Move to Applications"
            alert.informativeText = "Voqora needs to be in your Applications folder to work correctly. Would you like to move it now?"
            alert.addButton(withTitle: "Move to Applications")
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

    private func registerCustomFonts() {
        guard let fontFolder = Bundle.main.resourceURL?.appendingPathComponent("Fonts") else {
            print("📝 FontLoader: Could not locate Fonts directory in bundle.")
            return
        }
        guard let files = try? FileManager.default.contentsOfDirectory(at: fontFolder, includingPropertiesForKeys: nil) else {
            print("📝 FontLoader: No bundled fonts found or directory inaccessible.")
            return
        }

        for url in files where ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                print("⚠️ FontLoader: Failed to register font at \(url.path): \(error?.takeRetainedValue().localizedDescription ?? "Unknown error")")
            } else {
                print("✅ FontLoader: Registered \(url.lastPathComponent)")
            }
        }
    }

    private func setupShortcuts(vm: DashboardViewModel, audio: AudioService) {
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
                audio.stop()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .exportAudio) {
            print("⌨️ KeyboardShortcuts: exportAudio triggered")
            Task { @MainActor in
                audio.exportToDesktop()
            }
        }

        print("⌨️ KeyboardShortcuts: All shortcuts registered.")
    }

    @AppStorage("showMenuBarIcon") var showMenuBarIcon = true

    var body: some Scene {
        WindowGroup(id: "dashboard") {
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
                .environmentObject(legacyMigration)
        }
        .windowStyle(.hiddenTitleBar)
        .handlesExternalEvents(matching: ["dashboard"])

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            Button("Speak Selection") { Task { await dashboardVM.speakSelection() } }
            Button("Stop") { audio.stop() }
            Button("Quit") {
                dashboardVM.stopHeartbeat()
                Task { await backend.stop() }
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

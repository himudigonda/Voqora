import KeyboardShortcuts
import Sparkle
import SwiftUI

@main
struct VoqoraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @StateObject private var audio: AudioService
    @StateObject private var history: HistoryManager
    @StateObject private var launchManager: LaunchManager

    @StateObject private var dashboardVM: DashboardViewModel

    @StateObject private var audiobookVM: AudiobookViewModel

    @StateObject private var onboarding: OnboardingCoordinator

    @StateObject private var identity: IdentityService

    @StateObject private var permissions = PermissionsService.shared

    @StateObject private var updater: AppUpdater

    @StateObject private var installer: GuidedInstallerService

    private let backend: BackendService

    init() {
        let runningTests = RuntimeEnvironment.isRunningTests
        if !runningTests, AppDelegate.standDownIfAlreadyRunning() {
            exit(0)
        }
        if !runningTests {
            let bundleID = Bundle.main.bundleIdentifier ?? "com.himudigonda.Voqora"
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(bundleID)

            try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

            let logURL = appSupport.appendingPathComponent("frontend.log")

            freopen(logURL.path, "w+", stdout)
            freopen(logURL.path, "a+", stderr)
            setbuf(stdout, nil)

            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
            let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
            let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
            VoqoraLog.info("VoqoraApp", "Frontend log started", ["version": appVersion, "build": buildNumber, "os": osVersion])
        }

        _ = AppActivityMonitor.shared

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

        let vmInstance = DashboardViewModel(
            backend: backendInstance,
            system: systemInstance,
            audio: audioInstance,
            history: historyInstance,
            startsBackgroundWork: false
        )

        let audiobookInstance = AudiobookViewModel(audio: audioInstance)

        _audio = StateObject(wrappedValue: audioInstance)
        _history = StateObject(wrappedValue: historyInstance)
        _launchManager = StateObject(wrappedValue: launchInstance)
        _dashboardVM = StateObject(wrappedValue: vmInstance)
        _audiobookVM = StateObject(wrappedValue: audiobookInstance)
        _onboarding = StateObject(wrappedValue: onboardingInstance)
        _identity = StateObject(wrappedValue: identityInstance)
        _updater = StateObject(wrappedValue: updaterInstance)
        _installer = StateObject(wrappedValue: installerInstance)

        vmInstance.audiobookVM = audiobookInstance

        backend = backendInstance
        appDelegate.stopOwnedBackend = { [backendInstance] in
            backendInstance.stop()
        }

        if !runningTests {
            setupShortcuts(vm: vmInstance)

            if !RuntimeEnvironment.disablesTelemetry {
                MetricsService.shared.trackLaunch()
                Task { @MainActor in
                    MetricsFlushDriver.shared.start()
                }
            }
            Task { await identityInstance.retryPendingRemoval() }
            Task { await identityInstance.retryPendingSubmission() }
            Task { await updaterInstance.checkGitHubReleaseAtLaunch() }
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
                guard Self.shortcutAllowed("playText") else { return }
                VoqoraLog.info("KeyboardShortcuts", "playText triggered")
                await vm.speakSelection()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .togglePause) {
            Task { @MainActor in
                guard Self.shortcutAllowed("togglePause") else { return }
                VoqoraLog.info("KeyboardShortcuts", "togglePause triggered")
                vm.togglePlayback()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .stopText) {
            Task { @MainActor in
                guard Self.shortcutAllowed("stopText") else { return }
                VoqoraLog.info("KeyboardShortcuts", "stopText triggered")
                vm.stopPlayback()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .exportAudio) {
            Task { @MainActor in
                guard Self.shortcutAllowed("exportAudio") else { return }
                VoqoraLog.info("KeyboardShortcuts", "exportAudio triggered")
                vm.exportLastClip()
            }
        }

        VoqoraLog.info("KeyboardShortcuts", "All shortcuts registered")
    }

    @MainActor
    private static func shortcutAllowed(_ name: String) -> Bool {
        guard focusedTextInputOwnsShortcut() else { return true }
        VoqoraLog.info("KeyboardShortcuts", "\(name) left to the focused text field")
        return false
    }

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
                    dashboardVM.openAudiobook(book.bookID)
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Continue: \(book.displayTitle)", systemImage: "book.fill")
                }
            }

            Button {
                dashboardVM.showLibrary()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Open Audiobooks", systemImage: "books.vertical")
            }

            Divider()

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
                dashboardVM.selectedTab = "about"
                NSApp.activate(ignoringOtherApps: true)
                Task { await updater.checkGitHubReleaseForUpdate() }
            } label: {
                Label(
                    updater.isCheckingForUpdates ? "Checking for Updates…" : "Check for Updates…",
                    systemImage: "arrow.triangle.2.circlepath"
                )
            }
            .disabled(updater.isCheckingForUpdates)

            Toggle(isOn: $launchManager.isLaunchAtLoginEnabled) {
                Label("Launch at Login", systemImage: "power")
            }

            Divider()

            Button("Quit Voqora") {
                dashboardVM.stopHeartbeat()
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
                    .accessibilityLabel("Voqora")
            }
        }
    }
}

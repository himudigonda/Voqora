import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var stopOwnedBackend: (() -> Void)?
    var flushStudioDrafts: (() -> Void)?
    var flushDictation: (() -> Void)?
    var servicesProvider: NSObject?

    static func standDownIfAlreadyRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .filter { !$0.isTerminated }
        guard let original = others.first else { return false }
        let answered = askRunningCopyToShow(bundleID: bundleID)
        VoqoraLog.warn("AppDelegate", "Another Voqora is already running", [
            "existingPid": "\(original.processIdentifier)",
            "answered": "\(answered)",
        ])
        switch AppPresence.standDownAction(answered: answered, finishedLaunching: original.isFinishedLaunching) {
        case .activateExisting:
            original.activate(options: [])
            return true
        case .offerForceQuit:
            return !replaceFrozenCopy(original)
        }
    }

    private static func askRunningCopyToShow(bundleID: String) -> Bool {
        let center = DistributedNotificationCenter.default()
        var answered = false
        let observer = center.addObserver(forName: AppPresence.dashboardAnswerNotification, object: bundleID, queue: nil) { _ in
            answered = true
        }
        defer { center.removeObserver(observer) }
        center.postNotificationName(AppPresence.showDashboardNotification, object: bundleID, userInfo: nil, deliverImmediately: true)
        let deadline = Date().addingTimeInterval(AppPresence.answerTimeout)
        while !answered, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        return answered
    }

    private static func replaceFrozenCopy(_ original: NSRunningApplication) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Voqora is already open but isn't responding"
        alert.informativeText = "Force quit it and open Voqora again? Anything unsaved in the frozen copy will be lost."
        alert.addButton(withTitle: "Force Quit and Reopen")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        original.forceTerminate()
        let deadline = Date().addingTimeInterval(AppPresence.answerTimeout)
        while !original.isTerminated, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        return original.isTerminated
    }

    func applicationWillFinishLaunching(_: Notification) {
        NotificationPresenter.shared.install()
        if !RuntimeEnvironment.isRunningTests, Self.standDownIfAlreadyRunning() {
            exit(0)
        }
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix("NSSplitView Subview Frames dashboard")
        {
            defaults.removeObject(forKey: key)
        }
    }

    func applicationDidFinishLaunching(_: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.disableSplitViewAutosave()
        }
        AppIconOption.applyStored()
        if let servicesProvider {
            NSApp.servicesProvider = servicesProvider
            NSUpdateDynamicServices()
        }
        if AppPresence.hidesFromDock(), UserDefaults.standard.bool(forKey: OnboardingCoordinator.hasOnboardedKey) {
            NSApp.setActivationPolicy(.accessory)
        }
        DistributedNotificationCenter.default().addObserver(
            forName: AppPresence.showDashboardNotification,
            object: Bundle.main.bundleIdentifier,
            queue: .main
        ) { _ in
            DistributedNotificationCenter.default().postNotificationName(
                AppPresence.dashboardAnswerNotification,
                object: Bundle.main.bundleIdentifier,
                userInfo: nil,
                deliverImmediately: true
            )
            MainActor.assumeIsolated { WindowPresenter.shared.show() }
        }
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return true }
        WindowPresenter.shared.show()
        return false
    }

    private func disableSplitViewAutosave() {
        for window in NSApplication.shared.windows {
            guard let contentView = window.contentView else { continue }
            Self.disableAutosave(in: contentView)
        }
    }

    private static func disableAutosave(in view: NSView) {
        if let splitView = view as? NSSplitView {
            splitView.autosaveName = nil
        }
        for subview in view.subviews {
            disableAutosave(in: subview)
        }
    }

    func applicationWillTerminate(_: Notification) {
        flushStudioDrafts?()
        flushDictation?()
        stopOwnedBackend?()
        UsageStatsStore.shared.commitListening()
        UsageStatsStore.shared.saveNow()
        MetricsFlushDriver.shared.stop()
    }
}

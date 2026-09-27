import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var stopOwnedBackend: (() -> Void)?

    static func standDownIfAlreadyRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .filter { !$0.isTerminated }
        guard let original = others.first else { return false }

        VoqoraLog.warn("AppDelegate", "Another Voqora is already running; activating it and exiting", [
            "existingPid": "\(original.processIdentifier)",
        ])
        original.activate(options: [])
        return true
    }

    func applicationWillFinishLaunching(_: Notification) {
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
        stopOwnedBackend?()
        MetricsFlushDriver.shared.stop()
    }
}

import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    /// Installed by `VoqoraApp` with the exact `BackendService` instance this
    /// app launched. Never terminate a server merely because it shares a name.
    var stopOwnedBackend: (() -> Void)?

    /// `NavigationSplitView`'s sidebar column is backed by an AppKit
    /// `NSSplitView`, which by default persists its divider position via
    /// AppKit's frame-autosave mechanism — a `UserDefaults` key named
    /// `"NSSplitView Subview Frames <window-autosave-name>, <split-view-id>"`.
    ///
    /// On at least one development machine this autosave was observed to
    /// hold a subview height wildly inconsistent with the window's actual
    /// size (e.g. persisting 1576pt for a 1004pt-tall window — reproduced
    /// identically on unmodified pre-redesign code, so it predates and is
    /// unrelated to any UI change here). The window's own frame restores
    /// correctly; only the split view's cached subview frames are wrong,
    /// and nothing in `NavigationSplitView` reconciles them against the
    /// window's real size — so the sidebar and detail content lay out for
    /// a ~1576pt-tall canvas inside an actually-1004pt window, pushing most
    /// of both off the top and bottom of what's visible.
    ///
    /// Removing the stale key before the window is created (so the corrupt
    /// value is never read) and disabling the autosave going forward (so it
    /// can never be written again) closes off this whole failure mode,
    /// regardless of whatever originally wrote the bad value.
    /// True when this process stood down for an already-running Voqora, so
    /// later launch steps can skip work that a second instance must not do.
    private(set) var isRedundantInstance = false

    /// Voqora must be a single instance per user session.
    ///
    /// Until v1.2.2 this was enforced by accident: the backend bound a fixed
    /// loopback port, so a second app's server hit EADDRINUSE and could not
    /// serve, and both apps talked to the one surviving backend — whose
    /// module-level `interactive_tts_lock` then serialised them. v1.2.3 gave
    /// every instance its own app-owned ephemeral socket, which removed that
    /// accidental mutex: a second instance now gets a fully working private
    /// backend, so two copies of a ~330 MB model load and run inference
    /// against each other, and both register the same global hotkey.
    ///
    /// Voqora is also a login item, so an ordinary "open the app again" or
    /// running a local build alongside the installed copy lands in exactly
    /// that state. Activate the original and stand down instead.
    private func standDownIfAlreadyRunning() -> Bool {
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
        if standDownIfAlreadyRunning() {
            isRedundantInstance = true
            // Terminate before SwiftUI builds a window or BackendService
            // spawns a server. `exit` rather than `NSApp.terminate` because
            // the latter runs the normal shutdown path, which would tear down
            // shared on-disk state (logs) this instance never owned.
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
        // The window exists by the time this fires, but give SwiftUI's own
        // initial layout pass a runloop turn to finish before walking the
        // view hierarchy for the NSSplitView AppKit created underneath it.
        DispatchQueue.main.async { [weak self] in
            self?.disableSplitViewAutosave()
        }
        // Re-applies the user's last-chosen app icon (Dock + Finder) on
        // every launch — a plain `NSImage` override doesn't persist across
        // relaunches on its own, only the stored preference does.
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

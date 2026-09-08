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
    func applicationWillFinishLaunching(_: Notification) {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("NSSplitView Subview Frames dashboard") {
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

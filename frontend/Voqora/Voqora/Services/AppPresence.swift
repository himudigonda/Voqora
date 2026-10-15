import AppKit
import SwiftUI

enum AppPresence {
    static let hideFromDockKey = "hideFromDock"
    static let showMenuBarIconKey = "showMenuBarIcon"
    static let showDashboardNotification = Notification.Name("com.himudigonda.Voqora.showDashboard")

    static func hidesFromDock(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: hideFromDockKey)
    }

    static func setHideFromDock(_ hidden: Bool, defaults: UserDefaults = .standard) {
        defaults.set(hidden, forKey: hideFromDockKey)
        if hidden {
            defaults.set(true, forKey: showMenuBarIconKey)
        }
    }

    static func setShowMenuBarIcon(_ shown: Bool, defaults: UserDefaults = .standard) {
        defaults.set(shown, forKey: showMenuBarIconKey)
        if !shown {
            defaults.set(false, forKey: hideFromDockKey)
        }
    }

    static func activationPolicy(hideFromDock: Bool, onboarding: Bool) -> NSApplication.ActivationPolicy {
        hideFromDock && !onboarding ? .accessory : .regular
    }

    @MainActor
    static func applyActivationPolicy(onboarding: Bool, defaults: UserDefaults = .standard) {
        let policy = activationPolicy(hideFromDock: hidesFromDock(defaults), onboarding: onboarding)
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        WindowPresenter.shared.show()
    }
}

@MainActor
final class WindowPresenter {
    static let shared = WindowPresenter()

    var openDashboard: (() -> Void)?

    private var dashboardWindows: [NSWindow] {
        NSApp.windows.filter { window in
            window.identifier?.rawValue.hasPrefix("dashboard") == true && window.canBecomeMain
        }
    }

    func show() {
        if let window = dashboardWindows.first {
            window.makeKeyAndOrderFront(nil)
        } else {
            openDashboard?()
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

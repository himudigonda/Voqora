import AppKit
import SwiftUI

@MainActor
enum AppWindows {
    private static var navigateAction: ((String) -> Void)?
    private static var pendingKey: String?

    static func register(navigate: @escaping (String) -> Void) {
        navigateAction = navigate
        if let pendingKey {
            self.pendingKey = nil
            navigate(pendingKey)
        }
    }

    static func open(tab key: String) {
        if let navigateAction {
            navigateAction(key)
        } else {
            pendingKey = key
        }
        WindowPresenter.shared.show()
    }

    static func openSettings(tab: SettingsTab = .general) {
        open(tab: TabKey.settings(tab))
    }

    static func openAbout() {
        open(tab: TabKey.about)
    }

    static func openFeedback() {
        open(tab: TabKey.feedback)
    }
}

private struct WindowAppearance: ViewModifier {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    func body(content: Content) -> some View {
        content
            .voqoraTheme()
            .background(vm.theme.surface)
            .tint(vm.accentColor(scheme: colorScheme, contrast: colorSchemeContrast))
            .preferredColorScheme(vm.appTheme == "system" ? nil : (vm.appTheme == "dark" ? .dark : .light))
    }
}

extension View {
    func voqoraWindowAppearance() -> some View {
        modifier(WindowAppearance())
    }
}

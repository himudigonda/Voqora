import SwiftUI

extension DictationController {
    func installSystemIntegrations(dashboard: DashboardViewModel) {
        speechPauser = dashboard
        hud = DictationHUDPresenter(
            rootView: DictationHUDView()
                .environmentObject(self)
                .environmentObject(dashboard)
        )
        registerShortcut()
    }
}

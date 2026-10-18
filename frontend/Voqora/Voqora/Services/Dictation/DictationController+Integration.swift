import SwiftUI

extension DictationController {
    func installSystemIntegrations(appearance: DashboardViewModel) {
        speechPauser = appearance
        hud = DictationHUDPresenter(
            rootView: DictationHUDView()
                .environmentObject(self)
                .environmentObject(appearance)
        )
        registerShortcut()
    }
}

import SwiftUI

extension DictationController {
    func installSystemIntegrations(dashboard: DashboardViewModel) {
        speechPauser = dashboard
        hud = DictationHUDPresenter(
            rootView: DictationHUDView()
                .environmentObject(self)
                .environmentObject(dashboard)
        )
        let client = AIReadingClient()
        connectTidy { [weak dashboard] text in
            guard let credential = dashboard?.audiobookVM?.providers.activeCredential else {
                throw AIReadingError.providerRequired
            }
            guard AIReadingLimits.length(of: text) <= AIReadingLimits.tidyCharacters else {
                throw AIReadingError.tooLong("That dictation is too long to tidy.")
            }
            return try await client.tidy(text: text, credential: credential).text
        }
        registerShortcut()
    }
}

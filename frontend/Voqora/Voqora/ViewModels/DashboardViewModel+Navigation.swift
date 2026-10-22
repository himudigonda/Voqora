import Foundation

extension DashboardViewModel {
    func showSettings(_ tab: SettingsTab = .general) {
        selectedTab = TabKey.settings(tab)
    }

    func showAbout() {
        selectedTab = TabKey.about
    }

    func showFeedback() {
        selectedTab = TabKey.feedback
    }

    func showNewAudiobook(with source: AudiobookCreateSource, request: AudiobookCreateRequest? = nil) {
        (request ?? AudiobookCreateRequest.shared).pending = source
        selectedTab = TabKey.createAudiobook
    }
}

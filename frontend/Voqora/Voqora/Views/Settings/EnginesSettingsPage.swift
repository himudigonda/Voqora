import SwiftUI

struct EnginesSettingsPage: View {
    var body: some View {
        SettingsPage(.engines) {
            SettingsNoticeRow(text: SharedSettingsCopy.engineRecommendation, kind: .info, systemImage: "bolt.fill")
            SpeechEnginesSection()
        }
    }
}

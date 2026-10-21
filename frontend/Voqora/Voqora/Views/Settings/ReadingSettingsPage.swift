import SwiftUI

struct ReadingSettingsPage: View {
    @ObservedObject private var preferences = ReadingPreferences.shared

    var body: some View {
        SettingsPage(.reading) {
            ReadingSettingsSections(preferences: preferences)
        }
    }
}

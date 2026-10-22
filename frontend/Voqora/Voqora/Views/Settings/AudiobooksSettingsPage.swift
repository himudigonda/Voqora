import SwiftUI

struct AudiobooksSettingsPage: View {
    var body: some View {
        SettingsPage(.audiobooks) {
            AudiobookDefaultsSections()
        }
    }
}

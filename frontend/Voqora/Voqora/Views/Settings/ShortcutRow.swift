import KeyboardShortcuts
import SwiftUI

struct ShortcutRow: View {
    let title: String
    var detail: String?
    var systemImage: String?
    let name: KeyboardShortcuts.Name

    var body: some View {
        SettingsRowShell(title: title, detail: detail, systemImage: systemImage) {
            KeyboardShortcuts.Recorder(for: name)
        }
    }
}

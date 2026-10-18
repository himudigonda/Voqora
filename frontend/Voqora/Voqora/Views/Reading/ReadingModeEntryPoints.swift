import AppKit
import SwiftUI

extension OpenWindowAction {
    func openReadingMode() {
        callAsFunction(id: ReadingModeWindow.id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct ReadingModeButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        PlayerCircleButton(systemName: "doc.plaintext", label: ReadingModeWindow.title) {
            openWindow.openReadingMode()
        }
        .accessibilityHint("Opens the transcript in a large, adjustable reading window")
    }
}

struct ReadingModeMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow.openReadingMode()
        } label: {
            Label(ReadingModeWindow.title, systemImage: "doc.plaintext")
        }
    }
}

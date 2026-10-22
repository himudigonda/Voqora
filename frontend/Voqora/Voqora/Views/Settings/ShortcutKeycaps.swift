import KeyboardShortcuts
import SwiftUI

struct ShortcutKeycaps: View {
    enum Size {
        case compact
        case large

        var side: CGFloat {
            self == .large ? 64 : 40
        }

        var fontSize: CGFloat {
            self == .large ? 26 : 17
        }
    }

    let name: KeyboardShortcuts.Name
    var size: Size = .large

    @Environment(\.voqoraTheme) private var theme
    @State private var shortcutDescription: String?

    var body: some View {
        let caps = DictationStateLabel.keycaps(from: shortcutDescription)
        HStack(spacing: 10) {
            if caps.isEmpty {
                Text("Not set")
                    .voqoraFont(.title)
                    .foregroundStyle(theme.onSurfaceMuted)
            }
            ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                Text(cap)
                    .font(.system(size: cap.count > 1 ? size.fontSize * 0.7 : size.fontSize, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.onSurface)
                    .frame(minWidth: size.side, minHeight: size.side)
                    .padding(.horizontal, cap.count > 1 ? 8 : 0)
                    .background(theme.surfaceContainerHighest, in: RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caps.isEmpty ? "No shortcut set" : caps.joined(separator: " "))
        .onAppear { shortcutDescription = KeyboardShortcuts.getShortcut(for: name)?.description }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("KeyboardShortcuts_shortcutByNameDidChange"))) { _ in
            shortcutDescription = KeyboardShortcuts.getShortcut(for: name)?.description
        }
    }
}

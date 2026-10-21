import KeyboardShortcuts
import SwiftUI

struct OnboardingShortcutsStep: View {
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.card) {
            ShortcutKeycaps(name: .playText)
                .padding(Theme.Space.card)
                .frame(maxWidth: .infinity)
                .background(theme.surfaceContainerLow, in: RoundedRectangle(cornerRadius: Theme.Shape.lg, style: .continuous))
            SettingsSection(title: "Your shortcuts", footer: OnboardingCopy.shortcutsFooter) {
                ShortcutRow(title: "Speak Selection", detail: "Press once to read the selected text, again to stop.", systemImage: "text.cursor", name: .playText)
                ShortcutRow(title: "Start / Finish Dictation", detail: "Press once to start listening and again to finish.", systemImage: "mic", name: .toggleDictation)
            }
            ListGroup {
                ForEach(OnboardingCopy.hotkeyTips, id: \.title) { tip in
                    ListItem(
                        title: tip.title,
                        supporting: tip.body,
                        leading: { ListItemIcon(systemImage: tip.systemImage) },
                        trailing: { EmptyView() }
                    )
                }
            }
        }
    }
}

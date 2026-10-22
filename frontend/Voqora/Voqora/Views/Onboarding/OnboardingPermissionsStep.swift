import SwiftUI

struct OnboardingPermissionsStep: View {
    @EnvironmentObject var permissions: PermissionsService
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            SettingsSection(title: "Needed to read selected text", footer: OnboardingCopy.accessibilityFooter) {
                PermissionRow(kind: .accessibility)
            }
            if !permissions.accessibilityGranted {
                ListGroup {
                    ForEach(Array(OnboardingCopy.axSteps.enumerated()), id: \.offset) { index, text in
                        ListItem(
                            title: text,
                            leading: { numberBadge(index + 1) },
                            trailing: { EmptyView() }
                        )
                    }
                }
            }
            SettingsSection(title: "Optional", footer: OnboardingCopy.notificationsFooter) {
                PermissionRow(kind: .notifications)
            }
        }
    }

    private func numberBadge(_ number: Int) -> some View {
        Text("\(number)")
            .voqoraFont(.titleSmall)
            .foregroundStyle(theme.onPrimaryContainer)
            .frame(width: 40, height: 40)
            .background(theme.primaryContainer.opacity(0.65), in: Circle())
            .accessibilityHidden(true)
    }
}

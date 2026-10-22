import SwiftUI

struct OnboardingDictationStep: View {
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            ShortcutKeycaps(name: .toggleDictation)
                .padding(Theme.Space.card)
                .frame(maxWidth: .infinity)
                .background(theme.surfaceContainerLow, in: RoundedRectangle(cornerRadius: Theme.Shape.lg, style: .continuous))
            DictationEnginePicker()
            DictationPermissionRows()
            DictationCaptureSection()
            Text(OnboardingCopy.dictationServerNote)
                .voqoraFont(.bodySmall)
                .foregroundStyle(theme.onSurfaceVariant)
                .padding(.horizontal, 4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

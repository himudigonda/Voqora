import SwiftUI

struct StudioBanner: View {
    let message: String
    var tint: Color?
    var systemImage = "exclamationmark.triangle.fill"
    var onDismiss: (() -> Void)?

    @Environment(\.voqoraTheme) private var theme

    private var resolvedTint: Color {
        tint ?? theme.warning
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.item) {
            Image(systemName: systemImage)
                .foregroundStyle(resolvedTint)
                .accessibilityHidden(true)
            Text(message)
                .voqoraFont(.body)
                .foregroundStyle(theme.onSurface)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.voqoraIcon)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(Theme.Space.item + 4)
        .background(resolvedTint.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

struct StudioIssueLabel: View {
    let message: String

    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .voqoraFont(.bodySmall)
            .foregroundStyle(theme.danger)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct StudioCapsuleField: View {
    let prompt: String
    @Binding var text: String
    var label: String?

    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        TextField(prompt, text: $text)
            .textFieldStyle(.plain)
            .voqoraFont(.body)
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background(theme.surfaceContainerHigh, in: Capsule())
            .accessibilityLabel(label ?? prompt)
    }
}

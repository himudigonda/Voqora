import SwiftUI

struct VoqoraSheet<Content: View>: View {
    let title: String
    var supporting: String?
    var primaryTitle: String?
    var isPrimaryEnabled = true
    var width: CGFloat = 480
    var onPrimary: (() -> Void)?
    var onClose: (() -> Void)?
    @ViewBuilder var content: Content

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, Theme.Space.card)
            if let primaryTitle {
                actionRow(primaryTitle)
            }
        }
        .padding(.bottom, primaryTitle == nil ? 28 : 0)
        .frame(width: width)
        .presentationBackground(theme.surfaceContainerHigh)
        .presentationCornerRadius(Theme.Shape.xl)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Space.item) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(vm.font(.headline))
                    .foregroundStyle(theme.onSurface)
                    .accessibilityAddTraits(.isHeader)
                if let supporting {
                    Text(supporting)
                        .font(vm.font(.body))
                        .foregroundStyle(theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.voqoraIcon)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")
        }
        .padding(.leading, 28)
        .padding(.trailing, 16)
        .padding(.top, 24)
    }

    private func actionRow(_ primaryTitle: String) -> some View {
        HStack(spacing: Theme.Space.item) {
            Spacer(minLength: 0)
            Button("Cancel") { close() }
                .buttonStyle(.voqoraText)
            Button(primaryTitle) { onPrimary?() }
                .buttonStyle(.voqoraFilled)
                .disabled(!isPrimaryEnabled)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }
}

import SwiftUI

struct AudiobookToastView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        if let toast = bookVM.toast {
            HStack(spacing: Theme.Space.item) {
                Image(systemName: iconName(for: toast.kind))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(color(for: toast.kind))
                    .frame(width: 32, height: 32)
                    .background(color(for: toast.kind).opacity(0.16), in: Circle())
                    .accessibilityHidden(true)
                Text(toast.message)
                    .font(vm.font(.label))
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(Self.lineLimit(for: toast.kind))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button { bookVM.dismissToast() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.voqoraIcon)
                .accessibilityLabel("Dismiss")
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 8)
            .background(theme.surfaceContainerHighest, in: RoundedRectangle(cornerRadius: Theme.Shape.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Shape.lg, style: .continuous)
                    .strokeBorder(theme.outlineVariant, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .frame(maxWidth: 520)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func iconName(for kind: AudiobookViewModel.Toast.Kind) -> String {
        switch kind {
        case .error: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        }
    }

    private func color(for kind: AudiobookViewModel.Toast.Kind) -> Color {
        switch kind {
        case .error: theme.danger
        case .info: theme.primary
        case .success: theme.success
        }
    }

    static func lineLimit(for kind: AudiobookViewModel.Toast.Kind) -> Int? {
        kind == .error ? nil : 2
    }
}

import SwiftUI

/// Floating toast/banner mounted at the top of the detail pane.
struct AudiobookToastView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel

    var body: some View {
        if let toast = bookVM.toast {
            HStack(spacing: 12) {
                Image(systemName: iconName(for: toast.kind))
                    .foregroundStyle(color(for: toast.kind))
                    .font(.system(size: 14, weight: .bold))
                Text(toast.message)
                    .font(vm.appFont(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button { bookVM.dismissToast() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(color(for: toast.kind).opacity(0.4), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .frame(maxWidth: 520)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func iconName(for kind: AudiobookViewModel.Toast.Kind) -> String {
        switch kind {
        case .error: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        }
    }

    private func color(for kind: AudiobookViewModel.Toast.Kind) -> Color {
        switch kind {
        case .error: return .red
        case .info: return .cyan
        case .success: return .green
        }
    }
}

import SwiftUI

struct EmptyStateAction {
    let title: String
    let perform: () -> Void
}

struct EmptyStateView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    let symbol: String
    let title: String
    let message: String
    var action: EmptyStateAction?

    var body: some View {
        VStack(spacing: Theme.Space.item) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(theme.onPrimaryContainer)
                .frame(width: 72, height: 72)
                .background(theme.primaryContainer.opacity(0.65), in: Circle())
                .accessibilityHidden(true)
            VStack(spacing: Theme.Space.unit) {
                Text(title)
                    .font(vm.font(.title))
                    .foregroundStyle(theme.onSurface)
                Text(message)
                    .font(vm.font(.body))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
            }
            if let action {
                Button(action.title, action: action.perform)
                    .buttonStyle(.voqoraFilled)
                    .padding(.top, Theme.Space.unit)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .accessibilityElement(children: .contain)
    }
}

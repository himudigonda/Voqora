import AppKit
import SwiftUI

struct AppIconChoiceButton: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    let option: AppIconOption
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Group {
                    if let nsImage = NSImage(named: option.assetName) {
                        Image(nsImage: nsImage).resizable()
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                Text(option.displayName)
                    .font(vm.font(.labelSmall))
                    .foregroundStyle(isSelected ? theme.onPrimaryContainer : theme.onSurfaceVariant)
            }
            .padding(10)
            .background(isSelected ? theme.primaryContainer : .clear, in: RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous)
                    .strokeBorder(isSelected ? theme.primary : theme.outlineVariant, lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(Theme.Motion.selection, value: isSelected)
        .accessibilityLabel(option.displayName)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help(option.displayName)
    }
}

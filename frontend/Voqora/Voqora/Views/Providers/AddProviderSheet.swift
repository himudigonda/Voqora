import SwiftUI

struct AddProviderSheet: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private let opensDirectly: Bool
    @State private var selected: LLMProvider?

    init(provider: LLMProvider? = nil) {
        opensDirectly = provider != nil
        _selected = State(initialValue: provider)
    }

    var body: some View {
        Group {
            if let selected {
                ProviderConnectForm(
                    provider: selected,
                    backTitle: opensDirectly ? "Cancel" : "Back",
                    onBack: {
                        if opensDirectly {
                            dismiss()
                        } else {
                            withAnimation(DesignTokens.Animation.standard) { self.selected = nil }
                        }
                    },
                    onFinished: { dismiss() }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                chooser
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .padding(32)
        .frame(width: 760, height: selected == nil ? 700 : 560)
        .voqoraSurface(.floating, in: Rectangle())
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 18) {
                Image(systemName: "square.3.layers.3d")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(vm.accentColor(scheme: colorScheme, contrast: colorSchemeContrast))
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add a provider")
                        .font(vm.appFont(size: 24, weight: .bold))
                        .foregroundStyle(Palette.textPrimary)
                    Text("Your preferred models, connected to Voqora.")
                        .font(vm.appFont(size: 14))
                        .foregroundStyle(Palette.textSecondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.voqoraSecondary)
                    .keyboardShortcut(.cancelAction)
            }
            Divider()
            Text("Choose a provider")
                .font(vm.appFont(size: 15, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
            ScrollView {
                ProviderPickerGrid { provider in
                    withAnimation(DesignTokens.Animation.standard) { selected = provider }
                }
                .padding(.vertical, 2)
            }
            Label("Adding a provider won't change your current narration setup.", systemImage: "info.circle")
                .font(vm.appFont(size: 12))
                .foregroundStyle(Palette.textSecondary)
        }
    }
}

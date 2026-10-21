import SwiftUI

struct SegmentedTabs<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    var systemImage: ((Value) -> String?)?

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                segment(option)
            }
        }
        .padding(3)
        .overlay(Capsule().strokeBorder(theme.outline.opacity(0.6), lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .contain)
    }

    private func segment(_ option: Value) -> some View {
        let isSelected = option == selection
        return Button {
            withAnimation(Theme.Motion.selection) { selection = option }
        } label: {
            HStack(spacing: 6) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                } else if let name = systemImage?(option) {
                    Image(systemName: name)
                        .font(.system(size: 12, weight: .medium))
                }
                Text(title(option))
                    .font(vm.font(.label))
            }
            .foregroundStyle(isSelected ? theme.onPrimaryContainer : theme.onSurfaceVariant)
            .padding(.horizontal, 16)
            .frame(minHeight: 34)
            .background(isSelected ? theme.primaryContainer : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension SegmentedTabs where Value: CaseIterable & RawRepresentable, Value.RawValue == String {
    init(selection: Binding<Value>) {
        self.init(
            selection: selection,
            options: Array(Value.allCases),
            title: { $0.rawValue.capitalized },
            systemImage: nil
        )
    }
}

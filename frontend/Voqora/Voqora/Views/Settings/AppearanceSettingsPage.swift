import SwiftUI

struct AppearanceSettingsPage: View {
    @EnvironmentObject var vm: DashboardViewModel

    private static let fontOptions = ["Google Sans", "Poppins"]
    private static let systemFontOptions = ["System Rounded", "System Standard", "System Mono", "System Serif"]

    var body: some View {
        SettingsPage(.appearance) {
            AppearancePreviewCard()
            AppearanceLookSection()
            SettingsSection(title: "Font") {
                SettingsPickerRow(title: "Font", detail: "Used across the whole app.", systemImage: "textformat", valueLabel: vm.selectedFontName) {
                    Picker("Font", selection: $vm.selectedFontName) {
                        ForEach(Self.fontOptions, id: \.self) { Text($0).tag($0) }
                        Divider()
                        ForEach(Self.systemFontOptions, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
                SettingsButtonRow(
                    title: "More Fonts",
                    detail: "Pick any font installed on your Mac.",
                    systemImage: "textformat.size",
                    buttonTitle: "More Fonts…"
                ) {
                    vm.showFontPanel()
                }
            }
        }
    }
}

struct AppearancePreviewCard: View {
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        VoqoraCard {
            VStack(alignment: .leading, spacing: Theme.Space.item) {
                Text("Preview")
                    .voqoraFont(.labelSmall)
                    .foregroundStyle(theme.onSurfaceVariant)
                Text("Good evening")
                    .voqoraFont(.headline)
                    .foregroundStyle(theme.onSurface)
                Text("This is how headings, buttons and chips look with your theme and accent.")
                    .voqoraFont(.body)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Space.item) {
                    Button("Filled button") {}
                        .buttonStyle(.voqoraFilled)
                    Button("Tonal button") {}
                        .buttonStyle(.voqoraTonal)
                    FilterChip(title: "Selected chip", isSelected: true) {}
                    StatusChip(text: "Status", kind: .info)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Appearance preview")
    }
}

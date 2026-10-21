import SwiftUI

struct AddProviderSheet: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var providers: LLMProviderStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.voqoraTheme) private var theme

    private let opensDirectly: Bool
    private let cleaningCount: (LLMProvider) -> Int
    @State private var selected: LLMProvider?

    init(provider: LLMProvider? = nil, cleaningCount: @escaping (LLMProvider) -> Int = { _ in 0 }) {
        opensDirectly = provider != nil
        self.cleaningCount = cleaningCount
        _selected = State(initialValue: provider)
    }

    var body: some View {
        Group {
            if let selected {
                ProviderConnectForm(
                    provider: selected,
                    cleaningCount: cleaningCount,
                    onBack: opensDirectly ? nil : {
                        withAnimation(Theme.Motion.selection) { self.selected = nil }
                    },
                    onClose: { dismiss() },
                    onFinished: { dismiss() }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                chooser
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .voqoraTheme()
    }

    private var audiobookFooter: String {
        if let active = providers.activeProvider {
            return "Audiobooks keep using \(active.displayName) until you choose another."
        }
        if providers.needsActiveChoice {
            return "Choose which provider audiobooks use in Settings."
        }
        return "Audiobooks will use the first provider you connect."
    }

    private var chooser: some View {
        VoqoraSheet(
            title: "Add a provider",
            supporting: "Pick the service behind AI cleanup, summaries and translation.",
            width: 640,
            onClose: { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.card) {
                ScrollView {
                    ProviderPickerGrid { provider in
                        withAnimation(Theme.Motion.selection) { selected = provider }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.never)
                .frame(height: 380)
                Label(audiobookFooter, systemImage: "info.circle")
                    .voqoraFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
        }
    }
}

import SwiftUI

struct AISettingsPage: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var providers: LLMProviderStore
    @EnvironmentObject var bookVM: AudiobookViewModel

    @State private var sheet: ProviderSheet?
    @State private var removalTarget: LLMProvider?

    var body: some View {
        SettingsPage(.ai, accessory: {
            Button {
                sheet = .add
            } label: {
                Label("Add Provider", systemImage: "plus")
            }
            .buttonStyle(.voqoraFilled)
        }, content: {
            AICleanupSettings(sheet: $sheet, removalTarget: $removalTarget)
            AIReadingSettings()
        })
        .sheet(item: $sheet) { sheet in
            Group {
                switch sheet {
                case .add: AddProviderSheet(cleaningCount: bookVM.cleaningBookCount(using:))
                case let .edit(provider): AddProviderSheet(provider: provider, cleaningCount: bookVM.cleaningBookCount(using:))
                }
            }
            .environmentObject(vm)
            .environmentObject(providers)
        }
        .providerRemovalDialog(target: $removalTarget, cleaningCount: bookVM.cleaningBookCount(using:))
    }
}

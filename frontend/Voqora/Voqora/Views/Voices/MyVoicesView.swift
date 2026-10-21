import SwiftUI

struct MyVoicesView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @ObservedObject private var store = VoiceBlendStore.shared
    @ObservedObject private var engines = SpeechEngineStore.shared
    @StateObject private var mingStudio = MingVoiceStudioModel(engines: .shared)
    @State private var sheet: NewVoiceSheet?
    @State private var pendingDeletion: MyVoiceItem?
    @State private var actionError: String?

    private var items: [MyVoiceItem] {
        MyVoiceItems.make(blends: store.blends, mingVoices: engines.mingVoices)
    }

    var body: some View {
        PageScaffold(title: VoicesPage.myVoices.title, subtitle: VoicesPage.myVoices.subtitle) {
            Button { sheet = .chooser } label: {
                Label("New Voice", systemImage: "plus")
            }
            .buttonStyle(.voqoraFilled)
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(store.state != .loaded)
            .help("Make a new voice")
        } content: {
            if let message = actionError ?? mingStudio.errorMessage {
                VoicesBanner(message: message)
            }
            voicesContent
        }
        .navigationTitle(VoicesPage.myVoices.title)
        .sheet(item: $sheet) { current in
            sheetContent(current)
                .voqoraSheetContent(vm)
        }
        .confirmationDialog(
            "Delete \(pendingDeletion?.name ?? "Voice")?",
            isPresented: isConfirmingDeletion,
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { item in
            Button("Delete Voice", role: .destructive) { delete(item) }
        } message: { item in
            Text(MyVoiceItems.deletionWarning(for: item))
        }
        .task(id: vm.isBackendOnline) {
            if vm.isBackendOnline {
                await store.refresh()
                await engines.refresh()
            }
        }
        .onDisappear {
            mingStudio.stopSample()
        }
    }

    private var isConfirmingDeletion: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { presented in
                if !presented {
                    pendingDeletion = nil
                }
            }
        )
    }

    @ViewBuilder
    private func sheetContent(_ current: NewVoiceSheet) -> some View {
        switch current {
        case .chooser:
            NewVoiceChooserSheet(store: store, engines: engines) { choice in
                sheet = choice
            }
        case let .blend(blend):
            VoiceBlendEditorSheet(store: store, editing: blend)
        case .describe:
            DescribeVoiceSheet(store: engines, model: mingStudio)
        case .clone:
            CloneVoiceSheet(store: engines, model: mingStudio)
        }
    }

    @ViewBuilder
    private var voicesContent: some View {
        switch store.state {
        case .idle, .loading:
            VoicesLoadingRow(text: "Loading your voices…")
        case let .failed(message):
            VoicesBanner(message: message, actionTitle: "Try Again") {
                Task { await store.refresh() }
            }
        case .loaded:
            let items = items
            if items.isEmpty {
                EmptyStateView(
                    symbol: "person.wave.2",
                    title: "No voices of your own yet",
                    message: "Blend built-in voices, describe a new one in words, or clone one from a short recording. Everything you make appears here and in every voice picker.",
                    action: EmptyStateAction(title: "New Voice") { sheet = .chooser }
                )
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.item) {
                    VoicesSectionHeader(title: "Your voices", trailing: "\(items.count)")
                    ListGroup {
                        ForEach(items) { item in
                            MyVoiceRow(
                                item: item,
                                isPlaying: isPlaying(item),
                                isLoading: mingStudio.loadingSampleID == item.id,
                                isDeleting: mingStudio.deletingID == item.id,
                                togglePlay: { togglePlay(item) },
                                edit: { sheet = .blend(item.blend) },
                                delete: { pendingDeletion = item }
                            )
                        }
                    }
                }
            }
        }
    }

    private func isPlaying(_ item: MyVoiceItem) -> Bool {
        mingStudio.playingID == item.id
    }

    private func togglePlay(_ item: MyVoiceItem) {
        if let voice = item.mingVoice {
            mingStudio.toggleSample(voice)
        } else {
            mingStudio.stopSample()
            Task { await SpeechSource.$current.withValue(.sample) { await vm.speak(text: DashboardViewModel.sampleSentence(forVoice: item.id), voice: item.id) } }
        }
    }

    private func delete(_ item: MyVoiceItem) {
        pendingDeletion = nil
        actionError = nil
        if let voice = item.mingVoice {
            Task { await mingStudio.delete(voice) }
        } else if let blend = item.blend {
            Task {
                do {
                    try await store.delete(blend)
                } catch {
                    actionError = error.localizedDescription
                }
            }
        }
    }
}

private struct MyVoiceRow: View {
    @EnvironmentObject var vm: DashboardViewModel
    let item: MyVoiceItem
    let isPlaying: Bool
    let isLoading: Bool
    let isDeleting: Bool
    let togglePlay: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        ListItem(
            title: item.name,
            supporting: item.supporting,
            leading: {
                VoicePlayButton(
                    name: item.name,
                    isPlaying: isPlaying,
                    isLoading: isLoading,
                    isEnabled: vm.isBackendOnline,
                    action: togglePlay
                )
            },
            trailing: {
                HStack(spacing: 8) {
                    VoiceDefaultChips(voiceID: item.id)
                    StatusChip(text: item.kind.title, kind: .neutral)
                    VoiceUseMenu(voiceID: item.id, name: item.name)
                    if item.blend != nil {
                        Button(action: edit) {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.voqoraIcon)
                        .help("Edit \(item.name)")
                        .accessibilityLabel("Edit \(item.name)")
                    }
                    if isDeleting {
                        ProgressView().controlSize(.small).frame(width: 40)
                    } else {
                        Button(action: delete) {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.voqoraIcon)
                        .help("Delete \(item.name)")
                        .accessibilityLabel("Delete \(item.name)")
                    }
                }
            }
        )
        .contextMenu {
            if item.blend != nil {
                Button("Edit…", action: edit)
            }
            Button("Delete…", role: .destructive, action: delete)
        }
        .accessibilityElement(children: .contain)
    }
}

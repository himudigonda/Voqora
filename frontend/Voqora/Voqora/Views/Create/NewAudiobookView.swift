import SwiftUI

struct NewAudiobookView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @EnvironmentObject var providers: LLMProviderStore
    @ObservedObject private var request = AudiobookCreateRequest.shared
    @StateObject private var form = AudiobookCreateForm()
    @State private var isChoosingFile = false
    @State private var isAddingProvider = false

    var body: some View {
        PageScaffold(
            title: "New Audiobook",
            subtitle: "Turn a document, a web page, or text you paste into an audiobook.",
            scrolls: false
        ) {
            FormColumns {
                NewAudiobookSourceSection(form: form) { isChoosingFile = true }
                NewAudiobookVoiceSection(form: form)
                NewAudiobookCleanupSection(form: form, addProvider: { isAddingProvider = true }, providerChosen: refreshEstimateIfStale)
            } side: {
                AudiobookSummaryCard(form: form) { createAudiobook() }
            }
        }
        .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: AudiobookImportStaging.documentTypes) { result in
            switch result {
            case let .success(url): form.load(.file(url), library: bookVM)
            case let .failure(error): bookVM.showToast("Could not open that document: \(error.localizedDescription)", kind: .error)
            }
        }
        .sheet(isPresented: $isAddingProvider, onDismiss: refreshEstimateIfStale) {
            AddProviderSheet(cleaningCount: bookVM.cleaningBookCount(using:))
                .environmentObject(vm)
                .environmentObject(providers)
        }
        .onAppear {
            form.configure(library: bookVM)
            consumePending()
        }
        .onChange(of: request.pending) { _, _ in consumePending() }
        .onChange(of: form.voice) { _, _ in form.voiceDidChange() }
        .task(id: form.narrationKey) {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            form.applyNarration(library: bookVM)
        }
    }

    private func consumePending() {
        guard let source = request.pending else { return }
        request.pending = nil
        if bookVM.pendingSource != nil {
            bookVM.cancelUpload()
        }
        form.load(source, library: bookVM)
    }

    private func createAudiobook() {
        if form.useCleanup, providers.activeCredential == nil {
            bookVM.showToast(AudiobookViewModel.missingProviderMessage, kind: .error)
            return
        }
        Task {
            guard await form.create(library: bookVM) else { return }
            if bookVM.pendingSource == nil {
                vm.showLibrary()
            }
        }
    }

    private func refreshEstimateIfStale() {
        guard let estimate = bookVM.pendingEstimate,
              AudiobookViewModel.isEstimateStale(estimate, credential: providers.activeCredential)
        else { return }
        bookVM.refreshEstimate()
    }
}

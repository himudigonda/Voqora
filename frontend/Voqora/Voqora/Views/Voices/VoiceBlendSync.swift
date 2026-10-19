import SwiftUI

private struct VoiceBlendSync: ViewModifier {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @ObservedObject var store: VoiceBlendStore
    @ObservedObject var engines: SpeechEngineStore

    func body(content: Content) -> some View {
        content
            .task(id: vm.isBackendOnline) {
                if vm.isBackendOnline {
                    await store.refresh()
                    await engines.refresh()
                }
            }
            .onChange(of: store.revision) { _, _ in reconcile() }
            .onChange(of: engines.revision) { _, _ in reconcile() }
    }

    private func reconcile() {
        let speech = engines.resolvedVoice(store.resolvedVoice(vm.selectedVoice))
        if speech != vm.selectedVoice {
            VoqoraLog.info("VoiceBlendSync", "Speech voice is no longer available, using a fallback voice")
            vm.selectedVoice = speech
        }
        let book = engines.resolvedVoice(store.resolvedVoice(bookVM.defaultBookVoice))
        if book != bookVM.defaultBookVoice {
            VoqoraLog.info("VoiceBlendSync", "Audiobook voice is no longer available, using a fallback voice")
            bookVM.defaultBookVoice = book
        }
    }
}

extension View {
    func syncsVoiceBlends() -> some View {
        modifier(VoiceBlendSync(store: .shared, engines: .shared))
    }
}

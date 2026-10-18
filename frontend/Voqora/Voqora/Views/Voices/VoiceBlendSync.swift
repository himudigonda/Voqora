import SwiftUI

private struct VoiceBlendSync: ViewModifier {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @ObservedObject var store: VoiceBlendStore

    func body(content: Content) -> some View {
        content
            .task(id: vm.isBackendOnline) {
                if vm.isBackendOnline {
                    await store.refresh()
                }
            }
            .onChange(of: store.revision) { _, _ in reconcile() }
    }

    private func reconcile() {
        let speech = store.resolvedVoice(vm.selectedVoice)
        if speech != vm.selectedVoice {
            VoqoraLog.info("VoiceBlendSync", "Custom speech voice was removed, using its first voice")
            vm.selectedVoice = speech
        }
        let book = store.resolvedVoice(bookVM.defaultBookVoice)
        if book != bookVM.defaultBookVoice {
            VoqoraLog.info("VoiceBlendSync", "Custom audiobook voice was removed, using its first voice")
            bookVM.defaultBookVoice = book
        }
    }
}

extension View {
    func syncsVoiceBlends() -> some View {
        modifier(VoiceBlendSync(store: .shared))
    }
}

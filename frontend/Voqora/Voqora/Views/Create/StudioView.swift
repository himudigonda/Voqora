import SwiftUI

struct StudioView: View {
    @EnvironmentObject var studio: StudioViewModel
    @EnvironmentObject var vm: DashboardViewModel

    var body: some View {
        Group {
            switch TabKey.canonical(vm.selectedTab) {
            case TabKey.createAudiobook:
                NewAudiobookView()
            case TabKey.createPodcast:
                podcastPage
            case TabKey.createScriptEditor:
                if let editor = studio.editor {
                    ScriptEditorView(editor: editor)
                        .id(editor.id)
                } else {
                    ScriptsView(drafts: studio.drafts)
                }
            default:
                ScriptsView(drafts: studio.drafts)
            }
        }
        .task(id: vm.isBackendOnline) {
            if vm.isBackendOnline {
                await studio.loadBlends()
            }
        }
        .onAppear { applyRedirect() }
        .onChange(of: studio.redirect) { _, _ in applyRedirect() }
        .onDisappear { studio.previewer.stop() }
    }

    @ViewBuilder
    private var podcastPage: some View {
        if let model = studio.briefModel {
            NewPodcastView(model: model)
        } else {
            Color.clear.onAppear { studio.ensureBriefModel() }
        }
    }

    private func applyRedirect() {
        guard let key = studio.takeRedirect() else { return }
        if vm.selectedTab != key {
            vm.selectedTab = key
        }
    }
}

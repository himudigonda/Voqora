import AppKit
import SwiftUI

struct PrivacySettingsPage: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var audio: AudioService
    @EnvironmentObject var bookVM: AudiobookViewModel
    @EnvironmentObject var history: HistoryManager
    @EnvironmentObject var identity: IdentityService
    @EnvironmentObject var dictationTranscripts: DictationTranscriptStore
    @EnvironmentObject var inbox: InboxViewModel
    @EnvironmentObject var studio: StudioViewModel
    @Environment(\.voqoraTheme) private var theme

    @State private var identityDraft = IdentityDraft()
    @State private var showEraseConfirmation = false
    @State private var erasingLocalData = false
    @State private var eraseError: String?

    var body: some View {
        SettingsPage(.privacy) {
            analyticsSection
            IdentityFormSection(draft: $identityDraft)
            dataSection
        }
        .alert("Erase all local Voqora data?", isPresented: $showEraseConfirmation) {
            Button("Erase and Quit", role: .destructive) { eraseAllLocalData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This cannot be undone. All local books, sources, audio, history, dictation transcripts, Inbox articles, settings, caches, telemetry outbox, " +
                    "your name and email, anonymous identifier, and AI provider keys will be permanently removed. Voqora " +
                    "will quit after the erase finishes."
            )
        }
    }

    private var analyticsSection: some View {
        SettingsSection(title: "Analytics", footer: AnalyticsOptOut.footer) {
            AnalyticsSettingRow()
        }
    }

    private var dataSection: some View {
        SettingsSection(
            title: "Data",
            footer: "Erasing permanently removes every audiobook and source document, generated audio, history, dictation transcripts, Inbox articles, caches, " +
                "settings, your name and email, telemetry outbox, anonymous identifier, and saved AI provider keys from this Mac. Voqora will quit when complete."
        ) {
            SettingsButtonRow(
                title: "Last Clip",
                detail: audio.canExportLastClip ? "Export the most recently generated audio clip to your Desktop." : "Speak a text selection before exporting a clip.",
                systemImage: "waveform",
                buttonTitle: "Export Last Clip"
            ) {
                vm.exportLastClip()
            }
            .disabled(!audio.canExportLastClip)
            SettingsButtonRow(
                title: "Debug Logs",
                detail: "Save backend usage logs to your Desktop for troubleshooting.",
                systemImage: "doc.text.magnifyingglass",
                buttonTitle: "Export Debug Logs"
            ) {
                vm.exportLogs()
            }
            SettingsRowShell(
                title: "Erase All Local Data",
                detail: "Remove everything Voqora stored on this Mac.",
                systemImage: "trash"
            ) {
                Button(erasingLocalData ? "Erasing…" : "Erase All Local Data…") {
                    showEraseConfirmation = true
                }
                .buttonStyle(.voqoraDangerOutlined)
                .disabled(erasingLocalData || bookVM.deletingAllBooks)
            }
            if let eraseError {
                SettingsNoticeRow(text: eraseError, kind: .danger)
            }
        }
    }

    private func eraseAllLocalData() {
        guard !erasingLocalData else { return }
        eraseError = nil
        erasingLocalData = true
        Task {
            guard await bookVM.deleteAllBooksForErasure() else {
                erasingLocalData = false
                eraseError = "Your audiobook library could not be fully removed. Nothing else was erased. Try again when the local engine is available."
                return
            }

            audio.stop()
            var failures: [String] = []
            do {
                try history.eraseAll()
            } catch {
                failures.append("history")
            }
            do {
                try UsageStatsStore.shared.eraseAll()
            } catch {
                failures.append("stats")
            }
            do {
                try dictationTranscripts.eraseAll()
            } catch {
                failures.append("dictation transcripts")
            }
            do {
                try inbox.eraseAll()
            } catch {
                failures.append("inbox articles")
            }
            do {
                try studio.eraseAllDrafts()
            } catch {
                failures.append("studio scripts")
            }
            for key in KeychainKey.allCases where !KeychainService.delete(key) {
                failures.append("saved credential")
            }
            identity.eraseLocalIdentity()
            await MetricsService.shared.eraseLocalData()

            let fileManager = FileManager.default
            let bundleID = Bundle.main.bundleIdentifier ?? "com.himudigonda.Voqora"
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(bundleID, isDirectory: true)
            let cachesRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let caches = cachesRoot.appendingPathComponent(bundleID, isDirectory: true)
            let installers = cachesRoot.appendingPathComponent("Voqora", isDirectory: true)
            for (name, directory) in [
                ("application support files", appSupport),
                ("cache files", caches),
                ("downloaded installers", installers),
            ] {
                guard fileManager.fileExists(atPath: directory.path) else { continue }
                do {
                    try fileManager.removeItem(at: directory)
                } catch {
                    failures.append(name)
                }
            }

            guard failures.isEmpty else {
                UsageStatsStore.shared.resumeAfterFailedErase()
                erasingLocalData = false
                eraseError = "Some local data could not be removed (\(failures.joined(separator: ", "))). Voqora is still open; retrying this action is safe."
                return
            }
            UserDefaults.standard.removePersistentDomain(forName: bundleID)

            NSApplication.shared.terminate(nil)
        }
    }
}

import AppKit
import FluidAudio
import SwiftUI

struct DictationEngineSettingsSection: View {
    @AppStorage(DictationPreferences.engineKey) private var engine: DictationEngineChoice = .apple
    @AppStorage(DictationPreferences.liveInsertionKey) private var livesInsertion = false
    @AppStorage(DictationPreferences.playsSoundsKey) private var playsSounds = true
    @AppStorage(DictationTrace.defaultsKey) private var savesDebugTraces = false
    @ObservedObject private var models = ParakeetModelStore.shared
    @State private var installedBytes: Int64?
    @State private var removalFailure: String?

    var body: some View {
        Group {
            SettingsSection(title: "Recognition engine", footer: engineFooter) {
                SettingsSegmentedRow(
                    title: "Engine",
                    detail: engine == .apple
                        ? "Apple's speech recognition built into macOS."
                        : "NVIDIA Parakeet, run locally for fast, accurate dictation.",
                    systemImage: "waveform.badge.mic",
                    selection: $engine,
                    options: Array(DictationEngineChoice.allCases),
                    label: { $0.title }
                )
                if engine == .parakeet {
                    parakeetRow
                }
            }
            SettingsSection(
                title: "While you dictate",
                footer: "Tap the shortcut to start and stop. Hold it to talk, and release to insert. Press Esc to cancel."
            ) {
                SettingsSwitchRow(
                    title: "Insert as you speak",
                    detail: "Pastes each finished phrase into your app while you talk. Works with Paste into App and skips Tidy with AI.",
                    systemImage: "text.cursor",
                    isOn: $livesInsertion
                )
                SettingsSwitchRow(
                    title: "Play sounds",
                    detail: "Short cues when dictation starts, stops and inserts, and when speech or an audiobook is ready.",
                    systemImage: "speaker.wave.2",
                    isOn: $playsSounds
                )
            }
            SettingsSection(title: "Troubleshooting") {
                #if !DEBUG
                    SettingsSwitchRow(
                        title: "Save debug traces",
                        detail: "Records timing and word counts for each dictation on this Mac, never your words. Off by default.",
                        systemImage: "ladybug",
                        isOn: $savesDebugTraces
                    )
                #endif
                SettingsButtonRow(
                    title: "Debug Traces",
                    detail: "Open the folder where Voqora keeps the most recent traces.",
                    systemImage: "folder",
                    buttonTitle: "Show Traces in Finder",
                    action: showTracesInFinder
                )
            }
        }
        .onAppear { models.refresh() }
        .task(id: models.state) { installedBytes = await Self.installedByteCount(models.isInstalled) }
    }

    private var engineFooter: String? {
        engine == .parakeet
            ? "Parakeet downloads about 470 MB from Hugging Face once, and then it runs fully on this Mac. Until it is installed, dictation uses Apple."
            : nil
    }

    @ViewBuilder
    private var parakeetRow: some View {
        switch models.state {
        case .notInstalled:
            SettingsButtonRow(
                title: "Parakeet Model",
                detail: "Not installed. About 470 MB, downloaded once from Hugging Face.",
                systemImage: "arrow.down.circle",
                buttonTitle: "Download",
                action: download
            )
        case let .downloading(fraction):
            SettingsRowShell(
                title: "Parakeet Model",
                detail: fraction.map { "Downloading… \(Int($0 * 100))%" } ?? "Downloading…",
                systemImage: "arrow.down.circle"
            ) {
                if let fraction {
                    ProgressView(value: fraction).frame(width: 120)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        case .installed:
            SettingsButtonRow(
                title: "Parakeet Model",
                detail: installedDetail,
                systemImage: "checkmark.circle",
                buttonTitle: "Remove",
                action: remove
            )
        case let .failed(message):
            SettingsButtonRow(
                title: "Parakeet Model",
                detail: "Download failed. \(message)",
                systemImage: "exclamationmark.triangle",
                buttonTitle: "Download",
                action: download
            )
        }
    }

    private var installedDetail: String {
        if let removalFailure {
            return removalFailure
        }
        guard let installedBytes else { return "Installed. Runs fully on this Mac." }
        let size = ByteCountFormatter.string(fromByteCount: installedBytes, countStyle: .file)
        return "Installed, \(size). Runs fully on this Mac."
    }

    private func download() {
        removalFailure = nil
        Task { await models.download() }
    }

    private func remove() {
        do {
            try models.remove()
            removalFailure = nil
        } catch {
            removalFailure = "Couldn't remove the model. \(error.localizedDescription)"
        }
    }

    private func showTracesInFinder() {
        let directory = DictationTraceWriter.defaultDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    private static func installedByteCount(_ isInstalled: Bool) async -> Int64? {
        guard isInstalled else { return nil }
        return await Task.detached {
            let directory = AsrModels.defaultCacheDirectory(for: .v3)
            let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            var total: Int64 = 0
            while let url = files?.nextObject() as? URL {
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
            return total > 0 ? total : nil
        }.value
    }
}

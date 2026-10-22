import AVFoundation
import Combine
import Foundation
import UniformTypeIdentifiers

nonisolated struct MingDesignDraft: Equatable, Sendable {
    var name = ""
    var language = "en"
    var description = ""
    var sampleText = ""

    var isValid: Bool {
        !MingVoiceText.trimmed(name).isEmpty && !MingVoiceText.trimmed(description).isEmpty
    }

    var request: MingVoiceDesignRequest {
        let sample = MingVoiceText.trimmed(sampleText)
        return MingVoiceDesignRequest(
            name: MingVoiceText.trimmed(name),
            description: MingVoiceText.trimmed(description),
            language: language,
            sampleText: sample.isEmpty ? nil : sample
        )
    }
}

nonisolated struct MingCloneDraft: Equatable, Sendable {
    var name = ""
    var language = "en"
    var transcript = ""
    var fileURL: URL?
    var hasRights = false

    var isValid: Bool {
        !MingVoiceText.trimmed(name).isEmpty && !MingVoiceText.trimmed(transcript).isEmpty && fileURL != nil && hasRights
    }
}

nonisolated enum MingVoiceText {
    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

nonisolated enum MingVoiceAudio {
    static let maximumBytes = 25 * 1024 * 1024
    static let extensions = ["wav", "flac", "aiff", "aif", "mp3"]

    static var importTypes: [UTType] {
        extensions.compactMap { UTType(filenameExtension: $0) }
    }

    static func mimeType(forExtension fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "wav": "audio/wav"
        case "flac": "audio/flac"
        case "aiff", "aif": "audio/aiff"
        case "mp3": "audio/mpeg"
        default: "application/octet-stream"
        }
    }
}

nonisolated enum MingVoiceLanguage {
    static let fallback = ["en", "zh", "ja", "ko", "de", "fr", "es"]

    static func options(from engine: SpeechEngine?) -> [String] {
        let declared = engine?.languages ?? []
        return declared.isEmpty ? fallback : declared
    }

    static func label(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code
    }
}

@MainActor
final class MingVoiceStudioModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    enum Work: Equatable {
        case designing
        case cloning
    }

    @Published var designDraft = MingDesignDraft()
    @Published var cloneDraft = MingCloneDraft()
    @Published private(set) var work: Work?
    @Published private(set) var deletingID: String?
    @Published private(set) var loadingSampleID: String?
    @Published private(set) var playingID: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastCreated: SpeechEngineVoice?
    @Published private(set) var recordingDuration: TimeInterval?

    static let recordingPreviewID = "recording-preview"

    private let service: any MingVoiceServing
    private let engines: SpeechEngineStore
    private var player: AVAudioPlayer?
    private var sampleTask: Task<Void, Never>?

    init(service: (any MingVoiceServing)? = nil, engines: SpeechEngineStore? = nil) {
        self.service = service ?? MingVoiceService()
        self.engines = engines ?? .shared
        super.init()
    }

    var customVoices: [SpeechEngineVoice] {
        engines.mingVoices.filter(\.custom)
    }

    var isWorking: Bool {
        work != nil
    }

    var isPlayingRecording: Bool {
        playingID == Self.recordingPreviewID || loadingSampleID == Self.recordingPreviewID
    }

    func clearResult() {
        stopSample()
        lastCreated = nil
        errorMessage = nil
    }

    func chooseRecording(_ url: URL) {
        stopSample()
        cloneDraft.fileURL = url
        recordingDuration = nil
        Task { [weak self] in
            let duration = await Self.duration(of: url)
            guard let self, cloneDraft.fileURL == url else { return }
            recordingDuration = duration
        }
    }

    func toggleRecordingPreview() {
        guard let url = cloneDraft.fileURL else { return }
        if isPlayingRecording {
            stopSample()
            return
        }
        stopSample()
        errorMessage = nil
        loadingSampleID = Self.recordingPreviewID
        sampleTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await Self.readAudio(at: url)
                guard !Task.isCancelled, loadingSampleID == Self.recordingPreviewID else { return }
                try startPlayback(data, id: Self.recordingPreviewID)
                loadingSampleID = nil
            } catch {
                guard !Task.isCancelled else { return }
                loadingSampleID = nil
                report(error, label: "Ming recording preview failed")
            }
        }
    }

    func submitDesign() async {
        guard !isWorking, designDraft.isValid else { return }
        errorMessage = nil
        lastCreated = nil
        work = .designing
        defer { work = nil }
        do {
            let voice = try await service.design(designDraft.request)
            designDraft = MingDesignDraft(language: designDraft.language)
            await engines.refresh()
            lastCreated = voice
        } catch {
            report(error, label: "Ming voice design failed")
        }
    }

    func submitClone() async {
        guard !isWorking, cloneDraft.isValid, let fileURL = cloneDraft.fileURL else { return }
        errorMessage = nil
        lastCreated = nil
        work = .cloning
        defer { work = nil }
        do {
            let audio = try await Self.readAudio(at: fileURL)
            let request = MingVoiceCloneRequest(
                name: MingVoiceText.trimmed(cloneDraft.name),
                language: cloneDraft.language,
                transcript: MingVoiceText.trimmed(cloneDraft.transcript),
                filename: fileURL.lastPathComponent,
                mimeType: MingVoiceAudio.mimeType(forExtension: fileURL.pathExtension),
                audio: audio
            )
            let voice = try await service.clone(request)
            cloneDraft = MingCloneDraft(language: cloneDraft.language)
            recordingDuration = nil
            await engines.refresh()
            lastCreated = voice
        } catch {
            report(error, label: "Ming voice clone failed")
        }
    }

    func delete(_ voice: SpeechEngineVoice) async {
        guard deletingID == nil else { return }
        errorMessage = nil
        deletingID = voice.id
        defer { deletingID = nil }
        if playingID == voice.id || loadingSampleID == voice.id {
            stopSample()
        }
        do {
            try await service.delete(id: voice.id)
            await engines.refresh()
        } catch {
            report(error, label: "Ming voice removal failed")
        }
    }

    func toggleSample(_ voice: SpeechEngineVoice) {
        if playingID == voice.id || loadingSampleID == voice.id {
            stopSample()
            return
        }
        stopSample()
        errorMessage = nil
        loadingSampleID = voice.id
        sampleTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await service.sample(id: voice.id)
                guard !Task.isCancelled, loadingSampleID == voice.id else { return }
                try startPlayback(data, id: voice.id)
                loadingSampleID = nil
            } catch {
                guard !Task.isCancelled else { return }
                loadingSampleID = nil
                report(error, label: "Ming voice sample failed")
            }
        }
    }

    func stopSample() {
        sampleTask?.cancel()
        sampleTask = nil
        loadingSampleID = nil
        player?.stop()
        player = nil
        playingID = nil
    }

    func dismissError() {
        errorMessage = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ finished: AVAudioPlayer, successfully _: Bool) {
        let finishedID = ObjectIdentifier(finished)
        Task { @MainActor in
            guard let player = self.player, ObjectIdentifier(player) == finishedID else { return }
            self.player = nil
            self.playingID = nil
        }
    }

    private func startPlayback(_ data: Data, id: String) throws {
        let newPlayer = try AVAudioPlayer(data: data)
        newPlayer.delegate = self
        newPlayer.prepareToPlay()
        newPlayer.play()
        player = newPlayer
        playingID = id
    }

    private func report(_ error: Error, label: String) {
        if error is CancellationError {
            return
        }
        VoqoraLog.warn("MingVoiceStudioModel", label, ["status": BackendAPIError.logLabel(for: error)])
        errorMessage = error.localizedDescription
    }

    private nonisolated static func duration(of url: URL) async -> TimeInterval? {
        guard let data = try? await readAudio(at: url), let player = try? AVAudioPlayer(data: data) else { return nil }
        return player.duration
    }

    private nonisolated static func readAudio(at url: URL) async throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= MingVoiceAudio.maximumBytes else {
            throw BackendAPIError.rejected(statusCode: 413, message: "Choose an audio clip up to 25 MB.")
        }
        return try Data(contentsOf: url)
    }
}

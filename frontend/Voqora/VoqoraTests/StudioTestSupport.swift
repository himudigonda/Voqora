import Foundation
@testable import Voqora
import XCTest

@MainActor
final class StudioFakePodcastService: PodcastServing {
    var scriptResult: Result<PodcastScriptResult, Error> = .failure(PodcastServiceError.unexpected)
    var renderResult: Result<PodcastRenderReceipt, Error> = .failure(PodcastServiceError.unexpected)
    var storedScript: Result<PodcastScript, Error> = .failure(PodcastServiceError.notFound("Podcast not found."))
    var blends: [PodcastVoiceBlend] = []
    var holdsScript = false
    private(set) var writeRequests: [PodcastScriptRequest] = []
    private(set) var credentials: [LLMCredential] = []
    private(set) var renderedScripts: [PodcastScript] = []
    private(set) var requestedScriptIDs: [String] = []

    func writeScript(_ request: PodcastScriptRequest, credential: LLMCredential) async throws -> PodcastScriptResult {
        writeRequests.append(request)
        credentials.append(credential)
        while holdsScript {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        return try scriptResult.get()
    }

    func render(_ script: PodcastScript) async throws -> PodcastRenderReceipt {
        renderedScripts.append(script)
        return try renderResult.get()
    }

    func script(forPodcast bookID: String) async throws -> PodcastScript {
        requestedScriptIDs.append(bookID)
        return try storedScript.get()
    }

    func voiceBlends() async throws -> [PodcastVoiceBlend] {
        blends
    }

    func previewAudio(text _: String, voice _: String) async throws -> Data {
        Data()
    }
}

@MainActor
final class StudioLibrarySpy {
    private(set) var refreshCount = 0
    private(set) var tracked: [String] = []
    private(set) var announcements: [String] = []

    var hooks: StudioLibraryHooks {
        StudioLibraryHooks(
            refresh: { [weak self] in self?.refreshCount += 1 },
            track: { [weak self] in self?.tracked.append($0) },
            announce: { [weak self] in self?.announcements.append($0) }
        )
    }
}

@MainActor
enum StudioFixtures {
    static func script(turns: Int = 2) -> PodcastScript {
        let speakers = [
            PodcastSpeaker(id: "host_1", name: "Avery", voice: "af_bella"),
            PodcastSpeaker(id: "host_2", name: "Jordan", voice: "am_adam"),
        ]
        return PodcastScript(
            title: "Night Sky",
            speakers: speakers,
            turns: (0 ..< turns).map { index in
                PodcastTurn(speakerID: speakers[index % 2].id, text: "Line \(index + 1).")
            }
        )
    }

    static func receipt(bookID: String = String(repeating: "a", count: 32)) -> PodcastRenderReceipt {
        PodcastRenderReceipt(
            status: "queued",
            bookID: bookID,
            kind: "podcast",
            title: "Night Sky",
            turnCount: 2,
            speakers: script().speakers,
            estimatedAudioSeconds: 12
        )
    }

    static func result(script: PodcastScript? = nil, truncated: Bool = false) -> PodcastScriptResult {
        PodcastScriptResult(
            script: script ?? Self.script(),
            usedNotes: false,
            repaired: false,
            sourceTruncated: truncated,
            estimatedAudioSeconds: 30,
            llmProvider: "ollama",
            llmModel: "llama3"
        )
    }

    static func temporaryURL(_ name: String = "studio-drafts.json") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("VoqoraStudioTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
    }

    static func providers(connected: Bool) -> LLMProviderStore {
        let suite = "VoqoraStudioTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let store = LLMProviderStore(
            defaults: defaults,
            secrets: SecretStore(get: { _ in nil }, set: { _, _ in true }, delete: { _ in true }),
            verifier: { _ in LLMVerification(verified: true, models: [], error: nil) }
        )
        if connected {
            store.save(LLMCredential(provider: .ollama, apiKey: "", model: "llama3", serverURL: "http://localhost:11434/v1"))
        }
        return store
    }

    static func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}

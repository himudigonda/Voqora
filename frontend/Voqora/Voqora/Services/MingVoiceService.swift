import Foundation

nonisolated struct MingVoiceDesignRequest: Encodable, Equatable, Sendable {
    let name: String
    let description: String
    let language: String
    let sampleText: String?

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case language
        case sampleText = "sample_text"
    }
}

nonisolated struct MingVoiceCloneRequest: Equatable, Sendable {
    let name: String
    let language: String
    let transcript: String
    let filename: String
    let mimeType: String
    let audio: Data
}

nonisolated struct MingVoiceReceipt: Decodable, Sendable {
    let voice: SpeechEngineVoice

    private enum CodingKeys: String, CodingKey {
        case voice
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let nested = try? container.decode(SpeechEngineVoice.self, forKey: .voice) {
            voice = nested
        } else {
            voice = try SpeechEngineVoice(from: decoder)
        }
    }
}

protocol MingVoiceServing {
    func design(_ request: MingVoiceDesignRequest) async throws -> SpeechEngineVoice
    func clone(_ request: MingVoiceCloneRequest) async throws -> SpeechEngineVoice
    func delete(id: String) async throws
    func sample(id: String) async throws -> Data
}

final class MingVoiceService: MingVoiceServing {
    private let client: BackendAPIClient

    init(client: BackendAPIClient? = nil) {
        self.client = client ?? BackendAPIClient()
    }

    func design(_ request: MingVoiceDesignRequest) async throws -> SpeechEngineVoice {
        try await client.send(
            MingVoiceReceipt.self,
            path: "\(Self.voicesPath)/design",
            method: "POST",
            body: request,
            timeout: Self.designTimeout
        ).voice
    }

    func clone(_ request: MingVoiceCloneRequest) async throws -> SpeechEngineVoice {
        let form = MultipartForm()
            .appending(field: "name", value: request.name)
            .appending(field: "language", value: request.language)
            .appending(field: "transcript", value: request.transcript)
            .appending(file: "file", filename: request.filename, mimeType: request.mimeType, data: request.audio)
            .finished()
        return try await client.sendMultipart(
            MingVoiceReceipt.self,
            path: "\(Self.voicesPath)/clone",
            form: form,
            timeout: Self.designTimeout
        ).voice
    }

    func delete(id: String) async throws {
        try await client.delete(path: Self.path(forVoice: id))
    }

    func sample(id: String) async throws -> Data {
        try await client.getData(path: Self.path(forVoice: id, action: "sample"), accept: "audio/wav", timeout: Self.designTimeout)
    }

    nonisolated static let designTimeout: TimeInterval = 180

    static let voicesPath = "engine/\(SpeechEngineID.ming)/voices"

    static func path(forVoice id: String, action: String? = nil) -> String {
        [voicesPath, id, action].compactMap(\.self).joined(separator: "/")
    }
}

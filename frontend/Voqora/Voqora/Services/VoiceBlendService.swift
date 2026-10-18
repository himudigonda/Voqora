import Foundation

protocol VoiceBlendServing {
    func list() async throws -> VoiceBlendList
    func create(_ request: VoiceBlendRequest) async throws -> VoiceBlend
    func update(id: String, with request: VoiceBlendRequest) async throws -> VoiceBlend
    func delete(id: String) async throws
}

final class VoiceBlendService: VoiceBlendServing {
    private let client: BackendAPIClient

    init(client: BackendAPIClient? = nil) {
        self.client = client ?? BackendAPIClient()
    }

    func list() async throws -> VoiceBlendList {
        try await client.get(VoiceBlendList.self, path: "voices/blends")
    }

    func create(_ request: VoiceBlendRequest) async throws -> VoiceBlend {
        try await client.send(VoiceBlend.self, path: "voices/blends", method: "POST", body: request)
    }

    func update(id: String, with request: VoiceBlendRequest) async throws -> VoiceBlend {
        let path = try Self.path(for: id)
        return try await client.send(VoiceBlend.self, path: path, method: "PUT", body: request)
    }

    func delete(id: String) async throws {
        let path = try Self.path(for: id)
        try await client.delete(path: path)
    }

    static func path(for id: String) throws -> String {
        guard VoiceBlendRules.isBlendID(id) else {
            throw BackendAPIError.rejected(statusCode: 400, message: "That custom voice can't be found.")
        }
        return "voices/blends/\(id)"
    }
}

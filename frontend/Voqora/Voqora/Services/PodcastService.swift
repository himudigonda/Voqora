import Foundation

nonisolated enum PodcastServiceError: LocalizedError, Equatable {
    case engineUnavailable
    case providerSetup(String)
    case notFound(String)
    case tooLarge(String)
    case invalid(String)
    case busy(String)
    case scriptFailed(String)
    case providerUnavailable(String)
    case rejected(String)
    case unexpected
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .engineUnavailable:
            "Voqora's engine isn't running. Try again in a moment."
        case let .providerSetup(message), let .notFound(message), let .tooLarge(message),
             let .invalid(message), let .busy(message), let .scriptFailed(message),
             let .providerUnavailable(message), let .rejected(message):
            message
        case .unexpected:
            "Something went wrong. Try again."
        case .invalidResponse:
            "Voqora received an unexpected response. Try again."
        }
    }

    var logLabel: String {
        switch self {
        case .engineUnavailable: "engine_unavailable"
        case .providerSetup: "provider_setup"
        case .notFound: "not_found"
        case .tooLarge: "too_large"
        case .invalid: "invalid"
        case .busy: "busy"
        case .scriptFailed: "script_failed"
        case .providerUnavailable: "provider_unavailable"
        case .rejected: "rejected"
        case .unexpected: "unexpected"
        case .invalidResponse: "invalid_response"
        }
    }

    static func logLabel(for error: Error) -> String {
        (error as? PodcastServiceError)?.logLabel ?? "unknown"
    }

    static func from(statusCode: Int, data: Data) -> PodcastServiceError {
        let detail = PodcastErrorDetail.message(from: data)
        switch statusCode {
        case 400: return .providerSetup(detail ?? "Check your AI provider in Preferences and try again.")
        case 404: return .notFound(detail ?? "That item no longer exists. Refresh and try again.")
        case 409: return .rejected(detail ?? "Voqora couldn't start this podcast. Try again.")
        case 413: return .tooLarge(detail ?? "This podcast is too large for Voqora to make.")
        case 422: return .invalid(detail ?? "Check the script details and try again.")
        case 429: return .busy(detail ?? "Voqora is already writing podcast scripts. Try again shortly.")
        case 500: return detail.map(PodcastServiceError.rejected) ?? .unexpected
        case 502: return .scriptFailed(detail ?? "The AI provider did not return a usable script. Try again or choose another model.")
        case 503: return .providerUnavailable(detail ?? "The AI provider is temporarily unavailable. Try again later.")
        default: return .unexpected
        }
    }
}

nonisolated enum PodcastErrorDetail {
    static func message(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let detail = object["detail"] as? String {
            return sentence(detail)
        }
        if let items = object["detail"] as? [[String: Any]], let first = items.first?["msg"] as? String {
            return sentence(first)
        }
        return nil
    }

    static func sentence(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Value error, ", "Assertion failed, "] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        guard let first = text.first else { return nil }
        text = first.uppercased() + text.dropFirst()
        if let last = text.last, !".!?".contains(last) {
            text += "."
        }
        return text
    }
}

protocol PodcastServing: AnyObject {
    func writeScript(_ request: PodcastScriptRequest, credential: LLMCredential) async throws -> PodcastScriptResult
    func render(_ script: PodcastScript) async throws -> PodcastRenderReceipt
    func script(forPodcast bookID: String) async throws -> PodcastScript
    func voiceBlends() async throws -> [PodcastVoiceBlend]
    func previewAudio(text: String, voice: String) async throws -> Data
}

final class PodcastService: PodcastServing {
    nonisolated static let scriptTimeout: TimeInterval = 900
    nonisolated static let requestTimeout: TimeInterval = 30
    nonisolated static let previewTimeout: TimeInterval = 60

    private let connection: BackendConnection
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(connection: BackendConnection? = nil, session: URLSession? = nil) {
        self.connection = connection ?? .shared
        self.session = session ?? .shared
    }

    func writeScript(_ request: PodcastScriptRequest, credential: LLMCredential) async throws -> PodcastScriptResult {
        var urlRequest = try jsonRequest(path: "podcast/script", method: "POST", body: request, timeout: Self.scriptTimeout)
        credential.apply(to: &urlRequest)
        return try await decode(PodcastScriptResult.self, from: perform(urlRequest))
    }

    func render(_ script: PodcastScript) async throws -> PodcastRenderReceipt {
        let request = try jsonRequest(
            path: "podcast/render",
            method: "POST",
            body: PodcastRenderRequest(script: script),
            timeout: Self.requestTimeout
        )
        return try await decode(PodcastRenderReceipt.self, from: perform(request))
    }

    func script(forPodcast bookID: String) async throws -> PodcastScript {
        let request = try makeRequest(path: "podcast/\(bookID)/script", method: "GET", timeout: Self.requestTimeout)
        return try await decode(PodcastScript.self, from: perform(request))
    }

    func voiceBlends() async throws -> [PodcastVoiceBlend] {
        let request = try makeRequest(path: "voices/blends", method: "GET", timeout: Self.requestTimeout)
        return try await decode(PodcastVoiceBlendList.self, from: perform(request)).blends
    }

    func previewAudio(text: String, voice: String) async throws -> Data {
        var request = try jsonRequest(
            path: "speak",
            method: "POST",
            body: PodcastSpeechPreviewRequest(text: text, voice: voice),
            timeout: Self.previewTimeout
        )
        request.setValue("audio/wav", forHTTPHeaderField: "Accept")
        let data = try await perform(request)
        guard let wav = PodcastPreviewAudio.finalizedWAV(data) else {
            throw PodcastServiceError.invalidResponse
        }
        return wav
    }

    private func makeRequest(path: String, method: String, timeout: TimeInterval) throws -> URLRequest {
        do {
            var request = try connection.request(path: path, method: method, timeout: timeout)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            return request
        } catch {
            throw PodcastServiceError.engineUnavailable
        }
    }

    private func jsonRequest(path: String, method: String, body: some Encodable, timeout: TimeInterval) throws -> URLRequest {
        var request = try makeRequest(path: path, method: method, timeout: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw PodcastServiceError.engineUnavailable
        }
        let (data, response) = result
        guard let http = response as? HTTPURLResponse else {
            throw PodcastServiceError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw PodcastServiceError.from(statusCode: http.statusCode, data: data)
        }
        return data
    }

    private func decode<Response: Decodable>(_ type: Response.Type, from data: Data) throws -> Response {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw PodcastServiceError.invalidResponse
        }
    }
}

nonisolated enum PodcastPreviewAudio {
    static let headerLength = 44

    static func finalizedWAV(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > headerLength,
              bytes[0 ..< 4].elementsEqual("RIFF".utf8),
              bytes[8 ..< 12].elementsEqual("WAVE".utf8),
              bytes[36 ..< 40].elementsEqual("data".utf8)
        else { return nil }
        var fixed = bytes
        write(UInt32(bytes.count - 8), into: &fixed, at: 4)
        write(UInt32(bytes.count - headerLength), into: &fixed, at: 40)
        return Data(fixed)
    }

    private static func write(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        for index in 0 ..< 4 {
            bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(index)))
        }
    }
}

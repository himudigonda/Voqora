import Foundation

enum BackendAPIError: LocalizedError, Equatable {
    case engineUnavailable
    case unreachable
    case rejected(statusCode: Int, message: String?)
    case invalidResponse

    var statusCode: Int? {
        if case let .rejected(statusCode, _) = self {
            return statusCode
        }
        return nil
    }

    var logLabel: String {
        switch self {
        case .engineUnavailable: "engine_unavailable"
        case .unreachable: "unreachable"
        case let .rejected(statusCode, _): "\(statusCode)"
        case .invalidResponse: "invalid_response"
        }
    }

    static func logLabel(for error: Error) -> String {
        (error as? BackendAPIError)?.logLabel ?? "unknown"
    }

    var errorDescription: String? {
        switch self {
        case .engineUnavailable:
            "Voqora's engine isn't running. Try again in a moment."
        case .unreachable:
            "Voqora couldn't reach its local engine. Try again."
        case let .rejected(statusCode, message):
            message ?? Self.genericMessage(for: statusCode)
        case .invalidResponse:
            "Voqora received an unexpected response. Try again."
        }
    }

    private static func genericMessage(for statusCode: Int) -> String {
        switch statusCode {
        case 404: "That item no longer exists. Refresh and try again."
        case 409: "That conflicts with something you already saved."
        case 422: "Check the values you entered and try again."
        case 503: "Voqora's engine is still starting. Try again in a moment."
        default: "Something went wrong. Try again."
        }
    }
}

nonisolated enum BackendErrorDetail {
    static func message(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let detail = object["detail"] as? String {
            return sentence(detail)
        }
        if let items = object["detail"] as? [[String: Any]],
           let first = items.first?["msg"] as? String
        {
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

final class BackendAPIClient {
    private let connection: BackendConnection
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(connection: BackendConnection? = nil, session: URLSession? = nil) {
        self.connection = connection ?? .shared
        self.session = session ?? .shared
    }

    func get<Response: Decodable>(
        _ type: Response.Type,
        path: String,
        query: [URLQueryItem] = [],
        timeout: TimeInterval = 15
    ) async throws -> Response {
        let request = try makeRequest(path: path, method: "GET", query: query, timeout: timeout)
        return try await decode(type, from: perform(request))
    }

    func send<Response: Decodable>(
        _ type: Response.Type,
        path: String,
        method: String,
        body: some Encodable,
        timeout: TimeInterval = 15
    ) async throws -> Response {
        var request = try makeRequest(path: path, method: method, query: [], timeout: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        return try await decode(type, from: perform(request))
    }

    func delete(path: String, timeout: TimeInterval = 15) async throws {
        let request = try makeRequest(path: path, method: "DELETE", query: [], timeout: timeout)
        _ = try await perform(request)
    }

    private func makeRequest(
        path: String,
        method: String,
        query: [URLQueryItem],
        timeout: TimeInterval
    ) throws -> URLRequest {
        var request: URLRequest
        do {
            request = try connection.request(path: path, method: method, timeout: timeout)
        } catch {
            throw BackendAPIError.engineUnavailable
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !query.isEmpty, let url = request.url,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        {
            components.queryItems = query
            request.url = components.url
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw BackendAPIError.unreachable
        }
        let (data, response) = result
        guard let http = response as? HTTPURLResponse else {
            throw BackendAPIError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw BackendAPIError.rejected(statusCode: http.statusCode, message: BackendErrorDetail.message(from: data))
        }
        return data
    }

    private func decode<Response: Decodable>(_ type: Response.Type, from data: Data) throws -> Response {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw BackendAPIError.invalidResponse
        }
    }
}

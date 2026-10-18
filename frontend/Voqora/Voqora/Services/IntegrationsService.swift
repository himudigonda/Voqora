import Foundation

@MainActor
protocol LocalAPIBackend: AnyObject {
    func status() async throws -> LocalAPIStatus
    func apply(_ configuration: LocalAPIConfiguration) async throws -> LocalAPIStatus
    func events() -> AsyncThrowingStream<IntegrationEvent, Error>
}

nonisolated enum IntegrationsServiceError: LocalizedError, Equatable {
    case engineUnavailable
    case rejectedSettings
    case unexpectedResponse(Int)
    case eventStreamRejected(Int)

    var errorDescription: String? {
        switch self {
        case .engineUnavailable: "Voqora's engine isn't running yet. Try again in a moment."
        case .rejectedSettings: "Voqora's engine rejected those local API settings. Check the port and regenerate the key."
        case .unexpectedResponse: "Voqora's engine returned an unexpected response. Try again."
        case .eventStreamRejected: "Voqora could not listen for speech requests."
        }
    }

    var failureCode: String {
        switch self {
        case .engineUnavailable: "local_api_engine_unavailable"
        case .rejectedSettings: "local_api_settings_rejected"
        case .unexpectedResponse: "local_api_unexpected_response"
        case .eventStreamRejected: "local_api_events_rejected"
        }
    }
}

final class IntegrationsService: LocalAPIBackend {
    static let settingsPath = "integrations/local-api"
    static let eventsPath = "integrations/events"
    static let eventStreamIdleTimeout: TimeInterval = 45

    private let connection: BackendConnection
    private let session: URLSession

    init(connection: BackendConnection? = nil, session: URLSession = .shared) {
        self.connection = connection ?? .shared
        self.session = session
    }

    func status() async throws -> LocalAPIStatus {
        let request = try makeRequest(path: Self.settingsPath, method: "GET", timeout: 10)
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw IntegrationsServiceError.unexpectedResponse(response.statusCode)
        }
        return try decodeStatus(data, statusCode: response.statusCode)
    }

    func apply(_ configuration: LocalAPIConfiguration) async throws -> LocalAPIStatus {
        var request = try makeRequest(path: Self.settingsPath, method: "POST", timeout: 20)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(configuration)
        let (data, response) = try await send(request)
        switch response.statusCode {
        case 200, 409:
            return try decodeStatus(data, statusCode: response.statusCode)
        case 422:
            throw IntegrationsServiceError.rejectedSettings
        default:
            throw IntegrationsServiceError.unexpectedResponse(response.statusCode)
        }
    }

    func events() -> AsyncThrowingStream<IntegrationEvent, Error> {
        let request: URLRequest
        do {
            var built = try makeRequest(path: Self.eventsPath, method: "GET", timeout: Self.eventStreamIdleTimeout)
            built.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request = built
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        let session = session
        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard statusCode == 200 else {
                        throw IntegrationsServiceError.eventStreamRejected(statusCode)
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if let event = IntegrationEventParser.event(fromLine: line) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeRequest(path: String, method: String, timeout: TimeInterval) throws -> URLRequest {
        do {
            return try connection.request(path: path, method: method, timeout: timeout)
        } catch {
            throw IntegrationsServiceError.engineUnavailable
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            throw IntegrationsServiceError.engineUnavailable
        }
        guard let http = result.1 as? HTTPURLResponse else {
            throw IntegrationsServiceError.unexpectedResponse(0)
        }
        return (result.0, http)
    }

    private func decodeStatus(_ data: Data, statusCode: Int) throws -> LocalAPIStatus {
        do {
            return try JSONDecoder().decode(LocalAPIStatus.self, from: data)
        } catch {
            throw IntegrationsServiceError.unexpectedResponse(statusCode)
        }
    }
}

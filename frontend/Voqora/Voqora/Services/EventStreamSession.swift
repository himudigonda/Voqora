import Foundation

nonisolated enum EventStreamSession {
    static let maximumStreamsPerHost = 16

    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = EventStreamSession.maximumStreamsPerHost
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
}

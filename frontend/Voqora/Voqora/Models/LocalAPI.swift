import Foundation
import Security

nonisolated enum LocalAPIPort {
    static let defaultValue = 51851
    static let range = 1024 ... 65535
    static let invalidMessage = "Enter a port from 1024 to 65535."

    static func parse(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 5,
              trimmed.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) && $0.isASCII }),
              let value = Int(trimmed), range.contains(value)
        else { return nil }
        return value
    }
}

nonisolated enum LocalAPIKey {
    static let prefix = "vq_"
    static let randomByteCount = 32
    static let lengthRange = 32 ... 128
    private static let allowedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~+/=-")

    static func generate() -> String? {
        var bytes = [UInt8](repeating: 0, count: randomByteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return encode(bytes)
    }

    static func encode(_ bytes: [UInt8]) -> String {
        let base64URL = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return prefix + base64URL
    }

    static func isValid(_ key: String) -> Bool {
        lengthRange.contains(key.count) && key.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
    }

    static func masked(_ key: String) -> String {
        guard key.count > 8 else { return String(repeating: "•", count: key.count) }
        return "\(key.prefix(prefix.count))\(String(repeating: "•", count: 12))\(key.suffix(4))"
    }
}

nonisolated struct LocalAPIConfiguration: Encodable, Equatable, Sendable {
    let enabled: Bool
    let port: Int?
    let apiKey: String?

    static let disabled = LocalAPIConfiguration(enabled: false, port: nil, apiKey: nil)

    static func enabled(port: Int, apiKey: String) -> LocalAPIConfiguration {
        LocalAPIConfiguration(enabled: true, port: port, apiKey: apiKey)
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case port
        case apiKey = "api_key"
    }
}

nonisolated enum LocalAPIFailure: String, Sendable {
    case portInUse = "port_in_use"
    case permissionDenied = "permission_denied"
    case bindFailed = "bind_failed"
    case startFailed = "start_failed"
    case startTimeout = "start_timeout"
    case stopped

    func message(port: Int) -> String {
        switch self {
        case .portInUse: "Port \(port) is already in use by another app. Choose a different port."
        case .permissionDenied: "macOS did not let Voqora use port \(port). Choose a different port."
        case .bindFailed: "Voqora could not open port \(port). Choose a different port."
        case .startFailed: "The local API could not start. Turn it off and on again."
        case .startTimeout: "The local API took too long to start. Turn it off and on again."
        case .stopped: "The local API stopped unexpectedly. Turn it off and on again."
        }
    }
}

nonisolated struct LocalAPIStatus: Decodable, Equatable, Sendable {
    let enabled: Bool
    let port: Int?
    let running: Bool
    let errorCode: String?

    var failure: LocalAPIFailure? {
        errorCode.flatMap(LocalAPIFailure.init(rawValue:))
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case port
        case running
        case errorCode = "error_code"
    }
}

nonisolated enum LocalAPIPhase: Equatable, Sendable {
    case off
    case waitingForEngine
    case starting
    case running(port: Int)
    case failed(String)

    static let genericFailure = "The local API is not responding. Turn it off and on again."

    init(status: LocalAPIStatus, requestedPort: Int) {
        let port = status.port ?? requestedPort
        if let failure = status.failure {
            self = .failed(failure.message(port: port))
        } else if status.errorCode != nil {
            self = .failed(Self.genericFailure)
        } else if status.running {
            self = .running(port: port)
        } else if status.enabled {
            self = .failed(Self.genericFailure)
        } else {
            self = .off
        }
    }

    var statusLine: String {
        switch self {
        case .off: "Off"
        case .waitingForEngine: "Waiting for Voqora's engine to start."
        case .starting: "Starting…"
        case let .running(port): "Listening on 127.0.0.1:\(port). Only apps on this Mac can connect."
        case let .failed(message): message
        }
    }

    var isRunning: Bool {
        if case .running = self {
            return true
        }
        return false
    }

    var isFailure: Bool {
        if case .failed = self {
            return true
        }
        return false
    }
}

nonisolated enum LocalAPISnippets {
    static let sampleText = "Hello from Voqora."

    static func baseURL(port: Int) -> String {
        "http://127.0.0.1:\(port)"
    }

    static func speechCurl(port: Int, key: String) -> String {
        """
        curl \(baseURL(port: port))/v1/audio/speech \\
          -H "Authorization: Bearer \(key)" \\
          -H "Content-Type: application/json" \\
          -d '{"model": "tts-1", "voice": "alloy", "input": "\(sampleText)"}' \\
          --output speech.wav
        """
    }

    static func claudeCode(port: Int, key: String) -> String {
        "claude mcp add --transport http voqora \(baseURL(port: port))/mcp --header \"Authorization: Bearer \(key)\""
    }

    static func mcpServersJSON(port: Int, key: String) -> String {
        """
        {
          "mcpServers": {
            "voqora": {
              "type": "http",
              "url": "\(baseURL(port: port))/mcp",
              "headers": {
                "Authorization": "Bearer \(key)"
              }
            }
          }
        }
        """
    }
}

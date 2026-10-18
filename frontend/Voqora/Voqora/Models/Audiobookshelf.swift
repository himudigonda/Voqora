import Foundation

nonisolated struct AudiobookshelfFolder: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let fullPath: String?

    var displayName: String {
        guard let fullPath, !fullPath.isEmpty else { return id }
        return fullPath
    }
}

nonisolated struct AudiobookshelfLibrary: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let mediaType: String?
    let folders: [AudiobookshelfFolder]

    init(id: String, name: String, mediaType: String?, folders: [AudiobookshelfFolder]) {
        self.id = id
        self.name = name
        self.mediaType = mediaType
        self.folders = folders
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        mediaType = try container.decodeIfPresent(String.self, forKey: .mediaType)
        folders = try container.decodeIfPresent([AudiobookshelfFolder].self, forKey: .folders) ?? []
    }

    var holdsBooks: Bool {
        (mediaType ?? "book") == "book"
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case mediaType
        case folders
    }
}

nonisolated struct AudiobookshelfLibraryList: Decodable, Sendable {
    let libraries: [AudiobookshelfLibrary]
}

nonisolated struct AudiobookshelfDestination: Equatable, Sendable {
    let server: URL
    let token: String
    let libraryID: String
    let folderID: String
}

nonisolated struct AudiobookshelfUpload: Equatable, Sendable {
    let destination: AudiobookshelfDestination
    let title: String
    let author: String?
    let file: URL
}

nonisolated enum AudiobookshelfServerAddress: Equatable, Sendable {
    case secure(URL)
    case localNetwork(URL)
    case invalid(String)

    static let emptyMessage = "Enter your Audiobookshelf server address."
    static let malformedMessage = "Enter a full server address, like https://abs.example.com."
    static let insecureMessage = "Use an https address. Plain http only works for servers on your own network."
    static let credentialsMessage = "Leave the user name and password out of the address. Use an API token instead."
    static let localNetworkWarning = "This server uses plain http, so the token and audiobooks travel unencrypted on your network."

    init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self = .invalid(Self.emptyMessage)
            return
        }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty,
              components.query == nil, components.fragment == nil
        else {
            self = .invalid(Self.malformedMessage)
            return
        }
        guard components.user == nil, components.password == nil else {
            self = .invalid(Self.credentialsMessage)
            return
        }
        components.scheme = scheme
        while components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        guard let url = components.url else {
            self = .invalid(Self.malformedMessage)
            return
        }
        if scheme == "https" {
            self = .secure(url)
        } else if Self.isLocalNetworkHost(host) {
            self = .localNetwork(url)
        } else {
            self = .invalid(Self.insecureMessage)
        }
    }

    var url: URL? {
        switch self {
        case let .secure(url), let .localNetwork(url): url
        case .invalid: nil
        }
    }

    var warning: String? {
        if case .localNetwork = self {
            return Self.localNetworkWarning
        }
        return nil
    }

    var error: String? {
        if case let .invalid(message) = self {
            return message
        }
        return nil
    }

    static func isLocalNetworkHost(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".local") {
            return true
        }
        if let octets = ipv4Octets(host) {
            return isPrivateIPv4(octets)
        }
        if host.contains(":") {
            return host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd")
        }
        return !host.contains(".")
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(part), (0 ... 255).contains(value) else { return nil }
            return value
        }
        return octets.count == 4 ? octets : nil
    }

    private static func isPrivateIPv4(_ octets: [Int]) -> Bool {
        switch (octets[0], octets[1]) {
        case (10, _), (127, _): true
        case (192, 168), (169, 254): true
        case let (172, second): (16 ... 31).contains(second)
        default: false
        }
    }
}

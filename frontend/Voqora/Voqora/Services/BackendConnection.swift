import AppKit
import Darwin
import Foundation
import Security
import SwiftUI

/// The only authority allowed to construct requests to Voqora's local backend.
///
/// The macOS app binds the loopback socket before it starts Python and keeps
/// that descriptor open for the backend lifetime. A unique token is attached
/// as an HTTP header, never encoded in a URL or persisted in user defaults.
final class BackendConnection: @unchecked Sendable {
    static let shared = BackendConnection()

    struct LaunchConfiguration: Sendable {
        let generation: UUID
        let listenerFD: Int32
        let baseURL: URL
        let token: String
    }

    enum ConnectionError: LocalizedError {
        case unavailable
        case listenerCreationFailed
        case randomGenerationFailed

        var errorDescription: String? {
            switch self {
            case .unavailable: return "The local speech engine is not ready."
            case .listenerCreationFailed: return "Voqora could not reserve its local speech connection."
            case .randomGenerationFailed: return "Voqora could not secure its local speech connection."
            }
        }
    }

    private struct State {
        var generation: UUID?
        var listenerFD: Int32 = -1
        var baseURL: URL?
        var token: String?
    }

    private let stateQueue = DispatchQueue(label: "com.voqora.backend.connection")
    private var state = State()

    private init() {}

    deinit { invalidate() }

    private func closeLocked() {
        if state.listenerFD >= 0 {
            Darwin.close(state.listenerFD)
        }
        state = State()
    }

    /// Binds an app-owned listener and creates a fresh token for one child
    /// launch. Any prior listener is retired before the new one is exposed.
    func prepareForLaunch() throws -> LaunchConfiguration {
        try stateQueue.sync {
            closeLocked()

            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw ConnectionError.listenerCreationFailed }

            var reuseAddress: Int32 = 1
            guard setsockopt(
                fd,
                SOL_SOCKET,
                SO_REUSEADDR,
                &reuseAddress,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else {
                close(fd)
                throw ConnectionError.listenerCreationFailed
            }

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(0)
            guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
                close(fd)
                throw ConnectionError.listenerCreationFailed
            }
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, listen(fd, SOMAXCONN) == 0 else {
                close(fd)
                throw ConnectionError.listenerCreationFailed
            }

            // Process inherits only descriptors without close-on-exec. Keep our
            // own duplicate open too, preventing a port takeover during launch.
            let descriptorFlags = fcntl(fd, F_GETFD)
            guard descriptorFlags >= 0,
                  fcntl(fd, F_SETFD, descriptorFlags & ~FD_CLOEXEC) == 0
            else {
                close(fd)
                throw ConnectionError.listenerCreationFailed
            }

            var boundAddress = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &boundAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(fd, $0, &length)
                }
            }
            guard named == 0 else {
                close(fd)
                throw ConnectionError.listenerCreationFailed
            }

            var randomBytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes) == errSecSuccess else {
                close(fd)
                throw ConnectionError.randomGenerationFailed
            }
            let token = Data(randomBytes).base64EncodedString()
            let port = Int(UInt16(bigEndian: boundAddress.sin_port))
            guard let baseURL = URL(string: "http://127.0.0.1:\(port)") else {
                close(fd)
                throw ConnectionError.listenerCreationFailed
            }

            let generation = UUID()
            state = State(
                generation: generation,
                listenerFD: fd,
                baseURL: baseURL,
                token: token
            )
            return LaunchConfiguration(
                generation: generation,
                listenerFD: fd,
                baseURL: baseURL,
                token: token
            )
        }
    }

    /// Closes only the matching launch's listener. An old process termination
    /// cannot tear down a newer process's listener/token pair.
    func invalidate(generation: UUID? = nil) {
        stateQueue.sync {
            guard generation == nil || state.generation == generation else { return }
            closeLocked()
        }
    }

    func request(
        path: String,
        method: String = "GET",
        timeout: TimeInterval? = nil
    ) throws -> URLRequest {
        try stateQueue.sync {
            guard let baseURL = state.baseURL, let token = state.token else {
                throw ConnectionError.unavailable
            }
            let normalized = path.hasPrefix("/") ? String(path.dropFirst()) : path
            var request = URLRequest(url: baseURL.appendingPathComponent(normalized))
            request.httpMethod = method
            request.setValue(token, forHTTPHeaderField: "X-Voqora-IPC-Token")
            if let timeout { request.timeoutInterval = timeout }
            return request
        }
    }
}

/// Authenticated replacement for AsyncImage when the image lives on the local
/// backend. URLSession receives the token in a header, not a cacheable URL.
struct AuthenticatedBackendImage<Content: View, Placeholder: View>: View {
    let path: String
    let content: (Image) -> Content
    let placeholder: () -> Placeholder

    @State private var image: NSImage?

    init(
        path: String,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.path = path
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image { content(Image(nsImage: image)) }
            else { placeholder() }
        }
        .task(id: path) {
            image = nil
            guard let request = try? BackendConnection.shared.request(path: path),
                  let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let decoded = NSImage(data: data)
            else { return }
            image = decoded
        }
    }
}

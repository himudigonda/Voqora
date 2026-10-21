import Foundation

nonisolated enum AudiobookshelfError: LocalizedError, Equatable {
    case notConfigured
    case unauthorized
    case forbidden
    case uploadNotAllowed
    case notAudiobookshelf
    case libraryMissing
    case noBookLibraries
    case rejected
    case tooLarge
    case server(Int)
    case unreachable
    case untrustedCertificate
    case timedOut
    case insecureBlocked
    case couldNotPrepareFile

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Connect Audiobookshelf in Settings first."
        case .unauthorized: "Audiobookshelf rejected the API token. Create a new token in Audiobookshelf and paste it here."
        case .forbidden: "This Audiobookshelf account can't see the server's libraries."
        case .uploadNotAllowed: "This Audiobookshelf account isn't allowed to upload. Ask the server admin to allow uploads."
        case .notAudiobookshelf: "That address doesn't look like an Audiobookshelf server. Check it and try again."
        case .libraryMissing: "The chosen library or folder no longer exists. Pick a library again in Settings."
        case .noBookLibraries: "This server has no audiobook libraries yet. Create one in Audiobookshelf first."
        case .rejected: "Audiobookshelf didn't accept the upload. Check the library folder on the server."
        case .tooLarge: "The server refused a file this large. Raise the upload limit on the server or its proxy."
        case let .server(code): "Audiobookshelf returned an error (\(code)). Try again later."
        case .unreachable: "Voqora couldn't reach the Audiobookshelf server. Check the address and that the server is running."
        case .untrustedCertificate: "This Mac doesn't trust the server's certificate."
        case .timedOut: "Audiobookshelf took too long to respond. Try again."
        case .insecureBlocked: "macOS blocked the plain http connection. Use an https address."
        case .couldNotPrepareFile: "Voqora couldn't prepare the audiobook for upload."
        }
    }

    var failureCode: String {
        switch self {
        case .notConfigured: "abs_not_configured"
        case .unauthorized: "abs_unauthorized"
        case .forbidden: "abs_forbidden"
        case .uploadNotAllowed: "abs_upload_not_allowed"
        case .notAudiobookshelf: "abs_not_audiobookshelf"
        case .libraryMissing: "abs_library_missing"
        case .noBookLibraries: "abs_no_book_libraries"
        case .rejected: "abs_rejected"
        case .tooLarge: "abs_too_large"
        case .server: "abs_server_error"
        case .unreachable: "abs_unreachable"
        case .untrustedCertificate: "abs_untrusted_certificate"
        case .timedOut: "abs_timed_out"
        case .insecureBlocked: "abs_insecure_blocked"
        case .couldNotPrepareFile: "abs_prepare_failed"
        }
    }

    static func from(transport error: Error) -> Error {
        if error is CancellationError {
            return error
        }
        guard let urlError = error as? URLError else { return AudiobookshelfError.unreachable }
        switch urlError.code {
        case .cancelled: return CancellationError()
        case .timedOut: return AudiobookshelfError.timedOut
        case .appTransportSecurityRequiresSecureConnection: return AudiobookshelfError.insecureBlocked
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .secureConnectionFailed:
            return AudiobookshelfError.untrustedCertificate
        default: return AudiobookshelfError.unreachable
        }
    }
}

@MainActor
protocol AudiobookshelfServing: AnyObject {
    func libraries(server: URL, token: String) async throws -> [AudiobookshelfLibrary]
    func upload(_ upload: AudiobookshelfUpload, progress: @escaping @Sendable (Double) -> Void) async throws
}

final class AudiobookshelfClient: AudiobookshelfServing {
    static let librariesPath = "api/libraries"
    static let uploadPath = "api/upload"
    static let fileContentType = "audio/mp4"

    private let session: URLSession
    private let temporaryDirectory: URL

    init(session: URLSession = .shared, temporaryDirectory: URL? = nil) {
        self.session = session
        self.temporaryDirectory = temporaryDirectory ?? FileManager.default.temporaryDirectory
    }

    func libraries(server: URL, token: String) async throws -> [AudiobookshelfLibrary] {
        var request = Self.request(server: server, path: Self.librariesPath, token: token)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            throw AudiobookshelfError.from(transport: error)
        }
        let statusCode = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        switch statusCode {
        case 200:
            guard let list = try? JSONDecoder().decode(AudiobookshelfLibraryList.self, from: result.0) else {
                throw AudiobookshelfError.notAudiobookshelf
            }
            return list.libraries
        case 401: throw AudiobookshelfError.unauthorized
        case 403: throw AudiobookshelfError.forbidden
        case 404: throw AudiobookshelfError.notAudiobookshelf
        default: throw AudiobookshelfError.server(statusCode)
        }
    }

    func upload(_ upload: AudiobookshelfUpload, progress: @escaping @Sendable (Double) -> Void) async throws {
        let boundary = MultipartFormWriter.makeBoundary()
        let body = temporaryDirectory.appendingPathComponent("Voqora-abs-\(UUID().uuidString).multipart")
        defer { try? FileManager.default.removeItem(at: body) }
        let fields = Self.fields(for: upload)
        let filePart = Self.filePart(for: upload)
        do {
            try await Task.detached(priority: .userInitiated) {
                try MultipartFormWriter.write(fields: fields, file: filePart, boundary: boundary, to: body)
            }.value
        } catch {
            throw AudiobookshelfError.couldNotPrepareFile
        }
        try Task.checkCancellation()

        var request = Self.request(server: upload.destination.server, path: Self.uploadPath, token: upload.destination.token)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue(MultipartFormWriter.contentType(boundary: boundary), forHTTPHeaderField: "Content-Type")
        let result: (Data, URLResponse)
        do {
            result = try await session.upload(
                for: request,
                fromFile: body,
                delegate: UploadProgressDelegate(report: progress)
            )
        } catch {
            throw AudiobookshelfError.from(transport: error)
        }
        try Self.validateUpload(statusCode: (result.1 as? HTTPURLResponse)?.statusCode ?? 0)
        progress(1)
    }

    static func fields(for upload: AudiobookshelfUpload) -> [(String, String)] {
        var fields = [("title", upload.title)]
        if let author = upload.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
            fields.append(("author", author))
        }
        fields.append(("library", upload.destination.libraryID))
        fields.append(("folder", upload.destination.folderID))
        return fields
    }

    static func filePart(for upload: AudiobookshelfUpload) -> MultipartFilePart {
        MultipartFilePart(
            name: "0",
            filename: AudiobookExportNaming.fileName(for: upload.title, format: .m4b),
            contentType: fileContentType,
            source: upload.file
        )
    }

    static func validateUpload(statusCode: Int) throws {
        switch statusCode {
        case 200 ..< 300: return
        case 400: throw AudiobookshelfError.rejected
        case 401: throw AudiobookshelfError.unauthorized
        case 403: throw AudiobookshelfError.uploadNotAllowed
        case 404: throw AudiobookshelfError.libraryMissing
        case 413: throw AudiobookshelfError.tooLarge
        default: throw AudiobookshelfError.server(statusCode)
        }
    }

    static func request(server: URL, path: String, token: String) -> URLRequest {
        var request = URLRequest(url: server.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}

private final nonisolated class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Double) -> Void

    init(report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didSendBodyData _: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(min(1, max(0, Double(totalBytesSent) / Double(totalBytesExpectedToSend))))
    }
}

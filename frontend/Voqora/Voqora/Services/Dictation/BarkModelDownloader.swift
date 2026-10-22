import CryptoKit
import Foundation

nonisolated enum BarkModelDownloadError: LocalizedError, Equatable, Sendable {
    case badResponse(Int)
    case checksumMismatch(String)

    var errorDescription: String? {
        switch self {
        case let .badResponse(status): "Hugging Face answered with HTTP \(status)."
        case let .checksumMismatch(path): "\(path) didn't match its expected checksum."
        }
    }
}

nonisolated struct BarkModelDownloader: Sendable {
    typealias Fetch = @Sendable (URL, @escaping @Sendable (Int64) -> Void) async throws -> (URL, Int)

    let fetch: Fetch

    init(fetch: Fetch? = nil) {
        self.fetch = fetch ?? Self.urlSessionFetch
    }

    static func isInstalled(_ files: [BarkModelFile], in directory: URL) -> Bool {
        files.allSatisfy { file in
            let url = directory.appendingPathComponent(file.path)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            return size.map(Int64.init) == file.size
        }
    }

    static func stagingDirectory(for directory: URL) -> URL {
        directory.deletingLastPathComponent().appendingPathComponent(".\(directory.lastPathComponent).partial", isDirectory: true)
    }

    @concurrent
    func install(
        _ files: [BarkModelFile],
        folder: String,
        into directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let manager = FileManager.default
        let staging = Self.stagingDirectory(for: directory)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        let total = max(1, files.reduce(Int64(0)) { $0 + $1.size })
        var completed: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let target = staging.appendingPathComponent(file.path)
            if Self.matches(file, at: target) {
                completed += file.size
                progress(Double(completed) / Double(total))
                continue
            }
            let existing = directory.appendingPathComponent(file.path)
            if Self.matches(file, at: existing) {
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if manager.fileExists(atPath: target.path) {
                    try manager.removeItem(at: target)
                }
                try manager.copyItem(at: existing, to: target)
                completed += file.size
                progress(Double(completed) / Double(total))
                continue
            }
            let base = completed
            let (temporary, status) = try await fetch(BarkModelManifest.downloadURL(folder: folder, path: file.path)) { written in
                progress(Double(base + min(written, file.size)) / Double(total))
            }
            defer { try? manager.removeItem(at: temporary) }
            guard status == 200 else { throw BarkModelDownloadError.badResponse(status) }
            guard Self.matches(file, at: temporary) else { throw BarkModelDownloadError.checksumMismatch(file.path) }
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: target.path) {
                try manager.removeItem(at: target)
            }
            try manager.moveItem(at: temporary, to: target)
            completed += file.size
            progress(Double(completed) / Double(total))
        }
        try manager.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: directory.path) {
            try manager.removeItem(at: directory)
        }
        try manager.moveItem(at: staging, to: directory)
    }

    static func matches(_ file: BarkModelFile, at url: URL) -> Bool {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, Int64(size) == file.size else { return false }
        return sha256(of: url) == file.sha256
    }

    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static let urlSessionFetch: Fetch = { url, onWritten in
        let delegate = DownloadProgressDelegate(onWritten: onWritten)
        let (temporary, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: temporary, to: kept)
        return (kept, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

private final nonisolated class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    let onWritten: @Sendable (Int64) -> Void

    init(onWritten: @escaping @Sendable (Int64) -> Void) {
        self.onWritten = onWritten
    }

    func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite _: Int64) {
        onWritten(totalBytesWritten)
    }

    func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didFinishDownloadingTo _: URL) {}
}

import Foundation

nonisolated enum BackendFileDownload {
    static let chunkSize = 64 * 1024
    static let maximumErrorBodySize = 64 * 1024

    static func save(
        _ request: URLRequest,
        using session: URLSession,
        to destination: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let worker = Task.detached(priority: .userInitiated) {
            try await Self.stream(request, using: session, to: destination, progress: progress)
        }
        try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func stream(
        _ request: URLRequest,
        using session: URLSession,
        to destination: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AudiobookAPIFailure(statusCode: 0)
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let body = try await collect(bytes)
            throw AudiobookAPIFailure(statusCode: http.statusCode, body: body)
        }
        let workspace = try AtomicFileReplacement.makeWorkspace(near: destination)
        defer { AtomicFileReplacement.discard(workspace) }
        let staged = workspace.appendingPathComponent(destination.lastPathComponent)
        let expected = http.expectedContentLength
        let written = try await write(bytes, to: staged, expected: expected, progress: progress)
        guard expected < 0 || written == expected else {
            throw URLError(.networkConnectionLost)
        }
        try AtomicFileReplacement.moveIntoPlace(staged, at: destination)
        progress?(1)
    }

    private static func write(
        _ bytes: URLSession.AsyncBytes,
        to file: URL,
        expected: Int64,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> Int64 {
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(chunkSize)
        var written: Int64 = 0
        var reportedPercent: Int64 = -1
        func flush() throws {
            guard !buffer.isEmpty else { return }
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
            buffer.removeAll(keepingCapacity: true)
            guard expected > 0, let progress else { return }
            let percent = min(100, written * 100 / expected)
            if percent != reportedPercent {
                reportedPercent = percent
                progress(Double(percent) / 100)
            }
        }
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= chunkSize {
                try Task.checkCancellation()
                try flush()
            }
        }
        try flush()
        try handle.synchronize()
        return written
    }

    private static func collect(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var body = Data()
        for try await byte in bytes {
            guard body.count < maximumErrorBodySize else { break }
            body.append(byte)
        }
        return body
    }
}

import Foundation

nonisolated enum BackendFileDownload {
    static let maximumErrorBodySize = 64 * 1024

    static func fraction(written: Int64, expected: Int64) -> Double? {
        guard expected > 0 else { return nil }
        return min(1, max(0, Double(written) / Double(expected)))
    }

    static func save(
        _ request: URLRequest,
        using session: URLSession,
        to destination: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let transfer = DownloadTransfer(progress)
        let (downloaded, response) = try await download(request, using: session, transfer: transfer)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        guard let http = response as? HTTPURLResponse else {
            throw AudiobookAPIFailure(statusCode: 0)
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw AudiobookAPIFailure(statusCode: http.statusCode, body: errorBody(of: downloaded))
        }
        let expected = http.expectedContentLength
        if expected >= 0 {
            let actual = try (FileManager.default.attributesOfItem(atPath: downloaded.path)[.size] as? NSNumber)?.int64Value
            guard actual == expected else { throw URLError(.networkConnectionLost) }
        }
        try Task.checkCancellation()
        let workspace = try AtomicFileReplacement.makeWorkspace(near: destination)
        defer { AtomicFileReplacement.discard(workspace) }
        let staged = workspace.appendingPathComponent(destination.lastPathComponent)
        try FileManager.default.moveItem(at: downloaded, to: staged)
        try AtomicFileReplacement.moveIntoPlace(staged, at: destination)
        transfer.complete()
    }

    private static func download(
        _ request: URLRequest,
        using session: URLSession,
        transfer: DownloadTransfer
    ) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: request) { location, response, error in
                    transfer.finish()
                    continuation.resume(with: Self.outcome(location: location, response: response, error: error))
                }
                transfer.start(task)
            }
        } onCancel: {
            transfer.cancel()
        }
    }

    private static func outcome(
        location: URL?,
        response: URLResponse?,
        error: Error?
    ) -> Result<(URL, URLResponse), Error> {
        if let error {
            return .failure(error)
        }
        guard let location, let response else { return .failure(URLError(.badServerResponse)) }
        let retained = FileManager.default.temporaryDirectory
            .appendingPathComponent("voqora-download-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: retained)
        } catch {
            return .failure(error)
        }
        return .success((retained, response))
    }

    private static func errorBody(of file: URL) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: maximumErrorBodySize)) ?? Data()
    }
}

private final nonisolated class DownloadTransfer: @unchecked Sendable {
    private let report: (@Sendable (Double) -> Void)?
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?
    private var isCancelled = false
    private var lastPercent = -1

    init(_ report: (@Sendable (Double) -> Void)?) {
        self.report = report
    }

    func start(_ task: URLSessionDownloadTask) {
        let cancelled = lock.withLock { () -> Bool in
            self.task = task
            return isCancelled
        }
        if report != nil {
            let observation = task.observe(\.countOfBytesReceived, options: [.new]) { [weak self] task, _ in
                self?.publish(written: task.countOfBytesReceived, expected: task.countOfBytesExpectedToReceive)
            }
            lock.withLock { self.observation = observation }
        }
        if cancelled {
            task.cancel()
        } else {
            task.resume()
        }
    }

    func cancel() {
        let task = lock.withLock { () -> URLSessionDownloadTask? in
            isCancelled = true
            return self.task
        }
        task?.cancel()
    }

    func finish() {
        lock.withLock {
            observation?.invalidate()
            observation = nil
        }
    }

    func complete() {
        publish(percent: 100)
    }

    private func publish(written: Int64, expected: Int64) {
        guard let fraction = BackendFileDownload.fraction(written: written, expected: expected) else { return }
        publish(percent: Int(fraction * 100))
    }

    private func publish(percent: Int) {
        guard let report else { return }
        let isNew = lock.withLock { () -> Bool in
            guard percent != lastPercent else { return false }
            lastPercent = percent
            return true
        }
        if isNew {
            report(Double(percent) / 100)
        }
    }
}

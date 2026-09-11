import AppKit
import Combine
import Foundation

/// A thread-safe service to manage the Python backend process and handle streaming requests.
final class BackendService: NSObject, @unchecked Sendable {
    enum LogExportError: LocalizedError {
        case noLogsAvailable
        case couldNotSave

        var errorDescription: String? {
            switch self {
            case .noLogsAvailable:
                "There are no Voqora logs available to export yet."
            case .couldNotSave:
                "Voqora could not save the debug logs to your Desktop."
            }
        }
    }

    private var process: Process?
    private var processPipe: Pipe?
    /// Persistent log handle. Held for the lifetime of the backend process so
    /// the readability handler doesn't open/close per-chunk. See HARD-013.
    private var logFileHandle: FileHandle?
    private let stateQueue = DispatchQueue(label: "com.voqora.backend.state", qos: .userInitiated)

    // Thread-safe state managed by stateQueue
    private var _isLaunching = false
    private var nextLaunchAllowedAt = Date.distantPast
    /// A short, non-sensitive diagnostic for the UI while the owned local
    /// process is being retried. This is intentionally not a raw system error
    /// or a path: those stay in the exported debug log.
    private var _lastLaunchFailure: String?
    private static let failedLaunchBackoff: TimeInterval = 2
    private let executableOverride: URL?
    private let applicationSupportOverride: URL?
    private let connection: BackendConnection
    var isLaunching: Bool {
        stateQueue.sync { _isLaunching }
    }

    var lastLaunchFailure: String? {
        stateQueue.sync { _lastLaunchFailure }
    }

    func clearLaunchFailure() {
        stateQueue.sync { _lastLaunchFailure = nil }
    }

    /// Internal lifecycle visibility for deterministic fast-exit regression
    /// coverage. Product code never uses this to control backend ownership.
    var hasOwnedProcess: Bool {
        stateQueue.sync { process != nil }
    }

    private var continuations: [Int: AsyncThrowingStream<Data, Error>.Continuation] = [:]

    enum StreamError: Error, Equatable {
        case requestEncodingFailed
        case rejectedResponse(statusCode: Int)
        case unexpectedResponse
        case emptyAudio
    }

    /// Shared session for streaming this is a
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 10
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    init(
        executableOverride: URL? = nil,
        applicationSupportOverride: URL? = nil,
        connection: BackendConnection = .shared
    ) {
        self.executableOverride = executableOverride
        self.applicationSupportOverride = applicationSupportOverride
        self.connection = connection
        super.init()
    }

    // MARK: - Process Management

    func start() {
        // CRITICAL: stateQueue.sync closure `return` only exits the closure, NOT this
        // function. Use a flag so we can guard at function scope.
        var shouldStart = false
        stateQueue.sync {
            guard process == nil,
                  !_isLaunching,
                  Date() >= nextLaunchAllowedAt
            else { return }
            _isLaunching = true
            shouldStart = true
        }
        // Real function-level guard — prevents repeated launch attempts while
        // the server is already starting or during a bounded failure backoff.
        guard shouldStart else { return }

        let bundleID = Bundle.main.bundleIdentifier ?? "com.himudigonda.Voqora"
        let appSupport = applicationSupportOverride
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let executableURL = executableOverride
            ?? appSupport.appendingPathComponent("VoqoraServer/VoqoraServer")

        // Just check if LaunchManager did its job
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            stateQueue.sync {
                _isLaunching = false
                nextLaunchAllowedAt = Date().addingTimeInterval(Self.failedLaunchBackoff)
                _lastLaunchFailure = "The local speech engine is unavailable."
            }
            VoqoraLog.error("BackendService", "Backend binary not ready yet", ["path": executableURL.path])
            return
        }

        let launchConfiguration: BackendConnection.LaunchConfiguration
        do {
            launchConfiguration = try connection.prepareForLaunch()
        } catch {
            stateQueue.sync {
                _isLaunching = false
                nextLaunchAllowedAt = Date().addingTimeInterval(Self.failedLaunchBackoff)
                _lastLaunchFailure = "The local speech engine could not secure its connection."
            }
            VoqoraLog.error("BackendService", "Backend connection setup failed")
            return
        }

        let p = Process()
        p.executableURL = executableURL

        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["VOQORA_IPC_TOKEN"] = launchConfiguration.token
        env["VOQORA_IPC_LISTENER_FD"] = String(launchConfiguration.listenerFD)
        p.environment = env

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        let logURL = appSupport.appendingPathComponent("backend.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        _ = try? "".write(to: logURL, atomically: true, encoding: .utf8)

        // Open the log handle ONCE for the lifetime of the process. The previous
        // per-chunk FileHandle(forWritingTo:) was an `open()` + `seek` + `close`
        // syscall per backend log line. See HARD-013.
        let handle = try? FileHandle(forWritingTo: logURL)
        _ = try? handle?.seekToEnd()
        stateQueue.sync {
            self.logFileHandle = handle
        }

        var loggedWriteFailure = false
        pipe.fileHandleForReading.readabilityHandler = { [weak self] readHandle in
            let data = readHandle.availableData
            if data.isEmpty {
                return
            }
            // Write via the persistent handle (serialized on stateQueue so
            // concurrent log lines don't interleave inside a single write).
            self?.stateQueue.async {
                if let lh = self?.logFileHandle {
                    do {
                        try lh.write(contentsOf: data)
                    } catch {
                        // Silent here previously meant a real crash could leave
                        // the exported backend.log empty with zero indication
                        // why. Log once (not per-chunk — this runs on every
                        // backend stdout line) so a full disk/permission loss
                        // is at least visible in the app's own diagnostic log.
                        if !loggedWriteFailure {
                            loggedWriteFailure = true
                            VoqoraLog.error("BackendService", "backend.log write failed, further failures suppressed", ["failureCode": "backend_log_write_failed"])
                        }
                    }
                }
            }
            if let str = String(data: data, encoding: .utf8) {
                print("[BACKEND] \(str)", terminator: "")
            }
        }

        // When the process exits (crash or intentional stop), clear the reference so
        // the next heartbeat cycle can call start() again and restart it.
        p.terminationHandler = { [weak self] terminated in
            guard let self else { return }
            stateQueue.sync {
                if self.process === terminated {
                    self.process = nil
                    self._isLaunching = false
                    if terminated.terminationStatus != 0 {
                        self.nextLaunchAllowedAt = Date().addingTimeInterval(Self.failedLaunchBackoff)
                        self._lastLaunchFailure = "The local speech engine stopped unexpectedly."
                    }
                    self.processPipe?.fileHandleForReading.readabilityHandler = nil
                    self.processPipe = nil
                    try? self.logFileHandle?.close()
                    self.logFileHandle = nil
                }
            }
            connection.invalidate(generation: launchConfiguration.generation)
            VoqoraLog.warn("BackendService", "Backend process exited", ["pid": "\(terminated.processIdentifier)", "exitStatus": "\(terminated.terminationStatus)"])
        }

        // Register ownership before starting the child. A binary can fail fast
        // (for example, after a damaged extraction); recording it only after
        // `run()` races its termination handler and can leave the app holding a
        // dead Process forever. Never terminate a separately running copy here.
        stateQueue.sync {
            self.process = p
            self.processPipe = pipe
        }

        do {
            // LaunchManager verifies the installed runtime during extraction;
            // repeat the inexpensive manifest check immediately before every
            // production execution so post-install tampering fails closed.
            // Test fixtures intentionally bypass this sealed-bundle contract.
            if executableOverride == nil {
                try LaunchManager.validateRuntimeForExecution(at: executableURL)
            }
            try p.run()
            stateQueue.sync {
                if self.process === p {
                    self._isLaunching = false
                }
            }
            VoqoraLog.info("BackendService", "Backend launched", ["pid": "\(p.processIdentifier)"])
        } catch {
            VoqoraLog.error("BackendService", "Backend launch failed")
            connection.invalidate(generation: launchConfiguration.generation)
            stateQueue.sync {
                if self.process === p {
                    self.process = nil
                    self.processPipe?.fileHandleForReading.readabilityHandler = nil
                    self.processPipe = nil
                    try? self.logFileHandle?.close()
                    self.logFileHandle = nil
                }
                _isLaunching = false
                nextLaunchAllowedAt = Date().addingTimeInterval(Self.failedLaunchBackoff)
                _lastLaunchFailure = "The local speech engine could not start."
            }
        }
    }

    /// Terminates the current process (if any) and immediately attempts to
    /// relaunch it. `start()` is normally a no-op whenever `process != nil` —
    /// that's correct for an actually-healthy process, but leaves no recovery
    /// path if the process is alive per macOS yet wedged (e.g. a deadlocked
    /// event loop) and stops answering `/health`. Callers use this to force
    /// a fresh process when sustained health-check failures indicate a hang.
    func forceRestart() {
        stop()
        start()
    }

    func stop() {
        stateQueue.sync {
            // Close pipe readability handler to avoid file descriptor leak on restart
            processPipe?.fileHandleForReading.readabilityHandler = nil
            try? logFileHandle?.close()
            logFileHandle = nil
            process?.terminate()
            process = nil
            processPipe = nil
        }
        connection.invalidate()

        // `process?.terminate()` above is intentionally scoped to the child
        // Voqora started. Never kill every process named VoqoraServer: an
        // installed app and a local candidate can otherwise tear each other
        // down during ordinary testing.
    }

    func exportLogs() throws -> [URL] {
        let fileManager = FileManager.default
        let bundleID = Bundle.main.bundleIdentifier ?? "com.himudigonda.Voqora"
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(bundleID)
        let desktop = fileManager.urls(for: .desktopDirectory, in: .userDomainMask)[0]

        let logsToExport = ["backend.log", "frontend.log"]
        let timestamp = Int(Date().timeIntervalSince1970)

        var exportedURLs: [URL] = []
        do {
            for logName in logsToExport {
                let sourceURL = appSupport.appendingPathComponent(logName)
                guard fileManager.fileExists(atPath: sourceURL.path) else { continue }

                let destinationURL = uniqueLogExportURL(
                    named: "Voqora_\(logName)_\(timestamp)",
                    in: desktop,
                    fileManager: fileManager
                )
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
                exportedURLs.append(destinationURL)
            }
        } catch {
            VoqoraLog.error("BackendService", "exportLogs failed", ["failureCode": "log_export_failed"])
            for url in exportedURLs {
                try? fileManager.removeItem(at: url)
            }
            throw LogExportError.couldNotSave
        }

        guard !exportedURLs.isEmpty else { throw LogExportError.noLogsAvailable }
        return exportedURLs
    }

    private func uniqueLogExportURL(named stem: String, in directory: URL, fileManager: FileManager) -> URL {
        var suffix = 1
        var url = directory.appendingPathComponent("\(stem).txt")
        while fileManager.fileExists(atPath: url.path) {
            suffix += 1
            url = directory.appendingPathComponent("\(stem)_\(suffix).txt")
        }
        return url
    }

    struct HealthStatus {
        let isOnline: Bool
        let isModelLoaded: Bool

        static let offline = HealthStatus(isOnline: false, isModelLoaded: false)
    }

    func checkHealth() async -> HealthStatus {
        guard let request = try? connection.request(path: "health", timeout: 1) else {
            return .offline
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return .offline
            }
            stateQueue.sync { _isLaunching = false }
            let loaded = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["loaded"] as? Bool ?? false
            return HealthStatus(isOnline: true, isModelLoaded: loaded)
        } catch {
            return .offline
        }
    }

    /// Fire-and-forget: ask the backend to reload the model and optionally pre-compute
    /// the first audio segment for the given text (lookahead cache).
    /// Returns immediately. Safe to call when model is already loaded.
    func prewarm(text: String? = nil, voice: String? = nil, speed: Double? = nil) async {
        guard var request = try? connection.request(path: "prewarm", method: "POST", timeout: 2) else {
            return
        }
        if let text, let voice, let speed {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let payload: [String: Any] = ["text": text, "voice": voice, "speed": speed]
            request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        }
        _ = try? await URLSession.shared.data(for: request)
    }

    func streamAudio(text: String, voice: String, speed: Double, volume: Double) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            guard var request = try? self.connection.request(
                path: "speak", method: "POST", timeout: 120
            ) else {
                continuation.finish(throwing: StreamError.requestEncodingFailed)
                return
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let payload: [String: Any] = ["text": text, "voice": voice, "speed": speed, "volume": volume]

            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: payload)
                let task = session.dataTask(with: request)
                let id = task.taskIdentifier

                stateQueue.sync {
                    continuations[id] = continuation
                }

                task.resume()

                continuation.onTermination = { @Sendable _ in
                    task.cancel()
                    self.stateQueue.async {
                        self.continuations.removeValue(forKey: id)
                    }
                }
            } catch {
                VoqoraLog.error("BackendService", "streamAudio request encoding failed", ["failureCode": "stream_request_encoding_failed"])
                continuation.finish(throwing: StreamError.requestEncodingFailed)
            }
        }
    }

    /// A local /speak response is useful only when it is a successful WAV
    /// stream. Without this guard, a JSON error body could be handed to the
    /// audio decoder and then be reported as a successful generation.
    static func isExpectedAudioResponse(_ response: URLResponse?) -> Bool {
        guard let http = response as? HTTPURLResponse,
              (200 ..< 300).contains(http.statusCode),
              let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased()
        else {
            return false
        }
        return contentType.hasPrefix("audio/wav")
    }
}

extension BackendService: URLSessionDataDelegate {
    func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard Self.isExpectedAudioResponse(response) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            stateQueue.async {
                self.continuations[dataTask.taskIdentifier]?.finish(
                    throwing: statusCode.map(StreamError.rejectedResponse) ?? .unexpectedResponse
                )
                self.continuations.removeValue(forKey: dataTask.taskIdentifier)
            }
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let id = dataTask.taskIdentifier
        // Use async dispatch to avoid blocking the URLSession delegate queue
        stateQueue.async {
            self.continuations[id]?.yield(data)
        }
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        stateQueue.sync {
            if let error {
                continuations[id]?.finish(throwing: error)
            } else {
                continuations[id]?.finish()
            }
            continuations.removeValue(forKey: id)
        }
    }
}

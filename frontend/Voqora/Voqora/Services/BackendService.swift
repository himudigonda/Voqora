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
                return "There are no Voqora logs available to export yet."
            case .couldNotSave:
                return "Voqora could not save the debug logs to your Desktop."
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
    var isLaunching: Bool {
        stateQueue.sync { _isLaunching }
    }

    private let baseURL = URL(string: "http://127.0.0.1:10101")!
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

    // MARK: - Process Management

    func start() {
        // CRITICAL: stateQueue.sync closure `return` only exits the closure, NOT this
        // function. Use a flag so we can guard at function scope.
        var shouldStart = false
        stateQueue.sync {
            guard process == nil, !_isLaunching else { return }
            _isLaunching = true
            shouldStart = true
        }
        // Real function-level guard — prevents the pkill + relaunch every 500 ms while
        // the server is already starting (the previous crash-loop root cause).
        guard shouldStart else { return }

        // start() is called from the @MainActor heartbeat (every 500 ms while the
        // backend is offline). The pkill + waitUntilExit and Process.run below are
        // blocking syscalls that were stalling the UI on every cycle. Hop them to a
        // background queue — _isLaunching is already set, so re-entry stays blocked.
        // Mirrors stop()'s background-pkill pattern. See HARD-012.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.performLaunch()
        }
    }

    /// The blocking portion of start(): stale-process cleanup, process spawn, and
    /// log wiring. Always runs on a background queue (dispatched from start()).
    private func performLaunch() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.himudigonda.Voqora"
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(bundleID)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let executableURL = appSupport.appendingPathComponent("VoqoraServer/VoqoraServer")

        // Just check if LaunchManager did its job
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            stateQueue.sync { _isLaunching = false }
            print("❌ Backend binary not ready yet.")
            return
        }

        // Kill only a stale copy of this exact extracted backend. A generic
        // `pkill VoqoraServer` can terminate another app build and made local
        // QA look like the product was spawning or fighting multiple apps.
        let cleanup = Process()
        cleanup.launchPath = "/usr/bin/pkill"
        cleanup.arguments = ["-f", executableURL.path]
        try? cleanup.run()
        cleanup.waitUntilExit()

        let p = Process()
        p.executableURL = executableURL

        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
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

        pipe.fileHandleForReading.readabilityHandler = { [weak self] readHandle in
            let data = readHandle.availableData
            if data.isEmpty {
                return
            }
            // Write via the persistent handle (serialized on stateQueue so
            // concurrent log lines don't interleave inside a single write).
            self?.stateQueue.async {
                if let lh = self?.logFileHandle {
                    try? lh.write(contentsOf: data)
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
                    try? self.logFileHandle?.close()
                    self.logFileHandle = nil
                }
            }
            print("⚠️ Backend process exited (PID: \(terminated.processIdentifier), status: \(terminated.terminationStatus))")
        }

        do {
            try p.run()
            stateQueue.sync {
                self.process = p
                self.processPipe = pipe
                self._isLaunching = false
            }
            print("✅ Backend Launched (PID: \(p.processIdentifier))")
        } catch {
            print("❌ Backend Launch Failed: \(error)")
            stateQueue.sync {
                _isLaunching = false
            }
        }
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
            for url in exportedURLs { try? fileManager.removeItem(at: url) }
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
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        // 1-second timeout: we poll at 500 ms when offline, so 3 s was wasting
        // multiple entire poll cycles on each failed request.
        request.timeoutInterval = 1
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
        var request = URLRequest(url: baseURL.appendingPathComponent("prewarm"))
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        if let text, let voice, let speed {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let payload: [String: Any] = ["text": text, "voice": voice, "speed": speed]
            request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        }
        _ = try? await URLSession.shared.data(for: request)
    }

    func streamAudio(text: String, voice: String, speed: Double, volume: Double) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let url = baseURL.appendingPathComponent("speak")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 120

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
                continuation.finish(throwing: StreamError.requestEncodingFailed)
            }
        }
    }

    /// A local /speak response is useful only when it is a successful WAV
    /// stream. Without this guard, a JSON error body could be handed to the
    /// audio decoder and then be reported as a successful generation.
    static func isExpectedAudioResponse(_ response: URLResponse?) -> Bool {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
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

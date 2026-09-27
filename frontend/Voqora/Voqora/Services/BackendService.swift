import AppKit
import Combine
import Foundation

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
    private var logFileHandle: FileHandle?
    private let stateQueue = DispatchQueue(label: "com.voqora.backend.state", qos: .userInitiated)

    private var _isLaunching = false
    private var nextLaunchAllowedAt = Date.distantPast
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

    func start() {
        var shouldStart = false
        stateQueue.sync {
            guard process == nil,
                  !_isLaunching,
                  Date() >= nextLaunchAllowedAt
            else { return }
            _isLaunching = true
            shouldStart = true
        }
        guard shouldStart else { return }

        let bundleID = Bundle.main.bundleIdentifier ?? "com.himudigonda.Voqora"
        let appSupport = applicationSupportOverride
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let executableURL = executableOverride
            ?? appSupport.appendingPathComponent("VoqoraServer/VoqoraServer")

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
        env["VOQORA_IPC_LISTENER_FD"] = "0"
        p.environment = env
        p.standardInput = FileHandle(fileDescriptor: launchConfiguration.listenerFD, closeOnDealloc: false)

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        let logURL = appSupport.appendingPathComponent("backend.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        _ = try? "".write(to: logURL, atomically: true, encoding: .utf8)

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
            self?.stateQueue.async {
                if let lh = self?.logFileHandle {
                    do {
                        try lh.write(contentsOf: data)
                    } catch {
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

        stateQueue.sync {
            self.process = p
            self.processPipe = pipe
        }

        do {
            if executableOverride == nil {
                let started = Date()
                try LaunchManager.validateRuntimeForExecution(at: executableURL)
                let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
                VoqoraLog.info("BackendService", "Runtime integrity verified", ["verifyMs": "\(elapsedMs)"])
            }
            try p.run()
            stateQueue.sync {
                if self.process === p {
                    self._isLaunching = false
                }
            }
            VoqoraLog.info("BackendService", "Backend launched", ["pid": "\(p.processIdentifier)"])
        } catch {
            VoqoraLog.error("BackendService", "Backend launch failed", ["error": "\(error)"])
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

    func forceRestart() {
        stop()
        start()
    }

    func stop() {
        stateQueue.sync {
            processPipe?.fileHandleForReading.readabilityHandler = nil
            try? logFileHandle?.close()
            logFileHandle = nil
            process?.terminate()
            process = nil
            processPipe = nil
        }
        connection.invalidate()
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

    func prewarm() async {
        guard let request = try? connection.request(path: "prewarm", method: "POST", timeout: 2) else {
            return
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

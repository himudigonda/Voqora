import AppKit
import Foundation

/// HTTP client for the audiobook backend endpoints. SSE consumer.
final class AudiobookService: NSObject, @unchecked Sendable {
    private let connection: BackendConnection

    init(connection: BackendConnection = .shared) {
        self.connection = connection
        super.init()
    }

    /// Keep multipart metadata aligned with the file kinds the native picker,
    /// analytics boundary, and backend deliberately support.
    static func mimeType(forFileExtension fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "pdf": "application/pdf"
        case "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "txt", "md": "text/plain; charset=utf-8"
        default: "application/octet-stream"
        }
    }

    /// Local cache root for downloaded audio files.
    private var cacheDir: URL {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.himudigonda.Voqora"
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID)
            .appendingPathComponent("audiobook_cache")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport
    }

    // MARK: - Listing

    func list() async throws -> [Audiobook] {
        let req = try connection.request(path: "audiobook", timeout: 10)
        let (data, _) = try await URLSession.shared.data(for: req)
        // Decode each entry individually so one corrupt/partial book (e.g. a ghost
        // entry left by a failed upload) doesn't poison the whole library load.
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return try JSONDecoder().decode([Audiobook].self, from: data)
        }
        let decoder = JSONDecoder()
        return items.compactMap { dict in
            guard let itemData = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
            if let book = try? decoder.decode(Audiobook.self, from: itemData) {
                return book
            }
            if let id = dict["book_id"] as? String {
                VoqoraLog.warn("AudiobookService", "Skipping corrupt library entry", ["bookID": id])
            }
            return nil
        }
    }

    func get(_ id: String) async throws -> Audiobook {
        let req = try connection.request(path: "audiobook/\(id)", timeout: 10)
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(Audiobook.self, from: data)
    }

    func delete(_ id: String) async throws {
        let req = try connection.request(path: "audiobook/\(id)", method: "DELETE", timeout: 10)
        _ = try await URLSession.shared.data(for: req)
        let cached = cacheDir.appendingPathComponent("\(id).wav")
        try? FileManager.default.removeItem(at: cached)
    }

    /// Deletes the whole local audiobook library through the authenticated
    /// backend, then removes only this client's derived-audio cache. The
    /// caller owns confirmation UI and active-playback coordination.
    func deleteAll() async throws {
        let request = try connection.request(path: "audiobook", method: "DELETE", timeout: 30)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw AudiobookServiceError.libraryDeletionFailed
        }
        try? FileManager.default.removeItem(at: cacheDir)
    }

    func cancel(_ id: String) async {
        guard let req = try? connection.request(path: "audiobook/\(id)/cancel", method: "POST") else {
            return
        }
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Fetch the transcript JSON (sections + page→time + per-page text).
    func transcript(for id: String) async throws -> Transcript {
        let req = try connection.request(path: "audiobook/\(id)/transcript", timeout: 15)
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(Transcript.self, from: data)
    }

    struct Transcript: Codable {
        let bookID: String
        let sections: [AudiobookSection]
        let pageToTime: [String: Double]
        let totalAudioSeconds: Double
        let pages: [String: String]
        /// Per-page marker for a page whose transcript text doesn't match
        /// its audio: "tts_failed" (synthesis failed, page is near-silent),
        /// "cleaning_failed" (Gemini cleanup failed), or "duplicate"
        /// (byte-identical page, skipped and marked "-" to avoid redundant
        /// cost). Absent for a normally-narrated page. Additive — older
        /// books simply have no entries here. See jira-audiobook-quality.md T-1.
        let pageStatus: [String: String]?

        enum CodingKeys: String, CodingKey {
            case bookID = "book_id"
            case sections
            case pageToTime = "page_to_time"
            case totalAudioSeconds = "total_audio_seconds"
            case pages
            case pageStatus = "page_status"
        }
    }

    // MARK: - Upload

    func upload(document: URL, voice: String?, speed: Double?, engine: String?) async throws -> AudiobookEstimateResponse {
        var req = try connection.request(path: "audiobook", method: "POST", timeout: 60)

        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let bodyURL = try Self.makeMultipartUploadBody(
            document: document,
            boundary: boundary,
            voice: voice,
            speed: speed,
            engine: engine
        )
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        // `upload(for:fromFile:)` streams the staged multipart body.  Do not
        // turn a user document into `Data`: a permitted 100 MiB import must
        // not also become a 100 MiB app-memory spike while the backend/model
        // is running.
        let (data, response) = try await URLSession.shared.upload(for: req, fromFile: bodyURL)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode([String: String].self, from: data))?["detail"] ?? "Upload failed"
            throw AudiobookServiceError.uploadFailed(detail)
        }
        return try JSONDecoder().decode(AudiobookEstimateResponse.self, from: data)
    }

    /// Materializes a multipart envelope on disk while copying the document in
    /// bounded chunks. The backend independently validates content and limits;
    /// this early check gives the user a fast, local error and avoids staging a
    /// request it will necessarily reject.
    private static func makeMultipartUploadBody(
        document: URL,
        boundary: String,
        voice: String?,
        speed: Double?,
        engine: String?
    ) throws -> URL {
        let maximumBytes = 100 * 1024 * 1024
        let documentSize = try document.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard documentSize > 0, documentSize <= maximumBytes else {
            throw AudiobookServiceError.uploadFailed("Choose a document up to 100 MiB.")
        }

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("Voqora-upload-\(UUID().uuidString).multipart")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }

        func write(_ string: String) throws {
            try output.write(contentsOf: Data(string.utf8))
        }
        func appendField(_ name: String, _ value: String) throws {
            try write("--\(boundary)\r\n")
            try write("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            try write(value)
            try write("\r\n")
        }

        do {
            if let voice {
                try appendField("voice", voice)
            }
            if let speed {
                try appendField("speed", String(speed))
            }
            if let engine {
                try appendField("engine", engine)
            }

            // A local filename cannot normally contain CR/LF, but removing
            // them prevents it ever becoming a multipart-header injection
            // primitive when a URL arrives from a nonstandard file provider.
            let filename = document.lastPathComponent
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\"", with: "'")
            try write("--\(boundary)\r\n")
            try write("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
            try write("Content-Type: \(mimeType(forFileExtension: document.pathExtension))\r\n\r\n")

            let input = try FileHandle(forReadingFrom: document)
            defer { try? input.close() }
            var copied = 0
            while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
                copied += chunk.count
                guard copied <= maximumBytes else {
                    throw AudiobookServiceError.uploadFailed("Choose a document up to 100 MiB.")
                }
                try output.write(contentsOf: chunk)
            }
            guard copied > 0 else {
                throw AudiobookServiceError.uploadFailed("The selected document is empty.")
            }
            try write("\r\n--\(boundary)--\r\n")
            try output.synchronize()
            return temporary
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    func retry(_ id: String, apiKey: String?) async throws -> Int {
        var req = try connection.request(path: "audiobook/\(id)/retry", method: "POST")
        if let apiKey, !apiKey.isEmpty {
            req.setValue(apiKey, forHTTPHeaderField: "X-Gemini-Api-Key")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw AudiobookServiceError.uploadFailed("Retry failed")
        }
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (obj["retried_pages"] as? Int) ?? 0
    }

    func resolveCostApproval(
        _ id: String,
        approve: Bool,
        newCapUSD: Double? = nil,
        apiKey: String? = nil
    ) async throws {
        var request = try connection.request(path: "audiobook/\(id)/cost-approval", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "X-Gemini-Api-Key")
        }
        var payload: [String: Any] = ["approve": approve]
        if let newCapUSD {
            payload["new_cap_usd"] = newCapUSD
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode([String: String].self, from: data))?["detail"] ?? "Could not apply the cost choice."
            throw AudiobookServiceError.uploadFailed(detail)
        }
    }

    // MARK: - Start

    func start(_ id: String, apiKey: String?, useGeminiCleanup: Bool) async throws {
        var req = try connection.request(path: "audiobook/\(id)/start", method: "POST")
        if useGeminiCleanup {
            req.setValue("true", forHTTPHeaderField: "X-Voqora-Gemini-Cleanup")
            if let apiKey, !apiKey.isEmpty {
                req.setValue(apiKey, forHTTPHeaderField: "X-Gemini-Api-Key")
            }
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode([String: String].self, from: data))?["detail"] ?? "Failed to start processing"
            throw AudiobookServiceError.uploadFailed(detail)
        }
    }

    // MARK: - SSE progress

    /// Stream SSE events as raw JSON dictionaries until done/failed.
    /// Auto-reconnects with exponential backoff if the connection drops while
    /// the book is still in a non-terminal state. Stops permanently on:
    ///   - terminal event (done/failed)
    ///   - HTTP 404 (book deleted) or 410
    ///   - task cancellation
    func subscribe(to id: String) -> AsyncStream<[String: Any]> {
        AsyncStream { continuation in
            let task = Task {
                var attempt = 0
                while !Task.isCancelled {
                    guard var req = try? self.connection.request(
                        path: "audiobook/\(id)/events", timeout: 0
                    ) else { break }
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    var sawTerminal = false
                    var bookGone = false
                    do {
                        let (bytes, response) = try await URLSession.shared.bytes(for: req)
                        // C6: backend returns 404 for deleted books — bail out
                        // of the reconnect loop instead of spinning forever.
                        if let http = response as? HTTPURLResponse,
                           http.statusCode == 404 || http.statusCode == 410
                        {
                            bookGone = true
                        } else {
                            for try await line in bytes.lines {
                                if Task.isCancelled {
                                    break
                                }
                                guard line.hasPrefix("data: ") else { continue }
                                let json = String(line.dropFirst(6))
                                guard let data = json.data(using: .utf8),
                                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                                else { continue }
                                continuation.yield(obj)
                                if let type = obj["type"] as? String,
                                   type == "done" || type == "failed" || type == "cancelled"
                                {
                                    sawTerminal = true
                                    break
                                }
                            }
                        }
                    } catch {
                        VoqoraLog.warn("AudiobookService", "SSE connection dropped", ["bookID": id, "failureCode": "event_stream_disconnected", "attempt": "\(attempt)"])
                    }
                    if sawTerminal || bookGone || Task.isCancelled {
                        break
                    }
                    attempt = min(attempt + 1, 4)
                    let delay = UInt64(pow(2.0, Double(attempt - 1)) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: delay)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Audio caching + cover

    /// Download audio.wav once to local cache, return file URL.
    /// S9: validates HTTP status, content-type, expected size, AND a quick
    /// WAV magic-byte sanity check before promoting the temp file to the
    /// cache. If a previous failed download left a stale file, re-fetches.
    func ensureLocalAudio(for id: String) async throws -> URL {
        let local = cacheDir.appendingPathComponent("\(id).wav")
        if FileManager.default.fileExists(atPath: local.path),
           Self.isValidWAVHeader(at: local)
        {
            return local
        }
        // Drop a corrupt cache file before re-fetching.
        try? FileManager.default.removeItem(at: local)

        let request = try connection.request(path: "audiobook/\(id)/audio", timeout: 60)
        let (downloadedURL, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: downloadedURL) }

        guard let http = response as? HTTPURLResponse else {
            throw AudiobookServiceError.audioNotReady
        }
        guard http.statusCode == 200 else {
            throw AudiobookServiceError.audioNotReady
        }
        // Content-type sanity (be permissive — server says audio/wav today).
        if let ct = http.value(forHTTPHeaderField: "Content-Type"),
           !ct.lowercased().contains("audio"), !ct.lowercased().contains("wav")
        {
            throw AudiobookServiceError.audioNotReady
        }
        // Expected size (Content-Length). FileResponse sets this; range
        // responses set it for the slice. We only follow non-range here.
        if let lenStr = http.value(forHTTPHeaderField: "Content-Length"),
           let expected = Int(lenStr)
        {
            let actual = (try? FileManager.default.attributesOfItem(atPath: downloadedURL.path)[.size] as? Int) ?? 0
            if abs(actual - expected) > 64 {
                throw AudiobookServiceError.audioNotReady
            }
        }
        // WAV magic-byte sanity check: "RIFF" .. "WAVE".
        guard Self.isValidWAVHeader(at: downloadedURL) else {
            throw AudiobookServiceError.audioNotReady
        }
        try FileManager.default.moveItem(at: downloadedURL, to: local)
        return local
    }

    /// Quick header check: bytes 0..3 == "RIFF" and bytes 8..11 == "WAVE".
    private static func isValidWAVHeader(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 12), header.count >= 12 else { return false }
        let riff = header.subdata(in: 0 ..< 4)
        let wave = header.subdata(in: 8 ..< 12)
        return riff == "RIFF".data(using: .ascii) && wave == "WAVE".data(using: .ascii)
    }

    func coverPath(for id: String) -> String {
        "audiobook/\(id)/cover"
    }

    // MARK: - Key verification

    func verifyKey(_ key: String) async -> Bool {
        guard var req = try? connection.request(
            path: "audiobook/verify_key", method: "POST", timeout: 15
        ) else { return false }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["api_key": key])
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return (obj["verified"] as? Bool) ?? false
    }
}

enum AudiobookServiceError: LocalizedError {
    case uploadFailed(String)
    case audioNotReady
    case decodeFailed
    case libraryDeletionFailed

    var errorDescription: String? {
        switch self {
        case let .uploadFailed(msg): msg
        case .audioNotReady: "Audio is not ready yet."
        case .decodeFailed: "Could not decode response."
        case .libraryDeletionFailed: "Voqora could not delete the local audiobook library."
        }
    }
}

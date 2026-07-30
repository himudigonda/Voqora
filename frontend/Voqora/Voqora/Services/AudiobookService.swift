import AppKit
import Foundation

/// HTTP client for the audiobook backend endpoints. SSE consumer.
final class AudiobookService: NSObject, @unchecked Sendable {
    private let baseURL = URL(string: "http://127.0.0.1:10101")!

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
        var req = URLRequest(url: baseURL.appendingPathComponent("audiobook"))
        req.timeoutInterval = 10
        let (data, _) = try await URLSession.shared.data(for: req)
        // Decode each entry individually so one corrupt/partial book (e.g. a ghost
        // entry left by a failed upload) doesn't poison the whole library load.
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return try JSONDecoder().decode([Audiobook].self, from: data)
        }
        let decoder = JSONDecoder()
        return items.compactMap { dict in
            guard let itemData = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
            if let book = try? decoder.decode(Audiobook.self, from: itemData) { return book }
            if let id = dict["book_id"] as? String {
                print("⚠️ AudiobookService: skipping corrupt entry for book_id=\(id)")
            }
            return nil
        }
    }

    func get(_ id: String) async throws -> Audiobook {
        var req = URLRequest(url: baseURL.appendingPathComponent("audiobook/\(id)"))
        req.timeoutInterval = 10
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(Audiobook.self, from: data)
    }

    func delete(_ id: String) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("audiobook/\(id)"))
        req.httpMethod = "DELETE"
        req.timeoutInterval = 10
        _ = try await URLSession.shared.data(for: req)
        let cached = cacheDir.appendingPathComponent("\(id).wav")
        try? FileManager.default.removeItem(at: cached)
    }

    func cancel(_ id: String) async {
        var req = URLRequest(url: baseURL.appendingPathComponent("audiobook/\(id)/cancel"))
        req.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Fetch the transcript JSON (sections + page→time + per-page text).
    func transcript(for id: String) async throws -> Transcript {
        var req = URLRequest(url: baseURL.appendingPathComponent("audiobook/\(id)/transcript"))
        req.timeoutInterval = 15  // slightly longer: transcript JSON can be large for big books
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(Transcript.self, from: data)
    }

    struct Transcript: Codable {
        let bookID: String
        let sections: [AudiobookSection]
        let pageToTime: [String: Double]
        let totalAudioSeconds: Double
        let pages: [String: String]

        enum CodingKeys: String, CodingKey {
            case bookID = "book_id"
            case sections
            case pageToTime = "page_to_time"
            case totalAudioSeconds = "total_audio_seconds"
            case pages
        }
    }

    // MARK: - Upload

    func upload(pdf: URL, voice: String?, speed: Double?, engine: String?) async throws -> AudiobookEstimateResponse {
        let url = baseURL.appendingPathComponent("audiobook")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60

        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let pdfData = try Data(contentsOf: pdf)
        let filename = pdf.lastPathComponent

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append(value.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }
        if let voice { appendField("voice", voice) }
        if let speed { appendField("speed", String(speed)) }
        if let engine { appendField("engine", engine) }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/pdf\r\n\r\n".data(using: .utf8)!)
        body.append(pdfData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode([String: String].self, from: data))?["detail"] ?? "Upload failed"
            throw AudiobookServiceError.uploadFailed(detail)
        }
        return try JSONDecoder().decode(AudiobookEstimateResponse.self, from: data)
    }

    func retry(_ id: String, apiKey: String?) async throws -> Int {
        let url = baseURL.appendingPathComponent("audiobook/\(id)/retry")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        if let apiKey, !apiKey.isEmpty {
            req.setValue(apiKey, forHTTPHeaderField: "X-Gemini-Api-Key")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AudiobookServiceError.uploadFailed("Retry failed")
        }
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (obj["retried_pages"] as? Int) ?? 0
    }

    // MARK: - Start

    func start(_ id: String, apiKey: String?, useGeminiCleanup: Bool) async throws {
        let url = baseURL.appendingPathComponent("audiobook/\(id)/start")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        if useGeminiCleanup {
            req.setValue("true", forHTTPHeaderField: "X-Voqora-Gemini-Cleanup")
            if let apiKey, !apiKey.isEmpty {
                req.setValue(apiKey, forHTTPHeaderField: "X-Gemini-Api-Key")
            }
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
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
                let url = baseURL.appendingPathComponent("audiobook/\(id)/events")
                var attempt = 0
                while !Task.isCancelled {
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 0
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    var sawTerminal = false
                    var bookGone = false
                    do {
                        let (bytes, response) = try await URLSession.shared.bytes(for: req)
                        // C6: backend returns 404 for deleted books — bail out
                        // of the reconnect loop instead of spinning forever.
                        if let http = response as? HTTPURLResponse,
                           http.statusCode == 404 || http.statusCode == 410 {
                            bookGone = true
                        } else {
                            for try await line in bytes.lines {
                                if Task.isCancelled { break }
                                guard line.hasPrefix("data: ") else { continue }
                                let json = String(line.dropFirst(6))
                                guard let data = json.data(using: .utf8),
                                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                                else { continue }
                                continuation.yield(obj)
                                if let type = obj["type"] as? String,
                                   type == "done" || type == "failed" || type == "cancelled" {
                                    sawTerminal = true
                                    break
                                }
                            }
                        }
                    } catch {
                        print("[AudiobookService] SSE drop for \(id): \(error)")
                    }
                    if sawTerminal || bookGone || Task.isCancelled { break }
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
           Self.isValidWAVHeader(at: local) {
            return local
        }
        // Drop a corrupt cache file before re-fetching.
        try? FileManager.default.removeItem(at: local)

        let url = baseURL.appendingPathComponent("audiobook/\(id)/audio")
        let (downloadedURL, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: downloadedURL) }

        guard let http = response as? HTTPURLResponse else {
            throw AudiobookServiceError.audioNotReady
        }
        guard http.statusCode == 200 else {
            throw AudiobookServiceError.audioNotReady
        }
        // Content-type sanity (be permissive — server says audio/wav today).
        if let ct = http.value(forHTTPHeaderField: "Content-Type"),
           !ct.lowercased().contains("audio") && !ct.lowercased().contains("wav") {
            throw AudiobookServiceError.audioNotReady
        }
        // Expected size (Content-Length). FileResponse sets this; range
        // responses set it for the slice. We only follow non-range here.
        if let lenStr = http.value(forHTTPHeaderField: "Content-Length"),
           let expected = Int(lenStr) {
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
        let riff = header.subdata(in: 0..<4)
        let wave = header.subdata(in: 8..<12)
        return riff == "RIFF".data(using: .ascii) && wave == "WAVE".data(using: .ascii)
    }

    func coverURL(for id: String) -> URL {
        baseURL.appendingPathComponent("audiobook/\(id)/cover")
    }

    // MARK: - Key verification

    func verifyKey(_ key: String) async -> Bool {
        let url = baseURL.appendingPathComponent("audiobook/verify_key")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
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

    var errorDescription: String? {
        switch self {
        case .uploadFailed(let msg): return msg
        case .audioNotReady: return "Audio is not ready yet."
        case .decodeFailed: return "Could not decode response."
        }
    }
}

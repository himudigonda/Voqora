import Foundation

nonisolated struct MultipartFilePart: Equatable, Sendable {
    let name: String
    let filename: String
    let contentType: String
    let source: URL
}

nonisolated enum MultipartFormWriter {
    static let chunkSize = 1_048_576

    static func makeBoundary() -> String {
        "Boundary-\(UUID().uuidString)"
    }

    static func contentType(boundary: String) -> String {
        "multipart/form-data; boundary=\(boundary)"
    }

    static func singleLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    static func headerSafe(_ value: String) -> String {
        singleLine(value).replacingOccurrences(of: "\"", with: "'")
    }

    static func write(fields: [(String, String)], file: MultipartFilePart, boundary: String, to destination: URL) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            func emit(_ string: String) throws {
                try output.write(contentsOf: Data(string.utf8))
            }
            for (name, value) in fields {
                try emit("--\(boundary)\r\n")
                try emit("Content-Disposition: form-data; name=\"\(headerSafe(name))\"\r\n\r\n")
                try emit(singleLine(value))
                try emit("\r\n")
            }
            try emit("--\(boundary)\r\n")
            try emit("Content-Disposition: form-data; name=\"\(headerSafe(file.name))\"; filename=\"\(headerSafe(file.filename))\"\r\n")
            try emit("Content-Type: \(file.contentType)\r\n\r\n")
            let input = try FileHandle(forReadingFrom: file.source)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            try emit("\r\n--\(boundary)--\r\n")
            try output.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}

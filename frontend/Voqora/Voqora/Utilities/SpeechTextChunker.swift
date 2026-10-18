import Foundation

nonisolated enum SpeechTextChunker {
    static let maximumScalars = 48000
    private static let boundaries = ["\n\n", "\n", ". ", "! ", "? ", "; ", ", ", " "]

    static func chunks(of text: String, limit: Int = maximumScalars) -> [String] {
        guard limit > 0 else { return [text] }
        var chunks: [String] = []
        var remaining = Substring(text)
        while remaining.unicodeScalars.count > limit {
            let window = remaining[..<windowEnd(in: remaining, limit: limit)]
            let cut = boundaryEnd(in: window) ?? window.endIndex
            guard cut > remaining.startIndex else { break }
            appendTrimmed(remaining[..<cut], to: &chunks)
            remaining = remaining[cut...]
        }
        appendTrimmed(remaining, to: &chunks)
        return chunks
    }

    private static func windowEnd(in text: Substring, limit: Int) -> Substring.Index {
        var scalars = 0
        var end = text.startIndex
        for index in text.indices {
            let size = text[index].unicodeScalars.count
            guard scalars + size <= limit else { break }
            scalars += size
            end = text.index(after: index)
        }
        return end == text.startIndex ? text.index(after: text.startIndex) : end
    }

    private static func boundaryEnd(in window: Substring) -> Substring.Index? {
        let minimumOffset = window.count / 2
        let earliest = window.index(window.startIndex, offsetBy: minimumOffset)
        for boundary in boundaries {
            if let range = window.range(of: boundary, options: .backwards), range.upperBound > earliest {
                return range.upperBound
            }
        }
        return nil
    }

    private static func appendTrimmed(_ piece: Substring, to chunks: inout [String]) {
        let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            chunks.append(trimmed)
        }
    }
}

enum ChunkedSpeechStream {
    static let wavHeaderBytes = 44

    static func make(
        chunks: [String],
        stream: @escaping (String) -> AsyncThrowingStream<Data, Error>
    ) -> AsyncThrowingStream<Data, Error> {
        guard chunks.count > 1 else {
            return stream(chunks.first ?? "")
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for (index, chunk) in chunks.enumerated() {
                        var headerBytesToSkip = index == 0 ? 0 : wavHeaderBytes
                        for try await data in stream(chunk) {
                            try Task.checkCancellation()
                            guard headerBytesToSkip > 0 else {
                                continuation.yield(data)
                                continue
                            }
                            let skipped = min(headerBytesToSkip, data.count)
                            headerBytesToSkip -= skipped
                            if skipped < data.count {
                                continuation.yield(data.subdata(in: data.startIndex + skipped ..< data.endIndex))
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

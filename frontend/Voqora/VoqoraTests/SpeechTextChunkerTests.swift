import Foundation
@testable import Voqora
import XCTest

final class SpeechTextChunkerTests: XCTestCase {
    func test_shortTextStaysInOneChunk() {
        XCTAssertEqual(SpeechTextChunker.chunks(of: "  Hello there.  ", limit: 100), ["Hello there."])
    }

    func test_emptyTextHasNoChunks() {
        XCTAssertEqual(SpeechTextChunker.chunks(of: " \n ", limit: 100), [])
    }

    func test_longTextSplitsAtParagraphsFirst() {
        let first = String(repeating: "a", count: 30)
        let second = String(repeating: "b", count: 30)
        let text = "\(first)\n\n\(second)"

        XCTAssertEqual(SpeechTextChunker.chunks(of: text, limit: 40), [first, second])
    }

    func test_longParagraphsSplitAtSentenceEnds() {
        let text = "One two three four five. Six seven eight nine ten."

        let chunks = SpeechTextChunker.chunks(of: text, limit: 30)

        XCTAssertEqual(chunks, ["One two three four five.", "Six seven eight nine ten."])
    }

    func test_everyChunkFitsTheLimitAndNoTextIsLost() {
        let text = (0 ..< 200).map { "Sentence number \($0) has a few words." }.joined(separator: " ")

        let chunks = SpeechTextChunker.chunks(of: text, limit: 120)

        XCTAssertTrue(chunks.count > 1)
        XCTAssertTrue(chunks.allSatisfy { $0.unicodeScalars.count <= 120 })
        XCTAssertEqual(chunks.joined(separator: " "), text)
    }

    func test_unbrokenTextIsCutHard() {
        let text = String(repeating: "x", count: 25)

        XCTAssertEqual(SpeechTextChunker.chunks(of: text, limit: 10).map(\.count), [10, 10, 5])
    }

    func test_limitCountsUnicodeScalarsLikeTheBackend() {
        let text = String(repeating: "👩‍👩‍👧", count: 4)

        let chunks = SpeechTextChunker.chunks(of: text, limit: 10)

        XCTAssertTrue(chunks.allSatisfy { $0.unicodeScalars.count <= 10 })
        XCTAssertEqual(chunks.joined(), text)
    }
}

@MainActor
final class ChunkedSpeechStreamTests: XCTestCase {
    private func stream(of parts: [Data]) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            for part in parts {
                continuation.yield(part)
            }
            continuation.finish()
        }
    }

    private func collect(_ stream: AsyncThrowingStream<Data, Error>) async throws -> Data {
        var collected = Data()
        for try await part in stream {
            collected.append(part)
        }
        return collected
    }

    func test_singleChunkPassesTheStreamThrough() async throws {
        var requested: [String] = []
        let header = Data(repeating: 1, count: ChunkedSpeechStream.wavHeaderBytes)

        let combined = ChunkedSpeechStream.make(chunks: ["only"]) { text in
            requested.append(text)
            return self.stream(of: [header, Data([9, 9])])
        }

        let output = try await collect(combined)
        XCTAssertEqual(requested, ["only"])
        XCTAssertEqual(output, header + Data([9, 9]))
    }

    func test_laterChunksDropTheirWAVHeaders() async throws {
        var requested: [String] = []
        let firstHeader = Data(repeating: 1, count: ChunkedSpeechStream.wavHeaderBytes)
        let laterHeader = Data(repeating: 2, count: ChunkedSpeechStream.wavHeaderBytes)

        let combined = ChunkedSpeechStream.make(chunks: ["one", "two"]) { text in
            requested.append(text)
            if text == "one" {
                return self.stream(of: [firstHeader, Data([5, 5])])
            }
            return self.stream(of: [laterHeader.prefix(10), laterHeader.suffix(34) + Data([7, 7])])
        }

        let output = try await collect(combined)
        XCTAssertEqual(requested, ["one", "two"])
        XCTAssertEqual(output, firstHeader + Data([5, 5, 7, 7]))
    }

    func test_failuresEndTheCombinedStream() async {
        let combined = ChunkedSpeechStream.make(chunks: ["one", "two"]) { _ in
            AsyncThrowingStream { continuation in
                continuation.finish(throwing: URLError(.cannotConnectToHost))
            }
        }

        do {
            _ = try await collect(combined)
            XCTFail("Expected the stream to fail")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
        }
    }
}

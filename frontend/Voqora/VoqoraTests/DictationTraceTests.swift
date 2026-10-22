@testable import Voqora
import XCTest

final class DictationTraceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation-trace-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func sessionFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func lines(of url: URL) throws -> [[String: Any]] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    }

    func test_sessionWritesParseableJSONLInOrderWithFullText() throws {
        let writer = DictationTraceWriter(directory: directory, includesText: true)
        writer.beginSession(engine: "analyzer", locale: "en_US")
        writer.event("analyzer.result", ["text": "hello brave world", "isFinal": "false"])
        writer.event("analyzer.result", ["text": "hello brave new world", "isFinal": "true"])
        writer.endSession(outcome: "pasted")
        writer.flush()

        let files = try sessionFiles()
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].lastPathComponent.hasPrefix("session-"))
        let entries = try lines(of: files[0])
        XCTAssertEqual(entries.compactMap { $0["name"] as? String }, ["session.begin", "analyzer.result", "analyzer.result", "session.end"])
        let results = entries.compactMap { $0["fields"] as? [String: String] }
        XCTAssertEqual(results[1]["text"], "hello brave world")
        XCTAssertEqual(results[2]["text"], "hello brave new world")
        XCTAssertEqual(results[3]["outcome"], "pasted")
        XCTAssertEqual(results[0]["engine"], "analyzer")
        let milliseconds = entries.compactMap { $0["ms"] as? Int }
        XCTAssertEqual(milliseconds.count, entries.count)
        XCTAssertEqual(milliseconds, milliseconds.sorted())
        XCTAssertTrue(entries.allSatisfy { ($0["ts"] as? String)?.isEmpty == false })
    }

    func test_textIsReplacedByCountsWhenNotIncluded() throws {
        let writer = DictationTraceWriter(directory: directory, includesText: false)
        writer.beginSession(engine: "legacy", locale: nil)
        writer.event("legacy.restart_detected", ["previousText": "one two three", "newText": "four", "task": "2"])
        writer.event("insert.requested", ["text": "secret words here", "mode": "paste"])
        writer.flush()

        let entries = try lines(of: XCTUnwrap(sessionFiles().first))
        let restart = try XCTUnwrap(entries[1]["fields"] as? [String: String])
        XCTAssertNil(restart["previousText"])
        XCTAssertEqual(restart["previousTextChars"], "13")
        XCTAssertEqual(restart["previousTextWords"], "3")
        XCTAssertEqual(restart["newTextWords"], "1")
        XCTAssertEqual(restart["task"], "2")
        let insert = try XCTUnwrap(entries[2]["fields"] as? [String: String])
        XCTAssertNil(insert["text"])
        XCTAssertEqual(insert["textChars"], "17")
        XCTAssertEqual(insert["textWords"], "3")
        XCTAssertEqual(insert["mode"], "paste")
        let raw = try String(contentsOf: XCTUnwrap(sessionFiles().first), encoding: .utf8)
        XCTAssertFalse(raw.contains("secret"))
    }

    func test_mirrorNeverReceivesText() {
        final class Collected: @unchecked Sendable {
            let lock = NSLock()
            var lines: [[String: String]] = []
        }
        let collected = Collected()
        let writer = DictationTraceWriter(directory: directory, includesText: true) { _, fields in
            collected.lock.withLock { collected.lines.append(fields) }
        }
        writer.beginSession(engine: "legacy", locale: nil)
        writer.event("legacy.final", ["text": "private words"])
        writer.flush()

        let mirrored = collected.lock.withLock { collected.lines }
        XCTAssertEqual(mirrored.count, 2)
        XCTAssertNil(mirrored[1]["text"])
        XCTAssertEqual(mirrored[1]["textChars"], "13")
    }

    func test_retentionKeepsTwentyNewestSessions() throws {
        let writer = DictationTraceWriter(directory: directory, includesText: true)
        for index in 0 ..< 25 {
            writer.beginSession(engine: "analyzer", locale: "session-\(index)")
            writer.endSession(outcome: "done")
        }
        writer.flush()

        let files = try sessionFiles()
        XCTAssertEqual(files.count, 20)
        let locales = try files.map { try XCTUnwrap(lines(of: $0).first?["fields"] as? [String: String])["locale"] }
        XCTAssertEqual(locales, (5 ..< 25).map { "session-\($0)" })
    }

    func test_concurrentWritesFromEightThreadsStayIntact() throws {
        let writer = DictationTraceWriter(directory: directory, includesText: true)
        let perThread = 250
        writer.beginSession(engine: "analyzer", locale: "en_US")
        DispatchQueue.concurrentPerform(iterations: 8) { thread in
            for index in 0 ..< perThread {
                writer.event("tick", ["thread": "\(thread)", "index": "\(index)", "text": "line \(thread) \(index)"])
            }
        }
        writer.endSession(outcome: "done")
        writer.flush()

        let entries = try lines(of: XCTUnwrap(sessionFiles().first))
        let ticks = entries.filter { $0["name"] as? String == "tick" }
        XCTAssertEqual(ticks.count, 8 * perThread)
        for thread in 0 ..< 8 {
            let indices = ticks
                .compactMap { $0["fields"] as? [String: String] }
                .filter { $0["thread"] == "\(thread)" }
                .compactMap { $0["index"].flatMap(Int.init) }
            XCTAssertEqual(indices, Array(0 ..< perThread))
        }
    }

    func test_eventsOutsideASessionAreDropped() {
        let writer = DictationTraceWriter(directory: directory, includesText: true)
        writer.event("orphan")
        writer.endSession(outcome: "none")
        writer.flush()
        XCTAssertTrue(((try? sessionFiles()) ?? []).isEmpty)
    }

    func test_debugBuildsTraceByDefault() {
        #if DEBUG
            XCTAssertTrue(DictationTrace.isEnabled)
        #else
            XCTAssertEqual(DictationTrace.isEnabled, UserDefaults.standard.bool(forKey: DictationTrace.defaultsKey))
        #endif
    }
}

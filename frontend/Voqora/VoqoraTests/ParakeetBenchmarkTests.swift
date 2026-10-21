import Foundation
@testable import Voqora
import XCTest

@MainActor
final class ParakeetBenchmarkTests: XCTestCase {
    func test_benchmarkPrintsOneJSONLine() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let audioPath = environment["VOQORA_BENCH_AUDIO"], let referencePath = environment["VOQORA_BENCH_REFERENCE"] else {
            throw XCTSkip("Set TEST_RUNNER_VOQORA_BENCH_AUDIO and TEST_RUNNER_VOQORA_BENCH_REFERENCE to run the benchmark")
        }
        let reference = try String(contentsOfFile: referencePath, encoding: .utf8)
        let footprintBefore = ParakeetReplay.footprintMB()
        let transcriber = try await ParakeetReplay.installedTranscriber()
        let outcome = try await ParakeetReplay.run(url: URL(fileURLWithPath: audioPath), transcriber: transcriber)
        let score = TranscriptScoring.score(reference: reference, hypothesis: outcome.transcript)

        let finals = outcome.events.filter {
            if case .finalized = $0 {
                true
            } else {
                false
            }
        }.count
        let fields: [(String, String)] = [
            ("wer", String(format: "%.4f", score.wordErrorRate)),
            ("droppedSentences", "\(score.droppedSentences)"),
            ("repeatedInsertions", "\(score.repeatedInsertions)"),
            ("substitutions", "\(score.substitutions)"),
            ("deletions", "\(score.deletions)"),
            ("insertions", "\(score.insertions)"),
            ("referenceWords", "\(score.referenceWords)"),
            ("wallSeconds", String(format: "%.2f", outcome.wallSeconds)),
            ("audioSeconds", String(format: "%.2f", outcome.audioSeconds)),
            ("rtfx", String(format: "%.1f", outcome.audioSeconds / outcome.wallSeconds)),
            ("footprintBeforeMB", String(format: "%.0f", footprintBefore)),
            ("footprintAfterMB", String(format: "%.0f", ParakeetReplay.footprintMB())),
            ("footprintPeakMB", String(format: "%.0f", outcome.peakFootprintMB)),
            ("finalSegments", "\(finals)"),
            ("ended", "\(outcome.events.last == .ended)"),
        ]
        let line = "{" + fields.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}"
        print("PARAKEET_BENCH \(line)")
        if let outputPath = environment["VOQORA_BENCH_OUTPUT"] {
            try line.write(toFile: outputPath, atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(outcome.events.last, .ended)
    }
}

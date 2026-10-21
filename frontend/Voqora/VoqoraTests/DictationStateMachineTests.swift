@testable import Voqora
import XCTest

final class DictationStateMachineTests: XCTestCase {
    private func listeningMachine() -> DictationStateMachine {
        var machine = DictationStateMachine()
        _ = machine.handle(.toggle)
        _ = machine.handle(.ready)
        return machine
    }

    func test_toggleFromIdlePreparesAFreshSession() {
        var machine = DictationStateMachine()

        XCTAssertEqual(machine.handle(.toggle), .prepare)
        XCTAssertEqual(machine.phase, .preparing)
        XCTAssertEqual(machine.transcript, "")
    }

    func test_readyMovesPreparingToListening() {
        let machine = listeningMachine()

        XCTAssertEqual(machine.phase, .listening)
    }

    func test_readyAfterCancelAsksToStopTheRecognizer() {
        var machine = DictationStateMachine()
        _ = machine.handle(.toggle)

        XCTAssertEqual(machine.handle(.cancel), .stop)
        XCTAssertEqual(machine.handle(.ready), .stop)
        XCTAssertEqual(machine.phase, .idle)
    }

    func test_partialResultsUpdateTheLiveTranscript() {
        var machine = listeningMachine()

        XCTAssertEqual(machine.handle(.volatileChanged("hello there")), .nothing)
        XCTAssertEqual(machine.transcript, "hello there")
    }

    func test_secondToggleFinishesListening() {
        var machine = listeningMachine()

        XCTAssertEqual(machine.handle(.toggle), .finishListening)
        XCTAssertEqual(machine.phase, .finishing)
    }

    func test_silenceFinishesOnlyWhileListening() {
        var machine = listeningMachine()

        XCTAssertEqual(machine.handle(.silenceDetected), .finishListening)
        XCTAssertEqual(machine.handle(.silenceDetected), .nothing)
        XCTAssertEqual(machine.phase, .finishing)
    }

    func test_finalResultInsertsTrimmedTranscript() {
        var machine = listeningMachine()
        _ = machine.handle(.toggle)

        _ = machine.handle(.segmentFinalized("  Hello there.  "))
        XCTAssertEqual(machine.handle(.recognitionEnded), .insert("Hello there."))
        XCTAssertEqual(machine.phase, .inserting)
        XCTAssertEqual(machine.handle(.insertionFinished), .nothing)
        XCTAssertEqual(machine.phase, .idle)
    }

    func test_emptyFinalResultReportsNothingHeard() {
        var machine = listeningMachine()
        _ = machine.handle(.toggle)

        _ = machine.handle(.segmentFinalized("   "))
        XCTAssertEqual(machine.handle(.recognitionEnded), .report(.nothingHeard))
        XCTAssertEqual(machine.phase, .idle)
    }

    func test_failureWithPartialTranscriptStillInsertsWhatWasHeard() {
        var machine = listeningMachine()
        _ = machine.handle(.volatileChanged("Half a thought"))

        XCTAssertEqual(machine.handle(.recognitionFailed), .insert("Half a thought"))
    }

    func test_failureWithoutTranscriptReportsRecognitionFailure() {
        var machine = listeningMachine()

        XCTAssertEqual(machine.handle(.recognitionFailed), .report(.recognitionFailed))
    }

    func test_failureWhileFinishingWithoutTranscriptReportsNothingHeard() {
        var machine = listeningMachine()
        _ = machine.handle(.toggle)

        XCTAssertEqual(machine.handle(.recognitionFailed), .report(.nothingHeard))
    }

    func test_finishTimeoutInsertsTheLatestTranscript() {
        var machine = listeningMachine()
        _ = machine.handle(.volatileChanged("Almost done"))
        _ = machine.handle(.toggle)

        XCTAssertEqual(machine.handle(.finishTimedOut), .insert("Almost done"))
    }

    func test_finishTimeoutIsIgnoredOutsideFinishing() {
        var machine = listeningMachine()

        XCTAssertEqual(machine.handle(.finishTimedOut), .nothing)
        XCTAssertEqual(machine.phase, .listening)
    }

    func test_toggleWhileFinishingInsertsWithoutWaiting() {
        var machine = listeningMachine()
        _ = machine.handle(.volatileChanged("Quick note"))
        _ = machine.handle(.toggle)

        XCTAssertEqual(machine.handle(.toggle), .insert("Quick note"))
    }

    func test_toggleWhileInsertingIsIgnored() {
        var machine = listeningMachine()
        _ = machine.handle(.segmentFinalized("Done"))
        _ = machine.handle(.recognitionEnded)

        XCTAssertEqual(machine.handle(.toggle), .nothing)
        XCTAssertEqual(machine.handle(.cancel), .nothing)
        XCTAssertEqual(machine.phase, .inserting)
    }

    func test_abandoningWhileInsertingReturnsToIdleAndClearsTheTranscript() {
        var machine = listeningMachine()
        _ = machine.handle(.segmentFinalized("Done"))
        _ = machine.handle(.recognitionEnded)

        XCTAssertEqual(machine.handle(.abandonInsertion), .nothing)
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertEqual(machine.transcript, "")
        XCTAssertEqual(machine.handle(.insertionFinished), .nothing)
    }

    func test_abandoningOutsideInsertingDoesNothing() {
        var machine = listeningMachine()

        XCTAssertEqual(machine.handle(.abandonInsertion), .nothing)
        XCTAssertEqual(machine.phase, .listening)
    }

    func test_permissionFailureWhilePreparingReportsTheIssue() {
        var machine = DictationStateMachine()
        _ = machine.handle(.toggle)

        XCTAssertEqual(machine.handle(.failed(.microphoneDenied)), .report(.microphoneDenied))
        XCTAssertEqual(machine.phase, .idle)
    }

    func test_cancelWhileListeningDiscardsTheTranscript() {
        var machine = listeningMachine()
        _ = machine.handle(.volatileChanged("Never mind"))

        XCTAssertEqual(machine.handle(.cancel), .stop)
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertEqual(machine.transcript, "")
    }

    func test_eventsWhileIdleDoNothing() {
        var machine = DictationStateMachine()

        XCTAssertEqual(machine.handle(.volatileChanged("stray")), .nothing)
        XCTAssertEqual(machine.handle(.segmentFinalized("stray")), .nothing)
        XCTAssertEqual(machine.handle(.recognitionEnded), .nothing)
        XCTAssertEqual(machine.handle(.failed(.recognitionFailed)), .nothing)
        XCTAssertEqual(machine.handle(.cancel), .nothing)
        XCTAssertEqual(machine.phase, .idle)
    }
}

import AVFoundation
@testable import Voqora
import XCTest

final class FakeRecognitionTarget: RecognitionAudioTarget, @unchecked Sendable {
    private(set) var received: [AVAudioPCMBuffer] = []
    private(set) var ended = false

    func append(_ buffer: AVAudioPCMBuffer) {
        received.append(buffer)
    }

    func endAudio() {
        ended = true
    }
}

final class LegacyRestartTests: XCTestCase {
    private func buffer(seconds: Double = 0.1, sampleRate: Double = 16000) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false))
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        return buffer
    }

    private func ledgerText(_ partials: [String], final: String) -> String {
        var segmenter = LegacyTranscriptSegmenter()
        var ledger = DictationLedger()
        let apply: (SpeechRecognitionEvent) -> Void = { event in
            switch event {
            case let .volatile(text): ledger.revise(text)
            case let .finalized(text): ledger.commit(text)
            default: break
            }
        }
        partials.forEach { segmenter.ingest($0).forEach(apply) }
        segmenter.finalize(final).forEach(apply)
        return ledger.text
    }

    func test_shortFirstSentenceFollowedByANewOneIsARestart() {
        XCTAssertTrue(LegacyTranscriptSegmenter.isRestart(previous: "Okay.", next: "send it"))
        XCTAssertTrue(LegacyTranscriptSegmenter.isRestart(previous: "Thank you.", next: "Send it now"))
        XCTAssertTrue(LegacyTranscriptSegmenter.isRestart(previous: "Yes.", next: "Next"))
    }

    func test_longerReplacementOfSimilarLengthIsARestart() {
        XCTAssertTrue(LegacyTranscriptSegmenter.isRestart(previous: "The meeting is at nine", next: "The budget is approved now"))
        XCTAssertTrue(LegacyTranscriptSegmenter.isRestart(previous: "Hello there friend", next: "We need to"))
    }

    func test_collapseToAFewWordsIsARestart() {
        XCTAssertTrue(LegacyTranscriptSegmenter.isRestart(previous: "The payment flow still has", next: "The"))
    }

    func test_revisionsAndGrowthAreNotRestarts() {
        XCTAssertFalse(LegacyTranscriptSegmenter.isRestart(previous: "Hello", next: "Hi"))
        XCTAssertFalse(LegacyTranscriptSegmenter.isRestart(previous: "I scream for", next: "Ice cream for"))
        XCTAssertFalse(LegacyTranscriptSegmenter.isRestart(previous: "There are a lot", next: "Their a lot"))
        XCTAssertFalse(LegacyTranscriptSegmenter.isRestart(previous: "Next", next: "Next point is"))
        XCTAssertFalse(LegacyTranscriptSegmenter.isRestart(previous: "Send it", next: "Send it"))
        XCTAssertFalse(LegacyTranscriptSegmenter.isRestart(previous: "", next: "Send it"))
    }

    func test_oneWordHypothesisIsStillCommittedOnAReset() {
        XCTAssertEqual(ledgerText(["Yes.", "Next", "Next point is"], final: "Next point is"), "Yes. Next point is")
    }

    func test_resetsKeepEveryUtterance() {
        let thanks = ledgerText(["Thank you.", "Okay so we", "Okay so we start"], final: "Okay so we start")
        XCTAssertTrue(thanks.contains("Thank you."))
        XCTAssertTrue(thanks.contains("Okay so we start"))

        let hello = ledgerText(["Hello there friend", "We need to", "We need to ship"], final: "We need to ship")
        XCTAssertTrue(hello.contains("Hello there friend"))
        XCTAssertTrue(hello.contains("We need to ship"))
    }

    func test_shortPrefixSimilarFragmentAfterALongerUtteranceIsARestart() {
        XCTAssertTrue(LegacyTranscriptSegmenter.isRestart(previous: "Hello there friend", next: "He"))
        let text = ledgerText(["Hello there friend", "He", "Hey we need to ship"], final: "Hey we need to ship")
        XCTAssertTrue(text.contains("Hello there friend"))
        XCTAssertTrue(text.contains("Hey we need to ship"))
    }

    func test_aSmallRevisionIsNotARestartDespiteTheLengthClause() {
        XCTAssertFalse(LegacyTranscriptSegmenter.isRestart(previous: "There are a lot", next: "Their a lot"))
    }

    func test_slotDeliversToTheLiveRequestUntilDetached() throws {
        let slot = RecognitionRequestSlot()
        let first = FakeRecognitionTarget()
        slot.replace(with: first, token: 1)
        let one = try buffer(), two = try buffer()
        slot.append(one)
        slot.append(two)

        XCTAssertEqual(first.received.count, 2)
        XCTAssertFalse(slot.hasPending)
    }

    func test_slotKeepsAudioWhileDetachedAndReplaysItInOrderIntoTheNextRequest() throws {
        let slot = RecognitionRequestSlot()
        let first = FakeRecognitionTarget()
        let second = FakeRecognitionTarget()
        let buffers = try (0 ..< 6).map { _ in try buffer() }
        slot.replace(with: first, token: 1)
        slot.append(buffers[0])
        slot.append(buffers[1])
        XCTAssertTrue(slot.detach(1))
        slot.append(buffers[2])
        slot.append(buffers[3])
        XCTAssertTrue(slot.hasPending)

        slot.replace(with: second, token: 2)
        slot.append(buffers[4])
        slot.append(buffers[5])

        XCTAssertTrue(first.received.elementsEqual(buffers[0 ... 1], by: ===))
        XCTAssertTrue(second.received.elementsEqual(buffers[2 ... 5], by: ===))
        XCTAssertFalse(slot.hasPending)
    }

    func test_pendingAudioIsReplayedOnlyOnce() throws {
        let slot = RecognitionRequestSlot()
        let first = FakeRecognitionTarget()
        let second = FakeRecognitionTarget()
        let third = FakeRecognitionTarget()
        let held = try buffer()
        slot.replace(with: first, token: 1)
        slot.detach(1)
        slot.append(held)
        slot.replace(with: second, token: 2)
        slot.detach(2)
        slot.replace(with: third, token: 3)

        XCTAssertEqual(second.received.count, 1)
        XCTAssertEqual(third.received.count, 0)
    }

    func test_detachWithAStaleTokenOrTwiceChangesNothing() throws {
        let slot = RecognitionRequestSlot()
        let first = FakeRecognitionTarget()
        slot.replace(with: first, token: 2)

        XCTAssertFalse(slot.detach(1))
        try slot.append(buffer())
        XCTAssertEqual(first.received.count, 1)
        XCTAssertTrue(slot.detach(2))
        XCTAssertFalse(slot.detach(2))
    }

    func test_pendingAudioIsCappedAtThirtySecondsKeepingTheNewest() throws {
        let slot = RecognitionRequestSlot()
        let first = FakeRecognitionTarget()
        let second = FakeRecognitionTarget()
        slot.replace(with: first, token: 1)
        slot.detach(1)
        let buffers = try (0 ..< 40).map { _ in try buffer(seconds: 1) }
        buffers.forEach { slot.append($0) }

        XCTAssertLessThanOrEqual(slot.pendingDuration, RecognitionRequestSlot.pendingLimitSeconds + 0.001)
        slot.replace(with: second, token: 2)
        XCTAssertEqual(second.received.count, 30)
        XCTAssertTrue(second.received.last === buffers.last)
        XCTAssertTrue(second.received.first === buffers[10])
    }

    func test_replacingWithNothingWhileDetachedDiscardsPendingAudio() throws {
        let slot = RecognitionRequestSlot()
        slot.replace(with: FakeRecognitionTarget(), token: 1)
        slot.detach(1)
        try slot.append(buffer())
        slot.replace(with: nil)

        XCTAssertFalse(slot.hasPending)
    }

    func test_closingInputWhileDetachedKeepsPendingAudioForTheFinalDrain() throws {
        let slot = RecognitionRequestSlot()
        slot.replace(with: FakeRecognitionTarget(), token: 1)
        slot.detach(1)
        try slot.append(buffer())

        XCTAssertNil(slot.closeInput())
        XCTAssertTrue(slot.hasPending)
    }

    func test_closingInputEndsTheLiveRequest() {
        let slot = RecognitionRequestSlot()
        let live = FakeRecognitionTarget()
        slot.replace(with: live, token: 1)

        slot.closeInput()?.endAudio()

        XCTAssertTrue(live.ended)
    }

    func test_detachCurrentHandsBackTheRequestAndTokenOnce() {
        let slot = RecognitionRequestSlot()
        let live = FakeRecognitionTarget()
        slot.replace(with: live, token: 7)

        let detached = slot.detachCurrent()

        XCTAssertEqual(detached?.token, 7)
        XCTAssertTrue(detached?.target === live)
        XCTAssertNil(slot.detachCurrent())
    }

    func test_localeFallbackTriesTheBaseLanguageThenAmericanEnglish() {
        XCTAssertEqual(LocaleFallback.identifiers(for: "en_NG"), ["en_NG", "en", "en-US"])
        XCTAssertEqual(LocaleFallback.identifiers(for: "fr_CH"), ["fr_CH", "fr"])
        XCTAssertEqual(LocaleFallback.identifiers(for: "en_US"), ["en_US", "en"])
    }
}

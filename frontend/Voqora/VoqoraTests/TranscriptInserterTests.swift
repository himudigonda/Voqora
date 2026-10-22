import AppKit
@testable import Voqora
import XCTest

@MainActor
private final class FakePasteboard: PasteboardAccessing {
    private(set) var text: String?
    private(set) var lastWriteWasTransient = false
    private(set) var restoreCount = 0
    private(set) var changeCount = 0
    var readsPaste = true
    private var pendingRead: AsyncStream<Void>.Continuation?

    init(text: String?) {
        self.text = text
    }

    func snapshot() -> PasteboardSnapshot {
        guard let text else { return [] }
        return [[.string: Data(text.utf8)]]
    }

    func restore(_ snapshot: PasteboardSnapshot) {
        restoreCount += 1
        changeCount += 1
        text = snapshot.first?[.string].map { String(decoding: $0, as: UTF8.self) }
    }

    func write(_ text: String, transient: Bool) {
        changeCount += 1
        self.text = text
        lastWriteWasTransient = transient
    }

    func writeObserved(_ text: String) -> AsyncStream<Void> {
        write(text, transient: true)
        let (reads, continuation) = AsyncStream<Void>.makeStream()
        pendingRead = continuation
        return reads
    }

    func targetReadsThePaste() {
        guard readsPaste else { return }
        pendingRead?.yield()
        pendingRead?.finish()
    }

    func simulateCopyFromAnotherApp(_ text: String) {
        changeCount += 1
        self.text = text
    }
}

@MainActor
private final class FakeClock {
    var now: TimeInterval = 0
}

@MainActor
private final class FakePasteCommand: PasteCommandSending {
    var succeeds = true
    private(set) var sentCount = 0
    private(set) var clipboardAtPaste: String?
    var onSend: (() -> Void)?
    weak var pasteboard: FakePasteboard?

    func sendPaste() -> Bool {
        sentCount += 1
        clipboardAtPaste = pasteboard?.text
        onSend?()
        pasteboard?.targetReadsThePaste()
        return succeeds
    }
}

@MainActor
final class TranscriptInserterTests: XCTestCase {
    private var pasteboard: FakePasteboard!
    private var command: FakePasteCommand!
    private var waits: [TimeInterval] = []

    override func setUp() {
        super.setUp()
        pasteboard = FakePasteboard(text: "What was on the clipboard")
        command = FakePasteCommand()
        command.pasteboard = pasteboard
        waits = []
    }

    private func makeInserter(
        trusted: Bool = true,
        minimumRestoreDelay: TimeInterval = 0.25,
        clock: FakeClock? = nil,
        duringWait: (() -> Void)? = nil
    ) -> TranscriptInserter {
        let fakeClock = clock ?? FakeClock()
        return TranscriptInserter(
            pasteboard: pasteboard,
            pasteCommand: command,
            isAccessibilityTrusted: { trusted },
            restoreDelay: 0.25,
            minimumRestoreDelay: minimumRestoreDelay,
            readTimeout: 0.05,
            gate: PasteboardGate(),
            now: { fakeClock.now },
            wait: { [weak self] seconds in
                self?.waits.append(seconds)
                fakeClock.now += seconds
                duringWait?()
            }
        )
    }

    func test_pasteModePastesThenRestoresTheOriginalClipboard() async {
        let outcome = await makeInserter().insert("Dictated words", mode: .paste)

        XCTAssertEqual(outcome, .pasted)
        XCTAssertEqual(command.sentCount, 1)
        XCTAssertEqual(command.clipboardAtPaste, "Dictated words")
        XCTAssertEqual(waits, [0.25])
        XCTAssertEqual(pasteboard.restoreCount, 1)
        XCTAssertEqual(pasteboard.text, "What was on the clipboard")
    }

    func test_pasteModeMarksTheTemporaryClipboardEntryAsTransient() async {
        _ = await makeInserter(duringWait: { [weak self] in
            XCTAssertEqual(self?.pasteboard.lastWriteWasTransient, true)
        }).insert("Dictated words", mode: .paste)
    }

    func test_newerClipboardContentsAreNotOverwritten() async {
        let inserter = makeInserter(duringWait: { [weak self] in
            self?.pasteboard.simulateCopyFromAnotherApp("Copied meanwhile")
        })

        let outcome = await inserter.insert("Dictated words", mode: .paste)

        XCTAssertEqual(outcome, .pasted)
        XCTAssertEqual(pasteboard.restoreCount, 0)
        XCTAssertEqual(pasteboard.text, "Copied meanwhile")
    }

    func test_clipboardIsNotRestoredUntilTheTargetReadsThePaste() async {
        pasteboard.readsPaste = false

        let outcome = await makeInserter().insert("Dictated words", mode: .paste)

        XCTAssertEqual(outcome, .copied)
        XCTAssertTrue(waits.isEmpty)
        XCTAssertEqual(pasteboard.restoreCount, 0)
        XCTAssertEqual(pasteboard.text, "Dictated words")
        XCTAssertFalse(pasteboard.lastWriteWasTransient)
    }

    func test_anUnreadPasteNeverOverwritesANewerCopy() async {
        pasteboard.readsPaste = false
        command.onSend = { [weak self] in self?.pasteboard.simulateCopyFromAnotherApp("Copied meanwhile") }

        let outcome = await makeInserter().insert("Dictated words", mode: .paste)

        XCTAssertEqual(outcome, .copied)
        XCTAssertEqual(pasteboard.text, "Copied meanwhile")
    }

    func test_restoreWaitsTheShortDelayAfterTheRead() async {
        let outcome = await makeInserter().insert("Dictated words", mode: .paste)

        XCTAssertEqual(outcome, .pasted)
        XCTAssertEqual(waits, [0.25])
        XCTAssertEqual(TranscriptInserter.defaultRestoreDelay, 0.15)
        XCTAssertEqual(TranscriptInserter.defaultReadTimeout, 2.5)
    }

    func test_anImmediateReadStillWaitsTheMinimumRestoreDelayAfterTheSend() async {
        let clock = FakeClock()
        command.onSend = { clock.now = 10 }

        let outcome = await makeInserter(
            minimumRestoreDelay: TranscriptInserter.defaultMinimumRestoreDelay,
            clock: clock
        ).insert("Dictated words", mode: .paste)

        XCTAssertEqual(outcome, .pasted)
        XCTAssertEqual(TranscriptInserter.defaultMinimumRestoreDelay, 0.5)
        XCTAssertEqual(waits, [0.5])
        XCTAssertEqual(clock.now - 10, 0.5, accuracy: 0.0001)
        XCTAssertEqual(pasteboard.restoreCount, 1)
        XCTAssertEqual(pasteboard.text, "What was on the clipboard")
    }

    func test_copyModeLeavesTheTranscriptOnTheClipboard() async {
        let outcome = await makeInserter().insert("Dictated words", mode: .copy)

        XCTAssertEqual(outcome, .copied)
        XCTAssertEqual(command.sentCount, 0)
        XCTAssertEqual(pasteboard.text, "Dictated words")
        XCTAssertFalse(pasteboard.lastWriteWasTransient)
        XCTAssertEqual(pasteboard.restoreCount, 0)
    }

    func test_withoutAccessibilityTheTranscriptIsCopiedInstead() async {
        let outcome = await makeInserter(trusted: false).insert("Dictated words", mode: .paste)

        XCTAssertEqual(outcome, .copiedNeedsAccessibility)
        XCTAssertEqual(outcome.settingsPane, .accessibility)
        XCTAssertEqual(command.sentCount, 0)
        XCTAssertEqual(pasteboard.text, "Dictated words")
    }

    func test_failedKeystrokeKeepsTheTranscriptOnTheClipboard() async {
        command.succeeds = false

        let outcome = await makeInserter().insert("Dictated words", mode: .paste)

        XCTAssertEqual(outcome, .copied)
        XCTAssertTrue(waits.isEmpty)
        XCTAssertEqual(pasteboard.text, "Dictated words")
        XCTAssertFalse(pasteboard.lastWriteWasTransient)
    }

    func test_systemPasteboardReportsWhenTheTargetReadsTheText() async {
        let named = NSPasteboard(name: .init("com.himudigonda.Voqora.TranscriptInserterTests.observed"))
        named.clearContents()
        let system = SystemPasteboard(pasteboard: named)

        let reads = system.writeObserved("Transcript")
        XCTAssertEqual(named.string(forType: .string), "Transcript")

        var iterator = reads.makeAsyncIterator()
        let first: Void? = await iterator.next()
        XCTAssertNotNil(first)
    }

    func test_systemPasteboardRoundTripsAndFlagsTransientWrites() {
        let named = NSPasteboard(name: .init("com.himudigonda.Voqora.TranscriptInserterTests"))
        named.clearContents()
        named.setString("Original", forType: .string)
        let system = SystemPasteboard(pasteboard: named)

        let saved = system.snapshot()
        system.write("Transcript", transient: true)

        XCTAssertEqual(named.string(forType: .string), "Transcript")
        XCTAssertTrue(named.types?.contains(SystemPasteboard.transientType) ?? false)

        system.restore(saved)

        XCTAssertEqual(named.string(forType: .string), "Original")
        XCTAssertFalse(named.types?.contains(SystemPasteboard.transientType) ?? true)
    }
}

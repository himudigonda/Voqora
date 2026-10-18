import AppKit
@testable import Voqora
import XCTest

@MainActor
private final class FakePasteboard: PasteboardAccessing {
    private(set) var text: String?
    private(set) var lastWriteWasTransient = false
    private(set) var restoreCount = 0
    private(set) var changeCount = 0

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

    func simulateCopyFromAnotherApp(_ text: String) {
        changeCount += 1
        self.text = text
    }
}

@MainActor
private final class FakePasteCommand: PasteCommandSending {
    var succeeds = true
    private(set) var sentCount = 0
    private(set) var clipboardAtPaste: String?
    weak var pasteboard: FakePasteboard?

    func sendPaste() -> Bool {
        sentCount += 1
        clipboardAtPaste = pasteboard?.text
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

    private func makeInserter(trusted: Bool = true, duringWait: (() -> Void)? = nil) -> TranscriptInserter {
        TranscriptInserter(
            pasteboard: pasteboard,
            pasteCommand: command,
            isAccessibilityTrusted: { trusted },
            restoreDelay: 0.25,
            wait: { [weak self] seconds in
                self?.waits.append(seconds)
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

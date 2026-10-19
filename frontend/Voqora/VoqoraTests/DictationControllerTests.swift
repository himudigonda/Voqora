import Foundation
@testable import Voqora
import XCTest

@MainActor
private final class FakeRecognizer: SpeechRecognizing {
    var startError: DictationIssue?
    private(set) var startedLocales: [String?] = []
    private(set) var allowedServer: [Bool] = []
    private(set) var finishCount = 0
    private(set) var stopCount = 0

    func start(localeIdentifier: String?, allowsServer: Bool, onEvent _: @escaping SpeechRecognitionHandler) throws {
        if let startError {
            throw startError
        }
        startedLocales.append(localeIdentifier)
        allowedServer.append(allowsServer)
    }

    func finish() {
        finishCount += 1
    }

    func stop() {
        stopCount += 1
    }
}

@MainActor
private final class FakeAuthorizer: DictationAuthorizing {
    var microphone = DictationPermissionStatus.granted
    var speech = DictationPermissionStatus.granted

    func microphoneStatus() -> DictationPermissionStatus {
        microphone
    }

    func requestMicrophoneAccess() async -> Bool {
        true
    }

    func speechRecognitionStatus() -> DictationPermissionStatus {
        speech
    }

    func requestSpeechRecognitionAccess() async -> Bool {
        true
    }
}

@MainActor
private final class FakeInserter: TranscriptInserting {
    var outcome = DictationInsertionOutcome.pasted
    private(set) var inserted: [String] = []
    private(set) var modes: [DictationInsertionMode] = []

    func insert(_ text: String, mode: DictationInsertionMode) async -> DictationInsertionOutcome {
        inserted.append(text)
        modes.append(mode)
        return outcome
    }
}

@MainActor
private final class FakeHUD: DictationHUDPresenting {
    private(set) var showCount = 0
    private(set) var hideDelays: [TimeInterval] = []

    func show() {
        showCount += 1
    }

    func hide(after delay: TimeInterval) {
        hideDelays.append(delay)
    }
}

@MainActor
private final class FakeSpeech: DictationSpeechPausing {
    private(set) var pauseCount = 0

    func pauseSpeechForDictation() {
        pauseCount += 1
    }
}

@MainActor
private final class FrontmostStub {
    var current: FrontmostApplication? = FrontmostApplication(processIdentifier: 100, bundleIdentifier: "com.example.notes")
}

@MainActor
private final class ManualClock {
    var now: TimeInterval = 0
}

@MainActor
final class DictationControllerTests: XCTestCase {
    private var recognizer: FakeRecognizer!
    private var authorizer: FakeAuthorizer!
    private var inserter: FakeInserter!
    private var hud: FakeHUD!
    private var speech: FakeSpeech!
    private var clock: ManualClock!
    private var frontmost: FrontmostStub!
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var folder: URL!
    private var controller: DictationController!

    override func setUp() {
        super.setUp()
        recognizer = FakeRecognizer()
        authorizer = FakeAuthorizer()
        inserter = FakeInserter()
        hud = FakeHUD()
        speech = FakeSpeech()
        clock = ManualClock()
        frontmost = FrontmostStub()
        suiteName = "DictationControllerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoqoraDictationControllerTests-\(UUID().uuidString)", isDirectory: true)
        let manualClock: ManualClock? = clock
        let frontmostStub: FrontmostStub? = frontmost
        controller = DictationController(
            transcripts: DictationTranscriptStore(storageURL: folder.appendingPathComponent("transcripts.json")),
            dependencies: DictationDependencies(
                recognizer: recognizer,
                authorizer: authorizer,
                inserter: inserter,
                defaults: defaults,
                clock: { manualClock?.now ?? 0 },
                finishTimeout: 60,
                frontmostApplication: { frontmostStub?.current }
            )
        )
        controller.hud = hud
        controller.speechPauser = speech
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: folder)
        controller = nil
        super.tearDown()
    }

    func test_fullSessionInsertsTheFinalTranscriptAndSavesIt() async {
        await controller.toggle()
        XCTAssertEqual(controller.phase, .listening)
        XCTAssertEqual(speech.pauseCount, 1)
        XCTAssertEqual(hud.showCount, 1)

        await controller.receive(.transcript("hello wor", isFinal: false))
        XCTAssertEqual(controller.liveTranscript, "hello wor")

        await controller.toggle()
        XCTAssertEqual(controller.phase, .finishing)
        XCTAssertEqual(recognizer.finishCount, 1)

        await controller.receive(.transcript("Hello world.", isFinal: true))

        XCTAssertEqual(inserter.inserted, ["Hello world."])
        XCTAssertEqual(inserter.modes, [.paste])
        XCTAssertEqual(controller.transcripts.transcripts.map(\.text), ["Hello world."])
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.outcome, .pasted)
        XCTAssertEqual(hud.hideDelays.last, DictationController.outcomeDisplaySeconds)
    }

    func test_sessionUsesStoredPreferences() async {
        defaults.set("de_DE", forKey: DictationPreferences.localeKey)
        defaults.set(true, forKey: DictationPreferences.allowsServerRecognitionKey)
        defaults.set(DictationInsertionMode.copy.rawValue, forKey: DictationPreferences.insertionModeKey)

        await controller.toggle()
        await controller.receive(.transcript("Guten Tag", isFinal: true))

        XCTAssertEqual(recognizer.startedLocales, ["de_DE"])
        XCTAssertEqual(recognizer.allowedServer, [true])
        XCTAssertEqual(inserter.modes, [.copy])
        XCTAssertEqual(controller.transcripts.transcripts.first?.localeIdentifier, "de_DE")
    }

    func test_deniedMicrophoneNeverStartsListening() async {
        authorizer.microphone = .denied

        await controller.toggle()

        XCTAssertTrue(recognizer.startedLocales.isEmpty)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.issue, .microphoneDenied)
        XCTAssertEqual(hud.hideDelays.last, DictationController.actionableIssueDisplaySeconds)
    }

    func test_unavailableOnDeviceRecognitionIsReported() async {
        recognizer.startError = .onDeviceUnavailable

        await controller.toggle()

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.issue, .onDeviceUnavailable)
        XCTAssertTrue(inserter.inserted.isEmpty)
    }

    func test_silenceAfterSpeechFinishesAutomatically() async {
        await controller.toggle()

        clock.now = 1
        await controller.receive(.level(0.9))
        clock.now = 2.5
        await controller.receive(.level(0.01))
        XCTAssertEqual(controller.phase, .listening)

        clock.now = 3
        await controller.receive(.level(0.01))

        XCTAssertEqual(controller.phase, .finishing)
        XCTAssertEqual(recognizer.finishCount, 1)
    }

    func test_autoStopCanBeTurnedOff() async {
        defaults.set(0.0, forKey: DictationPreferences.silenceTimeoutKey)
        await controller.toggle()

        clock.now = 1
        await controller.receive(.level(0.9))
        clock.now = 60
        await controller.receive(.level(0))

        XCTAssertEqual(controller.phase, .listening)
        XCTAssertEqual(recognizer.finishCount, 0)
    }

    func test_emptyResultReportsNothingHeardWithoutInserting() async {
        await controller.toggle()
        await controller.toggle()
        await controller.receive(.transcript("  ", isFinal: true))

        XCTAssertEqual(controller.issue, .nothingHeard)
        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertTrue(controller.transcripts.transcripts.isEmpty)
    }

    func test_recognizerFailureKeepsWhatWasAlreadyHeard() async {
        await controller.toggle()
        await controller.receive(.transcript("Remember the milk", isFinal: false))
        await controller.receive(.failed)

        XCTAssertEqual(inserter.inserted, ["Remember the milk"])
    }

    func test_cancelStopsTheRecognizerAndDiscardsTheTranscript() async {
        await controller.toggle()
        await controller.receive(.transcript("Never mind", isFinal: false))

        await controller.cancel()

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.liveTranscript, "")
        XCTAssertGreaterThan(recognizer.stopCount, 0)
        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertEqual(hud.hideDelays.last, 0)
    }

    func test_eventsAfterTheSessionEndsAreIgnored() async {
        await controller.toggle()
        await controller.receive(.transcript("Done", isFinal: true))

        await controller.receive(.transcript("Late result", isFinal: true))
        await controller.receive(.level(1))

        XCTAssertEqual(inserter.inserted, ["Done"])
        XCTAssertEqual(controller.level, 0)
    }

    func test_newSessionClearsThePreviousMessage() async {
        authorizer.microphone = .denied
        await controller.toggle()
        XCTAssertEqual(controller.issue, .microphoneDenied)

        authorizer.microphone = .granted
        await controller.toggle()

        XCTAssertNil(controller.issue)
        XCTAssertEqual(controller.phase, .listening)
    }

    private func dictate(_ text: String) async {
        await controller.toggle()
        await controller.receive(.transcript(text, isFinal: true))
    }

    func test_tidyWithAIInsertsAndSavesTheTidiedText() async {
        defaults.set(true, forKey: DictationPreferences.tidiesWithAIKey)
        var received: [String] = []
        controller.connectTidy { text in
            received.append(text)
            return "Hello, world."
        }

        await dictate("hello world")

        XCTAssertEqual(received, ["hello world"])
        XCTAssertEqual(inserter.inserted, ["Hello, world."])
        XCTAssertEqual(controller.transcripts.transcripts.map(\.text), ["Hello, world."])
        XCTAssertNil(controller.tidyFailure)
        XCTAssertFalse(controller.isTidying)
        XCTAssertEqual(controller.outcomeMessage, DictationInsertionOutcome.pasted.message)
    }

    func test_tidyIsSkippedWhenTheOptionIsOff() async {
        var calls = 0
        controller.connectTidy { _ in
            calls += 1
            return "changed"
        }

        await dictate("hello world")

        XCTAssertEqual(calls, 0)
        XCTAssertEqual(inserter.inserted, ["hello world"])
    }

    func test_tidyFailureInsertsTheRawTextAndSurfacesTheError() async {
        defaults.set(true, forKey: DictationPreferences.tidiesWithAIKey)
        controller.connectTidy { _ in throw AIReadingError.providerRequired }

        await dictate("hello world")

        XCTAssertEqual(inserter.inserted, ["hello world"])
        XCTAssertEqual(controller.transcripts.transcripts.map(\.text), ["hello world"])
        XCTAssertEqual(controller.tidyFailure, AIReadingError.providerRequired.message)
        XCTAssertEqual(controller.outcome, .pasted)
        XCTAssertTrue(controller.outcomeMessage?.contains(AIReadingError.providerRequired.message) == true)
        XCTAssertEqual(hud.hideDelays.last, DictationController.actionableIssueDisplaySeconds)
        XCTAssertFalse(controller.isTidying)
    }

    func test_emptyTidyResultFallsBackToTheRawText() async {
        defaults.set(true, forKey: DictationPreferences.tidiesWithAIKey)
        controller.connectTidy { _ in "  \n" }

        await dictate("hello world")

        XCTAssertEqual(inserter.inserted, ["hello world"])
        XCTAssertEqual(controller.tidyFailure, AIReadingError.invalidResponse.message)
    }

    func test_slowTidyTimesOutAndInsertsTheRawText() async {
        defaults.set(true, forKey: DictationPreferences.tidiesWithAIKey)
        let manualClock: ManualClock? = clock
        let slow = DictationController(
            transcripts: DictationTranscriptStore(storageURL: folder.appendingPathComponent("slow.json")),
            dependencies: DictationDependencies(
                recognizer: recognizer,
                authorizer: authorizer,
                inserter: inserter,
                defaults: defaults,
                clock: { manualClock?.now ?? 0 },
                finishTimeout: 60,
                tidyTimeout: 0.05
            )
        )
        slow.hud = hud
        slow.connectTidy { _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return "never"
        }

        await slow.toggle()
        await slow.receive(.transcript("hello world", isFinal: true))

        XCTAssertEqual(inserter.inserted, ["hello world"])
        XCTAssertNotNil(slow.tidyFailure)
    }

    func test_aNewSessionClearsThePreviousTidyFailure() async {
        defaults.set(true, forKey: DictationPreferences.tidiesWithAIKey)
        controller.connectTidy { _ in throw AIReadingError.providerRequired }
        await dictate("first")
        XCTAssertNotNil(controller.tidyFailure)

        await controller.toggle()

        XCTAssertNil(controller.tidyFailure)
    }

    func test_cancelWhileTidyingInsertsNothingAndKeepsTheRawTranscript() async {
        defaults.set(true, forKey: DictationPreferences.tidiesWithAIKey)
        controller.connectTidy { _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return "never"
        }
        await controller.toggle()
        let session = Task { await controller.receive(.transcript("hello world", isFinal: true)) }
        await yieldUntil { controller.isTidying }

        await controller.cancel()
        await session.value

        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertEqual(controller.transcripts.transcripts.map(\.text), ["hello world"])
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.isTidying)
        XCTAssertNil(controller.tidyFailure)
        XCTAssertEqual(hud.hideDelays.last, 0)
    }

    func test_toggleWhileTidyingAbandonsTheTidy() async {
        defaults.set(true, forKey: DictationPreferences.tidiesWithAIKey)
        controller.connectTidy { _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return "never"
        }
        await controller.toggle()
        let session = Task { await controller.receive(.transcript("hello world", isFinal: true)) }
        await yieldUntil { controller.isTidying }

        await controller.toggle()
        await session.value

        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertEqual(controller.transcripts.transcripts.map(\.text), ["hello world"])
        XCTAssertEqual(controller.phase, .idle)
    }

    func test_switchingAppsBeforeInsertionCopiesInsteadOfPasting() async {
        defaults.set(true, forKey: DictationPreferences.tidiesWithAIKey)
        let stub: FrontmostStub? = frontmost
        controller.connectTidy { _ in
            stub?.current = FrontmostApplication(processIdentifier: 200, bundleIdentifier: "com.example.mail")
            return "Hello, world."
        }

        await dictate("hello world")

        XCTAssertEqual(inserter.inserted, ["Hello, world."])
        XCTAssertEqual(inserter.modes, [.copy])
        XCTAssertEqual(controller.outcome, .copiedAppChanged)
        XCTAssertEqual(controller.transcripts.transcripts.map(\.text), ["Hello, world."])
        XCTAssertEqual(hud.hideDelays.last, DictationController.actionableIssueDisplaySeconds)
    }

    func test_staysPastingWhenTheFrontmostAppIsUnchanged() async {
        await dictate("hello world")

        XCTAssertEqual(inserter.modes, [.paste])
        XCTAssertEqual(controller.outcome, .pasted)
    }

    func test_appCapturedWhenFinishingIsTheOneComparedAgainst() async {
        let stub: FrontmostStub? = frontmost
        await controller.toggle()
        await controller.toggle()
        stub?.current = FrontmostApplication(processIdentifier: 200, bundleIdentifier: "com.example.mail")
        await controller.receive(.transcript("Hello", isFinal: true))

        XCTAssertEqual(inserter.modes, [.copy])
        XCTAssertEqual(controller.outcome, .copiedAppChanged)
    }
}

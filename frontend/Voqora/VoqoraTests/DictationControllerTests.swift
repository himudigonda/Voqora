import Foundation
@testable import Voqora
import XCTest

@MainActor
private final class FakeRecognizer: SpeechRecognizing {
    var startError: DictationIssue?
    var isWarmingUp = false
    var failureIssue: DictationIssue?
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
private final class GatedRecognizer: SpeechRecognizing {
    private var gates: [CheckedContinuation<Void, Never>] = []
    private(set) var handlers: [SpeechRecognitionHandler] = []
    private(set) var stopCount = 0

    var waiting: Int {
        gates.count
    }

    func start(localeIdentifier _: String?, allowsServer _: Bool, onEvent: @escaping SpeechRecognitionHandler) async throws {
        handlers.append(onEvent)
        await withCheckedContinuation { gates.append($0) }
    }

    func release() {
        gates.removeFirst().resume()
    }

    func finish() {}

    func stop() {
        stopCount += 1
    }
}

@MainActor
private final class FakeAuthorizer: DictationAuthorizing {
    var microphone = DictationPermissionStatus.granted
    var speech = DictationPermissionStatus.granted
    private(set) var speechRequests = 0

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
        speechRequests += 1
        return true
    }
}

@MainActor
private final class FakeInserter: TranscriptInserting {
    var outcome = DictationInsertionOutcome.pasted
    private(set) var inserted: [String] = []
    private(set) var modes: [DictationInsertionMode] = []
    var onInsert: ((String) -> Void)?
    private(set) var insertedFromCancelledTask = false

    func insert(_ text: String, mode: DictationInsertionMode) async -> DictationInsertionOutcome {
        insertedFromCancelledTask = insertedFromCancelledTask || Task.isCancelled
        onInsert?(text)
        inserted.append(text)
        modes.append(mode)
        return outcome
    }
}

@MainActor
private final class GatedInserter: TranscriptInserting {
    private var gates: [CheckedContinuation<Void, Never>] = []
    private(set) var inserted: [String] = []

    func insert(_ text: String, mode _: DictationInsertionMode) async -> DictationInsertionOutcome {
        inserted.append(text)
        await withCheckedContinuation { gates.append($0) }
        return .pasted
    }

    func release() {
        gates.removeFirst().resume()
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
private final class RecordingSounds: SoundPlaying {
    private(set) var played: [VoqoraSound] = []

    func play(_ sound: VoqoraSound) {
        played.append(sound)
    }
}

@MainActor
private final class FrontmostStub {
    var current: FrontmostApplication? = FrontmostApplication(processIdentifier: 100, bundleIdentifier: "com.example.notes")
}

@MainActor
private final class FakeEscapeKey: EscapeKeyRegistering {
    private(set) var events: [String] = []
    private var onPress: (@MainActor () -> Void)?

    var isEnabled: Bool {
        events.last == "enable"
    }

    func enable(onPress: @escaping @MainActor () -> Void) {
        events.append("enable")
        self.onPress = onPress
    }

    func disable() {
        events.append("disable")
        onPress = nil
    }

    func press() {
        onPress?()
    }
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
    private var holdClock: ManualClock!
    private var escapeKey: FakeEscapeKey!
    private var frontmost: FrontmostStub!
    private var sounds: RecordingSounds!
    private var recoveryStore: DictationRecoveryStore!
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
        holdClock = ManualClock()
        escapeKey = FakeEscapeKey()
        frontmost = FrontmostStub()
        sounds = RecordingSounds()
        suiteName = "DictationControllerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoqoraDictationControllerTests-\(UUID().uuidString)", isDirectory: true)
        recoveryStore = DictationRecoveryStore(fileURL: folder.appendingPathComponent("inflight.json"))
        controller = makeController(named: "transcripts.json")
        controller.speechPauser = speech
    }

    private func makeController(
        named name: String,
        configure: (inout DictationDependencies) -> Void = { _ in }
    ) -> DictationController {
        let manualClock: ManualClock? = clock
        let frontmostStub: FrontmostStub? = frontmost
        let manualHoldClock: ManualClock? = holdClock
        var dependencies = DictationDependencies(
            recognizer: recognizer,
            authorizer: authorizer,
            inserter: inserter,
            defaults: defaults,
            clock: { manualClock?.now ?? 0 },
            finishTimeout: 60,
            frontmostApplication: { frontmostStub?.current },
            sounds: sounds,
            recovery: recoveryStore,
            now: { manualHoldClock?.now ?? 0 },
            escapeKey: escapeKey
        )
        configure(&dependencies)
        let made = DictationController(
            transcripts: DictationTranscriptStore(storageURL: folder.appendingPathComponent(name)),
            dependencies: dependencies
        )
        made.hud = hud
        return made
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

        await controller.receive(.volatile("hello wor"))
        XCTAssertEqual(controller.liveTranscript, "hello wor")

        await controller.toggle()
        XCTAssertEqual(controller.phase, .finishing)
        XCTAssertEqual(recognizer.finishCount, 1)

        await deliverFinal("Hello world.", to: controller)

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
        await deliverFinal("Guten Tag", to: controller)

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

    func test_autoStopIsOffByDefault() async {
        await controller.toggle()

        clock.now = 1
        await controller.receive(.level(0.9))
        clock.now = 30
        await controller.receive(.level(0))

        XCTAssertEqual(controller.phase, .listening)
        XCTAssertEqual(recognizer.finishCount, 0)
    }

    func test_silenceAfterSpeechFinishesAutomatically() async {
        defaults.set(2.0, forKey: DictationPreferences.silenceTimeoutKey)
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
        await deliverFinal("  ", to: controller)

        XCTAssertEqual(controller.issue, .nothingHeard)
        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertTrue(controller.transcripts.transcripts.isEmpty)
    }

    func test_recognizerFailureKeepsWhatWasAlreadyHeard() async {
        await controller.toggle()
        await controller.receive(.volatile("Remember the milk"))
        await controller.receive(.failed)

        XCTAssertEqual(inserter.inserted, ["Remember the milk"])
    }

    func test_cancelStopsTheRecognizerAndDiscardsTheTranscript() async {
        await controller.toggle()
        await controller.receive(.volatile("Never mind"))

        await controller.cancel()

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.liveTranscript, "")
        XCTAssertGreaterThan(recognizer.stopCount, 0)
        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertEqual(controller.outcome, .cancelledSaved)
        XCTAssertEqual(hud.hideDelays.last, DictationController.outcomeDisplaySeconds)
    }

    func test_eventsAfterTheSessionEndsAreIgnored() async {
        await controller.toggle()
        await deliverFinal("Done", to: controller)

        await deliverFinal("Late result", to: controller)
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

    private func makePushToTalkController(gated: GatedRecognizer? = nil) -> DictationController {
        makeController(named: "push-to-talk.json") {
            if let gated {
                $0.recognizer = gated
            }
        }
    }

    func test_aTapStartsHandsFreeAndTheNextPressStops() async {
        let talk = makePushToTalkController()

        await talk.shortcutPressed()
        XCTAssertEqual(talk.phase, .listening)
        holdClock.now = Self.shortTap
        await talk.shortcutReleased()
        XCTAssertEqual(talk.phase, .listening)
        XCTAssertEqual(recognizer.finishCount, 0)

        holdClock.now = 5
        await talk.shortcutPressed()
        XCTAssertEqual(talk.phase, .finishing)
        holdClock.now = 5.8
        await talk.shortcutReleased()
        XCTAssertEqual(recognizer.finishCount, 1)

        await deliverFinal("Hands free", to: talk)
        XCTAssertEqual(inserter.inserted, ["Hands free"])
    }

    func test_holdingForTheThresholdAndReleasingFinishesTheSession() async {
        let talk = makePushToTalkController()

        await talk.shortcutPressed()
        holdClock.now = DictationController.holdToTalkThreshold
        await talk.shortcutReleased()

        XCTAssertEqual(talk.phase, .finishing)
        XCTAssertEqual(recognizer.finishCount, 1)
        await deliverFinal("Held words", to: talk)
        XCTAssertEqual(inserter.inserted, ["Held words"])
    }

    func test_aHoldReleasedWhilePreparingFinishesOnceListening() async {
        let gated = GatedRecognizer()
        let talk = makePushToTalkController(gated: gated)
        let press = Task { await talk.shortcutPressed() }
        await yieldUntil { gated.waiting == 1 }
        XCTAssertEqual(talk.phase, .preparing)

        holdClock.now = 0.6
        await talk.shortcutReleased()
        XCTAssertEqual(talk.phase, .preparing)

        gated.release()
        await press.value

        XCTAssertEqual(talk.phase, .finishing)
        guard let deliver = gated.handlers.last else { return XCTFail("The recognizer never started") }
        deliver(.finalized("Quick words"))
        deliver(.ended)
        await yieldUntil { talk.phase == .idle }
        XCTAssertEqual(inserter.inserted, ["Quick words"])
    }

    func test_aTapReleasedWhilePreparingStaysHandsFree() async {
        let gated = GatedRecognizer()
        let talk = makePushToTalkController(gated: gated)
        let press = Task { await talk.shortcutPressed() }
        await yieldUntil { gated.waiting == 1 }

        holdClock.now = Self.shortTap
        await talk.shortcutReleased()
        gated.release()
        await press.value

        XCTAssertEqual(talk.phase, .listening)
    }

    func test_autoRepeatedKeyDownsAreIgnored() async {
        let talk = makePushToTalkController()

        await talk.shortcutPressed()
        await talk.shortcutPressed()
        await talk.shortcutPressed()
        XCTAssertEqual(talk.phase, .listening)

        holdClock.now = 1
        await talk.shortcutReleased()
        XCTAssertEqual(talk.phase, .finishing)
        XCTAssertEqual(recognizer.finishCount, 1)
    }

    func test_aLostKeyUpDoesNotDisableTheShortcut() async {
        let talk = makePushToTalkController()
        await talk.shortcutPressed()
        XCTAssertEqual(talk.phase, .listening)

        holdClock.now = 2
        await talk.shortcutPressed()

        XCTAssertEqual(talk.phase, .finishing)
        XCTAssertEqual(recognizer.finishCount, 1)
    }

    func test_aReleaseAfterTheSessionWasStoppedByOtherMeansDoesNothing() async {
        let talk = makePushToTalkController()
        await talk.shortcutPressed()
        await talk.cancel()
        XCTAssertEqual(talk.phase, .idle)

        holdClock.now = 2
        await talk.shortcutReleased()

        XCTAssertEqual(talk.phase, .idle)
        XCTAssertEqual(recognizer.finishCount, 0)
    }

    func test_pressingWhileTidyingSkipsTidyAndInsertsTheRawText() async {
        defaults.set(true, forKey: DictationPreferences.tidiesWithAIKey)
        controller.connectTidy { _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return "never"
        }
        await controller.toggle()
        let session = Task { await deliverFinal("hello world", to: controller) }
        await yieldUntil { controller.isTidying }

        await controller.shortcutPressed()
        await session.value

        XCTAssertEqual(inserter.inserted, ["hello world"])
        XCTAssertEqual(controller.transcripts.transcripts.map(\.text), ["hello world"])
    }

    func test_escapeWhileListeningSavesToHistoryAndInsertsNothing() async {
        await controller.toggle()
        await controller.receive(.finalized("Never mind that"))
        await controller.receive(.volatile("and this"))
        XCTAssertTrue(escapeKey.isEnabled)

        escapeKey.press()
        await yieldUntil { controller.phase == .idle }

        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertEqual(controller.transcripts.transcripts.map(\.text), ["Never mind that and this"])
        XCTAssertEqual(controller.outcome, .cancelledSaved)
        XCTAssertEqual(controller.outcomeMessage, "Cancelled. Saved to history.")
        XCTAssertGreaterThan(recognizer.stopCount, 0)
        XCTAssertEqual(sounds.played, [.dictationStart])
        XCTAssertNil(recoveryStore.pending())
    }

    func test_escapeOnAnEmptySessionJustCloses() async {
        await controller.toggle()

        await controller.cancel()

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNil(controller.outcome)
        XCTAssertTrue(controller.transcripts.transcripts.isEmpty)
        XCTAssertEqual(hud.hideDelays.last, 0)
    }

    func test_escapeWhileFinishingSavesToHistoryAndInsertsNothing() async {
        await controller.toggle()
        await controller.receive(.volatile("Almost sent"))
        await controller.toggle()
        XCTAssertEqual(controller.phase, .finishing)

        await controller.cancel()

        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertEqual(controller.transcripts.transcripts.map(\.text), ["Almost sent"])
        XCTAssertEqual(controller.outcome, .cancelledSaved)
    }

    func test_escapeDuringLiveInsertionStopsPastingAndSavesTheFullText() async {
        enableLiveInsertion()
        let gated = GatedInserter()
        let live = makeController(named: "escape-live.json") { $0.inserter = gated }
        await live.toggle()
        await live.receive(.finalized("First."))
        await yieldUntil { gated.inserted.count == 1 }
        await live.receive(.finalized("Second."))
        await live.receive(.volatile("Third"))

        await live.cancel()
        gated.release()
        await Task.yield()

        XCTAssertEqual(gated.inserted, ["First."])
        XCTAssertEqual(live.transcripts.transcripts.map(\.text), ["First. Second. Third"])
        XCTAssertEqual(live.outcome, .cancelledSaved)
        XCTAssertEqual(live.phase, .idle)
    }

    func test_escapeIsRegisteredOnlyWhileASessionIsActive() async {
        XCTAssertEqual(escapeKey.events, ["disable"])

        await controller.toggle()
        XCTAssertEqual(escapeKey.events, ["disable", "enable"])
        await controller.receive(.volatile("hello"))
        await controller.toggle()
        XCTAssertEqual(escapeKey.events, ["disable", "enable"])
        await controller.receive(.ended)

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(escapeKey.events, ["disable", "enable", "disable"])
    }

    func test_escapeIsRemovedWhenASessionIsCancelledOrFails() async {
        await controller.toggle()
        await controller.cancel()
        XCTAssertEqual(escapeKey.events, ["disable", "enable", "disable"])

        authorizer.microphone = .denied
        await controller.toggle()
        XCTAssertEqual(escapeKey.events, ["disable", "enable", "disable", "enable", "disable"])
    }

    func test_escapeStaysRegisteredThroughTidyAndIsRemovedAfterwards() async {
        defaults.set(true, forKey: DictationPreferences.tidiesWithAIKey)
        controller.connectTidy { _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return "never"
        }
        await controller.toggle()
        let session = Task { await deliverFinal("hello world", to: controller) }
        await yieldUntil { controller.isTidying }
        XCTAssertTrue(escapeKey.isEnabled)

        escapeKey.press()
        await session.value

        XCTAssertEqual(escapeKey.events, ["disable", "enable", "disable"])
        XCTAssertTrue(inserter.inserted.isEmpty)
    }

    private static let shortTap: TimeInterval = 0.2

    private func deliverFinal(_ text: String, to target: DictationController) async {
        await target.receive(.finalized(text))
        await target.receive(.ended)
    }

    private func dictate(_ text: String) async {
        await controller.toggle()
        await deliverFinal(text, to: controller)
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
        await deliverFinal("hello world", to: slow)

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

    func test_cancelWhileTidyingInsertsNothingAndSavesTheRawText() async {
        defaults.set(true, forKey: DictationPreferences.tidiesWithAIKey)
        controller.connectTidy { _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return "never"
        }
        await controller.toggle()
        let session = Task { await deliverFinal("hello world", to: controller) }
        await yieldUntil { controller.isTidying }
        XCTAssertEqual(controller.phase, .inserting)

        await controller.cancel()
        await session.value

        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertEqual(controller.transcripts.transcripts.map(\.text), ["hello world"])
        XCTAssertNil(controller.transcripts.transcripts.first?.rawText)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.outcome, .cancelledSaved)
        XCTAssertFalse(controller.isTidying)
        XCTAssertNil(controller.tidyFailure)
        XCTAssertNil(controller.tidiedWords)
        XCTAssertEqual(hud.hideDelays.last, DictationController.outcomeDisplaySeconds)
        XCTAssertEqual(sounds.played, [.dictationStart])
    }

    func test_toggleWhileTidyingSkipsTidyAndInsertsTheRawText() async {
        defaults.set(true, forKey: DictationPreferences.tidiesWithAIKey)
        controller.connectTidy { _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return "never"
        }
        await controller.toggle()
        let session = Task { await deliverFinal("hello world", to: controller) }
        await yieldUntil { controller.isTidying }

        await controller.toggle()
        await session.value

        XCTAssertEqual(inserter.inserted, ["hello world"])
        XCTAssertEqual(controller.transcripts.transcripts.map(\.text), ["hello world"])
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNil(controller.tidiedWords)
    }

    func test_usedTidyResultReportsTheWordCountChange() async {
        defaults.set(true, forKey: DictationPreferences.tidiesWithAIKey)
        controller.connectTidy { _ in "Hello, world, how are you today." }

        await dictate("hello world")

        XCTAssertEqual(controller.tidiedWords, TidyWordCounts(before: 2, after: 6))
        XCTAssertEqual(
            controller.outcomeMessage,
            "\(DictationInsertionOutcome.pasted.message)\nTidied: 2 → 6 words"
        )
    }

    func test_tidyThatKeepsTheWordCountAddsNoSummary() async {
        defaults.set(true, forKey: DictationPreferences.tidiesWithAIKey)
        controller.connectTidy { _ in "Hello, world." }

        await dictate("hello world")

        XCTAssertNil(controller.tidiedWords)
    }

    func test_historyKeepsTheRawTextBesideTheTidiedText() async {
        defaults.set(true, forKey: DictationPreferences.tidiesWithAIKey)
        controller.connectTidy { _ in "Hello, world." }

        await dictate("hello world")

        XCTAssertEqual(controller.transcripts.transcripts.first?.text, "Hello, world.")
        XCTAssertEqual(controller.transcripts.transcripts.first?.rawText, "hello world")
    }

    func test_historyHasNoRawTextWhenNothingWasTidied() async {
        await dictate("hello world")

        XCTAssertNil(controller.transcripts.transcripts.first?.rawText)
    }

    func test_theTranscriptIsSavedBeforeThePasteStarts() async {
        var savedWhenPasting: [String] = []
        let store = controller.transcripts
        inserter.onInsert = { _ in savedWhenPasting = store.transcripts.map(\.text) }

        await dictate("keep this safe")

        XCTAssertEqual(savedWhenPasting, ["keep this safe"])
    }

    func test_cancellingASessionWithTextSavesItToHistory() async {
        await controller.toggle()
        await controller.receive(.finalized("Never mind that"))
        await controller.receive(.volatile("and this"))

        await controller.cancel()

        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertEqual(controller.transcripts.transcripts.map(\.text), ["Never mind that and this"])
    }

    func test_cancellingAnEmptySessionSavesNothing() async {
        await controller.toggle()

        await controller.cancel()

        XCTAssertTrue(controller.transcripts.transcripts.isEmpty)
    }

    private func gatedController(_ gated: GatedRecognizer) -> DictationController {
        let manualClock: ManualClock? = clock
        let gatedController = DictationController(
            transcripts: DictationTranscriptStore(storageURL: folder.appendingPathComponent("gated.json")),
            dependencies: DictationDependencies(
                recognizer: gated,
                authorizer: authorizer,
                inserter: inserter,
                defaults: defaults,
                clock: { manualClock?.now ?? 0 },
                finishTimeout: 60
            )
        )
        gatedController.hud = hud
        return gatedController
    }

    func test_aCancelledStartCannotMakeTheNextSessionListen() async {
        let gated = GatedRecognizer()
        let gatedController = gatedController(gated)
        let first = Task { await gatedController.toggle() }
        await yieldUntil { gated.waiting == 1 }
        await gatedController.cancel()
        let second = Task { await gatedController.toggle() }
        await yieldUntil { gated.waiting == 2 }

        gated.release()
        await first.value
        XCTAssertEqual(gatedController.phase, .preparing)

        gated.release()
        await second.value
        XCTAssertEqual(gatedController.phase, .listening)
    }

    func test_recognizerEventsAreAppliedInArrivalOrder() async {
        let gated = GatedRecognizer()
        let gatedController = gatedController(gated)
        let session = Task { await gatedController.toggle() }
        await yieldUntil { gated.waiting == 1 }
        gated.release()
        await session.value
        guard let deliver = gated.handlers.last else { return XCTFail("The recognizer never started") }

        deliver(.volatile("The meeting"))
        deliver(.finalized("The meeting starts at nine."))
        deliver(.volatile("Please"))
        deliver(.finalized("Please bring the forecast."))
        deliver(.volatile("Thanks"))
        deliver(.finalized("Thanks."))
        deliver(.ended)
        await yieldUntil { gatedController.phase == .idle }

        XCTAssertEqual(inserter.inserted, ["The meeting starts at nine. Please bring the forecast. Thanks."])
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
        await deliverFinal("Hello", to: controller)

        XCTAssertEqual(inserter.modes, [.copy])
        XCTAssertEqual(controller.outcome, .copiedAppChanged)
    }

    func test_soundsPlayForStartStopAndInsertedInOrder() async {
        await controller.toggle()
        await controller.receive(.finalized("Hello"))
        await controller.toggle()
        await controller.receive(.ended)

        XCTAssertEqual(sounds.played, [.dictationStart, .dictationStop, .dictationInserted])
    }

    func test_copiedOutcomeAlsoPlaysTheInsertedSound() async {
        defaults.set(DictationInsertionMode.copy.rawValue, forKey: DictationPreferences.insertionModeKey)
        inserter.outcome = .copied

        await dictate("Hello")

        XCTAssertEqual(sounds.played.last, .dictationInserted)
    }

    func test_aFailureOutcomePlaysTheErrorSound() async {
        inserter.outcome = .copiedNeedsAccessibility

        await dictate("Hello")

        XCTAssertEqual(sounds.played, [.dictationStart, .dictationError])
    }

    func test_aFailedStartPlaysOnlyTheErrorSound() async {
        authorizer.microphone = .denied

        await controller.toggle()

        XCTAssertEqual(sounds.played, [.dictationError])
    }

    func test_cancellingPlaysNoErrorSound() async {
        await controller.toggle()
        await controller.cancel()

        XCTAssertEqual(sounds.played, [.dictationStart])
    }

    func test_parakeetSkipsTheSpeechRecognitionPermission() async {
        defaults.set(DictationEngineChoice.parakeet.rawValue, forKey: DictationPreferences.engineKey)
        authorizer.speech = .denied
        let parakeet = makeController(named: "parakeet.json") { $0.localModelInstalled = { _ in true } }

        await parakeet.toggle()

        XCTAssertEqual(parakeet.phase, .listening)
        XCTAssertNil(parakeet.issue)
    }

    func test_aLocalEngineThatIsNotInstalledSaysSoInsteadOfSwitchingToApple() async {
        defaults.set(DictationEngineChoice.parakeet.rawValue, forKey: DictationPreferences.engineKey)
        authorizer.speech = .denied
        let missing = makeController(named: "fallback.json") { $0.localModelInstalled = { _ in false } }

        await missing.toggle()

        XCTAssertEqual(missing.issue, .localModelNotInstalled)
        XCTAssertTrue(recognizer.startedLocales.isEmpty)
        XCTAssertEqual(authorizer.speechRequests, 0)
    }

    func test_aMicrophoneFailureWithALocalEngineIsReportedAsAMicrophoneProblem() async {
        defaults.set(DictationEngineChoice.barkClean.rawValue, forKey: DictationPreferences.engineKey)
        recognizer.startError = .audioInputUnavailable
        let controller = makeController(named: "mic.json") { $0.localModelInstalled = { _ in true } }

        await controller.toggle()

        XCTAssertEqual(controller.issue, .audioInputUnavailable)
    }

    func test_appleEngineStillRequiresSpeechRecognition() async {
        authorizer.speech = .denied

        await controller.toggle()

        XCTAssertEqual(controller.issue, .speechRecognitionDenied)
    }

    private func enableLiveInsertion() {
        defaults.set(true, forKey: DictationPreferences.liveInsertionKey)
    }

    func test_liveInsertionPastesEachCommittedDeltaInOrderWithoutDuplicates() async {
        enableLiveInsertion()
        await controller.toggle()

        await controller.receive(.finalized("Hello world."))
        await yieldUntil { inserter.inserted.count == 1 }
        await controller.receive(.volatile("How are"))
        await controller.receive(.finalized("How are you?"))
        await yieldUntil { inserter.inserted.count == 2 }
        await controller.toggle()
        await controller.receive(.ended)

        XCTAssertEqual(inserter.inserted, ["Hello world.", " How are you?"])
        XCTAssertEqual(inserter.modes, [.paste, .paste])
        XCTAssertEqual(controller.outcome, .pasted)
        XCTAssertEqual(controller.transcripts.transcripts.map(\.text), ["Hello world. How are you?"])
        XCTAssertNil(controller.transcripts.transcripts.first?.rawText)
    }

    func test_liveInsertionDeliversTheSealedRemainderExactlyOnce() async {
        enableLiveInsertion()
        await controller.toggle()
        await controller.receive(.finalized("Hello world."))
        await yieldUntil { inserter.inserted.count == 1 }

        await controller.receive(.volatile("and the rest"))
        await controller.toggle()
        await controller.receive(.ended)

        XCTAssertEqual(inserter.inserted, ["Hello world.", " and the rest"])
        XCTAssertEqual(controller.outcome, .pasted)
        XCTAssertEqual(controller.transcripts.transcripts.map(\.text), ["Hello world. and the rest"])
    }

    func test_liveInsertionWithNothingCommittedUntilTheEndPastesOnce() async {
        enableLiveInsertion()
        await controller.toggle()

        await controller.receive(.volatile("only a hypothesis"))
        await controller.toggle()
        await controller.receive(.ended)

        XCTAssertEqual(inserter.inserted, ["only a hypothesis"])
    }

    func test_anAppChangeStopsLivePastingAndTheWholeDictationIsCopied() async {
        enableLiveInsertion()
        await controller.toggle()
        await controller.receive(.finalized("Hello world."))
        await yieldUntil { inserter.inserted.count == 1 }

        frontmost.current = FrontmostApplication(processIdentifier: 200, bundleIdentifier: "com.example.mail")
        await controller.receive(.finalized("Second thought."))
        await controller.receive(.finalized("Third thought."))
        await controller.toggle()
        await controller.receive(.ended)

        XCTAssertEqual(inserter.inserted, ["Hello world.", "Hello world. Second thought. Third thought."])
        XCTAssertEqual(inserter.modes, [.paste, .copy])
        XCTAssertEqual(controller.outcome, .copiedAppChanged)
        XCTAssertEqual(controller.transcripts.transcripts.map(\.text), ["Hello world. Second thought. Third thought."])
        XCTAssertEqual(hud.hideDelays.last, DictationController.actionableIssueDisplaySeconds)
    }

    func test_liveInsertionSkipsTidy() async {
        enableLiveInsertion()
        defaults.set(true, forKey: DictationPreferences.tidiesWithAIKey)
        var calls = 0
        controller.connectTidy { _ in
            calls += 1
            return "changed"
        }

        await dictate("hello world")

        XCTAssertEqual(calls, 0)
        XCTAssertEqual(inserter.inserted, ["hello world"])
    }

    func test_liveInsertionIsIgnoredInCopyMode() async {
        enableLiveInsertion()
        defaults.set(DictationInsertionMode.copy.rawValue, forKey: DictationPreferences.insertionModeKey)
        await controller.toggle()

        await controller.receive(.finalized("Hello world."))
        await controller.toggle()
        await controller.receive(.ended)

        XCTAssertEqual(inserter.inserted, ["Hello world."])
        XCTAssertEqual(inserter.modes, [.copy])
    }

    func test_aSecondDictationIntoTheSameAppWithinAMinuteGetsALeadingSpace() async {
        await dictate("first thought")
        clock.now = 30

        await dictate("second thought")

        XCTAssertEqual(inserter.inserted, ["first thought", " second thought"])
        XCTAssertEqual(controller.transcripts.transcripts.first?.text, "second thought")
    }

    func test_noLeadingSpaceAfterAMinute() async {
        await dictate("first thought")
        clock.now = 61

        await dictate("second thought")

        XCTAssertEqual(inserter.inserted, ["first thought", "second thought"])
    }

    func test_noLeadingSpaceIntoADifferentApp() async {
        await dictate("first thought")
        frontmost.current = FrontmostApplication(processIdentifier: 200, bundleIdentifier: "com.example.mail")

        await dictate("second thought")

        XCTAssertEqual(inserter.inserted, ["first thought", "second thought"])
    }

    func test_noLeadingSpaceBeforePunctuation() async {
        await dictate("first thought")

        await dictate("...and more")

        XCTAssertEqual(inserter.inserted, ["first thought", "...and more"])
    }

    func test_digitsGetALeadingSpace() async {
        await dictate("first thought")

        await dictate("42 is the answer")

        XCTAssertEqual(inserter.inserted, ["first thought", " 42 is the answer"])
    }

    func test_copyModeNeverGetsALeadingSpace() async {
        await dictate("first thought")
        defaults.set(DictationInsertionMode.copy.rawValue, forKey: DictationPreferences.insertionModeKey)

        await dictate("second thought")

        XCTAssertEqual(inserter.inserted, ["first thought", "second thought"])
    }

    func test_pasteLastTranscriptInsertsTheNewestHistoryEntry() async {
        await dictate("older")
        await dictate("newest words")
        inserter.onInsert = nil

        await controller.pasteLastTranscript()

        XCTAssertEqual(inserter.inserted.last, "newest words")
        XCTAssertEqual(controller.outcome, .pasted)
        XCTAssertEqual(sounds.played.last, .dictationInserted)
    }

    func test_pasteLastTranscriptDoesNothingWithoutHistory() async {
        await controller.pasteLastTranscript()

        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertNil(controller.outcome)
    }

    func test_inflightTextIsWrittenAsTheLedgerCommitsAndRemovedAfterSaving() async {
        await controller.toggle()
        await controller.receive(.finalized("Hello world."))

        XCTAssertEqual(recoveryStore.pending()?.text, "Hello world.")

        await controller.toggle()
        await controller.receive(.ended)

        XCTAssertNil(recoveryStore.pending())
    }

    func test_anUnsavedDictationFromACrashIsRecoveredOnStart() {
        recoveryStore.record(
            DictationInflightSession(
                sessionID: 9,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                localeIdentifier: "de_DE",
                text: "Rescued words"
            )
        )

        let relaunched = makeController(named: "relaunched.json")

        XCTAssertEqual(relaunched.transcripts.transcripts.map(\.text), ["Rescued words"])
        XCTAssertNil(relaunched.transcripts.transcripts.first?.rawText)
        XCTAssertEqual(relaunched.transcripts.transcripts.first?.localeIdentifier, "de_DE")
        XCTAssertNil(recoveryStore.pending())
    }

    func test_anEmptyInflightFileIsDiscardedWithoutAHistoryEntry() {
        recoveryStore.record(DictationInflightSession(sessionID: 1, startedAt: Date(), localeIdentifier: nil, text: "  "))

        let relaunched = makeController(named: "empty-recovery.json")

        XCTAssertTrue(relaunched.transcripts.transcripts.isEmpty)
        XCTAssertNil(recoveryStore.pending())
    }

    func test_quittingMidDictationSavesTheHeardWordsSynchronously() async {
        await controller.toggle()
        await controller.receive(.finalized("Almost lost"))
        await controller.receive(.volatile("this sentence"))

        controller.flushForTermination()

        XCTAssertEqual(controller.transcripts.transcripts.map(\.text), ["Almost lost this sentence"])
        XCTAssertNil(recoveryStore.pending())
        XCTAssertGreaterThan(recognizer.stopCount, 0)
    }

    func test_quittingWhileTheInsertionIsTidyingSavesTheHeardWords() async {
        defaults.set(true, forKey: DictationPreferences.tidiesWithAIKey)
        controller.connectTidy { _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return "never"
        }
        await controller.toggle()
        let session = Task { await deliverFinal("hello world", to: controller) }
        await yieldUntil { controller.isTidying }
        XCTAssertEqual(recoveryStore.pending()?.text, "hello world")

        controller.flushForTermination()

        XCTAssertEqual(controller.transcripts.transcripts.map(\.text), ["hello world"])
        XCTAssertNil(recoveryStore.pending())

        await controller.cancel()
        await session.value
    }

    func test_quittingKeepsTheWordsTheRecognizerHadNotFinalizedYet() async {
        await controller.toggle()
        await controller.receive(.volatile("one two three"))
        await controller.receive(.finalized("one two"))

        controller.flushForTermination()

        XCTAssertEqual(controller.transcripts.transcripts.map(\.text), ["one two three"])
        XCTAssertNil(controller.issue)
        XCTAssertEqual(sounds.played, [.dictationStart])
    }

    func test_quittingAfterTheTranscriptIsSavedDoesNotSaveItTwice() async {
        let session = Task { await dictate("saved already") }
        await session.value

        controller.flushForTermination()

        XCTAssertEqual(controller.transcripts.transcripts.map(\.text), ["saved already"])
    }

    func test_volatileWordsAreRecordedForRecovery() async {
        await controller.toggle()

        await controller.receive(.volatile("nothing committed yet"))

        XCTAssertEqual(recoveryStore.pending()?.text, "nothing committed yet")
    }

    func test_aLaterSessionStillPastesLiveAfterAnEarlierOneWasCancelledMidPaste() async {
        enableLiveInsertion()
        let gated = GatedInserter()
        let live = makeController(named: "gated-live.json") { $0.inserter = gated }
        await live.toggle()
        await live.receive(.finalized("First."))
        await yieldUntil { gated.inserted.count == 1 }
        await live.cancel()

        await live.toggle()
        await live.receive(.finalized("Second."))
        await yieldUntil { gated.inserted.count == 2 }

        XCTAssertEqual(gated.inserted, ["First.", "Second."])
        gated.release()
        gated.release()
        await live.toggle()
        await live.receive(.ended)
        XCTAssertEqual(live.outcome, .pasted)
    }

    func test_aTidyThatFinishesAfterTheUserSkippedItIsNotUsed() async {
        defaults.set(true, forKey: DictationPreferences.tidiesWithAIKey)
        let target: DictationController = controller
        controller.connectTidy { _ in
            await target.toggle()
            return "Tidied words."
        }

        await dictate("hello world")

        XCTAssertEqual(inserter.inserted, ["hello world"])
        XCTAssertEqual(controller.transcripts.transcripts.map(\.text), ["hello world"])
        XCTAssertNil(controller.tidiedWords)
    }

    func test_finishingWaitsForAWarmingUpModelInsteadOfTimingOut() async throws {
        recognizer.isWarmingUp = true
        let controller = makeController(named: "warming.json") { $0.finishTimeout = 0.05 }
        await controller.toggle()
        await controller.toggle()
        XCTAssertEqual(controller.phase, .finishing)

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(controller.phase, .finishing)
        XCTAssertNil(controller.issue)
        await controller.toggle()
        XCTAssertEqual(controller.phase, .finishing)

        recognizer.isWarmingUp = false
        await controller.receive(.finalized("words spoken while loading"))
        await controller.receive(.ended)

        XCTAssertEqual(inserter.inserted, ["words spoken while loading"])
    }

    func test_aTimedOutFinishInsertsFromATaskThatIsNotCancelled() async throws {
        let controller = makeController(named: "timeout.json") { $0.finishTimeout = 0.05 }
        await controller.toggle()
        await controller.receive(.finalized("kept words"))
        await controller.toggle()

        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(inserter.inserted, ["kept words"])
        XCTAssertFalse(inserter.insertedFromCancelledTask)
    }

    func test_finishingTimesOutOnceTheModelHasLoaded() async throws {
        let controller = makeController(named: "loaded.json") { $0.finishTimeout = 0.05 }
        await controller.toggle()
        await controller.toggle()

        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.issue, .nothingHeard)
    }

    func test_aModelThatFailsToLoadWhileListeningReportsTheLocalModelIssue() async {
        await controller.toggle()
        XCTAssertEqual(controller.phase, .listening)
        recognizer.failureIssue = .localModelUnavailable

        await controller.receive(.failed)

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.issue, .localModelUnavailable)
        XCTAssertTrue(inserter.inserted.isEmpty)
    }

    func test_aLocalModelStartFailureIsReportedAndDoesNotFallBack() async {
        for engine in [DictationEngineChoice.parakeet, .bark, .barkClean] {
            defaults.set(engine.rawValue, forKey: DictationPreferences.engineKey)
            recognizer.startError = .recognizerUnavailable
            let controller = makeController(named: "\(engine.rawValue)-failure.json") { $0.localModelInstalled = { _ in true } }

            await controller.toggle()

            XCTAssertEqual(controller.phase, .idle, engine.rawValue)
            XCTAssertEqual(controller.issue, .localModelUnavailable, engine.rawValue)
            XCTAssertTrue(recognizer.startedLocales.isEmpty, engine.rawValue)
        }
        XCTAssertEqual(DictationIssue.localModelUnavailable.rawValue, "parakeet_unavailable")
        XCTAssertEqual(
            DictationIssue.localModelUnavailable.message,
            "The local speech model could not be loaded. Reinstall it in Settings → Dictation, or switch to Apple."
        )
    }

    func test_barkSkipsTheSpeechRecognitionPermissionOnlyWhenInstalled() async {
        defaults.set(DictationEngineChoice.barkClean.rawValue, forKey: DictationPreferences.engineKey)
        authorizer.speech = .denied
        let installed = makeController(named: "bark-installed.json") { $0.localModelInstalled = { $0 == .barkClean } }
        await installed.toggle()
        XCTAssertEqual(installed.phase, .listening)
        XCTAssertNil(installed.issue)

        let missing = makeController(named: "bark-missing.json") { $0.localModelInstalled = { $0 == .parakeet } }
        await missing.toggle()
        XCTAssertEqual(missing.issue, .localModelNotInstalled)
        XCTAssertEqual(missing.phase, .idle)
        XCTAssertEqual(authorizer.speechRequests, 0)
    }

    func test_theRecoveryFileSurvivesWhenHistoryCannotBeSaved() async throws {
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("blocked.json"),
            withIntermediateDirectories: true
        )
        let blocked = makeController(named: "blocked.json")

        await blocked.toggle()
        await deliverFinal("Keep me safe", to: blocked)

        XCTAssertNotNil(blocked.transcripts.persistenceError)
        XCTAssertEqual(recoveryStore.pending()?.text, "Keep me safe")
    }

    func test_launchRecoverySkipsTextAlreadyInTheNewestHistoryEntry() async {
        await dictate("Same words")
        recoveryStore.record(DictationInflightSession(sessionID: 2, startedAt: Date(), localeIdentifier: nil, text: "Same words"))

        let relaunched = makeController(named: "transcripts.json")

        XCTAssertEqual(relaunched.transcripts.transcripts.map(\.text), ["Same words"])
        XCTAssertNil(recoveryStore.pending())
    }

    func test_launchRecoverySkipsTextMatchingTheNewestRawText() async {
        defaults.set(true, forKey: DictationPreferences.tidiesWithAIKey)
        controller.connectTidy { _ in "Hello, world." }
        await dictate("hello world")
        recoveryStore.record(DictationInflightSession(sessionID: 2, startedAt: Date(), localeIdentifier: nil, text: "hello world"))

        let relaunched = makeController(named: "transcripts.json")

        XCTAssertEqual(relaunched.transcripts.transcripts.map(\.text), ["Hello, world."])
        XCTAssertNil(recoveryStore.pending())
    }

    func test_quittingWhileIdleChangesNothing() {
        controller.flushForTermination()

        XCTAssertTrue(controller.transcripts.transcripts.isEmpty)
    }
}

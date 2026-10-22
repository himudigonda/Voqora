import AppKit
import Combine
import Foundation
import KeyboardShortcuts

@MainActor
protocol DictationSpeechPausing: AnyObject {
    func pauseSpeechForDictation()
}

@MainActor
protocol DictationHUDPresenting: AnyObject {
    func show()
    func hide(after delay: TimeInterval)
}

@MainActor
protocol EscapeKeyRegistering: AnyObject {
    func enable(onPress: @escaping @MainActor () -> Void)
    func disable()
}

@MainActor
final class InertEscapeKey: EscapeKeyRegistering {
    func enable(onPress _: @escaping @MainActor () -> Void) {}
    func disable() {}
}

@MainActor
final class SystemEscapeKey: EscapeKeyRegistering {
    private var onPress: (@MainActor () -> Void)?
    private var isHandlerInstalled = false

    func enable(onPress: @escaping @MainActor () -> Void) {
        self.onPress = onPress
        if !isHandlerInstalled {
            isHandlerInstalled = true
            KeyboardShortcuts.onKeyDown(for: .cancelDictation) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.onPress?()
                }
            }
        }
        KeyboardShortcuts.setShortcut(.init(.escape), for: .cancelDictation)
    }

    func disable() {
        KeyboardShortcuts.setShortcut(nil, for: .cancelDictation)
    }
}

struct FrontmostApplication: Equatable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?

    static func current() -> FrontmostApplication? {
        NSWorkspace.shared.frontmostApplication.map {
            FrontmostApplication(processIdentifier: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier)
        }
    }
}

struct DictationDependencies {
    var recognizer: any SpeechRecognizing
    var authorizer: any DictationAuthorizing
    var inserter: any TranscriptInserting
    var defaults: UserDefaults
    var clock: () -> TimeInterval
    var finishTimeout: TimeInterval
    var tidy: (@MainActor (String) async throws -> String)?
    var tidyTimeout: TimeInterval = 15
    var frontmostApplication: () -> FrontmostApplication? = { nil }
    var sounds: any SoundPlaying = SilentSoundPlayer()
    var recovery: DictationRecoveryStore?
    var localModelInstalled: @MainActor (LocalSpeechModel) -> Bool = { _ in false }
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var escapeKey: any EscapeKeyRegistering = InertEscapeKey()

    static func system(defaults: UserDefaults = .standard) -> DictationDependencies {
        DictationDependencies(
            recognizer: SystemSpeechRecognizer(defaults: defaults),
            authorizer: SystemDictationAuthorizer(),
            inserter: TranscriptInserter(),
            defaults: defaults,
            clock: { ProcessInfo.processInfo.systemUptime },
            finishTimeout: 2.5,
            frontmostApplication: { FrontmostApplication.current() },
            sounds: SoundPlayer.shared,
            recovery: DictationRecoveryStore(),
            localModelInstalled: { LocalSpeechModelStore.isInstalled($0) },
            escapeKey: SystemEscapeKey()
        )
    }
}

nonisolated struct TidyWordCounts: Equatable, Sendable {
    let before: Int
    let after: Int
}

private struct LiveInsertion {
    let target: FrontmostApplication?
    var deliveredText = ""
    var stopOutcome: DictationInsertionOutcome?
}

final class DictationController: ObservableObject {
    static let holdToTalkThreshold: TimeInterval = 0.45
    static let warmUpFinishLimit: TimeInterval = 300
    static let staleKeyDownSeconds: TimeInterval = 1
    static let continuationWindowSeconds: TimeInterval = 60

    static let outcomeDisplaySeconds: TimeInterval = 1.6
    static let issueDisplaySeconds: TimeInterval = 4
    static let actionableIssueDisplaySeconds: TimeInterval = 8

    @Published private(set) var phase: DictationPhase = .idle
    @Published private(set) var liveTranscript = ""
    @Published private(set) var level: Float = 0
    @Published private(set) var issue: DictationIssue?
    @Published private(set) var outcome: DictationInsertionOutcome?
    @Published private(set) var tidyFailure: String?
    @Published private(set) var isTidying = false
    @Published private(set) var tidiedWords: TidyWordCounts?

    let transcripts: DictationTranscriptStore
    weak var speechPauser: (any DictationSpeechPausing)?
    var hud: (any DictationHUDPresenting)?

    private var dependencies: DictationDependencies
    private var machine = DictationStateMachine()
    private var silenceDetector: SilenceDetector?
    private var finishTimeoutTask: Task<Void, Never>?
    private var sessionLocaleIdentifier: String?
    private var tidyTask: Task<String?, Never>?
    private var tidySkippedByUser = false
    private var tidyCancelledByUser = false

    var tidyWasDropped: Bool {
        tidyFailure != nil || tidySkippedByUser || tidyCancelledByUser
    }

    var tidyWasCancelled: Bool {
        tidyCancelledByUser
    }

    private var targetApplication: FrontmostApplication?
    private var pendingEvents: [SpeechRecognitionEvent] = []
    private var sessionID = 0
    private var drainTask: Task<Void, Never>?
    private var live: LiveInsertion?
    private var liveDrain: Task<Void, Never>?
    private var lastPaste: (application: FrontmostApplication, at: TimeInterval)?
    private var committedSegmentsSeen = 0
    private var sessionStartedAt = Date()
    private var isTraceOpen = false
    private var sessionSavedToHistory = false
    private var isShortcutDown = false
    private var isHoldArmed = false
    private var holdSession: Int?
    private var holdStartedAt: TimeInterval = 0
    private var finishesWhenReady = false
    private var isEscapeEnabled = false

    init(transcripts: DictationTranscriptStore, dependencies: DictationDependencies = .system()) {
        self.transcripts = transcripts
        self.dependencies = dependencies
        dependencies.escapeKey.disable()
        recoverUnsavedDictation()
    }

    static var shortcutLabel: String {
        KeyboardShortcuts.getShortcut(for: .toggleDictation).map { "\($0)" } ?? "your dictation shortcut"
    }

    func registerShortcut() {
        KeyboardShortcuts.onKeyDown(for: .toggleDictation) { [weak self] in
            Task { @MainActor [weak self] in
                VoqoraLog.info("KeyboardShortcuts", "toggleDictation pressed")
                await self?.shortcutPressed()
            }
        }
        KeyboardShortcuts.onKeyUp(for: .toggleDictation) { [weak self] in
            Task { @MainActor [weak self] in
                await self?.shortcutReleased()
            }
        }
        KeyboardShortcuts.onKeyUp(for: .pasteLastDictation) { [weak self] in
            Task { @MainActor [weak self] in
                await self?.pasteLastTranscript()
            }
        }
    }

    func toggle() async {
        if isTidying {
            skipTidy()
            return
        }
        if machine.phase == .finishing, dependencies.recognizer.isWarmingUp {
            VoqoraLog.info("Dictation", "Still waiting for the speech model; keeping the recorded audio")
            return
        }
        await send(.toggle)
    }

    func shortcutPressed() async {
        let pressedAt = dependencies.now()
        guard !isShortcutDown || pressedAt - holdStartedAt >= Self.staleKeyDownSeconds else { return }
        isShortcutDown = true
        isHoldArmed = machine.phase == .idle && !isTidying
        holdSession = nil
        holdStartedAt = pressedAt
        await toggle()
        isHoldArmed = false
    }

    func shortcutReleased() async {
        guard isShortcutDown else { return }
        isShortcutDown = false
        guard let session = holdSession else { return }
        holdSession = nil
        guard session == sessionID,
              dependencies.now() - holdStartedAt >= Self.holdToTalkThreshold
        else { return }
        switch machine.phase {
        case .preparing:
            finishesWhenReady = true
        case .listening:
            await send(.toggle)
        case .idle, .finishing, .inserting:
            break
        }
    }

    func cancel() async {
        if isTidying {
            VoqoraLog.info("Dictation", "Tidy cancelled by the user; inserting nothing")
            tidyCancelledByUser = true
            tidyTask?.cancel()
            return
        }
        await send(.cancel)
    }

    private func skipTidy() {
        VoqoraLog.info("Dictation", "Tidy skipped by the user; inserting the original words")
        tidySkippedByUser = true
        tidyTask?.cancel()
    }

    var outcomeMessage: String? {
        guard let outcome else { return nil }
        var message = outcome.message
        if let tidiedWords {
            message += "\nTidied: \(tidiedWords.before) → \(tidiedWords.after) words"
        }
        if let tidyFailure {
            message += "\nTidy with AI was skipped, so Voqora used your original words. \(tidyFailure)"
        }
        return message
    }

    func pasteLastTranscript() async {
        guard machine.phase == .idle, let text = transcripts.transcripts.first?.text else { return }
        let preferences = DictationPreferences(defaults: dependencies.defaults)
        let delivered = await dependencies.inserter.insert(text, mode: preferences.insertionMode)
        guard machine.phase == .idle else { return }
        issue = nil
        tidyFailure = nil
        tidiedWords = nil
        outcome = delivered
        playOutcomeSound(delivered)
        VoqoraLog.info("Dictation", "Pasted the last transcript again", ["outcome": delivered.rawValue])
        hud?.show()
        hud?.hide(after: delivered.settingsPane != nil ? Self.actionableIssueDisplaySeconds : Self.outcomeDisplaySeconds)
    }

    func flushForTermination() {
        if machine.phase.isCapturing {
            dependencies.recognizer.stop()
            _ = machine.handle(.recognitionFailed)
        }
        guard machine.phase == .inserting, !sessionSavedToHistory else { return }
        let text = machine.transcript
        VoqoraLog.info("Dictation", "Saving the dictation in progress before quitting", ["chars": "\(text.count)"])
        saveToHistory(text, rawText: nil)
        closeTrace(outcome: "cancelled")
    }

    func connectTidy(_ tidy: @escaping @MainActor (String) async throws -> String) {
        dependencies.tidy = tidy
    }

    func dismissMessage() {
        issue = nil
        outcome = nil
        tidyFailure = nil
        tidiedWords = nil
        hud?.hide(after: 0)
    }

    func openSystemSettings(_ pane: PrivacySettingsPane) {
        dismissMessage()
        guard let url = pane.url else { return }
        NSWorkspace.shared.open(url)
    }

    func receive(_ event: SpeechRecognitionEvent) async {
        guard machine.phase.isCapturing else { return }
        switch event {
        case let .level(value):
            level = value
            await detectSilence(level: value)
        case let .volatile(text):
            registerRecognitionActivity()
            await send(.volatileChanged(text))
        case let .finalized(text):
            registerRecognitionActivity()
            await send(.segmentFinalized(text))
        case .ended:
            await send(.recognitionEnded)
        case .failed:
            VoqoraLog.warn("Dictation", "Recognizer reported an error", ["phase": "\(machine.phase)"])
            if let issue = dependencies.recognizer.failureIssue {
                await send(.failed(issue))
            } else {
                await send(.recognitionFailed)
            }
        }
    }

    private func registerRecognitionActivity() {
        silenceDetector?.registerActivity(at: dependencies.clock())
        if machine.phase == .finishing {
            scheduleFinishTimeout()
        }
    }

    private func enqueue(_ event: SpeechRecognitionEvent) {
        pendingEvents.append(event)
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            await self?.drainEvents()
        }
    }

    private func drainEvents() async {
        while !pendingEvents.isEmpty {
            await receive(pendingEvents.removeFirst())
        }
        drainTask = nil
    }

    private func send(_ event: DictationEvent) async {
        let heardBefore = machine.transcript
        let effect = machine.handle(event)
        if effect == .prepare {
            openTrace()
        }
        syncState()
        await perform(effect, after: event, heardBefore: heardBefore)
    }

    private func syncState() {
        let previous = phase
        phase = machine.phase
        liveTranscript = machine.transcript
        setEscapeEnabled(phase != .idle)
        if phase != previous {
            DictationTrace.event("phase", ["from": "\(previous)", "to": "\(phase)"])
            switch phase {
            case .listening: play(.dictationStart)
            case .finishing: play(.dictationStop)
            default: break
            }
        }
        observeLedger()
    }

    private func setEscapeEnabled(_ enabled: Bool) {
        guard enabled != isEscapeEnabled else { return }
        isEscapeEnabled = enabled
        if enabled {
            dependencies.escapeKey.enable { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.cancel()
                }
            }
        } else {
            dependencies.escapeKey.disable()
        }
    }

    private func observeLedger() {
        let ledger = machine.ledger
        let hasNewCommit = ledger.committedSegments > committedSegmentsSeen
        committedSegmentsSeen = ledger.committedSegments
        if hasNewCommit {
            DictationTrace.event("ledger.commit", [
                "words": "\(Self.wordCount(ledger.committed))",
                "segments": "\(ledger.committedSegments)",
                "text": ledger.committed,
            ])
        }
        if machine.phase.isCapturing, !ledger.isEmpty {
            recordInflight(ledger.text, force: false)
        }
        if hasNewCommit {
            pumpLiveInsertion()
        }
    }

    private func recordInflight(_ text: String, force: Bool) {
        dependencies.recovery?.record(
            DictationInflightSession(
                sessionID: sessionID,
                startedAt: sessionStartedAt,
                localeIdentifier: sessionLocaleIdentifier,
                text: text
            ),
            force: force
        )
    }

    private func perform(_ effect: DictationEffect, after event: DictationEvent, heardBefore: String) async {
        switch effect {
        case .nothing:
            break
        case .prepare:
            await prepare()
        case .finishListening:
            finishListening()
        case let .insert(text):
            await insert(text)
        case .stop:
            stopCapture()
            discardLiveInsertion()
            saveToHistory(heardBefore, rawText: nil)
            closeTrace(outcome: "cancelled")
            presentCancelled(savedText: heardBefore)
        case let .report(reported):
            stopCapture()
            discardLiveInsertion()
            saveToHistory(heardBefore, rawText: nil)
            closeTrace(outcome: Self.traceOutcome(for: reported, after: event))
            present(reported)
        }
    }

    private func presentCancelled(savedText: String) {
        guard !savedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            hud?.hide(after: 0)
            return
        }
        outcome = .cancelledSaved
        hud?.hide(after: Self.outcomeDisplaySeconds)
    }

    private static func traceOutcome(for issue: DictationIssue, after event: DictationEvent) -> String {
        guard issue == .nothingHeard else { return "error" }
        return event == .finishTimedOut ? "timeout" : "empty"
    }

    private func openTrace() {
        closeTrace(outcome: "cancelled")
        let preferences = DictationPreferences(defaults: dependencies.defaults)
        DictationTrace.beginSession(engine: effectiveEngine(for: preferences).rawValue, locale: preferences.localeIdentifier)
        isTraceOpen = true
    }

    private func closeTrace(outcome: String) {
        guard isTraceOpen else { return }
        isTraceOpen = false
        DictationTrace.endSession(outcome: outcome)
    }

    private func effectiveEngine(for preferences: DictationPreferences) -> DictationEngineChoice {
        DictationEngineChoice.effective(preferred: preferences.engine, installed: dependencies.localModelInstalled)
    }

    private func play(_ sound: VoqoraSound) {
        DictationTrace.event("sound", ["name": sound.fileName])
        dependencies.sounds.play(sound)
    }

    private func playOutcomeSound(_ delivered: DictationInsertionOutcome) {
        play(delivered == .copiedNeedsAccessibility ? .dictationError : .dictationInserted)
    }

    private func saveToHistory(_ text: String, rawText: String?) {
        let added = transcripts.add(text, rawText: rawText, localeIdentifier: sessionLocaleIdentifier)
        if added != nil {
            guard transcripts.persistenceError == nil else {
                VoqoraLog.warn("Dictation", "History could not be saved; keeping the recovery file")
                return
            }
            sessionSavedToHistory = true
        }
        dependencies.recovery?.clear()
    }

    private func recoverUnsavedDictation() {
        guard let recovery = dependencies.recovery, let inflight = recovery.pending() else { return }
        let recovered = inflight.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let newest = transcripts.transcripts.first
        guard !recovered.isEmpty, recovered != newest?.text, recovered != newest?.rawText else {
            recovery.clear()
            return
        }
        transcripts.add(inflight.text, rawText: nil, localeIdentifier: inflight.localeIdentifier, at: inflight.startedAt)
        guard transcripts.persistenceError == nil else {
            VoqoraLog.warn("Dictation", "Recovered dictation could not be saved; keeping the recovery file")
            return
        }
        recovery.clear()
        VoqoraLog.info("Dictation", "Recovered unsaved dictation", ["chars": "\(inflight.text.count)"])
        DictationTrace.beginSession(engine: "recovery", locale: inflight.localeIdentifier)
        DictationTrace.endSession(outcome: "recovered")
    }

    private func prepare() async {
        sessionID += 1
        let session = sessionID
        sessionStartedAt = Date()
        issue = nil
        outcome = nil
        tidyFailure = nil
        tidiedWords = nil
        tidySkippedByUser = false
        tidyCancelledByUser = false
        finishesWhenReady = false
        holdSession = isHoldArmed ? session : nil
        isHoldArmed = false
        sessionSavedToHistory = false
        level = 0
        targetApplication = nil
        live = nil
        liveDrain = nil
        pendingEvents.removeAll()
        speechPauser?.pauseSpeechForDictation()
        hud?.show()
        let preferences = DictationPreferences(defaults: dependencies.defaults)
        if let model = preferences.engine.localModel, !dependencies.localModelInstalled(model) {
            DictationTrace.event("engine.not_installed", ["engine": preferences.engine.rawValue])
            await send(.failed(.localModelNotInstalled))
            return
        }
        let engine = effectiveEngine(for: preferences)
        let missing = await DictationPermissionGate(
            authorizer: dependencies.authorizer,
            requiresSpeechRecognition: engine == .apple
        ).missingAccess()
        guard session == sessionID else { return }
        if let missing {
            await send(.failed(missing))
            return
        }
        guard machine.phase == .preparing else { return }
        do {
            try await dependencies.recognizer.start(
                localeIdentifier: preferences.localeIdentifier,
                allowsServer: preferences.allowsServerRecognition
            ) { [weak self] event in
                self?.enqueue(event)
            }
        } catch {
            guard session == sessionID else { return }
            let thrown = error as? DictationIssue
            let reported: DictationIssue = if thrown == .audioInputUnavailable {
                .audioInputUnavailable
            } else if engine.localModel != nil {
                .localModelUnavailable
            } else {
                thrown ?? .audioInputUnavailable
            }
            await send(.failed(reported))
            return
        }
        guard session == sessionID else { return }
        sessionLocaleIdentifier = preferences.localeIdentifier
        silenceDetector = preferences.silenceTimeout.map { SilenceDetector(timeout: $0, startedAt: dependencies.clock()) }
        if preferences.livesInsertion, preferences.insertionMode == .paste {
            live = LiveInsertion(target: dependencies.frontmostApplication())
        }
        VoqoraLog.info("Dictation", "Listening", [
            "mode": preferences.insertionMode.rawValue,
            "locale": preferences.localeIdentifier ?? "system",
            "autoStop": preferences.silenceTimeout.map { "\($0)" } ?? "off",
            "engine": engine.rawValue,
            "live": "\(live != nil)",
        ])
        await send(.ready)
        if finishesWhenReady, session == sessionID, machine.phase == .listening {
            finishesWhenReady = false
            await send(.toggle)
        }
    }

    private func detectSilence(level value: Float) async {
        guard machine.phase == .listening,
              silenceDetector?.process(level: value, at: dependencies.clock()) == true
        else { return }
        VoqoraLog.info("Dictation", "Silence detected, finishing")
        await send(.silenceDetected)
    }

    private func finishListening() {
        targetApplication = dependencies.frontmostApplication()
        dependencies.recognizer.finish()
        level = 0
        scheduleFinishTimeout()
    }

    private func scheduleFinishTimeout() {
        finishTimeoutTask?.cancel()
        let timeout = dependencies.finishTimeout
        finishTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            var waited: TimeInterval = 0
            while !Task.isCancelled, self?.dependencies.recognizer.isWarmingUp == true, waited < Self.warmUpFinishLimit {
                try? await Task.sleep(nanoseconds: 250_000_000)
                waited += 0.25
            }
            if waited > 0 {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            self?.finishTimeoutTask = nil
            await self?.send(.finishTimedOut)
        }
    }

    private func insert(_ text: String) async {
        stopCapture()
        recordInflight(text, force: true)
        let preferences = DictationPreferences(defaults: dependencies.defaults)
        let isLive = live != nil
        if isLive {
            await liveDrain?.value
        }
        let target = live?.target ?? targetApplication ?? dependencies.frontmostApplication()
        let tidy = preferences.tidiesWithAI && !isLive ? await tidied(text) : text
        if tidyCancelledByUser {
            saveToHistory(text, rawText: nil)
            closeTrace(outcome: "cancelled")
            await send(.abandonInsertion)
            presentCancelled(savedText: text)
            return
        }
        guard machine.phase == .inserting else {
            saveToHistory(text, rawText: nil)
            closeTrace(outcome: "cancelled")
            return
        }
        saveToHistory(tidy, rawText: text)
        let delivered = isLive
            ? await finishLiveInsertion(text)
            : await deliver(tidy, mode: preferences.insertionMode, target: target)
        VoqoraLog.info("Dictation", "Transcript delivered", ["chars": "\(tidy.count)", "outcome": delivered.rawValue])
        outcome = delivered
        live = nil
        playOutcomeSound(delivered)
        closeTrace(outcome: delivered == .pasted ? "inserted" : "copied")
        await send(.insertionFinished)
        let needsAttention = delivered.settingsPane != nil || delivered == .copiedAppChanged || tidyFailure != nil
        hud?.hide(after: needsAttention ? Self.actionableIssueDisplaySeconds : Self.outcomeDisplaySeconds)
    }

    private func deliver(
        _ text: String,
        mode: DictationInsertionMode,
        target: FrontmostApplication?,
        startsDictation: Bool = true
    ) async -> DictationInsertionOutcome {
        guard mode == .paste else {
            return await dependencies.inserter.insert(text, mode: mode)
        }
        guard dependencies.frontmostApplication() == target else {
            VoqoraLog.info("Dictation", "Frontmost app changed before insertion; copying instead of pasting")
            _ = await dependencies.inserter.insert(text.trimmingCharacters(in: .whitespacesAndNewlines), mode: .copy)
            return .copiedAppChanged
        }
        let outgoing = startsDictation ? continuationPrefixed(text, target: target) : text
        let result = await dependencies.inserter.insert(outgoing, mode: .paste)
        if result == .pasted {
            recordPaste(into: target)
        }
        return result
    }

    private func continuationPrefixed(_ text: String, target: FrontmostApplication?) -> String {
        guard let lastPaste, let target, lastPaste.application == target,
              dependencies.clock() - lastPaste.at < Self.continuationWindowSeconds,
              let first = text.first, first.isLetter || first.isNumber
        else { return text }
        return " " + text
    }

    private func recordPaste(into target: FrontmostApplication?) {
        guard let target else { return }
        lastPaste = (target, dependencies.clock())
    }

    private func pumpLiveInsertion() {
        guard live != nil, liveDrain == nil else { return }
        let session = sessionID
        liveDrain = Task { [weak self] in
            await self?.drainLiveInsertion(session: session)
        }
    }

    private func drainLiveInsertion(session: Int) async {
        defer {
            if session == sessionID {
                liveDrain = nil
            }
        }
        while session == sessionID, let current = live, current.stopOutcome == nil {
            let committed = machine.ledger.committed
            guard committed.hasPrefix(current.deliveredText), committed.count > current.deliveredText.count else { return }
            let delta = String(committed.dropFirst(current.deliveredText.count))
            guard dependencies.frontmostApplication() == current.target else {
                live?.stopOutcome = .copiedAppChanged
                DictationTrace.event("live.stopped", ["reason": "app_changed"])
                return
            }
            let outgoing = current.deliveredText.isEmpty ? continuationPrefixed(delta, target: current.target) : delta
            let result = await dependencies.inserter.insert(outgoing, mode: .paste)
            guard session == sessionID, live != nil else { return }
            guard result == .pasted else {
                live?.stopOutcome = result
                DictationTrace.event("live.stopped", ["reason": result.rawValue])
                return
            }
            live?.deliveredText += delta
            recordPaste(into: current.target)
            DictationTrace.event("live.paste", ["chars": "\(delta.count)"])
        }
    }

    private func finishLiveInsertion(_ text: String) async -> DictationInsertionOutcome {
        guard let current = live else { return .copied }
        let remaining = text.hasPrefix(current.deliveredText) ? String(text.dropFirst(current.deliveredText.count)) : text
        guard !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .pasted }
        if let stopped = current.stopOutcome {
            _ = await dependencies.inserter.insert(text.trimmingCharacters(in: .whitespacesAndNewlines), mode: .copy)
            return stopped == .pasted ? .copied : stopped
        }
        if !current.deliveredText.isEmpty, dependencies.frontmostApplication() != current.target {
            VoqoraLog.info("Dictation", "Frontmost app changed during live insertion; copying the whole transcript")
            _ = await dependencies.inserter.insert(text.trimmingCharacters(in: .whitespacesAndNewlines), mode: .copy)
            return .copiedAppChanged
        }
        return await deliver(remaining, mode: .paste, target: current.target, startsDictation: current.deliveredText.isEmpty)
    }

    private func discardLiveInsertion() {
        live = nil
    }

    private func tidied(_ text: String) async -> String {
        guard let tidy = dependencies.tidy else { return text }
        isTidying = true
        tidySkippedByUser = false
        tidyCancelledByUser = false
        defer {
            isTidying = false
            tidyTask = nil
        }
        let timeout = dependencies.tidyTimeout
        let task = Task { [weak self] () -> String? in
            do {
                let result = try await Self.withTimeout(timeout) { try await tidy(text) }
                let cleaned = result.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { throw AIReadingError.invalidResponse }
                return cleaned
            } catch {
                guard !Task.isCancelled else { return nil }
                let failure = AIReadingError.wrapping(error)
                VoqoraLog.warn("Dictation", "Tidy with AI failed", ["failureCode": failure.code ?? "dictation_tidy_failed"])
                self?.tidyFailure = failure.message
                return nil
            }
        }
        tidyTask = task
        let result = await task.value
        guard !tidySkippedByUser, !tidyCancelledByUser, let cleaned = result else {
            DictationTrace.event("tidy", [
                "result": tidyFailure != nil ? "failed" : "skipped",
                "wordsIn": "\(Self.wordCount(text))",
            ])
            return text
        }
        let before = Self.wordCount(text)
        let after = Self.wordCount(cleaned)
        DictationTrace.event("tidy", ["result": "used", "wordsIn": "\(before)", "wordsOut": "\(after)"])
        if before != after {
            tidiedWords = TidyWordCounts(before: before, after: after)
        }
        return cleaned
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private static func withTimeout(
        _ seconds: TimeInterval,
        operation: @escaping @MainActor () async throws -> String
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw AIReadingError.invalidResponse }
            return first
        }
    }

    private func stopCapture() {
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil
        dependencies.recognizer.stop()
        silenceDetector = nil
        level = 0
    }

    private func present(_ reported: DictationIssue) {
        issue = reported
        play(.dictationError)
        VoqoraLog.warn("Dictation", "Dictation stopped", ["reason": reported.rawValue])
        hud?.hide(after: reported.settingsPane == nil ? Self.issueDisplaySeconds : Self.actionableIssueDisplaySeconds)
    }
}

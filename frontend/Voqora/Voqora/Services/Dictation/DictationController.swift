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

    static func system(defaults: UserDefaults = .standard) -> DictationDependencies {
        DictationDependencies(
            recognizer: SystemSpeechRecognizer(),
            authorizer: SystemDictationAuthorizer(),
            inserter: TranscriptInserter(),
            defaults: defaults,
            clock: { ProcessInfo.processInfo.systemUptime },
            finishTimeout: 2.5,
            frontmostApplication: { FrontmostApplication.current() }
        )
    }
}

final class DictationController: ObservableObject {
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

    let transcripts: DictationTranscriptStore
    weak var speechPauser: (any DictationSpeechPausing)?
    var hud: (any DictationHUDPresenting)?

    private var dependencies: DictationDependencies
    private var machine = DictationStateMachine()
    private var silenceDetector: SilenceDetector?
    private var finishTimeoutTask: Task<Void, Never>?
    private var sessionLocaleIdentifier: String?
    private var tidyTask: Task<String, Never>?
    private var targetApplication: FrontmostApplication?

    init(transcripts: DictationTranscriptStore, dependencies: DictationDependencies = .system()) {
        self.transcripts = transcripts
        self.dependencies = dependencies
    }

    static var shortcutLabel: String {
        KeyboardShortcuts.getShortcut(for: .toggleDictation).map { "\($0)" } ?? "your dictation shortcut"
    }

    func registerShortcut() {
        KeyboardShortcuts.onKeyUp(for: .toggleDictation) { [weak self] in
            Task { @MainActor [weak self] in
                VoqoraLog.info("KeyboardShortcuts", "toggleDictation triggered")
                await self?.toggle()
            }
        }
    }

    func toggle() async {
        if isTidying {
            abandonTidy()
            return
        }
        await send(.toggle)
    }

    func cancel() async {
        if isTidying {
            abandonTidy()
            return
        }
        await send(.cancel)
    }

    private func abandonTidy() {
        VoqoraLog.info("Dictation", "Tidy abandoned by the user")
        tidyTask?.cancel()
        _ = machine.handle(.abandonInsertion)
        phase = machine.phase
        liveTranscript = machine.transcript
        hud?.hide(after: 0)
    }

    var outcomeMessage: String? {
        guard let outcome else { return nil }
        guard let tidyFailure else { return outcome.message }
        return "\(outcome.message)\nTidy with AI was skipped, so Voqora used your original words. \(tidyFailure)"
    }

    func connectTidy(_ tidy: @escaping @MainActor (String) async throws -> String) {
        dependencies.tidy = tidy
    }

    func dismissMessage() {
        issue = nil
        outcome = nil
        tidyFailure = nil
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
        case let .transcript(text, isFinal):
            silenceDetector?.registerActivity(at: dependencies.clock())
            await send(isFinal ? .recognitionEnded(text) : .transcriptChanged(text))
        case .failed:
            VoqoraLog.warn("Dictation", "Recognizer reported an error", ["phase": "\(machine.phase)"])
            await send(.recognitionFailed)
        }
    }

    private func send(_ event: DictationEvent) async {
        let effect = machine.handle(event)
        phase = machine.phase
        liveTranscript = machine.transcript
        await perform(effect)
    }

    private func perform(_ effect: DictationEffect) async {
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
            hud?.hide(after: 0)
        case let .report(reported):
            stopCapture()
            present(reported)
        }
    }

    private func prepare() async {
        issue = nil
        outcome = nil
        tidyFailure = nil
        level = 0
        targetApplication = nil
        speechPauser?.pauseSpeechForDictation()
        hud?.show()
        if let missing = await DictationPermissionGate(authorizer: dependencies.authorizer).missingAccess() {
            await send(.failed(missing))
            return
        }
        guard machine.phase == .preparing else { return }
        let preferences = DictationPreferences(defaults: dependencies.defaults)
        do {
            try dependencies.recognizer.start(
                localeIdentifier: preferences.localeIdentifier,
                allowsServer: preferences.allowsServerRecognition
            ) { [weak self] event in
                Task { [weak self] in
                    await self?.receive(event)
                }
            }
        } catch {
            await send(.failed(error as? DictationIssue ?? .audioInputUnavailable))
            return
        }
        sessionLocaleIdentifier = preferences.localeIdentifier
        silenceDetector = preferences.silenceTimeout.map { SilenceDetector(timeout: $0, startedAt: dependencies.clock()) }
        VoqoraLog.info("Dictation", "Listening", [
            "mode": preferences.insertionMode.rawValue,
            "locale": preferences.localeIdentifier ?? "system",
            "autoStop": preferences.silenceTimeout.map { "\($0)" } ?? "off",
        ])
        await send(.ready)
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
        finishTimeoutTask?.cancel()
        let timeout = dependencies.finishTimeout
        finishTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.send(.finishTimedOut)
        }
    }

    private func insert(_ text: String) async {
        stopCapture()
        let preferences = DictationPreferences(defaults: dependencies.defaults)
        let target = targetApplication ?? dependencies.frontmostApplication()
        let deliverable = preferences.tidiesWithAI ? await tidied(text) : text
        guard machine.phase == .inserting else {
            transcripts.add(text, localeIdentifier: sessionLocaleIdentifier)
            return
        }
        let applicationChanged = preferences.insertionMode == .paste && dependencies.frontmostApplication() != target
        let delivered: DictationInsertionOutcome
        if applicationChanged {
            VoqoraLog.info("Dictation", "Frontmost app changed before insertion; copying instead of pasting")
            _ = await dependencies.inserter.insert(deliverable, mode: .copy)
            delivered = .copiedAppChanged
        } else {
            delivered = await dependencies.inserter.insert(deliverable, mode: preferences.insertionMode)
        }
        transcripts.add(deliverable, localeIdentifier: sessionLocaleIdentifier)
        VoqoraLog.info("Dictation", "Transcript delivered", ["chars": "\(deliverable.count)", "outcome": delivered.rawValue])
        outcome = delivered
        await send(.insertionFinished)
        let needsAttention = delivered.settingsPane != nil || delivered == .copiedAppChanged || tidyFailure != nil
        hud?.hide(after: needsAttention ? Self.actionableIssueDisplaySeconds : Self.outcomeDisplaySeconds)
    }

    private func tidied(_ text: String) async -> String {
        guard let tidy = dependencies.tidy else { return text }
        isTidying = true
        defer {
            isTidying = false
            tidyTask = nil
        }
        let timeout = dependencies.tidyTimeout
        let task = Task { [weak self] () -> String in
            do {
                let result = try await Self.withTimeout(timeout) { try await tidy(text) }
                let cleaned = result.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { throw AIReadingError.invalidResponse }
                return cleaned
            } catch {
                guard !Task.isCancelled else { return text }
                let failure = AIReadingError.wrapping(error)
                VoqoraLog.warn("Dictation", "Tidy with AI failed", ["failureCode": failure.code ?? "dictation_tidy_failed"])
                self?.tidyFailure = failure.message
                return text
            }
        }
        tidyTask = task
        return await task.value
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
        VoqoraLog.warn("Dictation", "Dictation stopped", ["reason": reported.rawValue])
        hud?.hide(after: reported.settingsPane == nil ? Self.issueDisplaySeconds : Self.actionableIssueDisplaySeconds)
    }
}

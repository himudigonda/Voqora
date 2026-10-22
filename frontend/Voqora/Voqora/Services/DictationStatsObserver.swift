import AppKit
import Combine
import Foundation

@MainActor
final class DictationStatsObserver {
    struct Feed {
        var phase: AnyPublisher<DictationPhase, Never>
        var isTidying: AnyPublisher<Bool, Never>
        var transcripts: AnyPublisher<[DictationTranscript], Never>
        var currentTranscripts: @MainActor () -> [DictationTranscript]
        var outcome: @MainActor () -> String?
        var tidyFailed: @MainActor () -> Bool
        var cancelledDuringTidy: @MainActor () -> Bool = { false }
    }

    struct Telemetry {
        var dictation: (_ words: Int, _ audioSeconds: Double?, _ outcome: String, _ language: String?, _ tidied: Bool) -> Void

        static let live = Telemetry { words, audioSeconds, outcome, language, tidied in
            MetricsService.shared.trackDictation(
                words: words,
                audioSeconds: audioSeconds,
                outcome: outcome,
                language: language,
                tidied: tidied
            )
        }
    }

    private struct Session {
        let startedAt: Date
        let app: String?
        var captureEndedAt: Date?
        var reachedInserting = false
        var sawTidying = false
        var transcript: DictationTranscript?
    }

    static let fallbackOutcome = "copied"

    private let feed: Feed
    private let usage: UsageStatsStore
    private let telemetry: Telemetry
    private let now: () -> Date
    private let frontmostAppName: () -> String?
    private var cancellables: Set<AnyCancellable> = []
    private var session: Session?
    private var lastPhase: DictationPhase = .idle
    private var lastHeadID: UUID?

    init(
        feed: Feed,
        usage: UsageStatsStore? = nil,
        telemetry: Telemetry? = nil,
        now: @escaping () -> Date = Date.init,
        frontmostAppName: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.localizedName }
    ) {
        let usage = usage ?? .shared
        self.feed = feed
        self.usage = usage
        self.telemetry = telemetry ?? .live
        self.now = now
        self.frontmostAppName = frontmostAppName
        let existing = feed.currentTranscripts()
        lastHeadID = existing.first?.id
        usage.importDictationHistoryIfNeeded(existing)
        feed.phase.sink { [weak self] in self?.handle(phase: $0) }.store(in: &cancellables)
        feed.isTidying.sink { [weak self] in self?.handle(isTidying: $0) }.store(in: &cancellables)
        feed.transcripts.dropFirst().sink { [weak self] in self?.handle(transcripts: $0) }.store(in: &cancellables)
    }

    convenience init(
        controller: DictationController,
        usage: UsageStatsStore? = nil,
        telemetry: Telemetry? = nil
    ) {
        self.init(
            feed: Feed(
                phase: controller.$phase.eraseToAnyPublisher(),
                isTidying: controller.$isTidying.eraseToAnyPublisher(),
                transcripts: controller.transcripts.$transcripts.eraseToAnyPublisher(),
                currentTranscripts: { [transcripts = controller.transcripts] in transcripts.transcripts },
                outcome: { [weak controller] in controller?.outcome?.rawValue },
                tidyFailed: { [weak controller] in controller?.tidyWasDropped ?? false },
                cancelledDuringTidy: { [weak controller] in controller?.tidyWasCancelled ?? false }
            ),
            usage: usage,
            telemetry: telemetry
        )
    }

    private func handle(phase: DictationPhase) {
        lastPhase = phase
        switch phase {
        case .listening:
            if session == nil || session?.captureEndedAt != nil {
                session = Session(startedAt: now(), app: frontmostAppName())
            }
        case .inserting:
            if var current = session {
                current.captureEndedAt = current.captureEndedAt ?? now()
                current.reachedInserting = true
                session = current
            }
        case .idle:
            resolveIdle()
        case .preparing, .finishing:
            break
        }
    }

    private func handle(isTidying: Bool) {
        if isTidying {
            session?.sawTidying = true
        }
    }

    private func handle(transcripts: [DictationTranscript]) {
        guard let head = transcripts.first, head.id != lastHeadID else { return }
        lastHeadID = head.id
        guard session != nil else { return }
        session?.transcript = head
        if lastPhase != .inserting {
            finalize()
        }
    }

    private func resolveIdle() {
        guard var current = session else { return }
        current.captureEndedAt = current.captureEndedAt ?? now()
        session = current
        if current.transcript != nil {
            finalize()
        } else if !current.reachedInserting {
            cancel(current)
        }
    }

    private func cancel(_ cancelled: Session) {
        session = nil
        usage.recordDictationCancelled(at: now())
        telemetry.dictation(0, seconds(of: cancelled), "cancelled", nil, false)
    }

    private func finalize() {
        guard let finished = session, let transcript = finished.transcript else { return }
        session = nil
        let duration = seconds(of: finished)
        if feed.cancelledDuringTidy() {
            cancel(finished)
            return
        }
        let outcome = feed.outcome() ?? Self.fallbackOutcome
        let language = transcript.localeIdentifier.flatMap { Locale(identifier: $0).language.languageCode?.identifier }
        let tidied = finished.sawTidying && !feed.tidyFailed()
        usage.recordDictation(
            DictationSession(
                text: transcript.text,
                seconds: duration,
                outcome: outcome,
                language: language,
                app: finished.app,
                tidied: tidied
            ),
            at: now()
        )
        telemetry.dictation(UsageLedger.wordCount(transcript.text), duration, outcome, language, tidied)
    }

    private func seconds(of session: Session) -> Double? {
        let duration = (session.captureEndedAt ?? now()).timeIntervalSince(session.startedAt)
        return duration > 0 ? duration : nil
    }
}

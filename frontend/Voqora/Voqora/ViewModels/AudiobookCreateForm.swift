import Combine
import Foundation

@MainActor
final class AudiobookCreateForm: ObservableObject {
    enum SourceTab: CaseIterable, Hashable {
        case file
        case link
        case text

        var title: String {
            switch self {
            case .file: "File"
            case .link: "Web link"
            case .text: "Paste text"
            }
        }
    }

    struct NarrationKey: Equatable {
        let voice: String
        let speed: Double
        let pauseScale: Double
        let delivery: SpeechDelivery
    }

    static let speedRange: ClosedRange<Double> = 0.75 ... 2.0
    static let minimumTextCharacters = 20

    @Published var sourceTab: SourceTab = .file
    @Published var linkText = ""
    @Published private(set) var linkProblem: WebPageLink.Problem?
    @Published var pasteText = ""
    @Published var pasteTitle = ""
    @Published var titleDraft = ""
    @Published var voice = "af_bella"
    @Published var speed = 1.0
    @Published var pauseScale = PauseScale.standard
    @Published var delivery = SpeechDelivery()
    @Published var useCleanup = false
    @Published private(set) var isCreating = false

    private var isConfigured = false

    var narrationKey: NarrationKey {
        NarrationKey(voice: voice, speed: speed, pauseScale: pauseScale, delivery: delivery)
    }

    var isMingVoice: Bool {
        SpeechEngineID.isMingVoice(voice)
    }

    var canSubmitText: Bool {
        pasteText.trimmingCharacters(in: .whitespacesAndNewlines).count >= Self.minimumTextCharacters
    }

    var canSubmitLink: Bool {
        !linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func configure(library: AudiobookViewModel) {
        guard !isConfigured else { return }
        isConfigured = true
        adoptDefaults(from: library)
        if let pendingVoice = library.pendingNarrationVoice {
            voice = pendingVoice
        }
        if let pendingSpeed = library.pendingSpeed {
            speed = pendingSpeed
        }
        if let pendingPause = library.pendingPauseScale {
            pauseScale = pendingPause
        }
        if let pendingDelivery = library.pendingDelivery {
            delivery = pendingDelivery
        }
        if let source = library.pendingSource {
            reflect(source)
        }
    }

    func voiceDidChange() {
        guard isMingVoice else { return }
        if delivery.isEmpty {
            delivery = SpeechDelivery.stored(forVoice: voice) ?? SpeechDelivery()
        }
        if let known = SpeechEngineStore.shared.voice(id: voice), !known.isChinese {
            delivery.dialect = nil
        }
    }

    func load(_ source: AudiobookCreateSource, library: AudiobookViewModel) {
        reflect(source)
        let engine = SpeechEngineID.engine(forVoice: voice)
        let deliveryForBook = SpeechDelivery.deliverable(delivery, forVoice: voice) ?? SpeechDelivery()
        switch source {
        case let .file(url):
            guard AudiobookImportStaging.supports(url) else {
                library.showToast("Voqora audiobooks support \(AudiobookImportStaging.supportedFormatsDescription) files.", kind: .info)
                return
            }
            do {
                let staged = try AudiobookImportStaging.stageDocument(from: url)
                library.presentEstimate(
                    for: .document(staged),
                    voice: voice,
                    speed: speed,
                    engine: engine,
                    pauseScale: pauseScale,
                    delivery: deliveryForBook
                )
            } catch {
                library.showToast("Could not prepare that document: \(error.localizedDescription)", kind: .error)
            }
        case let .link(url):
            library.presentEstimate(
                for: .webPage(url),
                voice: voice,
                speed: speed,
                engine: engine,
                pauseScale: pauseScale,
                delivery: deliveryForBook
            )
        case let .text(text, title):
            library.presentEstimate(
                forText: text,
                title: title,
                voice: voice,
                speed: speed,
                engine: engine,
                pauseScale: pauseScale,
                delivery: deliveryForBook
            )
        }
    }

    func submitLink(library: AudiobookViewModel) {
        switch WebPageLink.validate(linkText) {
        case let .success(url):
            linkProblem = nil
            load(.link(url), library: library)
        case let .failure(problem):
            linkProblem = problem
        }
    }

    func clearLinkProblem() {
        linkProblem = nil
    }

    func submitText(library: AudiobookViewModel) {
        let trimmed = pasteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minimumTextCharacters else { return }
        let title = pasteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        load(.text(trimmed, title: title.isEmpty ? nil : title), library: library)
    }

    func applyNarration(library: AudiobookViewModel) {
        guard library.pendingSource != nil else { return }
        library.updatePendingNarration(voice: voice, speed: speed, pauseScale: pauseScale, delivery: delivery)
    }

    func replaceSource(library: AudiobookViewModel) {
        library.cancelUpload()
        titleDraft = ""
        linkProblem = nil
    }

    func discardDraft(library: AudiobookViewModel) {
        replaceSource(library: library)
        resetSource()
    }

    func create(library: AudiobookViewModel) async -> Bool {
        guard !isCreating, let estimate = library.pendingEstimate else { return false }
        isCreating = true
        defer { isCreating = false }
        let title = AudiobookImportStaging.displayName(from: estimate.title)
        let started = await library.beginProcessing(useCleanup: useCleanup)
        guard started else { return false }
        library.showToast("Creating \u{201C}\(title)\u{201D}. It will appear in your Library.", kind: .success)
        resetSource()
        return true
    }

    func resetSource() {
        linkText = ""
        linkProblem = nil
        pasteText = ""
        pasteTitle = ""
        titleDraft = ""
        useCleanup = false
        sourceTab = .file
    }

    private func adoptDefaults(from library: AudiobookViewModel) {
        voice = library.defaultBookVoice.isEmpty ? SpeechEngineCatalog.fallbackVoice : library.defaultBookVoice
        speed = min(Self.speedRange.upperBound, max(Self.speedRange.lowerBound, library.defaultBookSpeed))
        pauseScale = PauseScale.clamped(library.defaultBookPauseScale)
        delivery = SpeechDelivery.stored(forVoice: voice) ?? SpeechDelivery()
    }

    private func reflect(_ source: AudiobookCreateSource) {
        switch source {
        case .file:
            sourceTab = .file
        case let .link(url):
            sourceTab = .link
            linkText = url.absoluteString
        case let .text(text, title):
            sourceTab = .text
            pasteText = text
            pasteTitle = title ?? ""
        }
    }

    private func reflect(_ source: AudiobookImportSource) {
        switch source {
        case .document:
            break
        case let .webPage(url):
            sourceTab = .link
            linkText = url.absoluteString
        }
    }
}

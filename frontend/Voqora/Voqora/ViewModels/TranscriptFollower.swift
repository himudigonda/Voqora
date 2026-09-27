import Combine
import Foundation

@MainActor
final class LineProgress: ObservableObject {
    @Published fileprivate(set) var fraction: Double = 0
}

@MainActor
final class TranscriptFollower: ObservableObject {
    @Published private(set) var document: TranscriptDocument = .empty
    @Published private(set) var revision = 0
    @Published private(set) var activeIndex: Int?
    @Published private(set) var isScrubbing = false
    let lineProgress = LineProgress()

    private let audio: AudioService
    private var scrubTime: TimeInterval?
    private var isRelative = false
    private var cancellables = Set<AnyCancellable>()

    init(audio: AudioService) {
        self.audio = audio
        audio.$currentTime
            .sink { [weak self] time in
                guard let self, scrubTime == nil else { return }
                update(at: time)
            }
            .store(in: &cancellables)
        audio.$duration
            .removeDuplicates()
            .sink { [weak self] duration in
                guard let self, isRelative, scrubTime == nil else { return }
                update(at: audio.currentTime, duration: duration)
            }
            .store(in: &cancellables)
    }

    var currentTime: TimeInterval {
        scrubTime ?? audio.currentTime
    }

    func load(_ document: TranscriptDocument) {
        isRelative = false
        replace(with: document)
    }

    func follow(spokenText text: String?) {
        isRelative = true
        replace(with: text.map { TranscriptDocument(spokenText: $0, duration: 1) } ?? .empty)
    }

    func clear() {
        isRelative = false
        replace(with: .empty)
    }

    func scrub(to time: TimeInterval?) {
        scrubTime = time
        if isScrubbing != (time != nil) {
            isScrubbing = time != nil
        }
        update(at: time ?? audio.currentTime)
    }

    private func replace(with document: TranscriptDocument) {
        self.document = document
        revision &+= 1
        activeIndex = nil
        update(at: currentTime)
    }

    private func update(at time: TimeInterval, duration: TimeInterval? = nil) {
        let time = isRelative ? time / max(duration ?? audio.duration, 0.001) : time
        let index = document.lineIndex(at: time)
        if index != activeIndex {
            activeIndex = index
        }
        let fraction = index.map { (document.progress(of: $0, at: time) * 100).rounded() / 100 } ?? 0
        if fraction != lineProgress.fraction {
            lineProgress.fraction = fraction
        }
    }
}

import AppKit
import ApplicationServices

typealias PasteboardSnapshot = [[NSPasteboard.PasteboardType: Data]]

@MainActor
protocol PasteboardAccessing {
    var changeCount: Int { get }
    func snapshot() -> PasteboardSnapshot
    func restore(_ snapshot: PasteboardSnapshot)
    func write(_ text: String, transient: Bool)
    func writeObserved(_ text: String) -> AsyncStream<Void>
}

@MainActor
protocol PasteCommandSending {
    func sendPaste() -> Bool
}

@MainActor
protocol TranscriptInserting {
    func insert(_ text: String, mode: DictationInsertionMode) async -> DictationInsertionOutcome
}

struct SystemPasteboard: PasteboardAccessing {
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int {
        pasteboard.changeCount
    }

    func snapshot() -> PasteboardSnapshot {
        SelectionManager.snapshotPasteboard(pasteboard)
    }

    func restore(_ snapshot: PasteboardSnapshot) {
        SelectionManager.restorePasteboard(snapshot, pasteboard: pasteboard)
    }

    func write(_ text: String, transient: Bool) {
        guard transient else {
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
            return
        }
        _ = writeObserved(text)
    }

    func writeObserved(_ text: String) -> AsyncStream<Void> {
        let (reads, continuation) = AsyncStream<Void>.makeStream()
        let provider = PasteboardReadObserver(text: text, continuation: continuation)
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        item.setData(Data(), forType: Self.transientType)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        return reads
    }
}

final nonisolated class PasteboardReadObserver: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private let text: String
    private let continuation: AsyncStream<Void>.Continuation
    private var retainedSelf: PasteboardReadObserver?

    init(text: String, continuation: AsyncStream<Void>.Continuation) {
        self.text = text
        self.continuation = continuation
        super.init()
        retainedSelf = self
    }

    func pasteboard(_: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        continuation.yield()
        item.setString(text, forType: type)
    }

    func pasteboardFinishedWithDataProvider(_: NSPasteboard) {
        continuation.finish()
        retainedSelf = nil
    }
}

struct SystemPasteCommand: PasteCommandSending {
    private static let vKeyCode: CGKeyCode = 0x09

    func sendPaste() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: false)
        else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}

struct TranscriptInserter: TranscriptInserting {
    nonisolated static let defaultRestoreDelay: TimeInterval = 0.15
    nonisolated static let defaultMinimumRestoreDelay: TimeInterval = 0.5
    nonisolated static let defaultReadTimeout: TimeInterval = 2.5

    private let pasteboard: any PasteboardAccessing
    private let pasteCommand: any PasteCommandSending
    private let isAccessibilityTrusted: () -> Bool
    private let restoreDelay: TimeInterval
    private let minimumRestoreDelay: TimeInterval
    private let readTimeout: TimeInterval
    private let gate: PasteboardGate
    private let now: () -> TimeInterval
    private let wait: (TimeInterval) async -> Void

    init(
        pasteboard: (any PasteboardAccessing)? = nil,
        pasteCommand: (any PasteCommandSending)? = nil,
        isAccessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        restoreDelay: TimeInterval = TranscriptInserter.defaultRestoreDelay,
        minimumRestoreDelay: TimeInterval = TranscriptInserter.defaultMinimumRestoreDelay,
        readTimeout: TimeInterval = TranscriptInserter.defaultReadTimeout,
        gate: PasteboardGate? = nil,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        wait: @escaping (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.pasteboard = pasteboard ?? SystemPasteboard()
        self.pasteCommand = pasteCommand ?? SystemPasteCommand()
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.restoreDelay = restoreDelay
        self.minimumRestoreDelay = minimumRestoreDelay
        self.readTimeout = readTimeout
        self.gate = gate ?? .shared
        self.now = now
        self.wait = wait
    }

    func insert(_ text: String, mode: DictationInsertionMode) async -> DictationInsertionOutcome {
        DictationTrace.event("insert.requested", [
            "mode": mode.rawValue,
            "chars": "\(text.count)",
            "words": "\(text.split(whereSeparator: \.isWhitespace).count)",
            "text": text,
        ])
        let outcome = await deliver(text, mode: mode)
        DictationTrace.event("insert.outcome", ["outcome": outcome.rawValue])
        return outcome
    }

    private func deliver(_ text: String, mode: DictationInsertionMode) async -> DictationInsertionOutcome {
        switch mode {
        case .copy:
            pasteboard.write(text, transient: false)
            return .copied
        case .paste:
            let trusted = isAccessibilityTrusted()
            DictationTrace.event("insert.accessibility", ["trusted": "\(trusted)"])
            guard trusted else {
                pasteboard.write(text, transient: false)
                return .copiedNeedsAccessibility
            }
            return await paste(text)
        }
    }

    private func paste(_ text: String) async -> DictationInsertionOutcome {
        await gate.acquire()
        defer { gate.release() }
        let saved = pasteboard.snapshot()
        let reads = pasteboard.writeObserved(text)
        let transcriptChange = pasteboard.changeCount
        let sent = pasteCommand.sendPaste()
        let sentAt = now()
        DictationTrace.event("insert.paste_sent", ["sent": "\(sent)"])
        guard sent else {
            DictationTrace.event("insert.clipboard", ["state": "transcript_left"])
            VoqoraLog.warn("TranscriptInserter", "Could not synthesize Command+V; transcript left on the clipboard")
            pasteboard.write(text, transient: false)
            return .copied
        }
        guard await wasRead(reads) else {
            leaveTranscript(text, ifUnchangedSince: transcriptChange)
            return .copied
        }
        let readAt = now()
        let deadline = max(readAt + restoreDelay, sentAt + minimumRestoreDelay)
        await wait(max(0, deadline - now()))
        if pasteboard.changeCount == transcriptChange {
            pasteboard.restore(saved)
            DictationTrace.event("insert.clipboard", ["state": "restored"])
        } else {
            DictationTrace.event("insert.clipboard", ["state": "newer_left"])
            VoqoraLog.info("TranscriptInserter", "Clipboard changed during paste; leaving the newer contents in place")
        }
        return .pasted
    }

    private func leaveTranscript(_ text: String, ifUnchangedSince change: Int) {
        guard pasteboard.changeCount == change else {
            DictationTrace.event("insert.clipboard", ["state": "newer_left_unread"])
            return
        }
        pasteboard.write(text, transient: false)
        DictationTrace.event("insert.clipboard", ["state": "transcript_left_unread"])
        VoqoraLog.warn("TranscriptInserter", "The target never read the paste; transcript left on the clipboard")
    }

    private func wasRead(_ reads: AsyncStream<Void>) async -> Bool {
        let timeout = readTimeout
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in reads {
                    return true
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}

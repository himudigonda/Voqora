import AppKit
import ApplicationServices

typealias PasteboardSnapshot = [[NSPasteboard.PasteboardType: Data]]

@MainActor
protocol PasteboardAccessing {
    var changeCount: Int { get }
    func snapshot() -> PasteboardSnapshot
    func restore(_ snapshot: PasteboardSnapshot)
    func write(_ text: String, transient: Bool)
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
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if transient {
            item.setData(Data(), forType: Self.transientType)
        }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
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
    nonisolated static let defaultRestoreDelay: TimeInterval = 0.4

    private let pasteboard: any PasteboardAccessing
    private let pasteCommand: any PasteCommandSending
    private let isAccessibilityTrusted: () -> Bool
    private let restoreDelay: TimeInterval
    private let wait: (TimeInterval) async -> Void

    init(
        pasteboard: (any PasteboardAccessing)? = nil,
        pasteCommand: (any PasteCommandSending)? = nil,
        isAccessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        restoreDelay: TimeInterval = TranscriptInserter.defaultRestoreDelay,
        wait: @escaping (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.pasteboard = pasteboard ?? SystemPasteboard()
        self.pasteCommand = pasteCommand ?? SystemPasteCommand()
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.restoreDelay = restoreDelay
        self.wait = wait
    }

    func insert(_ text: String, mode: DictationInsertionMode) async -> DictationInsertionOutcome {
        switch mode {
        case .copy:
            pasteboard.write(text, transient: false)
            return .copied
        case .paste:
            guard isAccessibilityTrusted() else {
                pasteboard.write(text, transient: false)
                return .copiedNeedsAccessibility
            }
            return await paste(text)
        }
    }

    private func paste(_ text: String) async -> DictationInsertionOutcome {
        let saved = pasteboard.snapshot()
        pasteboard.write(text, transient: true)
        let transcriptChange = pasteboard.changeCount
        guard pasteCommand.sendPaste() else {
            VoqoraLog.warn("TranscriptInserter", "Could not synthesize Command+V; transcript left on the clipboard")
            pasteboard.write(text, transient: false)
            return .copied
        }
        await wait(restoreDelay)
        if pasteboard.changeCount == transcriptChange {
            pasteboard.restore(saved)
        } else {
            VoqoraLog.info("TranscriptInserter", "Clipboard changed during paste; leaving the newer contents in place")
        }
        return .pasted
    }
}

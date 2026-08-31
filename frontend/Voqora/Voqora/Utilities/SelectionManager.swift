import AppKit

@MainActor
enum SelectionManager {
    /// Serializes overlapping calls instead of racing them. Without this, a
    /// rapid double-press of the shortcut could run two concurrent
    /// snapshot -> Cmd+C -> poll -> restore cycles against the same system
    /// pasteboard: call B could snapshot call A's synthetic copy (not the
    /// user's real prior clipboard) and later "restore" that permanently, or
    /// call A's restore could fire mid-poll for call B and make it time out
    /// even though a real selection existed. A second caller now awaits the
    /// first call's result instead of starting its own pasteboard mutation.
    private static var inFlightTask: Task<String?, Never>?

    static func getSelectedText() async -> String? {
        if let existing = inFlightTask {
            VoqoraLog.debug("SelectionManager", "getSelectedText already in flight, awaiting existing call")
            return await existing.value
        }
        let task = Task<String?, Never> {
            defer { inFlightTask = nil }
            return await performGetSelectedText()
        }
        inFlightTask = task
        return await task.value
    }

    private static func performGetSelectedText() async -> String? {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let frontAppName = frontApp?.localizedName ?? frontApp?.bundleIdentifier ?? "unknown"

        if let text = axSelectedText(frontAppName: frontAppName) {
            VoqoraLog.info("SelectionManager", "Found text via AX", ["app": frontAppName, "chars": "\(text.count)"])
            return text
        }

        // AXSelectedText is only implemented by apps that opt into the
        // Accessibility text APIs. Terminal, VS Code, browsers, and most
        // Electron apps never do, even though they support plain copy — so
        // for them AX alone can never satisfy "select text in any app".
        // Fall back to synthesizing Cmd+C. The user's existing clipboard is
        // saved and restored around it so the fallback has no visible
        // side effect.
        VoqoraLog.warn("SelectionManager", "AX returned no text, falling back to Clipboard (Cmd+C)", ["app": frontAppName])
        if let text = await getSelectedTextViaClipboard() {
            VoqoraLog.info("SelectionManager", "Found text via Clipboard fallback", ["app": frontAppName, "chars": "\(text.count)"])
            return text
        }

        VoqoraLog.warn("SelectionManager", "No selected text available via AX or Clipboard fallback", ["app": frontAppName])
        return nil
    }

    private static func axSelectedText(frontAppName: String) -> String? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?

        let result = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)

        guard result == .success, let focusedElement else {
            VoqoraLog.warn("SelectionManager", "AX focused-element lookup failed", ["app": frontAppName, "axError": "\(result.rawValue)"])
            return nil
        }
        guard CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else {
            VoqoraLog.warn("SelectionManager", "Focused accessibility value was not an element", ["app": frontAppName])
            return nil
        }

        var selectedText: AnyObject?
        // AXUIElementCopyAttributeValue bridges the Core Foundation value
        // as AnyObject. The type-ID check above makes this bridge safe
        // without relying on an unchecked forced cast.
        let element = unsafeBitCast(focusedElement, to: AXUIElement.self)
        let textResult = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedText)

        guard textResult == .success, let text = selectedText as? String, !text.isEmpty else {
            VoqoraLog.warn("SelectionManager", "AX selected-text lookup failed or was empty", ["app": frontAppName, "axError": "\(textResult.rawValue)"])
            return nil
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func getSelectedTextViaClipboard() async -> String? {
        let pasteboard = NSPasteboard.general
        let savedItems = snapshotPasteboard(pasteboard)
        let oldChangeCount = pasteboard.changeCount

        // Use the 'annotated' source to ensure macOS sees this as a legitimate user-driven event
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            VoqoraLog.error("SelectionManager", "Could not create CGEventSource for Cmd+C fallback")
            return nil
        }

        let cmdKey: CGKeyCode = 0x37
        let cKey: CGKeyCode = 0x08

        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: true)
        let cDown = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: true)
        let cUp = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: false)
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: false)

        cmdDown?.flags = .maskCommand
        cDown?.flags = .maskCommand
        cUp?.flags = .maskCommand
        cmdUp?.flags = .maskCommand // Cmd should stay up at the end

        // Post events
        cmdDown?.post(tap: .cghidEventTap)
        cDown?.post(tap: .cghidEventTap)
        cUp?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)

        // Poll instead of a single blind sleep: most apps update the
        // pasteboard within a few ms, so the common case returns fast and
        // only the worst case pays the full ~500ms ceiling.
        var copiedText: String?
        for _ in 0..<25 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if pasteboard.changeCount != oldChangeCount {
                copiedText = pasteboard.string(forType: .string)
                break
            }
        }

        // Always restore, even on failure — Cmd+C may have altered the
        // pasteboard without us observing the change in time.
        restorePasteboard(savedItems, pasteboard: pasteboard)

        guard let text = copiedText, !text.isEmpty else {
            VoqoraLog.warn("SelectionManager", "Cmd+C fallback timed out with no pasteboard change (frontmost app has no selection, or ignored the synthetic copy)")
            return nil
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func snapshotPasteboard(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            return dict
        }
    }

    static func restorePasteboard(_ items: [[NSPasteboard.PasteboardType: Data]], pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restoredItems = items.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dict {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restoredItems)
    }
}

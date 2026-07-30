import AppKit

@MainActor
enum SelectionManager {
    static func getSelectedText() async -> String? {
        // 1. Try Accessibility API
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?

        let result = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)

        if result == .success, let focusedElement {
            var selectedText: AnyObject?
            // AXUIElementCopyAttributeValue documents this attribute as an
            // AXUIElement when the call succeeds. Swift bridges that Core
            // Foundation type as AnyObject and rejects a conditional cast.
            let element = focusedElement as! AXUIElement
            let textResult = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedText)

            if textResult == .success, let text = selectedText as? String, !text.isEmpty {
                print("✅ SelectionManager: Found text via AX")
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        print("⚠️ SelectionManager: AX failed. Falling back to Clipboard (Cmd+C)...")
        return await getSelectedTextViaClipboard()
    }

    private static func getSelectedTextViaClipboard() async -> String? {
        let pasteboard = NSPasteboard.general
        let oldChangeCount = pasteboard.changeCount

        // Use the 'annotated' source to ensure macOS sees this as a legitimate user-driven event
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return nil }

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

        // Let the receiving app process Command-C without blocking Voqora's
        // main actor or freezing the window while the fallback is in flight.
        try? await Task.sleep(nanoseconds: 400_000_000)

        if pasteboard.changeCount != oldChangeCount,
           let text = pasteboard.string(forType: .string), !text.isEmpty
        {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }
}

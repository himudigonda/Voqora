import AppKit

@MainActor
enum SelectionManager {
    static func getSelectedText() async -> String? {
        // 1. Try Accessibility API
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?

        let result = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)

        if result == .success, let focusedElement {
            guard CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else {
                print("⚠️ SelectionManager: Focused accessibility value was not an element.")
                return nil
            }
            var selectedText: AnyObject?
            // AXUIElementCopyAttributeValue bridges the Core Foundation value
            // as AnyObject. The type-ID check above makes this bridge safe
            // without relying on an unchecked forced cast.
            let element = unsafeBitCast(focusedElement, to: AXUIElement.self)
            let textResult = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedText)

            if textResult == .success, let text = selectedText as? String, !text.isEmpty {
                print("✅ SelectionManager: Found text via AX")
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // The product's explicit contract is Accessibility-based selected-text
        // reading. Synthesising Command-C as a hidden fallback can overwrite a
        // user's clipboard and makes permission behavior unpredictable.
        print("⚠️ SelectionManager: No selected text available through Accessibility.")
        return nil
    }
}

import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let playText = Self("playText", initial: .init(.period, modifiers: [.command, .shift]))
    static let togglePause = Self("togglePause", initial: .init(.slash, modifiers: [.command, .shift]))
    static let stopText = Self("stopText", initial: .init(.comma, modifiers: [.command, .shift]))
    static let exportAudio = Self("exportAudio", initial: .init(.m, modifiers: [.command, .shift]))

    /// Helper array for iteration (Reset Logic)
    static let allCases: [KeyboardShortcuts.Name] = [
        .playText,
        .togglePause,
        .stopText,
        .exportAudio,
    ]
}

import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let playText = Self("playText", default: .init(.period, modifiers: [.command, .shift]))
    static let togglePause = Self("togglePause", default: .init(.slash, modifiers: [.command, .shift]))
    static let stopText = Self("stopText", default: .init(.comma, modifiers: [.command, .shift]))
    static let exportAudio = Self("exportAudio", default: .init(.m, modifiers: [.command, .shift]))

    /// Helper array for iteration (Reset Logic)
    static let allCases: [KeyboardShortcuts.Name] = [
        .playText,
        .togglePause,
        .stopText,
        .exportAudio,
    ]
}

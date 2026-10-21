import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let playText = Self("playText", default: .init(.period, modifiers: [.command, .shift]))
    static let togglePause = Self("togglePause", default: .init(.slash, modifiers: [.command, .shift]))
    static let stopText = Self("stopText", default: .init(.comma, modifiers: [.command, .shift]))
    static let exportAudio = Self("exportAudio", default: .init(.m, modifiers: [.command, .shift]))
    static let speakScreenText = Self("speakScreenText", default: .init(.eight, modifiers: [.command, .shift]))
    static let speakClipboard = Self("speakClipboard")
    static let toggleDictation = Self("toggleDictation", default: .init(.nine, modifiers: [.command, .shift]))
    static let pasteLastDictation = Self("pasteLastDictation")
    static let summarizeSelection = Self("summarizeSelection")
    static let translateSelection = Self("translateSelection")
    static let cancelDictation = Self("cancelDictation")

    static let allCases: [KeyboardShortcuts.Name] = [
        .playText,
        .togglePause,
        .stopText,
        .exportAudio,
        .speakScreenText,
        .speakClipboard,
        .toggleDictation,
        .pasteLastDictation,
        .summarizeSelection,
        .translateSelection,
    ]
}

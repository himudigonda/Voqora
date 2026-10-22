import Foundation

enum TabKey {
    static let home = "home"
    static let books = "books"
    static let createAudiobook = "create.audiobook"
    static let createPodcast = "create.podcast"
    static let createScripts = "create.scripts"
    static let createScriptEditor = "create.scripts.editor"
    static let booksPlayer = "books.player"
    static let inbox = "inbox"
    static let dictation = "dictation"
    static let history = "history"
    static let stats = "stats"
    static let about = "about"
    static let feedback = "feedback"
    static let settingsPrefix = "settings."

    private static let legacy: [String: String] = [
        "studio": createScripts,
        "create": createAudiobook,
        "create.script": createScripts,
        "settings.advanced": settings(.privacy),
        "voices": VoicesPage.myVoices.tab,
        "preferences": settings(.general),
        "settings": settings(.general),
        "vault": history,
    ]

    static func settings(_ tab: SettingsTab) -> String {
        settingsPrefix + tab.rawValue
    }

    static func canonical(_ key: String?) -> String? {
        guard let key else { return nil }
        return legacy[key] ?? key
    }

    static func settingsTab(for key: String?) -> SettingsTab? {
        guard let key, key.hasPrefix(settingsPrefix) else { return nil }
        return SettingsTab(rawValue: String(key.dropFirst(settingsPrefix.count)))
    }

    static func isCreate(_ key: String?) -> Bool {
        key == "create" || key?.hasPrefix("create.") == true
    }

    static var all: [String] {
        let create = [createAudiobook, createPodcast, createScripts]
        let voices = VoicesPage.allCases.map(\.tab)
        let settingsKeys = SettingsTab.allCases.map { settings($0) }
        return [home, books, inbox] + create + voices + [dictation, history, stats] + settingsKeys + [about, feedback]
    }

    static func title(for key: String?) -> String {
        guard let key = canonical(key) else { return "Home" }
        if let tab = settingsTab(for: key) {
            return tab.title
        }
        if let page = VoicesPage(tab: key) {
            return page.title
        }
        switch key {
        case createAudiobook: return "New Audiobook"
        case createPodcast: return "New Podcast"
        case createScripts, createScriptEditor: return "Scripts"
        case books, booksPlayer: return "Library"
        case inbox: return "Inbox"
        case dictation: return "Dictation"
        case history: return "History"
        case stats: return "Stats"
        case about: return "About"
        case feedback: return "Send Feedback"
        default: return "Home"
        }
    }
}

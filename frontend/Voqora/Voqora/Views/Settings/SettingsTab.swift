import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case permissions
    case appearance
    case speech
    case reading
    case audiobooks
    case dictation
    case engines
    case shortcuts
    case ai
    case integrations
    case privacy

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .general: "General"
        case .permissions: "Permissions"
        case .appearance: "Appearance"
        case .speech: "Speech"
        case .reading: "Reading Mode"
        case .audiobooks: "Audiobooks"
        case .dictation: "Dictation"
        case .engines: "Engines"
        case .shortcuts: "Shortcuts"
        case .ai: "AI"
        case .integrations: "Integrations"
        case .privacy: "Privacy & Data"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .permissions: "lock.shield"
        case .appearance: "paintpalette"
        case .speech: "waveform"
        case .reading: "text.book.closed"
        case .audiobooks: "books.vertical"
        case .dictation: "mic"
        case .engines: "cpu"
        case .shortcuts: "keyboard"
        case .ai: "sparkles"
        case .integrations: "puzzlepiece.extension"
        case .privacy: "hand.raised"
        }
    }

    var summary: String {
        switch self {
        case .general: "Startup, presence in the Dock and menu bar, updates and setup."
        case .permissions: "What macOS lets Voqora do, and how to turn it on."
        case .appearance: "Theme, accent color, app icon and font."
        case .speech: "Default voice, pace and how Voqora reads selections."
        case .reading: "How Reading Mode looks and scrolls."
        case .audiobooks: "Defaults for audiobooks you create."
        case .dictation: "Shortcut, language and what happens after you speak."
        case .engines: "Install and switch the speech engines that voice your audio."
        case .shortcuts: "Global keyboard shortcuts for reading and dictation."
        case .ai: "Providers behind cleanup, summaries and translation."
        case .integrations: "Connect Voqora to other apps and services."
        case .privacy: "Analytics, diagnostics and your data."
        }
    }
}

struct SettingsDetailView: View {
    let tab: SettingsTab

    var body: some View {
        CategoryRailHost(
            title: "Settings",
            items: SettingsTab.allCases.map { CategoryRailItem(key: TabKey.settings($0), title: $0.title, symbol: $0.symbol) },
            selectedKey: TabKey.settings(tab)
        ) {
            page.id(tab)
        }
    }

    @ViewBuilder
    private var page: some View {
        switch tab {
        case .general: GeneralSettingsPage()
        case .permissions: PermissionsSettingsPage()
        case .appearance: AppearanceSettingsPage()
        case .speech: SpeechSettingsPage()
        case .reading: ReadingSettingsPage()
        case .audiobooks: AudiobooksSettingsPage()
        case .dictation: DictationSettingsPage()
        case .engines: EnginesSettingsPage()
        case .shortcuts: ShortcutsSettingsPage()
        case .ai: AISettingsPage()
        case .integrations: IntegrationsSettingsPage()
        case .privacy: PrivacySettingsPage()
        }
    }
}

struct HelpDetailView: View {
    @EnvironmentObject var vm: DashboardViewModel

    private static let items = [
        CategoryRailItem(key: TabKey.about, title: "About", symbol: "info.circle"),
        CategoryRailItem(key: TabKey.feedback, title: "Send Feedback", symbol: "bubble.left"),
    ]

    var body: some View {
        CategoryRailHost(title: "Help", items: Self.items, selectedKey: vm.selectedTab ?? TabKey.about) {
            if vm.selectedTab == TabKey.feedback {
                FeedbackView()
            } else {
                AboutView()
            }
        }
    }
}

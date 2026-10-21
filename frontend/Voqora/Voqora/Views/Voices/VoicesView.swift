import SwiftUI

enum VoicesPage: String, CaseIterable, Identifiable {
    case catalog = "voices.catalog"
    case myVoices = "voices.mine"
    case pronunciations = "voices.pronunciations"

    init?(tab: String) {
        self.init(rawValue: tab)
    }

    var id: String {
        rawValue
    }

    var tab: String {
        rawValue
    }

    var title: String {
        switch self {
        case .myVoices: "My Voices"
        case .catalog: "Browse Voices"
        case .pronunciations: "Pronunciations"
        }
    }

    var icon: String {
        switch self {
        case .myVoices: "person.wave.2.fill"
        case .catalog: "square.grid.2x2.fill"
        case .pronunciations: "text.bubble.fill"
        }
    }

    var drawerTitle: String {
        title
    }

    var subtitle: String {
        switch self {
        case .myVoices:
            "Voices you made. Blend built-in voices, describe a new one, or clone one from a recording."
        case .catalog:
            "Every built-in voice on your Mac. Play a sample, then make it your default for speech or audiobooks."
        case .pronunciations:
            "Teach Voqora how to say names, acronyms and jargon. Rules apply everywhere or to one audiobook."
        }
    }
}

struct VoicesView: View {
    let page: VoicesPage

    var body: some View {
        switch page {
        case .myVoices: MyVoicesView()
        case .catalog: VoiceCatalogView()
        case .pronunciations: PronunciationsView()
        }
    }
}

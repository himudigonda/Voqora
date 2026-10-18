import SwiftUI

enum VoicesPage: String, CaseIterable, Identifiable {
    case myVoices = "voices"
    case catalog = "voices.catalog"
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
        case .catalog: "Voice Catalog"
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

    var subtitle: String {
        switch self {
        case .myVoices:
            "Mix two to four built-in voices into a voice of your own. Your voices appear in every voice picker under My Voices."
        case .catalog:
            "Every built-in voice, grouped by language. Play a sample, then choose it for speech or audiobooks."
        case .pronunciations:
            "Teach Voqora how to say names, acronyms and jargon. Entries apply everywhere or to one audiobook."
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

struct VoicesPageHeader: View {
    @EnvironmentObject var vm: DashboardViewModel
    let page: VoicesPage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(page.title)
                .font(vm.font(.pageTitle))
                .foregroundStyle(Palette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(page.subtitle)
                .font(vm.appFont(size: 14))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct VoicesStatusCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    let systemImage: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: systemImage)
                .foregroundStyle(Palette.textSecondary)
                .accessibilityHidden(true)
            Text(message)
                .font(vm.font(.rowTitle))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.voqoraSecondary)
            }
        }
        .padding(DesignTokens.Layout.cardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .voqoraSurface(.raised, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xLarge, style: .continuous))
    }
}

struct VoicesChip: View {
    @EnvironmentObject var vm: DashboardViewModel
    let text: String
    var tint: Color?

    var body: some View {
        let color = tint ?? Palette.textSecondary
        Text(text.uppercased())
            .font(vm.font(.chip))
            .kerning(0.6)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

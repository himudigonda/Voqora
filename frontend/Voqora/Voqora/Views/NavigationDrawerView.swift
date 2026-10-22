import SwiftUI

private struct DrawerPage {
    let tab: String
    let title: String
    let icon: String
}

struct NavigationDrawerView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var inbox: InboxViewModel
    @Environment(\.voqoraTheme) private var theme
    private static let titlebarClearance: CGFloat = 40

    static func highlightedKey(for tab: String?) -> String? {
        switch TabKey.canonical(tab) {
        case TabKey.createScriptEditor: TabKey.createScripts
        case TabKey.booksPlayer: TabKey.books
        default: TabKey.canonical(tab)
        }
    }

    private var key: String? {
        Self.highlightedKey(for: vm.selectedTab)
    }

    private var isSettingsActive: Bool {
        TabKey.settingsTab(for: key) != nil
    }

    private var isHelpActive: Bool {
        key == TabKey.about || key == TabKey.feedback
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: Self.titlebarClearance)
            brandHeader
            ScrollView {
                VStack(spacing: 2) {
                    item("Home", icon: "house", tab: TabKey.home)
                    item("Library", icon: "books.vertical", tab: TabKey.books)
                    item("Inbox", icon: "tray", tab: TabKey.inbox, badge: inbox.count(for: .unread))
                    createGroup
                    voicesGroup
                    item("Dictation", icon: "mic", tab: TabKey.dictation)
                    activityGroup
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)
            .clipped()
            pinnedFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surfaceContainerLow.ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .top)
        .navigationSplitViewColumnWidth(min: 240, ideal: 264, max: 300)
    }

    private var pinnedFooter: some View {
        VStack(spacing: 2) {
            Rectangle()
                .fill(theme.outlineVariant)
                .frame(height: 1)
                .padding(.bottom, 8)
            NavDrawerItem(title: "Settings", systemImage: "gearshape", isSelected: isSettingsActive) {
                if !isSettingsActive {
                    vm.selectedTab = TabKey.settings(.general)
                }
            }
            NavDrawerItem(title: "Help", systemImage: "questionmark.circle", isSelected: isHelpActive) {
                if !isHelpActive {
                    vm.selectedTab = TabKey.about
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var brandHeader: some View {
        HStack(spacing: 12) {
            Group {
                if let image = NSImage(named: vm.appIconID.assetName) {
                    Image(nsImage: image).resizable()
                } else {
                    Color.clear
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityHidden(true)
            Text("Voqora")
                .font(vm.font(.title))
                .foregroundStyle(theme.onSurface)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 12)
    }

    private var createGroup: some View {
        group("Create", icon: "wand.and.stars", storageKey: "drawer.create", pages: [
            DrawerPage(tab: TabKey.createAudiobook, title: "New Audiobook", icon: "book"),
            DrawerPage(tab: TabKey.createPodcast, title: "New Podcast", icon: "waveform.and.mic"),
            DrawerPage(tab: TabKey.createScripts, title: "Scripts", icon: "doc.text"),
        ])
    }

    private var voicesGroup: some View {
        let pages = VoicesPage.allCases.map { page in
            DrawerPage(tab: page.tab, title: page.drawerTitle, icon: page.icon)
        }
        return group("Voices", icon: "person.wave.2", storageKey: "drawer.voices", pages: pages)
    }

    private var activityGroup: some View {
        group("Activity", icon: "chart.bar", storageKey: "drawer.activity", pages: [
            DrawerPage(tab: TabKey.history, title: "History", icon: "clock.arrow.circlepath"),
            DrawerPage(tab: TabKey.stats, title: "Stats", icon: "chart.bar"),
        ])
    }

    private func group(
        _ title: String,
        icon: String,
        storageKey: String,
        defaultExpanded: Bool = true,
        pages: [DrawerPage]
    ) -> some View {
        NavDrawerGroup(
            title: title,
            systemImage: icon,
            storageKey: storageKey,
            isActive: pages.contains { $0.tab == key },
            defaultExpanded: defaultExpanded
        ) {
            ForEach(pages, id: \.tab) { page in
                item(page.title, icon: page.icon, tab: page.tab, indent: 12)
            }
        }
    }

    private func item(_ title: String, icon: String, tab: String, badge: Int? = nil, indent: CGFloat = 0) -> some View {
        NavDrawerItem(title: title, systemImage: icon, isSelected: key == tab, badge: badge, indent: indent) {
            if tab == TabKey.books {
                vm.showLibrary()
            } else {
                vm.selectedTab = tab
            }
        }
    }
}

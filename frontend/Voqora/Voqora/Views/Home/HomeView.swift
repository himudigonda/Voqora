import SwiftUI

struct HomeView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @EnvironmentObject var permissions: PermissionsService

    var body: some View {
        PageScaffold(title: "Home", subtitle: "Listen, create, and pick up where you left off.") {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                HomeNotices()
                hero
                HomeQuickActions()
                HomeRecentlyAdded()
            }
        }
        .overlay(alignment: .top) { HomeStatusMessage() }
        .navigationTitle("Home")
    }

    @ViewBuilder
    private var hero: some View {
        if vm.spokenText != nil {
            SpeechHeroCard()
        } else if let book = bookVM.nowPlaying ?? bookVM.continueListeningBook {
            ContinueListeningCard(book: book)
        }
    }
}

struct HomeStatusMessage: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    private var message: (text: String, isError: Bool)? {
        if let feedback = vm.actionFeedback {
            return (feedback, false)
        }
        if case let .error(text) = vm.status {
            return (text, true)
        }
        return nil
    }

    var body: some View {
        Group {
            if let message {
                Text(message.text)
                    .font(vm.font(.label))
                    .foregroundStyle(message.isError ? theme.danger : theme.onSurface)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 36)
                    .background(theme.surfaceContainerHighest, in: Capsule())
                    .overlay(Capsule().strokeBorder(theme.outlineVariant, lineWidth: 1))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                    .padding(.top, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Theme.Motion.selection, value: message?.text)
    }
}

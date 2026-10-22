import SwiftUI

struct HomeRecentlyAdded: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel

    static let limit = 6

    static func recent(_ books: [Audiobook]) -> [Audiobook] {
        Array(books.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    var body: some View {
        let books = Self.recent(bookVM.books)
        if !books.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.item) {
                HomeSectionHeader(title: "Recently added", actionTitle: "See all") {
                    vm.showLibrary()
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: Theme.Space.item + 4) {
                        ForEach(books) { book in
                            RecentBookTile(book: book)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

private struct RecentBookTile: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @Environment(\.voqoraTheme) private var theme
    let book: Audiobook
    @State private var hovering = false

    private static let width: CGFloat = 132

    private var isReady: Bool {
        (bookVM.processingState[book.bookID] ?? book.displayStatus).isReady
    }

    var body: some View {
        Button {
            if isReady {
                vm.openAudiobook(book.bookID)
            } else {
                vm.showLibrary()
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                BookCover(bookID: book.bookID)
                    .frame(width: Self.width, height: Self.width / BookCover.aspectRatio)
                    .shadow(color: .black.opacity(hovering ? 0.18 : 0.08), radius: hovering ? 12 : 5, y: hovering ? 6 : 2)
                Text(book.displayTitle)
                    .font(vm.font(.label))
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: Self.width, alignment: .leading)
                    .help(book.displayTitle)
            }
            .scaleEffect(hovering ? 1.02 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Theme.Motion.selection, value: hovering)
        .onHover { hovering = $0 }
        .accessibilityLabel(book.displayTitle)
    }
}

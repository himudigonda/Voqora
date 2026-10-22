import SwiftUI

struct BookCover: View {
    let bookID: String
    var radius: CGFloat = Theme.Shape.md

    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        Color.clear
            .overlay {
                AuthenticatedBackendImage(path: "audiobook/\(bookID)/cover") { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    placeholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(theme.outlineVariant, lineWidth: 1))
            .accessibilityHidden(true)
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [theme.primaryContainer, theme.secondaryContainer],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "book.closed.fill")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(theme.onPrimaryContainer.opacity(0.75))
        }
    }
}

extension BookCover {
    static let aspectRatio: CGFloat = 180.0 / 252.0
}

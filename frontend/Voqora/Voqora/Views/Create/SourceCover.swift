import PDFKit
import SwiftUI

struct SourceCover: View {
    let source: AudiobookImportSource?
    var size = CGSize(width: 84, height: 118)

    @Environment(\.voqoraTheme) private var theme
    @State private var thumbnail: NSImage?

    private var documentURL: URL? {
        source?.documentURL
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Shape.sm, style: .continuous)
                .fill(theme.surfaceContainerHigh)
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Shape.sm, style: .continuous))
            } else {
                Image(systemName: placeholderSymbol)
                    .font(.system(size: size.width * 0.34, weight: .regular))
                    .foregroundStyle(theme.onSurfaceMuted)
            }
        }
        .frame(width: size.width, height: size.height)
        .task(id: documentURL) { await loadThumbnail() }
        .accessibilityHidden(true)
    }

    private var placeholderSymbol: String {
        guard let source else { return "book.closed" }
        if source.webPageURL != nil {
            return "globe"
        }
        switch source.documentURL?.pathExtension.lowercased() {
        case "epub": return "book.closed.fill"
        case "txt", "md": return "text.alignleft"
        default: return "doc.fill"
        }
    }

    private func loadThumbnail() async {
        thumbnail = nil
        guard let url = documentURL else { return }
        let size = size
        let data = await Task.detached(priority: .utility) {
            Self.thumbnailData(for: url, size: size)
        }.value
        guard !Task.isCancelled, let data else { return }
        thumbnail = NSImage(data: data)
    }

    private nonisolated static func thumbnailData(for url: URL, size: CGSize) -> Data? {
        guard url.pathExtension.lowercased() == "pdf",
              let page = PDFDocument(url: url)?.page(at: 0)
        else { return nil }
        return page.thumbnail(of: NSSize(width: size.width * 2, height: size.height * 2), for: .cropBox).tiffRepresentation
    }
}

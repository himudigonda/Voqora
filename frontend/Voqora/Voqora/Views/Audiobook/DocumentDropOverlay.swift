import SwiftUI

/// Shared "drop a document here" overlay. Shown both by AudiobookLibraryView
/// (dropping onto the library) and VoqoraWindow (dropping from anywhere in
/// the app) — previously two independent implementations with drifted icon
/// size (72 vs 64), corner radius (24 vs 22), and padding (48 vs 40), so the
/// overlay visibly changed shape depending on which tab the drop landed on.
struct DocumentDropOverlay: View {
    let subtitle: String
    let appFont: (CGFloat, Font.Weight) -> Font

    var body: some View {
        ZStack {
            Color.primary.opacity(0.18).ignoresSafeArea()
                .background(.ultraThinMaterial)
            VStack(spacing: 24) {
                dropIcon
                Text("DROP TO ADD AUDIOBOOK")
                    .font(appFont(14, .black))
                    .kerning(3)
                    .foregroundStyle(.cyan)
                Text(subtitle)
                    .font(appFont(11, .regular))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(48)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.cyan.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            )
            .padding(60)
        }
    }

    @ViewBuilder
    private var dropIcon: some View {
        if #available(macOS 15.0, *) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 72, weight: .ultraLight))
                .foregroundStyle(.cyan)
                .symbolEffect(.bounce, options: .repeating)
        } else {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 72, weight: .ultraLight))
                .foregroundStyle(.cyan)
        }
    }
}

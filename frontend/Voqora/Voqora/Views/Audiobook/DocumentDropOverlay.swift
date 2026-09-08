import SwiftUI

/// Shared "drop a document here" overlay. Shown both by AudiobookLibraryView
/// (dropping onto the library) and VoqoraWindow (dropping from anywhere in
/// the app) — previously two independent implementations with drifted icon
/// size (72 vs 64), corner radius (24 vs 22), and padding (48 vs 40), so the
/// overlay visibly changed shape depending on which tab the drop landed on.
struct DocumentDropOverlay: View {
    // Not passed in by either call site (AudiobookLibraryView, VoqoraWindow)
    // — both already sit under the app root's `.environmentObject(dashboardVM)`,
    // so this resolves the same accent they'd otherwise have to thread through
    // an unchanged initializer.
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let subtitle: String
    let appFont: (CGFloat, Font.Weight) -> Font

    private var accentColor: Color {
        vm.accentColor(scheme: colorScheme, contrast: colorSchemeContrast)
    }

    var body: some View {
        ZStack {
            Palette.textPrimary.opacity(0.18).ignoresSafeArea()
            VStack(spacing: 24) {
                dropIcon
                Text("DROP TO ADD AUDIOBOOK")
                    .font(.system(size: 14, weight: .semibold))
                    .kerning(1.5)
                    .foregroundStyle(accentColor)
                Text(subtitle)
                    .font(appFont(11, .regular))
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(48)
            .voqoraSurface(.floating, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            )
            .padding(60)
        }
    }

    @ViewBuilder
    private var dropIcon: some View {
        if #available(macOS 15.0, *) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 72, weight: .ultraLight))
                .foregroundStyle(accentColor)
                .symbolEffect(.bounce, options: .repeating)
        } else {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 72, weight: .ultraLight))
                .foregroundStyle(accentColor)
        }
    }
}

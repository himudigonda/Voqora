import SwiftUI

struct DocumentDropOverlay: View {
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
                Text("Drop to Create Audiobook")
                    .font(.system(size: 14, weight: .semibold))
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

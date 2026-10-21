import SwiftUI

struct DocumentDropOverlay: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    let subtitle: String
    let appFont: (CGFloat, Font.Weight) -> Font

    var body: some View {
        ZStack {
            theme.onSurface.opacity(0.16).ignoresSafeArea()
            DropZone(title: "Drop to Create Audiobook", supporting: subtitle, isTargeted: true)
                .frame(maxWidth: 480)
                .background(theme.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: Theme.Shape.lg, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
                .padding(60)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

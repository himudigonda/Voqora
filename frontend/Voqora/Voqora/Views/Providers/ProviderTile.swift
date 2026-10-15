import SwiftUI

struct ProviderTile: View {
    let provider: LLMProvider
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(style.background)
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .strokeBorder(Color.black.opacity(style.outlined ? 0.08 : 0), lineWidth: 1)
            glyph
                .foregroundStyle(style.foreground)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var glyph: some View {
        switch style.mark {
        case let .symbol(name):
            Image(systemName: name)
                .font(.system(size: size * 0.46, weight: .semibold))
        case let .text(label):
            Text(label)
                .font(.system(size: size * (label.count > 2 ? 0.28 : 0.42), weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(.horizontal, size * 0.08)
        }
    }

    private var style: TileStyle {
        TileStyle(provider)
    }
}

private struct TileStyle {
    enum Mark {
        case symbol(String)
        case text(String)
    }

    let background: AnyShapeStyle
    let foreground: AnyShapeStyle
    let mark: Mark
    let outlined: Bool

    init(_ provider: LLMProvider) {
        switch provider {
        case .openai:
            self.init(.white, .black, .symbol("hexagon"), outlined: true)
        case .anthropic:
            self.init(Color(hex: 0xD4A27F), Color(hex: 0x191919), .text("A\\"))
        case .xai:
            self.init(.black, .white, .text("x"))
        case .groq:
            self.init(Color(hex: 0xF55036), .white, .text("groq"))
        case .cerebras:
            self.init(Color(hex: 0xF4F4F6), Color(hex: 0xF15A29), .symbol("circle.circle"), outlined: true)
        case .google:
            self.init(
                .white,
                LinearGradient(colors: [Color(hex: 0x4285F4), Color(hex: 0x9B72CB), Color(hex: 0xD96570)], startPoint: .topLeading, endPoint: .bottomTrailing),
                .symbol("sparkle"),
                outlined: true
            )
        case .openrouter:
            self.init(Color(hex: 0x2B2B35), .white, .symbol("arrow.triangle.branch"))
        case .ollama:
            self.init(.white, .black, .symbol("hare"), outlined: true)
        case .lmstudio:
            self.init(
                LinearGradient(colors: [Color(hex: 0x4F46E5), Color(hex: 0x7C3AED)], startPoint: .topLeading, endPoint: .bottomTrailing),
                .white,
                .symbol("text.alignleft")
            )
        case .custom:
            self.init(Color.clear, Color.accentColor, .symbol("server.rack"))
        }
    }

    private init(_ background: some ShapeStyle, _ foreground: some ShapeStyle, _ mark: Mark, outlined: Bool = false) {
        self.background = AnyShapeStyle(background)
        self.foreground = AnyShapeStyle(foreground)
        self.mark = mark
        self.outlined = outlined
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

import SwiftUI

struct PageBackAction {
    let title: String
    let action: () -> Void
}

struct PageScaffold<Accessory: View, Tabs: View, Content: View>: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    let title: String
    let subtitle: String?
    let scrolls: Bool
    let accessory: Accessory
    let tabs: Tabs
    let content: Content
    var back: PageBackAction?

    init(
        title: String,
        subtitle: String? = nil,
        scrolls: Bool = true,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder tabs: () -> Tabs,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.scrolls = scrolls
        self.accessory = accessory()
        self.tabs = tabs()
        self.content = content()
    }

    var body: some View {
        if scrolls {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.section) {
                    header
                    content
                }
                .frame(maxWidth: Theme.Space.pageMaxWidth, alignment: .leading)
                .padding(.horizontal, Theme.Space.gutter)
                .padding(.top, Self.topInset)
                .padding(.bottom, Theme.Space.gutter)
                .frame(maxWidth: .infinity)
            }
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                header
                    .padding(.horizontal, Theme.Space.gutter)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: Theme.Space.pageMaxWidth, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, Self.topInset)
            .frame(maxWidth: .infinity, minHeight: 0, idealHeight: 0, maxHeight: .infinity)
        }
    }

    func backButton(_ title: String, action: @escaping () -> Void) -> Self {
        var copy = self
        copy.back = PageBackAction(title: title, action: action)
        return copy
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.item + 4) {
            if let back {
                Button(action: back.action) {
                    Label(back.title, systemImage: "chevron.left")
                }
                .buttonStyle(.voqoraText)
                .padding(.leading, -12)
                .accessibilityLabel("Back to \(back.title)")
            }
            HStack(alignment: .top, spacing: Theme.Space.card) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(vm.font(.display))
                        .foregroundStyle(theme.onSurface)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle)
                            .font(vm.font(.body))
                            .foregroundStyle(theme.onSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Theme.Space.card)
                accessory
            }
            tabs
        }
    }

    private static var topInset: CGFloat {
        28
    }
}

extension PageScaffold where Tabs == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        scrolls: Bool = true,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title: title, subtitle: subtitle, scrolls: scrolls, accessory: accessory, tabs: { EmptyView() }, content: content)
    }
}

extension PageScaffold where Accessory == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        scrolls: Bool = true,
        tabs: Tabs,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title: title, subtitle: subtitle, scrolls: scrolls, accessory: { EmptyView() }, tabs: { tabs }, content: content)
    }
}

extension PageScaffold where Accessory == EmptyView, Tabs == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        scrolls: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title: title, subtitle: subtitle, scrolls: scrolls, accessory: { EmptyView() }, tabs: { EmptyView() }, content: content)
    }
}

extension DesignTokens.FontRole {
    static let scaffoldTitle = Self(size: 26, weight: .bold)
    static let scaffoldSubtitle = Self(size: 13, weight: .regular)
}

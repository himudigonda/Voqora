import SwiftUI

struct ReadingSettingsForm: View {
    @EnvironmentObject private var vm: DashboardViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ObservedObject var preferences: ReadingPreferences
    var showsPreview = true

    private var accentColor: Color {
        vm.accentColor(scheme: colorScheme, contrast: contrast)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if showsPreview {
                ReadingPreviewCard(preferences: preferences, increaseContrast: contrast == .increased)
                Divider()
            }
            typographySection
            Divider()
            themeSection
            Divider()
            guidanceSection
            footer
        }
    }

    private var typographySection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Font", systemImage: "textformat")
                    .font(vm.font(.rowTitle))
                Spacer()
                Picker("Font", selection: $preferences.typography.family) {
                    ForEach(ReadingFontFamily.allCases) { family in
                        Text(family.displayName).tag(family)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
            }

            ReadingSliderRow(
                title: "Text Size",
                systemImage: "textformat.size",
                value: $preferences.typography.fontSize,
                range: ReadingTypography.fontSizeRange,
                step: 1,
                accentColor: accentColor,
                format: { "\(Int($0.rounded())) pt" }
            )
            ReadingSliderRow(
                title: "Line Height",
                systemImage: "line.3.horizontal",
                value: $preferences.typography.lineHeight,
                range: ReadingTypography.lineHeightRange,
                step: 0.1,
                accentColor: accentColor,
                format: { String(format: "%.1f×", $0) }
            )
            ReadingSliderRow(
                title: "Letter Spacing",
                systemImage: "textformat.abc",
                value: $preferences.typography.letterSpacing,
                range: ReadingTypography.letterSpacingRange,
                step: 0.01,
                accentColor: accentColor,
                format: Self.percent
            )
            ReadingSliderRow(
                title: "Word Spacing",
                systemImage: "arrow.left.and.right",
                value: $preferences.typography.wordSpacing,
                range: ReadingTypography.wordSpacingRange,
                step: 0.05,
                accentColor: accentColor,
                format: Self.percent
            )
        }
    }

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Theme", systemImage: "circle.lefthalf.filled")
                    .font(vm.font(.rowTitle))
                Picker("Theme", selection: $preferences.theme) {
                    ForEach(ReadingTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("Soft Tint", systemImage: "drop")
                    .font(vm.font(.rowTitle))
                HStack(spacing: 12) {
                    ForEach(ReadingTint.allCases) { tint in
                        ReadingTintSwatch(
                            tint: tint,
                            theme: preferences.theme,
                            increaseContrast: contrast == .increased,
                            isSelected: preferences.tint == tint
                        ) {
                            preferences.tint = tint
                        }
                    }
                }
                .disabled(preferences.theme == .highContrast)
                Text(tintCaption)
                    .font(vm.font(.rowSubtitle))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var guidanceSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle(isOn: $preferences.showsRuler) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reading Ruler")
                        .font(vm.font(.rowTitle))
                    Text("Dims everything except the sentence being read.")
                        .font(vm.font(.rowSubtitle))
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .toggleStyle(.switch)

            Toggle(isOn: $preferences.emphasizesWords) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Word-by-Word Emphasis")
                        .font(vm.font(.rowTitle))
                    Text("Highlights each word as it is spoken when word timing is available. Otherwise the whole sentence is highlighted.")
                        .font(vm.font(.rowSubtitle))
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
        }
    }

    private var footer: some View {
        HStack {
            Text("Open Reading Mode from the player or the menu bar. Press Escape to close it.")
                .font(vm.font(.rowSubtitle))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Reset to Defaults") {
                preferences.resetToDefaults()
            }
            .buttonStyle(.borderless)
            .font(vm.font(.rowSubtitle))
            .foregroundStyle(accentColor)
        }
    }

    private var tintCaption: String {
        preferences.theme == .highContrast
            ? "High Contrast keeps a pure black page, so tints are off."
            : "A gentle color wash over the page. Some readers find a tint reduces glare and visual stress."
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

private struct ReadingSliderRow: View {
    @EnvironmentObject private var vm: DashboardViewModel
    let title: String
    let systemImage: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let accentColor: Color
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(vm.font(.rowTitle))
                Spacer()
                Text(format(value))
                    .font(vm.appFont(size: 14, weight: .bold).monospaced())
                    .foregroundStyle(accentColor)
            }
            Slider(value: $value, in: range, step: step)
                .tint(accentColor)
                .accessibilityLabel(title)
                .accessibilityValue(format(value))
        }
    }
}

private struct ReadingTintSwatch: View {
    let tint: ReadingTint
    let theme: ReadingTheme
    let increaseContrast: Bool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let palette = ReadingThemeResolver.palette(theme: theme, tint: tint, increaseContrast: increaseContrast)
        Button(action: action) {
            Circle()
                .fill(Color(palette.background))
                .frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(Palette.separator, lineWidth: 1))
                .overlay(
                    Circle()
                        .strokeBorder(Palette.textPrimary, lineWidth: isSelected ? 2 : 0)
                        .padding(-3)
                )
                .overlay {
                    if tint == .clear {
                        Image(systemName: "slash.circle")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color(palette.text).opacity(0.6))
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tint == .clear ? "No Tint" : "\(tint.displayName) Tint")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help(tint.displayName)
    }
}

private struct ReadingPreviewCard: View {
    @ObservedObject var preferences: ReadingPreferences
    let increaseContrast: Bool

    private static let sample = "Reading feels easier when the page fits you. Adjust the text until each line sits comfortably."

    var body: some View {
        let palette = ReadingThemeResolver.palette(theme: preferences.theme, tint: preferences.tint, increaseContrast: increaseContrast)
        Text(ReadingTextStyler.attributed(Self.sample, typography: preferences.typography, palette: palette, emphasis: nil))
            .font(preferences.typography.font(isHeading: false))
            .lineSpacing(preferences.typography.lineSpacing)
            .foregroundStyle(Color(palette.text))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignTokens.Spacing.xl)
            .background(Color(palette.background), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                    .strokeBorder(Palette.separator, lineWidth: 1)
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Reading preview")
            .accessibilityValue(Self.sample)
    }
}

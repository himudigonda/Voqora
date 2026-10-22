import SwiftUI

struct ReadingSettingsSections: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @ObservedObject var preferences: ReadingPreferences
    var showsPreview = true

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            if showsPreview {
                ReadingPreviewCard(preferences: preferences, increaseContrast: contrast == .increased)
            }
            typographySection
            themeSection
            guidanceSection
        }
    }

    private var typographySection: some View {
        SettingsSection(title: "Typography") {
            SettingsSegmentedRow(
                title: "Font",
                selection: $preferences.typography.family,
                options: Array(ReadingFontFamily.allCases),
                label: { $0.displayName }
            )
            SettingsSliderRow(
                title: "Text Size",
                value: $preferences.typography.fontSize,
                range: ReadingTypography.fontSizeRange,
                step: 1,
                valueLabel: "\(Int(preferences.typography.fontSize.rounded())) pt"
            )
            SettingsSliderRow(
                title: "Line Height",
                value: $preferences.typography.lineHeight,
                range: ReadingTypography.lineHeightRange,
                step: 0.1,
                valueLabel: String(format: "%.1f×", preferences.typography.lineHeight)
            )
            SettingsSliderRow(
                title: "Letter Spacing",
                value: $preferences.typography.letterSpacing,
                range: ReadingTypography.letterSpacingRange,
                step: 0.01,
                valueLabel: Self.percent(preferences.typography.letterSpacing)
            )
            SettingsSliderRow(
                title: "Word Spacing",
                value: $preferences.typography.wordSpacing,
                range: ReadingTypography.wordSpacingRange,
                step: 0.05,
                valueLabel: Self.percent(preferences.typography.wordSpacing)
            )
        }
    }

    private var themeSection: some View {
        SettingsSection(title: "Theme", footer: tintCaption) {
            SettingsSegmentedRow(
                title: "Theme",
                selection: $preferences.theme,
                options: Array(ReadingTheme.allCases),
                label: { $0.displayName }
            )
            SettingsValueRow(title: "Soft Tint") {
                HStack(spacing: 4) {
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
            }
        }
    }

    private var guidanceSection: some View {
        SettingsSection(title: "Guidance", footer: "Open Reading Mode from the player or the menu bar. Press Escape to close it.") {
            SettingsSwitchRow(
                title: "Reading Ruler",
                detail: "Dims everything except the sentence being read.",
                isOn: $preferences.showsRuler
            )
            SettingsSwitchRow(
                title: "Word-by-Word Emphasis",
                detail: "Highlights each word as it is spoken when word timing is available. Otherwise the whole sentence is highlighted.",
                isOn: $preferences.emphasizesWords
            )
            SettingsButtonRow(
                title: "Reset Reading Mode",
                detail: "Restore the default typography, theme and guidance.",
                buttonTitle: "Reset to Defaults"
            ) {
                preferences.resetToDefaults()
            }
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

private struct ReadingTintSwatch: View {
    @Environment(\.voqoraTheme) private var appTheme
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
                .frame(width: 30, height: 30)
                .overlay(Circle().strokeBorder(appTheme.outlineVariant, lineWidth: 1))
                .overlay(
                    Circle()
                        .strokeBorder(appTheme.onSurface, lineWidth: isSelected ? 2 : 0)
                        .padding(-4)
                )
                .padding(4)
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
    @Environment(\.voqoraTheme) private var theme

    private static let sample = "Reading feels easier when the page fits you. Adjust the text until each line sits comfortably."

    var body: some View {
        let palette = ReadingThemeResolver.palette(theme: preferences.theme, tint: preferences.tint, increaseContrast: increaseContrast)
        Text(ReadingTextStyler.attributed(Self.sample, typography: preferences.typography, palette: palette, emphasis: nil))
            .font(preferences.typography.font(isHeading: false))
            .lineSpacing(preferences.typography.lineSpacing)
            .foregroundStyle(Color(palette.text))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.card + 8)
            .background(Color(palette.background), in: RoundedRectangle(cornerRadius: Theme.Shape.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Shape.lg, style: .continuous)
                    .strokeBorder(theme.outlineVariant, lineWidth: 1)
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Reading preview")
            .accessibilityValue(Self.sample)
    }
}

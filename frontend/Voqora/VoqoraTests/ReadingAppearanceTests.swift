import SwiftUI
@testable import Voqora
import XCTest

@MainActor
final class ReadingAppearanceTests: XCTestCase {
    func test_typographyClampsEveryValueIntoItsRange() {
        let low = ReadingTypography(fontSize: 2, family: .serif, letterSpacing: -1, wordSpacing: -1, lineHeight: 0.2)
        XCTAssertEqual(low.fontSize, 14)
        XCTAssertEqual(low.letterSpacing, 0)
        XCTAssertEqual(low.wordSpacing, 0)
        XCTAssertEqual(low.lineHeight, 1.0)

        let high = ReadingTypography(fontSize: 300, family: .rounded, letterSpacing: 9, wordSpacing: 9, lineHeight: 9)
        XCTAssertEqual(high.fontSize, 48)
        XCTAssertEqual(high.letterSpacing, 0.25)
        XCTAssertEqual(high.wordSpacing, 1.0)
        XCTAssertEqual(high.lineHeight, 2.5)
    }

    func test_typographyRejectsNonFiniteValues() {
        var typography = ReadingTypography(fontSize: .nan, family: .standard, letterSpacing: .infinity, wordSpacing: .nan, lineHeight: .nan)
        XCTAssertEqual(typography, .standard)

        typography.fontSize = .infinity
        typography.lineHeight = -.infinity
        XCTAssertEqual(typography.fontSize, ReadingTypography.standard.fontSize)
        XCTAssertEqual(typography.lineHeight, ReadingTypography.standard.lineHeight)
    }

    func test_typographySettersClamp() {
        var typography = ReadingTypography.standard
        typography.fontSize = 100
        typography.lineHeight = 0
        typography.letterSpacing = 0.5
        typography.wordSpacing = 3

        XCTAssertEqual(typography.fontSize, 48)
        XCTAssertEqual(typography.lineHeight, 1.0)
        XCTAssertEqual(typography.letterSpacing, 0.25)
        XCTAssertEqual(typography.wordSpacing, 1.0)
    }

    func test_fontSizeStepsStopAtTheBounds() {
        let largest = ReadingTypography(fontSize: 47, family: .standard, letterSpacing: 0, wordSpacing: 0, lineHeight: 1.5)
            .adjustingFontSize(by: ReadingTypography.fontSizeStep)
        XCTAssertEqual(largest.fontSize, 48)
        XCTAssertFalse(largest.canIncreaseFontSize)
        XCTAssertTrue(largest.canDecreaseFontSize)

        let smallest = ReadingTypography(fontSize: 15, family: .standard, letterSpacing: 0, wordSpacing: 0, lineHeight: 1.5)
            .adjustingFontSize(by: -ReadingTypography.fontSizeStep)
        XCTAssertEqual(smallest.fontSize, 14)
        XCTAssertFalse(smallest.canDecreaseFontSize)
    }

    func test_typographyDerivesSpacingFromTheFontSize() {
        let typography = ReadingTypography(fontSize: 20, family: .standard, letterSpacing: 0.1, wordSpacing: 0.5, lineHeight: 2.0)

        XCTAssertEqual(typography.letterKerning, 2, accuracy: 0.0001)
        XCTAssertEqual(typography.wordKerning, 10, accuracy: 0.0001)
        XCTAssertEqual(typography.lineSpacing, 24, accuracy: 0.0001)
        XCTAssertEqual(typography.headingSize, 25, accuracy: 0.0001)
        XCTAssertEqual(ReadingTypography.standard.adjustingFontSize(by: 0).lineSpacing, CGFloat(0.5 * 24 * 1.2), accuracy: 0.0001)
        XCTAssertEqual(ReadingTypography(fontSize: 20, family: .standard, letterSpacing: 0, wordSpacing: 0, lineHeight: 1).lineSpacing, 0)
    }

    func test_fontFamiliesIncludeRoundedAndSerifDesigns() {
        XCTAssertEqual(ReadingFontFamily.rounded.design, .rounded)
        XCTAssertEqual(ReadingFontFamily.serif.design, .serif)
        XCTAssertEqual(ReadingFontFamily.standard.design, .default)
        XCTAssertEqual(ReadingFontFamily.monospaced.design, .monospaced)
    }

    func test_everyThemeAndTintKeepsTextHighlyLegible() {
        for theme in ReadingTheme.allCases {
            for tint in ReadingTint.allCases {
                for increaseContrast in [false, true] {
                    let palette = ReadingThemeResolver.palette(theme: theme, tint: tint, increaseContrast: increaseContrast)
                    let label = "\(theme) \(tint) \(increaseContrast)"
                    XCTAssertGreaterThanOrEqual(palette.text.wcagContrast(against: palette.background), 7, label)
                    XCTAssertGreaterThanOrEqual(palette.text.wcagContrast(against: palette.focusBand), 7, label)
                    XCTAssertGreaterThanOrEqual(palette.emphasisText.wcagContrast(against: palette.emphasis), 7, label)
                }
            }
        }
    }

    func test_tintWashesTheBackgroundExceptInHighContrast() {
        let plain = ReadingThemeResolver.palette(theme: .paper, tint: .clear, increaseContrast: false)
        let tinted = ReadingThemeResolver.palette(theme: .paper, tint: .aqua, increaseContrast: false)
        XCTAssertNotEqual(plain.background, tinted.background)

        let highContrast = ReadingThemeResolver.palette(theme: .highContrast, tint: .clear, increaseContrast: false)
        let highContrastTinted = ReadingThemeResolver.palette(theme: .highContrast, tint: .rose, increaseContrast: false)
        XCTAssertEqual(highContrast.background, highContrastTinted.background)
        XCTAssertEqual(highContrast.background, ColorRGBA(r: 0, g: 0, b: 0, a: 1))
    }

    func test_increaseContrastStrengthensTextAndSoftensTheRuler() {
        let standard = ReadingThemeResolver.palette(theme: .sepia, tint: .lemon, increaseContrast: false)
        let increased = ReadingThemeResolver.palette(theme: .sepia, tint: .lemon, increaseContrast: true)

        XCTAssertGreaterThan(increased.text.wcagContrast(against: increased.background), standard.text.wcagContrast(against: standard.background))
        XCTAssertGreaterThan(increased.dimmedOpacity, standard.dimmedOpacity)
        XCTAssertEqual(ReadingThemeResolver.palette(theme: .highContrast, tint: .clear, increaseContrast: false).dimmedOpacity, increased.dimmedOpacity)
    }

    func test_darkThemesReportDarkAppearance() {
        XCTAssertFalse(ReadingThemeResolver.palette(theme: .paper, tint: .clear, increaseContrast: false).isDark)
        XCTAssertFalse(ReadingThemeResolver.palette(theme: .sepia, tint: .clear, increaseContrast: false).isDark)
        XCTAssertTrue(ReadingThemeResolver.palette(theme: .dark, tint: .clear, increaseContrast: false).isDark)
        XCTAssertTrue(ReadingThemeResolver.palette(theme: .highContrast, tint: .clear, increaseContrast: false).isDark)
    }

    func test_textStylerWidensSpacesAndMarksTheEmphasizedWord() {
        let text = "One two three"
        let typography = ReadingTypography(fontSize: 20, family: .standard, letterSpacing: 0.05, wordSpacing: 0.5, lineHeight: 1.5)
        let palette = ReadingThemeResolver.palette(theme: .paper, tint: .clear, increaseContrast: false)
        let emphasis = text.range(of: "two")
        let styled = ReadingTextStyler.attributed(text, typography: typography, palette: palette, emphasis: emphasis)

        var spaceKerns: [CGFloat] = []
        var letterKerns: [CGFloat] = []
        var emphasized: [String] = []
        for run in styled.runs {
            let content = String(styled[run.range].characters)
            let kern = run[AttributeScopes.SwiftUIAttributes.KerningAttribute.self]
            if content == " " {
                spaceKerns.append(kern ?? 0)
            } else {
                letterKerns.append(kern ?? 0)
            }
            if run[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] != nil {
                emphasized.append(content)
            }
        }

        XCTAssertEqual(String(styled.characters), text)
        XCTAssertEqual(spaceKerns.count, 2)
        XCTAssertTrue(spaceKerns.allSatisfy { abs($0 - 11) < 0.0001 })
        XCTAssertTrue(letterKerns.allSatisfy { abs($0 - 1) < 0.0001 })
        XCTAssertEqual(emphasized, ["two"])
    }

    func test_textStylerLeavesSpacesAloneWithoutWordSpacing() {
        let styled = ReadingTextStyler.attributed(
            "One two",
            typography: .standard,
            palette: ReadingThemeResolver.palette(theme: .dark, tint: .clear, increaseContrast: false),
            emphasis: nil
        )

        XCTAssertEqual(styled.runs.count, 1)
    }
}

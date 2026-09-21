import SwiftUI
@testable import Voqora
import XCTest

@MainActor
final class AccentContrastTests: XCTestCase {
    private let appearances: [(ColorScheme, Bool)] = [
        (.light, false), (.light, true), (.dark, false), (.dark, true),
    ]

    func test_onAccentInkClearsAAAgainstItsOwnAccentFill() {
        for option in AccentColorOption.allCases {
            for (scheme, increaseContrast) in appearances {
                let ramp = Palette.accentRamp(for: option, appearance: scheme, increaseContrast: increaseContrast)
                let contrast = ramp.onAccent.wcagContrast(against: ramp.base)
                XCTAssertGreaterThanOrEqual(
                    contrast, 4.5,
                    "\(option.rawValue)/\(scheme)/contrast=\(increaseContrast): onAccent on base is \(contrast):1"
                )
            }
        }
    }

    func test_whiteLabelFailsAAOnDarkModeAccentFills() throws {
        let white = try XCTUnwrap(ColorRGBA(hex: "#FFFFFF"))
        for option in AccentColorOption.allCases {
            let ramp = Palette.accentRamp(for: option, appearance: .dark, increaseContrast: false)
            XCTAssertLessThan(
                white.wcagContrast(against: ramp.base), 4.5,
                """
                \(option.rawValue) dark base now carries a white label at AA. \
                Accent-filled buttons use VoqoraPrimaryButtonStyle's onAccent ink \
                precisely because white does not; re-check that choice before relaxing this.
                """
            )
        }
    }

    func test_onDangerInkClearsAAAgainstTheDangerFill() throws {
        let fills = [
            ("light", "#C6483C"), ("dark", "#F08379"),
            ("highContrastLight", "#A32E24"), ("highContrastDark", "#FF9E96"),
        ]
        let inks = try [XCTUnwrap(ColorRGBA(hex: "#FFFFFF")), XCTUnwrap(ColorRGBA(hex: "#181817"))]
        for (name, hex) in fills {
            let fill = try XCTUnwrap(ColorRGBA(hex: hex))
            let best = inks.map { $0.wcagContrast(against: fill) }.max() ?? 0
            XCTAssertGreaterThanOrEqual(
                best, 4.5,
                "danger/\(name): no ink clears AA against \(hex)"
            )
        }
    }

    func test_whiteLabelFailsAAOnDarkModeDangerFills() throws {
        let white = try XCTUnwrap(ColorRGBA(hex: "#FFFFFF"))
        for (name, hex) in [("dark", "#F08379"), ("highContrastDark", "#FF9E96")] {
            XCTAssertLessThan(
                try white.wcagContrast(against: XCTUnwrap(ColorRGBA(hex: hex))), 4.5,
                """
                danger/\(name) now carries a white label at AA. Destructive buttons \
                use VoqoraDestructiveButtonStyle's onDanger ink precisely because \
                white does not; re-check that choice before relaxing this.
                """
            )
        }
    }
}

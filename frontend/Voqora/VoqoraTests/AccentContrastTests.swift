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
}

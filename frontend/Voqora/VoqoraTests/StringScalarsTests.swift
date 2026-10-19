@testable import Voqora
import XCTest

final class StringScalarsTests: XCTestCase {
    func test_scalarCountMatchesCodePointsNotCharacters() {
        let accented = "e\u{301}"
        XCTAssertEqual(accented.count, 1)
        XCTAssertEqual(accented.scalarCount, 2)
        XCTAssertEqual("\u{1F468}\u{200D}\u{1F469}".count, 1)
        XCTAssertEqual("\u{1F468}\u{200D}\u{1F469}".scalarCount, 3)
        XCTAssertEqual("plain".scalarCount, 5)
    }

    func test_scalarPrefixCutsByCodePoints() {
        XCTAssertEqual("abcdef".scalarPrefix(3), "abc")
        XCTAssertEqual("ab".scalarPrefix(10), "ab")
        XCTAssertEqual(String(repeating: "e\u{301}", count: 10).scalarPrefix(6).scalarCount, 6)
    }
}

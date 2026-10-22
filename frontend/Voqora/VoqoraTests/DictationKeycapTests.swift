@testable import Voqora
import XCTest

final class DictationKeycapTests: XCTestCase {
    func test_modifiersSplitOnePerCapAndKeyNameStaysWhole() {
        XCTAssertEqual(DictationStateLabel.keycaps(from: "⌃⌥Space"), ["⌃", "⌥", "Space"])
        XCTAssertEqual(DictationStateLabel.keycaps(from: "^⌥Space"), ["⌃", "⌥", "Space"])
        XCTAssertEqual(DictationStateLabel.keycaps(from: "⌘⇧F12"), ["⌘", "⇧", "F12"])
        XCTAssertEqual(DictationStateLabel.keycaps(from: "⌘Return"), ["⌘", "Return"])
        XCTAssertEqual(DictationStateLabel.keycaps(from: "⌥Tab"), ["⌥", "Tab"])
    }

    func test_bareKeyAndEmptyInput() {
        XCTAssertEqual(DictationStateLabel.keycaps(from: "F5"), ["F5"])
        XCTAssertEqual(DictationStateLabel.keycaps(from: "⌘"), ["⌘"])
        XCTAssertTrue(DictationStateLabel.keycaps(from: "").isEmpty)
    }
}

final class PronunciationBookOptionTests: XCTestCase {
    func test_duplicateTitlesGetNumberedSuffixInStableOrder() {
        let options = PronunciationBookOption.disambiguated([
            (id: "bb", title: "Market Mechanics Crash Course"),
            (id: "aa", title: "Market Mechanics Crash Course"),
            (id: "cc", title: "Atlas"),
        ])
        XCTAssertEqual(options.map(\.title), ["Atlas", "Market Mechanics Crash Course", "Market Mechanics Crash Course (2)"])
        XCTAssertEqual(options.map(\.id), ["cc", "aa", "bb"])
    }

    func test_uniqueTitlesAreUntouched() {
        let options = PronunciationBookOption.disambiguated([(id: "a", title: "One"), (id: "b", title: "Two")])
        XCTAssertEqual(options.map(\.title), ["One", "Two"])
    }
}

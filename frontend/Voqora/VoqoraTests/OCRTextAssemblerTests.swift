import CoreGraphics
import Foundation
@testable import Voqora
import XCTest

final class OCRTextAssemblerTests: XCTestCase {
    private func line(_ text: String, top: CGFloat, height: CGFloat = 0.04, x: CGFloat = 0.1, width: CGFloat = 0.8) -> OCRLine {
        OCRLine(text: text, bounds: CGRect(x: x, y: top - height, width: width, height: height))
    }

    func test_emptyInputProducesEmptyText() {
        XCTAssertEqual(OCRTextAssembler.assemble([]), "")
        XCTAssertEqual(OCRTextAssembler.assemble([line("   ", top: 0.9)]), "")
    }

    func test_consecutiveLinesMergeIntoOneParagraph() {
        let text = OCRTextAssembler.assemble([
            line("The quick brown fox", top: 0.90),
            line("jumps over the lazy dog.", top: 0.85),
        ])
        XCTAssertEqual(text, "The quick brown fox jumps over the lazy dog.")
    }

    func test_hyphenatedLineBreakJoinsWordWithoutHyphen() {
        let text = OCRTextAssembler.assemble([
            line("An extraordi-", top: 0.90),
            line("nary result.", top: 0.85),
        ])
        XCTAssertEqual(text, "An extraordinary result.")
    }

    func test_hyphenBeforeCapitalizedWordIsKept() {
        let text = OCRTextAssembler.assemble([
            line("Trans-", top: 0.90),
            line("Atlantic flights", top: 0.85),
        ])
        XCTAssertEqual(text, "Trans- Atlantic flights")
    }

    func test_standaloneDashIsNotTreatedAsHyphenation() {
        XCTAssertFalse(OCRTextAssembler.endsWithLineBreakHyphen("costs 5 -"))
        XCTAssertTrue(OCRTextAssembler.endsWithLineBreakHyphen("extraordi-"))
    }

    func test_largeVerticalGapStartsNewParagraph() {
        let text = OCRTextAssembler.assemble([
            line("First paragraph line", top: 0.90),
            line("Second paragraph line", top: 0.78),
        ])
        XCTAssertEqual(text, "First paragraph line\n\nSecond paragraph line")
    }

    func test_shortLineEndingSentenceStartsNewParagraph() {
        let text = OCRTextAssembler.assemble([
            line("The end of a thought.", top: 0.90, width: 0.3),
            line("A new paragraph begins here and runs wide", top: 0.85),
        ])
        XCTAssertEqual(text, "The end of a thought.\n\nA new paragraph begins here and runs wide")
    }

    func test_fullWidthLineEndingSentenceStaysInParagraph() {
        let text = OCRTextAssembler.assemble([
            line("This line ends a sentence.", top: 0.90),
            line("This one continues the paragraph", top: 0.85),
        ])
        XCTAssertEqual(text, "This line ends a sentence. This one continues the paragraph")
    }

    func test_jumpBackUpToNewColumnStartsNewParagraph() {
        let text = OCRTextAssembler.assemble([
            line("Bottom of column one", top: 0.20, x: 0.05, width: 0.4),
            line("Top of column two", top: 0.90, x: 0.55, width: 0.4),
        ])
        XCTAssertEqual(text, "Bottom of column one\n\nTop of column two")
    }

    func test_sideBySideFragmentsOnOneRowJoinWithSpace() {
        let text = OCRTextAssembler.assemble([
            line("Name:", top: 0.90, x: 0.1, width: 0.2),
            line("Voqora", top: 0.90, x: 0.4, width: 0.2),
        ])
        XCTAssertEqual(text, "Name: Voqora")
    }

    func test_cjkLinesJoinWithoutSpace() {
        let text = OCRTextAssembler.assemble([
            line("敏捷的棕色狐狸", top: 0.90),
            line("跳过了那只懒狗", top: 0.85),
        ])
        XCTAssertEqual(text, "敏捷的棕色狐狸跳过了那只懒狗")
    }

    func test_internalWhitespaceIsNormalized() {
        let text = OCRTextAssembler.assemble([line("  spaced \t  out   words ", top: 0.9)])
        XCTAssertEqual(text, "spaced out words")
    }

    func test_zeroHeightLinesNeverSplit() {
        let first = OCRLine(text: "One", bounds: CGRect(x: 0, y: 0.9, width: 0.5, height: 0))
        let second = OCRLine(text: "Two", bounds: CGRect(x: 0, y: 0.1, width: 0.5, height: 0))
        XCTAssertFalse(OCRTextAssembler.startsParagraph(after: first, next: second))
    }
}

@testable import Voqora
import XCTest

final class VoqoraTests: XCTestCase {
    func testTelemetryVerificationOverrideRequiresAnExactOne() {
        XCTAssertTrue(RuntimeEnvironment.disablesTelemetry(in: ["VOQORA_DISABLE_TELEMETRY": "1"]))
        XCTAssertFalse(RuntimeEnvironment.disablesTelemetry(in: [:]))
        XCTAssertFalse(RuntimeEnvironment.disablesTelemetry(in: ["VOQORA_DISABLE_TELEMETRY": "true"]))
    }

    func testTextSanitization_CleanURLs() {
        let input = "Check this out https://example.com/cool"
        let options = TextProcessor.Options(cleanURLs: true, cleanHandles: false, fixLigatures: false, expandAbbr: false)
        let output = TextProcessor.sanitize(input, options: options)
        XCTAssertEqual(output, "Check this out link")
    }

    func testTextSanitization_FixLigatures() {
        let input = "The f ish and the f ly"
        let options = TextProcessor.Options(cleanURLs: false, cleanHandles: false, fixLigatures: true, expandAbbr: false)
        let output = TextProcessor.sanitize(input, options: options)
        XCTAssertEqual(output, "The fish and the fly")
    }

    func testTextSanitization_CleanHandles() {
        let input = "Hello @user123 and @test_account"
        let options = TextProcessor.Options(cleanURLs: false, cleanHandles: true, fixLigatures: false, expandAbbr: false)
        let output = TextProcessor.sanitize(input, options: options)
        XCTAssertEqual(output, "Hello and")
    }

    func testTextSanitization_ExpandAbbr() {
        let input = "Visit st. James vs. the park etc."
        let options = TextProcessor.Options(cleanURLs: false, cleanHandles: false, fixLigatures: false, expandAbbr: true)
        let output = TextProcessor.sanitize(input, options: options)
        XCTAssertEqual(output, "Visit street James versus the park etcetera")
    }

    func testTextSanitization_MultipleSpaces() {
        let input = "This    has  too many    spaces."
        let options = TextProcessor.Options(cleanURLs: false, cleanHandles: false, fixLigatures: false, expandAbbr: false)
        let output = TextProcessor.sanitize(input, options: options)
        XCTAssertEqual(output, "This has too many spaces.")
    }

    func testTextSanitization_Composite() {
        let input = "Check @handle for etc. a f ish at https://bing.com"
        let options = TextProcessor.Options(cleanURLs: true, cleanHandles: true, fixLigatures: true, expandAbbr: true)
        let output = TextProcessor.sanitize(input, options: options)
        XCTAssertEqual(output, "Check for etcetera a fish at link")
    }

    func testTextSanitization_StripMarkdownHeadingsAndEmphasis() {
        let input = "## Heading\nThis is **bold** and *italic* text."
        let options = TextProcessor.Options(cleanURLs: false, cleanHandles: false, fixLigatures: false, expandAbbr: false)
        let output = TextProcessor.sanitize(input, options: options)
        XCTAssertEqual(output, "Heading This is bold and italic text.")
    }

    func testTextSanitization_StripMarkdownCode() {
        let input = "Run `npm install` to start.\n```swift\nlet x = 1\n```"
        let options = TextProcessor.Options(cleanURLs: false, cleanHandles: false, fixLigatures: false, expandAbbr: false)
        let output = TextProcessor.sanitize(input, options: options)
        XCTAssertEqual(output, "Run npm install to start. let x = 1")
    }

    func testTextSanitization_StripMarkdownLinks() {
        let input = "See [the docs](https://example.com/docs) for more."
        let options = TextProcessor.Options(cleanURLs: false, cleanHandles: false, fixLigatures: false, expandAbbr: false)
        let output = TextProcessor.sanitize(input, options: options)
        XCTAssertEqual(output, "See the docs for more.")
    }

    func testTextSanitization_StripMarkdownListsAndQuotes() {
        let input = "- item one\n- item two\n> a quoted line"
        let options = TextProcessor.Options(cleanURLs: false, cleanHandles: false, fixLigatures: false, expandAbbr: false)
        let output = TextProcessor.sanitize(input, options: options)
        XCTAssertEqual(output, "item one item two a quoted line")
    }

    func testTextSanitization_StripMarkdownCanBeDisabled() {
        let input = "## Heading with *emphasis*"
        let options = TextProcessor.Options(cleanURLs: false, cleanHandles: false, fixLigatures: false, expandAbbr: false, stripMarkdown: false)
        let output = TextProcessor.sanitize(input, options: options)
        XCTAssertEqual(output, "## Heading with *emphasis*")
    }

    private func spoken(_ input: String, cleanURLs: Bool = false) -> String {
        TextProcessor.sanitize(
            input,
            options: .init(cleanURLs: cleanURLs, cleanHandles: false, fixLigatures: false, expandAbbr: false)
        )
    }

    func testOrderedListMarkersAreStripped() {
        let output = TextProcessor.sanitize(
            "1. First item\n2. Second item",
            options: .init(cleanURLs: false, cleanHandles: false, fixLigatures: false, expandAbbr: false, expandNumbers: true)
        )
        XCTAssertFalse(output.contains("one."), output)
        XCTAssertTrue(output.contains("First item"), output)
        XCTAssertTrue(output.contains("Second item"), output)
    }

    func testPipeTablesAreNotSpoken() {
        let output = spoken("| Name | Age |\n| --- | --- |\n| Alice | 30 |")
        XCTAssertFalse(output.contains("|"), output)
        XCTAssertTrue(output.contains("Alice"), output)
    }

    func testHTMLTagsAreStripped() {
        let output = spoken("Some <b>bold</b> and <br/> text.")
        XCTAssertFalse(output.contains("<"), output)
        XCTAssertTrue(output.contains("bold"), output)
    }

    func testSetextHeadingUnderlineIsStripped() {
        let output = spoken("My Title\n========\n\nBody text.")
        XCTAssertFalse(output.contains("="), output)
        XCTAssertTrue(output.contains("My Title"), output)
    }

    func testTaskListCheckboxesAreStripped() {
        let output = spoken("- [ ] Buy milk\n- [x] Walk dog")
        XCTAssertFalse(output.contains("["), output)
        XCTAssertTrue(output.contains("Buy milk"), output)
    }

    func testURLReplacementDoesNotIntroduceBrackets() {
        let output = spoken("Check https://example.com now", cleanURLs: true)
        XCTAssertFalse(output.contains("["), output)
        XCTAssertFalse(output.contains("]"), output)
        XCTAssertTrue(output.contains("Check"), output)
        XCTAssertTrue(output.contains("now"), output)
    }

    func testSnakeCaseIdentifiersAreNotCorrupted() {
        let output = spoken("Call get_user_name and max_retry_count.")
        XCTAssertTrue(output.contains("get_user_name"), output)
        XCTAssertTrue(output.contains("max_retry_count"), output)
    }

    func testUnderscoresInSeparateWordsAreNotMerged() {
        let output = spoken("value_a and value_b")
        XCTAssertTrue(output.contains("value_a"), output)
        XCTAssertTrue(output.contains("value_b"), output)
    }

    func testMultiplicationSignsAreNotDeleted() {
        let output = spoken("5 * 3 and 4 * 8")
        XCTAssertTrue(output.contains("5 * 3"), output)
        XCTAssertTrue(output.contains("4 * 8"), output)
    }
}

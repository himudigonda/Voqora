@testable import Voqora
import XCTest

final class VoqoraTests: XCTestCase {
    func testTelemetryVerificationOverrideRequiresAnExactOne() {
        XCTAssertTrue(RuntimeEnvironment.disablesTelemetry(in: ["VOQORA_DISABLE_TELEMETRY": "1"]))
        XCTAssertFalse(RuntimeEnvironment.disablesTelemetry(in: [:]))
        XCTAssertFalse(RuntimeEnvironment.disablesTelemetry(in: ["VOQORA_DISABLE_TELEMETRY": "true"]))
    }

    /// Test 1: Verify Text Processor strips URLs correctly
    func testTextSanitization_CleanURLs() {
        let input = "Check this out https://example.com/cool"
        let options = TextProcessor.Options(cleanURLs: true, cleanHandles: false, fixLigatures: false, expandAbbr: false)
        let output = TextProcessor.sanitize(input, options: options)
        XCTAssertEqual(output, "Check this out [link]")
    }

    /// Test 2: Verify Ligature fixing
    /// Logic replaces "f i" with "fi", "f l" with "fl"
    /// Input adjusted to "f ish" so "f i" -> "fi" creates "fish"
    func testTextSanitization_FixLigatures() {
        let input = "The f ish and the f ly"
        let options = TextProcessor.Options(cleanURLs: false, cleanHandles: false, fixLigatures: true, expandAbbr: false)
        let output = TextProcessor.sanitize(input, options: options)
        XCTAssertEqual(output, "The fish and the fly")
    }

    /// Test 3: Verify Handle cleaning
    func testTextSanitization_CleanHandles() {
        let input = "Hello @user123 and @test_account"
        let options = TextProcessor.Options(cleanURLs: false, cleanHandles: true, fixLigatures: false, expandAbbr: false)
        let output = TextProcessor.sanitize(input, options: options)
        // Sanitizer reduces multiple spaces to one
        XCTAssertEqual(output, "Hello and")
    }

    /// Test 4: Verify complex abbreviation expansion
    func testTextSanitization_ExpandAbbr() {
        let input = "Visit st. James vs. the park etc."
        let options = TextProcessor.Options(cleanURLs: false, cleanHandles: false, fixLigatures: false, expandAbbr: true)
        let output = TextProcessor.sanitize(input, options: options)
        XCTAssertEqual(output, "Visit street James versus the park etcetera")
    }

    /// Test 5: Verify multiple space reduction
    func testTextSanitization_MultipleSpaces() {
        let input = "This    has  too many    spaces."
        let options = TextProcessor.Options(cleanURLs: false, cleanHandles: false, fixLigatures: false, expandAbbr: false)
        let output = TextProcessor.sanitize(input, options: options)
        XCTAssertEqual(output, "This has too many spaces.")
    }

    /// Test 6: Composite test with corrected input for clean merging
    func testTextSanitization_Composite() {
        let input = "Check @handle for etc. a f ish at https://bing.com"
        let options = TextProcessor.Options(cleanURLs: true, cleanHandles: true, fixLigatures: true, expandAbbr: true)
        let output = TextProcessor.sanitize(input, options: options)
        XCTAssertEqual(output, "Check for etcetera a fish at [link]")
    }

    /// Test 7: Markdown headings and emphasis shouldn't be read aloud as
    /// "pound"/"asterisk" when a shortcut fires over raw Markdown source.
    func testTextSanitization_StripMarkdownHeadingsAndEmphasis() {
        let input = "## Heading\nThis is **bold** and *italic* text."
        let options = TextProcessor.Options(cleanURLs: false, cleanHandles: false, fixLigatures: false, expandAbbr: false)
        let output = TextProcessor.sanitize(input, options: options)
        XCTAssertEqual(output, "Heading This is bold and italic text.")
    }

    /// Test 8: Inline code and fenced code blocks keep their content, not
    /// their backtick delimiters.
    func testTextSanitization_StripMarkdownCode() {
        let input = "Run `npm install` to start.\n```swift\nlet x = 1\n```"
        let options = TextProcessor.Options(cleanURLs: false, cleanHandles: false, fixLigatures: false, expandAbbr: false)
        let output = TextProcessor.sanitize(input, options: options)
        XCTAssertEqual(output, "Run npm install to start. let x = 1")
    }

    /// Test 9: Markdown links keep the visible text, not the URL or brackets.
    func testTextSanitization_StripMarkdownLinks() {
        let input = "See [the docs](https://example.com/docs) for more."
        let options = TextProcessor.Options(cleanURLs: false, cleanHandles: false, fixLigatures: false, expandAbbr: false)
        let output = TextProcessor.sanitize(input, options: options)
        XCTAssertEqual(output, "See the docs for more.")
    }

    /// Test 10: List markers and blockquote carets are dropped, not read aloud.
    func testTextSanitization_StripMarkdownListsAndQuotes() {
        let input = "- item one\n- item two\n> a quoted line"
        let options = TextProcessor.Options(cleanURLs: false, cleanHandles: false, fixLigatures: false, expandAbbr: false)
        let output = TextProcessor.sanitize(input, options: options)
        XCTAssertEqual(output, "item one item two a quoted line")
    }

    /// Test 11: stripMarkdown can be turned off to preserve literal Markdown
    /// characters, matching every other TextProcessor option.
    func testTextSanitization_StripMarkdownCanBeDisabled() {
        let input = "## Heading with *emphasis*"
        let options = TextProcessor.Options(cleanURLs: false, cleanHandles: false, fixLigatures: false, expandAbbr: false, stripMarkdown: false)
        let output = TextProcessor.sanitize(input, options: options)
        XCTAssertEqual(output, "## Heading with *emphasis*")
    }
}

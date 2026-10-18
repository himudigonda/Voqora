import Foundation
@testable import Voqora
import XCTest

@MainActor
final class PodcastBriefTests: XCTestCase {
    private func textBrief(_ text: String = "Notes about stars.") -> PodcastBrief {
        var brief = PodcastBrief()
        brief.text = text
        return brief
    }

    func test_defaultBriefHasTwoEnglishHostsAndBuildsRequest() throws {
        let brief = textBrief("  Notes about stars.  ")

        XCTAssertEqual(brief.hosts.count, 2)
        XCTAssertEqual(brief.hosts.map(\.voice), ["af_bella", "am_adam"])
        let request = try XCTUnwrap(brief.request(blends: []))
        XCTAssertEqual(request.source, .text("Notes about stars."))
        XCTAssertEqual(request.style, .deepDive)
        XCTAssertEqual(request.minutes, PodcastLimits.defaultMinutes)
        XCTAssertEqual(request.language, .englishUS)
        XCTAssertNil(request.title)
    }

    func test_sourceIsRequired() {
        XCTAssertEqual(textBrief(" ").issues(blends: []), [.missingText])
        var library = PodcastBrief()
        library.sourceKind = .library
        XCTAssertEqual(library.issues(blends: []), [.missingBook])
        library.bookID = String(repeating: "a", count: 32)
        XCTAssertEqual(library.issues(blends: []), [])
        XCTAssertEqual(library.request(blends: [])?.source, .book(String(repeating: "a", count: 32)))
    }

    func test_sourceTextIsCapped() {
        let brief = textBrief(String(repeating: "a", count: PodcastLimits.sourceCharacters + 1))

        XCTAssertEqual(brief.issues(blends: []), [.textTooLong(length: PodcastLimits.sourceCharacters + 1)])
        XCTAssertNil(brief.request(blends: []))
    }

    func test_hostCountFollowsStyle() {
        var brief = textBrief()
        brief.applyStyle(.lecture)
        XCTAssertEqual(brief.hosts.count, 1)
        XCTAssertFalse(brief.canAddHost)
        XCTAssertFalse(brief.canRemoveHost)

        brief.applyStyle(.debate)
        XCTAssertEqual(brief.hosts.count, 2)
        XCTAssertNotEqual(brief.hosts[0].name, brief.hosts[1].name)
        XCTAssertFalse(brief.canRemoveHost)

        brief.hosts.removeLast()
        XCTAssertEqual(brief.issues(blends: []), [.hostCount(.debate)])
    }

    func test_hostNamesMustBePresentAndDifferent() {
        var brief = textBrief()
        brief.hosts[1].name = " avery "
        XCTAssertEqual(brief.issues(blends: []), [.duplicateHostNames])

        brief.hosts[1].name = ""
        XCTAssertEqual(brief.issues(blends: []), [.missingHostName(host: 1)])

        brief.hosts[1].name = String(repeating: "n", count: PodcastLimits.speakerNameCharacters + 1)
        XCTAssertEqual(brief.issues(blends: []), [.hostNameTooLong(host: 1)])
    }

    func test_voicesMustSpeakTheLanguage() {
        var brief = textBrief()
        brief.language = .spanish

        XCTAssertEqual(brief.issues(blends: []), [
            .voiceLanguage(host: 0, language: .spanish),
            .voiceLanguage(host: 1, language: .spanish),
        ])
    }

    func test_britishAndAmericanVoicesAreInterchangeable() {
        var brief = textBrief()
        brief.language = .englishUK

        XCTAssertEqual(brief.issues(blends: []), [])
    }

    func test_changingLanguageReplacesVoicesThatDoNotFit() {
        var brief = textBrief()

        brief.applyLanguage(.french, blends: [])

        XCTAssertEqual(brief.hosts.map(\.voice), ["ff_siwis", "ff_siwis"])
        XCTAssertEqual(brief.issues(blends: []), [])
    }

    func test_blendVoicesUseTheirLanguage() {
        var brief = textBrief()
        let blends = [PodcastVoiceBlend(id: "blend:warm", name: "Warm", lang: "es")]
        brief.hosts[0].voice = "blend:warm"

        XCTAssertEqual(brief.issues(blends: blends), [.voiceLanguage(host: 0, language: .englishUS)])
        brief.applyLanguage(.spanish, blends: blends)
        XCTAssertEqual(brief.hosts[0].voice, "blend:warm")
    }

    func test_titleIsTrimmedAndCapped() {
        var brief = textBrief()
        brief.title = "  Stars   tonight "
        XCTAssertEqual(brief.request(blends: [])?.title, "Stars tonight")

        brief.title = String(repeating: "t", count: PodcastLimits.titleCharacters + 1)
        XCTAssertEqual(brief.issues(blends: []), [.titleTooLong])
    }

    func test_voiceCatalogGroupsByLanguageWithBlendsFirst() {
        let blends = [PodcastVoiceBlend(id: "blend:warm", name: "Warm", lang: "en-us")]

        let groups = StudioVoiceCatalog.groups(blends: blends, language: .italian)
        let all = StudioVoiceCatalog.groups(blends: blends)

        XCTAssertEqual(groups.map(\.id), ["Italian"])
        XCTAssertEqual(all.first?.id, StudioVoiceCatalog.blendGroupTitle)
        XCTAssertEqual(StudioVoiceCatalog.displayName(for: "blend:warm", blends: blends), "Warm")
        XCTAssertEqual(StudioVoiceCatalog.displayName(for: "blend:gone", blends: blends), "Custom blend")
        XCTAssertEqual(StudioVoiceCatalog.displayName(for: "am_adam", blends: blends), "Adam")
        XCTAssertTrue(StudioVoiceCatalog.speaks("blend:gone", language: .hindi, blends: blends))
    }
}

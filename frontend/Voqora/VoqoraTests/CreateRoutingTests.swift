@testable import Voqora
import XCTest

@MainActor
final class CreateRoutingTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "CreateRoutingTests.runtime"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    func test_drawerHighlightsTheParentOfChildPages() {
        XCTAssertEqual(NavigationDrawerView.highlightedKey(for: TabKey.createScriptEditor), TabKey.createScripts)
        XCTAssertEqual(NavigationDrawerView.highlightedKey(for: TabKey.booksPlayer), TabKey.books)
        XCTAssertEqual(NavigationDrawerView.highlightedKey(for: TabKey.createPodcast), TabKey.createPodcast)
        XCTAssertEqual(NavigationDrawerView.highlightedKey(for: "studio"), TabKey.createScripts)
        XCTAssertNil(NavigationDrawerView.highlightedKey(for: nil))
    }

    func test_showNewAudiobookStagesTheSourceAndSelectsTheCreatePage() {
        let vm = DashboardViewModel(
            backend: BackendService(),
            system: SystemService(),
            audio: AudioService(),
            history: HistoryManager(),
            startsBackgroundWork: false,
            defaults: defaults
        )
        let request = AudiobookCreateRequest()
        vm.selectedTab = TabKey.stats

        vm.showNewAudiobook(with: .text("Hello there, selected text.", title: "Hello"), request: request)

        XCTAssertEqual(request.pending, .text("Hello there, selected text.", title: "Hello"))
        XCTAssertEqual(vm.selectedTab, TabKey.createAudiobook)
    }
}

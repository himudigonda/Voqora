import Foundation
@testable import Voqora
import XCTest

@MainActor
private final class FakeShelfClient: AudiobookshelfServing {
    var result: Result<[AudiobookshelfLibrary], Error> = .success([])
    private(set) var requests: [(server: URL, token: String)] = []

    func libraries(server: URL, token: String) async throws -> [AudiobookshelfLibrary] {
        requests.append((server, token))
        return try result.get()
    }

    func upload(_: AudiobookshelfUpload, progress _: @escaping @Sendable (Double) -> Void) async throws {}
}

@MainActor
final class AudiobookshelfSettingsStoreTests: XCTestCase {
    private var testDefaults: TestDefaults!
    private var secrets: MemorySecretStore!
    private var client: FakeShelfClient!

    private let books = AudiobookshelfLibrary(
        id: "lib1",
        name: "Books",
        mediaType: "book",
        folders: [AudiobookshelfFolder(id: "f1", fullPath: "/books"), AudiobookshelfFolder(id: "f2", fullPath: "/more")]
    )
    private let podcasts = AudiobookshelfLibrary(id: "pod", name: "Podcasts", mediaType: "podcast", folders: [AudiobookshelfFolder(id: "p1", fullPath: "/p")])

    override func setUp() {
        super.setUp()
        testDefaults = TestDefaults()
        secrets = MemorySecretStore()
        client = FakeShelfClient()
    }

    override func tearDown() {
        testDefaults.tearDown()
        super.tearDown()
    }

    private func makeStore() -> AudiobookshelfSettingsStore {
        AudiobookshelfSettingsStore(client: client, secrets: secrets.store, defaults: testDefaults.defaults)
    }

    func test_successfulTestSavesServerAndPicksTheFirstBookLibrary() async throws {
        client.result = .success([podcasts, books])
        let store = makeStore()
        store.serverText = "abs.example.com/"
        XCTAssertTrue(store.saveToken("  token-123  "))

        await store.testConnection()

        XCTAssertEqual(store.connection, .connected)
        XCTAssertEqual(store.serverText, "https://abs.example.com")
        XCTAssertEqual(client.requests.first?.token, "token-123")
        XCTAssertEqual(store.bookLibraries, [books])
        XCTAssertEqual(store.libraryID, "lib1")
        XCTAssertEqual(store.folderID, "f1")
        XCTAssertEqual(secrets.value(for: .audiobookshelfToken), "token-123")
        let server = try XCTUnwrap(URL(string: "https://abs.example.com"))
        XCTAssertEqual(store.destination, AudiobookshelfDestination(server: server, token: "token-123", libraryID: "lib1", folderID: "f1"))
        XCTAssertEqual(testDefaults.defaults.string(forKey: AudiobookshelfSettingsStore.serverKey), "https://abs.example.com")
    }

    func test_settingsSurviveARelaunch() async {
        client.result = .success([books])
        let first = makeStore()
        first.serverText = "https://abs.example.com"
        first.saveToken("token")
        await first.testConnection()
        first.selectFolder("f2")

        let relaunched = makeStore()

        XCTAssertTrue(relaunched.isConfigured)
        XCTAssertEqual(relaunched.libraryName, "Books")
        XCTAssertEqual(relaunched.destination?.folderID, "f2")
    }

    func test_failedTestShowsTheErrorAndDoesNotConfigure() async {
        client.result = .failure(AudiobookshelfError.unauthorized)
        let store = makeStore()
        store.serverText = "https://abs.example.com"
        store.saveToken("bad")

        await store.testConnection()

        XCTAssertEqual(store.connection, .failed(AudiobookshelfError.unauthorized.errorDescription ?? ""))
        XCTAssertFalse(store.isConfigured)
    }

    func test_serverWithoutBookLibrariesIsReported() async {
        client.result = .success([podcasts])
        let store = makeStore()
        store.serverText = "https://abs.example.com"
        store.saveToken("token")

        await store.testConnection()

        XCTAssertEqual(store.connection, .failed(AudiobookshelfError.noBookLibraries.errorDescription ?? ""))
        XCTAssertNil(store.destination)
    }

    func test_invalidAddressOrMissingTokenNeverCallsTheServer() async {
        let store = makeStore()
        store.serverText = "http://abs.example.com"
        store.saveToken("token")
        await store.testConnection()
        XCTAssertEqual(store.connection, .failed(AudiobookshelfServerAddress.insecureMessage))

        let tokenless = AudiobookshelfSettingsStore(client: client, secrets: MemorySecretStore().store, defaults: testDefaults.defaults)
        tokenless.serverText = "https://abs.example.com"
        await tokenless.testConnection()
        XCTAssertEqual(tokenless.connection, .failed(AudiobookshelfSettingsStore.missingTokenMessage))
        XCTAssertTrue(client.requests.isEmpty)
    }

    func test_blankTokensAreRejected() {
        let store = makeStore()

        XCTAssertFalse(store.saveToken("   "))
        XCTAssertEqual(store.tokenError, AudiobookshelfSettingsStore.missingTokenMessage)
        XCTAssertFalse(store.hasToken)
    }

    func test_changingServerClearsTheOldLibrary() async {
        client.result = .success([books])
        let store = makeStore()
        store.serverText = "https://one.example.com"
        store.saveToken("token")
        await store.testConnection()

        let other = AudiobookshelfLibrary(id: "lib9", name: "Other", mediaType: "book", folders: [AudiobookshelfFolder(id: "f9", fullPath: nil)])
        client.result = .success([other])
        store.serverText = "https://two.example.com"
        store.saveToken("token-two")
        await store.testConnection()

        XCTAssertEqual(store.destination?.libraryID, "lib9")
        XCTAssertEqual(store.destination?.server.absoluteString, "https://two.example.com")
        XCTAssertEqual(store.destination?.token, "token-two")
        XCTAssertEqual(client.requests.last?.token, "token-two")
    }

    func test_savedTokenIsNotSentToANewServerAddress() async {
        client.result = .success([books])
        let store = makeStore()
        store.serverText = "https://one.example.com"
        store.saveToken("token")
        await store.testConnection()

        store.serverText = "two.example.com"
        XCTAssertTrue(store.needsTokenForAddress)
        await store.testConnection()

        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(store.connection, .failed(AudiobookshelfSettingsStore.tokenForNewServerMessage))
        XCTAssertEqual(store.destination?.server.absoluteString, "https://one.example.com")

        store.serverText = "https://one.example.com/"
        XCTAssertFalse(store.needsTokenForAddress)
    }

    func test_savedTokenStaysWithItsServerAfterARelaunch() async {
        client.result = .success([books])
        let first = makeStore()
        first.serverText = "https://one.example.com"
        first.saveToken("token")
        await first.testConnection()

        let relaunched = makeStore()
        relaunched.serverText = "https://two.example.com"
        await relaunched.testConnection()

        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(relaunched.connection, .failed(AudiobookshelfSettingsStore.tokenForNewServerMessage))
    }

    func test_newTokenIsNotUsedForUploadsUntilItsServerIsVerified() async {
        client.result = .success([books])
        let store = makeStore()
        store.serverText = "https://one.example.com"
        store.saveToken("token")
        await store.testConnection()

        client.result = .failure(AudiobookshelfError.unreachable)
        store.serverText = "https://two.example.com"
        store.saveToken("token-two")
        await store.testConnection()

        XCTAssertEqual(client.requests.last?.server.absoluteString, "https://two.example.com")
        XCTAssertNil(store.destination)
        XCTAssertFalse(store.needsTokenForAddress)
    }

    func test_firstTokenCanBeTestedAgainstAnyAddress() async {
        client.result = .failure(AudiobookshelfError.unreachable)
        let store = makeStore()
        store.serverText = "https://one.example.com"
        store.saveToken("token")
        await store.testConnection()

        client.result = .success([books])
        store.serverText = "https://two.example.com"
        await store.testConnection()

        XCTAssertEqual(store.connection, .connected)
        XCTAssertEqual(client.requests.map(\.server.absoluteString), ["https://one.example.com", "https://two.example.com"])
    }

    func test_disconnectRemovesTokenAndSettings() async {
        client.result = .success([books])
        let store = makeStore()
        store.serverText = "https://abs.example.com"
        store.saveToken("token")
        await store.testConnection()

        store.disconnect()

        XCTAssertNil(secrets.value(for: .audiobookshelfToken))
        XCTAssertFalse(store.hasToken)
        XCTAssertNil(store.destination)
        XCTAssertEqual(store.serverText, "")
        XCTAssertNil(testDefaults.defaults.string(forKey: AudiobookshelfSettingsStore.libraryIDKey))
    }
}

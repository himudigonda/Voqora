import Foundation
@testable import Voqora
import XCTest

final class BackendConnectionTests: XCTestCase {
    override func tearDown() {
        BackendConnection.shared.invalidate()
        super.tearDown()
    }

    func testRequestUsesEphemeralListenerAndHeaderTokenOnly() throws {
        let launch = try BackendConnection.shared.prepareForLaunch()
        let request = try BackendConnection.shared.request(path: "audiobook/example/cover")

        XCTAssertGreaterThan(launch.listenerFD, 2)
        XCTAssertNotEqual(launch.baseURL.port, 10101)
        XCTAssertEqual(request.url?.host, "127.0.0.1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Voqora-IPC-Token"), launch.token)
        XCTAssertFalse(request.url?.absoluteString.contains(launch.token) ?? true)
    }

    func testRestartRotatesTheAuthenticatedConnection() throws {
        let first = try BackendConnection.shared.prepareForLaunch()
        let second = try BackendConnection.shared.prepareForLaunch()

        XCTAssertNotEqual(first.generation, second.generation)
        XCTAssertNotEqual(first.token, second.token)
        XCTAssertEqual(
            try BackendConnection.shared.request(path: "health")
                .value(forHTTPHeaderField: "X-Voqora-IPC-Token"),
            second.token
        )
    }

    func testStaleGenerationCannotInvalidateNewConnection() throws {
        let first = try BackendConnection.shared.prepareForLaunch()
        let second = try BackendConnection.shared.prepareForLaunch()

        BackendConnection.shared.invalidate(generation: first.generation)

        let request = try BackendConnection.shared.request(path: "health")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Voqora-IPC-Token"), second.token
        )
    }
}

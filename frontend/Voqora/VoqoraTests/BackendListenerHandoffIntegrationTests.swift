import Darwin
import Foundation
@testable import Voqora
import XCTest

/// Integration coverage for the ONE mechanism that actually gets Voqora's
/// app-owned loopback listener into the Python backend process.
///
/// Shipped 1.2.x tried to hand the listener over by clearing `FD_CLOEXEC` and
/// telling the child its raw descriptor number in `VOQORA_IPC_LISTENER_FD`.
/// That cannot work: `Foundation.Process` launches via `posix_spawn` and closes
/// every descriptor except the three it wires itself, regardless of CLOEXEC
/// state — so the backend never received the socket and the app could not talk
/// to it. The fix hands the descriptor over as `standardInput` (fd 0) and tells
/// the backend to read it from exactly there.
///
/// These tests spawn a REAL child process through the REAL `Process` API and
/// prove both halves of that statement, so a future "cleanup" that reverts to
/// the environment-variable approach fails here instead of in a user's hands.
final class BackendListenerHandoffIntegrationTests: XCTestCase {
    private static let python = "/usr/bin/python3"

    /// Adopts `VOQORA_IPC_LISTENER_FD` as a listening socket, serves exactly one
    /// HTTP request, and answers 200 only when the expected IPC token header is
    /// present. Exits non-zero when the descriptor is absent or is not a
    /// listening socket, so an unrelated inherited descriptor cannot false-pass.
    private static let listenerChildProgram = #"""
    import os
    import socket
    import sys

    try:
        fd = int(os.environ["VOQORA_IPC_LISTENER_FD"])
    except (KeyError, ValueError):
        sys.exit(2)

    expected = os.environ.get("VOQORA_EXPECTED_TOKEN", "")

    try:
        listener = socket.fromfd(fd, socket.AF_INET, socket.SOCK_STREAM)
        # Darwin has no getsockopt(SO_ACCEPTCONN), so prove this really is a
        # bound stream socket instead: getsockname() raises ENOTSOCK on a pipe
        # or a regular file, and the accept() below proves it is listening.
        if listener.getsockopt(socket.SOL_SOCKET, socket.SO_TYPE) != socket.SOCK_STREAM:
            sys.exit(4)
        host, port = listener.getsockname()
        if host != "127.0.0.1" or port <= 0:
            sys.exit(4)
    except (OSError, ValueError):
        sys.exit(3)

    listener.settimeout(25)
    try:
        connection, _ = listener.accept()
    except OSError:
        sys.exit(5)

    connection.settimeout(25)
    received = b""
    while b"\r\n\r\n" not in received:
        chunk = connection.recv(4096)
        if not chunk:
            break
        received += chunk

    # Header NAMES are case-insensitive; the base64 token value is not, so the
    # two halves have to be compared separately.
    authenticated = False
    for line in received.split(b"\r\n"):
        name, separator, value = line.partition(b":")
        if separator and name.strip().lower() == b"x-voqora-ipc-token":
            authenticated = value.strip() == expected.encode()
            break

    body = b"ok" if authenticated else b"denied"
    status = b"200 OK" if authenticated else b"401 Unauthorized"
    connection.sendall(
        b"HTTP/1.1 " + status
        + b"\r\nContent-Length: " + str(len(body)).encode()
        + b"\r\nConnection: close\r\n\r\n" + body
    )
    connection.close()
    sys.exit(0)
    """#

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: Self.python),
            "/usr/bin/python3 is required to exercise the real descriptor hand-off"
        )
    }

    override func tearDown() {
        BackendConnection.shared.invalidate()
        super.tearDown()
    }

    private func makeChild(
        listenerFD: Int32,
        advertisedFD: String,
        expectedToken: String,
        attachToStandardInput: Bool
    ) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.python)
        process.arguments = ["-c", Self.listenerChildProgram]

        var environment = ProcessInfo.processInfo.environment
        environment["VOQORA_IPC_LISTENER_FD"] = advertisedFD
        environment["VOQORA_EXPECTED_TOKEN"] = expectedToken
        process.environment = environment

        if attachToStandardInput {
            // The exact production line under test.
            process.standardInput = FileHandle(fileDescriptor: listenerFD, closeOnDealloc: false)
        }
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        return process
    }

    private func fetch(
        _ request: URLRequest,
        timeout: TimeInterval = 25
    ) throws -> (status: Int, body: String) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let completed = expectation(description: "loopback response")
        var outcome: Result<(Int, String), Error>?
        session.dataTask(with: request) { data, response, error in
            if let error {
                outcome = .failure(error)
            } else {
                outcome = .success((
                    (response as? HTTPURLResponse)?.statusCode ?? -1,
                    String(data: data ?? Data(), encoding: .utf8) ?? ""
                ))
            }
            completed.fulfill()
        }.resume()
        wait(for: [completed], timeout: timeout + 5)

        switch try XCTUnwrap(outcome) {
        case let .success(value): return value
        case let .failure(error): throw error
        }
    }

    // MARK: - Bug #3 regression

    /// The production hand-off. Fails if anybody swaps `standardInput` back for
    /// a bare environment variable.
    func test_listenerSocketReachesTheChildThroughStandardInput() throws {
        let launch = try BackendConnection.shared.prepareForLaunch()
        XCTAssertGreaterThan(launch.listenerFD, 2)

        let child = makeChild(
            listenerFD: launch.listenerFD,
            advertisedFD: "0",
            expectedToken: launch.token,
            attachToStandardInput: true
        )
        try child.run()
        defer {
            if child.isRunning {
                child.terminate()
            }
            child.waitUntilExit()
        }

        let response = try fetch(BackendConnection.shared.request(path: "health"))

        XCTAssertEqual(response.status, 200, "The child must have adopted the app-bound listener on fd 0")
        XCTAssertEqual(response.body, "ok", "The child must also have seen the per-launch IPC token header")

        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
    }

    /// The shipped-and-broken approach, pinned as broken so nobody "restores"
    /// it. `prepareForLaunch()` already clears `FD_CLOEXEC` on this descriptor;
    /// that is deliberately not enough.
    func test_advertisingTheRawDescriptorNumberDoesNotReachTheChild() throws {
        let launch = try BackendConnection.shared.prepareForLaunch()

        // Prove the premise: CLOEXEC really is clear on the parent's copy, so
        // the failure below is about posix_spawn, not about a stale flag.
        let flags = fcntl(launch.listenerFD, F_GETFD)
        XCTAssertGreaterThanOrEqual(flags, 0)
        XCTAssertEqual(flags & FD_CLOEXEC, 0, "BackendConnection is expected to clear FD_CLOEXEC")

        let child = makeChild(
            listenerFD: launch.listenerFD,
            advertisedFD: String(launch.listenerFD),
            expectedToken: launch.token,
            attachToStandardInput: false
        )
        try child.run()
        child.waitUntilExit()

        XCTAssertNotEqual(
            child.terminationStatus,
            0,
            """
            `Process` must NOT be trusted to carry an arbitrary descriptor across \
            posix_spawn. If this starts passing, the FD-number environment variable \
            approach looks viable again — it is not portable, and shipping it broke \
            backend launch in 1.2.x.
            """
        )
    }

    /// A child told to adopt fd 0 when fd 0 is not a listening socket must fail
    /// loudly rather than silently serve nothing — this is what makes the
    /// positive test above meaningful rather than vacuous.
    func test_childRejectsAStandardInputThatIsNotAListeningSocket() throws {
        let launch = try BackendConnection.shared.prepareForLaunch()
        let pipe = Pipe()

        let child = Process()
        child.executableURL = URL(fileURLWithPath: Self.python)
        child.arguments = ["-c", Self.listenerChildProgram]
        var environment = ProcessInfo.processInfo.environment
        environment["VOQORA_IPC_LISTENER_FD"] = "0"
        environment["VOQORA_EXPECTED_TOKEN"] = launch.token
        child.environment = environment
        child.standardInput = pipe
        child.standardOutput = Pipe()
        child.standardError = Pipe()

        try child.run()
        try? pipe.fileHandleForWriting.close()
        child.waitUntilExit()

        XCTAssertNotEqual(child.terminationStatus, 0)
    }

    // MARK: - Listener lifecycle edge cases

    /// A relaunch must not leave the previous generation's listener bound; the
    /// app is the only holder of that port and a leak would eventually exhaust
    /// descriptors across restarts.
    func test_repeatedPreparationDoesNotLeakDescriptorsOrUseTheDevPort() throws {
        var descriptors: [Int32] = []
        var ports: [Int] = []

        for _ in 0 ..< 12 {
            let launch = try BackendConnection.shared.prepareForLaunch()
            XCTAssertGreaterThan(launch.listenerFD, 2)
            descriptors.append(launch.listenerFD)
            ports.append(launch.baseURL.port ?? -1)
        }

        // A leaked listener would force each new socket() onto a higher
        // descriptor; a correctly-retired one is immediately reusable, so the
        // numbers must stay flat rather than climbing once per relaunch.
        let first = try XCTUnwrap(descriptors.first)
        let highest = try XCTUnwrap(descriptors.max())
        XCTAssertLessThanOrEqual(
            highest - first,
            2,
            "Descriptor numbers climbing once per relaunch means the prior listener was never closed: \(descriptors)"
        )

        XCTAssertFalse(ports.contains(-1))
        XCTAssertFalse(ports.contains(10101), "Release launches must never reuse the dev fallback port")
        XCTAssertTrue(ports.allSatisfy { $0 > 1024 }, "An ephemeral loopback port is expected, not a privileged one")
    }

    /// Nothing may be requestable once the connection is invalidated — a
    /// half-torn-down state that still hands out URLs would let a stale
    /// backend generation be addressed.
    func test_requestsAreRefusedAfterInvalidation() throws {
        _ = try BackendConnection.shared.prepareForLaunch()
        BackendConnection.shared.invalidate()

        XCTAssertThrowsError(try BackendConnection.shared.request(path: "health")) { error in
            XCTAssertEqual(error as? BackendConnection.ConnectionError, .unavailable)
        }
    }

    /// Path shapes the app actually passes, including an already-rooted one.
    func test_requestBuilderNormalizesPathsAndNeverPutsTheTokenInTheURL() throws {
        let launch = try BackendConnection.shared.prepareForLaunch()

        for path in ["health", "/health", "audiobook/abc/cover"] {
            let request = try BackendConnection.shared.request(path: path)
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.host, "127.0.0.1")
            XCTAssertEqual(url.port, launch.baseURL.port)
            XCTAssertFalse(url.absoluteString.contains("//health"))
            XCTAssertFalse(url.absoluteString.contains(launch.token))
            XCTAssertNil(url.query, "Secrets and parameters must never ride in a query string")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Voqora-IPC-Token"), launch.token)
        }
    }

    /// Tokens are per-launch secrets; a weak or repeated one would let any
    /// local process talk to the backend.
    func test_perLaunchTokensAreUniqueAndFullEntropy() throws {
        var tokens = Set<String>()
        for _ in 0 ..< 16 {
            let launch = try BackendConnection.shared.prepareForLaunch()
            XCTAssertEqual(
                Data(base64Encoded: launch.token)?.count,
                32,
                "The IPC token must remain 256 bits of base64-encoded entropy"
            )
            tokens.insert(launch.token)
        }
        XCTAssertEqual(tokens.count, 16)
    }
}

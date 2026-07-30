@testable import Voqora
import XCTest

/// Pure-logic state-machine tests for DashboardViewModel.
///
/// These tests pin the most user-visible behaviors that don't require a
/// running backend:
///   - togglePlayback error path when nothing has been spoken yet
///   - currentVoiceDisplay formatting
///   - isOnline reflecting backend state
///   - Status enum coverage
///
/// HARD-044 (the planned full BackendServiceProtocol / AudioServiceProtocol
/// dependency-injection refactor) was scoped down to focused public-surface
/// tests instead. Reasoning: the speak() / streamAudio integration path is
/// already exercised end-to-end via manual launch + the backend's own
/// streaming-contract tests; adding mock-everything protocols for
/// 1,200 lines of frontend would cost more in adapter glue than it
/// would catch in regressions. The behaviors below are the ones a real
/// user trips most often.
@MainActor
final class DashboardViewModelTests: XCTestCase {
    private var testDefaults: UserDefaults!
    private let testDefaultsSuite = "DashboardViewModelTests.runtime"

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: testDefaultsSuite)!
        testDefaults.removePersistentDomain(forName: testDefaultsSuite)
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: testDefaultsSuite)
        testDefaults = nil
        super.tearDown()
    }

    func test_voiceDefaultsMigration_resetsLegacyVoiceAndRepairsUnsupportedValueAfterMigration() {
        let suiteName = "DashboardViewModelTests.voiceDefaultsMigration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("zf_xiaoxiao", forKey: "selectedVoice")
        defaults.set("zf_xiaoxiao", forKey: "defaultBookVoice")
        // v6 could already be recorded by an early local build without
        // actually applying the Bella default before the voice model initialized.
        defaults.set(6, forKey: "voiceDefaultsMigrationVersion")

        XCTAssertTrue(DashboardViewModel.applyVoiceDefaultsMigrationIfNeeded(defaults: defaults))
        XCTAssertEqual(defaults.string(forKey: "selectedVoice"), "af_bella")
        XCTAssertEqual(defaults.string(forKey: "defaultBookVoice"), "af_bella")

        // A short-lived pre-release could persist the migration marker before
        // storing Bella. The marker must not leave this public-only build
        // displaying a voice it cannot actually offer.
        defaults.set("zf_xiaoxiao", forKey: "selectedVoice")
        defaults.set("zf_xiaoxiao", forKey: "defaultBookVoice")
        defaults.set(8, forKey: "voiceDefaultsMigrationVersion")
        XCTAssertTrue(DashboardViewModel.applyVoiceDefaultsMigrationIfNeeded(defaults: defaults))
        XCTAssertEqual(defaults.string(forKey: "selectedVoice"), "af_bella")
        XCTAssertEqual(defaults.string(forKey: "defaultBookVoice"), "af_bella")

        defaults.set("bf_emma", forKey: "selectedVoice")
        XCTAssertFalse(DashboardViewModel.applyVoiceDefaultsMigrationIfNeeded(defaults: defaults))
        XCTAssertEqual(defaults.string(forKey: "selectedVoice"), "bf_emma")
    }


    private func makeVM() -> DashboardViewModel {
        DashboardViewModel(
            backend: BackendService(),
            system: SystemService(),
            audio: AudioService(),
            history: HistoryManager(),
            startsBackgroundWork: false,
            defaults: testDefaults
        )
    }

    func test_fastFailedBackendDoesNotRetainDeadProcessOwnership() {
        let temporarySupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("voqora-backend-fast-exit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporarySupport) }

        let backend = BackendService(
            executableOverride: URL(fileURLWithPath: "/usr/bin/false"),
            applicationSupportOverride: temporarySupport
        )
        backend.start()

        let exited = expectation(description: "fast failing backend releases ownership")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
            XCTAssertFalse(backend.hasOwnedProcess)
            XCTAssertFalse(backend.isLaunching)
            XCTAssertEqual(backend.lastLaunchFailure, "The local speech engine stopped unexpectedly.")
            exited.fulfill()
        }
        wait(for: [exited], timeout: 2)
    }

    func test_backgroundWork_startsOnlyOnceAfterExplicitLaunchPreparation() {
        let vm = makeVM()
        XCTAssertFalse(vm.backgroundWorkStarted)

        vm.startBackgroundWork()
        XCTAssertTrue(vm.backgroundWorkStarted)

        // A second window appearance must not create another health loop or
        // prewarm subscription.
        vm.startBackgroundWork()
        XCTAssertTrue(vm.backgroundWorkStarted)
        vm.stopHeartbeat()
    }

    func test_backendResponseValidation_acceptsOnlySuccessfulWavStreams() {
        let ok = HTTPURLResponse(
            url: URL(string: "http://127.0.0.1:10101/speak")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "audio/wav"]
        )!
        let serverError = HTTPURLResponse(
            url: URL(string: "http://127.0.0.1:10101/speak")!,
            statusCode: 500,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!

        XCTAssertTrue(BackendService.isExpectedAudioResponse(ok))
        XCTAssertFalse(BackendService.isExpectedAudioResponse(serverError))
        XCTAssertFalse(BackendService.isExpectedAudioResponse(nil))
    }

    func test_speechFailureCopyDistinguishesValidationFromConnectivity() {
        XCTAssertEqual(
            DashboardViewModel.speechFailureMessage(for: BackendService.StreamError.rejectedResponse(statusCode: 422)),
            "That selection is empty or too long. Try a shorter passage."
        )
        XCTAssertEqual(
            DashboardViewModel.speechFailureMessage(for: BackendService.StreamError.rejectedResponse(statusCode: 503)),
            "Voqora's local speech engine is still warming up. Try again in a moment."
        )
        XCTAssertEqual(
            DashboardViewModel.speechFailureMessage(for: BackendService.StreamError.unexpectedResponse),
            "Voqora could not reach the local speech engine. Try again."
        )
    }

    func test_backendMarker_usesArchiveIdentity_andPreservesOlderBuildFallback() {
        XCTAssertEqual(
            LaunchManager.backendMarker(bundleVersion: "1.0.2", archiveBuildID: "abc123\n"),
            "archive:abc123"
        )
        XCTAssertEqual(
            LaunchManager.backendMarker(bundleVersion: "1.0.2", archiveBuildID: "  "),
            "version:1.0.2"
        )
        XCTAssertEqual(
            LaunchManager.backendMarker(bundleVersion: "1.0.2", archiveBuildID: nil),
            "version:1.0.2"
        )
    }

    func test_backendStagingCleanup_removesOnlyOldMatchingDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoqoraLaunchManagerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let oldStaging = root.appendingPathComponent(".backend-staging-old", isDirectory: true)
        let newStaging = root.appendingPathComponent(".backend-staging-new", isDirectory: true)
        let unrelated = root.appendingPathComponent("audiobooks", isDirectory: true)
        try FileManager.default.createDirectory(at: oldStaging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newStaging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-3_600)],
            ofItemAtPath: oldStaging.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-30)],
            ofItemAtPath: newStaging.path
        )

        LaunchManager.removeStaleBackendStagingDirectories(
            in: root,
            fileManager: .default,
            now: now,
            minimumAge: 60
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldStaging.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newStaging.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func test_installValidatedBackend_replacesOnlyAfterStagedServerExists() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoqoraBackendInstallTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let installed = root.appendingPathComponent("VoqoraServer", isDirectory: true)
        let installedExecutable = installed.appendingPathComponent("VoqoraServer")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: installedExecutable)

        let missingStaged = root.appendingPathComponent("missing", isDirectory: true)
        XCTAssertThrowsError(
            try LaunchManager.installValidatedBackend(
                from: missingStaged,
                to: installed,
                fileManager: .default
            )
        )
        XCTAssertEqual(try String(contentsOf: installedExecutable, encoding: .utf8), "old")

        let staged = root.appendingPathComponent("staged", isDirectory: true)
        let stagedExecutable = staged.appendingPathComponent("VoqoraServer")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: stagedExecutable)

        try LaunchManager.installValidatedBackend(from: staged, to: installed, fileManager: .default)
        XCTAssertEqual(
            try String(contentsOf: installed.appendingPathComponent("VoqoraServer"), encoding: .utf8),
            "new"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    // MARK: - togglePlayback error path

    func test_togglePlayback_with_zero_duration_sets_error() async {
        let vm = makeVM()
        // Fresh AudioService starts with duration == 0 (no buffer scheduled).
        XCTAssertEqual(vm.audio.duration, 0)

        vm.togglePlayback()

        if case let .error(msg) = vm.status {
            XCTAssertTrue(msg.contains("Nothing to play"), "expected error pill, got: \(msg)")
        } else {
            XCTFail("expected .error status, got \(vm.status)")
        }
    }

    func test_stopPlayback_returnsTheTTSStateToReady() {
        let vm = makeVM()
        vm.status = .thinking

        vm.stopPlayback()

        XCTAssertEqual(vm.status, .ready)
    }

    func test_togglePlayback_error_current_reset_returns_to_ready() async {
        let vm = makeVM()
        vm.togglePlayback()  // sets .error

        vm.resetPlaybackError(for: vm.errorResetGeneration)

        XCTAssertEqual(vm.status, .ready)
    }

    func test_togglePlayback_twice_in_a_row_does_not_double_schedule_clear() async {
        let vm = makeVM()
        vm.togglePlayback()  // .error #1
        let firstGeneration = vm.errorResetGeneration
        // The HARD-021 fix cancels the prior errorResetTask; re-triggering
        // shouldn't leak a second timer.
        vm.togglePlayback()  // .error #2
        let secondGeneration = vm.errorResetGeneration

        if case .error = vm.status {} else {
            XCTFail("expected .error after two toggles; got \(vm.status)")
        }

        // A stale reset may wake up, but cannot clear a newer error.
        vm.resetPlaybackError(for: firstGeneration)
        if case .error = vm.status {} else {
            XCTFail("the cancelled reset cleared the second error too early")
        }

        // The current reset must still return to .ready.
        vm.resetPlaybackError(for: secondGeneration)
        XCTAssertEqual(vm.status, .ready)
    }

    // MARK: - currentVoiceDisplay

    func test_currentVoiceDisplay_humanizes_voice_id() async {
        let vm = makeVM()
        vm.selectedVoice = "af_bella"
        XCTAssertEqual(vm.currentVoiceDisplay, "Af Bella")

        vm.selectedVoice = "bm_george"
        XCTAssertEqual(vm.currentVoiceDisplay, "Bm George")
    }

    func test_selectedVoice_startsBellaThenPersistsAnIntentionalChoice() {
        let initial = makeVM()
        XCTAssertEqual(initial.selectedVoice, "af_bella")

        initial.selectedVoice = "bf_emma"
        let restored = makeVM()

        XCTAssertEqual(restored.selectedVoice, "bf_emma")
    }

    // MARK: - isOnline

    func test_isOnline_reflects_isBackendOnline() async {
        let vm = makeVM()
        XCTAssertFalse(vm.isOnline)
        vm.isBackendOnline = true
        XCTAssertTrue(vm.isOnline)
        vm.isBackendOnline = false
        XCTAssertFalse(vm.isOnline)
    }

    // MARK: - status equality (covers the Equatable conformance for SwiftUI)

    func test_status_equality_for_all_cases() {
        XCTAssertEqual(AppStatus.ready, AppStatus.ready)
        XCTAssertEqual(AppStatus.error("hi"), AppStatus.error("hi"))
        XCTAssertNotEqual(AppStatus.error("a"), AppStatus.error("b"))
        XCTAssertNotEqual(AppStatus.ready, AppStatus.speaking)
    }
}

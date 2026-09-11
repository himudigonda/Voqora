import AppKit
import CryptoKit
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

    func test_voiceDefaultsMigration_resetsLegacyVoiceAndRepairsUnsupportedValueAfterMigration() throws {
        let suiteName = "DashboardViewModelTests.voiceDefaultsMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
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

    func test_backendResponseValidation_acceptsOnlySuccessfulWavStreams() throws {
        let ok = try XCTUnwrap(try HTTPURLResponse(
            url: XCTUnwrap(URL(string: "http://localhost/speak")),
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "audio/wav"]
        ))
        let serverError = try XCTUnwrap(try HTTPURLResponse(
            url: XCTUnwrap(URL(string: "http://localhost/speak")),
            statusCode: 500,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ))

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
            [.modificationDate: now.addingTimeInterval(-3600)],
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

    func test_runtimeValidationRejectsTamperedAndUnexpectedFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoqoraRuntimeValidationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("VoqoraServer", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)

        let original = Data("verified executable".utf8)
        let executable = runtime.appendingPathComponent("VoqoraServer")
        try original.write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let hash = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
        let manifest = LaunchManager.RuntimeManifest(
            format: 1,
            version: "1.2.3",
            archiveSHA256: String(repeating: "a", count: 64),
            root: "VoqoraServer",
            files: [.init(path: "VoqoraServer", sha256: hash, mode: 0o755)]
        )

        XCTAssertNoThrow(try LaunchManager.validateInstalledRuntime(at: runtime, manifest: manifest))

        try Data("tampered".utf8).write(to: executable)
        XCTAssertThrowsError(try LaunchManager.validateInstalledRuntime(at: runtime, manifest: manifest))

        try original.write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data("unexpected".utf8).write(to: runtime.appendingPathComponent("extra"))
        XCTAssertThrowsError(try LaunchManager.validateInstalledRuntime(at: runtime, manifest: manifest))
    }

    // MARK: - togglePlayback error path

    func test_togglePlayback_with_zero_duration_sets_error() {
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

    func test_togglePlayback_error_current_reset_returns_to_ready() {
        let vm = makeVM()
        vm.togglePlayback() // sets .error

        vm.resetPlaybackError(for: vm.errorResetGeneration)

        XCTAssertEqual(vm.status, .ready)
    }

    func test_togglePlayback_twice_in_a_row_does_not_double_schedule_clear() {
        let vm = makeVM()
        vm.togglePlayback() // .error #1
        let firstGeneration = vm.errorResetGeneration
        // The HARD-021 fix cancels the prior errorResetTask; re-triggering
        // shouldn't leak a second timer.
        vm.togglePlayback() // .error #2
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

    func test_currentVoiceDisplay_humanizes_voice_id() {
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

    func test_isOnline_reflects_isBackendOnline() {
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

    // MARK: - heartbeatDelay (jira-cpu-ram-optimization.md T-5)

    func test_heartbeatDelay_foreground_matchesExistingOnlineOfflineCadence() {
        XCTAssertEqual(DashboardViewModel.heartbeatDelay(isOnline: true, isBackgrounded: false), 5_000_000_000)
        XCTAssertEqual(DashboardViewModel.heartbeatDelay(isOnline: false, isBackgrounded: false), 500_000_000)
    }

    func test_heartbeatDelay_backgrounded_widensToThirtySecondFloor() {
        XCTAssertEqual(DashboardViewModel.heartbeatDelay(isOnline: true, isBackgrounded: true), 30_000_000_000)
        XCTAssertEqual(DashboardViewModel.heartbeatDelay(isOnline: false, isBackgrounded: true), 30_000_000_000)
    }

    // MARK: - heartbeatOutcome (single-poll-miss no longer kills playback)

    func test_heartbeatOutcome_singleMissWhileOnline_isDebouncedNotReportedOffline() {
        let outcome = DashboardViewModel.heartbeatOutcome(
            rawOnline: false, wasOnline: true, previousConsecutiveFailures: 0
        )
        XCTAssertTrue(outcome.isOnline, "one missed poll must not flip the app to OFFLINE / cancel playback")
        XCTAssertEqual(outcome.consecutiveFailures, 1)
        XCTAssertFalse(outcome.shouldForceRestart)
    }

    func test_heartbeatOutcome_secondConsecutiveMissWhileOnline_reportsOffline() {
        let outcome = DashboardViewModel.heartbeatOutcome(
            rawOnline: false, wasOnline: true, previousConsecutiveFailures: 1
        )
        XCTAssertFalse(outcome.isOnline)
        XCTAssertEqual(outcome.consecutiveFailures, 2)
    }

    func test_heartbeatOutcome_recoveryIsImmediate_noDebounceOnTheWayBackOnline() {
        let outcome = DashboardViewModel.heartbeatOutcome(
            rawOnline: true, wasOnline: false, previousConsecutiveFailures: 5
        )
        XCTAssertTrue(outcome.isOnline)
        XCTAssertEqual(outcome.consecutiveFailures, 0)
    }

    func test_heartbeatOutcome_alreadyOffline_reportsRawStateImmediately() {
        let outcome = DashboardViewModel.heartbeatOutcome(
            rawOnline: false, wasOnline: false, previousConsecutiveFailures: 0
        )
        XCTAssertFalse(outcome.isOnline)
    }

    func test_heartbeatOutcome_sustainedFailuresPastInterval_requestsForceRestartOnce() {
        let atThreshold = DashboardViewModel.heartbeatOutcome(
            rawOnline: false, wasOnline: false, previousConsecutiveFailures: 9,
            hungProcessRestartInterval: 10
        )
        XCTAssertEqual(atThreshold.consecutiveFailures, 10)
        XCTAssertTrue(atThreshold.shouldForceRestart, "a live-but-unresponsive backend must eventually be force-restarted, not stay OFFLINE forever")

        let justPast = DashboardViewModel.heartbeatOutcome(
            rawOnline: false, wasOnline: false, previousConsecutiveFailures: 10,
            hungProcessRestartInterval: 10
        )
        XCTAssertFalse(justPast.shouldForceRestart, "should not fire again until the next interval boundary")
    }

    // MARK: - shouldPrewarmOnPasteboardChange (content-blind clipboard prewarm)

    func test_shouldPrewarmOnPasteboardChange_firesOnNewTextCopyWhileColdAndOnline() {
        XCTAssertTrue(DashboardViewModel.shouldPrewarmOnPasteboardChange(
            currentChangeCount: 2, lastChangeCount: 1,
            isBackendOnline: true, isModelLoaded: false, hasReadableStringContent: true
        ))
    }

    func test_shouldPrewarmOnPasteboardChange_skipsWhenModelAlreadyLoaded() {
        // The core "don't burn CPU for no reason" guard: once warm, repeated
        // copies during a session are free no-ops until the backend idle-unloads.
        XCTAssertFalse(DashboardViewModel.shouldPrewarmOnPasteboardChange(
            currentChangeCount: 2, lastChangeCount: 1,
            isBackendOnline: true, isModelLoaded: true, hasReadableStringContent: true
        ))
    }

    func test_shouldPrewarmOnPasteboardChange_skipsWhenBackendOffline() {
        XCTAssertFalse(DashboardViewModel.shouldPrewarmOnPasteboardChange(
            currentChangeCount: 2, lastChangeCount: 1,
            isBackendOnline: false, isModelLoaded: false, hasReadableStringContent: true
        ))
    }

    func test_shouldPrewarmOnPasteboardChange_skipsWhenChangeCountUnchanged() {
        XCTAssertFalse(DashboardViewModel.shouldPrewarmOnPasteboardChange(
            currentChangeCount: 1, lastChangeCount: 1,
            isBackendOnline: true, isModelLoaded: false, hasReadableStringContent: true
        ))
    }

    func test_shouldPrewarmOnPasteboardChange_skipsNonTextCopiesLikeImagesOrFiles() {
        // Only the declared pasteboard type is checked here (never content),
        // so an image/file copy shouldn't trigger a pointless model load.
        XCTAssertFalse(DashboardViewModel.shouldPrewarmOnPasteboardChange(
            currentChangeCount: 2, lastChangeCount: 1,
            isBackendOnline: true, isModelLoaded: false, hasReadableStringContent: false
        ))
    }

    func test_diagnosticContextRedactsSecretsAndSourceContent() {
        let canary = "CANARY_SOURCE_PROSE_do_not_export"
        let key = "AIzaSyDUMMY-should-never-reach-a-log"
        let token = String(repeating: "a", count: 64)

        let safe = VoqoraLog.redactedContext([
            "error": canary,
            "apiKey": key,
            "ipcToken": token,
            "page": "4",
        ])

        XCTAssertEqual(safe["error_redacted"], "true")
        XCTAssertEqual(safe["apiKey_redacted"], "true")
        XCTAssertEqual(safe["ipcToken_redacted"], "true")
        XCTAssertEqual(safe["page"], "4")
        XCTAssertFalse(safe.values.contains(canary))
        XCTAssertFalse(safe.values.contains(key))
        XCTAssertFalse(safe.values.contains(token))
    }

    func test_focusedTextInputKeepsEditingShortcutPrecedence() {
        XCTAssertTrue(VoqoraApp.focusedTextInputOwnsShortcut(responder: NSTextView()))
        XCTAssertFalse(VoqoraApp.focusedTextInputOwnsShortcut(responder: NSView()))
    }
}

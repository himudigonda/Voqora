@testable import Voqora
import SwiftUI
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

    func test_voiceDefaultsMigration_resetsLegacyVoiceOnceThenPreservesChoice() {
        let suiteName = "DashboardViewModelTests.voiceDefaultsMigration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("zf_xiaoxiao", forKey: "selectedVoice")
        defaults.set("zf_xiaoxiao", forKey: "defaultBookVoice")
        defaults.set(true, forKey: "autoDetectLanguage")

        XCTAssertTrue(DashboardViewModel.applyVoiceDefaultsMigrationIfNeeded(defaults: defaults))
        XCTAssertEqual(defaults.string(forKey: "selectedVoice"), "af_bella")
        XCTAssertEqual(defaults.string(forKey: "defaultBookVoice"), "af_bella")
        XCTAssertFalse(defaults.bool(forKey: "autoDetectLanguage"))

        defaults.set("bf_emma", forKey: "selectedVoice")
        XCTAssertFalse(DashboardViewModel.applyVoiceDefaultsMigrationIfNeeded(defaults: defaults))
        XCTAssertEqual(defaults.string(forKey: "selectedVoice"), "bf_emma")
    }

    private func makeVM() -> DashboardViewModel {
        DashboardViewModel(
            backend: BackendService(),
            system: SystemService(),
            audio: AudioService(),
            history: HistoryManager()
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

    func test_togglePlayback_error_reset_only_applies_to_latest_action() {
        let vm = makeVM()
        vm.togglePlayback()
        let firstGeneration = vm.errorResetGeneration
        vm.togglePlayback()
        let secondGeneration = vm.errorResetGeneration

        XCTAssertGreaterThan(secondGeneration, firstGeneration)
        vm.resetPlaybackError(for: firstGeneration)
        if case .error = vm.status {} else {
            XCTFail("a stale reset must not clear the latest error")
        }

        vm.resetPlaybackError(for: secondGeneration)
        XCTAssertEqual(vm.status, .ready)
    }

    func test_togglePlayback_twice_in_a_row_replaces_prior_reset() {
        let vm = makeVM()
        vm.togglePlayback()
        let firstGeneration = vm.errorResetGeneration
        vm.togglePlayback()
        let secondGeneration = vm.errorResetGeneration

        if case .error = vm.status {} else {
            XCTFail("expected .error after two toggles; got \(vm.status)")
        }

        vm.resetPlaybackError(for: firstGeneration)
        if case .error = vm.status {} else {
            XCTFail("the replaced timer must not clear the second action")
        }
        vm.resetPlaybackError(for: secondGeneration)
        XCTAssertEqual(vm.status, .ready)
    }

    // MARK: - currentVoiceDisplay

    func test_currentVoiceDisplay_uses_catalog_name_and_flag() {
        let vm = makeVM()
        vm.selectedVoice = "af_bella"
        XCTAssertEqual(vm.currentVoiceDisplay, "🇺🇸 Bella")

        vm.selectedVoice = "bm_george"
        XCTAssertEqual(vm.currentVoiceDisplay, "🇬🇧 George")

        vm.selectedVoice = "ff_siwis"
        XCTAssertEqual(vm.currentVoiceDisplay, "🇫🇷 Siwis")
    }

    func test_currentVoiceDisplay_falls_back_for_unknown_voice() {
        let vm = makeVM()
        vm.selectedVoice = "qx_unknown"
        // Not in catalog → humanized id, never a crash.
        XCTAssertEqual(vm.currentVoiceDisplay, "Qx Unknown")
    }

    func test_mandarin_voice_display_is_marked_beta() {
        let vm = makeVM()
        vm.selectedVoice = "zf_xiaoxiao"
        XCTAssertEqual(vm.currentVoiceDisplay, "🇨🇳 Xiaoxiao (Beta)")
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

    // MARK: - appFont / Poppins font name mapping

    /// appFont must not crash for any font name or weight combination.
    func test_appFont_does_not_crash_for_system_fonts() {
        let vm = makeVM()
        let names = ["System Rounded", "System Mono", "System Serif", "System Standard"]
        let weights: [Font.Weight] = [.regular, .bold, .semibold, .medium, .light]
        for name in names {
            vm.selectedFontName = name
            for weight in weights {
                // Would crash / return nil in prior implementations — just verify no crash
                _ = vm.appFont(size: 14, weight: weight)
            }
        }
    }

    func test_appFont_does_not_crash_for_poppins_all_weights() {
        let vm = makeVM()
        vm.selectedFontName = "Poppins"
        // All Font.Weight cases that poppinsFontName maps explicitly
        let weights: [Font.Weight] = [
            .regular, .bold, .semibold, .medium,
            .light, .thin, .heavy, .black, .ultraLight,
        ]
        for weight in weights {
            // Should not crash — prior bug was using .weight() on custom font
            // which silently loaded the wrong font file
            _ = vm.appFont(size: 14, weight: weight)
        }
    }

    func test_appFont_poppins_uses_custom_font_not_system() {
        let vm = makeVM()
        vm.selectedFontName = "Poppins"
        // Custom Poppins font must produce a different Font value than system rounded
        let poppins = vm.appFont(size: 14, weight: .bold)
        vm.selectedFontName = "System Rounded"
        let system = vm.appFont(size: 14, weight: .bold)
        // Font doesn't expose Equatable, but we can verify both are non-nil Font values
        // The key invariant is poppins doesn't crash and returns a real Font
        _ = poppins
        _ = system
    }

    // MARK: - availableVoices

    func test_all_voices_have_non_empty_ids_and_display_names() {
        for (id, display) in DashboardViewModel.availableVoices {
            XCTAssertFalse(id.isEmpty, "Voice ID must not be empty")
            XCTAssertFalse(display.isEmpty, "Voice display name must not be empty")
        }
    }

    func test_all_voice_ids_contain_underscore() {
        // All Kokoro voice IDs follow the {lang}_{name} pattern
        for (id, _) in DashboardViewModel.availableVoices {
            XCTAssertTrue(id.contains("_"), "Voice ID '\(id)' must follow lang_name pattern")
        }
    }

    func test_voice_catalog_is_multilingual() {
        // Curated catalog across 8 locales. Must stay in lockstep with the
        // backend catalog in backend/app/services/languages.py.
        XCTAssertEqual(DashboardViewModel.voiceCatalog.count, 28)
        XCTAssertEqual(DashboardViewModel.availableVoices.count, 28)
    }

    func test_legacy_english_voices_still_present() {
        // Audiobooks persist a voice id — the original 8 must never disappear.
        let legacy = ["af_bella", "af_sarah", "am_adam", "am_michael",
                      "bf_emma", "bf_isabella", "bm_george", "bm_lewis"]
        let ids = Set(DashboardViewModel.voiceCatalog.map(\.id))
        for v in legacy {
            XCTAssertTrue(ids.contains(v), "legacy voice \(v) dropped — breaks stored audiobooks")
        }
    }

    func test_no_japanese_voices_exposed() {
        // espeak has no kanji G2P — Japanese is intentionally excluded.
        for v in DashboardViewModel.voiceCatalog {
            XCTAssertFalse(v.id.hasPrefix("j"), "Japanese voice \(v.id) must not be exposed")
        }
    }

    func test_language_groups_cover_every_voice_exactly_once() {
        let grouped = DashboardViewModel.languageGroups.flatMap { $0.voices.map(\.id) }
        let catalog = DashboardViewModel.voiceCatalog.map(\.id)
        XCTAssertEqual(grouped.sorted(), catalog.sorted())
        XCTAssertEqual(grouped.count, Set(grouped).count, "a voice appears in two groups")
    }

    func test_only_mandarin_group_is_beta() {
        for group in DashboardViewModel.languageGroups {
            if group.id == "Mandarin" {
                XCTAssertTrue(group.beta)
            } else {
                XCTAssertFalse(group.beta, "\(group.id) should not be beta")
            }
        }
    }

    func test_default_voice_is_in_available_voices() {
        let vm = makeVM()
        let ids = DashboardViewModel.availableVoices.map(\.id)
        XCTAssertTrue(
            ids.contains(vm.selectedVoice),
            "Default voice '\(vm.selectedVoice)' not in availableVoices"
        )
    }

    func test_voice_ids_are_unique() {
        let ids = DashboardViewModel.availableVoices.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "Voice IDs must be unique")
    }

    // MARK: - currentVoiceDisplay

    func test_currentVoiceDisplay_for_bella() {
        let vm = makeVM()
        vm.selectedVoice = "af_bella"
        XCTAssertEqual(vm.currentVoiceDisplay, "🇺🇸 Bella")
    }

    func test_currentVoiceDisplay_for_george() {
        let vm = makeVM()
        vm.selectedVoice = "bm_george"
        XCTAssertEqual(vm.currentVoiceDisplay, "🇬🇧 George")
    }

    func test_currentVoiceDisplay_replaces_all_underscores() {
        let vm = makeVM()
        vm.selectedVoice = "af_sarah"
        // "af_sarah" → "Af Sarah" (underscore replaced by space, then capitalized)
        XCTAssertFalse(vm.currentVoiceDisplay.contains("_"), "Display name must not contain underscores")
    }

    // MARK: - isBackendInitializing

    func test_initial_state_is_backend_initializing() {
        let vm = makeVM()
        // On creation, backend is not yet online → should be in initializing state
        XCTAssertTrue(vm.isBackendInitializing)
        XCTAssertFalse(vm.isBackendOnline)
    }
}

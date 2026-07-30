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
    func test_voiceDefaultsMigration_resetsLegacyVoiceOnceThenPreservesChoice() {
        let suiteName = "DashboardViewModelTests.voiceDefaultsMigration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("zf_xiaoxiao", forKey: "selectedVoice")
        defaults.set("zf_xiaoxiao", forKey: "defaultBookVoice")
        defaults.set(1, forKey: "voiceDefaultsMigrationVersion")

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
            startsBackgroundWork: false
        )
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

    func test_togglePlayback_error_clears_to_ready_after_three_seconds() async {
        let vm = makeVM()
        vm.togglePlayback()  // sets .error

        // Wait slightly longer than the 3s auto-clear.
        try? await Task.sleep(nanoseconds: 3_200_000_000)

        XCTAssertEqual(vm.status, .ready)
    }

    func test_togglePlayback_twice_in_a_row_does_not_double_schedule_clear() async {
        let vm = makeVM()
        vm.togglePlayback()  // .error #1
        // The HARD-021 fix cancels the prior errorResetTask; re-triggering
        // shouldn't leak a second timer.
        vm.togglePlayback()  // .error #2

        if case .error = vm.status {} else {
            XCTFail("expected .error after two toggles; got \(vm.status)")
        }

        // The 3s clear from the second call must still fire and bring us
        // back to .ready. (If the first task had clobbered, we'd be stuck.)
        try? await Task.sleep(nanoseconds: 3_300_000_000)
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

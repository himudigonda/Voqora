import AVFoundation
import ServiceManagement
@testable import Voqora
import XCTest

@MainActor
final class BackendStartupReliabilityTests: XCTestCase {
    private func hungOutcome() -> DashboardViewModel.HeartbeatOutcome {
        DashboardViewModel.heartbeatOutcome(rawOnline: false, wasOnline: false, previousConsecutiveFailures: 9)
    }

    func test_slowFirstStartIsNotKilledDuringTheGracePeriod() {
        XCTAssertTrue(hungOutcome().shouldForceRestart)
        XCTAssertFalse(DashboardViewModel.shouldRestartHungProcess(hungOutcome(), processUptime: 15))
        XCTAssertFalse(DashboardViewModel.shouldRestartHungProcess(hungOutcome(), processUptime: 179.9))
    }

    func test_processHungPastTheGracePeriodIsRestarted() {
        XCTAssertTrue(DashboardViewModel.shouldRestartHungProcess(hungOutcome(), processUptime: 180))
    }

    func test_noProcessMeansNothingToRestart() {
        XCTAssertFalse(DashboardViewModel.shouldRestartHungProcess(hungOutcome(), processUptime: nil))
    }

    func test_healthyProcessIsNeverRestarted() {
        let healthy = DashboardViewModel.heartbeatOutcome(rawOnline: true, wasOnline: true, previousConsecutiveFailures: 0)
        XCTAssertFalse(DashboardViewModel.shouldRestartHungProcess(healthy, processUptime: 10000))
    }

    func test_launchBackoffGrowsAndIsCapped() {
        XCTAssertEqual(BackendService.launchBackoff(afterFailures: 0), 2)
        XCTAssertEqual(BackendService.launchBackoff(afterFailures: 1), 2)
        XCTAssertEqual(BackendService.launchBackoff(afterFailures: 2), 4)
        XCTAssertEqual(BackendService.launchBackoff(afterFailures: 5), 32)
        XCTAssertEqual(BackendService.launchBackoff(afterFailures: 6), 60)
        XCTAssertEqual(BackendService.launchBackoff(afterFailures: 5000), 60)
    }

    func test_rotateLogKeepsThePreviousRunAndStartsEmpty() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("backend.log")
        let previous = root.appendingPathComponent("backend.prev.log")

        try "first run".write(to: log, atomically: true, encoding: .utf8)
        BackendService.rotateLog(at: log)
        XCTAssertEqual(try String(contentsOf: previous, encoding: .utf8), "first run")
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "")

        try "second run".write(to: log, atomically: true, encoding: .utf8)
        BackendService.rotateLog(at: log)
        XCTAssertEqual(try String(contentsOf: previous, encoding: .utf8), "second run")
    }

    func test_rotateLogCreatesTheFileOnFirstRun() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("backend.log")

        BackendService.rotateLog(at: log)

        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("backend.prev.log").path))
    }
}

final class CaptureReliabilityTests: XCTestCase {
    func test_objcExceptionBecomesASwiftError() {
        XCTAssertThrowsError(try ObjCException.catching {
            NSException(name: .invalidArgumentException, reason: "bad format", userInfo: nil).raise()
        }) { error in
            XCTAssertEqual(error as? ObjCExceptionError, ObjCExceptionError(reason: "bad format"))
        }
    }

    func test_normalBodyDoesNotThrow() {
        var ran = false
        XCTAssertNoThrow(try ObjCException.catching { ran = true })
        XCTAssertTrue(ran)
    }

    func test_restartLimiterStopsAFlappingDevice() {
        var limiter = CaptureRestartLimiter(limit: 3, window: 30)
        XCTAssertTrue(limiter.allow(at: 0))
        XCTAssertTrue(limiter.allow(at: 1))
        XCTAssertTrue(limiter.allow(at: 2))
        XCTAssertFalse(limiter.allow(at: 3))
        XCTAssertFalse(limiter.allow(at: 29.9))
    }

    func test_restartLimiterRecoversAfterTheWindow() {
        var limiter = CaptureRestartLimiter(limit: 2, window: 30)
        XCTAssertTrue(limiter.allow(at: 0))
        XCTAssertTrue(limiter.allow(at: 1))
        XCTAssertFalse(limiter.allow(at: 2))
        XCTAssertTrue(limiter.allow(at: 31))
    }

    func test_legacyBackoffRetriesThenWaitsLongerThenGivesUp() {
        var backoff = LegacyRestartBackoff()
        var now: TimeInterval = 0
        var delays: [TimeInterval?] = []
        for _ in 0 ..< 11 {
            let delay = backoff.delayAfterFailure(at: now)
            delays.append(delay)
            now += (delay ?? 0) + 0.1
        }
        XCTAssertEqual(delays, [0, 0, 0, 0.5, 1, 2, 4, 8, 8, 8, nil])
    }

    func test_legacyBackoffForgetsFailuresOnceTextArrives() {
        var backoff = LegacyRestartBackoff()
        for _ in 0 ..< 5 {
            _ = backoff.delayAfterFailure(at: 0)
        }
        backoff.noteProgress()
        XCTAssertEqual(backoff.delayAfterFailure(at: 0), 0)
    }

    func test_legacyBackoffDoesNotEndASessionForSpacedOutFailures() {
        var backoff = LegacyRestartBackoff()
        for attempt in 0 ..< 50 {
            XCTAssertEqual(backoff.delayAfterFailure(at: TimeInterval(attempt) * 15), 0)
        }
    }

    func test_parakeetConverterHandlesMultichannelInput() throws {
        let converter = try XCTUnwrap(ParakeetAudioConverter())
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4))
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        buffer.frameLength = 4800
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0 ..< 4 {
            for frame in 0 ..< 4800 {
                channels[channel][frame] = channel == 3 ? 0.5 : 0
            }
        }

        let samples = try XCTUnwrap(converter.convert(buffer))

        XCTAssertFalse(samples.isEmpty)
        XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0, "A signal on any input channel must reach the mono mix")
    }
}

final class FirstLaunchReliabilityTests: XCTestCase {
    func test_extractionNeedsRoomForTheUnpackedArchive() {
        XCTAssertTrue(LaunchManager.hasSpaceForExtraction(availableBytes: 2000, archiveBytes: 1000))
        XCTAssertFalse(LaunchManager.hasSpaceForExtraction(availableBytes: 1999, archiveBytes: 1000))
        XCTAssertFalse(LaunchManager.hasSpaceForExtraction(availableBytes: 0, archiveBytes: 1000))
    }

    func test_unknownFreeSpaceDoesNotBlockExtraction() {
        XCTAssertTrue(LaunchManager.hasSpaceForExtraction(availableBytes: nil, archiveBytes: 1000))
    }

    func test_manifestModesRepairARestrictiveUmask() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("VoqoraServer")
        try Data("bin".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)

        try LaunchManager.applyManifestModes(at: root, entries: [(path: "VoqoraServer", mode: 0o755)])

        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o755)
    }

    func test_applyingModesToAMissingFileFails() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try LaunchManager.applyManifestModes(at: root, entries: [(path: "nope", mode: 0o755)]))
    }

    func test_loginItemNeedingApprovalExplainsWhere() {
        XCTAssertNotNil(LaunchManager.loginItemIssue(for: .requiresApproval))
        XCTAssertNil(LaunchManager.loginItemIssue(for: .enabled))
        XCTAssertNil(LaunchManager.loginItemIssue(for: .notRegistered))
    }
}

final class MultichannelMixTests: XCTestCase {
    private func buffer(channels: UInt32, fill: (Int) -> Float) throws -> AVAudioPCMBuffer {
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels))
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        buffer.frameLength = 16
        let data = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0 ..< Int(channels) {
            for frame in 0 ..< 16 {
                data[channel][frame] = fill(channel)
            }
        }
        return buffer
    }

    func test_micOnALaterChannelIsKeptAtFullLevel() throws {
        let mono = try MultichannelMix.flattened(buffer(channels: 4) { $0 == 3 ? 0.5 : 0 })

        XCTAssertEqual(mono.format.channelCount, 1)
        XCTAssertEqual(mono.floatChannelData?[0][0] ?? 0, 0.5, accuracy: 0.0001)
    }

    func test_activeChannelsAreAveraged() throws {
        let mono = try MultichannelMix.flattened(buffer(channels: 4) { $0 < 2 ? 0.4 : 0 })

        XCTAssertEqual(mono.floatChannelData?[0][0] ?? 0, 0.4, accuracy: 0.0001)
    }

    func test_allSilentStaysSilentWithoutDividingByZero() throws {
        let mono = try MultichannelMix.flattened(buffer(channels: 4) { _ in 0 })

        XCTAssertEqual(mono.floatChannelData?[0][0] ?? 1, 0)
    }

    func test_stereoAndMonoPassThroughUntouched() throws {
        let stereo = try buffer(channels: 2) { _ in 0.1 }
        XCTAssertTrue(MultichannelMix.flattened(stereo) === stereo)
    }

    func test_emptyBufferPassesThrough() throws {
        let empty = try buffer(channels: 4) { _ in 0 }
        empty.frameLength = 0
        XCTAssertTrue(MultichannelMix.flattened(empty) === empty)
    }

    func test_monoDownmixerKeepsALaterChannel() throws {
        let mono = try XCTUnwrap(MonoDownmixer().convert(buffer(channels: 4) { $0 == 2 ? 0.5 : 0 }))

        XCTAssertGreaterThan(mono.floatChannelData?[0][0] ?? 0, 0.1)
    }
}

final class MicrophoneStopRaceTests: XCTestCase {
    private func makeSession() -> MicrophoneSession {
        MicrophoneSession(sink: MicrophoneTapSink(forward: { _ in }, consume: { _ in })) { _ in }
    }

    func test_stopBeforeAPendingStartLeavesTheMicOff() async throws {
        let session = makeSession()

        session.stop()
        try await session.startOffMain()

        XCTAssertFalse(session.isCapturing)
    }

    func test_stopBeforeASynchronousStartLeavesTheMicOff() throws {
        let session = makeSession()

        session.stop()
        try session.start()

        XCTAssertFalse(session.isCapturing)
    }

    func test_stopIsIdempotentAfterAPendingStart() async throws {
        let session = makeSession()

        session.stop()
        try await session.startOffMain()
        session.stop()

        XCTAssertFalse(session.isCapturing)
    }
}

final class SingleInstanceDecisionTests: XCTestCase {
    @MainActor
    func test_aCopyThatAnswersIsActivated() {
        XCTAssertEqual(AppPresence.standDownAction(answered: true, finishedLaunching: true), .activateExisting)
    }

    @MainActor
    func test_aCopyStillLaunchingIsNotTreatedAsFrozen() {
        XCTAssertEqual(AppPresence.standDownAction(answered: false, finishedLaunching: false), .activateExisting)
    }

    @MainActor
    func test_aLaunchedCopyThatStaysSilentOffersForceQuit() {
        XCTAssertEqual(AppPresence.standDownAction(answered: false, finishedLaunching: true), .offerForceQuit)
    }
}

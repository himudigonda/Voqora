import CryptoKit
@testable import Voqora
import XCTest

final class LocalSpeechModelTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("local-speech-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func test_barkManifestsCarryTheFluidAudioV3Layout() {
        for files in [BarkModelManifest.bark, BarkModelManifest.barkClean] {
            let paths = Set(files.map(\.path))
            for required in ["Preprocessor.mlmodelc/model.mil", "Encoder.mlmodelc/weights/weight.bin", "Decoder.mlmodelc/model.mil", "JointDecisionv3.mlmodelc/model.mil", "parakeet_vocab.json", "NOTICE"] {
                XCTAssertTrue(paths.contains(required), required)
            }
            XCTAssertFalse(paths.contains { $0.hasPrefix("Encoder_lut3") })
            XCTAssertTrue(files.allSatisfy { $0.sha256.count == 64 && $0.sha256.allSatisfy(\.isHexDigit) && $0.size > 0 })
        }
        XCTAssertEqual(BarkModelManifest.revision.count, 40)
        XCTAssertEqual(
            BarkModelManifest.downloadURL(folder: "bark-3.0", path: "NOTICE").absoluteString,
            "https://huggingface.co/FluidInference/bark-3.0-coreml/resolve/\(BarkModelManifest.revision)/bark-3.0/NOTICE"
        )
    }

    func test_eachEngineMapsToItsModelAndFolder() {
        XCTAssertNil(DictationEngineChoice.apple.localModel)
        XCTAssertEqual(DictationEngineChoice.parakeet.localModel, .parakeet)
        XCTAssertEqual(DictationEngineChoice.bark.localModel, .bark)
        XCTAssertEqual(DictationEngineChoice.barkClean.localModel, .barkClean)
        XCTAssertEqual(LocalSpeechModel.bark.defaultDirectory.lastPathComponent, "bark-3.0")
        XCTAssertEqual(LocalSpeechModel.barkClean.defaultDirectory.lastPathComponent, "bark-3.0-clean")
        XCTAssertEqual(LocalSpeechModel.bark.defaultDirectory.deletingLastPathComponent().lastPathComponent, "bark-3.0-coreml")
        XCTAssertNil(LocalSpeechModel.parakeet.manifest)
    }

    func test_barkIsEffectiveOnlyWhenItsOwnModelIsInstalled() {
        let onlyParakeet: (LocalSpeechModel) -> Bool = { $0 == .parakeet }
        XCTAssertEqual(DictationEngineChoice.effective(preferred: .bark, installed: onlyParakeet), .apple)
        XCTAssertEqual(DictationEngineChoice.effective(preferred: .barkClean, installed: { $0 == .barkClean }), .barkClean)
        XCTAssertEqual(DictationEngineChoice.effective(preferred: .parakeet, installed: onlyParakeet), .parakeet)
    }

    func test_barkCleanIsRecommendedOnlyForEnglishDictation() {
        XCTAssertTrue(DictationEngineCopy.isRecommended(.barkClean, localeIdentifier: "en-US"))
        XCTAssertFalse(DictationEngineCopy.isRecommended(.barkClean, localeIdentifier: "de-DE"))
        XCTAssertFalse(DictationEngineCopy.isRecommended(.bark, localeIdentifier: "en-US"))
        XCTAssertFalse(DictationEngineCopy.isRecommended(.parakeet, localeIdentifier: "en-US"))
    }

    @MainActor
    func test_warmUpIgnoresTheAppleEngine() {
        XCTAssertNil(LocalSpeechModelStore.warmUp(.apple))
    }

    func test_localEnginesSkipSpeechRecognitionPermission() {
        XCTAssertEqual(DictationPermissionRows.kinds(for: .bark), [.microphone, .accessibility])
        XCTAssertEqual(DictationPermissionRows.kinds(for: .barkClean), [.microphone, .accessibility])
        XCTAssertEqual(DictationPermissionRows.kinds(for: .apple), [.microphone, .speechRecognition, .accessibility])
    }

    func test_barkWarnsWhenTheDictationLanguageIsNotEnglish() {
        XCTAssertTrue(DictationEngineCopy.footer(engine: .bark, localeIdentifier: "de-DE").hasPrefix("Bark understands English only"))
        XCTAssertTrue(DictationEngineCopy.footer(engine: .barkClean, localeIdentifier: "fr_FR").hasPrefix("Bark Clean understands English only"))
        XCTAssertEqual(DictationEngineCopy.footer(engine: .bark, localeIdentifier: "en-GB"), DictationEngineCopy.footer)
        XCTAssertEqual(DictationEngineCopy.footer(engine: .parakeet, localeIdentifier: "de-DE"), DictationEngineCopy.footer)
    }

    func test_installVerifiesEveryFileAndMovesTheFolderIntoPlace() async throws {
        let files = [Self.file("a.bin", "alpha"), Self.file("nested/b.bin", "beta")]
        let source = FakeSource(contents: ["a.bin": "alpha", "nested/b.bin": "beta"], root: root)
        let target = root.appendingPathComponent("bark-3.0")
        let fractions = FractionLog()

        try await BarkModelDownloader(fetch: source.fetch).install(files, folder: "bark-3.0", into: target) { fractions.append($0) }

        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("nested/b.bin"), encoding: .utf8), "beta")
        XCTAssertTrue(BarkModelDownloader.isInstalled(files, in: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: BarkModelDownloader.stagingDirectory(for: target).path))
        XCTAssertEqual(fractions.values.last, 1)
        XCTAssertEqual(source.requested, ["bark-3.0/a.bin", "bark-3.0/nested/b.bin"])
    }

    func test_installRejectsAFileWhoseChecksumDoesNotMatch() async throws {
        let files = [Self.file("a.bin", "alpha")]
        let source = FakeSource(contents: ["a.bin": "alphX"], root: root)
        let target = root.appendingPathComponent("bark-3.0")

        do {
            try await BarkModelDownloader(fetch: source.fetch).install(files, folder: "bark-3.0", into: target) { _ in }
            XCTFail("install should throw")
        } catch {
            XCTAssertEqual(error as? BarkModelDownloadError, .checksumMismatch("a.bin"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func test_installRejectsAnHTTPError() async throws {
        let source = FakeSource(contents: ["a.bin": "alpha"], root: root, status: 404)
        do {
            try await BarkModelDownloader(fetch: source.fetch).install([Self.file("a.bin", "alpha")], folder: "bark-3.0", into: root.appendingPathComponent("m")) { _ in }
            XCTFail("install should throw")
        } catch {
            XCTAssertEqual(error as? BarkModelDownloadError, .badResponse(404))
        }
    }

    func test_installResumesWithoutRefetchingVerifiedFiles() async throws {
        let files = [Self.file("a.bin", "alpha"), Self.file("b.bin", "beta")]
        let target = root.appendingPathComponent("bark-3.0")
        let staging = BarkModelDownloader.stagingDirectory(for: target)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("alpha".utf8).write(to: staging.appendingPathComponent("a.bin"))
        let source = FakeSource(contents: ["a.bin": "alpha", "b.bin": "beta"], root: root)

        try await BarkModelDownloader(fetch: source.fetch).install(files, folder: "bark-3.0", into: target) { _ in }

        XCTAssertEqual(source.requested, ["bark-3.0/b.bin"])
        XCTAssertTrue(BarkModelDownloader.isInstalled(files, in: target))
    }

    func test_repairReusesInstalledFilesThatStillVerifyAndRefetchesDamagedOnes() async throws {
        let files = [Self.file("a.bin", "alpha"), Self.file("b.bin", "beta")]
        let target = root.appendingPathComponent("bark-3.0")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("alpha".utf8).write(to: target.appendingPathComponent("a.bin"))
        try Data("bxta".utf8).write(to: target.appendingPathComponent("b.bin"))
        let source = FakeSource(contents: ["a.bin": "alpha", "b.bin": "beta"], root: root)

        try await BarkModelDownloader(fetch: source.fetch).install(files, folder: "bark-3.0", into: target) { _ in }

        XCTAssertEqual(source.requested, ["bark-3.0/b.bin"])
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("b.bin"), encoding: .utf8), "beta")
        XCTAssertFalse(FileManager.default.fileExists(atPath: BarkModelDownloader.stagingDirectory(for: target).path))
    }

    @MainActor
    func test_aModelThatFailsToLoadStaysInstalledAndOffersRepair() async throws {
        let directory = root.appendingPathComponent("bark-3.0")
        try Self.writePlaceholders(BarkModelManifest.bark, in: directory)
        let store = LocalSpeechModelStore(model: .bark, directory: directory)
        XCTAssertEqual(store.state, .installed)

        do {
            _ = try await store.loadedModels()
            XCTFail("load should throw")
        } catch {}

        guard case .loadFailed = store.state else { return XCTFail("expected loadFailed, got \(store.state)") }
        XCTAssertTrue(store.isInstalled)
        XCTAssertFalse(store.isPreparing)
        store.refresh()
        guard case .loadFailed = store.state else { return XCTFail("refresh hid the load failure") }
        try store.remove()
        XCTAssertEqual(store.state, .notInstalled)
    }

    @MainActor
    func test_aFailedRepairKeepsTheInstalledBarkFilesAndStaysRepairable() async throws {
        let directory = root.appendingPathComponent("bark-3.0")
        try Self.writePlaceholders(BarkModelManifest.bark, in: directory)
        let source = FakeSource(contents: [:], root: root, status: 503)
        let store = LocalSpeechModelStore(
            model: .bark,
            directory: directory,
            downloader: BarkModelDownloader(fetch: source.fetch),
            defaults: Self.isolatedDefaults()
        )
        _ = try? await store.loadedModels()

        await store.download()

        guard case let .loadFailed(message) = store.state else { return XCTFail("expected loadFailed, got \(store.state)") }
        XCTAssertTrue(message.hasPrefix("Repair didn't finish."))
        XCTAssertTrue(store.isInstalled)
        XCTAssertFalse(store.isPreparing)
        XCTAssertTrue(BarkModelDownloader.isInstalled(BarkModelManifest.bark, in: directory))
    }

    @MainActor
    func test_replacingOnSuccessRestoresTheOldCopyWhenTheNewOneFails() async throws {
        let directory = root.appendingPathComponent("parakeet-tdt-0.6b-v3")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: directory.appendingPathComponent("Encoder.bin"))

        do {
            try await LocalSpeechModelStore.replacingOnSuccess(directory, when: true) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data("half".utf8).write(to: directory.appendingPathComponent("partial.bin"))
                throw URLError(.notConnectedToInternet)
            }
            XCTFail("operation should throw")
        } catch {}

        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("Encoder.bin"), encoding: .utf8), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("partial.bin").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".parakeet-tdt-0.6b-v3.backup").path))

        try await LocalSpeechModelStore.replacingOnSuccess(directory, when: true) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("new".utf8).write(to: directory.appendingPathComponent("Encoder.bin"))
        }
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("Encoder.bin"), encoding: .utf8), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".parakeet-tdt-0.6b-v3.backup").path))
    }

    @MainActor
    func test_parakeetLoadsOnlyFromDiskAndNeverDownloadsOnItsOwn() async throws {
        let directory = root.appendingPathComponent("parakeet-tdt-0.6b-v3")
        for name in ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data("{}".utf8).write(to: directory.appendingPathComponent("parakeet_vocab.json"))
        let store = LocalSpeechModelStore(model: .parakeet, directory: directory)
        guard store.isInstalled else { throw XCTSkip("FluidAudio needs more files to call Parakeet installed") }
        let started = Date()

        do {
            _ = try await store.loadedModels()
            XCTFail("load should throw")
        } catch {}

        guard case .loadFailed = store.state else { return XCTFail("expected loadFailed, got \(store.state)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path))
    }

    @MainActor
    func test_storeReportsInstalledOnlyWhenEveryManifestFileIsPresent() throws {
        let directory = root.appendingPathComponent("bark-3.0")
        XCTAssertEqual(LocalSpeechModelStore(model: .bark, directory: directory).state, .notInstalled)
        for file in BarkModelManifest.bark.dropLast() {
            let url = directory.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(file.size))
            try handle.close()
        }
        XCTAssertEqual(LocalSpeechModelStore(model: .bark, directory: directory).state, .notInstalled)
    }

    @MainActor
    func test_removeDeletesTheModelAndAnyPartialDownload() throws {
        let directory = root.appendingPathComponent("bark-3.0")
        let staging = BarkModelDownloader.stagingDirectory(for: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let store = LocalSpeechModelStore(model: .bark, directory: directory)

        try store.remove()

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(store.state, .notInstalled)
    }

    @MainActor
    func test_aFailedBarkDownloadReportsTheReasonAndLeavesNothingInstalled() async {
        let directory = root.appendingPathComponent("bark-3.0")
        let source = FakeSource(contents: [:], root: root, status: 503)
        let store = LocalSpeechModelStore(model: .bark, directory: directory, downloader: BarkModelDownloader(fetch: source.fetch))

        await store.download()

        XCTAssertEqual(store.state, .failed("Hugging Face answered with HTTP 503."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(source.requested.first, "bark-3.0/\(BarkModelManifest.bark[0].path)")
        try? store.remove()
        XCTAssertEqual(store.state, .notInstalled)
    }

    @MainActor
    func test_downloadsAndLoadsBarkCleanFromHuggingFaceOnlyWhenAskedTo() async throws {
        guard ProcessInfo.processInfo.environment["VOQORA_BARK_DOWNLOAD"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_VOQORA_BARK_DOWNLOAD=1 to download Bark Clean from Hugging Face")
        }
        let store = LocalSpeechModelStore(model: .barkClean, directory: root.appendingPathComponent("bark-3.0-clean"))

        await store.download()

        XCTAssertEqual(store.state, .installed)
        _ = try await store.loadedModels()
        XCTAssertEqual(store.state, .installed)
        XCTAssertFalse(store.isPreparing)
    }

    @MainActor
    func test_storeLoadFailsCleanlyWhenNotInstalled() async {
        let store = LocalSpeechModelStore(model: .barkClean, directory: root.appendingPathComponent("missing"))
        do {
            _ = try await store.loadedModels()
            XCTFail("load should throw")
        } catch {
            XCTAssertEqual(error as? LocalSpeechModelError, .notInstalled("Bark Clean"))
        }
    }

    private static func isolatedDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "LocalSpeechModelTests.\(UUID().uuidString)")!
        defaults.set(DictationEngineChoice.apple.rawValue, forKey: DictationPreferences.engineKey)
        return defaults
    }

    private static func writePlaceholders(_ files: [BarkModelFile], in directory: URL) throws {
        for file in files {
            let url = directory.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(file.size))
            try handle.close()
        }
    }

    private static func file(_ path: String, _ text: String) -> BarkModelFile {
        let data = Data(text.utf8)
        return BarkModelFile(path: path, size: Int64(data.count), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
}

private final class FractionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []

    var values: [Double] {
        lock.withLock { stored }
    }

    func append(_ value: Double) {
        lock.withLock { stored.append(value) }
    }
}

private final class FakeSource: @unchecked Sendable {
    private let lock = NSLock()
    private let contents: [String: String]
    private let root: URL
    private let status: Int
    private var log: [String] = []

    init(contents: [String: String], root: URL, status: Int = 200) {
        self.contents = contents
        self.root = root
        self.status = status
    }

    var requested: [String] {
        lock.withLock { log }
    }

    var fetch: BarkModelDownloader.Fetch {
        { [self] url, onWritten in
            let path = url.pathComponents.drop { $0 != BarkModelManifest.revision }.dropFirst().joined(separator: "/")
            lock.withLock { log.append(path) }
            let name = path.split(separator: "/", maxSplits: 1).last.map(String.init) ?? path
            let data = Data((contents[name] ?? "").utf8)
            let temporary = root.appendingPathComponent(UUID().uuidString)
            try data.write(to: temporary)
            onWritten(Int64(data.count))
            return (temporary, status)
        }
    }
}

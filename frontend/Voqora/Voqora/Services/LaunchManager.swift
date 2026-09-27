import Combine
import CryptoKit
import Foundation
import ServiceManagement

private final nonisolated class RuntimeValidationCache: @unchecked Sendable {
    static let shared = RuntimeValidationCache()

    private let lock = NSLock()
    private var validatedFingerprint: String?

    func isValid(_ fingerprint: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return validatedFingerprint == fingerprint
    }

    func record(_ fingerprint: String) {
        lock.lock()
        defer { lock.unlock() }
        validatedFingerprint = fingerprint
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        validatedFingerprint = nil
    }
}

@MainActor
class LaunchManager: ObservableObject {
    nonisolated struct RuntimeManifest: Decodable, Sendable {
        nonisolated struct FileEntry: Decodable, Sendable {
            let path: String
            let sha256: String
            let mode: Int
        }

        let format: Int
        let version: String
        let archiveSHA256: String
        let root: String
        let files: [FileEntry]

        enum CodingKeys: String, CodingKey {
            case format, version, root, files
            case archiveSHA256 = "archive_sha256"
        }
    }

    enum RuntimeIntegrityError: LocalizedError {
        case manifestMissing
        case invalidManifest
        case archiveMismatch
        case unsafeArchive
        case extractedRuntimeMismatch

        var errorDescription: String? {
            switch self {
            case .manifestMissing:
                "The packaged backend integrity manifest is missing."
            case .invalidManifest:
                "The packaged backend integrity manifest is invalid."
            case .archiveMismatch:
                "The packaged backend archive did not pass integrity verification."
            case .unsafeArchive:
                "The packaged backend archive contains unsafe paths."
            case .extractedRuntimeMismatch:
                "The local backend did not pass integrity verification."
            }
        }
    }

    @Published var isReady = false
    @Published var error: String? = nil
    @Published private(set) var isPreparing = false

    @Published var isLaunchAtLoginEnabled: Bool = false {
        didSet {
            try? updateLoginItem()
        }
    }

    init() {
        isLaunchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    nonisolated static func backendMarker(bundleVersion: String, archiveBuildID: String?) -> String {
        guard let archiveBuildID else { return "version:\(bundleVersion)" }
        let normalizedID = archiveBuildID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return "version:\(bundleVersion)" }
        return "archive:\(normalizedID)"
    }

    nonisolated static func runtimeManifest(at url: URL) throws -> RuntimeManifest {
        let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: Data(contentsOf: url))
        guard manifest.format == 1,
              manifest.root == "VoqoraServer",
              !manifest.version.isEmpty,
              isLowercaseHex64(manifest.archiveSHA256),
              !manifest.files.isEmpty
        else {
            throw RuntimeIntegrityError.invalidManifest
        }

        var paths = Set<String>()
        for entry in manifest.files {
            guard isSafeRelativeRuntimePath(entry.path),
                  isLowercaseHex64(entry.sha256),
                  (0 ... 0o777).contains(entry.mode),
                  paths.insert(entry.path).inserted
            else {
                throw RuntimeIntegrityError.invalidManifest
            }
        }
        guard paths.contains("VoqoraServer") else {
            throw RuntimeIntegrityError.invalidManifest
        }
        return manifest
    }

    nonisolated static func validateBundledArchive(
        at archiveURL: URL,
        manifest: RuntimeManifest
    ) throws {
        guard sha256(of: archiveURL) == manifest.archiveSHA256 else {
            throw RuntimeIntegrityError.archiveMismatch
        }

        let output = try runTool("/usr/bin/zipinfo", arguments: ["-1", archiveURL.path])
        var members = Set<String>()
        for rawMember in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let member = String(rawMember)
            let normalized = member.hasSuffix("/") ? String(member.dropLast()) : member
            guard isSafeArchivePath(normalized), members.insert(member).inserted else {
                throw RuntimeIntegrityError.unsafeArchive
            }
        }
        guard !members.isEmpty else { throw RuntimeIntegrityError.unsafeArchive }

        let details = try runTool("/usr/bin/zipinfo", arguments: ["-l", archiveURL.path])
        for line in details.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let first = line.first else { continue }
            if first == "l" {
                throw RuntimeIntegrityError.unsafeArchive
            }
        }
    }

    nonisolated static func validateInstalledRuntime(
        at serverURL: URL,
        manifest: RuntimeManifest,
        fileManager: FileManager = .default
    ) throws {
        var actualFiles = Set<String>()
        guard let enumerator = fileManager.enumerator(
            at: serverURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw RuntimeIntegrityError.extractedRuntimeMismatch
        }
        let resolvedRoot = serverURL.resolvingSymlinksInPath().standardizedFileURL

        var expectedDirectories = Set<String>()
        for entry in manifest.files {
            let components = entry.path.split(separator: "/")
            guard components.count > 1 else { continue }
            for depth in 1 ..< components.count {
                expectedDirectories.insert(components[0 ..< depth].joined(separator: "/"))
            }
        }

        while let fileURL = enumerator.nextObject() as? URL {
            let resolvedFileURL = fileURL.resolvingSymlinksInPath().standardizedFileURL
            if resolvedFileURL == resolvedRoot {
                continue
            }
            let relative = resolvedFileURL.path.replacingOccurrences(of: resolvedRoot.path + "/", with: "")
            if relative == ".bundle_version" {
                continue
            }
            guard isSafeRelativeRuntimePath(relative) else {
                throw RuntimeIntegrityError.extractedRuntimeMismatch
            }
            guard let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                throw RuntimeIntegrityError.extractedRuntimeMismatch
            }
            guard values.isSymbolicLink != true else {
                throw RuntimeIntegrityError.extractedRuntimeMismatch
            }
            if values.isDirectory == true {
                guard expectedDirectories.contains(relative) else {
                    throw RuntimeIntegrityError.extractedRuntimeMismatch
                }
                continue
            }
            actualFiles.insert(relative)
        }

        let expectedFiles = Set(manifest.files.map(\.path))
        guard actualFiles == expectedFiles else {
            throw RuntimeIntegrityError.extractedRuntimeMismatch
        }
        for entry in manifest.files {
            let fileURL = serverURL.appendingPathComponent(entry.path)
            guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let mode = attributes[.posixPermissions] as? NSNumber,
                  Int(mode.intValue) & 0o777 == entry.mode,
                  sha256(of: fileURL) == entry.sha256
            else {
                throw RuntimeIntegrityError.extractedRuntimeMismatch
            }
        }
    }

    nonisolated static func runtimeStateFingerprint(
        at serverURL: URL,
        manifest: RuntimeManifest,
        fileManager: FileManager = .default
    ) -> String? {
        let rootPath = serverURL.standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(
            at: serverURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return nil }

        var lines: [String] = []
        while let fileURL = enumerator.nextObject() as? URL {
            let path = fileURL.standardizedFileURL.path
            if path == rootPath {
                continue
            }
            guard path.hasPrefix(rootPath + "/") else { return nil }
            let relative = String(path.dropFirst(rootPath.count + 1))
            var status = stat()
            guard lstat(path, &status) == 0 else { return nil }
            let type = status.st_mode & S_IFMT
            let mode = status.st_mode & 0o7777
            let modified = status.st_mtimespec
            lines.append(
                "\(relative)|\(type)|\(status.st_size)|\(mode)|\(modified.tv_sec).\(modified.tv_nsec)"
            )
        }
        guard !lines.isEmpty else { return nil }

        var digest = SHA256()
        digest.update(data: Data("\(rootPath)\u{0}\(manifest.archiveSHA256)\u{0}\(manifest.version)\u{0}".utf8))
        for line in lines.sorted() {
            digest.update(data: Data(line.utf8))
            digest.update(data: Data([0]))
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func verifyInstalledRuntime(
        at serverURL: URL,
        manifest: RuntimeManifest,
        fileManager: FileManager = .default
    ) throws {
        if let fingerprint = runtimeStateFingerprint(at: serverURL, manifest: manifest, fileManager: fileManager),
           RuntimeValidationCache.shared.isValid(fingerprint)
        {
            return
        }
        try validateInstalledRuntime(at: serverURL, manifest: manifest, fileManager: fileManager)
        recordValidatedRuntime(at: serverURL, manifest: manifest, fileManager: fileManager)
    }

    nonisolated static func recordValidatedRuntime(
        at serverURL: URL,
        manifest: RuntimeManifest,
        fileManager: FileManager = .default
    ) {
        guard let fingerprint = runtimeStateFingerprint(
            at: serverURL,
            manifest: manifest,
            fileManager: fileManager
        ) else { return }
        RuntimeValidationCache.shared.record(fingerprint)
    }

    nonisolated static func invalidateRuntimeValidation() {
        RuntimeValidationCache.shared.invalidate()
    }

    nonisolated static func validateRuntimeForExecution(at executableURL: URL) throws {
        guard let manifestURL = Bundle.main.url(
            forResource: "VoqoraServer",
            withExtension: "manifest.json"
        ) else {
            throw RuntimeIntegrityError.manifestMissing
        }
        let manifest = try runtimeManifest(at: manifestURL)
        try verifyInstalledRuntime(
            at: executableURL.deletingLastPathComponent(),
            manifest: manifest
        )
    }

    private nonisolated static func isLowercaseHex64(_ value: String) -> Bool {
        let bytes = value.utf8
        guard bytes.count == 64 else { return false }
        for byte in bytes {
            let isDigit = byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
            let isLowerAF = byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f")
            guard isDigit || isLowerAF else { return false }
        }
        return true
    }

    private nonisolated static func isSafeRelativeRuntimePath(_ path: String) -> Bool {
        !path.isEmpty
            && !path.hasPrefix("/")
            && !path.contains("\\")
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." || $0.isEmpty })
    }

    private nonisolated static func isSafeArchivePath(_ path: String) -> Bool {
        path == "VoqoraServer" || (path.hasPrefix("VoqoraServer/") && isSafeRelativeRuntimePath(String(path.dropFirst("VoqoraServer/".count))))
    }

    private nonisolated static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var digest = SHA256()
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 1024 * 1024)
            } catch {
                return nil
            }
            guard let chunk else { break }
            guard !chunk.isEmpty else { break }
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func runTool(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw RuntimeIntegrityError.unsafeArchive }
        guard let text = String(data: data, encoding: .utf8) else {
            throw RuntimeIntegrityError.unsafeArchive
        }
        return text
    }

    nonisolated static func removeStaleBackendStagingDirectories(
        in appSupport: URL,
        fileManager: FileManager = .default,
        now: Date = Date(),
        minimumAge: TimeInterval = 60 * 60
    ) {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: appSupport,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: []
        ) else { return }

        for entry in entries where entry.lastPathComponent.hasPrefix(".backend-staging-") {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values?.isDirectory == true,
                  let modified = values?.contentModificationDate,
                  now.timeIntervalSince(modified) >= minimumAge else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }

    nonisolated static func installValidatedBackend(
        from stagedServerURL: URL,
        to serverURL: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: stagedServerURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        if fileManager.fileExists(atPath: serverURL.path) {
            _ = try fileManager.replaceItemAt(
                serverURL,
                withItemAt: stagedServerURL,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
        } else {
            try fileManager.moveItem(at: stagedServerURL, to: serverURL)
        }
    }

    private func updateLoginItem() throws {
        if isLaunchAtLoginEnabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        }
    }

    func prepare() async {
        guard !isReady, !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }

        let fm = FileManager.default
        let bundleID = Bundle.main.bundleIdentifier ?? "com.himudigonda.Voqora"
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID)

        let serverURL = appSupport.appendingPathComponent("VoqoraServer")
        let executableURL = serverURL.appendingPathComponent("VoqoraServer")
        let versionMarkerURL = serverURL.appendingPathComponent(".bundle_version")

        guard let zipURL = Bundle.main.url(forResource: "VoqoraServer", withExtension: "zip") else {
            error = "Backend zip missing from bundle."
            return
        }
        guard let manifestURL = Bundle.main.url(
            forResource: "VoqoraServer",
            withExtension: "manifest.json"
        ) else {
            error = "Backend integrity manifest missing from bundle."
            return
        }

        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "unknown"
        let archiveBuildID = Bundle.main
            .url(forResource: "VoqoraServer", withExtension: "build-id")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let expectedMarker = Self.backendMarker(bundleVersion: currentVersion, archiveBuildID: archiveBuildID)
        if fm.isExecutableFile(atPath: executableURL.path),
           let stored = try? String(contentsOf: versionMarkerURL, encoding: .utf8),
           stored.trimmingCharacters(in: .whitespacesAndNewlines) == expectedMarker,
           let manifest = try? Self.runtimeManifest(at: manifestURL),
           manifest.version == currentVersion
        {
            let started = Date()
            let verified = await Task.detached(priority: .userInitiated) { () -> Bool in
                do {
                    try Self.verifyInstalledRuntime(
                        at: serverURL,
                        manifest: manifest,
                        fileManager: FileManager()
                    )
                    return true
                } catch {
                    return false
                }
            }.value

            if verified {
                VoqoraLog.info("LaunchManager", "Verified backend already extracted", [
                    "verifyMs": "\(Int(Date().timeIntervalSince(started) * 1000))",
                ])
                isReady = true
                return
            }
        }

        VoqoraLog.info("LaunchManager", "Extracting backend (first launch or update)", ["version": currentVersion])
        let stagingURL = appSupport.appendingPathComponent(".backend-staging-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: appSupport.path)
            Self.removeStaleBackendStagingDirectories(in: appSupport, fileManager: fm)
            try fm.createDirectory(at: stagingURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: stagingURL) }

            Self.invalidateRuntimeValidation()

            let manifest = try Self.runtimeManifest(at: manifestURL)
            guard manifest.version == currentVersion else { throw RuntimeIntegrityError.invalidManifest }

            let zipPath = zipURL.path
            let bundledZipURL = zipURL
            let stagingPath = stagingURL.path
            let stagedServerURL = stagingURL.appendingPathComponent("VoqoraServer")
            let installedServerURL = serverURL

            try await Task.detached(priority: .userInitiated) {
                let fm = FileManager()
                try Self.validateBundledArchive(at: bundledZipURL, manifest: manifest)

                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                unzip.arguments = ["-o", "-q", zipPath, "-d", stagingPath]
                try unzip.run()
                unzip.waitUntilExit()
                guard unzip.terminationStatus == 0 else {
                    throw NSError(
                        domain: "LaunchManager",
                        code: Int(unzip.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey:
                            "unzip failed (status \(unzip.terminationStatus))"]
                    )
                }

                try Self.validateInstalledRuntime(
                    at: stagedServerURL,
                    manifest: manifest,
                    fileManager: fm
                )
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stagedServerURL.path)

                try Self.installValidatedBackend(
                    from: stagedServerURL,
                    to: installedServerURL,
                    fileManager: fm
                )
                try Self.validateInstalledRuntime(
                    at: installedServerURL,
                    manifest: manifest,
                    fileManager: fm
                )
            }.value

            try expectedMarker.write(
                to: versionMarkerURL,
                atomically: true,
                encoding: .utf8
            )

            Self.recordValidatedRuntime(at: serverURL, manifest: manifest, fileManager: fm)

            VoqoraLog.info("LaunchManager", "Backend extracted successfully", ["version": currentVersion])
            isReady = true
        } catch {
            VoqoraLog.error("LaunchManager", "Backend extraction failed", ["failureCode": "runtime_extraction_failed", "version": currentVersion])
            self.error = "Launch Error: \(error.localizedDescription)"
        }
    }
}

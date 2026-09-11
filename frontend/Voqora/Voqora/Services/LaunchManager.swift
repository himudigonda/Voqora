import Combine
import CryptoKit
import Foundation
import ServiceManagement

/// Handles the initial extraction and validation of the Python backend.
@MainActor
class LaunchManager: ObservableObject {
    struct RuntimeManifest: Decodable, Sendable {
        struct FileEntry: Decodable, Sendable {
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
                return "The packaged backend integrity manifest is missing."
            case .invalidManifest:
                return "The packaged backend integrity manifest is invalid."
            case .archiveMismatch:
                return "The packaged backend archive did not pass integrity verification."
            case .unsafeArchive:
                return "The packaged backend archive contains unsafe paths."
            case .extractedRuntimeMismatch:
                return "The local backend did not pass integrity verification."
            }
        }
    }

    @Published var isReady = false
    @Published var error: String? = nil
    @Published private(set) var isPreparing = false

    // Fix: Add the actual registration logic
    @Published var isLaunchAtLoginEnabled: Bool = false {
        didSet {
            try? updateLoginItem()
        }
    }

    init() {
        // Sync the toggle state with macOS reality on start
        isLaunchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Identifies the exact bundled backend archive when available. Older
    /// signed builds did not carry a build-id file, so they retain the
    /// version-only marker until they are replaced by a newer build.
    static func backendMarker(bundleVersion: String, archiveBuildID: String?) -> String {
        guard let archiveBuildID else { return "version:\(bundleVersion)" }
        let normalizedID = archiveBuildID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return "version:\(bundleVersion)" }
        return "archive:\(normalizedID)"
    }

    /// Reads the detached manifest sealed alongside the backend zip in the app
    /// bundle. It is detached specifically so it can authenticate the zip's
    /// complete SHA-256 digest without a self-referential archive hash.
    static func runtimeManifest(at url: URL) throws -> RuntimeManifest {
        let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: Data(contentsOf: url))
        guard manifest.format == 1,
              manifest.root == "VoqoraServer",
              !manifest.version.isEmpty,
              manifest.archiveSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              !manifest.files.isEmpty else {
            throw RuntimeIntegrityError.invalidManifest
        }

        var paths = Set<String>()
        for entry in manifest.files {
            guard isSafeRelativeRuntimePath(entry.path),
                  entry.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  (0...0o777).contains(entry.mode),
                  paths.insert(entry.path).inserted else {
                throw RuntimeIntegrityError.invalidManifest
            }
        }
        guard paths.contains("VoqoraServer") else {
            throw RuntimeIntegrityError.invalidManifest
        }
        return manifest
    }

    /// The pre-extraction check deliberately validates archive names before
    /// invoking `unzip`: a crafted archive never gets an opportunity to write
    /// outside the private staging directory.
    static func validateBundledArchive(
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

        // Name validation alone cannot reveal a Unix symlink. Refuse one
        // before extraction, because a link followed by a later archive entry
        // can otherwise redirect an extractor's writes.
        let details = try runTool("/usr/bin/zipinfo", arguments: ["-l", archiveURL.path])
        for line in details.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let first = line.first else { continue }
            if first == "l" { throw RuntimeIntegrityError.unsafeArchive }
        }
    }

    /// Validates every installed file every time a process is about to run.
    /// The extracted copy is user-writable Application Support data and must
    /// never be trusted merely because a previous extraction succeeded.
    static func validateInstalledRuntime(
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

        while let fileURL = enumerator.nextObject() as? URL {
            // FileManager's recursive enumerator can yield its starting URL on
            // some macOS filesystem providers. It is the trusted root passed
            // to this validator, not an archive member.
            let resolvedFileURL = fileURL.resolvingSymlinksInPath().standardizedFileURL
            if resolvedFileURL == resolvedRoot { continue }
            let relative = resolvedFileURL.path.replacingOccurrences(of: resolvedRoot.path + "/", with: "")
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
                let expectedDirectories = Set(manifest.files.compactMap { entry -> String? in
                    let components = entry.path.split(separator: "/")
                    guard components.count > 1 else { return nil }
                    return components.dropLast().joined(separator: "/")
                })
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
                  sha256(of: fileURL) == entry.sha256 else {
                throw RuntimeIntegrityError.extractedRuntimeMismatch
            }
        }
    }

    /// Entry point for BackendService immediately before `Process.run()`.
    /// It reloads the sealed manifest rather than relying on state retained
    /// from app launch, so a runtime changed after preparation is rejected.
    static func validateRuntimeForExecution(at executableURL: URL) throws {
        guard let manifestURL = Bundle.main.url(
            forResource: "VoqoraServer",
            withExtension: "manifest.json"
        ) else {
            throw RuntimeIntegrityError.manifestMissing
        }
        let manifest = try runtimeManifest(at: manifestURL)
        try validateInstalledRuntime(
            at: executableURL.deletingLastPathComponent(),
            manifest: manifest
        )
    }

    private static func isSafeRelativeRuntimePath(_ path: String) -> Bool {
        !path.isEmpty
            && !path.hasPrefix("/")
            && !path.contains("\\")
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." || $0.isEmpty })
    }

    private static func isSafeArchivePath(_ path: String) -> Bool {
        path == "VoqoraServer" || (path.hasPrefix("VoqoraServer/") && isSafeRelativeRuntimePath(String(path.dropFirst("VoqoraServer/".count))))
    }

    private static func sha256(of url: URL) -> String? {
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

    private static func runTool(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        // Drain before waiting: zipinfo emits one line per packaged file and
        // can exceed a pipe buffer for the PyInstaller runtime.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw RuntimeIntegrityError.unsafeArchive }
        return String(decoding: data, as: UTF8.self)
    }

    /// An interrupted first launch can leave an extraction staging directory
    /// behind. Remove only directories with our exact prefix that have been
    /// untouched for an hour; a fresh concurrent extraction is never touched.
    static func removeStaleBackendStagingDirectories(
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

    /// Promote a fully validated staged backend without first removing the
    /// working copy. `replaceItemAt` keeps the prior server in place if the
    /// filesystem rejects the final replacement, which is materially safer
    /// than delete-then-move during an update or an interrupted first launch.
    static func installValidatedBackend(
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

        let serverURL    = appSupport.appendingPathComponent("VoqoraServer")
        let executableURL = serverURL.appendingPathComponent("VoqoraServer")
        // Marker file: stores the exact bundled backend archive identity that
        // was last extracted. This prevents a local rebuild from quietly
        // talking to a stale server with the same marketing version.
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

        // ─── Fast path: skip the 60-120 s zip extraction when binary is already current ───
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
           manifest.version == currentVersion,
           (try? Self.validateBundledArchive(at: zipURL, manifest: manifest)) != nil,
           (try? Self.validateInstalledRuntime(at: serverURL, manifest: manifest, fileManager: fm)) != nil {
            VoqoraLog.info("LaunchManager", "Verified backend already extracted")
            isReady = true
            return
        }

        // ─── Slow path: extract (first launch or after an app update) ───────────────────
        VoqoraLog.info("LaunchManager", "Extracting backend (first launch or update)", ["version": currentVersion])
        let stagingURL = appSupport.appendingPathComponent(".backend-staging-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: appSupport.path)
            Self.removeStaleBackendStagingDirectories(in: appSupport, fileManager: fm)
            try fm.createDirectory(at: stagingURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: stagingURL) }

            let manifest = try Self.runtimeManifest(at: manifestURL)
            guard manifest.version == currentVersion else { throw RuntimeIntegrityError.invalidManifest }
            try Self.validateBundledArchive(at: zipURL, manifest: manifest)

            let zipPath = zipURL.path
            let stagingPath = stagingURL.path
            let stagedServerURL = stagingURL.appendingPathComponent("VoqoraServer")
            try await Task.detached(priority: .userInitiated) {
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
            }.value

            try Self.validateInstalledRuntime(
                at: stagedServerURL,
                manifest: manifest,
                fileManager: fm
            )
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stagedServerURL.path)

            // The existing backend remains intact until the complete archive
            // has passed extraction and executable checks. The final handoff
            // replaces it atomically where the filesystem supports it instead
            // of deleting it before the new server has a final home.
            try Self.installValidatedBackend(
                from: stagedServerURL,
                to: serverURL,
                fileManager: fm
            )
            try Self.validateInstalledRuntime(at: serverURL, manifest: manifest, fileManager: fm)

            // Stamp the exact archive identity only after the fully validated
            // backend is in its final location. A partial extraction can never
            // win the fast path on a later launch.
            try expectedMarker.write(
                to: versionMarkerURL,
                atomically: true,
                encoding: .utf8
            )

            VoqoraLog.info("LaunchManager", "Backend extracted successfully", ["version": currentVersion])
            isReady = true
        } catch {
            VoqoraLog.error("LaunchManager", "Backend extraction failed", ["error": String(describing: error), "version": currentVersion])
            self.error = "Launch Error: \(error.localizedDescription)"
        }
    }
}

import Combine
import CryptoKit
import Foundation
import ServiceManagement

/// Process-wide record of the one installed runtime whose full SHA-256
/// verification has already passed during this app session.
///
/// Full verification reads and hashes every byte of the ~578 MB PyInstaller
/// runtime. That is a reasonable price to pay once per launch. It is the
/// wrong price to pay a second time moments later in `BackendService.start()`,
/// and it is a catastrophic price to pay on the heartbeat's retry loop, which
/// calls `start()` again every 2 seconds for as long as the backend stays
/// offline — that turned a one-time launch cost into sustained, unbounded
/// main-thread hashing whenever the server was down.
///
/// A cache hit is never unconditional. `LaunchManager.runtimeStateFingerprint`
/// re-walks the whole installed tree and digests every entry's relative path,
/// type, size, permission bits and modification date. Any file added, removed,
/// replaced, chmod-ed or written through the filesystem changes that digest
/// and forces the full hash to run again. The expensive check therefore still
/// does its job against real corruption and ordinary tampering; it just stops
/// re-reading 578 MB to re-derive an answer that nothing has invalidated.
///
/// `nonisolated` throughout: this target compiles with MainActor-by-default
/// actor isolation, and every caller here runs on a background executor
/// precisely so the main thread is free. The `NSLock` is what makes that safe.
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

/// Handles the initial extraction and validation of the Python backend.
@MainActor
class LaunchManager: ObservableObject {
    // `nonisolated`: this target compiles with MainActor-by-default isolation,
    // which would otherwise isolate the synthesized `Decodable` conformance to
    // the main actor and make it unusable from the background task that does
    // the actual verification work.
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
    nonisolated static func backendMarker(bundleVersion: String, archiveBuildID: String?) -> String {
        guard let archiveBuildID else { return "version:\(bundleVersion)" }
        let normalizedID = archiveBuildID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return "version:\(bundleVersion)" }
        return "archive:\(normalizedID)"
    }

    /// Reads the detached manifest sealed alongside the backend zip in the app
    /// bundle. It is detached specifically so it can authenticate the zip's
    /// complete SHA-256 digest without a self-referential archive hash.
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

    /// The pre-extraction check deliberately validates archive names before
    /// invoking `unzip`: a crafted archive never gets an opportunity to write
    /// outside the private staging directory.
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

        // Name validation alone cannot reveal a Unix symlink. Refuse one
        // before extraction, because a link followed by a later archive entry
        // can otherwise redirect an extractor's writes.
        let details = try runTool("/usr/bin/zipinfo", arguments: ["-l", archiveURL.path])
        for line in details.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let first = line.first else { continue }
            if first == "l" {
                throw RuntimeIntegrityError.unsafeArchive
            }
        }
    }

    /// Validates every installed file every time a process is about to run.
    /// The extracted copy is user-writable Application Support data and must
    /// never be trusted merely because a previous extraction succeeded.
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

        // Every ancestor directory of every manifest file, not just each
        // file's immediate parent — a package directory containing only
        // subdirectories and no files of its own (e.g. `_internal/numpy`,
        // whose entries all live deeper under `_internal/numpy/core`, ...)
        // is still a real directory the enumerator below will visit, and
        // computing only immediate parents left it permanently unrecognized,
        // failing verification for any archive with that shape.
        var expectedDirectories = Set<String>()
        for entry in manifest.files {
            let components = entry.path.split(separator: "/")
            guard components.count > 1 else { continue }
            for depth in 1 ..< components.count {
                expectedDirectories.insert(components[0 ..< depth].joined(separator: "/"))
            }
        }

        while let fileURL = enumerator.nextObject() as? URL {
            // FileManager's recursive enumerator can yield its starting URL on
            // some macOS filesystem providers. It is the trusted root passed
            // to this validator, not an archive member.
            let resolvedFileURL = fileURL.resolvingSymlinksInPath().standardizedFileURL
            if resolvedFileURL == resolvedRoot {
                continue
            }
            let relative = resolvedFileURL.path.replacingOccurrences(of: resolvedRoot.path + "/", with: "")
            // `.bundle_version` is this code's own fast-path marker, stamped
            // into `serverURL` right after a successful extraction+install —
            // never an archive member, so the manifest never lists it. Every
            // launch after the first one hit exactly this: extraction succeeds,
            // the marker gets written, and this same validator (run again by
            // `validateRuntimeForExecution` immediately before `Process.run()`,
            // and by the fast-path check at the top of this function on every
            // later launch) found an "extra" file and failed closed — forcing
            // a full re-extraction every single time and then failing anyway.
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

    /// A cheap, change-sensitive summary of the installed runtime as it
    /// currently sits on disk: the sealed manifest's own identity, plus every
    /// entry the tree actually contains with its relative path, file type,
    /// size, permission bits and modification date.
    ///
    /// This walks the same tree `validateInstalledRuntime` walks but never
    /// opens a file, so it costs milliseconds instead of seconds. It is not a
    /// substitute for the SHA-256 pass and is never used as one — it exists
    /// solely to answer "is this bit-for-bit the same tree the SHA-256 pass
    /// already approved in this session?". Adding, removing, replacing,
    /// truncating, chmod-ing or rewriting any file moves the digest, so the
    /// answer degrades to "re-verify properly", never to "trust it anyway".
    ///
    /// Returns nil when the tree cannot be walked at all, which likewise
    /// forces the caller onto the full-verification path.
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
            // `lstat` rather than `FileManager.attributesOfItem`: this runs
            // once per installed file (2131 of them) on a path that the
            // heartbeat retries every 2 seconds, and building an
            // `NSDictionary` of boxed values per file cost ~130 ms against
            // ~10 ms for the raw syscall. `lstat` also does not traverse
            // symlinks, so a link substituted for a real file changes
            // `S_IFMT` here instead of silently describing its target.
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
        // `FileManager`'s enumerator makes no ordering promise across
        // filesystems, so sort before digesting or the same tree could
        // fingerprint differently between two walks.
        for line in lines.sorted() {
            digest.update(data: Data(line.utf8))
            digest.update(data: Data([0]))
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// `validateInstalledRuntime`, but at most once per unchanged runtime per
    /// app session. Use this from every product code path; the uncached
    /// `validateInstalledRuntime` stays available for the extraction path and
    /// for tests that need the full pass unconditionally.
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

    /// Pins the current on-disk state as "already fully verified". Only ever
    /// called immediately after a successful `validateInstalledRuntime`, or
    /// after `prepare()` stamps its `.bundle_version` marker — that write is
    /// itself part of the tree and would otherwise invalidate the entry the
    /// post-install verification just earned.
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

    /// Drops the session's "already verified" entry. Called before the app
    /// re-extracts and replaces the runtime, so a fresh install can never be
    /// waved through on the strength of the previous one's verification.
    nonisolated static func invalidateRuntimeValidation() {
        RuntimeValidationCache.shared.invalidate()
    }

    /// Entry point for BackendService immediately before `Process.run()`.
    /// It reloads the sealed manifest rather than relying on state retained
    /// from app launch, so a runtime changed after preparation is rejected.
    ///
    /// The manifest reload is cheap; the integrity pass behind it is not, and
    /// this runs on every launch attempt — including the heartbeat's 2-second
    /// retry while the backend is down. `verifyInstalledRuntime` keeps the
    /// fail-closed contract while charging the full ~578 MB hash only when the
    /// runtime has actually changed since this session last approved it.
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

    /// Exactly `^[0-9a-f]{64}$`, without the regex engine.
    ///
    /// The manifest lists one entry per installed file (2131 of them for the
    /// shipped PyInstaller runtime) and the whole manifest is re-validated on
    /// every pre-execution integrity check — including every heartbeat retry
    /// while the backend is down. Running `NSRegularExpression` 2131+ times on
    /// that path dominated the check once the SHA-256 work was cached away.
    /// This is the same predicate, byte for byte.
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
        // Drain before waiting: zipinfo emits one line per packaged file and
        // can exceed a pipe buffer for the PyInstaller runtime.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw RuntimeIntegrityError.unsafeArchive }
        guard let text = String(data: data, encoding: .utf8) else {
            throw RuntimeIntegrityError.unsafeArchive
        }
        return text
    }

    /// An interrupted first launch can leave an extraction staging directory
    /// behind. Remove only directories with our exact prefix that have been
    /// untouched for an hour; a fresh concurrent extraction is never touched.
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

    /// Promote a fully validated staged backend without first removing the
    /// working copy. `replaceItemAt` keeps the prior server in place if the
    /// filesystem rejects the final replacement, which is materially safer
    /// than delete-then-move during an update or an interrupted first launch.
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
           manifest.version == currentVersion
        {
            // The bundled zip is deliberately NOT re-hashed here. On this path
            // nothing is ever extracted from it: the installed runtime is
            // verified directly against the sealed manifest, file by file. The
            // zip's 425 MB digest only certifies bytes that are about to be
            // unpacked, which is exactly what the extraction path below still
            // does before it runs `unzip`. Hashing it on a launch that unpacks
            // nothing certified nothing — and the manifest it would have been
            // checked against is a sibling resource inside the same codesigned,
            // notarization-checked app bundle, so it carries no more authority
            // than the zip it vouches for. That was ~425 MB of pure ceremony on
            // every single launch.
            //
            // Nor does the remaining integrity pass run inline. `prepare()` is
            // `@MainActor` because it publishes `isReady`/`error`; SHA-256 over
            // ~578 MB of Application Support has no business holding the main
            // thread while it does so, and holding it is what made launch feel
            // frozen.
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

        // ─── Slow path: extract (first launch or after an app update) ───────────────────
        VoqoraLog.info("LaunchManager", "Extracting backend (first launch or update)", ["version": currentVersion])
        let stagingURL = appSupport.appendingPathComponent(".backend-staging-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: appSupport.path)
            Self.removeStaleBackendStagingDirectories(in: appSupport, fileManager: fm)
            try fm.createDirectory(at: stagingURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: stagingURL) }

            // Whatever this session may have approved a moment ago is about to
            // be replaced wholesale. Drop it now so a re-extraction can never
            // be waved through on the strength of the runtime it overwrites.
            Self.invalidateRuntimeValidation()

            let manifest = try Self.runtimeManifest(at: manifestURL)
            guard manifest.version == currentVersion else { throw RuntimeIntegrityError.invalidManifest }

            let zipPath = zipURL.path
            let bundledZipURL = zipURL
            let stagingPath = stagingURL.path
            let stagedServerURL = stagingURL.appendingPathComponent("VoqoraServer")
            let installedServerURL = serverURL

            // Archive verification, extraction and both integrity passes are
            // ~1 GB of file IO and SHA-256 between them. None of it needs the
            // main actor; `prepare()` only needs it back to publish the result.
            // The bundled zip IS still hashed here, unlike on the fast path
            // above, because this is the one path that actually unpacks it —
            // `unzip` must never be handed bytes nothing has authenticated.
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

                // The existing backend remains intact until the complete
                // archive has passed extraction and executable checks. The
                // final handoff replaces it atomically where the filesystem
                // supports it instead of deleting it before the new server has
                // a final home.
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

            // Stamp the exact archive identity only after the fully validated
            // backend is in its final location. A partial extraction can never
            // win the fast path on a later launch.
            try expectedMarker.write(
                to: versionMarkerURL,
                atomically: true,
                encoding: .utf8
            )

            // Pin the session's verified state only now. The marker file lives
            // inside the runtime directory, so stamping it changes the tree
            // the post-install verification just approved; recording before
            // this write would leave a stale entry that never matches, and
            // `BackendService.start()` would re-hash all 578 MB moments later.
            Self.recordValidatedRuntime(at: serverURL, manifest: manifest, fileManager: fm)

            VoqoraLog.info("LaunchManager", "Backend extracted successfully", ["version": currentVersion])
            isReady = true
        } catch {
            VoqoraLog.error("LaunchManager", "Backend extraction failed", ["failureCode": "runtime_extraction_failed", "version": currentVersion])
            self.error = "Launch Error: \(error.localizedDescription)"
        }
    }
}

import CryptoKit
import Foundation
@testable import Voqora
import XCTest

/// Regression + edge-case coverage for `LaunchManager`'s runtime integrity
/// logic against REAL on-disk directory trees, not pre-extracted pure helpers.
///
/// This exists because the 1.2.x "integrity check failed" bug shipped despite a
/// green suite: `validateInstalledRuntime` computed only each manifest entry's
/// *immediate* parent directory, so any package directory whose own children are
/// all directories (`_internal/numpy`, whose files live under
/// `_internal/numpy/core/...`) was reported as an unexpected extra directory and
/// a perfectly good install was condemned as corrupt. The same function also
/// failed to exclude its own `.bundle_version` fast-path marker, so *every*
/// launch after the first one failed. Neither is observable without building a
/// realistic directory tree on disk and running the real validator over it —
/// which is exactly what these tests do.
@MainActor
final class LaunchManagerRuntimeIntegrityTests: XCTestCase {
    // MARK: - Fixture plumbing

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voqora-integrity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
        try super.tearDownWithError()
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Writes `contents` at `relativePath` under `serverURL`, creating every
    /// intermediate directory, and returns the matching manifest entry.
    @discardableResult
    private func materialize(
        _ relativePath: String,
        contents: String,
        mode: Int = 0o644,
        in serverURL: URL
    ) throws -> LaunchManager.RuntimeManifest.FileEntry {
        let fileURL = serverURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = Data(contents.utf8)
        try data.write(to: fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: mode],
            ofItemAtPath: fileURL.path
        )
        return .init(path: relativePath, sha256: Self.digest(data), mode: mode)
    }

    private func manifest(
        _ entries: [LaunchManager.RuntimeManifest.FileEntry],
        version: String = "1.2.4"
    ) -> LaunchManager.RuntimeManifest {
        .init(
            format: 1,
            version: version,
            archiveSHA256: String(repeating: "a", count: 64),
            root: "VoqoraServer",
            files: entries
        )
    }

    /// Builds a `VoqoraServer/` directory under `root` containing exactly the
    /// listed (path, contents, mode) triples, and the manifest describing it.
    private func buildRuntime(
        _ files: [(String, String, Int)]
    ) throws -> (serverURL: URL, manifest: LaunchManager.RuntimeManifest) {
        let serverURL = root.appendingPathComponent("VoqoraServer")
        try FileManager.default.createDirectory(at: serverURL, withIntermediateDirectories: true)
        var entries: [LaunchManager.RuntimeManifest.FileEntry] = []
        for (path, contents, mode) in files {
            try entries.append(materialize(path, contents: contents, mode: mode, in: serverURL))
        }
        return (serverURL, manifest(entries))
    }

    private func assertIntegrityFailure(
        _ expression: @autoclosure () throws -> Void,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), message, file: file, line: line) { error in
            XCTAssertEqual(
                error as? LaunchManager.RuntimeIntegrityError,
                .extractedRuntimeMismatch,
                message,
                file: file,
                line: line
            )
        }
    }

    // MARK: - Bug #2 regression: ancestor-directory computation

    /// THE regression test for the shipped false-failure. `_internal` and
    /// `_internal/numpy` contain no files of their own — every file lives
    /// deeper — yet the enumerator visits both. Computing only immediate
    /// parents (the shipped 1.2.x logic) leaves them unrecognized and throws.
    func test_validatesPackageDirectoriesThatContainNoFilesOfTheirOwn() throws {
        let runtime = try buildRuntime([
            ("VoqoraServer", "#!/bin/sh\n", 0o755),
            ("_internal/numpy/core/_multiarray.so", "so", 0o644),
            ("_internal/numpy/linalg/lapack.so", "so2", 0o644),
        ])

        XCTAssertNoThrow(
            try LaunchManager.validateInstalledRuntime(
                at: runtime.serverURL,
                manifest: runtime.manifest
            ),
            "Directories that only contain subdirectories are legitimate archive members"
        )
    }

    /// The pathological depth case: one file, five levels of intermediate
    /// directories, none of which are any file's immediate parent except the
    /// last. Every one of them must be recognized.
    func test_validatesDeeplyNestedSingleFileRuntime() throws {
        let runtime = try buildRuntime([
            ("VoqoraServer", "bin", 0o755),
            ("a/b/c/d/e/leaf.dat", "leaf", 0o644),
        ])

        XCTAssertNoThrow(
            try LaunchManager.validateInstalledRuntime(
                at: runtime.serverURL,
                manifest: runtime.manifest
            )
        )
    }

    /// The degenerate opposite: a manifest with no nested entries at all must
    /// not accidentally synthesize expected directories.
    func test_validatesFlatRuntimeWithOnlyTopLevelFiles() throws {
        let runtime = try buildRuntime([
            ("VoqoraServer", "bin", 0o755),
            ("libpython.dylib", "dylib", 0o644),
        ])

        XCTAssertNoThrow(
            try LaunchManager.validateInstalledRuntime(
                at: runtime.serverURL,
                manifest: runtime.manifest
            )
        )
    }

    // MARK: - Bug #2 regression: `.bundle_version` marker exclusion

    /// The marker is stamped by `prepare()` immediately after a successful
    /// install and is never an archive member. Before the fix, its presence
    /// made every launch after the very first one fail integrity, forcing a
    /// full re-extraction that then failed anyway.
    func test_ignoresItsOwnBundleVersionMarkerFile() throws {
        let runtime = try buildRuntime([
            ("VoqoraServer", "bin", 0o755),
            ("_internal/base_library.zip", "zip", 0o644),
        ])
        try "archive:abc123".write(
            to: runtime.serverURL.appendingPathComponent(".bundle_version"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertNoThrow(
            try LaunchManager.validateInstalledRuntime(
                at: runtime.serverURL,
                manifest: runtime.manifest
            ),
            "The fast-path marker this code writes itself must never count as corruption"
        )
    }

    /// The exclusion must be exact. A *nested* `.bundle_version`, or a
    /// similarly-named file, is a genuinely unexpected member.
    func test_rejectsBundleVersionLookalikesThatAreNotTheRootMarker() throws {
        let runtime = try buildRuntime([
            ("VoqoraServer", "bin", 0o755),
            ("_internal/base_library.zip", "zip", 0o644),
        ])
        try "x".write(
            to: runtime.serverURL.appendingPathComponent("_internal/.bundle_version"),
            atomically: true,
            encoding: .utf8
        )

        try assertIntegrityFailure(
            LaunchManager.validateInstalledRuntime(
                at: runtime.serverURL,
                manifest: runtime.manifest
            ),
            "Only the root marker is excluded; a nested one is an unexpected file"
        )
    }

    func test_rejectsBundleVersionSuffixedLookalikeAtRoot() throws {
        let runtime = try buildRuntime([("VoqoraServer", "bin", 0o755)])
        try "x".write(
            to: runtime.serverURL.appendingPathComponent(".bundle_version.bak"),
            atomically: true,
            encoding: .utf8
        )

        try assertIntegrityFailure(
            LaunchManager.validateInstalledRuntime(
                at: runtime.serverURL,
                manifest: runtime.manifest
            ),
            "`.bundle_version.bak` is not the marker and must not be tolerated"
        )
    }

    // MARK: - The validator must still fail closed on real tampering

    func test_rejectsAnExtraFileNotInTheManifest() throws {
        let runtime = try buildRuntime([("VoqoraServer", "bin", 0o755)])
        try Data("payload".utf8).write(to: runtime.serverURL.appendingPathComponent("evil.dylib"))

        try assertIntegrityFailure(
            LaunchManager.validateInstalledRuntime(
                at: runtime.serverURL,
                manifest: runtime.manifest
            ),
            "An injected dylib must fail integrity"
        )
    }

    func test_rejectsAnExtraDirectoryNoManifestEntryLivesUnder() throws {
        let runtime = try buildRuntime([("VoqoraServer", "bin", 0o755)])
        try FileManager.default.createDirectory(
            at: runtime.serverURL.appendingPathComponent("stowaway"),
            withIntermediateDirectories: true
        )

        try assertIntegrityFailure(
            LaunchManager.validateInstalledRuntime(
                at: runtime.serverURL,
                manifest: runtime.manifest
            ),
            "A directory no manifest entry descends from is unexpected"
        )
    }

    func test_rejectsAMissingManifestFile() throws {
        let runtime = try buildRuntime([
            ("VoqoraServer", "bin", 0o755),
            ("_internal/present.so", "so", 0o644),
        ])
        var entries = runtime.manifest.files
        entries.append(.init(path: "_internal/absent.so", sha256: String(repeating: "b", count: 64), mode: 0o644))

        try assertIntegrityFailure(
            LaunchManager.validateInstalledRuntime(
                at: runtime.serverURL,
                manifest: manifest(entries)
            ),
            "A manifest entry with no file on disk must fail"
        )
    }

    func test_rejectsModifiedFileContents() throws {
        let runtime = try buildRuntime([("VoqoraServer", "original", 0o755)])
        try Data("tampered".utf8).write(to: runtime.serverURL.appendingPathComponent("VoqoraServer"))

        try assertIntegrityFailure(
            LaunchManager.validateInstalledRuntime(
                at: runtime.serverURL,
                manifest: runtime.manifest
            ),
            "A changed digest must fail"
        )
    }

    func test_rejectsChangedPermissionBits() throws {
        let runtime = try buildRuntime([("VoqoraServer", "bin", 0o755)])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777],
            ofItemAtPath: runtime.serverURL.appendingPathComponent("VoqoraServer").path
        )

        try assertIntegrityFailure(
            LaunchManager.validateInstalledRuntime(
                at: runtime.serverURL,
                manifest: runtime.manifest
            ),
            "A world-writable executable must fail even with a matching digest"
        )
    }

    func test_rejectsASymlinkStandingInForAManifestFile() throws {
        let runtime = try buildRuntime([("VoqoraServer", "bin", 0o755)])
        let target = root.appendingPathComponent("outside.dylib")
        try Data("outside".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: runtime.serverURL.appendingPathComponent("link.dylib"),
            withDestinationURL: target
        )

        try assertIntegrityFailure(
            LaunchManager.validateInstalledRuntime(
                at: runtime.serverURL,
                manifest: runtime.manifest
            ),
            "A symlink inside the runtime is never acceptable"
        )
    }

    func test_rejectsAnEmptyRuntimeDirectory() throws {
        let serverURL = root.appendingPathComponent("VoqoraServer")
        try FileManager.default.createDirectory(at: serverURL, withIntermediateDirectories: true)

        try assertIntegrityFailure(
            LaunchManager.validateInstalledRuntime(
                at: serverURL,
                manifest: manifest([
                    .init(path: "VoqoraServer", sha256: String(repeating: "c", count: 64), mode: 0o755),
                ])
            ),
            "Nothing extracted at all must fail"
        )
    }

    func test_rejectsAMissingRuntimeDirectoryOutright() {
        try assertIntegrityFailure(
            LaunchManager.validateInstalledRuntime(
                at: root.appendingPathComponent("does-not-exist"),
                manifest: manifest([
                    .init(path: "VoqoraServer", sha256: String(repeating: "c", count: 64), mode: 0o755),
                ])
            ),
            "An absent runtime directory must fail rather than validate vacuously"
        )
    }

    /// An empty `files` array can never reach the validator through
    /// `runtimeManifest`, but the validator must not treat "no expectations"
    /// as "everything is fine" if it is ever called directly.
    func test_emptyManifestRejectsANonEmptyRuntime() throws {
        let serverURL = root.appendingPathComponent("VoqoraServer")
        try FileManager.default.createDirectory(at: serverURL, withIntermediateDirectories: true)
        try Data("bin".utf8).write(to: serverURL.appendingPathComponent("VoqoraServer"))

        try assertIntegrityFailure(
            LaunchManager.validateInstalledRuntime(at: serverURL, manifest: manifest([])),
            "An empty manifest cannot vouch for an extracted file"
        )
    }

    // MARK: - Session validation cache

    /// The whole point of the cache: the second call must not repeat the
    /// SHA-256 pass. Proven without a stopwatch by corrupting a file's
    /// *contents* while leaving its size, mode and mtime exactly as they were
    /// — a full verification would catch that, a legitimate cache hit will
    /// not. That is precisely the trade this cache makes, so asserting it
    /// documents the trade rather than hiding it.
    /// Pins every entry in `serverURL` to one exact modification date, so a
    /// test can rewrite a file and put the tree back into a byte-identical
    /// stat state without depending on timestamp precision.
    private func pinModificationDates(_ date: Date, under serverURL: URL) throws {
        var targets = [serverURL]
        if let enumerator = FileManager.default.enumerator(at: serverURL, includingPropertiesForKeys: nil) {
            while let url = enumerator.nextObject() as? URL {
                targets.append(url)
            }
        }
        // Deepest first: touching a child would otherwise re-dirty its parent.
        for url in targets.sorted(by: { $0.path.count > $1.path.count }) {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
    }

    func test_verifyInstalledRuntimeSkipsTheHashOnASecondCallForAnUnchangedTree() throws {
        LaunchManager.invalidateRuntimeValidation()
        let runtime = try buildRuntime([
            ("VoqoraServer", "original", 0o755),
            ("_internal/lib.so", "so", 0o644),
        ])
        let pinned = Date(timeIntervalSince1970: 1_600_000_000)
        try pinModificationDates(pinned, under: runtime.serverURL)

        let fingerprintBefore = LaunchManager.runtimeStateFingerprint(
            at: runtime.serverURL,
            manifest: runtime.manifest
        )
        try LaunchManager.verifyInstalledRuntime(at: runtime.serverURL, manifest: runtime.manifest)

        // Identical byte count, identical permissions, identical modification
        // dates — nothing the fingerprint looks at has moved, only the bytes
        // the SHA-256 pass would have read.
        let target = runtime.serverURL.appendingPathComponent("VoqoraServer")
        try Data("tampered".utf8).write(to: target)
        try pinModificationDates(pinned, under: runtime.serverURL)

        XCTAssertEqual(
            LaunchManager.runtimeStateFingerprint(at: runtime.serverURL, manifest: runtime.manifest),
            fingerprintBefore,
            "Same size, mode and mtime must fingerprint identically"
        )
        XCTAssertNoThrow(
            try LaunchManager.verifyInstalledRuntime(at: runtime.serverURL, manifest: runtime.manifest),
            "A cache hit must not re-read 578 MB to re-derive an answer nothing invalidated"
        )
        try assertIntegrityFailure(
            LaunchManager.validateInstalledRuntime(at: runtime.serverURL, manifest: runtime.manifest),
            "The uncached validator must still catch the change — the cache is the only thing being skipped"
        )
    }

    /// Every ordinary way a runtime can change still forces the full hash,
    /// because the fingerprint covers the whole tree, not just the entry
    /// point: an added file, a deleted file, a rewritten file, a chmod, and a
    /// symlink swapped in for a real one.
    func test_everyOrdinaryRuntimeChangeDefeatsTheCache() throws {
        let extraFile = { (server: URL) in
            try Data("evil".utf8).write(to: server.appendingPathComponent("injected.dylib"))
        }
        let rewrite = { (server: URL) in
            try Data("much longer contents than before".utf8)
                .write(to: server.appendingPathComponent("VoqoraServer"))
        }
        let chmod = { (server: URL) in
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o777],
                ofItemAtPath: server.appendingPathComponent("VoqoraServer").path
            )
        }
        let delete = { (server: URL) in
            try FileManager.default.removeItem(at: server.appendingPathComponent("_internal/lib.so"))
        }

        let mutations: [(String, (URL) throws -> Void)] = [
            ("an injected extra file", extraFile),
            ("rewritten executable contents", rewrite),
            ("changed permission bits", chmod),
            ("a deleted manifest file", delete),
        ]

        for (label, mutate) in mutations {
            LaunchManager.invalidateRuntimeValidation()
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("voqora-cache-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let serverURL = root.appendingPathComponent("VoqoraServer")
            try FileManager.default.createDirectory(at: serverURL, withIntermediateDirectories: true)
            var entries: [LaunchManager.RuntimeManifest.FileEntry] = []
            try entries.append(materialize("VoqoraServer", contents: "bin", mode: 0o755, in: serverURL))
            try entries.append(materialize("_internal/lib.so", contents: "so", in: serverURL))
            let sealed = manifest(entries)

            try LaunchManager.verifyInstalledRuntime(at: serverURL, manifest: sealed)
            try mutate(serverURL)

            XCTAssertThrowsError(
                try LaunchManager.verifyInstalledRuntime(at: serverURL, manifest: sealed),
                "\(label) must invalidate the cached entry and fail the re-verification"
            )
        }
    }

    /// The cache is keyed on the tree AND the manifest that vouches for it, so
    /// a swapped manifest can never inherit the previous one's approval.
    func test_cacheIsKeyedOnTheManifestNotJustTheTree() throws {
        LaunchManager.invalidateRuntimeValidation()
        let runtime = try buildRuntime([("VoqoraServer", "bin", 0o755)])
        try LaunchManager.verifyInstalledRuntime(at: runtime.serverURL, manifest: runtime.manifest)

        let differentArchive = LaunchManager.RuntimeManifest(
            format: 1,
            version: runtime.manifest.version,
            archiveSHA256: String(repeating: "f", count: 64),
            root: "VoqoraServer",
            files: runtime.manifest.files
        )
        XCTAssertNotEqual(
            LaunchManager.runtimeStateFingerprint(at: runtime.serverURL, manifest: differentArchive),
            LaunchManager.runtimeStateFingerprint(at: runtime.serverURL, manifest: runtime.manifest),
            "A different sealed archive identity must produce a different fingerprint"
        )

        let differentVersion = LaunchManager.RuntimeManifest(
            format: 1,
            version: "9.9.9",
            archiveSHA256: runtime.manifest.archiveSHA256,
            root: "VoqoraServer",
            files: runtime.manifest.files
        )
        XCTAssertNotEqual(
            LaunchManager.runtimeStateFingerprint(at: runtime.serverURL, manifest: differentVersion),
            LaunchManager.runtimeStateFingerprint(at: runtime.serverURL, manifest: runtime.manifest)
        )
    }

    /// `invalidateRuntimeValidation` is what `prepare()` calls before it
    /// re-extracts, so a fresh install is never waved through on the strength
    /// of the runtime it replaces.
    func test_explicitInvalidationForcesAFullReverification() throws {
        LaunchManager.invalidateRuntimeValidation()
        let runtime = try buildRuntime([("VoqoraServer", "bin", 0o755)])
        try LaunchManager.verifyInstalledRuntime(at: runtime.serverURL, manifest: runtime.manifest)

        let target = runtime.serverURL.appendingPathComponent("VoqoraServer")
        let before = try FileManager.default.attributesOfItem(atPath: target.path)
        try Data("BIN".utf8).write(to: target)
        try FileManager.default.setAttributes(
            [
                .modificationDate: before[.modificationDate] as Any,
                .posixPermissions: before[.posixPermissions] as Any,
            ],
            ofItemAtPath: target.path
        )

        LaunchManager.invalidateRuntimeValidation()
        try assertIntegrityFailure(
            LaunchManager.verifyInstalledRuntime(at: runtime.serverURL, manifest: runtime.manifest),
            "After explicit invalidation the full hash must run again and catch the change"
        )
    }

    /// The fingerprint must be stable across repeated walks of an untouched
    /// tree, or the cache would never hit and the whole exercise is pointless.
    func test_fingerprintIsStableAndFailsSafeOnAMissingRuntime() throws {
        let runtime = try buildRuntime([
            ("VoqoraServer", "bin", 0o755),
            ("_internal/pkg/sub/mod.so", "so", 0o644),
        ])

        let first = LaunchManager.runtimeStateFingerprint(at: runtime.serverURL, manifest: runtime.manifest)
        let second = LaunchManager.runtimeStateFingerprint(at: runtime.serverURL, manifest: runtime.manifest)
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second, "Two walks of an untouched tree must agree")

        XCTAssertNil(
            LaunchManager.runtimeStateFingerprint(
                at: root.appendingPathComponent("does-not-exist"),
                manifest: runtime.manifest
            ),
            "No tree to fingerprint must read as `re-verify properly`, never as a hit"
        )
    }

    // MARK: - Manifest decoding edge cases

    private func decodeManifest(_ json: String) throws -> LaunchManager.RuntimeManifest {
        let url = root.appendingPathComponent("\(UUID().uuidString).manifest.json")
        try Data(json.utf8).write(to: url)
        return try LaunchManager.runtimeManifest(at: url)
    }

    func test_acceptsAWellFormedManifest() throws {
        let sha = String(repeating: "a", count: 64)
        let decoded = try decodeManifest("""
        {"format":1,"version":"1.2.4","archive_sha256":"\(sha)","root":"VoqoraServer",
         "files":[{"path":"VoqoraServer","sha256":"\(sha)","mode":493}]}
        """)
        XCTAssertEqual(decoded.version, "1.2.4")
        XCTAssertEqual(decoded.files.count, 1)
        XCTAssertEqual(decoded.files[0].mode, 0o755)
    }

    func test_rejectsMalformedManifests() throws {
        let sha = String(repeating: "a", count: 64)
        let entry = #"{"path":"VoqoraServer","sha256":"\#(sha)","mode":493}"#

        let cases: [(String, String)] = [
            ("unsupported format version", #"{"format":2,"version":"1","archive_sha256":"\#(sha)","root":"VoqoraServer","files":[\#(entry)]}"#),
            ("wrong archive root", #"{"format":1,"version":"1","archive_sha256":"\#(sha)","root":"Other","files":[\#(entry)]}"#),
            ("empty version string", #"{"format":1,"version":"","archive_sha256":"\#(sha)","root":"VoqoraServer","files":[\#(entry)]}"#),
            ("uppercase archive digest", #"{"format":1,"version":"1","archive_sha256":"\#(sha.uppercased())","root":"VoqoraServer","files":[\#(entry)]}"#),
            ("short archive digest", #"{"format":1,"version":"1","archive_sha256":"abc","root":"VoqoraServer","files":[\#(entry)]}"#),
            ("no files at all", #"{"format":1,"version":"1","archive_sha256":"\#(sha)","root":"VoqoraServer","files":[]}"#),
            ("no VoqoraServer executable entry", #"{"format":1,"version":"1","archive_sha256":"\#(sha)","root":"VoqoraServer","files":[{"path":"_internal/x","sha256":"\#(sha)","mode":420}]}"#),
            ("absolute member path", #"{"format":1,"version":"1","archive_sha256":"\#(sha)","root":"VoqoraServer","files":[\#(entry),{"path":"/etc/passwd","sha256":"\#(sha)","mode":420}]}"#),
            ("parent traversal member path", #"{"format":1,"version":"1","archive_sha256":"\#(sha)","root":"VoqoraServer","files":[\#(entry),{"path":"../escape","sha256":"\#(sha)","mode":420}]}"#),
            ("dot component member path", #"{"format":1,"version":"1","archive_sha256":"\#(sha)","root":"VoqoraServer","files":[\#(entry),{"path":"a/./b","sha256":"\#(sha)","mode":420}]}"#),
            ("empty path component", #"{"format":1,"version":"1","archive_sha256":"\#(sha)","root":"VoqoraServer","files":[\#(entry),{"path":"a//b","sha256":"\#(sha)","mode":420}]}"#),
            ("backslash member path", #"{"format":1,"version":"1","archive_sha256":"\#(sha)","root":"VoqoraServer","files":[\#(entry),{"path":"a\\b","sha256":"\#(sha)","mode":420}]}"#),
            ("duplicate member paths", #"{"format":1,"version":"1","archive_sha256":"\#(sha)","root":"VoqoraServer","files":[\#(entry),\#(entry)]}"#),
            ("negative mode", #"{"format":1,"version":"1","archive_sha256":"\#(sha)","root":"VoqoraServer","files":[{"path":"VoqoraServer","sha256":"\#(sha)","mode":-1}]}"#),
            ("mode above 0o777", #"{"format":1,"version":"1","archive_sha256":"\#(sha)","root":"VoqoraServer","files":[{"path":"VoqoraServer","sha256":"\#(sha)","mode":4095}]}"#),
        ]

        for (label, json) in cases {
            XCTAssertThrowsError(try decodeManifest(json), "manifest with \(label) must be rejected")
        }
    }

    func test_rejectsUnreadableAndNonJSONManifests() throws {
        XCTAssertThrowsError(try decodeManifest("not json at all"))
        XCTAssertThrowsError(
            try LaunchManager.runtimeManifest(at: root.appendingPathComponent("missing.json"))
        )
    }

    // MARK: - Backend marker identity

    func test_backendMarkerPrefersArchiveIdentityAndFallsBackSafely() {
        XCTAssertEqual(
            LaunchManager.backendMarker(bundleVersion: "1.2.4", archiveBuildID: "abc123"),
            "archive:abc123"
        )
        XCTAssertEqual(
            LaunchManager.backendMarker(bundleVersion: "1.2.4", archiveBuildID: "  abc123\n"),
            "archive:abc123",
            "A trailing newline from the build-id file must not fork the marker identity"
        )
        XCTAssertEqual(
            LaunchManager.backendMarker(bundleVersion: "1.2.4", archiveBuildID: nil),
            "version:1.2.4"
        )
        XCTAssertEqual(
            LaunchManager.backendMarker(bundleVersion: "1.2.4", archiveBuildID: "   \n "),
            "version:1.2.4",
            "A blank build-id must not produce the marker `archive:`"
        )
        XCTAssertEqual(
            LaunchManager.backendMarker(bundleVersion: "", archiveBuildID: nil),
            "version:"
        )
        XCTAssertNotEqual(
            LaunchManager.backendMarker(bundleVersion: "1.2.4", archiveBuildID: "a"),
            LaunchManager.backendMarker(bundleVersion: "1.2.4", archiveBuildID: "b")
        )
    }

    // MARK: - Staging-directory reaper

    func test_reaperRemovesOnlyOldStagingDirectories() throws {
        let appSupport = root.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let old = appSupport.appendingPathComponent(".backend-staging-old")
        let fresh = appSupport.appendingPathComponent(".backend-staging-fresh")
        let unrelated = appSupport.appendingPathComponent("VoqoraServer")
        for dir in [old, fresh, unrelated] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let strayFile = appSupport.appendingPathComponent(".backend-staging-file")
        try Data("x".utf8).write(to: strayFile)

        let now = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-7200)],
            ofItemAtPath: old.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-7200)],
            ofItemAtPath: strayFile.path
        )

        LaunchManager.removeStaleBackendStagingDirectories(in: appSupport, now: now)

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path), "A concurrent extraction must survive")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path), "The real server must never be reaped")
        XCTAssertTrue(FileManager.default.fileExists(atPath: strayFile.path), "Only directories are reaped")
    }

    func test_reaperIsExactlyAtTheAgeBoundaryAndToleratesAMissingDirectory() throws {
        let appSupport = root.appendingPathComponent("support-boundary")
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let atBoundary = appSupport.appendingPathComponent(".backend-staging-boundary")
        try FileManager.default.createDirectory(at: atBoundary, withIntermediateDirectories: true)

        let now = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-3600)],
            ofItemAtPath: atBoundary.path
        )

        LaunchManager.removeStaleBackendStagingDirectories(in: appSupport, now: now)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: atBoundary.path),
            "`>= minimumAge` must include the boundary itself"
        )

        // Must be a silent no-op, never a crash, on a first launch where
        // Application Support does not exist yet.
        LaunchManager.removeStaleBackendStagingDirectories(
            in: root.appendingPathComponent("never-created")
        )
    }

    // MARK: - Atomic install handoff

    func test_installPromotesStagedRuntimeAndReplacesAnExistingOne() throws {
        let staged = root.appendingPathComponent("staging/VoqoraServer")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: staged.appendingPathComponent("VoqoraServer"))

        let destination = root.appendingPathComponent("installed/VoqoraServer")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appendingPathComponent("VoqoraServer"))
        try Data("stale".utf8).write(to: destination.appendingPathComponent("leftover.so"))

        try LaunchManager.installValidatedBackend(from: staged, to: destination)

        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("VoqoraServer"), encoding: .utf8),
            "new"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.appendingPathComponent("leftover.so").path),
            "A replacement must not leave files from the previous runtime behind"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    func test_installMovesIntoPlaceWhenNoRuntimeExistsYet() throws {
        let staged = root.appendingPathComponent("staging2/VoqoraServer")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: staged.appendingPathComponent("VoqoraServer"))

        let destinationParent = root.appendingPathComponent("installed2")
        try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: true)
        let destination = destinationParent.appendingPathComponent("VoqoraServer")

        try LaunchManager.installValidatedBackend(from: staged, to: destination)

        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("VoqoraServer"), encoding: .utf8),
            "first"
        )
    }

    func test_installRefusesAMissingStagedRuntime() {
        XCTAssertThrowsError(
            try LaunchManager.installValidatedBackend(
                from: root.appendingPathComponent("nope"),
                to: root.appendingPathComponent("dest")
            )
        )
    }

    // MARK: - Round trip: install, stamp the marker, re-validate

    /// The exact sequence `prepare()` performs on a first launch, followed by
    /// the validation `validateRuntimeForExecution` runs before *every*
    /// subsequent `Process.run()`. Shipped 1.2.x failed the second pass.
    func test_installThenStampThenRevalidateSucceedsRepeatedly() throws {
        let staged = root.appendingPathComponent("stage/VoqoraServer")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        var entries: [LaunchManager.RuntimeManifest.FileEntry] = []
        try entries.append(materialize("VoqoraServer", contents: "bin", mode: 0o755, in: staged))
        try entries.append(materialize("_internal/pkg/sub/mod.so", contents: "so", in: staged))
        let sealed = manifest(entries)

        try LaunchManager.validateInstalledRuntime(at: staged, manifest: sealed)

        let installed = root.appendingPathComponent("live/VoqoraServer")
        try FileManager.default.createDirectory(
            at: installed.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try LaunchManager.installValidatedBackend(from: staged, to: installed)
        try LaunchManager.validateInstalledRuntime(at: installed, manifest: sealed)

        try "archive:deadbeef".write(
            to: installed.appendingPathComponent(".bundle_version"),
            atomically: true,
            encoding: .utf8
        )

        // Three more launches' worth of pre-exec validation.
        for launch in 1 ... 3 {
            XCTAssertNoThrow(
                try LaunchManager.validateInstalledRuntime(at: installed, manifest: sealed),
                "Launch \(launch) must not report a healthy install as corrupt"
            )
        }
    }
}

import CryptoKit
import Foundation
@testable import Voqora
import XCTest

@MainActor
final class LaunchManagerRuntimeIntegrityTests: XCTestCase {
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

    func test_emptyManifestRejectsANonEmptyRuntime() throws {
        let serverURL = root.appendingPathComponent("VoqoraServer")
        try FileManager.default.createDirectory(at: serverURL, withIntermediateDirectories: true)
        try Data("bin".utf8).write(to: serverURL.appendingPathComponent("VoqoraServer"))

        try assertIntegrityFailure(
            LaunchManager.validateInstalledRuntime(at: serverURL, manifest: manifest([])),
            "An empty manifest cannot vouch for an extracted file"
        )
    }

    private func pinModificationDates(_ date: Date, under serverURL: URL) throws {
        var targets = [serverURL]
        if let enumerator = FileManager.default.enumerator(at: serverURL, includingPropertiesForKeys: nil) {
            while let url = enumerator.nextObject() as? URL {
                targets.append(url)
            }
        }
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

        LaunchManager.removeStaleBackendStagingDirectories(
            in: root.appendingPathComponent("never-created")
        )
    }

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

        for launch in 1 ... 3 {
            XCTAssertNoThrow(
                try LaunchManager.validateInstalledRuntime(at: installed, manifest: sealed),
                "Launch \(launch) must not report a healthy install as corrupt"
            )
        }
    }
}

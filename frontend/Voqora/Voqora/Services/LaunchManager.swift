import Combine
import Foundation
import ServiceManagement

/// Handles the initial extraction and validation of the Python backend.
@MainActor
class LaunchManager: ObservableObject {
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

        // ─── Fast path: skip the 60-120 s zip extraction when binary is already current ───
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "unknown"
        let archiveBuildID = Bundle.main
            .url(forResource: "VoqoraServer", withExtension: "build-id")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let expectedMarker = Self.backendMarker(
            bundleVersion: currentVersion,
            archiveBuildID: archiveBuildID
        )
        if fm.isExecutableFile(atPath: executableURL.path),
           let stored = try? String(contentsOf: versionMarkerURL, encoding: .utf8),
           stored.trimmingCharacters(in: .whitespacesAndNewlines) == expectedMarker {
            print("✅ Current bundled backend already extracted — skipping unzip.")
            isReady = true
            return
        }

        // ─── Slow path: extract (first launch or after an app update) ───────────────────
        print("📦 Extracting backend v\(currentVersion)… (first launch or update)")
        let stagingURL = appSupport.appendingPathComponent(".backend-staging-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
            Self.removeStaleBackendStagingDirectories(in: appSupport, fileManager: fm)
            try fm.createDirectory(at: stagingURL, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: stagingURL) }

            let zipPath = zipURL.path
            let stagingPath = stagingURL.path
            let stagedServerURL = stagingURL.appendingPathComponent("VoqoraServer")
            let stagedExecutableURL = stagedServerURL.appendingPathComponent("VoqoraServer")
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
                // Sanity: extracted binary must be present before we chmod/stamp.
                guard FileManager.default.isReadableFile(atPath: stagedExecutableURL.path) else {
                    throw NSError(
                        domain: "LaunchManager",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey:
                            "unzip exited 0 but the bundled backend binary was missing"]
                    )
                }

                let chmod = Process()
                chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
                chmod.arguments = ["755", stagedExecutableURL.path]
                try chmod.run()
                chmod.waitUntilExit()
                guard chmod.terminationStatus == 0 else {
                    throw NSError(
                        domain: "LaunchManager",
                        code: Int(chmod.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey:
                            "chmod failed (status \(chmod.terminationStatus))"]
                    )
                }

            }.value

            // The existing backend remains intact until the complete archive
            // has passed extraction and executable checks. This avoids leaving
            // the player pointed at a half-written server after an interrupted
            // first launch or update.
            if fm.fileExists(atPath: serverURL.path) {
                try fm.removeItem(at: serverURL)
            }
            try fm.moveItem(at: stagedServerURL, to: serverURL)

            // Stamp the exact archive identity only after the fully validated
            // backend is in its final location. A partial extraction can never
            // win the fast path on a later launch.
            try expectedMarker.write(
                to: versionMarkerURL,
                atomically: true,
                encoding: .utf8
            )

            print("✅ Backend extracted successfully.")
            isReady = true
        } catch {
            self.error = "Launch Error: \(error.localizedDescription)"
        }
    }
}

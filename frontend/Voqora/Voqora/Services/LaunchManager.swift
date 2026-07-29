import Combine
import Foundation
import ServiceManagement

/// Handles the initial extraction and validation of the Python backend.
@MainActor
class LaunchManager: ObservableObject {
    @Published var isReady = false
    @Published var error: String? = nil

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
        let fm = FileManager.default
        let bundleID = Bundle.main.bundleIdentifier ?? "com.himudigonda.Voqora"
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID)

        let serverURL    = appSupport.appendingPathComponent("VoqoraServer")
        let executableURL = serverURL.appendingPathComponent("VoqoraServer")
        // Marker file: stores the bundle version that was last extracted.
        let versionMarkerURL = serverURL.appendingPathComponent(".bundle_version")

        guard let zipURL = Bundle.main.url(forResource: "VoqoraServer", withExtension: "zip") else {
            error = "Backend zip missing from bundle."
            return
        }

        // ─── Fast path: skip the 60-120 s zip extraction when binary is already current ───
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "unknown"
        if fm.isExecutableFile(atPath: executableURL.path),
           let stored = try? String(contentsOf: versionMarkerURL, encoding: .utf8),
           stored.trimmingCharacters(in: .whitespacesAndNewlines) == currentVersion {
            print("✅ Backend v\(currentVersion) already extracted — skipping unzip.")
            isReady = true
            return
        }

        // ─── Slow path: extract (first launch or after an app update) ───────────────────
        print("📦 Extracting backend v\(currentVersion)… (first launch or update)")
        do {
            // Remove stale server dir only; logs live in the parent appSupport dir.
            if fm.fileExists(atPath: serverURL.path) {
                try fm.removeItem(at: serverURL)
            }
            try fm.createDirectory(at: appSupport, withIntermediateDirectories: true)

            let zipPath = zipURL.path
            let appSupportPath = appSupport.path
            let execPath = executableURL.path
            let versionMarkerPath = versionMarkerURL.path
            try await Task.detached(priority: .userInitiated) {
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                unzip.arguments = ["-o", "-q", zipPath, "-d", appSupportPath]
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
                guard FileManager.default.isReadableFile(atPath: execPath) else {
                    throw NSError(
                        domain: "LaunchManager",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey:
                            "unzip exited 0 but binary missing at \(execPath)"]
                    )
                }

                let chmod = Process()
                chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
                chmod.arguments = ["755", execPath]
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

                // Stamp version ONLY after every prior step succeeded.
                // Previously the marker was written unconditionally; a partial
                // unzip would then take the fast path on next launch and hand
                // a non-executable binary to BackendService. See HARD-011.
                try currentVersion.write(
                    to: URL(fileURLWithPath: versionMarkerPath),
                    atomically: true,
                    encoding: .utf8
                )
            }.value

            print("✅ Backend extracted successfully.")
            isReady = true
        } catch {
            self.error = "Launch Error: \(error.localizedDescription)"
        }
    }
}

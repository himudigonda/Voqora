import AppKit
import Combine
import CryptoKit
import Foundation

/// Downloads the exact DMG published by the official Voqora GitHub release,
/// verifies its GitHub-published SHA-256 digest, then opens the disk image.
///
/// This is intentionally a *guided manual* update path. It never replaces the
/// running app, changes Gatekeeper settings, or runs a shell command. The user
/// still drags the verified app to Applications in Finder.
@MainActor
final class GuidedInstallerService: ObservableObject {
    enum State: Equatable {
        case idle
        case resolving
        case downloading
        case verifying
        case opened(version: String)
        case failed(message: String)

        var isBusy: Bool {
            switch self {
            case .resolving, .downloading, .verifying: true
            case .idle, .opened, .failed: false
            }
        }

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }

        var message: String? {
            switch self {
            case .idle: nil
            case .resolving: "Finding the latest verified Voqora installer…"
            case .downloading: "Downloading the Voqora installer…"
            case .verifying: "Verifying the downloaded installer…"
            case .opened(let version): "Voqora \(version) is open in Finder. Drag it to Applications, then open it there."
            case .failed(let message): message
            }
        }
    }

    struct ReleaseArtifact: Equatable {
        let version: String
        let name: String
        let downloadURL: URL
        let byteCount: Int64
        let sha256: String
    }

    enum InstallerError: LocalizedError, Equatable {
        case invalidRelease
        case unexpectedResponse
        case fileSizeMismatch
        case checksumMismatch
        case cannotOpenInstaller

        var errorDescription: String? {
            switch self {
            case .invalidRelease:
                "The latest GitHub release did not contain one verifiable Voqora DMG. You can download it from GitHub instead."
            case .unexpectedResponse:
                "GitHub did not return the installer correctly. Your current Voqora still works. Try again later."
            case .fileSizeMismatch, .checksumMismatch:
                "The downloaded installer did not match the official release, so Voqora did not open it. Please try again."
            case .cannotOpenInstaller:
                "The verified installer was saved, but Finder could not open it. Use the GitHub release page instead."
            }
        }
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let assets: [GitHubAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let browserDownloadURL: String
        let size: Int64
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case size
            case digest
        }
    }

    static let releasePageURL = URL(string: "https://github.com/himudigonda/Voqora/releases/latest")!
    private static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/himudigonda/Voqora/releases/latest")!

    @Published private(set) var state: State = .idle

    func downloadAndOpenLatest() {
        guard !state.isBusy else { return }
        state = .resolving
        Task { [weak self] in
            guard let self else { return }
            do {
                let artifact = try await Self.fetchLatestArtifact()
                self.state = .downloading
                MetricsService.shared.trackInstallerDownloadStarted()
                let downloaded = try await Self.download(artifact: artifact)
                self.state = .verifying
                try Self.verify(downloaded, matches: artifact)
                MetricsService.shared.trackInstallerDownloadVerified()
                let destination = try Self.persist(downloaded, named: artifact.name)
                guard NSWorkspace.shared.open(destination) else {
                    throw InstallerError.cannotOpenInstaller
                }
                MetricsService.shared.trackInstallerOpened()
                self.state = .opened(version: artifact.version)
            } catch is CancellationError {
                self.state = .idle
            } catch let error as InstallerError {
                MetricsService.shared.trackInstallerFailed()
                self.state = .failed(message: error.localizedDescription)
            } catch {
                MetricsService.shared.trackInstallerFailed()
                self.state = .failed(message: InstallerError.unexpectedResponse.localizedDescription)
            }
        }
    }

    func reset() {
        guard !state.isBusy else { return }
        state = .idle
    }

    static func artifact(from data: Data) throws -> ReleaseArtifact {
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let dmgAssets = release.assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        guard dmgAssets.count == 1,
              let asset = dmgAssets.first,
              let url = URL(string: asset.browserDownloadURL),
              url.scheme == "https",
              url.host?.lowercased() == "github.com",
              asset.size > 0,
              let digest = normalizedSHA256(asset.digest) else {
            throw InstallerError.invalidRelease
        }
        return ReleaseArtifact(
            version: release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
            name: asset.name,
            downloadURL: url,
            byteCount: asset.size,
            sha256: digest
        )
    }

    private static func fetchLatestArtifact() async throws -> ReleaseArtifact {
        var request = URLRequest(url: latestReleaseAPIURL)
        request.timeoutInterval = 12
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Voqora", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw InstallerError.unexpectedResponse
        }
        return try artifact(from: data)
    }

    private static func download(artifact: ReleaseArtifact) async throws -> URL {
        var request = URLRequest(url: artifact.downloadURL)
        request.timeoutInterval = 120
        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw InstallerError.unexpectedResponse
        }
        return temporaryURL
    }

    static func verify(_ fileURL: URL, matches artifact: ReleaseArtifact) throws {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        guard Int64(values.fileSize ?? -1) == artifact.byteCount else {
            throw InstallerError.fileSizeMismatch
        }
        guard try sha256Hex(of: fileURL) == artifact.sha256 else {
            throw InstallerError.checksumMismatch
        }
    }

    private static func persist(_ temporaryURL: URL, named name: String) throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = caches.appendingPathComponent("Voqora/Installers", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDestination = destination
        try mutableDestination.setResourceValues(values)
        return destination
    }

    private static func normalizedSHA256(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let prefix = "sha256:"
        let value = raw.lowercased()
        guard value.hasPrefix(prefix) else { return nil }
        let hash = String(value.dropFirst(prefix.count))
        guard hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return hash
    }

    private static func sha256Hex(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

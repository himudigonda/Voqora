import Foundation
import UniformTypeIdentifiers

/// Pure file-drop handling for `AudiobookLibraryView`'s drop target (the v1.1 design notes
/// Sprint 7, T7.9/E10).
///
/// `handleDrop` previously only ever processed `providers.first` — dragging
/// multiple files onto the library (an entirely normal Finder gesture)
/// silently dropped everything after the first. Extracted into its own type,
/// decoupled from `@EnvironmentObject`-dependent View state, so "process
/// every provider" is directly unit-testable — mirrors the
/// `AudiobookPlayerLayout`/`MainDashboardLayout` precedent (Sprint 6) of
/// pulling pure logic out of Views that can't otherwise be driven in
/// isolation.
enum AudiobookDropHandler {
    /// File extensions accepted for audiobook upload.
    static let allowedExtensions: Set<String> = ["pdf", "txt", "docx", "md"]

    /// Loads the file URL for every provider in `providers` (not just the
    /// first), copies each into a security-scope-safe temp location, and
    /// reports the result via `onURL`/`onError`. Providers whose extension
    /// isn't in `allowedExtensions` are silently skipped, matching the drop's
    /// pre-existing behavior. `loadItem`'s completion handler runs off the
    /// main thread — callers that touch `@MainActor` state must hop
    /// themselves, same as before this was extracted. Returns `false`
    /// (declining the drop) only when `providers` is empty.
    @discardableResult
    static func handle(
        providers: [NSItemProvider],
        onURL: @escaping (URL) -> Void,
        onError: @escaping (URL, Error) -> Void
    ) -> Bool {
        guard !providers.isEmpty else { return false }
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                }
                guard let url, allowedExtensions.contains(url.pathExtension.lowercased()) else { return }

                // Acquire security scope, copy to temp, release scope.
                let scoped = url.startAccessingSecurityScopedResource()
                let tmpURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(url.lastPathComponent)
                do {
                    let data = try Data(contentsOf: url)
                    if scoped {
                        url.stopAccessingSecurityScopedResource()
                    }
                    try data.write(to: tmpURL)
                    onURL(tmpURL)
                } catch {
                    if scoped {
                        url.stopAccessingSecurityScopedResource()
                    }
                    onError(url, error)
                }
            }
        }
        return true
    }
}

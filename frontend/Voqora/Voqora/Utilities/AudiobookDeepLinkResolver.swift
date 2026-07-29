import Foundation

/// Pure deep-link resolution logic for `AudiobookLibraryView` (the v1.1 design notes
/// Sprint 7, T7.12/E13).
///
/// The view's `.onChange(of: bookVM.pendingDeepLink)` previously cleared
/// `pendingDeepLink` unconditionally, even when the target book wasn't found
/// in `books` yet (e.g. a deep link arriving before the library has finished
/// its first load) — losing the deep link permanently instead of retrying
/// once the book appears. Extracted into its own type, decoupled from
/// `@EnvironmentObject`/`@State`-dependent View state, so the resolve-or-stay-
/// armed decision is directly unit-testable — mirrors the
/// `AudiobookPlayerLayout`/`MainDashboardLayout` precedent (Sprint 6).
enum AudiobookDeepLinkResolver {
    /// Given a pending deep-link book id, the current library list, and the
    /// current nav path, decides whether to push a new route and whether the
    /// pending deep link should be cleared.
    ///
    /// `clear` is `false` when the target book isn't in `books` yet (E13) —
    /// the caller must leave `pendingDeepLink` armed and call this again the
    /// next time `books` updates, rather than dropping the deep link after
    /// one failed lookup.
    static func resolve(
        pendingDeepLink: String?,
        books: [Audiobook],
        currentPath: [AudiobookRoute]
    ) -> (route: AudiobookRoute?, clear: Bool) {
        guard let bookID = pendingDeepLink else { return (nil, false) }
        guard let book = books.first(where: { $0.bookID == bookID }) else {
            // Not found yet — leave pendingDeepLink armed, retry on the next
            // books update instead of losing the deep link (E13).
            return (nil, false)
        }
        let route = AudiobookRoute.player(book.bookID)
        let shouldPush = !currentPath.contains(route)
        return (shouldPush ? route : nil, true)
    }
}

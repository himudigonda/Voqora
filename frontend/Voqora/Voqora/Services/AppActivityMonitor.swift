import AppKit
import Combine

/// Tracks whether Voqora is the frontmost app, so background loops (health
/// heartbeat, audiobook library poll) can widen their interval instead of
/// running at full cadence indefinitely while the user isn't looking.
///
/// `NSApplication` activation state (not `scenePhase` or window occlusion) is
/// the right signal here: Voqora is a `MenuBarExtra` app whose window can be
/// closed while the app keeps running, and `DashboardViewModel`/
/// `AudiobookViewModel` are plain `ObservableObject`s, not Views, so they
/// can't read `@Environment(\.scenePhase)` directly.
@MainActor
final class AppActivityMonitor: ObservableObject {
    static let shared = AppActivityMonitor()

    @Published private(set) var isBackgrounded: Bool = false

    private var cancellables = Set<AnyCancellable>()

    init() {
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.isBackgrounded = true }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.isBackgrounded = false }
            .store(in: &cancellables)
    }
}

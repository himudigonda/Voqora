import AppKit
import Combine

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

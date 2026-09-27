import AppKit
import SwiftUI

struct ScrollInteractionMonitor: NSViewRepresentable {
    let onUserScroll: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.onUserScroll = onUserScroll
        context.coordinator.start()
        return view
    }

    func updateNSView(_: NSView, context: Context) {
        context.coordinator.onUserScroll = onUserScroll
    }

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var onUserScroll: () -> Void = {}
        private var monitor: Any?
        private var liveScrollObserver: NSObjectProtocol?

        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event)
                return event
            }
            liveScrollObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let scrollView = note.object as? NSScrollView,
                          scrollView === self.view?.enclosingScrollView
                    else { return }
                    self.onUserScroll()
                }
            }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            if let liveScrollObserver {
                NotificationCenter.default.removeObserver(liveScrollObserver)
            }
            monitor = nil
            liveScrollObserver = nil
        }

        private func handle(_ event: NSEvent) {
            guard let scrollView = view?.enclosingScrollView,
                  event.window === scrollView.window,
                  event.scrollingDeltaY != 0 || event.phase != [] || event.momentumPhase != []
            else { return }
            let location = scrollView.convert(event.locationInWindow, from: nil)
            if scrollView.bounds.contains(location) {
                onUserScroll()
            }
        }
    }
}

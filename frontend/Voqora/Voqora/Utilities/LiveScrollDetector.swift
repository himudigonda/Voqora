import AppKit
import SwiftUI

/// Bridges AppKit's `NSScrollView.willStartLiveScrollNotification` into a
/// SwiftUI callback — fired only for real interactive scrolling (trackpad,
/// scroll wheel, scrollbar drag), never for a programmatic
/// `ScrollViewReader.scrollTo(...)`. T-13's original fix used only a SwiftUI
/// `DragGesture` to detect "the user is manually scrolling," but trackpad
/// and scroll-wheel input — how virtually all Mac users actually scroll —
/// goes through AppKit's NSScrollView entirely outside SwiftUI's gesture
/// system, so that mechanism functionally never fired for a real user; the
/// auto-scroll kept yanking the view back exactly as before the fix. This
/// is the macOS-14-compatible way to see it (`.onScrollGeometryChange`
/// needs a 15.0 deployment target, which this app doesn't have).
struct LiveScrollDetector: NSViewRepresentable {
    let onLiveScroll: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // enclosingScrollView is only resolvable once this view has actually
        // been inserted into the real view hierarchy, which hasn't happened
        // yet at the point makeNSView returns.
        DispatchQueue.main.async {
            context.coordinator.attach(to: view)
        }
        return view
    }

    // Retry attachment on every update. The single deferred attempt above is
    // best-effort: if the view is not yet inside its NSScrollView on that one
    // runloop turn, `attach` returns without installing the observer, and with
    // an empty updateNSView it never got a second chance — silently, for the
    // life of the view. The failure is invisible but consequential: with no
    // observer, `userScrolledAt` is never set, `shouldAutoScroll` always
    // returns true, and auto-scroll yanks the transcript away from a reader
    // who has deliberately scrolled elsewhere — exactly the bug this type was
    // written to fix. `attach` is idempotent (it no-ops once `observer` is
    // non-nil), so retrying costs nothing.
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(to: nsView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onLiveScroll: onLiveScroll)
    }

    final class Coordinator {
        private let onLiveScroll: () -> Void
        private var observer: NSObjectProtocol?

        init(onLiveScroll: @escaping () -> Void) {
            self.onLiveScroll = onLiveScroll
        }

        func attach(to view: NSView) {
            guard observer == nil, let scrollView = view.enclosingScrollView else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                self?.onLiveScroll()
            }
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}

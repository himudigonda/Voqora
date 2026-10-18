import AppKit
import SwiftUI

enum DictationHUDLayout {
    static let cardWidth: CGFloat = 420
    static let shadowInset: CGFloat = 28
    static let topMargin: CGFloat = 8
    static let panelSize = NSSize(width: cardWidth + shadowInset * 2, height: 200)
}

final class DictationHUDPresenter: DictationHUDPresenting {
    private let rootView: AnyView
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    init(rootView: some View) {
        self.rootView = AnyView(rootView)
    }

    func show() {
        hideTask?.cancel()
        hideTask = nil
        let hudPanel = panel ?? makePanel()
        panel = hudPanel
        position(hudPanel)
        hudPanel.orderFrontRegardless()
    }

    func hide(after delay: TimeInterval) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let hudPanel = NSPanel(
            contentRect: NSRect(origin: .zero, size: DictationHUDLayout.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        hudPanel.isFloatingPanel = true
        hudPanel.level = .statusBar
        hudPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hudPanel.hidesOnDeactivate = false
        hudPanel.becomesKeyOnlyIfNeeded = true
        hudPanel.isMovable = false
        hudPanel.isOpaque = false
        hudPanel.backgroundColor = .clear
        hudPanel.hasShadow = false
        hudPanel.isReleasedWhenClosed = false
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: DictationHUDLayout.panelSize)
        hudPanel.contentView = hostingView
        return hudPanel
    }

    private func position(_ hudPanel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = DictationHUDLayout.panelSize
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - DictationHUDLayout.topMargin
        )
        hudPanel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

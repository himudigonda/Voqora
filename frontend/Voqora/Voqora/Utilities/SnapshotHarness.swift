#if DEBUG
    import AppKit
    import Combine
    import SwiftUI

    @MainActor
    final class SnapshotOnboarding: ObservableObject {
        static let shared = SnapshotOnboarding()
        @Published var step: Int?
    }

    @MainActor
    enum SnapshotHarness {
        private static let onboardingPrefix = "onboarding."

        private static let directoryKey = "VOQORA_SNAPSHOT_DIR"
        private static let tabsKey = "VOQORA_SNAPSHOT_TABS"
        private static let windowSize = NSSize(width: 1280, height: 820)
        private static let themes = ["light", "dark"]
        private static let maxPagesPerScreen = 12
        private static var started = false

        private static var environment: [String: String] {
            ProcessInfo.processInfo.environment
        }

        static var isActive: Bool {
            guard let path = environment[directoryKey] else { return false }
            return !path.isEmpty
        }

        private static var allTabs: [String] {
            TabKey.all
        }

        private static var requestedTabs: [String] {
            guard let list = environment[tabsKey], !list.isEmpty else { return allTabs }
            let wanted = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return wanted.filter { !$0.isEmpty }
        }

        static func runIfRequested(vm: DashboardViewModel, launchManager: LaunchManager) {
            guard isActive, !started, let path = environment[directoryKey] else { return }
            started = true
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            Task { @MainActor in
                await run(vm: vm, launchManager: launchManager, directory: directory)
            }
        }

        private static func run(vm: DashboardViewModel, launchManager: LaunchManager, directory: URL) async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var report: [String] = []

            await waitUntil(timeout: 60) { launchManager.isReady }
            report.append("launchReady=\(launchManager.isReady)")
            await waitUntil(timeout: 30) { vm.isBackendOnline }
            report.append("backendOnline=\(vm.isBackendOnline)")
            await sleep(1.5)

            let originalTheme = vm.appTheme
            let originalTab = vm.selectedTab

            if let window = snapshotWindow() {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                var frame = window.frame
                frame.origin.y += frame.height - windowSize.height
                frame.size = windowSize
                window.setFrame(frame, display: true)
                await sleep(0.8)
            } else {
                report.append("error=no window")
            }

            for theme in themes {
                vm.appTheme = theme
                await sleep(0.8)
                for tab in requestedTabs {
                    if tab.hasPrefix(onboardingPrefix) {
                        SnapshotOnboarding.shared.step = Int(tab.dropFirst(onboardingPrefix.count))
                    } else {
                        SnapshotOnboarding.shared.step = nil
                        vm.selectedTab = tab
                    }
                    await waitForTitle(VoqoraWindow.title(forTab: tab), in: snapshotWindow)
                    await settle(snapshotWindow())
                    guard let window = snapshotWindow() else {
                        report.append("fail \(theme)-\(tab): no window")
                        continue
                    }
                    let written = await captureScreen(window: window, name: "\(theme)-\(tab)", directory: directory)
                    report.append(written.isEmpty ? "fail \(theme)-\(tab)" : "ok \(written.joined(separator: ","))")
                }
            }

            SnapshotOnboarding.shared.step = nil
            vm.appTheme = originalTheme
            vm.selectedTab = originalTab
            await sleep(0.5)

            let summary = report.joined(separator: "\n") + "\n"
            try? summary.write(to: directory.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)

            NSApp.terminate(nil)
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            exit(0)
        }

        private static func snapshotWindow() -> NSWindow? {
            let candidates = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain && $0.contentView != nil }
            return candidates.first { $0.identifier?.rawValue.hasPrefix("dashboard") == true } ?? candidates.first
        }

        private static func waitForTitle(_ title: String, in window: () -> NSWindow?) async {
            await waitUntil(timeout: 2) { window()?.title == title }
        }

        private static func settle(_ window: NSWindow?) async {
            await sleep(0.6)
            window?.contentView?.layoutSubtreeIfNeeded()
            window?.displayIfNeeded()
            CATransaction.flush()
            await sleep(0.6)
        }

        private static func captureScreen(window: NSWindow, name: String, directory: URL) async -> [String] {
            var written: [String] = []
            let scroller = primaryScrollView(in: window)
            let originalOffset = scroller?.contentView.bounds.origin
            let pageHeight = scroller?.contentView.bounds.height ?? 0
            let documentHeight = scroller?.documentView?.bounds.height ?? 0
            let pageCount = pageHeight > 0
                ? min(maxPagesPerScreen, max(1, Int((documentHeight / pageHeight).rounded(.up))))
                : 1

            for page in 0 ..< pageCount {
                if page > 0, let scroller {
                    scroll(scroller, toPage: page, pageHeight: pageHeight)
                    await sleep(0.5)
                }
                let fileName = page == 0 ? "\(name).png" : "\(name)-p\(page + 1).png"
                if writePNG(of: window, to: directory.appendingPathComponent(fileName)) {
                    written.append(fileName)
                }
            }

            if let scroller, let originalOffset {
                scroller.contentView.scroll(to: originalOffset)
                scroller.reflectScrolledClipView(scroller.contentView)
            }
            return written
        }

        private static func primaryScrollView(in window: NSWindow) -> NSScrollView? {
            guard let root = window.contentView else { return nil }
            return scrollViews(in: root)
                .filter { $0.frame.width > 500 && ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height + 1 }
                .max { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) }
        }

        private static func scrollViews(in view: NSView) -> [NSScrollView] {
            var found: [NSScrollView] = []
            if let scroll = view as? NSScrollView {
                found.append(scroll)
            }
            for child in view.subviews {
                found.append(contentsOf: scrollViews(in: child))
            }
            return found
        }

        private static func scroll(_ scroller: NSScrollView, toPage page: Int, pageHeight: CGFloat) {
            guard let document = scroller.documentView else { return }
            let maxOffset = max(0, document.bounds.height - pageHeight)
            let offset = min(maxOffset, CGFloat(page) * pageHeight * 0.9)
            let y = document.isFlipped ? offset : document.bounds.height - pageHeight - offset
            scroller.contentView.scroll(to: NSPoint(x: scroller.contentView.bounds.origin.x, y: y))
            scroller.reflectScrolledClipView(scroller.contentView)
        }

        private static func writePNG(of window: NSWindow, to url: URL) -> Bool {
            if let data = compositedPNG(of: window) {
                return (try? data.write(to: url, options: .atomic)) != nil
            }
            return writeCachedPNG(of: window, to: url)
        }

        private static func compositedPNG(of window: NSWindow) -> Data? {
            guard window.windowNumber > 0,
                  let image = CGWindowListCreateImage(
                      .null,
                      .optionIncludingWindow,
                      CGWindowID(window.windowNumber),
                      [.boundsIgnoreFraming, .nominalResolution]
                  )
            else { return nil }
            return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        }

        private static func writeCachedPNG(of window: NSWindow, to url: URL) -> Bool {
            guard let view = window.contentView else { return false }
            let bounds = view.bounds
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(bounds.width),
                pixelsHigh: Int(bounds.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { return false }
            rep.size = bounds.size
            view.cacheDisplay(in: bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { return false }
            return (try? data.write(to: url, options: .atomic)) != nil
        }

        private static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition(), Date() < deadline {
                await sleep(0.25)
            }
        }

        private static func sleep(_ seconds: TimeInterval) async {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }
#endif

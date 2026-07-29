import Combine
import SwiftUI

class Downloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var progress: Double = 0
    @Published var isDownloading = false
    @Published var isFinished = false
    @Published var downloadedURL: URL?

    private var downloadTask: URLSessionDownloadTask?

    func download(url: URL) {
        isDownloading = true
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        downloadTask = session.downloadTask(with: url)
        downloadTask?.resume()
    }

    func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            DispatchQueue.main.async {
                self.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            }
        }
    }

    func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let fileManager = FileManager.default
        let destinationURL = fileManager.temporaryDirectory.appendingPathComponent(downloadTask.originalRequest?.url?.lastPathComponent ?? "update.dmg")

        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: location, to: destinationURL)

            DispatchQueue.main.async {
                self.isDownloading = false
                self.downloadedURL = destinationURL
                self.isFinished = true
            }
        } catch {
            print("❌ Downloader: Failed to save DMG: \(error)")
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            print("❌ Downloader: task completed with error: \(error)")
            DispatchQueue.main.async {
                self.isDownloading = false
            }
        }
    }
}

struct UpdateView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.dismiss) var dismiss

    @StateObject private var downloader = Downloader()
    @State private var errorMessage: String?
    @State private var isInstalling = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                Image(systemName: isInstalling ? "cog.circle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.cyan.gradient)
                    .symbolEffect(.bounce, value: downloader.isDownloading)
                    .rotationEffect(.degrees(isInstalling ? 360 : 0))
                    .animation(isInstalling ? .linear(duration: 2).repeatForever(autoreverses: false) : .default, value: isInstalling)

                Text(isInstalling ? "Installing Update" : "Update Available")
                    .font(vm.appFont(size: 24, weight: .bold))

                if let latest = vm.availableUpdate {
                    Text(latest.name)
                        .font(vm.appFont(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 40)
            .padding(.bottom, 24)

            // Release Notes (Aggregated)
            VStack(alignment: .leading, spacing: 12) {
                Text("What's New")
                    .font(vm.appFont(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(vm.allRelevantReleases, id: \.tagName) { release in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(release.tagName)
                                        .font(vm.appFont(size: 12, weight: .black))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(.cyan.opacity(0.2))
                                        .foregroundStyle(.cyan)
                                        .clipShape(Capsule())

                                    Text(release.name)
                                        .font(vm.appFont(size: 14, weight: .bold))
                                }

                                MarkdownRenderView(markdown: release.body, vm: vm)
                            }

                            if release.tagName != vm.allRelevantReleases.last?.tagName {
                                Divider().opacity(0.1)
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(.white.opacity(0.1), lineWidth: 1)
                    )
                }
            }
            .padding(.horizontal, 40)

            // Footer (Controls)
            VStack(spacing: 24) {
                if downloader.isDownloading {
                    VStack(spacing: 12) {
                        ProgressView(value: downloader.progress)
                            .tint(.cyan)
                            .scaleEffect(x: 1, y: 0.5)

                        Text("Downloading update... \(Int(downloader.progress * 100))%")
                            .font(vm.appFont(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                } else if isInstalling {
                    Text("Replacing application files...")
                        .font(vm.appFont(size: 12, weight: .medium))
                        .foregroundStyle(.cyan)
                } else if let error = errorMessage {
                    Text(error)
                        .font(vm.appFont(size: 12))
                        .foregroundStyle(.red)
                }

                HStack(spacing: 16) {
                    Button(downloader.isFinished ? "Close" : "Later") {
                        dismiss()
                    }
                    .buttonStyle(.plain)
                    .font(vm.appFont(size: 14, weight: .medium))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .disabled(isInstalling)

                    if downloader.isFinished {
                        Button {
                            autoInstall()
                        } label: {
                            Text("Install & Relaunch")
                                .font(vm.appFont(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 32)
                                .padding(.vertical, 12)
                                .background(Color.cyan)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(isInstalling)
                    } else {
                        Button {
                            startDownload()
                        } label: {
                            Text(downloader.isDownloading ? "Downloading..." : "Update Now")
                                .font(vm.appFont(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 32)
                                .padding(.vertical, 12)
                                .background(downloader.isDownloading ? Color.gray : Color.cyan)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(downloader.isDownloading)
                    }
                }
            }
            .padding(40)
        }
        .frame(width: 550, height: 750)
        .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow).ignoresSafeArea())
    }

    private func startDownload() {
        guard let latest = vm.availableUpdate,
              let asset = latest.assets.first(where: { $0.name.contains(".dmg") })
        else {
            errorMessage = "No DMG found in release assets."
            return
        }

        errorMessage = nil
        downloader.download(url: asset.browserDownloadUrl)
    }

    private func autoInstall() {
        guard let dmgURL = downloader.downloadedURL else { return }
        isInstalling = true

        Task {
            let script = """
            try
                set dmgPath to \"\(dmgURL.path)\"
                set mountPoint to \"/tmp/VoqoraUpdate\"

                -- Create mount point
                do shell script \"mkdir -p \" & mountPoint

                -- Mount DMG
                do shell script \"hdiutil attach \" & quoted form of dmgPath & \" -mountpoint \" & quoted form of mountPoint & \" -nobrowse -quiet\"

                -- Copy App using elevated privileges
                do shell script \"cp -R \" & quoted form of (mountPoint & \"/Voqora.app\") & \" /Applications/\" with administrator privileges

                -- Unmount
                do shell script \"hdiutil detach \" & quoted form of mountPoint & \" -quiet\"

                -- Cleanup
                do shell script \"rm -rf \" & quoted form of mountPoint

                return \"success\"
            on error errMsg
                return errMsg
            end try
            """

            var error: NSDictionary?
            if let scriptObject = NSAppleScript(source: script) {
                let result = scriptObject.executeAndReturnError(&error)
                if result.stringValue == "success" {
                    // Relaunch
                    let path = "/Applications/Voqora.app"
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    exit(0)
                } else {
                    isInstalling = false
                    errorMessage = "Installation failed: \(error?.description ?? result.stringValue ?? "Unknown error")"
                }
            }
        }
    }
}

/// Custom Markdown Parser View
struct MarkdownRenderView: View {
    let markdown: String
    let vm: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) { // Slightly increased spacing
            let lines = markdown.components(separatedBy: .newlines)
            let parsedItems = parseMarkdownLines(lines)

            ForEach(parsedItems.indices, id: \.self) { index in
                let item = parsedItems[index]
                renderItem(item)
            }
        }
    }

    @ViewBuilder
    private func renderItem(_ item: ParsedItem) -> some View {
        switch item.type {
        case .header2:
            Text(LocalizedStringKey(item.content))
                .font(vm.appFont(size: 16, weight: .black))
                .foregroundStyle(.cyan)
                .padding(.top, 10)
        case .header3:
            Text(LocalizedStringKey(item.content))
                .font(vm.appFont(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .padding(.top, 8)
        case .bullet:
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                    .font(vm.appFont(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)
                Text(LocalizedStringKey(item.content))
                    .font(vm.appFont(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
            }
        case .code:
            Text(item.content)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.3))
                .cornerRadius(8)
                .foregroundStyle(.cyan.opacity(0.9))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 1))
        case .text:
            if !item.content.isEmpty {
                Text(LocalizedStringKey(item.content))
                    .font(vm.appFont(size: 13))
                    .foregroundStyle(.secondary.opacity(0.8))
                    .lineSpacing(4)
            }
        }
    }

    private enum ItemType {
        case header2, header3, bullet, code, text
    }

    private struct ParsedItem {
        let type: ItemType
        let content: String
    }

    private func parseMarkdownLines(_ lines: [String]) -> [ParsedItem] {
        var items: [ParsedItem] = []
        var inCodeBlock = false
        var currentCode = ""

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    // Close block
                    items.append(ParsedItem(type: .code, content: currentCode.trimmingCharacters(in: .whitespacesAndNewlines)))
                    currentCode = ""
                }
                inCodeBlock.toggle()
                continue
            }

            if inCodeBlock {
                currentCode += line + "\n"
                continue
            }

            if trimmed.hasPrefix("### ") {
                items.append(ParsedItem(type: .header3, content: trimmed.replacingOccurrences(of: "### ", with: "")))
            } else if trimmed.hasPrefix("## ") {
                items.append(ParsedItem(type: .header2, content: trimmed.replacingOccurrences(of: "## ", with: "")))
            } else if trimmed.hasPrefix("- ") {
                items.append(ParsedItem(type: .bullet, content: trimmed.replacingOccurrences(of: "- ", with: "")))
            } else if trimmed.hasPrefix("* ") {
                items.append(ParsedItem(type: .bullet, content: trimmed.replacingOccurrences(of: "* ", with: "")))
            } else if !trimmed.isEmpty {
                items.append(ParsedItem(type: .text, content: trimmed))
            }
        }

        // Catch edge case: unclosed block
        if inCodeBlock, !currentCode.isEmpty {
            items.append(ParsedItem(type: .code, content: currentCode.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        return items
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context _: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

import AppKit
import SwiftUI

enum ClipboardWriter {
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    static func copy(_ text: String, concealed: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if concealed {
            pasteboard.setData(Data(), forType: concealedType)
        }
    }
}

struct CopyButton: View {
    let accessibilityTitle: String
    let text: () -> String
    var concealed = true

    @State private var copied = false

    var body: some View {
        AssistChip(title: copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
            ClipboardWriter.copy(text(), concealed: concealed)
            copied = true
        }
        .accessibilityLabel(copied ? "\(accessibilityTitle) copied" : "Copy \(accessibilityTitle)")
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}

struct CopyableSnippet: View {
    let title: String
    let caption: String
    let displayText: String
    let copyText: String

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: Theme.Space.item) {
                Text(title)
                    .font(vm.font(.titleSmall))
                    .foregroundStyle(theme.onSurface)
                Spacer(minLength: 0)
                CopyButton(accessibilityTitle: title, text: { copyText })
            }
            Text(caption)
                .font(vm.font(.bodySmall))
                .foregroundStyle(theme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView(.horizontal) {
                Text(displayText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.onSurface)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(Theme.Space.item)
            }
            .scrollIndicators(.never)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surfaceContainerHighest, in: RoundedRectangle(cornerRadius: Theme.Shape.sm, style: .continuous))
            .accessibilityLabel("\(title) snippet")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceContainer, in: RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous))
    }
}

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
        Button {
            ClipboardWriter.copy(text(), concealed: concealed)
            copied = true
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.voqoraSecondary)
        .accessibilityLabel(copied ? "\(accessibilityTitle) copied" : "Copy \(accessibilityTitle)")
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}

struct CopyableSnippet: View {
    @EnvironmentObject var vm: DashboardViewModel
    let title: String
    let caption: String
    let displayText: String
    let copyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(vm.font(.rowTitle).weight(.semibold))
                    Text(caption)
                        .font(vm.font(.rowSubtitle))
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                CopyButton(accessibilityTitle: title, text: { copyText })
            }
            ScrollView(.horizontal) {
                Text(displayText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(DesignTokens.Spacing.md)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .voqoraSurface(.control, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.small, style: .continuous))
            .accessibilityLabel("\(title) snippet")
        }
    }
}

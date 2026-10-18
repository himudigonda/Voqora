import SwiftUI

struct AudiobookExportMenuItems: View {
    @ObservedObject var exports: AudiobookExportController
    let book: Audiobook

    var body: some View {
        if exports.isExporting(book) {
            Button { exports.cancel() } label: {
                Label("Cancel Export", systemImage: "xmark.circle")
            }
        } else {
            ForEach(AudiobookExportFormat.allCases) { format in
                Button { exports.export(book, as: format) } label: {
                    Label(format.menuTitle, systemImage: format.systemImage)
                }
            }
            .disabled(exports.active != nil || book.status != "done")
        }
    }
}

struct AudiobookExportButton: View {
    @ObservedObject var exports: AudiobookExportController
    let book: Audiobook
    let tint: Color

    private var isEnabled: Bool {
        book.status == "done"
    }

    var body: some View {
        Menu {
            AudiobookExportMenuItems(exports: exports, book: book)
        } label: {
            Group {
                if let progress = exports.progress(for: book) {
                    ProgressView(value: progress)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(tint)
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.textPrimary)
                }
            }
            .frame(width: 30, height: 30)
            .background(Circle().fill(Palette.controlFill))
            .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    private var helpText: String {
        guard let progress = exports.progress(for: book) else { return "Export" }
        return "Exporting, \(Int((progress * 100).rounded())) percent"
    }
}

struct AudiobookExportQualityPicker: View {
    @EnvironmentObject var vm: DashboardViewModel
    @AppStorage(AudiobookExportSettings.bitrateKey) private var bitrateKbps = AudiobookExportSettings.defaultBitrateKbps

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Export Quality", systemImage: "square.and.arrow.up")
                    .font(vm.font(.rowTitle))
                Spacer()
                Picker("Export Quality", selection: $bitrateKbps) {
                    ForEach(AudiobookExportSettings.bitrateOptionsKbps, id: \.self) { kbps in
                        Text("\(kbps) kbps").tag(kbps)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            Text("M4B exports are encoded as mono AAC at this bitrate. 64 kbps keeps narration clear and files small.")
                .font(vm.font(.rowSubtitle))
                .foregroundStyle(Palette.textSecondary)
        }
    }
}

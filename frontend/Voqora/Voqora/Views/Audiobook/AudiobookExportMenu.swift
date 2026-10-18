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
            Group {
                formatButtons(AudiobookExportFormat.audioFormats)
                Divider()
                formatButtons(AudiobookExportFormat.subtitleFormats)
            }
            .disabled(exports.active != nil || book.status != "done")
        }
    }

    private func formatButtons(_ formats: [AudiobookExportFormat]) -> some View {
        ForEach(formats) { format in
            Button { exports.export(book, as: format) } label: {
                Label(format.menuTitle, systemImage: format.systemImage)
            }
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
                    if progress > 0 {
                        ProgressView(value: progress)
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .tint(tint)
                    } else {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .tint(tint)
                    }
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
        guard progress > 0 else { return "Preparing export" }
        return "Exporting, \(Int((progress * 100).rounded())) percent"
    }
}

struct AudiobookExportQualityPicker: View {
    @EnvironmentObject var vm: DashboardViewModel
    @AppStorage(AudiobookExportSettings.bitrateKey) private var bitrateKbps = AudiobookExportSettings.defaultBitrateKbps
    @AppStorage(AudiobookExportSettings.mp3BitrateKey) private var mp3BitrateKbps = AudiobookExportSettings.defaultMP3BitrateKbps

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            qualityRow(
                "Export Quality",
                systemImage: "square.and.arrow.up",
                selection: $bitrateKbps,
                options: AudiobookExportSettings.bitrateOptionsKbps
            )
            Text("M4B exports are encoded as mono AAC at this bitrate. 64 kbps keeps narration clear and files small.")
                .font(vm.font(.rowSubtitle))
                .foregroundStyle(Palette.textSecondary)
            qualityRow(
                "MP3 Quality",
                systemImage: "music.note",
                selection: mp3Selection,
                options: AudiobookExportSettings.mp3BitrateOptionsKbps
            )
            .padding(.top, 8)
            Text("MP3 exports play on almost any device. 96 kbps suits spoken word; higher rates make larger files.")
                .font(vm.font(.rowSubtitle))
                .foregroundStyle(Palette.textSecondary)
        }
    }

    private var mp3Selection: Binding<Int> {
        Binding(
            get: { AudiobookExportSettings.nearestMP3Kbps(mp3BitrateKbps) },
            set: { mp3BitrateKbps = $0 }
        )
    }

    private func qualityRow(_ title: String, systemImage: String, selection: Binding<Int>, options: [Int]) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(vm.font(.rowTitle))
            Spacer()
            Picker(title, selection: selection) {
                ForEach(options, id: \.self) { kbps in
                    Text("\(kbps) kbps").tag(kbps)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}

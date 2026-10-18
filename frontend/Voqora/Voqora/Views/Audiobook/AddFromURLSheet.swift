import SwiftUI

struct AddFromURLSheet: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @State private var address: String
    @State private var voice: String
    @State private var speed: Double
    @State private var problem: WebPageLink.Problem?
    @FocusState private var isAddressFocused: Bool

    init(initialAddress: String, voice: String, speed: Double) {
        _address = State(initialValue: initialAddress)
        _voice = State(initialValue: voice)
        _speed = State(initialValue: min(2.0, max(0.75, speed)))
    }

    private var accentColor: Color {
        vm.accentColor(scheme: colorScheme, contrast: colorSchemeContrast)
    }

    private var canSubmit: Bool {
        !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            addressField
            Divider()
            voiceRow
            speedRow
            Label("You can turn on AI cleanup and choose a provider on the next step.", systemImage: "info.circle")
                .font(vm.appFont(size: 11))
                .foregroundStyle(Palette.textSecondary)
            actions
                .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 520)
        .voqoraSurface(.floating, in: Rectangle())
        .onAppear { isAddressFocused = true }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Audiobook")
                    .font(vm.font(.sectionHeader))
                    .foregroundStyle(accentColor)
                Text("Add from URL")
                    .font(vm.appFont(size: 18, weight: .bold))
                    .foregroundStyle(Palette.textPrimary)
                Text("Voqora reads the article on the page, or the PDF the link points to.")
                    .font(vm.appFont(size: 12))
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            Button { bookVM.dismissWebPageImport() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Palette.textSecondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")
        }
    }

    private var addressField: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("https://example.com/article", text: $address)
                .textFieldStyle(.roundedBorder)
                .font(vm.appFont(size: 13))
                .autocorrectionDisabled()
                .focused($isAddressFocused)
                .onSubmit(submit)
                .onChange(of: address) { _, _ in problem = nil }
                .accessibilityLabel("Web page address")
                .accessibilityHint(problem?.message ?? "Enter a link that starts with http or https")
            if let problem {
                Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                    .font(vm.appFont(size: 11))
                    .foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var voiceRow: some View {
        HStack {
            Label("Voice", systemImage: "person.wave.2")
                .font(vm.font(.rowTitle))
            Spacer()
            GroupedVoicePicker(title: "Narration Voice", selection: $voice)
                .accessibilityLabel("Narration voice")
        }
    }

    private var speedRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Narration Speed", systemImage: "gauge.with.needle")
                    .font(vm.font(.rowTitle))
                Spacer()
                Text(PlayerSpeedMenu.label(speed))
                    .font(vm.appFont(size: 14, weight: .bold).monospaced())
                    .foregroundStyle(accentColor)
            }
            Slider(value: $speed, in: 0.75 ... 2.0, step: 0.05)
                .tint(accentColor)
                .accessibilityLabel("Narration speed")
                .accessibilityValue(PlayerSpeedMenu.label(speed))
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button { bookVM.dismissWebPageImport() } label: {
                Text("Cancel")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.voqoraSecondary)

            Button(action: submit) {
                Label("Continue", systemImage: "arrow.right")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .font(vm.appFont(size: 13, weight: .bold))
            }
            .buttonStyle(.voqoraPrimary)
            .disabled(!canSubmit)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func submit() {
        guard bookVM.isWebPageImportPresented else { return }
        switch WebPageLink.validate(address) {
        case let .success(url):
            bookVM.importWebPage(url, voice: voice, speed: speed)
        case let .failure(found):
            problem = found
            isAddressFocused = true
        }
    }
}

import SwiftUI

struct FeedbackView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var identity: IdentityService
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var kind: FeedbackKind = .issue
    @State private var message = ""
    @AppStorage("feedbackIncludesVersions") private var includeVersions = true
    @State private var email = ""
    @State private var isSending = false
    @State private var sent = false
    @State private var error: String?
    @FocusState private var messageFocused: Bool

    private var accent: Color {
        vm.accentColor(scheme: colorScheme, contrast: contrast)
    }

    private var accentMuted: Color {
        Palette.accentColors(for: vm.accentColorID, appearance: colorScheme, increaseContrast: contrast == .increased).accentMuted
    }

    private var isEmpty: Bool {
        message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                kindTiles
                composer
                footer
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 36)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .animation(DesignTokens.Animation.standard, value: kind)
        .animation(DesignTokens.Animation.standard, value: sent)
        .animation(DesignTokens.Animation.standard, value: error)
        .onAppear {
            if email.isEmpty {
                email = identity.email ?? ""
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Group {
                if let icon = NSImage(named: vm.appIconID.assetName) {
                    Image(nsImage: icon).resizable()
                } else {
                    Color.clear
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.1), radius: 6, y: 3)

            VStack(alignment: .leading, spacing: 4) {
                Text("Tell me what you think")
                    .font(vm.font(.pageTitle))
                    .foregroundStyle(Palette.textPrimary)
                Text("Voqora is made by one person. Every note gets read.")
                    .font(vm.appFont(size: 14))
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private var kindTiles: some View {
        HStack(spacing: 12) {
            ForEach(FeedbackKind.allCases) { option in
                tile(option)
            }
        }
    }

    private func tile(_ option: FeedbackKind) -> some View {
        let selected = option == kind
        return Button {
            kind = option
            sent = false
            messageFocused = true
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: option.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(selected ? accent : Palette.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(selected ? accentMuted.opacity(0.6) : Palette.controlFill, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(vm.appFont(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                    Text(option.subtitle)
                        .font(vm.font(.rowSubtitle))
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large, style: .continuous)
                    .fill(selected ? accentMuted.opacity(0.18) : Palette.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large, style: .continuous)
                    .strokeBorder(selected ? accent.opacity(0.7) : Palette.controlBorder, lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    @ViewBuilder
    private var composer: some View {
        if sent {
            thanks
        } else {
            form
        }
    }

    private var form: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $message)
                    .disabled(isSending)
                    .font(vm.appFont(size: 14))
                    .scrollContentBackground(.hidden)
                    .focused($messageFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                if message.isEmpty {
                    Text(kind.placeholder)
                        .font(vm.appFont(size: 14))
                        .foregroundStyle(Palette.textTertiary)
                        .padding(.horizontal, 19)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 170)
            .onChange(of: message) { error = nil }

            Rectangle().fill(Palette.separator).frame(height: 1)

            HStack(spacing: 8) {
                Image(systemName: "envelope")
                    .font(vm.font(.rowSubtitle))
                    .foregroundStyle(Palette.textTertiary)
                TextField("Your email, if you'd like a reply", text: $email)
                    .textFieldStyle(.plain)
                    .font(vm.appFont(size: 13))
                    .textContentType(.emailAddress)
                    .onChange(of: email) { error = nil }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)

            Rectangle().fill(Palette.separator).frame(height: 1)

            HStack(spacing: 12) {
                Toggle(isOn: $includeVersions) {
                    Text("Add app and macOS version")
                        .font(vm.font(.rowSubtitle))
                        .foregroundStyle(Palette.textSecondary)
                }
                .toggleStyle(.checkbox)
                .help("Only the version numbers. Nothing you've read or listened to.")

                Spacer()

                Button(action: send) {
                    HStack(spacing: 6) {
                        if isSending {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "paperplane.fill")
                        }
                        Text(isSending ? "Sending…" : "Send")
                    }
                }
                .buttonStyle(VoqoraPrimaryButtonStyle())
                .disabled(isEmpty || isSending)
                .opacity(isEmpty ? 0.5 : 1)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .voqoraSurface(.raised, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xLarge, style: .continuous)
                .strokeBorder(messageFocused ? accent.opacity(0.6) : .clear, lineWidth: 1.5)
        )
        .transition(.opacity)
    }

    private var thanks: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 44, height: 44)
                .background(accentMuted.opacity(0.5), in: Circle())
            Text("Got it. Thank you.")
                .font(vm.font(.sectionTitle))
                .foregroundStyle(Palette.textPrimary)
            Text(email.isEmpty ? "Your note is on its way." : "If it needs a reply, I'll write to \(email.lowercased()).")
                .font(vm.font(.rowSubtitle))
                .foregroundStyle(Palette.textSecondary)
            Button("Send another") {
                sent = false
                messageFocused = true
            }
            .buttonStyle(VoqoraSecondaryButtonStyle())
            .padding(.top, 6)
        }
        .padding(36)
        .frame(maxWidth: .infinity)
        .voqoraSurface(.raised, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xLarge, style: .continuous))
        .transition(.opacity)
    }

    @ViewBuilder
    private var footer: some View {
        if let error {
            Label {
                Text(error).foregroundStyle(Palette.textSecondary)
            } icon: {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.danger)
            }
            .font(vm.font(.rowSubtitle))
            .transition(.opacity)
        } else {
            HStack(spacing: 4) {
                Text("Enjoying Voqora? A")
                Link("star on GitHub", destination: URL(string: "https://github.com/himudigonda/Voqora")!)
                    .foregroundStyle(accent)
                Text("helps other people find it.")
            }
            .font(vm.font(.rowSubtitle))
            .foregroundStyle(Palette.textTertiary)
        }
    }

    private func send() {
        guard !isEmpty, !isSending else { return }
        isSending = true
        error = nil
        let service = FeedbackService(anonID: { identity.anonID })
        let sentMessage = message
        Task {
            do {
                try await service.send(kind: kind, message: sentMessage, email: email, includeVersions: includeVersions)
                if message == sentMessage {
                    message = ""
                }
                sent = true
            } catch {
                self.error = (error as? FeedbackService.SendError)?.errorDescription
                    ?? FeedbackService.SendError.failed.errorDescription
            }
            isSending = false
        }
    }
}

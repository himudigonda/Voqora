import AppKit
import SwiftUI

struct FeedbackView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var identity: IdentityService
    @Environment(\.voqoraTheme) private var theme

    @State private var kind: FeedbackKind = .issue
    @State private var message = ""
    @AppStorage("feedbackIncludesVersions") private var includeVersions = true
    @State private var email = ""
    @State private var isSending = false
    @State private var sent = false
    @State private var error: String?
    @FocusState private var messageFocused: Bool

    private var isEmpty: Bool {
        message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        PageScaffold(title: "Send Feedback", subtitle: "Voqora is made by one person. Every note gets read.") {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                kindTiles
                composer
                footer
            }
            .frame(maxWidth: 760, alignment: .leading)
        }
        .animation(Theme.Motion.selection, value: kind)
        .animation(Theme.Motion.selection, value: sent)
        .animation(Theme.Motion.selection, value: error)
        .onAppear {
            if email.isEmpty {
                email = identity.email ?? ""
            }
        }
    }

    private var kindTiles: some View {
        HStack(spacing: Theme.Space.item + 4) {
            ForEach(FeedbackKind.allCases) { option in
                OptionCard(
                    title: option.title,
                    supporting: option.subtitle,
                    systemImage: option.icon,
                    isSelected: option == kind
                ) {
                    kind = option
                    sent = false
                    messageFocused = true
                }
            }
        }
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
        VoqoraCard {
            VStack(alignment: .leading, spacing: Theme.Space.item + 4) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $message)
                        .disabled(isSending)
                        .font(vm.font(.body))
                        .foregroundStyle(theme.onSurface)
                        .scrollContentBackground(.hidden)
                        .focused($messageFocused)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    if message.isEmpty {
                        Text(kind.placeholder)
                            .font(vm.font(.body))
                            .foregroundStyle(theme.onSurfaceMuted)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 170)
                .background(theme.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous)
                        .strokeBorder(theme.primary, lineWidth: messageFocused ? 2 : 0)
                )
                .onChange(of: message) { error = nil }

                HStack(spacing: 8) {
                    Image(systemName: "envelope")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.onSurfaceMuted)
                    TextField("Your email, if you'd like a reply", text: $email)
                        .textContentType(.emailAddress)
                        .onChange(of: email) { error = nil }
                }
                .settingsField()

                HStack(spacing: Theme.Space.item) {
                    Toggle(isOn: $includeVersions) {
                        Text("Add app and macOS version")
                            .font(vm.font(.label))
                            .foregroundStyle(theme.onSurfaceVariant)
                    }
                    .toggleStyle(.voqoraSwitch)
                    .help("Only the version numbers. Nothing you've read or listened to.")
                    Spacer(minLength: 0)
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
                    .buttonStyle(.voqoraFilled)
                    .disabled(isEmpty || isSending)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .transition(.opacity)
    }

    private var thanks: some View {
        VoqoraCard {
            EmptyStateView(
                symbol: "checkmark",
                title: "Got it. Thank you.",
                message: email.isEmpty ? "Your note is on its way." : "If it needs a reply, I'll write to \(email.lowercased()).",
                action: EmptyStateAction(title: "Send another") {
                    sent = false
                    messageFocused = true
                }
            )
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private var footer: some View {
        if let error {
            SettingsNoticeRow(text: error, kind: .danger)
                .transition(.opacity)
        } else {
            HStack(spacing: 4) {
                Text("Enjoying Voqora? A")
                Button("star on GitHub") {
                    if let url = URL(string: "https://github.com/himudigonda/Voqora") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.voqoraText)
                .padding(.horizontal, -8)
                Text("helps other people find it.")
            }
            .font(vm.font(.bodySmall))
            .foregroundStyle(theme.onSurfaceMuted)
        }
    }

    private func send() {
        guard !isEmpty, !isSending else { return }
        isSending = true
        error = nil
        let service = FeedbackService(anonID: { MetricsService.userAllowsAnalytics() ? identity.anonID : UUID().uuidString })
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

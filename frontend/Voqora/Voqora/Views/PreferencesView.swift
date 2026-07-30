import KeyboardShortcuts
import SwiftUI

struct PreferencesView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var audio: AudioService
    @EnvironmentObject var launchManager: LaunchManager
    @EnvironmentObject var bookVM: AudiobookViewModel
    @EnvironmentObject var identity: IdentityService
    @EnvironmentObject var onboarding: OnboardingCoordinator
    @EnvironmentObject var updater: AppUpdater
    @EnvironmentObject var legacyMigration: LegacySuperSayMigration

    @AppStorage("showMenuBarIcon") var showMenuBarIcon = true
    @State private var emailDraft: String = ""
    @State private var emailSubmitting = false
    @State private var emailError: String?
    @State private var emailSaved = false
    @State private var emailRemoving = false
    @State private var migrationStatus: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text("Preferences")
                        .font(vm.appFont(size: 34, weight: .bold))
                    Text("Configure Voqora to match your workflow.")
                        .font(vm.appFont(size: 14))
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)

                // Section: Optional identity
                PreferenceSection(title: "Identity", icon: "person.crop.circle") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Optional email")
                            .font(vm.appFont(size: 14, weight: .bold))
                        Text("Add an email only if you want us to recognise the same person across installs. We never collect your text or files, and you can remove your email at any time.")
                            .font(vm.appFont(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Email address")
                            .font(vm.appFont(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)

                        HStack(alignment: .center, spacing: 10) {
                            TextField("name@example.com", text: $emailDraft)
                                .textFieldStyle(.roundedBorder)
                                .textContentType(.emailAddress)
                                .disableAutocorrection(true)
                                .font(vm.appFont(size: 13))
                            Button {
                                submitEmail()
                            } label: {
                                if emailSubmitting {
                                    ProgressView().scaleEffect(0.6).frame(width: 96)
                                } else {
                                    Text(identity.hasIdentity ? "Update email" : "Save email").frame(width: 96)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.cyan)
                            .disabled(emailDraft.trimmingCharacters(in: .whitespaces).isEmpty || emailSubmitting)
                        }

                        if let err = emailError {
                            Text(err).font(vm.appFont(size: 11)).foregroundStyle(.red)
                        } else if emailSaved {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                                Text("Saved. Thanks!").font(vm.appFont(size: 11)).foregroundStyle(.green)
                            }
                        } else if let current = identity.email {
                            HStack {
                                Text("Email saved for this Mac")
                                    .font(vm.appFont(size: 11))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button(emailRemoving ? "Removing…" : "Remove") {
                                    removeEmail()
                                }
                                    .buttonStyle(.plain)
                                    .font(vm.appFont(size: 11))
                                    .foregroundStyle(.red)
                                    .disabled(emailRemoving)
                            }
                            .accessibilityLabel("Saved email: \(current)")
                        } else {
                            Text("No email saved. Voqora works fully without one.")
                                .font(vm.appFont(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onAppear {
                    if emailDraft.isEmpty { emailDraft = identity.email ?? "" }
                }

                PreferenceSection(title: "Setup", icon: "checklist") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Need to review permissions or the first-use guide?")
                            .font(vm.appFont(size: 12))
                            .foregroundStyle(.secondary)
                        Button {
                            onboarding.reset()
                        } label: {
                            Label("Run onboarding again", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if legacyMigration.isLegacyInstalled {
                    PreferenceSection(title: "SuperSay migration", icon: "arrow.right.circle") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("SuperSay is retired. Voqora is the supported successor.")
                                .font(vm.appFont(size: 14, weight: .bold))
                            Text("Import compatible playback and appearance preferences if you want to. Documents, audio, history, credentials, email, shortcuts, and analytics choices are never copied. Voqora will never remove SuperSay automatically.")
                                .font(vm.appFont(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button("Import preferences") {
                                    let count = legacyMigration.importCompatiblePreferences()
                                    migrationStatus = count > 0
                                        ? "Imported \(count) compatible preference\(count == 1 ? "" : "s")."
                                        : "No compatible SuperSay preferences were found."
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.cyan)
                                Button("Show SuperSay in Finder") {
                                    legacyMigration.showLegacyAppInFinder()
                                }
                                .buttonStyle(.bordered)
                            }
                            if let migrationStatus {
                                Text(migrationStatus)
                                    .font(vm.appFont(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // Section: Voice Engine
                PreferenceSection(title: "Voice Engine", icon: "cpu") {
                    VStack(spacing: 20) {
                        HStack {
                            Label("Active Voice", systemImage: "person.wave.2")
                                .font(vm.appFont(size: 14))
                            Spacer()
                            Picker("", selection: $vm.selectedVoice) {
                                ForEach(vm.availableVoices, id: \.id) { voice in
                                    Text(voice.display).tag(voice.id)
                                }
                            }
                            .frame(width: 150)
                            .labelsHidden()
                        }

                        Text("Kokoro delivers high-quality, expressive voices.")
                            .font(vm.appFont(size: 11))
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label("Speech Speed", systemImage: "gauge.with.needle")
                                    .font(vm.appFont(size: 14))
                                Spacer()
                                Text("\(String(format: "%.1f", vm.speechSpeed))x")
                                    .font(vm.appFont(size: 14, weight: .bold).monospaced())
                                    .foregroundStyle(.cyan)
                                    .fontWeight(.bold)
                            }
                            Slider(value: $vm.speechSpeed, in: 0.5 ... 2.0)
                                .tint(.cyan)
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label("Master Volume", systemImage: "speaker.wave.3")
                                    .font(vm.appFont(size: 14))
                                Spacer()
                                Text("\(Int(vm.speechVolume * 100))%")
                                    .font(vm.appFont(size: 14, weight: .bold).monospaced())
                                    .foregroundStyle(.cyan)
                                    .fontWeight(.bold)
                            }
                            Slider(value: $vm.speechVolume, in: 0.0 ... 1.5)
                                .tint(.cyan)
                        }
                    }
                }

                // Section: Audiobooks
                PreferenceSection(title: "Audiobooks", icon: "books.vertical") {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label("Gemini API Key", systemImage: "key.fill")
                                    .font(vm.appFont(size: 14))
                                Spacer()
                                if bookVM.keyVerified {
                                    HStack(spacing: 4) {
                                        Image(systemName: "checkmark.seal.fill")
                                        Text("VERIFIED")
                                    }
                                    .font(vm.appFont(size: 9, weight: .black))
                                    .kerning(1)
                                    .foregroundStyle(.green)
                                }
                            }
                            HStack {
                                SecureField("AIza...", text: $bookVM.draftKey)
                                    .textFieldStyle(.roundedBorder)
                                    .font(vm.appFont(size: 13).monospaced())
                                Button {
                                    bookVM.verifyAndSaveKey()
                                } label: {
                                    if bookVM.verifyingKey {
                                        ProgressView().scaleEffect(0.6).frame(width: 60)
                                    } else {
                                        Text("Verify").frame(width: 60)
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.cyan)
                                .disabled(bookVM.draftKey.trimmingCharacters(in: .whitespaces).isEmpty || bookVM.verifyingKey)
                            }
                            HStack {
                                Link("Get a key from aistudio.google.com",
                                     destination: URL(string: "https://aistudio.google.com/apikey")!)
                                    .font(vm.appFont(size: 11))
                                    .foregroundStyle(.cyan)
                                Spacer()
                                if bookVM.hasStoredKey {
                                    Button("Remove") { bookVM.removeKey() }
                                        .buttonStyle(.plain)
                                        .font(vm.appFont(size: 11))
                                        .foregroundStyle(.red)
                                }
                            }
                        }

                        Divider()

                        HStack {
                            Label("Default Voice", systemImage: "person.wave.2")
                                .font(vm.appFont(size: 14))
                            Spacer()
                            Picker("", selection: $bookVM.defaultBookVoice) {
                                ForEach(vm.availableVoices, id: \.id) { voice in
                                    Text(voice.display).tag(voice.id)
                                }
                            }
                            .frame(width: 150)
                            .labelsHidden()
                        }

                        Text("Audiobook generation uses this voice. Clipboard TTS continues to use the live 'Active Voice' above.")
                            .font(vm.appFont(size: 11))
                            .foregroundStyle(.secondary)

                        Divider()

                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label("Default Speed", systemImage: "gauge.with.needle")
                                    .font(vm.appFont(size: 14))
                                Spacer()
                                Text(String(format: "%.2fx", bookVM.defaultBookSpeed))
                                    .font(vm.appFont(size: 14, weight: .bold).monospaced())
                                    .foregroundStyle(.cyan)
                            }
                            Slider(value: $bookVM.defaultBookSpeed, in: 0.75...2.0).tint(.cyan)
                        }

                        Text("Text-based documents are narrated locally by default. You can opt into Gemini cleanup for a difficult document, and scanned PDFs need Gemini OCR before they can be narrated.")
                            .font(vm.appFont(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                // Section: Audio Environment
                PreferenceSection(title: "Audio Environment", icon: "hifispeaker") {
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle(isOn: $vm.enableDucking) {
                            VStack(alignment: .leading) {
                                Text("Music Ducking")
                                    .font(vm.appFont(size: 16))
                                Text("Attenuates background music while Voqora is speaking.")
                                    .font(vm.appFont(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Divider()

                        Toggle(isOn: $vm.cleanURLs) {
                            VStack(alignment: .leading) {
                                Text("Sanitize URLs")
                                    .font(vm.appFont(size: 16))
                                Text("Automatically removes complex URLs and handles from spoken text.")
                                    .font(vm.appFont(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // Section: Keyboard Shortcuts
                PreferenceSection(title: "Shortcuts", icon: "keyboard") {
                    VStack(spacing: 0) {
                        ShortcutRow(title: "Speak Selection", name: .playText)
                        Divider().padding(.vertical, 8)
                        ShortcutRow(title: "Pause / Resume", name: .togglePause)
                        Divider().padding(.vertical, 8)
                        ShortcutRow(title: "Stop Playback", name: .stopText)
                        Divider().padding(.vertical, 8)
                        ShortcutRow(title: "Export to Desktop", name: .exportAudio)

                        Divider().padding(.vertical, 16)

                        HStack {
                            Text("Shortcuts are global and work from any app.")
                                .font(vm.appFont(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Reset to Defaults") {
                                resetShortcuts()
                            }
                            .buttonStyle(.borderless)
                            .font(vm.appFont(size: 12))
                            .foregroundStyle(.red)
                        }
                    }
                }

                // Section: System & Appearance
                PreferenceSection(title: "Application", icon: "window.badge.magnifyingglass") {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Theme")
                                .font(vm.appFont(size: 14))
                            Spacer()
                            Picker("", selection: $vm.appTheme) {
                                Text("System").tag("system")
                                Text("Light").tag("light")
                                Text("Dark").tag("dark")
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 200)
                        }

                        Divider()

                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Typography")
                                    .font(vm.appFont(size: 14, weight: .bold))
                                Text("Current: \(vm.selectedFontName)")
                                    .font(vm.appFont(size: 11))
                                    .foregroundStyle(.cyan)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 12) {
                                Picker("", selection: $vm.selectedFontName) {
                                    Text("System Rounded").tag("System Rounded")
                                    Text("System Standard").tag("System Standard")
                                    Text("System Mono").tag("System Mono")
                                    Text("System Serif").tag("System Serif")
                                    Divider()
                                    Text("Poppins").tag("Poppins")
                                }
                                .frame(width: 200)

                                Button {
                                    vm.showFontPanel()
                                } label: {
                                    Label("More Fonts...", systemImage: "textformat.size")
                                        .font(vm.appFont(size: 11, weight: .semibold))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(.ultraThinMaterial)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Divider()

                        Toggle(isOn: $launchManager.isLaunchAtLoginEnabled) {
                            Text("Start at Login")
                                .font(vm.appFont(size: 14))
                        }
                        .toggleStyle(.switch)

                        Divider()

                        Toggle(isOn: $showMenuBarIcon) {
                            Text("Show Menu Bar Icon")
                                .font(vm.appFont(size: 14))
                        }
                        .toggleStyle(.switch)

                        Divider()

                        Toggle(isOn: Binding(
                            get: { vm.telemetryEnabled },
                            set: { enabled in
                                vm.telemetryEnabled = enabled
                                Task { await MetricsService.shared.setEnabled(enabled) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Anonymous Analytics")
                                    .font(vm.appFont(size: 14, weight: .bold))
                                Text("Help improve Voqora by sharing anonymous usage statistics with himudigonda.me")
                                    .font(vm.appFont(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .help("We collect anonymous activity counts, never text, filenames, audio, or API keys. An email is sent only if you choose to provide one in Identity settings.")

                        Divider()

                        Toggle(isOn: Binding(
                            get: { updater.automaticallyChecksForUpdates },
                            set: { updater.setAutomaticallyChecksForUpdates($0) }
                        )) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Automatically check for updates")
                                    .font(vm.appFont(size: 14, weight: .bold))
                                Text("Checks Voqora's public update feed once a day. Voqora always shows you the update before replacing the app.")
                                    .font(vm.appFont(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.switch)

                        Divider()

                        HStack {
                            Button {
                                updater.checkForUpdates()
                            } label: {
                                Label("Check for Updates...", systemImage: "arrow.triangle.2.circlepath")
                                    .font(vm.appFont(size: 13, weight: .medium))
                            }
                            .buttonStyle(.plain)
                            .disabled(!updater.canCheckForUpdates)

                            if !updater.canCheckForUpdates {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Preparing update checks…")
                                        .font(vm.appFont(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                .help("Voqora enables this after the update service has finished starting or after a current check completes.")
                            }

                            Spacer()

                            Text("v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"))
                                .font(vm.appFont(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        Divider()

                        Button {
                            vm.exportLastClip()
                        } label: {
                            Label("Export Last Clip to Desktop", systemImage: "square.and.arrow.down")
                                .font(vm.appFont(size: 13, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)
                        .help("Manually export the most recently generated audio clip.")

                        Button {
                            vm.exportLogs()
                        } label: {
                            Label("Export Debug Logs", systemImage: "doc.text.fill")
                                .font(vm.appFont(size: 13, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered)
                        .help("Save backend usage logs to Desktop for troubleshooting.")
                    }
                }
            }
            .padding(40)
            .frame(maxWidth: 800)
        }
    }

    private func submitEmail() {
        emailError = nil
        emailSaved = false
        let candidate = emailDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }
        emailSubmitting = true
        Task {
            defer { emailSubmitting = false }
            do {
                try await identity.submitEmail(candidate)
                emailSaved = true
            } catch {
                emailError = (error as? IdentityService.IdentityError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func resetShortcuts() {
        for name in KeyboardShortcuts.Name.allCases {
            KeyboardShortcuts.reset(name)
        }
    }

    private func removeEmail() {
        emailError = nil
        emailSaved = false
        emailRemoving = true
        Task {
            defer { emailRemoving = false }
            do {
                try await identity.removeEmail()
                emailDraft = ""
            } catch {
                emailError = (error as? IdentityService.IdentityError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

struct ShortcutRow: View {
    @EnvironmentObject var vm: DashboardViewModel
    let title: String
    let name: KeyboardShortcuts.Name

    var body: some View {
        HStack {
            Text(title)
                .font(vm.appFont(size: 14, weight: .medium))
            Spacer()
            KeyboardShortcuts.Recorder(for: name)
        }
    }
}

struct PreferenceSection<Content: View>: View {
    @EnvironmentObject var vm: DashboardViewModel
    let title: String
    let icon: String
    let content: Content

    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(.cyan)
                    .font(.headline)
                Text(title.uppercased())
                    .font(vm.appFont(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)
                    .kerning(1)
            }

            VStack {
                content
            }
            .padding(20)
            .background(.ultraThinMaterial.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.1), lineWidth: 1)
            )
        }
    }
}

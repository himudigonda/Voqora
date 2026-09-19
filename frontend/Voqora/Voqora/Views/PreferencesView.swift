import AppKit
import KeyboardShortcuts
import SwiftUI

struct PreferencesView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var audio: AudioService
    @EnvironmentObject var launchManager: LaunchManager
    @EnvironmentObject var bookVM: AudiobookViewModel
    @EnvironmentObject var history: HistoryManager
    @EnvironmentObject var identity: IdentityService
    @EnvironmentObject var onboarding: OnboardingCoordinator
    @EnvironmentObject var installer: GuidedInstallerService
    @EnvironmentObject var permissions: PermissionsService
    @EnvironmentObject var updater: AppUpdater
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.colorSchemeContrast) var colorSchemeContrast

    @AppStorage("showMenuBarIcon") var showMenuBarIcon = true
    @State private var emailDraft: String = ""
    @State private var emailSubmitting = false
    @State private var emailError: String?
    @State private var emailSaved = false
    @State private var emailRemoving = false
    @State private var emailRemovalQueued = false
    @State private var showEraseConfirmation = false
    @State private var erasingLocalData = false
    @State private var eraseError: String?

    /// The app's accent, resolved once per body pass — every row, button,
    /// and link in this screen reads through this rather than a hardcoded
    /// `.cyan`.
    private var accentColor: Color {
        vm.accentColor(scheme: colorScheme, contrast: colorSchemeContrast)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text("Preferences")
                        .font(vm.font(.pageTitle))
                    Text("Configure Voqora to match your workflow.")
                        .font(vm.appFont(size: 14))
                        .foregroundStyle(Palette.textSecondary)
                }
                .padding(.bottom, 8)

                // Section: Optional identity
                PreferenceSection(title: "Identity", icon: "person.crop.circle") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Optional email")
                            .font(vm.font(.sectionTitle))
                        Text(
                            "Voqora works without an account. Add an email only if you want voluntary returning installs " +
                                "to be recognised in aggregate adoption metrics. We never collect your text or files, " +
                                "and you can remove your email at any time."
                        )
                        .font(vm.font(.rowSubtitle))
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                        Text("Email address")
                            .font(vm.font(.sectionHeader))
                            .foregroundStyle(Palette.textSecondary)

                        HStack(alignment: .center, spacing: 10) {
                            TextField("name@example.com", text: $emailDraft)
                                .textFieldStyle(.roundedBorder)
                                .textContentType(.emailAddress)
                                .disableAutocorrection(true)
                                .font(vm.font(.rowTitle))
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
                            .tint(accentColor)
                            .disabled(!canSaveEmail || emailSubmitting)
                            .help(canSaveEmail ? "Save this optional email" : "Enter a valid email to enable Save")
                        }

                        if let err = emailError {
                            Text(err).font(vm.font(.rowSubtitle)).foregroundStyle(Palette.danger)
                        } else if emailRemovalQueued || identity.hasPendingRemoval {
                            Text("Email removed from this Mac. Voqora will retry removing the optional server contact when it is online.")
                                .font(vm.font(.rowSubtitle))
                                .foregroundStyle(Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if emailSaved {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.success)
                                Text("Saved. Thanks!").font(vm.font(.rowSubtitle)).foregroundStyle(Palette.success)
                            }
                        } else if let current = identity.email {
                            HStack {
                                Text("Email saved for this Mac")
                                    .font(vm.font(.rowSubtitle))
                                    .foregroundStyle(Palette.textSecondary)
                                Spacer()
                                Button(emailRemoving ? "Removing…" : "Remove") {
                                    removeEmail()
                                }
                                .buttonStyle(.plain)
                                .font(vm.font(.rowSubtitle))
                                .foregroundStyle(Palette.danger)
                                .disabled(emailRemoving)
                            }
                            .accessibilityLabel("Saved email: \(current)")
                        } else {
                            Text(emailDraft.isEmpty || canSaveEmail
                                ? "No email saved. Voqora works fully without one."
                                : "Enter a valid email to enable Save.")
                                .font(vm.font(.rowSubtitle))
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }
                }
                .onAppear {
                    if emailDraft.isEmpty {
                        emailDraft = identity.email ?? ""
                    }
                }

                // Section: Notifications
                PreferenceSection(title: "Notifications", icon: "bell.badge") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Label("System Notifications", systemImage: "bell")
                                .font(vm.font(.rowTitle))
                            Spacer()
                            notificationsStatusBadge
                        }

                        Text("Notifies you when an audiobook finishes converting, when Voqora starts speaking a selection, and when an update is available.")
                            .font(vm.font(.rowSubtitle))
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if permissions.notificationsStatus == .denied {
                            Button {
                                permissions.openNotificationSettings()
                            } label: {
                                Label("Open Notification Settings", systemImage: "gear")
                            }
                            .buttonStyle(.bordered)
                        } else if permissions.notificationsStatus != .authorized {
                            Button {
                                Task { await permissions.requestNotifications() }
                            } label: {
                                Label("Enable Notifications", systemImage: "bell.badge")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(accentColor)
                        }
                    }
                }
                .onAppear { Task { await permissions.refreshNotifications() } }

                PreferenceSection(title: "Setup", icon: "checklist") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Need to review permissions or the first-use guide?")
                            .font(vm.font(.rowSubtitle))
                            .foregroundStyle(Palette.textSecondary)
                        Button {
                            onboarding.reset()
                        } label: {
                            Label("Run onboarding again", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                // Section: Appearance
                PreferenceSection(title: "Appearance", icon: "paintpalette") {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Accent Color")
                                .font(vm.font(.sectionTitle))
                            Text("Colors every highlight, selected row, and primary button across Voqora.")
                                .font(vm.font(.rowSubtitle))
                                .foregroundStyle(Palette.textSecondary)

                            HStack(spacing: 14) {
                                ForEach(AccentColorOption.allCases, id: \.self) { option in
                                    AccentSwatchButton(option: option, isSelected: vm.accentColorID == option) {
                                        vm.accentColorID = option
                                    }
                                }
                            }
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 10) {
                            Text("App Icon")
                                .font(vm.font(.sectionTitle))
                            Text("Changes the Dock and Finder icon immediately.")
                                .font(vm.font(.rowSubtitle))
                                .foregroundStyle(Palette.textSecondary)

                            HStack(spacing: 16) {
                                ForEach(AppIconOption.allCases) { option in
                                    AppIconChoiceButton(option: option, isSelected: vm.appIconID == option) {
                                        vm.appIconID = option
                                    }
                                }
                            }
                        }
                    }
                }

                // Section: Voice Engine
                PreferenceSection(title: "Voice Engine", icon: "cpu") {
                    VStack(spacing: 20) {
                        HStack {
                            Label("Active Voice", systemImage: "person.wave.2")
                                .font(vm.font(.rowTitle))
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
                            .font(vm.font(.rowSubtitle))
                            .foregroundStyle(Palette.textSecondary)

                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label("Speech Speed", systemImage: "gauge.with.needle")
                                    .font(vm.font(.rowTitle))
                                Spacer()
                                Text("\(String(format: "%.2f", vm.speechSpeed))x")
                                    .font(vm.appFont(size: 14, weight: .bold).monospaced())
                                    .foregroundStyle(accentColor)
                                    .fontWeight(.bold)
                            }
                            Slider(value: $vm.speechSpeed, in: 0.5 ... 2.0, step: 0.05)
                                .tint(accentColor)
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label("Master Volume", systemImage: "speaker.wave.3")
                                    .font(vm.font(.rowTitle))
                                Spacer()
                                Text("\(Int(vm.speechVolume * 100))%")
                                    .font(vm.appFont(size: 14, weight: .bold).monospaced())
                                    .foregroundStyle(accentColor)
                                    .fontWeight(.bold)
                            }
                            Slider(value: $vm.speechVolume, in: 0.0 ... 1.5, step: 0.05)
                                .tint(accentColor)
                        }
                    }
                }

                // Section: Audiobooks
                PreferenceSection(title: "Audiobooks", icon: "books.vertical") {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label("Gemini API Key", systemImage: "key.fill")
                                    .font(vm.font(.rowTitle))
                                Spacer()
                                if bookVM.keyVerified {
                                    HStack(spacing: 4) {
                                        Image(systemName: "checkmark.seal.fill")
                                        Text("VERIFIED")
                                    }
                                    .font(vm.font(.chip))
                                    .kerning(0.6)
                                    .foregroundStyle(Palette.success)
                                }
                            }
                            HStack {
                                SecureField("AIza...", text: $bookVM.draftKey)
                                    .textFieldStyle(.roundedBorder)
                                    .font(vm.font(.rowTitle).monospaced())
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
                                .tint(accentColor)
                                .disabled(bookVM.draftKey.trimmingCharacters(in: .whitespaces).isEmpty || bookVM.verifyingKey)
                            }
                            HStack {
                                Link("Get a key from aistudio.google.com",
                                     destination: URL(string: "https://aistudio.google.com/apikey")!)
                                    .font(vm.font(.rowSubtitle))
                                    .foregroundStyle(accentColor)
                                Spacer()
                                if bookVM.hasStoredKey {
                                    Button("Remove") { bookVM.removeKey() }
                                        .buttonStyle(.plain)
                                        .font(vm.font(.rowSubtitle))
                                        .foregroundStyle(Palette.danger)
                                }
                            }
                        }

                        Divider()

                        HStack {
                            Label("Default Voice", systemImage: "person.wave.2")
                                .font(vm.font(.rowTitle))
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
                            .font(vm.font(.rowSubtitle))
                            .foregroundStyle(Palette.textSecondary)

                        Divider()

                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label("Default Speed", systemImage: "gauge.with.needle")
                                    .font(vm.font(.rowTitle))
                                Spacer()
                                Text(String(format: "%.2fx", bookVM.defaultBookSpeed))
                                    .font(vm.appFont(size: 14, weight: .bold).monospaced())
                                    .foregroundStyle(accentColor)
                            }
                            Slider(value: $bookVM.defaultBookSpeed, in: 0.75 ... 2.0, step: 0.05).tint(accentColor)
                        }

                        Text(
                            "Text-based documents are narrated locally by default. You can opt into Gemini cleanup for " +
                                "a difficult document, and scanned PDFs need Gemini OCR before they can be narrated."
                        )
                        .font(vm.font(.rowSubtitle))
                        .foregroundStyle(Palette.textSecondary)
                    }
                }

                // Section: Audio Environment
                PreferenceSection(title: "Audio Environment", icon: "hifispeaker") {
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle(isOn: $vm.enableDucking) {
                            VStack(alignment: .leading) {
                                Text("Music Ducking")
                                    .font(vm.font(.paneTitle))
                                Text("Optionally lowers Music and Spotify while Voqora speaks, then restores each app's previous volume. macOS may ask for Automation permission.")
                                    .font(vm.font(.rowSubtitle))
                                    .foregroundStyle(Palette.textSecondary)
                            }
                        }

                        Divider()

                        Toggle(isOn: $vm.cleanURLs) {
                            VStack(alignment: .leading) {
                                Text("Sanitize URLs")
                                    .font(vm.font(.paneTitle))
                                Text("Automatically removes complex URLs and handles from spoken text.")
                                    .font(vm.font(.rowSubtitle))
                                    .foregroundStyle(Palette.textSecondary)
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
                                .font(vm.font(.rowSubtitle))
                                .foregroundStyle(Palette.textSecondary)
                            Spacer()
                            Button("Reset to Defaults") {
                                resetShortcuts()
                            }
                            .buttonStyle(.borderless)
                            .font(vm.font(.rowSubtitle))
                            .foregroundStyle(Palette.danger)
                        }
                    }
                }

                // Section: System & Appearance
                PreferenceSection(title: "Application", icon: "window.badge.magnifyingglass") {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Theme")
                                .font(vm.font(.rowTitle))
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
                                    .font(vm.font(.sectionTitle))
                                Text("Current: \(vm.selectedFontName)")
                                    .font(vm.font(.rowSubtitle))
                                    .foregroundStyle(accentColor)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 12) {
                                Picker("", selection: $vm.selectedFontName) {
                                    Text("Google Sans").tag("Google Sans")
                                    Text("Poppins").tag("Poppins")
                                    Divider()
                                    Text("System Rounded").tag("System Rounded")
                                    Text("System Standard").tag("System Standard")
                                    Text("System Mono").tag("System Mono")
                                    Text("System Serif").tag("System Serif")
                                }
                                .frame(width: 200)

                                Button {
                                    vm.showFontPanel()
                                } label: {
                                    Label("More Fonts...", systemImage: "textformat.size")
                                        .font(vm.font(.sectionHeader))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .voqoraSurface(.control, in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Divider()

                        Toggle(isOn: $launchManager.isLaunchAtLoginEnabled) {
                            Text("Start at Login")
                                .font(vm.font(.rowTitle))
                        }
                        .toggleStyle(.switch)

                        Divider()

                        Toggle(isOn: $showMenuBarIcon) {
                            Text("Show Menu Bar Icon")
                                .font(vm.font(.rowTitle))
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
                                    .font(vm.font(.sectionTitle))
                                Text("Help improve Voqora by sharing anonymous usage statistics with himudigonda.me")
                                    .font(vm.font(.rowSubtitle))
                                    .foregroundStyle(Palette.textSecondary)
                            }
                        }
                        .help("We collect anonymous activity counts, never text, filenames, audio, or API keys. An email is sent only if you choose to provide one in Identity settings.")

                        Divider()

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Erase all local Voqora data")
                                .font(vm.font(.sectionTitle))
                            Text(
                                "Permanently removes every audiobook and source document, generated audio, history, caches, " +
                                    "settings, optional email, telemetry outbox, anonymous identifier, and saved Gemini credential " +
                                    "from this Mac. Voqora will quit when complete. This does not delete optional contact data " +
                                    "already sent to the website; remove that first from Identity if needed."
                            )
                            .font(vm.font(.rowSubtitle))
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            Button(role: .destructive) {
                                showEraseConfirmation = true
                            } label: {
                                Label(erasingLocalData ? "Erasing local data…" : "Erase all local data", systemImage: "trash.fill")
                                    .font(vm.font(.button))
                            }
                            .buttonStyle(.bordered)
                            .disabled(erasingLocalData || bookVM.deletingAllBooks)
                            if let eraseError {
                                Text(eraseError)
                                    .font(vm.font(.rowSubtitle))
                                    .foregroundStyle(Palette.danger)
                            }
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 9) {
                            if let latest = updater.latestGitHubVersion {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.up.circle.fill").foregroundStyle(accentColor)
                                    Text("Voqora \(latest) is available.")
                                        .font(vm.appFont(size: 12, weight: .semibold))
                                    Link("Open the releases page", destination: GuidedInstallerService.releasePageURL)
                                        .font(vm.font(.rowSubtitle))
                                }
                            }

                            HStack {
                                Button {
                                    installer.downloadAndOpenLatest()
                                } label: {
                                    Label(installer.state.isBusy ? "Preparing installer…" : "Download latest installer", systemImage: "arrow.down.circle")
                                        .font(vm.font(.button))
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(accentColor)
                                .disabled(installer.state.isBusy)

                                Link("View releases on GitHub", destination: GuidedInstallerService.releasePageURL)
                                    .font(vm.font(.rowSubtitle))

                                Spacer()

                                Text("v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"))
                                    .font(vm.font(.caption))
                                    .foregroundStyle(Palette.textTertiary)
                            }

                            Text(
                                installer.state.message ??
                                    "Early access downloads a verified DMG, opens it in Finder, and lets you drag Voqora to " +
                                    "Applications. It never replaces the app automatically."
                            )
                            .font(vm.font(.rowSubtitle))
                            .foregroundStyle(installer.state.isFailure ? Palette.danger : Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                            if case .failed = installer.state {
                                Button("Try again") { installer.reset(); installer.downloadAndOpenLatest() }
                                    .buttonStyle(.bordered)
                            }
                        }

                        Divider()

                        Button {
                            vm.exportLastClip()
                        } label: {
                            Label("Export Last Clip to Desktop", systemImage: "square.and.arrow.down")
                                .font(vm.font(.button))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(accentColor)
                        .disabled(!audio.canExportLastClip)
                        .help(audio.canExportLastClip
                            ? "Manually export the most recently generated audio clip."
                            : "Speak a text selection before exporting a clip.")

                        Button {
                            vm.exportLogs()
                        } label: {
                            Label("Export Debug Logs", systemImage: "doc.text.fill")
                                .font(vm.font(.button))
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
        .alert("Erase all local Voqora data?", isPresented: $showEraseConfirmation) {
            Button("Erase and Quit", role: .destructive) { eraseAllLocalData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This cannot be undone. All local books, sources, audio, history, settings, caches, telemetry outbox, " +
                    "optional email, anonymous identifier, and Gemini credential will be permanently removed. Voqora " +
                    "will quit after the erase finishes."
            )
        }
    }

    private func submitEmail() {
        emailError = nil
        emailSaved = false
        emailRemovalQueued = false
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

    @ViewBuilder
    private var notificationsStatusBadge: some View {
        switch permissions.notificationsStatus {
        case .authorized, .provisional:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.success)
                Text("ENABLED")
            }
            .font(vm.font(.chip))
            .kerning(0.6)
            .foregroundStyle(Palette.success)
        case .denied:
            Text("DENIED")
                .font(vm.font(.chip))
                .kerning(0.6)
                .foregroundStyle(Palette.danger)
        case .notDetermined, .unknown:
            Text("NOT ENABLED")
                .font(vm.font(.chip))
                .kerning(0.6)
                .foregroundStyle(Palette.textTertiary)
        }
    }

    private var canSaveEmail: Bool {
        IdentityService.looksLikeEmail(emailDraft.trimmingCharacters(in: .whitespacesAndNewlines))
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
            let result = await identity.removeEmail()
            emailDraft = ""
            emailRemovalQueued = result == .queuedForRetry
        }
    }

    private func eraseAllLocalData() {
        guard !erasingLocalData else { return }
        eraseError = nil
        erasingLocalData = true
        Task {
            guard await bookVM.deleteAllBooksForErasure() else {
                erasingLocalData = false
                eraseError = "Your audiobook library could not be fully removed. Nothing else was erased. Try again when the local engine is available."
                return
            }

            // Stop user-visible playback before removing its cache. The backend
            // has already cancelled/deleted active book work above.
            audio.stop()
            var failures: [String] = []
            do {
                try history.eraseAll()
            } catch {
                failures.append("history")
            }
            for key in KeychainKey.allCases where !KeychainService.delete(key) {
                failures.append("saved credential")
            }
            identity.eraseLocalIdentity()
            await MetricsService.shared.eraseLocalData()

            let fileManager = FileManager.default
            let bundleID = Bundle.main.bundleIdentifier ?? "com.himudigonda.Voqora"
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(bundleID, isDirectory: true)
            let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(bundleID, isDirectory: true)
            // These are application-owned directories. The operation is
            // intentionally idempotent and is followed by termination so no
            // live component can recreate data under the erased root.
            for (name, directory) in [("application support files", appSupport), ("cache files", caches)] {
                guard fileManager.fileExists(atPath: directory.path) else { continue }
                do {
                    try fileManager.removeItem(at: directory)
                } catch {
                    failures.append(name)
                }
            }

            guard failures.isEmpty else {
                erasingLocalData = false
                eraseError = "Some local data could not be removed (\(failures.joined(separator: ", "))). Voqora is still open; retrying this action is safe."
                return
            }
            UserDefaults.standard.removePersistentDomain(forName: bundleID)

            NSApplication.shared.terminate(nil)
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
                .font(vm.font(.button))
            Spacer()
            KeyboardShortcuts.Recorder(for: name)
        }
    }
}

/// One tappable circle in the accent-color picker, filled with `option`'s
/// own resolved color rather than a static swatch — it re-resolves with
/// the current color scheme and Increase Contrast, same as every other
/// accent read in the app.
struct AccentSwatchButton: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.colorSchemeContrast) var colorSchemeContrast
    let option: AccentColorOption
    let isSelected: Bool
    let action: () -> Void

    private var swatchColor: Color {
        Palette.accentColors(for: option, appearance: colorScheme, increaseContrast: colorSchemeContrast == .increased).accent
    }

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(swatchColor)
                .frame(width: 28, height: 28)
                .overlay(
                    Circle()
                        .strokeBorder(Palette.textPrimary, lineWidth: isSelected ? 2 : 0)
                        .padding(-3)
                )
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Palette.onAccentColor(for: option, appearance: colorScheme, increaseContrast: colorSchemeContrast == .increased))
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.displayName)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help(option.displayName)
    }
}

/// One tappable preview in the app-icon picker. Loads the actual asset
/// catalog image rather than redrawing the wave, so the preview can never
/// drift from what `AppIconOption.apply()` sets as the real Dock/Finder icon.
struct AppIconChoiceButton: View {
    @EnvironmentObject var vm: DashboardViewModel
    let option: AppIconOption
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Group {
                    if let nsImage = NSImage(named: option.assetName) {
                        Image(nsImage: nsImage).resizable()
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isSelected ? Palette.textPrimary : Palette.separator, lineWidth: isSelected ? 2 : 1)
                )

                Text(option.displayName)
                    .font(vm.font(.caption))
                    .foregroundStyle(isSelected ? Palette.textPrimary : Palette.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.displayName)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help(option.displayName)
    }
}

struct PreferenceSection<Content: View>: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.colorSchemeContrast) var colorSchemeContrast
    let title: String
    let icon: String
    let content: Content

    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    private var accentColor: Color {
        vm.accentColor(scheme: colorScheme, contrast: colorSchemeContrast)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(accentColor)
                    .font(.headline)
                Text(title.uppercased())
                    .font(vm.font(.sectionHeader))
                    .foregroundStyle(Palette.textSecondary)
                    .kerning(0.6)
            }

            VStack {
                content
            }
            .padding(20)
            .voqoraSurface(.raised, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xLarge, style: .continuous))
        }
    }
}

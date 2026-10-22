import SwiftUI

enum SharedSettingsCopy {
    static let engineRecommendation = "We recommend Kokoro for the fastest, real-time speech. It's built in, works offline and starts speaking almost instantly."
    static let speakingVoiceLabel = "Speaking voice"
    static let narrationVoiceLabel = "Narration voice"
    static let voiceFooter = "Used when you speak selected text. Browse every installed voice with Change. Ming voices appear once Ming is downloaded."
    static let pauseFooter = "Pause length sets how long Voqora pauses between sentences and paragraphs."
    static let autoDetectTitle = "Auto-detect Language"
    static let autoDetectDetail = "Switches to a voice in the text's language when it differs from your voice's language."
    static let matchSpeakingVoiceButton = "Use My Speaking Voice"
    static let narrationFooter = "New audiobooks are narrated with this voice. Text-based documents are narrated locally by default. " +
        "You can opt into AI cleanup for a difficult document, and scanned PDFs need an AI provider that can read images."
    static let mingNarrationNote = "Ming narrates slower than real time, so long books take a while to finish. Kokoro is the quickest way to make an audiobook."
    static let exportFooter = "M4B exports are encoded as mono AAC. 64 kbps keeps narration clear and files small. " +
        "MP3 at 96 kbps suits spoken word; higher rates make larger files."
    static let accentDetail = "Tints buttons, chips and selected rows."
    static let analyticsDetail = "Anonymous counts, durations, engine, and feature names. No text, file names, app names, or recorded voices."
}

enum VoiceSync {
    static func bookVoice(current: String, previousSpeaking: String, newSpeaking: String) -> String {
        current == previousSpeaking ? newSpeaking : current
    }
}

struct IdentityDraft: Equatable {
    static let purposeNote = "Optional. Used only to reply to your feedback."
    static let partialNameMessage = "Add a name too, or clear the email to skip."

    var name = ""
    var email = ""

    enum Validation: Equatable {
        case blank
        case valid
        case invalid(String)
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var validation: Validation {
        if trimmedName.isEmpty, trimmedEmail.isEmpty {
            return .blank
        }
        guard IdentityService.looksLikeName(trimmedName) else {
            return .invalid(trimmedName.isEmpty ? Self.partialNameMessage : IdentityService.IdentityError.invalidName.errorDescription ?? "")
        }
        guard IdentityService.looksLikeEmail(trimmedEmail) else {
            return .invalid(IdentityService.IdentityError.invalidEmail.errorDescription ?? "")
        }
        return .valid
    }

    var allowsContinue: Bool {
        if case .invalid = validation {
            return false
        }
        return true
    }

    var errorMessage: String? {
        if case let .invalid(message) = validation {
            return message
        }
        return nil
    }

    func canSave(storedName: String?, storedEmail: String?) -> Bool {
        validation == .valid && (trimmedName != (storedName ?? "") || trimmedEmail != (storedEmail ?? "").lowercased())
    }

    @MainActor
    @discardableResult
    func commit(to identity: IdentityService) async throws -> Bool {
        guard validation == .valid, canSave(storedName: identity.name, storedEmail: identity.email) else { return false }
        try await identity.submitIdentity(name: name, email: email)
        return true
    }
}

struct SpeakingVoiceSections: View {
    var includesVolume = false

    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            SettingsSection(title: "Voice", footer: SharedSettingsCopy.voiceFooter) {
                SettingsVoiceCardRow(title: SharedSettingsCopy.speakingVoiceLabel, voiceID: $vm.selectedVoice)
                SettingsSwitchRow(
                    title: SharedSettingsCopy.autoDetectTitle,
                    detail: SharedSettingsCopy.autoDetectDetail,
                    systemImage: "character.bubble",
                    isOn: $vm.autoDetectLanguage
                )
            }
            SettingsSection(title: "Delivery", footer: SharedSettingsCopy.pauseFooter) {
                SettingsSliderRow(
                    title: "Speed",
                    value: $vm.speechSpeed,
                    range: 0.5 ... 2.0,
                    step: 0.05,
                    valueLabel: PlayerSpeedMenu.label(vm.speechSpeed)
                )
                SettingsSliderRow(
                    title: "Pause Length",
                    value: $vm.speechPauseScale,
                    range: PauseScale.range,
                    step: PauseScale.step,
                    valueLabel: PauseScale.label(vm.speechPauseScale)
                )
                if includesVolume {
                    SettingsSliderRow(
                        title: "Volume",
                        value: $vm.speechVolume,
                        range: 0.0 ... 1.5,
                        step: 0.05,
                        valueLabel: "\(Int(vm.speechVolume * 100))%"
                    )
                }
            }
            if SpeechEngineID.isMingVoice(vm.selectedVoice) {
                MingDeliverySettingsSection()
            }
        }
        .onChange(of: vm.selectedVoice) { previous, current in
            bookVM.defaultBookVoice = VoiceSync.bookVoice(
                current: bookVM.defaultBookVoice,
                previousSpeaking: previous,
                newSpeaking: current
            )
        }
    }
}

struct AudiobookDefaultsSections: View {
    var includesMP3Quality = true

    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @AppStorage(AudiobookExportSettings.bitrateKey) private var bitrateKbps = AudiobookExportSettings.defaultBitrateKbps
    @AppStorage(AudiobookExportSettings.mp3BitrateKey) private var mp3BitrateKbps = AudiobookExportSettings.defaultMP3BitrateKbps

    private var mp3Selection: Binding<Int> {
        Binding(
            get: { AudiobookExportSettings.nearestMP3Kbps(mp3BitrateKbps) },
            set: { mp3BitrateKbps = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            SettingsSection(title: "Narration", footer: SharedSettingsCopy.narrationFooter) {
                SettingsVoiceCardRow(title: SharedSettingsCopy.narrationVoiceLabel, voiceID: $bookVM.defaultBookVoice)
                if bookVM.defaultBookVoice != vm.selectedVoice {
                    SettingsButtonRow(
                        title: "Match your speaking voice",
                        detail: "Narrate books with \(DashboardViewModel.voiceName(for: vm.selectedVoice)).",
                        systemImage: "arrow.triangle.2.circlepath",
                        buttonTitle: SharedSettingsCopy.matchSpeakingVoiceButton
                    ) {
                        bookVM.defaultBookVoice = vm.selectedVoice
                    }
                }
                SettingsSliderRow(
                    title: "Narration Speed",
                    value: $bookVM.defaultBookSpeed,
                    range: 0.75 ... 2.0,
                    step: 0.05,
                    valueLabel: PlayerSpeedMenu.label(bookVM.defaultBookSpeed)
                )
                SettingsSliderRow(
                    title: "Pause Length",
                    value: $bookVM.defaultBookPauseScale,
                    range: PauseScale.range,
                    step: PauseScale.step,
                    valueLabel: PauseScale.label(bookVM.defaultBookPauseScale),
                    detail: "How long narration pauses between sentences and paragraphs."
                )
            }
            if SpeechEngineID.isMingVoice(bookVM.defaultBookVoice) {
                SettingsNoticeRow(text: SharedSettingsCopy.mingNarrationNote, kind: .info, systemImage: "hourglass")
            }
            SettingsSection(title: "Export quality", footer: SharedSettingsCopy.exportFooter) {
                qualityRow("M4B Quality", detail: "Bitrate for M4B audiobooks.", selection: $bitrateKbps, options: AudiobookExportSettings.bitrateOptionsKbps)
                if includesMP3Quality {
                    qualityRow("MP3 Quality", detail: "Bitrate for MP3 exports.", selection: mp3Selection, options: AudiobookExportSettings.mp3BitrateOptionsKbps)
                }
            }
        }
    }

    private func qualityRow(_ title: String, detail: String, selection: Binding<Int>, options: [Int]) -> some View {
        SettingsPickerRow(title: title, detail: detail, systemImage: "dial.medium", valueLabel: "\(selection.wrappedValue) kbps") {
            Picker(title, selection: selection) {
                ForEach(options, id: \.self) { kbps in
                    Text("\(kbps) kbps").tag(kbps)
                }
            }
            .pickerStyle(.inline)
        }
    }
}

struct AppearanceLookSection: View {
    @EnvironmentObject var vm: DashboardViewModel

    private static let themeOptions = ["system", "light", "dark"]

    var body: some View {
        SettingsSection(title: "Look") {
            SettingsSegmentedRow(
                title: "Theme",
                detail: "Follow macOS or pick a fixed appearance.",
                systemImage: "circle.lefthalf.filled",
                selection: $vm.appTheme,
                options: Self.themeOptions,
                label: { $0.capitalized }
            )
            SettingsValueRow(title: "Accent", detail: SharedSettingsCopy.accentDetail, systemImage: "paintpalette") {
                HStack(spacing: 4) {
                    ForEach(AccentColorOption.allCases, id: \.self) { option in
                        AccentSwatchButton(option: option, isSelected: vm.accentColorID == option) {
                            vm.accentColorID = option
                        }
                    }
                }
            }
            SettingsValueRow(title: "App Icon", detail: "Changes in the Dock and Finder immediately.", systemImage: "app.badge") {
                HStack(spacing: 12) {
                    ForEach(AppIconOption.allCases) { option in
                        AppIconChoiceButton(option: option, isSelected: vm.appIconID == option) {
                            vm.appIconID = option
                        }
                    }
                }
            }
        }
    }
}

struct IdentityFormSection: View {
    @Binding var draft: IdentityDraft
    var requiresSave = true

    @EnvironmentObject var identity: IdentityService
    @State private var submitting = false
    @State private var saved = false
    @State private var submitError: String?

    var body: some View {
        SettingsSection(title: "About you", footer: IdentityDraft.purposeNote) {
            SettingsValueRow(title: "Name", systemImage: "person") {
                TextField("Name", text: $draft.name, prompt: Text("Your name"))
                    .labelsHidden()
                    .textContentType(.name)
                    .settingsField(width: 280)
            }
            SettingsValueRow(title: "Email", systemImage: "envelope") {
                TextField("Email", text: $draft.email, prompt: Text("you@example.com"))
                    .labelsHidden()
                    .textContentType(.emailAddress)
                    .disableAutocorrection(true)
                    .settingsField(width: 280)
            }
            if requiresSave {
                SettingsRowShell(title: "Save changes", detail: "Updates the name and email stored on this Mac.", systemImage: "checkmark.circle") {
                    HStack(spacing: 10) {
                        if submitting {
                            ProgressView().controlSize(.small)
                        }
                        if saved {
                            StatusChip(text: "Saved", kind: .success, systemImage: "checkmark")
                        }
                        Button("Save") { save() }
                            .buttonStyle(.voqoraFilled)
                            .disabled(!draft.canSave(storedName: identity.name, storedEmail: identity.email) || submitting)
                    }
                }
            }
            if let message = submitError ?? draft.errorMessage {
                SettingsNoticeRow(text: message, kind: submitError == nil ? .warning : .danger)
            }
        }
        .onAppear {
            if draft == IdentityDraft() {
                draft = IdentityDraft(name: identity.name ?? "", email: identity.email ?? "")
            }
        }
        .onChange(of: draft) { _, _ in
            saved = false
            submitError = nil
        }
    }

    private func save() {
        submitError = nil
        saved = false
        submitting = true
        Task {
            defer { submitting = false }
            do {
                saved = try await draft.commit(to: identity)
            } catch {
                submitError = (error as? IdentityService.IdentityError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

struct AnalyticsSettingRow: View {
    @EnvironmentObject var vm: DashboardViewModel
    @AppStorage(MetricsService.analyticsEnabledKey) private var analyticsEnabled = false
    @State private var confirmingOptOut = false

    var body: some View {
        SettingsSwitchRow(
            title: "Share Usage Analytics",
            detail: SharedSettingsCopy.analyticsDetail,
            systemImage: "chart.bar",
            isOn: Binding(
                get: { analyticsEnabled },
                set: { enabled in
                    if enabled {
                        analyticsEnabled = true
                    } else {
                        confirmingOptOut = true
                    }
                }
            )
        )
        .sheet(isPresented: $confirmingOptOut) {
            AnalyticsOptOutSheet()
                .environmentObject(vm)
        }
    }
}

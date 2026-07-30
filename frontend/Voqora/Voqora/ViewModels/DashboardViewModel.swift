import AppKit
import ApplicationServices
import Combine
import SwiftUI

@MainActor
class DashboardViewModel: ObservableObject {
    /// A one-time release migration for the new Voqora app identity. A prior
    /// development build could leave a non-English voice in shared defaults;
    /// every fresh v1.1 install and every upgrade from that build must begin
    /// with the same predictable US-English voice.
    /// v8 is deliberately higher than the public v1 migration so the private
    /// multilingual branch preserves the same predictable Bella-first start
    /// rather than reviving a voice from a development build.
    private static let voiceDefaultsMigrationVersion = 8
    private static let voiceDefaultsMigrationKey = "voiceDefaultsMigrationVersion"

    private static let supportedVoiceIDs: Set<String> = [
        "af_bella", "af_sarah", "am_adam", "am_michael",
        "bf_emma", "bf_isabella", "bm_george", "bm_lewis",
    ]

    static func applyVoiceDefaultsMigrationIfNeeded(defaults: UserDefaults = .standard) -> Bool {
        let needsReleaseMigration = defaults.integer(forKey: voiceDefaultsMigrationKey) < voiceDefaultsMigrationVersion
        let hasUnsupportedSelectedVoice = !supportedVoiceIDs.contains(
            defaults.string(forKey: "selectedVoice") ?? "af_bella"
        )
        let hasUnsupportedBookVoice = !supportedVoiceIDs.contains(
            defaults.string(forKey: "defaultBookVoice") ?? "af_bella"
        )

        guard needsReleaseMigration || hasUnsupportedSelectedVoice || hasUnsupportedBookVoice else {
            return false
        }

        // A versioned release migration resets both choices once. Afterwards,
        // preserve an explicit supported choice, but never render an orphaned
        // multilingual/legacy identifier that this public build cannot play.
        if needsReleaseMigration || hasUnsupportedSelectedVoice {
            defaults.set("af_bella", forKey: "selectedVoice")
        }
        if needsReleaseMigration || hasUnsupportedBookVoice {
            defaults.set("af_bella", forKey: "defaultBookVoice")
        }
        if needsReleaseMigration {
            defaults.set(false, forKey: "autoDetectLanguage")
            defaults.set(voiceDefaultsMigrationVersion, forKey: voiceDefaultsMigrationKey)
        }
        return true
    }

    // Dependencies
    private let backend: BackendService
    private let system: SystemService
    let audio: AudioService
    private let history: HistoryManager

    // State
    @Published var status: AppStatus = .ready
    @Published var isBackendOnline = false
    @Published var isBackendInitializing = true // Start as initializing
    @Published var isModelLoaded = false        // Model in ONNX session RAM
    /// A concise recovery message when the app-owned local engine exits before
    /// it can answer health checks. It keeps a damaged/blocked backend from
    /// looking like an indefinitely blank player while automatic retries run.
    @Published private(set) var backendRecoveryMessage: String?
    @Published var selectedTab: String? = "home"
    /// A file-action confirmation is deliberately separate from playback state.
    /// Saving a clip must not make a still-playing session look idle or failed.
    @Published private(set) var actionFeedback: String?

    /// Set after init by VoqoraApp so the TTS speak path can stop any audiobook playback.
    weak var audiobookVM: AudiobookViewModel?

    @AppStorage("selectedVoice") var selectedVoice = "af_bella"
    /// When on, the language of the text being spoken is auto-detected (via Apple's
    /// on-device NLLanguageRecognizer) and a matching voice is chosen automatically.
    /// Off by default so every new install starts with Bella. Users can opt in
    /// from onboarding or Preferences when they want matching-language speech.
    @AppStorage("autoDetectLanguage") var autoDetectLanguage = false
    @AppStorage("speechSpeed") var speechSpeed = 1.0
    @AppStorage("speechVolume") var speechVolume = 1.0
    @AppStorage("enableDucking") var enableDucking = true
    @AppStorage("cleanURLs") var cleanURLs = true
    @AppStorage("appTheme") var appTheme = "system" // system, light, dark
    @AppStorage("telemetryEnabled") var telemetryEnabled = true
    @AppStorage("selectedFontName") var selectedFontName = "System Rounded"

    /// Helper to get Font
    func appFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch selectedFontName {
        case "System Rounded":
            .system(size: size, weight: weight, design: .rounded)
        case "System Mono":
            .system(size: size, weight: weight, design: .monospaced)
        case "System Serif":
            .system(size: size, weight: weight, design: .serif)
        case "System Standard":
            .system(size: size, weight: weight, design: .default)
        case "Poppins":
            .custom(poppinsFontName(weight), size: size)
        default:
            .custom(selectedFontName, size: size).weight(weight)
        }
    }

    /// Only Black/Bold/Light/Medium/Regular ship in Resources/Fonts — map every
    /// other Font.Weight to its nearest bundled file rather than a name that
    /// doesn't exist (SwiftUI silently falls back to the system font otherwise,
    /// which broke `.semibold` and `.thin` labels like the dashboard clock).
    private func poppinsFontName(_ weight: Font.Weight) -> String {
        switch weight {
        case .black: "Poppins-Black"
        case .heavy: "Poppins-Black"
        case .bold: "Poppins-Bold"
        case .semibold: "Poppins-Bold"
        case .medium: "Poppins-Medium"
        case .light: "Poppins-Light"
        case .thin: "Poppins-Light"
        case .ultraLight: "Poppins-Light"
        default: "Poppins-Regular"
        }
    }

    /// A selectable Kokoro voice. Mirrors the backend catalog in
    /// `backend/app/services/languages.py` (single source of truth for which
    /// voices render cleanly under espeak-ng). Japanese is intentionally absent —
    /// espeak has no kanji G2P. See journal.md.
    struct VoiceOption: Identifiable, Hashable {
        let id: String // e.g. "ff_siwis"
        let name: String // "Siwis"
        let flag: String // "🇫🇷"
        let language: String // "French"
        let beta: Bool // true → label "(Beta)"

        /// "🇫🇷 Siwis" or "🇨🇳 Xiaoxiao (Beta)".
        var display: String {
            beta ? "\(flag) \(name) (Beta)" : "\(flag) \(name)"
        }
    }

    /// One row per language for building a grouped picker.
    struct LanguageGroup: Identifiable, Hashable {
        let id: String // language name (stable, unique)
        let flag: String
        let beta: Bool
        let voices: [VoiceOption]
    }

    /// Full curated catalog, ordered by language. Legacy English voices stay
    /// first so existing audiobooks (which persist a voice id) keep working.
    /// `nonisolated`: immutable Sendable data read by nonisolated helpers/tests.
    nonisolated static let voiceCatalog: [VoiceOption] = [
        // American English
        .init(id: "af_bella", name: "Bella", flag: "🇺🇸", language: "English (US)", beta: false),
        .init(id: "af_sarah", name: "Sarah", flag: "🇺🇸", language: "English (US)", beta: false),
        .init(id: "am_adam", name: "Adam", flag: "🇺🇸", language: "English (US)", beta: false),
        .init(id: "am_michael", name: "Michael", flag: "🇺🇸", language: "English (US)", beta: false),
        .init(id: "af_heart", name: "Heart", flag: "🇺🇸", language: "English (US)", beta: false),
        .init(id: "af_nicole", name: "Nicole", flag: "🇺🇸", language: "English (US)", beta: false),
        .init(id: "af_aoede", name: "Aoede", flag: "🇺🇸", language: "English (US)", beta: false),
        .init(id: "af_kore", name: "Kore", flag: "🇺🇸", language: "English (US)", beta: false),
        .init(id: "am_fenrir", name: "Fenrir", flag: "🇺🇸", language: "English (US)", beta: false),
        .init(id: "am_puck", name: "Puck", flag: "🇺🇸", language: "English (US)", beta: false),
        // British English
        .init(id: "bf_emma", name: "Emma", flag: "🇬🇧", language: "English (UK)", beta: false),
        .init(id: "bf_isabella", name: "Isabella", flag: "🇬🇧", language: "English (UK)", beta: false),
        .init(id: "bm_george", name: "George", flag: "🇬🇧", language: "English (UK)", beta: false),
        .init(id: "bm_lewis", name: "Lewis", flag: "🇬🇧", language: "English (UK)", beta: false),
        .init(id: "bm_fable", name: "Fable", flag: "🇬🇧", language: "English (UK)", beta: false),
        // Spanish
        .init(id: "ef_dora", name: "Dora", flag: "🇪🇸", language: "Spanish", beta: false),
        .init(id: "em_alex", name: "Alex", flag: "🇪🇸", language: "Spanish", beta: false),
        // French
        .init(id: "ff_siwis", name: "Siwis", flag: "🇫🇷", language: "French", beta: false),
        // Italian
        .init(id: "if_sara", name: "Sara", flag: "🇮🇹", language: "Italian", beta: false),
        .init(id: "im_nicola", name: "Nicola", flag: "🇮🇹", language: "Italian", beta: false),
        // Brazilian Portuguese
        .init(id: "pf_dora", name: "Dora", flag: "🇧🇷", language: "Portuguese", beta: false),
        .init(id: "pm_alex", name: "Alex", flag: "🇧🇷", language: "Portuguese", beta: false),
        // Hindi
        .init(id: "hf_alpha", name: "Aanya", flag: "🇮🇳", language: "Hindi", beta: false),
        .init(id: "hf_beta", name: "Diya", flag: "🇮🇳", language: "Hindi", beta: false),
        .init(id: "hm_omega", name: "Arjun", flag: "🇮🇳", language: "Hindi", beta: false),
        .init(id: "hm_psi", name: "Kabir", flag: "🇮🇳", language: "Hindi", beta: false),
        // Mandarin (Beta)
        .init(id: "zf_xiaoxiao", name: "Xiaoxiao", flag: "🇨🇳", language: "Mandarin", beta: true),
        .init(id: "zm_yunyang", name: "Yunyang", flag: "🇨🇳", language: "Mandarin", beta: true),
    ]

    /// Voices grouped by language, preserving catalog order, for a sectioned picker.
    static let languageGroups: [LanguageGroup] = {
        var order: [String] = []
        var byLang: [String: [VoiceOption]] = [:]
        for v in voiceCatalog {
            if byLang[v.language] == nil {
                order.append(v.language)
            }
            byLang[v.language, default: []].append(v)
        }
        return order.map { lang in
            let voices = byLang[lang] ?? []
            return LanguageGroup(id: lang, flag: voices.first?.flag ?? "",
                                 beta: voices.first?.beta ?? false, voices: voices)
        }
    }()

    /// Back-compat flat list of (id, display) tuples (used by older pickers/tests).
    static let availableVoices: [(id: String, display: String)] =
        voiceCatalog.map { ($0.id, $0.display) }

    var availableVoices: [(id: String, display: String)] {
        Self.availableVoices
    }

    static let voicesByID: [String: VoiceOption] =
        Dictionary(uniqueKeysWithValues: voiceCatalog.map { ($0.id, $0) })

    /// Voice-id first-letter → espeak language code. MUST mirror the backend
    /// `_PREFIX_TO_ESPEAK` in languages.py (Japanese intentionally absent).
    /// `nonisolated` so the pure helpers below (and LanguageDetector) can read it.
    nonisolated static let voicePrefixToLang: [Character: String] = [
        "a": "en-us", "b": "en-gb", "e": "es", "f": "fr-fr",
        "h": "hi", "i": "it", "p": "pt-br", "z": "cmn",
    ]

    /// The espeak language code a voice renders in (derived from its prefix).
    /// `nonisolated` (pure, reads only immutable static data) so LanguageDetector
    /// and tests can call it off the main actor.
    nonisolated static func langCode(forVoice id: String) -> String {
        guard let first = id.first else { return "en-us" }
        return voicePrefixToLang[first] ?? "en-us"
    }

    /// First (default) voice for a given espeak language code, or nil if none.
    nonisolated static func defaultVoice(forLang code: String) -> String? {
        voiceCatalog.first { langCode(forVoice: $0.id) == code }?.id
    }

    /// A native-language pangram-ish sample sentence for previewing a voice,
    /// so e.g. a French voice is heard reading French rather than accented English.
    nonisolated static func sampleSentence(forVoice id: String) -> String {
        switch langCode(forVoice: id) {
        case "es": "El veloz zorro marrón salta sobre el perro perezoso."
        case "fr-fr": "Le vif renard brun saute par-dessus le chien paresseux."
        case "it": "La rapida volpe marrone salta sopra il cane pigro."
        case "pt-br": "A rápida raposa marrom salta sobre o cão preguiçoso."
        case "hi": "तेज़ भूरी लोमड़ी आलसी कुत्ते के ऊपर कूद जाती है।"
        case "cmn": "敏捷的棕色狐狸跳过了那只懒狗。"
        default: "The quick brown fox jumps over the lazy dog."
        }
    }

    /// Human-friendly display for the currently-selected voice ("🇺🇸 Bella").
    /// Falls back to a humanized id for any voice not in the catalog.
    var currentVoiceDisplay: String {
        if let v = Self.voicesByID[selectedVoice] {
            return v.display
        }
        return selectedVoice.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Computed property for online status
    var isOnline: Bool {
        isBackendOnline
    }

    private var currentSpeakTask: Task<Void, Never>?
    /// A cancelled request must not be able to stop or overwrite newer audio.
    private var speakGeneration = 0
    private var heartbeatTask: Task<Void, Never>?
    /// Background timer for the "1s after playback ended, restore music
    /// volume" behavior. Cancelled on re-entrance so a quick stop/start
    /// doesn't unduck mid-playback. See HARD-021.
    private var unduckTask: Task<Void, Never>?
    /// Auto-clear timer for the "Nothing to play" error pill in togglePlayback.
    /// Cancelled on re-entrance for the same reason. See HARD-021.
    private var errorResetTask: Task<Void, Never>?
    private(set) var errorResetGeneration = 0
    private var actionFeedbackTask: Task<Void, Never>?

    /// True between prepareForStream() and the first audio chunk of a TTS request.
    /// While true the UI stays in `.thinking` (loading) rather than flipping to
    /// `.speaking` at 0:00 — important when the model is cold (idle-unloaded) or a
    /// slow voice is generating, which otherwise looked frozen. Defaults false so
    /// non-TTS playback (audiobook, seek, resume) is unaffected.
    private var awaitingFirstChunk = false

    /// Records whether the one-time backend health and prewarm work has begun.
    /// This keeps repeated window appearances from creating duplicate loops.
    private(set) var backgroundWorkStarted = false

    private var cancellables = Set<AnyCancellable>()

    init(
        backend: BackendService,
        system: SystemService,
        audio: AudioService,
        history: HistoryManager,
        startsBackgroundWork: Bool = !RuntimeEnvironment.isRunningTests
    ) {
        _ = Self.applyVoiceDefaultsMigrationIfNeeded()
        self.backend = backend
        self.system = system
        self.audio = audio
        self.history = history

        setupBindings()
        if startsBackgroundWork {
            startBackgroundWork()
        }
    }

    /// Start backend work once the bundled server is available. Starting while
    /// LaunchManager replaces its files causes an avoidable launch/kill loop
    /// on fresh installs, and running it in unit tests needlessly heats up the
    /// machine.
    func startBackgroundWork() {
        guard !backgroundWorkStarted else { return }
        backgroundWorkStarted = true
        startHeartbeat()
        startPrewarmObservers()
    }

    private func setupBindings() {
        // Sync Audio Service state to local status
        audio.$isPlaying
            .sink { [weak self] isPlaying in
                guard let self else { return }
                if isPlaying {
                    // Stay in .thinking until real audio flows, so a cold-model
                    // reload / slow voice shows "loading", not a frozen 0:00 wave.
                    if !awaitingFirstChunk {
                        status = .speaking
                    }
                    if enableDucking {
                        system.setMusicVolume(ducked: true)
                    }
                    // Cancel any pending unduck — we're playing again.
                    unduckTask?.cancel()
                    unduckTask = nil
                } else {
                    if status == .speaking || status == .paused {
                        // BUG FIX: use the explicit playbackCompleted flag instead of
                        // unreliable currentTime thresholds (which were always 0 before).
                        // playbackCompleted is set true only when the last buffer drains
                        // naturally; manual pause leaves it false.
                        status = audio.playbackCompleted ? .ready : .paused
                    }

                    if enableDucking {
                        unduckTask?.cancel()
                        unduckTask = Task { [weak self] in
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            guard !Task.isCancelled, let self else { return }
                            if !audio.isPlaying {
                                system.setMusicVolume(ducked: false)
                            }
                        }
                    }
                }
            }
            .store(in: &cancellables)
    }

    func speakSelection(text: String? = nil) async {
        print("⌨️ DashboardViewModel: speakSelection triggered")
        if let text {
            await speak(text: text)
            return
        }
        // The global-hotkey path reads the current selection via the Accessibility
        // API. If the grant is missing (common after a reinstall — re-signing changes
        // the code signature macOS ties the grant to), getSelectedText() returns nil
        // and the app would silently do nothing. Detect it and guide the user instead.
        guard AXIsProcessTrusted() else {
            print("⚠️ DashboardViewModel: Accessibility not granted.")
            flashError("Enable Accessibility for Voqora in System Settings to read selected text.", seconds: 8)
            promptForAccessibility()
            return
        }
        guard let text = await SelectionManager.getSelectedText(), !text.isEmpty else {
            print("⚠️ DashboardViewModel: No text found in selection.")
            flashError("Select some text first, then press the shortcut.")
            return
        }
        print("🎤 DashboardViewModel: Sending \(text.count) chars to backend...")
        await speak(text: text)
    }

    /// Show a transient error in the status label, auto-clearing back to .ready.
    private func flashError(_ message: String, seconds: Double = 4) {
        clearActionFeedback()
        status = .error(message)
        errorResetTask?.cancel()
        errorResetGeneration &+= 1
        let generation = errorResetGeneration
        errorResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            resetPlaybackError(for: generation)
        }
    }

    /// Makes stale status timers harmless after quick repeated actions.
    func resetPlaybackError(for generation: Int) {
        guard generation == errorResetGeneration else { return }
        if case .error = status { status = .ready }
    }

    /// Show the macOS Accessibility prompt and open the relevant Settings pane.
    private func promptForAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Speak `text`. When `forcedVoice` is set, that exact voice is used and
    /// auto-detect is bypassed — used to preview a specific voice (onboarding).
    func speak(text: String, forcedVoice: String? = nil) async {
        clearActionFeedback()
        guard isBackendOnline else {
            backend.start()
            flashError("Voqora is still starting. Try again in a moment.")
            return
        }

        // The newest request always wins. The generation token keeps a
        // cancelled older request from stopping the newer playback in defer.
        speakGeneration &+= 1
        let generation = speakGeneration
        currentSpeakTask?.cancel()

        // Mutual exclusion: a hotkey TTS request always interrupts audiobook playback.
        // The backend `/speak` endpoint also acquires a preemption lock so any in-flight
        // audiobook generation pauses between pages. Here we fade-stop frontend
        // playback (P11) instead of an abrupt stop so there's no click.
        if let avm = audiobookVM, avm.nowPlaying != nil {
            avm.audio.fadeOutAndStop(over: 0.12)
            avm.nowPlaying = nil
            avm.currentTranscript = nil
        }

        currentSpeakTask = Task { [weak self] in
            guard let self else { return }
            defer {
                awaitingFirstChunk = false
                if Task.isCancelled, generation == self.speakGeneration {
                    if self.status == .thinking {
                        self.status = .ready
                    }
                    self.audio.stop()
                }
                if generation == self.speakGeneration {
                    self.currentSpeakTask = nil
                }
            }
            print("DEBUG [DashboardVM] Starting new speak task")
            status = .thinking
            // Hold the loading state until the first chunk plays (see the
            // $isPlaying sink); prepareForStream() flips isPlaying true early.
            awaitingFirstChunk = true

            let cleaned = TextProcessor.sanitize(text, options: .init(cleanURLs: cleanURLs, cleanHandles: true, fixLigatures: true, expandAbbr: true, expandNumbers: true))
            audio.setEstimatedDuration(textLength: cleaned.count, speed: speechSpeed)

            // forcedVoice wins (voice preview); else auto-detect the text language
            // and pick a matching voice when enabled; else the explicit choice.
            let effectiveVoice = forcedVoice
                ?? (autoDetectLanguage
                    ? LanguageDetector.voiceForText(cleaned, fallback: selectedVoice)
                    : selectedVoice)

            // This resets the AudioService buffers
            audio.prepareForStream()

            let stream = backend.streamAudio(
                text: cleaned,
                voice: effectiveVoice,
                speed: speechSpeed,
                volume: speechVolume
            )

            do {
                for try await chunk in stream {
                    // Check if this task was cancelled while we were waiting for a chunk
                    guard !Task.isCancelled, generation == self.speakGeneration else {
                        print("DEBUG [DashboardVM] Task cancelled, exiting loop")
                        return
                    }

                    // First real audio chunk → now we're genuinely speaking.
                    awaitingFirstChunk = false
                    if status == .thinking {
                        status = .speaking
                    }
                    audio.playChunk(chunk, volume: Float(speechVolume))
                }
            } catch {
                guard !Task.isCancelled, generation == self.speakGeneration else { return }
                awaitingFirstChunk = false
                audio.stop()
                status = .error("Voqora could not generate audio. Check that the local engine is ready and try again.")
                return
            }

            if !Task.isCancelled, generation == self.speakGeneration {
                audio.finishStream()
                // Zero-audio edge case (e.g. a voice produced an empty stream):
                // the $isPlaying sink only resets .speaking/.paused, so a request
                // that never emitted a chunk would otherwise stick on .thinking.
                if status == .thinking {
                    status = .ready
                }
                history.log(text: cleaned, voice: effectiveVoice)
                // audio_seconds is the rendered length (PCM frames / sample rate),
                // computed by AudioService after finishStream(). See spec §10.
                MetricsService.shared.trackGeneration(
                    chars: cleaned.count,
                    voice: effectiveVoice,
                    speed: speechSpeed,
                    audioSeconds: audio.renderedAudioSeconds
                )
            }
        }
    }

    /// Translate the local HTTP contract into an action someone can take.
    /// A validation response is not a network failure, and describing it that
    /// way sends people looking for an installer/network fix when they only
    /// need to shorten or reselect a passage.
    static func speechFailureMessage(for error: Error) -> String {
        guard let streamError = error as? BackendService.StreamError else {
            return "Voqora could not reach the local speech engine. Try again."
        }
        switch streamError {
        case .rejectedResponse(let statusCode) where statusCode == 422:
            return "That selection is empty or too long. Try a shorter passage."
        case .rejectedResponse(let statusCode) where statusCode == 503:
            return "Voqora's local speech engine is still warming up. Try again in a moment."
        case .emptyAudio:
            return "Voqora did not receive playable audio. Try the selection again."
        default:
            return "Voqora could not reach the local speech engine. Try again."
        }
    }

    func togglePlayback() {
        if let audiobookVM, audiobookVM.nowPlaying != nil {
            audiobookVM.togglePlayback()
            return
        }
        if audio.duration == 0 {
            flashError("Nothing to play. Select text and press Cmd+Shift+.", seconds: 3)
        } else {
            audio.togglePause()
        }
    }

    /// Stops streams before the audio engine so a late network chunk cannot
    /// make playback resume after the user explicitly pressed Stop.
    func stopPlayback() {
        speakGeneration &+= 1
        currentSpeakTask?.cancel()
        currentSpeakTask = nil
        awaitingFirstChunk = false

        if let audiobookVM, audiobookVM.nowPlaying != nil || audiobookVM.isPreparingPlayback {
            audiobookVM.stopPlayback()
        } else {
            audio.stop()
        }

        clearActionFeedback()
        if status == .speaking || status == .paused || status == .thinking {
            status = .ready
        }
    }

    func startHeartbeat() {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task {
            var wasOnline = false
            while !Task.isCancelled {
                let health = await backend.checkHealth()
                let isNowOnline = health.isOnline
                isBackendOnline = isNowOnline
                isModelLoaded = health.isModelLoaded

                // Detect backend crash: was online, now offline
                if wasOnline && !isNowOnline {
                    print("⚠️ DashboardViewModel: Backend crash detected, cancelling stream")
                    stopPlayback()
                }

                wasOnline = isNowOnline

                if isNowOnline {
                    isBackendInitializing = false
                    backend.clearLaunchFailure()
                    backendRecoveryMessage = nil
                } else {
                    let launching = backend.isLaunching
                    isBackendInitializing = launching
                    backendRecoveryMessage = backend.lastLaunchFailure
                    backend.start()
                }

                // Poll aggressively (500 ms) while backend is offline/starting up,
                // then relax to 5 s once stable. This cuts the "waiting for backend"
                // window from up to 5 s to under 500 ms in normal operation.
                let delay: UInt64 = isNowOnline ? 5_000_000_000 : 500_000_000
                try? await Task.sleep(nanoseconds: delay)
            }
        }
    }

    func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    func exportLastClip() {
        do {
            let url = try audio.exportToDesktop()
            showActionFeedback("Saved \(url.lastPathComponent) to Desktop")
        } catch {
            flashError(error.localizedDescription)
        }
    }

    /// Pre-warm only when Voqora becomes active. The app does not poll or read
    /// the clipboard in the background: it waits for an explicit shortcut or
    /// document action before touching user text.
    private func startPrewarmObservers() {
        // App focus only loads the model. No lookahead is possible because
        // Voqora intentionally has no text until the user asks it to speak.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self, isBackendOnline, !self.isModelLoaded else { return }
                Task { await self.backend.prewarm() }
            }
            .store(in: &cancellables)
    }

    /// --- FONT PANEL SUPPORT ---
    func showFontPanel() {
        NSFontManager.shared.target = self
        NSFontManager.shared.action = #selector(changeFont(_:))
        NSFontPanel.shared.orderFront(nil)
        NSFontPanel.shared.isEnabled = true
    }

    @objc func changeFont(_ sender: Any?) {
        guard let fontManager = sender as? NSFontManager else { return }
        let newFont = fontManager.convert(.systemFont(ofSize: 12))
        selectedFontName = newFont.familyName ?? "System Standard"
    }

    func exportLogs() {
        do {
            let urls = try backend.exportLogs()
            NSWorkspace.shared.activateFileViewerSelecting(urls)
            showActionFeedback("Saved \(urls.count) debug log\(urls.count == 1 ? "" : "s") to Desktop")
        } catch {
            flashError(error.localizedDescription)
        }
    }

    private func showActionFeedback(_ message: String) {
        actionFeedbackTask?.cancel()
        actionFeedback = message
        actionFeedbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.actionFeedback = nil
        }
    }

    private func clearActionFeedback() {
        actionFeedbackTask?.cancel()
        actionFeedbackTask = nil
        actionFeedback = nil
    }
}

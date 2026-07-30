import Combine
import Foundation
import SwiftUI

@MainActor
class DashboardViewModel: ObservableObject {
    /// A one-time release migration for the new Voqora app identity. A prior
    /// development build could leave a non-English voice in shared defaults;
    /// every fresh v1 install and every upgrade from that build must begin with
    /// the same predictable US-English voice.
    // Version 7 supersedes the short-lived builds that could record v6 while
    // retaining a stale multilingual development voice. It resets only once,
    // then preserves every explicit choice made afterwards.
    private static let voiceDefaultsMigrationVersion = 7
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
            defaults.set(voiceDefaultsMigrationVersion, forKey: voiceDefaultsMigrationKey)
        }
        return true
    }

    // Dependencies
    private let backend: BackendService
    private let system: SystemService
    let audio: AudioService
    private let history: HistoryManager
    private let defaults: UserDefaults

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
    /// Confirmation for a completed file action. Kept separate from playback
    /// status so saving while audio is playing never makes the player look idle.
    @Published private(set) var actionFeedback: String?

    /// Set after init by VoqoraApp so the TTS speak path can stop any audiobook playback.
    weak var audiobookVM: AudiobookViewModel?

    /// Explicit persistence keeps the visible player voice deterministic. The
    /// former `@AppStorage` wrapper could restore a stale cached value after a
    /// migration, so only an actual user selection writes this preference.
    @Published var selectedVoice: String {
        didSet {
            defaults.set(selectedVoice, forKey: "selectedVoice")
        }
    }
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
            .custom("Poppins-Regular", size: size).weight(weight)
        default:
            .custom(selectedFontName, size: size).weight(weight)
        }
    }

    static let availableVoices: [(id: String, display: String)] = [
        ("af_bella", "🇺🇸 Bella"), ("af_sarah", "🇺🇸 Sarah"),
        ("am_adam", "🇺🇸 Adam"), ("am_michael", "🇺🇸 Michael"),
        ("bf_emma", "🇬🇧 Emma"), ("bf_isabella", "🇬🇧 Isabella"),
        ("bm_george", "🇬🇧 George"), ("bm_lewis", "🇬🇧 Lewis"),
    ]

    var availableVoices: [(id: String, display: String)] { Self.availableVoices }

    /// Computed property for display
    var currentVoiceDisplay: String {
        selectedVoice.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Computed property for online status
    var isOnline: Bool {
        isBackendOnline
    }

    private var currentSpeakTask: Task<Void, Never>?
    /// Monotonic token for user speech requests. A cancelled older request
    /// must never stop or overwrite audio that belongs to the newer one.
    private var speakGeneration = 0
    private var heartbeatTask: Task<Void, Never>?
    /// Startup work must begin only after LaunchManager has installed the
    /// bundled server. Starting it while that directory is being replaced
    /// creates a launch/kill/poll loop on a fresh install.
    private(set) var backgroundWorkStarted = false
    /// Background timer for the "1s after playback ended, restore music
    /// volume" behavior. Cancelled on re-entrance so a quick stop/start
    /// doesn't unduck mid-playback. See HARD-021.
    private var unduckTask: Task<Void, Never>?
    /// Auto-clear timer for the "Nothing to play" error pill in togglePlayback.
    /// Cancelled on re-entrance for the same reason. See HARD-021.
    private var errorResetTask: Task<Void, Never>?
    private(set) var errorResetGeneration = 0
    private var actionFeedbackTask: Task<Void, Never>?

    private var cancellables = Set<AnyCancellable>()

    init(
        backend: BackendService,
        system: SystemService,
        audio: AudioService,
        history: HistoryManager,
        startsBackgroundWork: Bool = true,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        _ = Self.applyVoiceDefaultsMigrationIfNeeded(defaults: defaults)
        self.selectedVoice = defaults.string(forKey: "selectedVoice") ?? "af_bella"
        self.backend = backend
        self.system = system
        self.audio = audio
        self.history = history

        setupBindings()
        if startsBackgroundWork {
            startBackgroundWork()
        }
    }

    /// Starts the backend health loop and prewarm observers once. VoqoraApp
    /// calls this only after LaunchManager has extracted the bundled server;
    /// repeated view appearances are harmless.
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
                    status = .speaking
                    if enableDucking { system.setMusicVolume(ducked: true) }
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
                            if !self.audio.isPlaying {
                                self.system.setMusicVolume(ducked: false)
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
        guard let text = await SelectionManager.getSelectedText(), !text.isEmpty else {
            print("⚠️ DashboardViewModel: No text found in selection.")
            showTransientError("Select text in any app, then press Cmd+Shift+.")
            return
        }
        print("🎤 DashboardViewModel: Sending \(text.count) chars to backend...")
        await speak(text: text)
    }

    func speak(text: String) async {
        clearActionFeedback()
        guard isBackendOnline else {
            backend.start()
            showTransientError("Voqora is still starting. Try again in a moment.")
            return
        }

        // The newest selection always wins. The generation token prevents the
        // cancelled task's deferred cleanup from stopping the new playback.
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
                if Task.isCancelled, generation == self.speakGeneration {
                    if self.status == .thinking { self.status = .ready }
                    self.audio.stop()
                }
                if generation == self.speakGeneration {
                    self.currentSpeakTask = nil
                }
            }
            print("DEBUG [DashboardVM] Starting new speak task")
            status = .thinking

            let cleaned = TextProcessor.sanitize(text, options: .init(cleanURLs: cleanURLs, cleanHandles: true, fixLigatures: true, expandAbbr: true, expandNumbers: true))
            audio.setEstimatedDuration(textLength: cleaned.count, speed: speechSpeed)

            // This resets the AudioService buffers
            audio.prepareForStream()

            do {
                let stream = backend.streamAudio(
                    text: cleaned,
                    voice: selectedVoice,
                    speed: speechSpeed,
                    volume: speechVolume
                )
                var receivedAudio = false

                for try await chunk in stream {
                    guard !Task.isCancelled, generation == self.speakGeneration else {
                        return
                    }
                    if status == .thinking { status = .speaking }
                    audio.playChunk(chunk, volume: Float(speechVolume))
                    receivedAudio = true
                }

                guard !Task.isCancelled, generation == self.speakGeneration else { return }
                guard receivedAudio else {
                    audio.stop()
                    showTransientError("Voqora could not generate audio. Try again.")
                    return
                }

                audio.finishStream()
                history.log(text: cleaned, voice: selectedVoice)
                // audio_seconds is the rendered length (PCM frames / sample rate),
                // computed by AudioService after finishStream(). See spec §10.
                MetricsService.shared.trackGeneration(
                    chars: cleaned.count,
                    voice: selectedVoice,
                    speed: speechSpeed,
                    audioSeconds: audio.renderedAudioSeconds
                )
            } catch {
                guard !Task.isCancelled, generation == self.speakGeneration else { return }
                audio.stop()
                showTransientError(Self.speechFailureMessage(for: error))
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
        // The shared audio engine can be playing an audiobook while this view
        // is visible. Delegate to the book model so it persists the resume
        // point instead of treating a book like an anonymous TTS clip.
        if let audiobookVM, audiobookVM.nowPlaying != nil {
            audiobookVM.togglePlayback()
            return
        }
        if audio.duration == 0 {
            showTransientError("Nothing to play. Select text and press Cmd+Shift+.")
        } else {
            audio.togglePause()
        }
    }

    /// Stops the current product playback decisively. Cancelling the request
    /// before touching the audio engine is important: otherwise an in-flight
    /// TTS stream can append another buffer and resume after the user pressed
    /// the global Stop shortcut.
    func stopPlayback() {
        speakGeneration &+= 1
        currentSpeakTask?.cancel()
        currentSpeakTask = nil

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

    private func showTransientError(_ message: String) {
        clearActionFeedback()
        status = .error(message)
        // Auto-clear the error and return to READY after three seconds.
        // Cancellable so an earlier error cannot overwrite later app state.
        errorResetTask?.cancel()
        errorResetGeneration &+= 1
        let resetGeneration = errorResetGeneration
        errorResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.resetPlaybackError(for: resetGeneration)
        }
    }

    /// Applies an error reset only when it belongs to the latest playback
    /// attempt. This makes a stale timer harmless after quick repeated taps.
    func resetPlaybackError(for generation: Int) {
        guard generation == errorResetGeneration else { return }
        if case .error = status {
            status = .ready
        }
    }

    func exportLastClip() {
        do {
            let url = try audio.exportToDesktop()
            showActionFeedback("Saved \(url.lastPathComponent) to Desktop")
        } catch {
            showTransientError(error.localizedDescription)
        }
    }

    func exportLogs() {
        do {
            let urls = try backend.exportLogs()
            NSWorkspace.shared.activateFileViewerSelecting(urls)
            showActionFeedback("Saved \(urls.count) debug log\(urls.count == 1 ? "" : "s") to Desktop")
        } catch {
            showTransientError(error.localizedDescription)
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
                    currentSpeakTask?.cancel()
                    currentSpeakTask = nil
                    if status == .speaking || status == .thinking {
                        status = .ready
                    }
                    audio.stop()
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

    /// Pre-warm the model when Voqora becomes active, hiding the cold start
    /// without polling or reading the user's clipboard in the background.
    private func startPrewarmObservers() {
        // App focus only loads the model. No text is inspected until the user
        // explicitly activates the selected-text shortcut.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self, self.isBackendOnline, !self.isModelLoaded else { return }
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

}

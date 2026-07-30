import Combine
import SwiftUI

@MainActor
class DashboardViewModel: ObservableObject {
    /// A one-time release migration for the new Voqora app identity. A prior
    /// development build could leave a non-English voice in shared defaults;
    /// every fresh v1 install and every upgrade from that build must begin with
    /// the same predictable US-English voice.
    private static let voiceDefaultsMigrationVersion = 2
    private static let voiceDefaultsMigrationKey = "voiceDefaultsMigrationVersion"

    static func applyVoiceDefaultsMigrationIfNeeded(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.integer(forKey: voiceDefaultsMigrationKey) < voiceDefaultsMigrationVersion else {
            return false
        }

        defaults.set("af_bella", forKey: "selectedVoice")
        defaults.set("af_bella", forKey: "defaultBookVoice")
        defaults.set(voiceDefaultsMigrationVersion, forKey: voiceDefaultsMigrationKey)
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
    @Published var selectedTab: String? = "home"

    /// Set after init by VoqoraApp so the TTS speak path can stop any audiobook playback.
    weak var audiobookVM: AudiobookViewModel?

    // Clipboard monitoring for anticipatory pre-warm
    private var lastPasteboardChangeCount = NSPasteboard.general.changeCount

    @AppStorage("selectedVoice") var selectedVoice = "af_bella"
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
    private var heartbeatTask: Task<Void, Never>?
    /// Background timer for the "1s after playback ended, restore music
    /// volume" behavior. Cancelled on re-entrance so a quick stop/start
    /// doesn't unduck mid-playback. See HARD-021.
    private var unduckTask: Task<Void, Never>?
    /// Auto-clear timer for the "Nothing to play" error pill in togglePlayback.
    /// Cancelled on re-entrance for the same reason. See HARD-021.
    private var errorResetTask: Task<Void, Never>?

    private var cancellables = Set<AnyCancellable>()

    init(
        backend: BackendService,
        system: SystemService,
        audio: AudioService,
        history: HistoryManager,
        startsBackgroundWork: Bool = true
    ) {
        _ = Self.applyVoiceDefaultsMigrationIfNeeded()
        self.backend = backend
        self.system = system
        self.audio = audio
        self.history = history

        setupBindings()
        if startsBackgroundWork {
            startHeartbeat()
            startPrewarmObservers()
        }
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
        guard let text = SelectionManager.getSelectedText(), !text.isEmpty else {
            print("⚠️ DashboardViewModel: No text found in selection.")
            return
        }
        print("🎤 DashboardViewModel: Sending \(text.count) chars to backend...")
        await speak(text: text)
    }

    func speak(text: String) async {
        // --- FIX: Cancel the previous stream task if it exists ---
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

        currentSpeakTask = Task {
            defer {
                if Task.isCancelled {
                    if self.status == .thinking { self.status = .ready }
                    self.audio.stop()
                }
            }
            print("DEBUG [DashboardVM] Starting new speak task")
            status = .thinking

            let cleaned = TextProcessor.sanitize(text, options: .init(cleanURLs: cleanURLs, cleanHandles: true, fixLigatures: true, expandAbbr: true, expandNumbers: true))
            audio.setEstimatedDuration(textLength: cleaned.count, speed: speechSpeed)

            // This resets the AudioService buffers
            audio.prepareForStream()

            let stream = backend.streamAudio(
                text: cleaned,
                voice: selectedVoice,
                speed: speechSpeed,
                volume: speechVolume
            )

            for await chunk in stream {
                // Check if this task was cancelled while we were waiting for a chunk
                if Task.isCancelled {
                    print("DEBUG [DashboardVM] Task cancelled, exiting loop")
                    return
                }

                if status == .thinking { status = .speaking }
                audio.playChunk(chunk, volume: Float(speechVolume))
            }

            if !Task.isCancelled {
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
            }
        }
    }

    func togglePlayback() {
        if audio.duration == 0 {
            // Show the error message in the UI pill
            status = .error("Nothing to play. Select text and press Cmd+Shift+.")

            // Auto-clear the error and return to "READY" after 3 seconds.
            // Cancellable so a quick re-toggle doesn't trip the stale reset.
            errorResetTask?.cancel()
            errorResetTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled, let self else { return }
                if case let .error(msg) = self.status,
                   msg == "Nothing to play. Select text and press Cmd+Shift+." {
                    self.status = .ready
                }
            }
        } else {
            audio.togglePause()
        }
    }


    func startHeartbeat() {
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
                } else {
                    let launching = backend.isLaunching
                    isBackendInitializing = launching
                    await backend.start()
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

    /// Pre-warm the model before the user speaks, hiding the ~1.3 s cold-reload cost.
    ///
    /// Two signals trigger this:
    /// 1. The clipboard changes — user just copied text and will likely press the hotkey.
    /// 2. The app becomes active — user switched to Voqora to type/speak directly.
    ///
    /// In both cases the backend starts loading the ONNX model in the background.
    /// By the time the user actually presses the hotkey (typically 0.5–3 s later),
    /// the model is already warm and /speak returns audio with normal ~300 ms latency.
    private func startPrewarmObservers() {
        // Signal 1: clipboard change — always prewarm (model load + lookahead cache).
        // No !isModelLoaded guard: even when warm, we want to pre-compute the first
        // audio segment so /speak finds it cached and streams it in <20ms.
        Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                let current = NSPasteboard.general.changeCount
                guard current != self.lastPasteboardChangeCount else { return }
                self.lastPasteboardChangeCount = current
                guard self.isBackendOnline else { return }
                let text = NSPasteboard.general.string(forType: .string) ?? ""
                let voice = self.selectedVoice
                let speed = self.speechSpeed
                Task { await self.backend.prewarm(text: text, voice: voice, speed: speed) }
            }
            .store(in: &cancellables)

        // Signal 2: app focus — only loads the model (no lookahead; unknown text).
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

    func exportLogs() {
        Task {
            backend.exportLogs()
        }
    }
}

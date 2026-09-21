import ApplicationServices
import Combine
import Foundation
import SwiftUI

@MainActor
class DashboardViewModel: ObservableObject {
    // A one-time release migration for the new Voqora app identity. A prior
    // development build could leave a non-English voice in shared defaults;
    // every fresh v1 install and every upgrade from that build must begin with
    // the same predictable US-English voice.
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

    /// State
    @Published var status: AppStatus = .ready
    /// Consecutive "no text found" failures per frontmost app name — reset
    /// on success or on switching apps. See speakSelection().
    private var selectionFailuresByApp: [String: Int] = [:]
    @Published var isBackendOnline = false
    @Published var isBackendInitializing = true // Start as initializing
    @Published var isModelLoaded = false // Model in ONNX session RAM
    /// Last-seen NSPasteboard.changeCount, used only to detect *that* a copy
    /// happened — never to read what was copied. See startPrewarmObservers().
    private var lastPasteboardChangeCount = NSPasteboard.general.changeCount
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
    /// New installs must opt into cross-app Automation. Existing explicit
    /// UserDefaults values are preserved by @AppStorage.
    @AppStorage("enableDucking") var enableDucking = false
    @AppStorage("cleanURLs") var cleanURLs = true
    @AppStorage("appTheme") var appTheme = "system" // system, light, dark
    @AppStorage("selectedFontName") var selectedFontName = "Google Sans"
    @AppStorage("accentColorID") var accentColorID: AccentColorOption = .clay
    @AppStorage("appIconID") var appIconID: AppIconOption = .waveLight {
        didSet { appIconID.apply() }
    }

    /// The bundle version this profile last recorded seeing — compared
    /// against `CFBundleShortVersionString` on every launch so `VoqoraWindow`
    /// can detect "this launch is the first one after an update" and land on
    /// `AboutView`. Empty on a fresh profile, which is what keeps a brand
    /// new install's own first launch from being mistaken for an update.
    @AppStorage("lastSeenAppVersion") var lastSeenAppVersion: String = ""

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
            // The bundle ships five static Poppins weights (Light/Regular/
            // Medium/Bold/Black — registered via ATSApplicationFontsPath),
            // not a variable font. Asking `.weight(_)` to synthesize a
            // heavier/lighter weight on top of "Poppins-Regular" alone
            // fails silently in this environment (CoreText logs "Unable to
            // update Font Descriptor's weight" and the text doesn't render
            // at all) once enough distinct weights are requested. Picking
            // the actual matching file avoids synthesis entirely.
            .custom(Self.poppinsPostScriptName(for: weight), size: size)
        case "Google Sans":
            // Same static-weight-file constraint as Poppins above — five
            // bundled cuts (Light/Regular/Medium/Bold/Black, mixing the
            // "17pt" UI-optical-size static family with two Flex-derived
            // static instances for the tiers "17pt" doesn't ship), matched
            // by their real embedded PostScript name rather than the
            // on-disk filename, which differs from it.
            .custom(Self.googleSansPostScriptName(for: weight), size: size)
        default:
            .custom(selectedFontName, size: size).weight(weight)
        }
    }

    private static func poppinsPostScriptName(for weight: Font.Weight) -> String {
        switch weight {
        case .black, .heavy: "Poppins-Black"
        case .bold: "Poppins-Bold"
        case .semibold, .medium: "Poppins-Medium"
        case .light, .thin, .ultraLight: "Poppins-Light"
        default: "Poppins-Regular"
        }
    }

    private static func googleSansPostScriptName(for weight: Font.Weight) -> String {
        switch weight {
        case .black, .heavy: "GoogleSansFlex24pt-Black"
        case .bold: "GoogleSans17pt-Bold"
        case .semibold, .medium: "GoogleSans17pt-Medium"
        case .light, .thin, .ultraLight: "GoogleSansFlex24pt-Light"
        default: "GoogleSans17pt-Regular"
        }
    }

    static let availableVoices: [(id: String, display: String)] = [
        ("af_bella", "🇺🇸 Bella"), ("af_sarah", "🇺🇸 Sarah"),
        ("am_adam", "🇺🇸 Adam"), ("am_michael", "🇺🇸 Michael"),
        ("bf_emma", "🇬🇧 Emma"), ("bf_isabella", "🇬🇧 Isabella"),
        ("bm_george", "🇬🇧 George"), ("bm_lewis", "🇬🇧 Lewis"),
    ]

    var availableVoices: [(id: String, display: String)] {
        Self.availableVoices
    }

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
        selectedVoice = defaults.string(forKey: "selectedVoice") ?? "af_bella"
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
                    if enableDucking {
                        system.beginDucking { [weak self] message in
                            self?.showTransientError(message)
                        }
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
                                system.endDucking()
                            }
                        }
                    }
                }
            }
            .store(in: &cancellables)
    }

    func speakSelection(text: String? = nil) async {
        VoqoraLog.info("DashboardViewModel", "speakSelection triggered", ["explicitText": text != nil ? "true" : "false"])
        if let text {
            await speak(text: text)
            return
        }
        let frontApp = NSWorkspace.shared.frontmostApplication
        let frontAppName = frontApp?.localizedName ?? frontApp?.bundleIdentifier ?? "unknown"

        guard let text = await SelectionManager.getSelectedText(), !text.isEmpty else {
            VoqoraLog.warn("DashboardViewModel", "No text found in selection", ["axTrusted": AXIsProcessTrusted() ? "true" : "false", "app": frontAppName])
            if !AXIsProcessTrusted() {
                // Without Accessibility, SelectionManager can never read a
                // selection — this is the shortcut's most common silent
                // failure. A toast alone is easy to miss if Voqora's window
                // isn't focused, so bring the app forward and go straight to
                // the fix instead of leaving the user to guess why nothing happened.
                showTransientError("Voqora needs Accessibility access. Opening System Settings…")
                NSApp.activate(ignoringOtherApps: true)
                PermissionsService.shared.openAccessibilitySettings()
            } else {
                // "Nothing selected" and "this app can't expose its content
                // via Accessibility or copy at all" (canvas-rendered PDF
                // viewers, games, video subtitles) both silently return nil
                // here — there's no reliable way to tell them apart from a
                // single attempt. But repeated failures in the SAME app are
                // a real signal worth surfacing instead of repeating the
                // identical generic message every time.
                let failures = (selectionFailuresByApp[frontAppName] ?? 0) + 1
                selectionFailuresByApp[frontAppName] = failures
                if failures >= 2 {
                    showTransientError("Voqora couldn't read text from \(frontAppName). Some apps (games, custom-rendered viewers) don't support this.")
                } else {
                    showTransientError("Select text in any app, then press Cmd+Shift+.")
                }
            }
            return
        }
        selectionFailuresByApp[frontAppName] = 0
        VoqoraLog.info("DashboardViewModel", "Sending selection to backend", ["chars": "\(text.count)"])
        // Confirms the shortcut actually fired even when Voqora's window is
        // backgrounded — the only in-app feedback otherwise is a toast on a
        // window the user may not be looking at.
        PermissionsService.shared.scheduleNotification(
            title: "Voqora is speaking",
            body: String(text.prefix(120))
        )
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
        // audiobook generation pauses between pages. Routed through
        // AudiobookViewModel.stopPlayback(fadeOverSeconds:) (not a raw
        // audio.fadeOutAndStop() + manual state clear) so the interruption
        // gets the same resume-position save, transcript-task cancellation,
        // and sleep-timer cancellation as any other stop — a prior version
        // skipped all three, most importantly leaving an armed sleep timer
        // running to later stop whatever audio played next for no visible reason.
        if let avm = audiobookVM, avm.nowPlaying != nil {
            avm.stopPlayback(fadeOverSeconds: 0.12)
        }

        currentSpeakTask = Task { [weak self] in
            guard let self else { return }
            defer {
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
            VoqoraLog.debug("DashboardViewModel", "Starting new speak task", ["voice": selectedVoice, "speed": "\(speechSpeed)", "volume": "\(speechVolume)"])
            status = .thinking

            let cleaned = TextProcessor.sanitize(text, options: .init(cleanURLs: cleanURLs, cleanHandles: true, fixLigatures: true, expandAbbr: true, expandNumbers: true, stripMarkdown: true))

            // This resets the AudioService buffers. Must run BEFORE
            // setEstimatedDuration: it unconditionally zeroes `duration`, so
            // calling it after silently wiped out the estimate on every
            // single speak() — the scrub bar showed 0:00 during the whole
            // "thinking" phase instead of an immediate estimate.
            audio.prepareForStream()
            audio.setEstimatedDuration(textLength: cleaned.count, speed: speechSpeed)

            do {
                let stream = backend.streamAudio(
                    text: cleaned,
                    voice: selectedVoice,
                    speed: speechSpeed,
                    volume: speechVolume
                )
                var receivedAudio = false

                for try await chunk in stream {
                    guard !Task.isCancelled, generation == speakGeneration else {
                        return
                    }
                    if status == .thinking {
                        status = .speaking
                    }
                    audio.playChunk(chunk, volume: Float(speechVolume))
                    receivedAudio = true
                }

                guard !Task.isCancelled, generation == speakGeneration else { return }
                guard receivedAudio else {
                    VoqoraLog.error("DashboardViewModel", "Stream completed with zero audio chunks", ["chars": "\(cleaned.count)", "voice": selectedVoice])
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
                guard !Task.isCancelled, generation == speakGeneration else { return }
                VoqoraLog.error("DashboardViewModel", "speak() failed", ["failureCode": "speech_request_failed", "voice": selectedVoice, "chars": "\(cleaned.count)"])
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
        case let .rejectedResponse(statusCode) where statusCode == 422:
            return "That selection is empty or too long. Try a shorter passage."
        case let .rejectedResponse(statusCode) where statusCode == 503:
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
            resetPlaybackError(for: resetGeneration)
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
        // The generic export is intentionally only for retained selected-text
        // PCM. Audiobooks are file-backed and expose their own Save-panel
        // export, so a global/menu invocation must be a no-op rather than
        // surfacing a misleading "no audio" failure while a book is playing.
        guard audio.canExportLastClip else { return }
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
            VoqoraLog.error("DashboardViewModel", "exportLogs failed", ["failureCode": "log_export_failed"])
            showTransientError(error.localizedDescription)
        }
    }

    private func showActionFeedback(_ message: String) {
        actionFeedbackTask?.cancel()
        actionFeedback = message
        actionFeedbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let self else { return }
            actionFeedback = nil
        }
    }

    private func clearActionFeedback() {
        actionFeedbackTask?.cancel()
        actionFeedbackTask = nil
        actionFeedback = nil
    }

    /// Poll aggressively (500 ms) while backend is offline/starting up, then
    /// relax to 5 s once stable — this cuts the "waiting for backend" window
    /// from up to 5 s to under 500 ms in normal operation. While the app is
    /// backgrounded, widen to a 30 s floor: the crash-recovery/auto-relaunch
    /// behavior driven by this loop still needs to keep working, just far
    /// less frequently, since nobody is watching in real time. Never shrinks
    /// the interval — only ever widens it.
    static func heartbeatDelay(isOnline: Bool, isBackgrounded: Bool) -> UInt64 {
        let baseDelay: UInt64 = isOnline ? 5_000_000_000 : 500_000_000
        return isBackgrounded ? max(baseDelay, 30_000_000_000) : baseDelay
    }

    struct HeartbeatOutcome: Equatable {
        let isOnline: Bool
        let consecutiveFailures: Int
        let shouldForceRestart: Bool
    }

    /// A single missed poll (thermal throttling, Spotlight indexing, a busy
    /// Mac) used to be treated as a crash outright, instantly cancelling
    /// in-flight playback and flashing OFFLINE. Require `crashThreshold`
    /// consecutive failures before reporting offline; recovery (offline ->
    /// online) still reports immediately on the very next success.
    ///
    /// If failures keep piling up well past that point, the backend is
    /// likely wedged (event loop deadlock) rather than actually down —
    /// `BackendService.start()` is a no-op whenever it still holds a process
    /// handle, so nothing else would ever recover it. `shouldForceRestart`
    /// fires once every `hungProcessRestartInterval` failures so a caller
    /// holding a live process handle can force a fresh one periodically.
    static func heartbeatOutcome(
        rawOnline: Bool,
        wasOnline: Bool,
        previousConsecutiveFailures: Int,
        crashThreshold: Int = 2,
        hungProcessRestartInterval: Int = 10
    ) -> HeartbeatOutcome {
        let consecutiveFailures = rawOnline ? 0 : previousConsecutiveFailures + 1
        let isNowOnline = rawOnline || (wasOnline && consecutiveFailures < crashThreshold)
        let shouldForceRestart = !isNowOnline
            && consecutiveFailures > 0
            && consecutiveFailures % hungProcessRestartInterval == 0
        return HeartbeatOutcome(isOnline: isNowOnline, consecutiveFailures: consecutiveFailures, shouldForceRestart: shouldForceRestart)
    }

    func startHeartbeat() {
        guard heartbeatTask == nil else { return }
        // [weak self] to match startPolling/subscribe — self owns
        // heartbeatTask, so a strong capture here is a retain cycle
        // (self -> heartbeatTask -> closure -> self).
        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            var wasOnline = false
            var consecutiveFailures = 0

            while !Task.isCancelled {
                let health = await backend.checkHealth()
                let outcome = Self.heartbeatOutcome(
                    rawOnline: health.isOnline,
                    wasOnline: wasOnline,
                    previousConsecutiveFailures: consecutiveFailures
                )
                consecutiveFailures = outcome.consecutiveFailures
                let isNowOnline = outcome.isOnline
                isBackendOnline = isNowOnline
                isModelLoaded = health.isModelLoaded

                // Detect backend crash: was online, now offline
                if wasOnline, !isNowOnline {
                    VoqoraLog.error("DashboardViewModel", "Backend crash detected, cancelling in-flight stream", ["status": "\(status)"])
                    currentSpeakTask?.cancel()
                    currentSpeakTask = nil
                    if status == .speaking || status == .thinking {
                        status = .ready
                    }
                    // Audiobook playback reads a local WAV and never talks to
                    // the backend, so a TTS-engine crash must not corrupt it.
                    // An unconditional audio.stop() here bypassed
                    // AudiobookViewModel.stopPlayback and left exactly the
                    // broken state described there — stale nowPlaying, unsaved
                    // resume position, phantom playback on the next Play — for
                    // a listener whose book had nothing to do with the crash.
                    // Same routing as stopPlayback() and speak() below.
                    if let avm = audiobookVM, avm.nowPlaying != nil {
                        avm.stopPlayback()
                    } else {
                        audio.stop()
                    }
                }

                wasOnline = isNowOnline

                if isNowOnline {
                    isBackendInitializing = false
                    backend.clearLaunchFailure()
                    backendRecoveryMessage = nil
                } else {
                    if outcome.shouldForceRestart, backend.hasOwnedProcess {
                        VoqoraLog.error("DashboardViewModel", "Backend unresponsive with a live process handle, forcing restart", ["consecutiveFailures": "\(consecutiveFailures)"])
                        backend.forceRestart()
                    }
                    let launching = backend.isLaunching
                    isBackendInitializing = launching
                    backendRecoveryMessage = backend.lastLaunchFailure
                    backend.start()
                }

                let delay = Self.heartbeatDelay(
                    isOnline: isNowOnline,
                    isBackgrounded: AppActivityMonitor.shared.isBackgrounded
                )
                try? await Task.sleep(nanoseconds: delay)
            }
        }
    }

    func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    /// Pre-warm the model ahead of the hotkey, hiding the ~1-2s cold ONNX
    /// reload without ever reading the user's clipboard content.
    ///
    /// Two signals trigger a bare, content-free `prewarm()` (model load only,
    /// no lookahead — we don't have the text and don't want it):
    /// 1. The clipboard changes — user likely just copied something they're
    ///    about to speak. Only `changeCount` is observed, never the string
    ///    value, and only when the new pasteboard item is plausibly text
    ///    (checked by declared type, not content) so image/file copies don't
    ///    trigger a pointless model load.
    /// 2. The app becomes active — user switched to Voqora directly.
    ///
    /// Both signals are gated on `!isModelLoaded`: once warm, further copies
    /// are free no-ops (no network call, no backend work) until the backend's
    /// 5-minute idle-unload drops it again. Without this gate a long copy-paste
    /// session would fire one HTTP round-trip per copy for zero benefit.
    static func shouldPrewarmOnPasteboardChange(
        currentChangeCount: Int,
        lastChangeCount: Int,
        isBackendOnline: Bool,
        isModelLoaded: Bool,
        hasReadableStringContent: Bool
    ) -> Bool {
        guard isBackendOnline, !isModelLoaded else { return false }
        guard currentChangeCount != lastChangeCount else { return false }
        return hasReadableStringContent
    }

    private func startPrewarmObservers() {
        Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                let pasteboard = NSPasteboard.general
                let current = pasteboard.changeCount
                defer { self.lastPasteboardChangeCount = current }
                // Type check only — never touches the actual clipboard content.
                let shouldPrewarm = Self.shouldPrewarmOnPasteboardChange(
                    currentChangeCount: current,
                    lastChangeCount: lastPasteboardChangeCount,
                    isBackendOnline: isBackendOnline,
                    isModelLoaded: isModelLoaded,
                    hasReadableStringContent: pasteboard.canReadItem(withDataConformingToTypes: [NSPasteboard.PasteboardType.string.rawValue])
                )
                guard shouldPrewarm else { return }
                Task { await self.backend.prewarm() }
            }
            .store(in: &cancellables)

        // App focus only loads the model. No text is inspected until the user
        // explicitly activates the selected-text shortcut.
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
}

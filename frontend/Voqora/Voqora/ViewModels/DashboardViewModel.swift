import ApplicationServices
import Combine
import Foundation
import SwiftUI

@MainActor
class DashboardViewModel: ObservableObject {
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

    private let backend: BackendService
    private let system: SystemService
    let audio: AudioService
    private let history: HistoryManager
    private let defaults: UserDefaults

    @Published var status: AppStatus = .ready
    private var selectionFailuresByApp: [String: Int] = [:]
    @Published var isBackendOnline = false
    @Published var isBackendInitializing = true // Start as initializing
    @Published var isModelLoaded = false // Model in ONNX session RAM
    private var lastPasteboardChangeCount = NSPasteboard.general.changeCount
    @Published private(set) var backendRecoveryMessage: String?
    @Published var selectedTab: String? = "home"
    @Published private(set) var actionFeedback: String?

    weak var audiobookVM: AudiobookViewModel?

    @Published private(set) var spokenText: String?
    let speechFollower: TranscriptFollower

    @Published var selectedVoice: String {
        didSet {
            defaults.set(selectedVoice, forKey: "selectedVoice")
        }
    }

    @AppStorage("speechSpeed") var speechSpeed = 1.0
    private var clipSpeed = 1.0
    @AppStorage("speechVolume") var speechVolume = 1.0
    @AppStorage("enableDucking") var enableDucking = false
    @AppStorage("cleanURLs") var cleanURLs = true
    @AppStorage("appTheme") var appTheme = "system" // system, light, dark
    @AppStorage("selectedFontName") var selectedFontName = "Google Sans"
    @AppStorage("accentColorID") var accentColorID: AccentColorOption = .clay
    @AppStorage("appIconID") var appIconID: AppIconOption = .waveLight {
        didSet { appIconID.apply() }
    }

    @AppStorage("lastSeenAppVersion") var lastSeenAppVersion: String = ""

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
            .custom(Self.poppinsPostScriptName(for: weight), size: size)
        case "Google Sans":
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

    var currentVoiceDisplay: String {
        Self.voiceName(for: selectedVoice)
    }

    static func voiceName(for id: String) -> String {
        let name = id.split(separator: "_").last.map(String.init) ?? id
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    func showLibrary() {
        audiobookVM?.libraryPath = []
        selectedTab = "books"
    }

    func openAudiobook(_ bookID: String) {
        audiobookVM?.openPlayer(for: bookID)
        selectedTab = "books"
    }

    func openNowPlaying() {
        if let book = audiobookVM?.nowPlaying {
            openAudiobook(book.bookID)
        } else {
            selectedTab = "home"
        }
    }

    var isOnline: Bool {
        isBackendOnline
    }

    private var currentSpeakTask: Task<Void, Never>?
    private var speakGeneration = 0
    private var heartbeatTask: Task<Void, Never>?
    private(set) var backgroundWorkStarted = false
    private var unduckTask: Task<Void, Never>?
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
        speechFollower = TranscriptFollower(audio: audio)

        setupBindings()
        if startsBackgroundWork {
            startBackgroundWork()
        }
    }

    func startBackgroundWork() {
        guard !backgroundWorkStarted else { return }
        backgroundWorkStarted = true
        startHeartbeat()
        startPrewarmObservers()
    }

    private func setupBindings() {
        audio.$isPlaying
            .sink { [weak self] isPlaying in
                guard let self else { return }
                if isPlaying, let audiobookVM, audiobookVM.nowPlaying != nil || audiobookVM.isPreparingPlayback {
                    spokenText = nil
                    speechFollower.clear()
                }
                if isPlaying {
                    status = .speaking
                    if enableDucking {
                        system.beginDucking { [weak self] message in
                            self?.showTransientError(message)
                        }
                    }
                    unduckTask?.cancel()
                    unduckTask = nil
                } else {
                    if status == .speaking || status == .paused {
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

    func speakSelection() async {
        VoqoraLog.info("DashboardViewModel", "speakSelection triggered")
        let frontApp = NSWorkspace.shared.frontmostApplication
        let frontAppName = frontApp?.localizedName ?? frontApp?.bundleIdentifier ?? "unknown"

        guard let text = await SelectionManager.getSelectedText(), !text.isEmpty else {
            VoqoraLog.warn("DashboardViewModel", "No text found in selection", ["axTrusted": AXIsProcessTrusted() ? "true" : "false", "app": frontAppName])
            if !AXIsProcessTrusted() {
                showTransientError("Voqora needs Accessibility access. Opening System Settings…")
                NSApp.activate(ignoringOtherApps: true)
                PermissionsService.shared.openAccessibilitySettings()
            } else {
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

        speakGeneration &+= 1
        let generation = speakGeneration
        currentSpeakTask?.cancel()

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
            spokenText = text.trimmingCharacters(in: .whitespacesAndNewlines)

            audio.prepareForStream()
            clipSpeed = speechSpeed
            audio.setEstimatedDuration(textLength: cleaned.count, speed: speechSpeed)
            speechFollower.follow(spokenText: spokenText)

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
                if let spokenText {
                    speechFollower.load(TranscriptDocument(
                        spokenText: spokenText,
                        duration: audio.duration,
                        pauses: audio.streamPauses(),
                        speed: speechSpeed
                    ))
                }
                history.log(text: cleaned, voice: selectedVoice)
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

    func playSpokenText(from line: TranscriptLine) {
        audio.seek(toSeconds: speechFollower.startTime(of: line))
        if !audio.isPlaying {
            audio.resume()
        }
    }

    func skipSpeech(by seconds: TimeInterval) {
        audio.skip(by: seconds)
    }

    func setSpeechSpeed(_ speed: Double) {
        speechSpeed = min(2.0, max(0.5, speed))
        if audiobookVM?.nowPlaying == nil, audio.hasMedia {
            audio.setPlaybackRate(Float(speechSpeed / clipSpeed))
        }
    }

    func togglePlayback() {
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
        errorResetTask?.cancel()
        errorResetGeneration &+= 1
        let resetGeneration = errorResetGeneration
        errorResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self else { return }
            resetPlaybackError(for: resetGeneration)
        }
    }

    func resetPlaybackError(for generation: Int) {
        guard generation == errorResetGeneration else { return }
        if case .error = status {
            status = .ready
        }
    }

    func exportLastClip() {
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

    static func heartbeatDelay(isOnline: Bool, isBackgrounded: Bool) -> UInt64 {
        let baseDelay: UInt64 = isOnline ? 5_000_000_000 : 500_000_000
        return isBackgrounded ? max(baseDelay, 30_000_000_000) : baseDelay
    }

    struct HeartbeatOutcome: Equatable {
        let isOnline: Bool
        let consecutiveFailures: Int
        let shouldForceRestart: Bool
    }

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

                if wasOnline, !isNowOnline {
                    VoqoraLog.error("DashboardViewModel", "Backend crash detected, cancelling in-flight stream", ["status": "\(status)"])
                    currentSpeakTask?.cancel()
                    currentSpeakTask = nil
                    if status == .speaking || status == .thinking {
                        status = .ready
                    }
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

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self, isBackendOnline, !self.isModelLoaded else { return }
                Task { await self.backend.prewarm() }
            }
            .store(in: &cancellables)
    }

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

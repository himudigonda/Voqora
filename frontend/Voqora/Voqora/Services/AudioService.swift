import AppKit
import AVFoundation
import Combine

@MainActor
class AudioService: NSObject, ObservableObject {
    enum ExportError: LocalizedError {
        case noAudioAvailable
        case couldNotSave

        var errorDescription: String? {
            switch self {
            case .noAudioAvailable:
                return "There is no generated audio to save yet."
            case .couldNotSave:
                return "Voqora could not save the audio clip to your Desktop."
            }
        }
    }

    @Published var isPlaying = false
    @Published var progress: Double = 0.0
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var isDragging = false
    /// True when the current clip played to its natural end (not manually paused/stopped).
    @Published var playbackCompleted = false

    /// 0...1.5 (matches existing speechVolume range used elsewhere for TTS).
    /// Mirrors `playerNode.volume`. Use `setVolume(_:)` to change it; the
    /// setter ramps for ~50ms to avoid pops.
    @Published private(set) var volume: Float = 1.0

    /// Fade volume to zero over `seconds`, then stop. Used when TTS hotkey
    /// preempts audiobook playback so we don't get an abrupt click (P11).
    func fadeOutAndStop(over seconds: TimeInterval = 0.15) {
        guard isPlaying else { stop(); return }
        let originalVolume = volume
        let steps = max(3, Int(seconds / 0.02))
        let stepDuration = seconds / Double(steps)
        let delta = originalVolume / Float(steps)
        var step = 0
        volumeRampTimer?.invalidate()
        volumeRampTimer = Timer.scheduledTimer(withTimeInterval: stepDuration, repeats: true) { [weak self] timer in
            DispatchQueue.main.async {
                guard let self else { timer.invalidate(); return }
                step += 1
                let v = max(0, originalVolume - delta * Float(step))
                self.playerNode.volume = v
                if step >= steps {
                    timer.invalidate()
                    self.volumeRampTimer = nil
                    self.stop()
                    self.volume = originalVolume  // restore for next play
                    self.playerNode.volume = originalVolume
                }
            }
        }
    }

    func setVolume(_ newValue: Float) {
        let clamped = max(0, min(1.5, newValue))
        volume = clamped
        if abs(playerNode.volume - clamped) > 0.01 {
            rampVolume(to: clamped)
        } else {
            playerNode.volume = clamped
        }
    }

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    /// Sits between `playerNode` and the mixer so audiobook speed changes
    /// actually change how fast audio plays, instead of only relabeling a
    /// picker that never reached the engine.
    private let timePitch = AVAudioUnitTimePitch()
    /// AVAudioUnitTimePitch is a real Audio Unit and only accepts the
    /// engine's canonical Float32 format — connecting it with the Int16
    /// format this class used before crashes at `engine.connect(...)` with
    /// kAudioUnitErr_FormatNotSupported. PCM byte accounting elsewhere
    /// (`lastAudioData`, export, seek) still treats network audio as Int16;
    /// only buffer construction converts to Float32 for the engine.
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!

    /// Live playback rate applied to `timePitch`. Reset to 1.0 by `stop()` so
    /// an audiobook's chosen speed never bleeds into an unrelated hotkey TTS
    /// clip (TTS speed is instead baked in server-side at generation time).
    @Published private(set) var playbackRate: Float = 1.0

    func setPlaybackRate(_ rate: Float) {
        let clamped = max(0.5, min(2.5, rate))
        playbackRate = clamped
        timePitch.rate = clamped
    }
    /// Test-only instances deliberately skip Core Audio setup. Keep every
    /// playback entry point aware of that rather than letting one helper try
    /// to start an unconfigured graph.
    private var engineConfigured = false

    private var lastAudioData = Data()
    private var headerAccumulator = Data()
    private var pcmAccumulator = Data()
    private var hasStrippedHeader = false
    private var isStreamActive = false
    private var hasStartedPlayback = false
    private var scheduledBufferCount = 0

    // Timer for progress
    private var timer: AnyCancellable?
    private var pausedTime: TimeInterval = 0

    /// For duration estimation
    private var estimatedDuration: TimeInterval = 0

    /// Volume ramping support
    private var volumeRampTimer: Timer?
    /// Token issued per `rampVolume` call. The deferred `volumeRampTimer = nil`
    /// inside the timer closure only fires if it still owns this slot — prevents
    /// a finished ramp from clobbering a successor ramp that was queued up
    /// between the timer firing and the DispatchQueue.main.async block running.
    /// See HARD-020.
    private var volumeRampToken: UUID?

    init(startingEngine: Bool = !RuntimeEnvironment.isRunningTests) {
        super.init()
        // XCTest hosts the app target. Starting Core Audio there can leave an
        // orphaned audio process after pure logic tests have finished. Unit
        // tests do not exercise playback hardware, so keep that dependency
        // explicit and leave the production default unchanged.
        if startingEngine {
            setupEngine()
        }
    }

    private func setupEngine() {
        engine.attach(playerNode)
        engine.attach(timePitch)
        engine.connect(playerNode, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        engineConfigured = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigChange),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
        do {
            try engine.start()
        } catch {
            print("❌ AudioService: Engine start error: \(error)")
        }
    }

    @objc private func handleEngineConfigChange(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self, isPlaying else { return }
            do {
                try engine.start()
                playerNode.play()
            } catch {
                print("❌ AudioService: Engine restart after device change failed: \(error)")
                stop()
            }
        }
    }

    func setEstimatedDuration(textLength: Int, speed: Double) {
        let rawSeconds = Double(textLength) / 12.0
        estimatedDuration = max(1.0, rawSeconds / speed)
        duration = estimatedDuration
    }

    func playChunk(_ data: Data, volume: Float) {
        var dataToProcess = data

        // 1. Strip Header
        if !hasStrippedHeader {
            headerAccumulator.append(dataToProcess)
            if headerAccumulator.count >= 44 {
                dataToProcess = headerAccumulator.suffix(from: 44)
                hasStrippedHeader = true
                headerAccumulator = Data()
                print("🔊 AudioService: Header stripped. PCM accumulation started.")
            } else {
                return
            }
        }

        if dataToProcess.isEmpty { return }

        // 2. PCM Accumulation with Alignment Fix
        pcmAccumulator.append(dataToProcess)

        // --- FIX: Only process full 2-byte samples ---
        let totalAvailable = pcmAccumulator.count
        let bytesToProcess = (totalAvailable / 2) * 2 // Force even number

        guard bytesToProcess > 0 else { return }

        let chunkToBuffer = pcmAccumulator.prefix(bytesToProcess)
        pcmAccumulator.removeFirst(bytesToProcess) // Keep the leftover byte if it was odd

        // 3. Scheduling
        lastAudioData.append(chunkToBuffer)
        let actualDataDuration = Double(lastAudioData.count / 2) / 24000.0
        duration = max(estimatedDuration, actualDataDuration)

        if !isDragging {
            guard let buffer = dataToBuffer(chunkToBuffer) else { return }
            // Ramp volume smoothly if it changed (prevents audio pops)
            if abs(playerNode.volume - volume) > 0.02 {
                rampVolume(to: volume)
            } else {
                playerNode.volume = volume
            }

            scheduledBufferCount += 1
            playerNode.scheduleBuffer(buffer, at: nil, options: [], completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    scheduledBufferCount -= 1
                    if !isStreamActive, scheduledBufferCount == 0, isPlaying {
                        playbackCompleted = true
                        stop()
                    }
                }
            })

            // Start playback after minimal safety buffer (10ms = 480 bytes at 24kHz 16-bit mono)
            if !hasStartedPlayback, lastAudioData.count > 480 {
                startPlayback()
            }
        }
    }

    private func startPlayback() {
        guard !hasStartedPlayback else { return }
        guard engineConfigured else { return }
        do {
            if !engine.isRunning { try engine.start() }
            playerNode.play()
            isPlaying = true
            hasStartedPlayback = true
            startTimer()
        } catch {
            print("❌ AudioService: Start error: \(error)")
        }
    }

    private func startTimer() {
        timer?.cancel()
        timer = Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, isPlaying else { return }

                // 🔊 HARDWARE SYNC: Only count time that physically left the speakers
                if let nodeTime = playerNode.lastRenderTime,
                   let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
                {
                    let elapsedSamples = Double(playerTime.sampleTime)
                    // sampleTime can briefly be negative during engine startup
                    if elapsedSamples > 0 {
                        let elapsedSeconds = elapsedSamples / format.sampleRate
                        currentTime = pausedTime + elapsedSeconds
                    }
                }

                if !isDragging {
                    progress = duration > 0 ? min(1.0, currentTime / duration) : 0
                }
            }
    }

    func togglePause() {
        // 🔒 FIX: Refuse to play if memory is completely empty
        guard duration > 0 else { return }

        if playerNode.isPlaying {
            // Save accumulated hardware time before pausing
            if let nodeTime = playerNode.lastRenderTime,
               let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
            {
                let elapsedSamples = Double(playerTime.sampleTime)
                if elapsedSamples > 0 {
                    pausedTime += elapsedSamples / format.sampleRate
                }
            }
            playerNode.pause()
            engine.pause()
            isPlaying = false
        } else {
            if playbackCompleted {
                pausedTime = 0
                currentTime = 0
                progress = 0
            }
            playbackCompleted = false
            if engineConfigured { try? engine.start() }
            playerNode.play()
            isPlaying = true
            startTimer()
        }
    }

    func seek(to percentage: Double) {
        guard !lastAudioData.isEmpty else { return }
        playerNode.stop()
        scheduledBufferCount = 0

        let targetTime = percentage * duration
        let targetSample = Int(targetTime * 24000)
        var targetByte = targetSample * 2

        if targetByte >= lastAudioData.count { targetByte = lastAudioData.count - 2 }
        if targetByte < 0 { targetByte = 0 }
        if targetByte % 2 != 0 { targetByte -= 1 }

        let remainingData = lastAudioData.advanced(by: targetByte)
        if let buffer = dataToBuffer(remainingData) {
            scheduledBufferCount += 1
            let gen = audiobookGeneration
            playerNode.scheduleBuffer(buffer, at: nil, options: [], completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, gen == self.audiobookGeneration else { return }
                    self.scheduledBufferCount -= 1
                }
            })

            pausedTime = targetTime
            currentTime = targetTime

            if !engine.isRunning { try? engine.start() }
            playerNode.play()
            isPlaying = true
            startTimer()
        }
    }

    func prepareForStream() {
        stop()
        // Reset playback-position state for the new session (stop() no longer clears these).
        progress = 0
        currentTime = 0
        pausedTime = 0
        duration = 0
        playbackCompleted = false
        // `stop()` deliberately preserves the last completed clip so it can be
        // exported. A new speech request is the point at which that clip must
        // be discarded.
        lastAudioData = Data()
        pcmAccumulator = Data()
        headerAccumulator = Data()
        estimatedDuration = 0
        isStreamActive = true
        // Pre-warm the engine, but do not claim playback has started until a
        // real buffer has been scheduled. Otherwise a slow or failed request
        // makes the product show “Speaking 0:00” while nothing is audible.
        if engineConfigured, !engine.isRunning { try? engine.start() }
        hasStartedPlayback = false
        isPlaying = false
    }

    func finishStream() {
        isStreamActive = false
        // Final flush of any leftover partial PCM byte
        if !pcmAccumulator.isEmpty {
            playChunk(Data(), volume: playerNode.volume)
        }
        // BUG FIX: correct duration to exact actual length now that all data has arrived.
        // Estimated duration (text-length / 12 / speed) often overshoots — without this
        // correction the scrub bar never reaches 100%.
        if lastAudioData.count > 0 {
            duration = Double(lastAudioData.count / 2) / format.sampleRate
        }
        if scheduledBufferCount == 0, isPlaying { stop() }
    }

    func stop() {
        volumeRampTimer?.invalidate()
        volumeRampTimer = nil
        audiobookGeneration += 1  // invalidate any in-flight completion handlers
        setPlaybackRate(1.0)
        playerNode.stop()
        timer?.cancel()
        isPlaying = false
        // BUG FIX: do NOT reset progress / currentTime / pausedTime / duration here.
        // Those values are cleared in prepareForStream() when a new session begins.
        // Keeping them lets the scrub bar stay visible and accurate after playback ends,
        // and preserves the Save button so the user can export the last clip.
        hasStartedPlayback = false
        isStreamActive = false
        hasStrippedHeader = false
        scheduledBufferCount = 0
        pcmAccumulator = Data()
        headerAccumulator = Data()
        estimatedDuration = 0
        currentAudioFile = nil
        audiobookFrameOffset = 0
        audiobookTotalFrames = 0
    }

    /// `data` holds raw little-endian Int16 PCM (the wire/export format).
    /// The engine connection format is Float32, so each sample is converted
    /// on the way into the buffer. Reads bytes rather than binding to Int16
    /// directly since `data` is a slice and isn't guaranteed 2-byte aligned.
    private func dataToBuffer(_ data: Data) -> AVAudioPCMBuffer? {
        let frameCount = UInt32(data.count) / 2
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<Int(frameCount) {
                let lo = UInt16(raw[i * 2])
                let hi = UInt16(raw[i * 2 + 1])
                let sample = Int16(bitPattern: lo | (hi << 8))
                channel[i] = Float(sample) / 32768.0
            }
        }
        return buffer
    }

    /// Smoothly ramp volume to target over 50ms (5 steps of 10ms each) to avoid pops
    private func rampVolume(to targetVolume: Float) {
        volumeRampTimer?.invalidate()

        let initialVolume = playerNode.volume
        guard abs(initialVolume - targetVolume) > 0.01 else {
            playerNode.volume = targetVolume
            return
        }

        let steps = 5
        let stepDuration = 0.01  // 10ms per step
        let delta = (targetVolume - initialVolume) / Float(steps)
        var step = 0

        let token = UUID()
        volumeRampToken = token
        volumeRampTimer = Timer.scheduledTimer(withTimeInterval: stepDuration, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            step += 1
            let newVolume = initialVolume + delta * Float(step)
            // playerNode.volume is safe to set from any thread per AVFoundation,
            // so the DispatchQueue.main.async hop is mostly to serialize with
            // the @MainActor class. We keep it for consistency.
            DispatchQueue.main.async {
                self.playerNode.volume = newVolume
            }
            if step >= steps {
                DispatchQueue.main.async {
                    self.playerNode.volume = targetVolume
                    // Only clear the slot if we still own it — a successor
                    // ramp may have replaced us already.
                    if self.volumeRampToken == token {
                        self.volumeRampTimer = nil
                        self.volumeRampToken = nil
                    }
                }
                timer.invalidate()
            }
        }
    }

    // MARK: - Audiobook playback (chunked, file-backed)
    //
    // Audiobooks can be hours long (≥300 MB on disk). The original
    // implementation read the entire WAV into one PCM buffer — for a 2 h book
    // that's ~680 MB resident, which OOM-killed the app on real content
    // (C9). We now stream from the file in 30 s chunks, refilling as
    // playback advances.

    /// Currently-playing audiobook file (kept for chunked refills + seek).
    private var currentAudioFile: AVAudioFile?
    private var audiobookFrameOffset: AVAudioFramePosition = 0
    private var audiobookTotalFrames: AVAudioFramePosition = 0
    private var audiobookSampleRate: Double = 24000
    private static let audiobookChunkSeconds: Double = 30
    /// Number of pre-scheduled chunks ahead of the current play head.
    private static let audiobookChunkLookahead: Int = 2
    /// Incremented on every seek/stop to invalidate stale completion handlers.
    private var audiobookGeneration: Int = 0

    /// Open a local WAV file and start chunked playback from frame 0.
    func loadAndPlayWAV(at url: URL) throws {
        stop()
        progress = 0
        currentTime = 0
        pausedTime = 0
        playbackCompleted = false
        isStreamActive = false
        hasStrippedHeader = true

        // AVAudioFile(forReading:) sets processingFormat to Float32 regardless
        // of the file's on-disk format, which now matches the engine's
        // connection format directly (see `format` above) — no conversion
        // needed between the file read and the scheduled buffer.
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        currentAudioFile = file
        audiobookSampleRate = file.processingFormat.sampleRate
        audiobookTotalFrames = file.length
        audiobookFrameOffset = 0
        duration = Double(file.length) / audiobookSampleRate
        // Used by exportToDesktop() and seek()'s legacy code path: we only
        // populate `lastAudioData` lazily in `seek()` if needed for backward
        // compat, otherwise leave it empty to avoid the RAM blowup.
        lastAudioData = Data()

        if !engine.isRunning { try engine.start() }
        playerNode.volume = volume

        // Schedule the first N chunks ahead. As each completes we schedule
        // the next one to keep the lookahead full.
        for _ in 0..<Self.audiobookChunkLookahead {
            scheduleNextAudiobookChunk()
        }
        playerNode.play()
        isPlaying = true
        hasStartedPlayback = true
        startTimer()
    }

    /// Pull the next chunk from `currentAudioFile` starting at
    /// `audiobookFrameOffset`, schedule it on the player node, and advance
    /// the offset. When the file is exhausted, mark `playbackCompleted` and
    /// stop on the last buffer drain.
    private func scheduleNextAudiobookChunk() {
        guard let file = currentAudioFile else { return }
        if audiobookFrameOffset >= audiobookTotalFrames { return }
        let chunkFrames = AVAudioFrameCount(
            min(
                AVAudioFramePosition(Self.audiobookChunkSeconds * audiobookSampleRate),
                audiobookTotalFrames - audiobookFrameOffset
            )
        )
        guard chunkFrames > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: chunkFrames
              )
        else { return }
        do {
            file.framePosition = audiobookFrameOffset
            try file.read(into: buffer, frameCount: chunkFrames)
        } catch {
            print("❌ AudioService: chunk read error: \(error)")
            return
        }
        audiobookFrameOffset += AVAudioFramePosition(buffer.frameLength)

        scheduledBufferCount += 1
        let gen = audiobookGeneration  // capture before the async hop
        playerNode.scheduleBuffer(buffer, at: nil, options: [], completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, gen == self.audiobookGeneration else { return }
                scheduledBufferCount -= 1
                // Refill: keep the lookahead window full as long as we have file left.
                if currentAudioFile != nil, audiobookFrameOffset < audiobookTotalFrames {
                    scheduleNextAudiobookChunk()
                }
                // End-of-file: when the last buffer drains, mark complete.
                if scheduledBufferCount == 0, isPlaying,
                   audiobookFrameOffset >= audiobookTotalFrames {
                    playbackCompleted = true
                    stop()
                }
            }
        })
    }

    /// Seek for chunked audiobook playback. Resets the file head and schedules
    /// fresh chunks at the target frame.
    func seekAudiobook(toSeconds seconds: TimeInterval) {
        guard let _ = currentAudioFile else {
            seek(to: max(0, min(1, seconds / max(0.01, duration))))
            return
        }
        let wasPlaying = isPlaying
        audiobookGeneration += 1  // invalidate stale handlers before stop fires them
        playerNode.stop()
        scheduledBufferCount = 0
        let target = max(0, min(audiobookTotalFrames, AVAudioFramePosition(seconds * audiobookSampleRate)))
        audiobookFrameOffset = target
        currentTime = Double(target) / audiobookSampleRate
        pausedTime = currentTime
        for _ in 0..<Self.audiobookChunkLookahead {
            scheduleNextAudiobookChunk()
        }
        if !engine.isRunning { try? engine.start() }
        if wasPlaying {
            playerNode.play()
            isPlaying = true
            startTimer()
        } else {
            isPlaying = false
        }
    }

    /// Total rendered audio length of the *current* TTS session, derived
    /// from accumulated PCM frames. Source of truth for the
    /// `audio_seconds` metric (see spec §10). Returns 0 when no session
    /// has rendered any audio yet.
    var renderedAudioSeconds: Double {
        if audiobookTotalFrames > 0 {
            return Double(audiobookTotalFrames) / max(1, audiobookSampleRate)
        }
        return Double(lastAudioData.count / 2) / format.sampleRate
    }

    func exportToDesktop() throws -> URL {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let timestamp = Int(Date().timeIntervalSince1970)
        do {
            let exportedURL = try Self.writeWAV(
                pcmData: lastAudioData,
                to: desktop,
                timestamp: timestamp
            )
            // Record an export only after the atomic file write has succeeded.
            MetricsService.shared.trackExport(audioSeconds: renderedAudioSeconds)
            return exportedURL
        } catch let error as ExportError {
            throw error
        } catch {
            throw ExportError.couldNotSave
        }
    }

    /// Writes a complete WAV for a rendered PCM stream. Kept deterministic so
    /// the app can test export bytes and name collisions without touching a
    /// person's Desktop or needing an audio device.
    static func writeWAV(
        pcmData: Data,
        to directory: URL,
        timestamp: Int,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard !pcmData.isEmpty else { throw ExportError.noAudioAvailable }
        let headerSize = 44
        let totalSize = pcmData.count + headerSize - 8
        var header = Data()
        header.append("RIFF".data(using: .ascii)!)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(totalSize)) { Data($0) })
        header.append("WAVEfmt ".data(using: .ascii)!)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16)) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1)) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1)) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt32(24000)) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt32(24000 * 2)) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(2)) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(16)) { Data($0) })
        header.append("data".data(using: .ascii)!)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(pcmData.count)) { Data($0) })

        let wavData = header + pcmData
        let exportURL = uniqueWAVExportURL(
            in: directory,
            timestamp: timestamp,
            fileManager: fileManager
        )
        do {
            try wavData.write(to: exportURL, options: .atomic)
        } catch {
            throw ExportError.couldNotSave
        }
        return exportURL
    }

    private static func uniqueWAVExportURL(
        in directory: URL,
        timestamp: Int,
        fileManager: FileManager
    ) -> URL {
        let stem = "Voqora_\(timestamp)"
        var suffix = 1
        var url = directory.appendingPathComponent("\(stem).wav")

        while fileManager.fileExists(atPath: url.path) {
            suffix += 1
            url = directory.appendingPathComponent("\(stem)_\(suffix).wav")
        }
        return url
    }
}

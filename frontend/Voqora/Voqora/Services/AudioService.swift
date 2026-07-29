import AppKit
import AVFoundation
import Combine

@MainActor
class AudioService: NSObject, ObservableObject {
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
                    self.volume = originalVolume // restore for next play
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

    /// Live playback-rate multiplier. Used by the audiobook player, where
    /// audio is pre-rendered at a fixed speed and the only way to change
    /// tempo mid-playback is client-side (the backend has no re-render
    /// endpoint). Streaming TTS bakes speed into synthesis instead, so
    /// `stop()` resets this to 1.0 at the start of every new session and
    /// callers that want a non-default rate must re-apply it explicitly.
    @Published private(set) var playbackRate: Float = 1.0

    func setPlaybackRate(_ rate: Float) {
        let clamped = max(0.5, min(2.0, rate))
        playbackRate = clamped
        timePitch.rate = clamped
    }

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    /// Live playback-rate control, inserted between playerNode and the mixer.
    /// AVAudioUnitTimePitch stretches/compresses tempo without shifting pitch,
    /// so sped-up speech doesn't get chipmunked. Because it resamples
    /// downstream of playerNode, playerNode's own sample clock (read via
    /// `playerTime(forNodeTime:)` in startTimer()) still advances in lockstep
    /// with position in the *source* audio regardless of rate — so none of
    /// the currentTime/scrubbing math below needs to account for rate.
    private let timePitch = AVAudioUnitTimePitch()
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: false)!

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

    override init() {
        super.init()
        setupEngine()
    }

    private func setupEngine() {
        engine.attach(playerNode)
        engine.attach(timePitch)
        connectRenderChain()
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

    /// playerNode -> mainMixerNode stays Int16 (matching the buffers scheduled
    /// in dataToBuffer/loadAndPlayWAV) — mixer nodes auto-convert arbitrary
    /// input formats. AVAudioUnitTimePitch is a generic effect unit and has no
    /// such conversion, so it must sit downstream of the mixer at its
    /// (floating-point) render format, not directly after playerNode. Re-run
    /// on every device/config change too — the render format can change (e.g.
    /// switching to a Bluetooth/USB device with a different native sample
    /// rate), and a connection pinned to the old format would either throw on
    /// engine.start() or silently glitch instead of following the device.
    private func connectRenderChain() {
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        let renderFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.connect(engine.mainMixerNode, to: timePitch, format: renderFormat)
        engine.connect(timePitch, to: engine.outputNode, format: renderFormat)
    }

    @objc private func handleEngineConfigChange(_: Notification) {
        Task { @MainActor [weak self] in
            guard let self, isPlaying else { return }
            do {
                connectRenderChain()
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

        if dataToProcess.isEmpty {
            return
        }

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
            // Capture the generation so that if stop()/seek() bumps it, this
            // stale stream buffer's handler won't decrement scheduledBufferCount
            // (it was already zeroed) — matching the seek/audiobook handlers.
            let gen = audiobookGeneration
            playerNode.scheduleBuffer(buffer, at: nil, options: [], completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, gen == audiobookGeneration else { return }
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
        do {
            if !engine.isRunning {
                try engine.start()
            }
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
            try? engine.start()
            playerNode.play()
            isPlaying = true
            startTimer()
        }
    }

    func seek(to percentage: Double) {
        // Need at least one full 16-bit sample (2 bytes) to seek into.
        guard lastAudioData.count >= 2 else { return }
        // Mirror stop(): bump the generation so completion handlers of buffers
        // that playerNode.stop() is about to fire (including stream buffers from
        // playChunk) are invalidated and can't drive scheduledBufferCount
        // negative — which would break end-of-playback detection. See HARD note
        // and the matching pattern in stop()/seekAudiobook().
        audiobookGeneration += 1
        // Seeking means we're (re)positioning to play, not finished.
        playbackCompleted = false
        playerNode.stop()
        scheduledBufferCount = 0

        let targetTime = percentage * duration
        let targetSample = Int(targetTime * 24000)
        var targetByte = targetSample * 2

        if targetByte >= lastAudioData.count {
            targetByte = lastAudioData.count - 2
        }
        if targetByte < 0 {
            targetByte = 0
        }
        if targetByte % 2 != 0 {
            targetByte -= 1
        }

        let remainingData = lastAudioData.advanced(by: targetByte)
        if let buffer = dataToBuffer(remainingData) {
            scheduledBufferCount += 1
            let gen = audiobookGeneration
            playerNode.scheduleBuffer(buffer, at: nil, options: [], completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, gen == audiobookGeneration else { return }
                    scheduledBufferCount -= 1
                }
            })

            pausedTime = targetTime
            currentTime = targetTime

            if !engine.isRunning {
                try? engine.start()
            }
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
        isStreamActive = true
        // Streaming TTS bakes speed into synthesis server-side; force the live
        // rate node back to normal so a leftover audiobook speed never bleeds
        // into a dashboard read. Deliberately NOT in stop() — stop() is also
        // used to fully halt an audiobook (global hotkey, sleep timer) without
        // starting a new session, and resetting the rate there would silently
        // desync the displayed speed from actual playback on the next resume.
        setPlaybackRate(1.0)
        // Pre-warm hardware: start playerNode now so it's running when first buffer arrives.
        if !engine.isRunning {
            try? engine.start()
        }
        playerNode.play()
        hasStartedPlayback = true
        // BUG FIX: set isPlaying so all guards work and start the timer so progress updates.
        isPlaying = true
        startTimer()
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
        if !lastAudioData.isEmpty {
            duration = Double(lastAudioData.count / 2) / format.sampleRate
        }
        if scheduledBufferCount == 0, isPlaying {
            stop()
        }
    }

    func stop() {
        volumeRampTimer?.invalidate()
        volumeRampTimer = nil
        audiobookGeneration += 1 // invalidate any in-flight completion handlers
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
        lastAudioData = Data()
        pcmAccumulator = Data()
        headerAccumulator = Data()
        estimatedDuration = 0
        currentAudioFile = nil
        audiobookFrameOffset = 0
        audiobookTotalFrames = 0
    }

    private func dataToBuffer(_ data: Data) -> AVAudioPCMBuffer? {
        let frameCount = UInt32(data.count) / 2
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        data.withUnsafeBytes { ptr in
            if let base = ptr.baseAddress, let channel = buffer.int16ChannelData?[0] {
                memcpy(channel, base, Int(frameCount) * MemoryLayout<Int16>.size)
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
        let stepDuration = 0.01 // 10ms per step
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

        // AVAudioFile(forReading:) sets processingFormat to Float32 regardless of
        // the file's on-disk format. Our player node is connected with Int16, so
        // scheduling Float32 buffers reinterprets the bit patterns as Int16 and
        // produces pure noise. Force Int16 processing format to match the
        // connection format and avoid the mismatch.
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false)
        currentAudioFile = file
        audiobookSampleRate = file.processingFormat.sampleRate
        audiobookTotalFrames = file.length
        audiobookFrameOffset = 0
        duration = Double(file.length) / audiobookSampleRate
        // Used by exportToDesktop() and seek()'s legacy code path: we only
        // populate `lastAudioData` lazily in `seek()` if needed for backward
        // compat, otherwise leave it empty to avoid the RAM blowup.
        lastAudioData = Data()

        if !engine.isRunning {
            try engine.start()
        }
        playerNode.volume = volume

        // Schedule the first N chunks ahead. As each completes we schedule
        // the next one to keep the lookahead full.
        for _ in 0 ..< Self.audiobookChunkLookahead {
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
        if audiobookFrameOffset >= audiobookTotalFrames {
            return
        }
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
        let gen = audiobookGeneration // capture before the async hop
        playerNode.scheduleBuffer(buffer, at: nil, options: [], completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, gen == audiobookGeneration else { return }
                scheduledBufferCount -= 1
                // Refill: keep the lookahead window full as long as we have file left.
                if currentAudioFile != nil, audiobookFrameOffset < audiobookTotalFrames {
                    scheduleNextAudiobookChunk()
                }
                // End-of-file: when the last buffer drains, mark complete.
                if scheduledBufferCount == 0, isPlaying,
                   audiobookFrameOffset >= audiobookTotalFrames
                {
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
        audiobookGeneration += 1 // invalidate stale handlers before stop fires them
        // Seeking after the book finished must clear the completed flag, else the
        // next pause/play is misrouted as "restart from beginning".
        playbackCompleted = false
        playerNode.stop()
        scheduledBufferCount = 0
        let target = max(0, min(audiobookTotalFrames, AVAudioFramePosition(seconds * audiobookSampleRate)))
        audiobookFrameOffset = target
        currentTime = Double(target) / audiobookSampleRate
        pausedTime = currentTime
        for _ in 0 ..< Self.audiobookChunkLookahead {
            scheduleNextAudiobookChunk()
        }
        if !engine.isRunning {
            try? engine.start()
        }
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

    func exportToDesktop() {
        guard !lastAudioData.isEmpty else { return }
        let headerSize = 44
        let totalSize = lastAudioData.count + headerSize - 8
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
        header.append(contentsOf: withUnsafeBytes(of: UInt32(lastAudioData.count)) { Data($0) })

        let wavData = header + lastAudioData
        let filename = "Voqora_\(Int(Date().timeIntervalSince1970)).wav"
        let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)
        try? wavData.write(to: desktopURL)
        MetricsService.shared.trackExport(audioSeconds: renderedAudioSeconds)
    }
}

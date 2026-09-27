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
                "There is no generated audio to save yet."
            case .couldNotSave:
                "Voqora could not save the audio clip to your Desktop."
            }
        }
    }

    @Published var isPlaying = false
    @Published var progress: Double = 0.0
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var isDragging = false
    @Published var playbackCompleted = false
    @Published var completedSessionID: String?
    @Published private(set) var volume: Float = 1.0
    @Published private(set) var playbackRate: Float = 1.0

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
    private var lastOutputFormat: AVAudioFormat?
    private var engineConfigured = false

    private var lastAudioData = Data()
    private var headerAccumulator = Data()
    private var pcmAccumulator = Data()
    private var hasStrippedHeader = false
    private var isStreamActive = false
    private var hasStartedPlayback = false
    private var estimatedDuration: TimeInterval = 0

    private var currentAudioFile: AVAudioFile?
    private var audiobookFrameOffset: AVAudioFramePosition = 0
    private var audiobookTotalFrames: AVAudioFramePosition = 0
    private var audiobookSampleRate: Double = 24000
    private static let audiobookChunkSeconds: Double = 30
    private static let audiobookChunkLookahead = 2
    private var activeSessionID: String?

    private var generation = 0
    private var scheduledBufferCount = 0
    private var nodePrimed = false
    // AVAudioPlayerNode.stop() resets its sample clock; pause() does not.
    private var timelineOrigin: TimeInterval = 0
    private var timer: AnyCancellable?
    private var volumeRampTimer: Timer?
    private var volumeRampToken: UUID?

    var canExportLastClip: Bool {
        !lastAudioData.isEmpty
    }

    var hasMedia: Bool {
        currentAudioFile != nil || !lastAudioData.isEmpty
    }

    init(startingEngine: Bool = !RuntimeEnvironment.isRunningTests) {
        super.init()
        if startingEngine {
            setupEngine()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: nil)
    }

    private func setupEngine() {
        engine.attach(playerNode)
        engine.attach(timePitch)
        engine.connect(playerNode, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        engineConfigured = true
        lastOutputFormat = engine.outputNode.outputFormat(forBus: 0)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigChange),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
        do {
            try engine.start()
        } catch {
            VoqoraLog.error("AudioService", "Engine start error", ["failureCode": "engine_start_failed"])
        }
    }

    @objc private func handleEngineConfigChange(_: Notification) {
        Task { @MainActor [weak self] in
            guard let self, engineConfigured else { return }
            reconcileEngineConfiguration()
        }
    }

    private func reconcileEngineConfiguration() {
        let current = engine.outputNode.outputFormat(forBus: 0)
        let previous = lastOutputFormat
        lastOutputFormat = current
        let formatChanged = previous == nil
            || previous?.sampleRate != current.sampleRate
            || previous?.channelCount != current.channelCount
        let wasPlaying = isPlaying
        if formatChanged {
            engine.connect(playerNode, to: timePitch, format: format)
            engine.connect(timePitch, to: engine.mainMixerNode, format: format)
            VoqoraLog.info("AudioService", "Rewired audio graph after output format change", [
                "previousRate": previous.map { "\($0.sampleRate)" } ?? "unknown",
                "currentRate": "\(current.sampleRate)",
                "wasPlaying": "\(wasPlaying)",
            ])
        }
        guard formatChanged || wasPlaying else { return }
        do {
            try engine.start()
        } catch {
            VoqoraLog.error("AudioService", "Engine restart after device change failed", ["failureCode": "engine_restart_failed"])
            if wasPlaying {
                pause()
            }
            return
        }
        guard wasPlaying else { return }
        if currentAudioFile != nil {
            refreshPosition()
            reposition(to: currentTime, play: true)
        } else {
            playerNode.play()
        }
    }

    private func startNode() {
        guard engineConfigured else { return }
        do {
            if !engine.isRunning {
                try engine.start()
            }
        } catch {
            VoqoraLog.error("AudioService", "Start error", ["failureCode": "playback_start_failed"])
            return
        }
        playerNode.play()
        isPlaying = true
        startTimer()
    }

    private func startTimer() {
        timer?.cancel()
        timer = Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.tick()
            }
    }

    private func tick() {
        guard isPlaying else { return }
        refreshPosition()
        publishProgress()
        if currentAudioFile == nil, !isStreamActive, duration > 0, currentTime >= duration + 0.75 {
            finishStreamPlayback()
        }
    }

    private func refreshPosition() {
        guard isPlaying,
              let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
              playerTime.sampleTime > 0
        else { return }
        let position = timelineOrigin + Double(playerTime.sampleTime) / playerTime.sampleRate
        currentTime = duration > 0 ? min(position, duration) : position
    }

    private func publishProgress() {
        guard !isDragging else { return }
        progress = duration > 0 ? min(1.0, max(0, currentTime / duration)) : 0
    }

    func togglePause() {
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    func pause() {
        guard isPlaying else { return }
        refreshPosition()
        playerNode.pause()
        if engineConfigured {
            engine.pause()
        }
        timer?.cancel()
        isPlaying = false
        publishProgress()
    }

    func resume() {
        guard hasMedia, duration > 0 else { return }
        if playbackCompleted || !nodePrimed {
            reposition(to: playbackCompleted ? 0 : currentTime, play: true)
            return
        }
        startNode()
    }

    func seek(toSeconds seconds: TimeInterval) {
        guard hasMedia else { return }
        reposition(to: seconds, play: isPlaying)
    }

    func seek(to percentage: Double) {
        guard duration > 0 else { return }
        seek(toSeconds: max(0, min(1, percentage)) * duration)
    }

    func seekAudiobook(toSeconds seconds: TimeInterval) {
        seek(toSeconds: seconds)
    }

    func skip(by seconds: TimeInterval) {
        guard duration > 0 else { return }
        seek(toSeconds: max(0, min(duration, currentTime + seconds)))
    }

    private func reposition(to seconds: TimeInterval, play: Bool) {
        generation += 1
        playerNode.stop()
        scheduledBufferCount = 0
        playbackCompleted = false
        if currentAudioFile != nil {
            repositionFile(to: seconds, play: play)
        } else if !lastAudioData.isEmpty {
            repositionStream(to: seconds, play: play)
        }
    }

    private func repositionFile(to seconds: TimeInterval, play: Bool) {
        let target = max(0, min(audiobookTotalFrames, AVAudioFramePosition(seconds * audiobookSampleRate)))
        audiobookFrameOffset = target
        timelineOrigin = Double(target) / audiobookSampleRate
        currentTime = timelineOrigin
        publishProgress()
        guard target < audiobookTotalFrames else {
            finishFilePlayback(sessionID: activeSessionID)
            return
        }
        for _ in 0 ..< Self.audiobookChunkLookahead {
            scheduleNextFileChunk()
        }
        nodePrimed = true
        if play {
            startNode()
        } else {
            timer?.cancel()
            isPlaying = false
        }
    }

    private func repositionStream(to seconds: TimeInterval, play: Bool) {
        let totalFrames = lastAudioData.count / 2
        let lastFrame = isStreamActive ? max(0, totalFrames - 1) : totalFrames
        let frame = max(0, min(lastFrame, Int(seconds * format.sampleRate)))
        timelineOrigin = Double(frame) / format.sampleRate
        currentTime = timelineOrigin
        publishProgress()
        if frame >= totalFrames, !isStreamActive {
            finishStreamPlayback()
            return
        }
        if let buffer = dataToBuffer(lastAudioData.subdata(in: frame * 2 ..< totalFrames * 2)) {
            scheduleStreamBuffer(buffer)
        }
        nodePrimed = true
        hasStartedPlayback = true
        if play {
            startNode()
        } else {
            timer?.cancel()
            isPlaying = false
        }
    }

    func setEstimatedDuration(textLength: Int, speed: Double) {
        let rawSeconds = Double(textLength) / 12.0
        estimatedDuration = max(1.0, rawSeconds / max(0.1, speed))
        duration = estimatedDuration
    }

    func prepareForStream() {
        stop()
        progress = 0
        currentTime = 0
        timelineOrigin = 0
        duration = 0
        playbackCompleted = false
        lastAudioData = Data()
        pcmAccumulator = Data()
        headerAccumulator = Data()
        estimatedDuration = 0
        isStreamActive = true
        if engineConfigured, !engine.isRunning {
            try? engine.start()
        }
        hasStartedPlayback = false
        isPlaying = false
    }

    func playChunk(_ data: Data, volume: Float) {
        var incoming = data
        if !hasStrippedHeader {
            headerAccumulator.append(incoming)
            guard headerAccumulator.count >= 44 else { return }
            incoming = headerAccumulator.suffix(from: 44)
            hasStrippedHeader = true
            headerAccumulator = Data()
        }
        guard !incoming.isEmpty else { return }

        pcmAccumulator.append(incoming)
        let evenBytes = (pcmAccumulator.count / 2) * 2
        guard evenBytes > 0 else { return }
        let chunk = pcmAccumulator.prefix(evenBytes)
        pcmAccumulator.removeFirst(evenBytes)

        lastAudioData.append(chunk)
        duration = max(estimatedDuration, Double(lastAudioData.count / 2) / format.sampleRate)

        guard !isDragging, let buffer = dataToBuffer(Data(chunk)) else { return }
        if abs(playerNode.volume - volume) > 0.02 {
            rampVolume(to: volume)
        } else {
            playerNode.volume = volume
        }
        scheduleStreamBuffer(buffer)
        nodePrimed = true
        if !hasStartedPlayback, lastAudioData.count > 480 {
            hasStartedPlayback = true
            startNode()
        }
    }

    func finishStream() {
        isStreamActive = false
        if !pcmAccumulator.isEmpty {
            playChunk(Data(), volume: playerNode.volume)
        }
        if !lastAudioData.isEmpty {
            duration = Double(lastAudioData.count / 2) / format.sampleRate
            if !hasStartedPlayback {
                hasStartedPlayback = true
                startNode()
            }
        }
        if scheduledBufferCount == 0, isPlaying {
            finishStreamPlayback()
        }
    }

    private func scheduleStreamBuffer(_ buffer: AVAudioPCMBuffer) {
        guard engineConfigured else { return }
        scheduledBufferCount += 1
        let gen = generation
        playerNode.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, gen == generation else { return }
                scheduledBufferCount -= 1
                if !isStreamActive, scheduledBufferCount == 0, isPlaying {
                    finishStreamPlayback()
                }
            }
        }
    }

    private func finishStreamPlayback() {
        generation += 1
        timer?.cancel()
        playerNode.stop()
        scheduledBufferCount = 0
        nodePrimed = false
        currentTime = duration
        timelineOrigin = duration
        progress = duration > 0 ? 1 : 0
        completedSessionID = nil
        playbackCompleted = true
        isPlaying = false
        setPlaybackRate(1.0)
    }

    func loadAndPlayWAV(at url: URL, sessionID: String? = nil, startingAt seconds: TimeInterval = 0) throws {
        stop()
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        currentAudioFile = file
        audiobookSampleRate = file.processingFormat.sampleRate
        audiobookTotalFrames = file.length
        duration = Double(file.length) / audiobookSampleRate
        lastAudioData = Data()
        activeSessionID = sessionID
        hasStrippedHeader = true
        if engineConfigured, !engine.isRunning {
            try engine.start()
        }
        playerNode.volume = volume
        reposition(to: seconds, play: true)
    }

    private func scheduleNextFileChunk() {
        guard engineConfigured, let file = currentAudioFile, audiobookFrameOffset < audiobookTotalFrames else { return }
        let chunkFrames = AVAudioFrameCount(
            min(
                AVAudioFramePosition(Self.audiobookChunkSeconds * audiobookSampleRate),
                audiobookTotalFrames - audiobookFrameOffset
            )
        )
        guard chunkFrames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames)
        else { return }
        do {
            file.framePosition = audiobookFrameOffset
            try file.read(into: buffer, frameCount: chunkFrames)
        } catch {
            VoqoraLog.error("AudioService", "Audiobook chunk read error", ["failureCode": "audiobook_chunk_read_failed"])
            return
        }
        audiobookFrameOffset += AVAudioFramePosition(buffer.frameLength)
        scheduledBufferCount += 1
        let gen = generation
        let sessionID = activeSessionID
        playerNode.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, gen == generation else { return }
                scheduledBufferCount -= 1
                if audiobookFrameOffset < audiobookTotalFrames {
                    scheduleNextFileChunk()
                } else if scheduledBufferCount == 0, isPlaying {
                    finishFilePlayback(sessionID: sessionID)
                }
            }
        }
    }

    private func finishFilePlayback(sessionID: String?) {
        generation += 1
        timer?.cancel()
        playerNode.stop()
        scheduledBufferCount = 0
        nodePrimed = false
        audiobookFrameOffset = audiobookTotalFrames
        currentTime = duration
        timelineOrigin = duration
        progress = duration > 0 ? 1 : 0
        completedSessionID = sessionID
        playbackCompleted = true
        isPlaying = false
    }

    func stop() {
        volumeRampTimer?.invalidate()
        volumeRampTimer = nil
        generation += 1
        setPlaybackRate(1.0)
        playerNode.stop()
        timer?.cancel()
        let wasFileBacked = currentAudioFile != nil
        isPlaying = false
        hasStartedPlayback = false
        isStreamActive = false
        hasStrippedHeader = false
        scheduledBufferCount = 0
        nodePrimed = false
        pcmAccumulator = Data()
        headerAccumulator = Data()
        estimatedDuration = 0
        currentAudioFile = nil
        audiobookFrameOffset = 0
        audiobookTotalFrames = 0
        activeSessionID = nil
        completedSessionID = nil
        if wasFileBacked {
            currentTime = 0
            timelineOrigin = 0
            duration = 0
            progress = 0
        }
    }

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
                self.playerNode.volume = max(0, originalVolume - delta * Float(step))
                if step >= steps {
                    timer.invalidate()
                    self.volumeRampTimer = nil
                    self.stop()
                    self.volume = originalVolume
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

    func setPlaybackRate(_ rate: Float) {
        let clamped = max(0.5, min(2.5, rate))
        playbackRate = clamped
        timePitch.rate = clamped
    }

    private func rampVolume(to targetVolume: Float) {
        volumeRampTimer?.invalidate()
        let initialVolume = playerNode.volume
        guard abs(initialVolume - targetVolume) > 0.01 else {
            playerNode.volume = targetVolume
            return
        }
        let steps = 5
        let delta = (targetVolume - initialVolume) / Float(steps)
        var step = 0
        let token = UUID()
        volumeRampToken = token
        volumeRampTimer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            step += 1
            let newVolume = initialVolume + delta * Float(step)
            DispatchQueue.main.async {
                self.playerNode.volume = newVolume
            }
            if step >= steps {
                DispatchQueue.main.async {
                    self.playerNode.volume = targetVolume
                    if self.volumeRampToken == token {
                        self.volumeRampTimer = nil
                        self.volumeRampToken = nil
                    }
                }
                timer.invalidate()
            }
        }
    }

    private func dataToBuffer(_ data: Data) -> AVAudioPCMBuffer? {
        let frameCount = UInt32(data.count) / 2
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0 ..< Int(frameCount) {
                let lo = UInt16(raw[i * 2])
                let hi = UInt16(raw[i * 2 + 1])
                channel[i] = Float(Int16(bitPattern: lo | (hi << 8))) / 32768.0
            }
        }
        return buffer
    }

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
            let exportedURL = try Self.writeWAV(pcmData: lastAudioData, to: desktop, timestamp: timestamp)
            MetricsService.shared.trackExport(audioSeconds: renderedAudioSeconds)
            return exportedURL
        } catch let error as ExportError {
            throw error
        } catch {
            throw ExportError.couldNotSave
        }
    }

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

        let exportURL = uniqueWAVExportURL(in: directory, timestamp: timestamp, fileManager: fileManager)
        do {
            try (header + pcmData).write(to: exportURL, options: .atomic)
        } catch {
            throw ExportError.couldNotSave
        }
        return exportURL
    }

    private static func uniqueWAVExportURL(in directory: URL, timestamp: Int, fileManager: FileManager) -> URL {
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

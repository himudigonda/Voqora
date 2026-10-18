import AVFoundation
import CoreMedia
import Foundation

nonisolated protocol M4BExporting: Sendable {
    func export(_ request: M4BExportRequest, progress: @escaping @Sendable (Double) -> Void) async throws
}

nonisolated struct M4BExporter: M4BExporting {
    func export(_ request: M4BExportRequest, progress: @escaping @Sendable (Double) -> Void) async throws {
        try request.validate()
        try Task.checkCancellation()
        let job = Task.detached(priority: .userInitiated) {
            try await Self.encode(request, progress: progress)
        }
        try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
    }

    private static func encode(_ request: M4BExportRequest, progress: @escaping @Sendable (Double) -> Void) async throws {
        let workspace: URL
        do {
            workspace = try AtomicFileReplacement.makeWorkspace(near: request.outputURL)
        } catch {
            throw M4BExportError.couldNotSave
        }
        defer { AtomicFileReplacement.discard(workspace) }
        do {
            try Task.checkCancellation()
            let audio = try await M4BSourceAudio.load(request.sources)
            let timeline = M4BChapterTimeline(chapters: request.chapters, duration: audio.duration.seconds, fallbackTitle: request.title)
            let chapterTrack = try M4BChapterTrack(timeline: timeline)
            let temporaryURL = workspace.appendingPathComponent("audiobook.m4a")
            let pipeline = try M4BWriterPipeline(request: request, audio: audio, chapterTrack: chapterTrack, outputURL: temporaryURL)
            try await pipeline.run(progress: progress)
            try place(temporaryURL, at: request.outputURL)
            progress(1)
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    private static func place(_ temporaryURL: URL, at destination: URL) throws {
        do {
            try AtomicFileReplacement.moveIntoPlace(temporaryURL, at: destination)
        } catch {
            throw M4BExportError.couldNotSave
        }
    }
}

private nonisolated struct M4BSourceAudio {
    let composition: AVMutableComposition
    let track: AVMutableCompositionTrack
    let duration: CMTime

    static func load(_ sources: [URL]) async throws -> M4BSourceAudio {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw M4BExportError.unreadableAudio
        }
        var cursor = CMTime.zero
        for source in sources {
            try Task.checkCancellation()
            let range = try await append(source, to: track, at: cursor)
            cursor = CMTimeAdd(cursor, range.duration)
        }
        guard cursor.isValid, cursor.seconds > 0 else { throw M4BExportError.unreadableAudio }
        return M4BSourceAudio(composition: composition, track: track, duration: cursor)
    }

    private static func append(_ source: URL, to track: AVMutableCompositionTrack, at cursor: CMTime) async throws -> CMTimeRange {
        do {
            let asset = AVURLAsset(url: source)
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
                throw M4BExportError.unreadableAudio
            }
            let range = try await sourceTrack.load(.timeRange)
            try track.insertTimeRange(range, of: sourceTrack, at: cursor)
            return range
        } catch let error as M4BExportError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw M4BExportError.unreadableAudio
        }
    }
}

private nonisolated struct M4BChapterTrack {
    let format: CMFormatDescription
    let samples: [CMSampleBuffer]

    private static let timescale: CMTimeScale = 1000

    init(timeline: M4BChapterTimeline) throws {
        guard !timeline.entries.isEmpty else { throw M4BExportError.unreadableAudio }
        let format = try Self.makeFormat()
        self.format = format
        samples = try timeline.entries.map { try Self.makeSample(for: $0, format: format) }
    }

    private static func makeFormat() throws -> CMFormatDescription {
        let white: [String: Int] = [
            kCMTextFormatDescriptionColor_Red as String: 255,
            kCMTextFormatDescriptionColor_Green as String: 255,
            kCMTextFormatDescriptionColor_Blue as String: 255,
            kCMTextFormatDescriptionColor_Alpha as String: 255,
        ]
        let black: [String: Int] = [
            kCMTextFormatDescriptionColor_Red as String: 0,
            kCMTextFormatDescriptionColor_Green as String: 0,
            kCMTextFormatDescriptionColor_Blue as String: 0,
            kCMTextFormatDescriptionColor_Alpha as String: 255,
        ]
        let textBox: [String: Int] = [
            kCMTextFormatDescriptionRect_Top as String: 0,
            kCMTextFormatDescriptionRect_Left as String: 0,
            kCMTextFormatDescriptionRect_Bottom as String: 0,
            kCMTextFormatDescriptionRect_Right as String: 0,
        ]
        let style: [String: Any] = [
            kCMTextFormatDescriptionStyle_StartChar as String: 0,
            kCMTextFormatDescriptionStyle_EndChar as String: 0,
            kCMTextFormatDescriptionStyle_Font as String: 1,
            kCMTextFormatDescriptionStyle_FontFace as String: 0,
            kCMTextFormatDescriptionStyle_ForegroundColor as String: white,
            kCMTextFormatDescriptionStyle_FontSize as String: 12,
        ]
        let extensions: [String: Any] = [
            kCMTextFormatDescriptionExtension_DisplayFlags as String: 0,
            kCMTextFormatDescriptionExtension_BackgroundColor as String: black,
            kCMTextFormatDescriptionExtension_DefaultTextBox as String: textBox,
            kCMTextFormatDescriptionExtension_DefaultStyle as String: style,
            kCMTextFormatDescriptionExtension_HorizontalJustification as String: 0,
            kCMTextFormatDescriptionExtension_VerticalJustification as String: 0,
            kCMTextFormatDescriptionExtension_FontTable as String: ["1": "Sans-Serif"],
        ]
        var format: CMFormatDescription?
        let status = CMFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            mediaType: kCMMediaType_Text,
            mediaSubType: kCMTextFormatType_3GText,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &format
        )
        guard status == noErr, let format else { throw M4BExportError.chaptersUnsupported }
        return format
    }

    private static func makeSample(for entry: M4BChapterTimeline.Entry, format: CMFormatDescription) throws -> CMSampleBuffer {
        let payload = M4BChapterText.samplePayload(for: entry.title)
        let block = try makeBlockBuffer(containing: payload)
        var timing = CMSampleTimingInfo(
            duration: CMTime(seconds: entry.end - entry.start, preferredTimescale: timescale),
            presentationTimeStamp: CMTime(seconds: entry.start, preferredTimescale: timescale),
            decodeTimeStamp: .invalid
        )
        var size = payload.count
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else { throw M4BExportError.chaptersUnsupported }
        return sample
    }

    private static func makeBlockBuffer(containing payload: Data) throws -> CMBlockBuffer {
        var block: CMBlockBuffer?
        let created = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        )
        guard created == kCMBlockBufferNoErr, let block else { throw M4BExportError.chaptersUnsupported }
        let copied = payload.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count)
        }
        guard copied == kCMBlockBufferNoErr else { throw M4BExportError.chaptersUnsupported }
        return block
    }
}

private nonisolated enum M4BContainer: CaseIterable {
    case appleM4A
    case mpeg4
    case quickTime

    var fileType: AVFileType {
        switch self {
        case .appleM4A: .m4a
        case .mpeg4: .mp4
        case .quickTime: .mov
        }
    }

    func metadata(for request: M4BExportRequest) -> [AVMetadataItem] {
        let ids = identifiers
        var items = [
            Self.textItem(ids.title, request.title),
            Self.textItem(ids.artist, request.author),
            Self.textItem(ids.album, request.album),
            Self.textItem(ids.genre, "Audiobook"),
        ].compactMap(\.self)
        if let cover = request.cover, let format = M4BArtworkFormat(data: cover) {
            let artwork = AVMutableMetadataItem()
            artwork.identifier = ids.artwork
            artwork.value = cover as NSData
            artwork.dataType = format.metadataDataType
            items.append(artwork)
        }
        return items
    }

    private var identifiers: M4BMetadataIdentifiers {
        switch self {
        case .appleM4A, .mpeg4:
            M4BMetadataIdentifiers(
                title: .iTunesMetadataSongName,
                artist: .iTunesMetadataArtist,
                album: .iTunesMetadataAlbum,
                genre: .iTunesMetadataUserGenre,
                artwork: .iTunesMetadataCoverArt
            )
        case .quickTime:
            M4BMetadataIdentifiers(
                title: .quickTimeMetadataTitle,
                artist: .quickTimeMetadataArtist,
                album: .quickTimeMetadataAlbum,
                genre: .quickTimeMetadataGenre,
                artwork: .quickTimeMetadataArtwork
            )
        }
    }

    private static func textItem(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem? {
        guard !value.isEmpty else { return nil }
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        return item
    }
}

private nonisolated struct M4BMetadataIdentifiers {
    let title: AVMetadataIdentifier
    let artist: AVMetadataIdentifier
    let album: AVMetadataIdentifier
    let genre: AVMetadataIdentifier
    let artwork: AVMetadataIdentifier
}

private nonisolated struct M4BConfiguredWriter {
    let writer: AVAssetWriter
    let audio: AVAssetWriterInput
    let chapters: AVAssetWriterInput
}

private final nonisolated class M4BWriterPipeline {
    static let sampleRate = 44100
    private static let idleNanoseconds: UInt64 = 2_000_000
    private static let progressStep = 0.01

    private let reader: AVAssetReader
    private let readerOutput: AVAssetReaderAudioMixOutput
    private let writer: AVAssetWriter
    private let audioInput: AVAssetWriterInput
    private let chapterInput: AVAssetWriterInput
    private let chapterSamples: [CMSampleBuffer]
    private let durationSeconds: Double

    init(request: M4BExportRequest, audio: M4BSourceAudio, chapterTrack: M4BChapterTrack, outputURL: URL) throws {
        let (reader, readerOutput) = try Self.makeReader(for: audio)
        self.reader = reader
        self.readerOutput = readerOutput
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: request.bitrate,
        ]
        guard let configured = try Self.makeWriter(at: outputURL, audioSettings: audioSettings, chapterFormat: chapterTrack.format, request: request) else {
            throw M4BExportError.chaptersUnsupported
        }
        writer = configured.writer
        audioInput = configured.audio
        chapterInput = configured.chapters
        chapterSamples = chapterTrack.samples
        durationSeconds = audio.duration.seconds
    }

    func run(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard writer.startWriting() else { throw M4BExportError.encodingFailed }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            writer.cancelWriting()
            throw M4BExportError.unreadableAudio
        }
        do {
            try await pump(progress: progress)
            await finishWriting()
            guard writer.status == .completed else { throw M4BExportError.encodingFailed }
        } catch {
            cancelPipeline()
            throw error
        }
    }

    private func pump(progress: @escaping @Sendable (Double) -> Void) async throws {
        var nextChapter = 0
        var audioFinished = false
        var reported = 0.0
        while !audioFinished || nextChapter < chapterSamples.count {
            try Task.checkCancellation()
            var advanced = false
            if nextChapter < chapterSamples.count, chapterInput.isReadyForMoreMediaData {
                guard chapterInput.append(chapterSamples[nextChapter]) else { throw M4BExportError.chaptersUnsupported }
                nextChapter += 1
                if nextChapter == chapterSamples.count {
                    chapterInput.markAsFinished()
                }
                advanced = true
            }
            if !audioFinished, audioInput.isReadyForMoreMediaData {
                if let buffer = readerOutput.copyNextSampleBuffer() {
                    guard audioInput.append(buffer) else { throw M4BExportError.encodingFailed }
                    let fraction = fractionWritten(through: buffer)
                    if fraction - reported >= Self.progressStep {
                        reported = fraction
                        progress(fraction)
                    }
                } else {
                    guard reader.status == .completed else { throw M4BExportError.unreadableAudio }
                    audioInput.markAsFinished()
                    audioFinished = true
                }
                advanced = true
            }
            if !advanced {
                try await Task.sleep(nanoseconds: Self.idleNanoseconds)
            }
        }
    }

    private func finishWriting() async {
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
    }

    private func fractionWritten(through buffer: CMSampleBuffer) -> Double {
        let end = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(buffer), CMSampleBufferGetDuration(buffer))
        guard durationSeconds > 0, end.isNumeric else { return 0 }
        return min(0.99, max(0, end.seconds / durationSeconds))
    }

    private func cancelPipeline() {
        if reader.status == .reading {
            reader.cancelReading()
        }
        if writer.status == .writing {
            writer.cancelWriting()
        }
    }

    private static func makeReader(for audio: M4BSourceAudio) throws -> (AVAssetReader, AVAssetReaderAudioMixOutput) {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: audio.composition)
        } catch {
            throw M4BExportError.unreadableAudio
        }
        let pcmSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: [audio.track], audioSettings: pcmSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw M4BExportError.unreadableAudio }
        reader.add(output)
        return (reader, output)
    }

    private static func makeWriter(
        at url: URL,
        audioSettings: [String: Any],
        chapterFormat: CMFormatDescription,
        request: M4BExportRequest
    ) throws -> M4BConfiguredWriter? {
        for container in M4BContainer.allCases {
            let writer: AVAssetWriter
            do {
                writer = try AVAssetWriter(outputURL: url, fileType: container.fileType)
            } catch {
                throw M4BExportError.couldNotSave
            }
            guard writer.canApply(outputSettings: audioSettings, forMediaType: .audio) else {
                throw M4BExportError.unsupportedBitrate
            }
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput.expectsMediaDataInRealTime = false
            let chapterInput = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: chapterFormat)
            chapterInput.expectsMediaDataInRealTime = false
            chapterInput.marksOutputTrackAsEnabled = false
            guard writer.canAdd(audioInput), writer.canAdd(chapterInput) else { continue }
            writer.add(audioInput)
            writer.add(chapterInput)
            let association = AVAssetTrack.AssociationType.chapterList.rawValue
            guard audioInput.canAddTrackAssociation(withTrackOf: chapterInput, type: association) else { continue }
            audioInput.addTrackAssociation(withTrackOf: chapterInput, type: association)
            writer.metadata = container.metadata(for: request)
            writer.shouldOptimizeForNetworkUse = true
            return M4BConfiguredWriter(writer: writer, audio: audioInput, chapters: chapterInput)
        }
        return nil
    }
}

import AVFoundation
import CoreMedia
import Darwin
import Foundation
import Speech

func rssMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

struct Event: Codable { let t: Double; let text: String; let isFinal: Bool; let start: Double; let end: Double; let rss: Double }
struct Report: Codable { var events: [Event]; var setup: Double; var error: String? }

actor Log { var events: [Event] = []; func add(_ e: Event) { events.append(e) } }

@main
struct Repro {
    static func main() async {
        let args = CommandLine.arguments
        let input = URL(fileURLWithPath: args[1]); let output = URL(fileURLWithPath: args[2])
        let speed = Double(args[3]) ?? 1; let mode = args[4]
        var report = Report(events: [], setup: 0)
        do {
            let t0 = Date()
            let locale = Locale(identifier: "en-US")
            let module: any SpeechModule
            let results: AsyncThrowingStream<(String, Bool, CMTimeRange), Error>
            if mode == "dictation" {
                let m = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation], reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])
                module = m
                results = AsyncThrowingStream { c in Task { do { for try await r in m.results { c.yield((String(r.text.characters), r.isFinal, r.range)) }; c.finish() } catch { c.finish(throwing: error) } } }
            } else {
                let m = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange])
                module = m
                results = AsyncThrowingStream { c in Task { do { for try await r in m.results { c.yield((String(r.text.characters), r.isFinal, r.range)) }; c.finish() } catch { c.finish(throwing: error) } } }
            }
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [module]) { try await req.downloadAndInstall() }
            let analyzer = SpeechAnalyzer(modules: [module])
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else { throw NSError(domain: "fmt", code: 1) }
            try await analyzer.prepareToAnalyze(in: format)
            report.setup = Date().timeIntervalSince(t0)
            let log = Log(); let start = Date()
            let reader = Task { for try await (text, fin, range) in results { await log.add(Event(t: Date().timeIntervalSince(start), text: text, isFinal: fin, start: range.start.seconds, end: range.end.seconds, rss: rssMB())) } }
            let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
            try await analyzer.start(inputSequence: stream)
            let file = try AVAudioFile(forReading: input)
            let src = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: src)
            let conv = AVAudioConverter(from: file.processingFormat, to: format)!
            let all = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(file.length) * format.sampleRate / file.processingFormat.sampleRate) + 8192)!
            var fed = false
            _ = conv.convert(to: all, error: nil) { _, s in if fed { s.pointee = .endOfStream; return nil }; fed = true; s.pointee = .haveData; return src }
            let chunk = AVAudioFrameCount(format.sampleRate / 10)
            var off: AVAudioFrameCount = 0
            let clock = ContinuousClock(); let c0 = clock.now
            let bps = Int(format.streamDescription.pointee.mBytesPerFrame)
            while off < all.frameLength {
                let n = min(chunk, all.frameLength - off)
                let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!; b.frameLength = n
                let srcPtr = UnsafeRawPointer(all.audioBufferList.pointee.mBuffers.mData!) + Int(off) * bps
                memcpy(b.audioBufferList.pointee.mBuffers.mData!, srcPtr, Int(n) * bps)
                cont.yield(AnalyzerInput(buffer: b))
                off += n
                if speed > 0 { try await clock.sleep(until: c0 + .seconds(Double(off) / format.sampleRate / speed)) }
            }
            cont.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            _ = try? await reader.value
            report.events = await log.events
        } catch { report.error = "\(error)" }
        try? JSONEncoder().encode(report).write(to: output)
        exit(0)
    }
}

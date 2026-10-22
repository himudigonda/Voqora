import AVFoundation
import Darwin
import Foundation
import Speech

func rssMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

struct Event: Codable { let t: Double; let text: String; let isFinal: Bool; let segStart: Double?; let segEnd: Double?; let error: String?; let rss: Double }

@main
struct Repro {
    static func main() async throws {
        let args = CommandLine.arguments
        let input = URL(fileURLWithPath: args[1])
        let output = URL(fileURLWithPath: args[2])
        let speed = args.count > 3 ? Double(args[3])! : 1
        let status = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard status == .authorized else { try "{\"error\":\"auth \(status.rawValue)\"}".write(to: output, atomically: true, encoding: .utf8); exit(3) }
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true
        let start = Date()
        var events: [Event] = []
        let lock = NSLock()
        var done = false
        let task = recognizer.recognitionTask(with: request) { result, error in
            let segs = result?.bestTranscription.segments
            let e = Event(t: Date().timeIntervalSince(start), text: result?.bestTranscription.formattedString ?? "", isFinal: result?.isFinal ?? false,
                          segStart: segs?.first?.timestamp, segEnd: segs?.last.map { $0.timestamp + $0.duration }, error: error.map { "\($0)" }, rss: rssMB())
            lock.lock(); events.append(e); if e.isFinal || error != nil { done = true }; lock.unlock()
        }
        let file = try AVAudioFile(forReading: input)
        let mic = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: file.processingFormat, to: mic)!
        let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: source)
        let total = AVAudioPCMBuffer(pcmFormat: mic, frameCapacity: AVAudioFrameCount(Double(file.length) * 48000 / file.processingFormat.sampleRate) + 4096)!
        var fed = false
        _ = converter.convert(to: total, error: nil) { _, s in if fed { s.pointee = .endOfStream; return nil }; fed = true; s.pointee = .haveData; return source }
        let chunk: AVAudioFrameCount = 1024
        var offset: AVAudioFrameCount = 0
        let clock = ContinuousClock()
        let t0 = clock.now
        while offset < total.frameLength {
            let n = min(chunk, total.frameLength - offset)
            let b = AVAudioPCMBuffer(pcmFormat: mic, frameCapacity: n)!
            b.frameLength = n
            memcpy(b.floatChannelData![0], total.floatChannelData![0] + Int(offset), Int(n) * 4)
            request.append(b)
            offset += n
            let due = t0 + .seconds(Double(offset) / 48000 / speed)
            try await clock.sleep(until: due)
        }
        request.endAudio()
        for _ in 0 ..< 200 { lock.lock(); let d = done; lock.unlock(); if d { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        task.cancel()
        lock.lock(); let snapshot = events; lock.unlock()
        try JSONEncoder().encode(snapshot).write(to: output)
        exit(0)
    }
}

import AVFoundation
import FluidAudio
import Foundation

struct Clip: Decodable { let id: String; let path: String; let dur: Double }

func readSamples(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

let args = CommandLine.arguments
let engine = args[1]
let manifest = args[2]
let output = args[3]
let models: AsrModels
let loadStart = Date()
if engine == "parakeet" {
    models = try await AsrModels.load(from: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
} else {
    models = try AsrModels.loadLocal(from: URL(fileURLWithPath: engine), version: .ultra)
}
let manager = AsrManager(models: models)
let loadSeconds = Date().timeIntervalSince(loadStart)
let clips = try String(contentsOfFile: manifest, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(Clip.self, from: Data($0.utf8)) }
FileManager.default.createFile(atPath: output, contents: nil)
let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: output))
var audio = 0.0, compute = 0.0
for clip in clips {
    var samples = try readSamples(clip.path)
    if samples.count < 5000 { samples += [Float](repeating: 0, count: 5000 - samples.count) }
    var state = await TdtDecoderState.make(decoderLayers: manager.decoderLayerCount)
    let start = Date()
    let result = try await manager.transcribe(samples, decoderState: &state)
    let seconds = Date().timeIntervalSince(start)
    audio += clip.dur; compute += seconds
    let text = result.text.replacingOccurrences(of: "<unk>", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    let line = try JSONSerialization.data(withJSONObject: ["id": clip.id, "hyp": text, "seconds": seconds])
    handle.write(line + Data("\n".utf8))
}
print("load_s=\(String(format: "%.1f", loadSeconds)) audio_s=\(Int(audio)) compute_s=\(String(format: "%.1f", compute)) rtfx=\(String(format: "%.0f", audio / compute))")

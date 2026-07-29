import AppKit
import SwiftUI

/// Async sampler that fetches a cover JPEG, downscales it, and returns the
/// dominant color (k-means-style by averaging in chunks). Result is cached
/// in-memory keyed by URL so we don't repeat the work.
@MainActor
final class CoverColorExtractor {
    static let shared = CoverColorExtractor()

    private var cache: [URL: Color] = [:]
    private var inFlight: [URL: Task<Color, Never>] = [:]

    func dominantColor(for url: URL) async -> Color {
        if let cached = cache[url] { return cached }
        if let task = inFlight[url] { return await task.value }

        let task = Task<Color, Never> { [weak self] in
            guard let self else { return .cyan }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let image = NSImage(data: data) else { return .cyan }
                let color = Self.computeDominantColor(image)
                self.cache[url] = color
                return color
            } catch {
                return .cyan
            }
        }
        inFlight[url] = task
        let value = await task.value
        inFlight[url] = nil
        return value
    }

    private static func computeDominantColor(_ image: NSImage) -> Color {
        // Downscale to 32x32 then average. Heavy bias toward saturated pixels.
        let target = NSSize(width: 32, height: 32)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .cyan
        }
        let width = 32
        let height = 32
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .cyan }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: target.width, height: target.height))

        // Weighted average: pixels with high saturation count more.
        var rSum: Double = 0, gSum: Double = 0, bSum: Double = 0, weightSum: Double = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255
            let g = Double(pixels[i + 1]) / 255
            let b = Double(pixels[i + 2]) / 255
            let mn = min(r, g, b)
            let mx = max(r, g, b)
            let saturation = mx > 0 ? (mx - mn) / mx : 0
            // Skip near-white and near-black so the gradient doesn't get washed out.
            if mx < 0.15 || (mn > 0.85 && saturation < 0.05) { continue }
            let weight = 0.3 + saturation
            rSum += r * weight
            gSum += g * weight
            bSum += b * weight
            weightSum += weight
        }
        guard weightSum > 0 else { return .cyan }
        return Color(red: rSum / weightSum, green: gSum / weightSum, blue: bSum / weightSum)
    }
}

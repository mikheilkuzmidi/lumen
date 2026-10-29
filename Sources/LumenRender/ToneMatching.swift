import Foundation
import LumenCore

/// A redrawn face given back the photo's own colour cast. On a bluish phone photo Muse Image drew a face warmer than
/// the photo, even when told not to, and the seam showed down the neck where the redraw ended.
enum ToneMatching {
    /// `generated` with each channel under `mask` scaled so its colour cast (each channel's share of the lightness)
    /// is the original's there, keeping the redraw's own lightness, so new stubble stays dark. The scaling fades out
    /// with the mask, softened a little, so nothing outside it changes.
    static func matched(_ generated: EncodedImage, to original: EncodedImage, under mask: MaskData) throws -> EncodedImage? {
        var drawn = try RGBAPixels(generated)
        let photo = try RGBAPixels(original)
        guard let was = mean(photo, under: mask.resized(to: PixelSize(width: photo.width, height: photo.height))) else { return nil }
        let weights = mask.resized(to: PixelSize(width: drawn.width, height: drawn.height))
            .blurred(by: Double(min(drawn.width, drawn.height)) * 0.01)
        guard let now = mean(drawn, under: weights) else { return nil }
        // Gains that give the redraw the photo's cast, then scaled so its lightness is its own.
        var gains = (0..<3).map { was[$0] / max(now[$0], 1e-6) * (now[3] / max(was[3], 1e-6)) }
        let lightness = zip(luma, zip(gains, now)).reduce(0) { $0 + $1.0 * $1.1.0 * $1.1.1 }
        gains = gains.map { $0 * now[3] / max(lightness, 1e-6) }
        for index in 0..<(drawn.width * drawn.height) {
            let weight = Double(weights.coverage[index]) / 255
            guard weight > 0 else { continue }
            for channel in 0..<3 {
                let value = linear(drawn.bytes[index * 4 + channel]) * (1 + (gains[channel] - 1) * weight)
                drawn.bytes[index * 4 + channel] = encoded(value)
            }
        }
        return try drawn.encoded()
    }

    private static let luma = [0.2126, 0.7152, 0.0722]

    /// Mean linear red, green and blue under `mask`, weighted by its coverage, and their lightness.
    private static func mean(_ pixels: RGBAPixels, under mask: MaskData) -> [Double]? {
        var sums = [0.0, 0.0, 0.0], total = 0.0
        for index in 0..<(pixels.width * pixels.height) {
            let weight = Double(mask.coverage[index]) / 255
            guard weight > 0.5 else { continue }
            for channel in 0..<3 { sums[channel] += linear(pixels.bytes[index * 4 + channel]) * weight }
            total += weight
        }
        guard total > 16 else { return nil }
        let means = sums.map { $0 / total }
        return means + [zip(luma, means).reduce(0) { $0 + $1.0 * $1.1 }]
    }

    private static func linear(_ value: UInt8) -> Double {
        let c = Double(value) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func encoded(_ value: Double) -> UInt8 {
        let c = min(1, max(0, value))
        let e = c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
        return UInt8((e * 255).rounded())
    }
}

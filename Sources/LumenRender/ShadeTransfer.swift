import Foundation
import LumenCore

/// A build's new muscle as light and shade, not as new pixels. Redrawn by Muse Image, a man's T-shirt came back with
/// its waist drawn narrower than the warp's (grass inside his side), its logo moved (two crocodiles where the two met)
/// and a hand drawn in a gap. Taken as light and shade over the warped photo, the fuller chest shows and every edge,
/// print and colour stays the photo's.
enum ShadeTransfer {
    /// `original` with the broad lightness of `generated` under `mask`: both softened to about 3.5% of the crop's short
    /// side, the scale of a muscle, not of a logo (softened less, a white print the redraw left out dimmed the photo's),
    /// the redraw's overall drift taken out, its difference held within 20 (CIELAB lightness), and laid on as a change of
    /// brightness only. Where the redraw changed the colour itself (by over 12 in chroma, softened alike),
    /// nothing is laid on.
    static func shaded(_ generated: EncodedImage, onto original: EncodedImage, within mask: MaskData) throws -> EncodedImage? {
        var photo = try RGBAPixels(original)
        let drawn = try RGBAPixels(generated)
        let width = photo.width, height = photo.height, count = width * height
        guard width > 4, height > 4 else { return nil }
        let weights = mask.resized(to: PixelSize(width: width, height: height))
        func sample(_ pixels: RGBAPixels, _ index: Int) -> (UInt8, UInt8, UInt8) {
            let x = min(pixels.width - 1, (index % width) * pixels.width / width)
            let y = min(pixels.height - 1, (index / width) * pixels.height / height)
            let at = (y * pixels.width + x) * 4
            return (pixels.bytes[at], pixels.bytes[at + 1], pixels.bytes[at + 2])
        }
        var was = [Double](repeating: 0, count: count), now = was, wasChroma = was, nowChroma = was
        var drift = 0.0, covered = 0.0
        for index in 0..<count {
            let a = ColourMeasuring.lab(red: photo.bytes[index * 4], green: photo.bytes[index * 4 + 1], blue: photo.bytes[index * 4 + 2])
            let p = sample(drawn, index)
            let b = ColourMeasuring.lab(red: p.0, green: p.1, blue: p.2)
            was[index] = a.lightness; now[index] = b.lightness
            wasChroma[index] = (a.a * a.a + a.b * a.b).squareRoot(); nowChroma[index] = (b.a * b.a + b.b * b.b).squareRoot()
            let weight = Double(weights.coverage[index]) / 255
            drift += (b.lightness - a.lightness) * weight; covered += weight
        }
        guard covered > 16 else { return nil }
        drift /= covered
        let radius = max(1, Int((Double(min(width, height)) * 0.035).rounded()))
        let softWas = blurred(was, width: width, height: height, radius: radius)
        let softNow = blurred(now, width: width, height: height, radius: radius)
        let recoloured = blurred((0..<count).map { abs(nowChroma[$0] - wasChroma[$0]) }, width: width, height: height, radius: radius)
        for index in 0..<count {
            let weight = Double(weights.coverage[index]) / 255
            guard weight > 0 else { continue }
            let kept = max(0, min(1, (18 - recoloured[index]) / 6))
            let change = max(-20, min(20, softNow[index] - drift - softWas[index])) * weight * kept
            guard abs(change) > 0.05 else { continue }
            // The same colour, brighter or darker: its linear light scaled as CIELAB lightness asks.
            let gain = luminance(was[index] + change) / max(luminance(was[index]), 1e-5)
            for channel in 0..<3 {
                let value = linear(photo.bytes[index * 4 + channel]) * min(4, gain)
                photo.bytes[index * 4 + channel] = encoded(value)
            }
        }
        return try photo.encoded()
    }

    /// A box blur of `radius` run three times each way, the edge values repeated.
    private static func blurred(_ values: [Double], width: Int, height: Int, radius: Int) -> [Double] {
        var current = values
        func pass(_ input: [Double], horizontal: Bool) -> [Double] {
            var output = input
            let lines = horizontal ? height : width, length = horizontal ? width : height
            for line in 0..<lines {
                func at(_ i: Int) -> Int {
                    let c = min(max(i, 0), length - 1)
                    return horizontal ? line * width + c : c * width + line
                }
                var sum = 0.0
                for i in -radius...radius { sum += input[at(i)] }
                for i in 0..<length {
                    output[at(i)] = sum / Double(2 * radius + 1)
                    sum += input[at(i + radius + 1)] - input[at(i - radius)]
                }
            }
            return output
        }
        for _ in 0..<3 { current = pass(pass(current, horizontal: true), horizontal: false) }
        return current
    }

    /// CIELAB lightness as relative luminance.
    private static func luminance(_ lightness: Double) -> Double {
        let f = (max(0, lightness) + 16) / 116
        return f > 6.0 / 29 ? f * f * f : (f - 4.0 / 29) * 108.0 / 841
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

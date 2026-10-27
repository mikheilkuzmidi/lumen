import CoreGraphics
import Foundation
import ImageIO
import LumenCore

/// The CIELAB colour most of a render has where a mask covers it: the median of each channel, so the coffee in a cup
/// or a highlight on it doesn't pull a black cup toward grey. Measured on a sample with a long edge of at most 512
/// pixels.
enum ColourMeasuring {
    static func measure(_ image: EncodedImage, mask: MaskData?) throws -> ColourMeasurement? {
        guard let source = CGImageSourceCreateWithData(image.data as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil), decoded.width > 0, decoded.height > 0 else {
            throw LumenError.invalidResponse("The render could not be read for measurement.")
        }
        let scale = min(1, 512 / Double(max(decoded.width, decoded.height)))
        let width = max(1, Int((Double(decoded.width) * scale).rounded()))
        let height = max(1, Int((Double(decoded.height) * scale).rounded()))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw LumenError.invalidResponse("The render could not be sampled for measurement.")
            }
            context.interpolationQuality = .high
            context.draw(decoded, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let coverage = mask.map { $0.resized(to: PixelSize(width: width, height: height)).coverage }
        var lightness: [Double] = [], a: [Double] = [], b: [Double] = []
        for index in 0..<(width * height) where coverage.map({ $0[index] > 127 }) ?? true {
            let lab = Self.lab(red: pixels[index * 4], green: pixels[index * 4 + 1], blue: pixels[index * 4 + 2])
            lightness.append(lab.lightness)
            a.append(lab.a)
            b.append(lab.b)
        }
        guard !lightness.isEmpty else { return nil }
        let sorted = lightness.sorted()
        func tenth(_ fraction: Double) -> Double {
            let start = Int((Double(sorted.count) * fraction).rounded(.down))
            let part = sorted[min(start, sorted.count - 1)..<min(sorted.count, max(start + 1, start + sorted.count / 10))]
            return part.reduce(0, +) / Double(part.count)
        }
        return ColourMeasurement(lightness: median(lightness), a: median(a), b: median(b),
                                 brightest: tenth(0.9), darkest: tenth(0))
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// An sRGB colour in CIELAB, with a D65 white.
    static func lab(red: UInt8, green: UInt8, blue: UInt8) -> ColourMeasurement {
        let r = linear[Int(red)], g = linear[Int(green)], b = linear[Int(blue)]
        let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : t * 841.0 / 108 + 4.0 / 29 }
        return ColourMeasurement(lightness: 116 * f(y) - 16, a: 500 * (f(x) - f(y)), b: 200 * (f(y) - f(z)))
    }

    private static let linear: [Double] = (0..<256).map { value in
        let encoded = Double(value) / 255
        return encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
    }
}

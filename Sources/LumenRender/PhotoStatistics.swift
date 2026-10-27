import CoreImage
import Vision
import Foundation
import ImageIO
import LumenCore

/// Lightness and colour measured in sRGB on a sample with a long edge of at most 512 pixels.
struct PhotoStatistics: Sendable {
    let facts: PhotoFacts
    private let median: Double
    private let blackPoint: Double
    private let whitePoint: Double
    private let meanRed: Double
    private let meanGreen: Double
    private let meanBlue: Double
    private let saturation: Double

    init(photo: CIImage, context: CIContext, capturedAt: Date?) throws {
        let extent = photo.extent
        let scale = min(1, 512 / max(extent.width, extent.height))
        let width = max(1, Int((extent.width * scale).rounded()))
        let height = max(1, Int((extent.height * scale).rounded()))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let sample = PhotoCompositor.resized(photo, to: bounds)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let bitmap = context.createCGImage(sample, from: bounds, format: .RGBA8, colorSpace: colorSpace) else {
            throw LumenError.invalidResponse("The photo could not be rendered for measurement.")
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            guard let drawing = CGContext(data: buffer.baseAddress, width: width, height: height,
                                           bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw LumenError.invalidResponse("The photo could not be sampled for measurement.")
            }
            drawing.draw(bitmap, in: bounds)
        }
        self.init(pixels: pixels, width: width, height: height,
                  photoSize: PixelSize(width: Int(extent.width.rounded()), height: Int(extent.height.rounded())),
                  tilt: Self.tilt(in: sample), capturedAt: capturedAt)
    }

    init(pixels: [UInt8], width: Int, height: Int, photoSize: PixelSize, tilt: Double? = nil, capturedAt: Date? = nil) {
        precondition(width > 0 && height > 0 && pixels.count == width * height * 4)
        var lightness = [Double]()
        lightness.reserveCapacity(width * height)
        var red = 0.0, green = 0.0, blue = 0.0, saturation = 0.0
        var shadows = 0, highlights = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[index]) / 255
            let g = Double(pixels[index + 1]) / 255
            let b = Double(pixels[index + 2]) / 255
            let light = 0.2126 * r + 0.7152 * g + 0.0722 * b
            lightness.append(light)
            red += r
            green += g
            blue += b
            let maximum = max(r, g, b)
            saturation += maximum > 0 ? (maximum - min(r, g, b)) / maximum : 0
            if light < 0.02 { shadows += 1 }
            if light > 0.98 { highlights += 1 }
        }
        let count = Double(lightness.count)
        let sorted = lightness.sorted()
        func percentile(_ fraction: Double) -> Double {
            let position = fraction * Double(sorted.count - 1)
            let lower = Int(position), upper = min(sorted.count - 1, Int(position) + 1)
            return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
        }
        median = percentile(0.5)
        blackPoint = percentile(0.005)
        whitePoint = percentile(0.995)
        meanRed = red / count
        meanGreen = green / count
        meanBlue = blue / count
        self.saturation = saturation / count
        facts = PhotoFacts(size: photoSize,
                           sharpness: Self.sharpness(lightness, width: width, height: height),
                           exposure: lightness.reduce(0, +) / count,
                           clippedShadows: Double(shadows) / count, clippedHighlights: Double(highlights) / count,
                           tilt: tilt, capturedAt: capturedAt)
    }

    /// A gentle Auto that leaves a photo's intent alone: a high-key or night photo stays bright or dark.
    /// Exposure moves only when median lightness is outside 0.35...0.6, halfway toward that range, by at most
    /// 0.7 stop. After exposure, the 0.5% and 99.5% points set blacks and whites, capped at 10%; flat photos
    /// keep their tone range. Grey-world channel differences set temperature and tint at 30% strength, capped
    /// at 5 for temperature and 8 for tint, so a sunset or a warm room keeps its colour. Saturation below 0.25 adds 10% vibrance, except in
    /// a black-and-white photo. Exposure under 0.03 stop and colour or tone under 0.5% are left alone.
    var autoValues: [AdjustmentKey: Double] {
        var values: [AdjustmentKey: Double] = [:]
        let target = min(0.6, max(0.35, median))
        let wanted = log2(Self.linear(target) / max(0.0001, Self.linear(median)))
        let exposure = min(0.7, max(-0.7, wanted / 2))
        if abs(exposure) >= 0.03 { values[.exposure] = exposure }
        let gain = pow(2, values[.exposure] ?? 0)
        if whitePoint - blackPoint >= 0.1 {
            let black = Self.encoded(Self.linear(blackPoint) * gain)
            let white = Self.encoded(Self.linear(whitePoint) * gain)
            let blacks = -min(10, black / 0.15 * 100)
            let whites = min(10, max(0, 1 - white) / 0.15 * 100)
            if abs(blacks) >= 0.5 { values[.blacks] = blacks }
            if whites >= 0.5 { values[.whites] = whites }
        }
        let grey = (meanRed + meanGreen + meanBlue) / 3
        if grey > 0.02 {
            let temperature = min(5, max(-5, (meanBlue - meanRed) / grey * 9))
            let tint = min(8, max(-8, ((meanRed + meanBlue) / 2 - meanGreen) / grey * 15))
            if abs(temperature) >= 0.5 { values[.temperature] = temperature }
            if abs(tint) >= 0.5 { values[.tint] = tint }
        }
        if saturation < 0.25, saturation > 0.03 { values[.vibrance] = 10 }
        return values
    }

    /// Maps four-neighbour Laplacian variance v through v / (v + 0.01); variance 0.01 scores 0.5.
    private static func sharpness(_ lightness: [Double], width: Int, height: Int) -> Double {
        guard width > 2, height > 2 else { return 0 }
        var sum = 0.0, squares = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let index = y * width + x
                let laplacian = lightness[index - 1] + lightness[index + 1]
                    + lightness[index - width] + lightness[index + width] - 4 * lightness[index]
                sum += laplacian
                squares += laplacian * laplacian
            }
        }
        let count = Double((width - 2) * (height - 2))
        let variance = max(0, squares / count - pow(sum / count, 2))
        return variance / (variance + 0.01)
    }

    /// The horizon's tilt from Vision's horizon detector, positive counterclockwise (Vision reports the angle
    /// that levels it, the other way round); nil when it finds no horizon or one within 0.3°.
    static func tilt(in sample: CIImage) -> Double? {
        let request = VNDetectHorizonRequest()
        guard (try? VNImageRequestHandler(ciImage: sample).perform([request])) != nil,
              let angle = request.results?.first?.angle else { return nil }
        let degrees = -Double(angle) * 180 / .pi
        return degrees.isFinite && abs(degrees) >= 0.3 ? degrees : nil
    }

    /// Reads the original capture time, using UTC when EXIF has no offset.
    static func capturedAt(in properties: [CFString: Any]?) -> Date? {
        guard let exif = properties?[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        if let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXX"
            return formatter.date(from: original + offset)
        }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: original)
    }

    private static func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private static func encoded(_ value: Double) -> Double {
        value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
    }
}

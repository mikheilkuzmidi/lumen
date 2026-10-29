import Foundation
import LumenCore

/// A V-taper drawn by moving pixels, not by an image model. Asked for "broader shoulders and a slimmer waist", Muse
/// Image changed a body by a percent or two, or not at all; a warp changes it by exactly as much as asked, and leaves
/// the face, the clothes and their print as they were.
enum BodyReshaping {
    /// Each row of the person in `mask` scaled about their own centre line: by `shoulders` around the shoulders (the
    /// widest row between a tenth and two fifths of the way down) and by `waist` around the waist (a shoulder width
    /// below them, where it is on a standing adult, so a half-length shot finds it too). The change fades out a quarter
    /// of a shoulder width past the outline, so only the background next to the body bends.
    static func reshaped(_ image: EncodedImage, mask: MaskData, shoulders: Double, waist: Double) throws -> Reshaped? {
        let input = try RGBAPixels(image)
        let width = input.width, height = input.height
        guard width > 8, height > 8 else { return nil }
        let pixels = input.bytes
        let body = mask.resized(to: PixelSize(width: width, height: height))
        guard let shape = Shape(body), shape.shoulderWidth >= 8 else { return nil }
        var moved = pixels
        var changed = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let gain = shape.gain(at: y, shoulders: shoulders, waist: waist)
            guard abs(gain) > 0.0005, let centre = shape.centre[y], let half = shape.half[y] else { continue }
            let scale = 1 + gain
            let edge = half * scale, falloff = shape.falloff
            for x in 0..<width {
                let d = Double(x) - centre
                let source: Double
                if abs(d) <= edge {
                    source = centre + d / scale
                } else if abs(d) <= edge + falloff {
                    // The edge moved by half × gain; beside it, the background moves less, down to nothing.
                    let shift = half * gain * (1 - (abs(d) - edge) / falloff)
                    source = Double(x) - (d < 0 ? -shift : shift)
                } else {
                    continue
                }
                guard abs(source - Double(x)) > 0.25 else { continue }
                let left = min(max(Int(source.rounded(.down)), 0), width - 1), right = min(left + 1, width - 1)
                let t = min(max(source - Double(left), 0), 1)
                for channel in 0..<4 {
                    let a = Double(pixels[(y * width + left) * 4 + channel]), b = Double(pixels[(y * width + right) * 4 + channel])
                    moved[(y * width + x) * 4 + channel] = UInt8(min(255, max(0, (a + (b - a) * t).rounded())))
                }
                changed[y * width + x] = 255
            }
        }
        return Reshaped(image: try RGBAPixels(width: width, height: height, bytes: moved).encoded(),
                        changed: MaskData(size: PixelSize(width: width, height: height), coverage: changed))
    }

    /// A person's outline, row by row: its centre and half width, smoothed over a few rows so a hand or a strap doesn't
    /// kink the warp, and where its shoulders and waist are.
    struct Shape {
        var centre: [Double?]
        var half: [Double?]
        var shoulders: Int
        var waist: Int
        var shoulderWidth: Double
        /// How far past the outline the warp fades out.
        var falloff: Double { shoulderWidth * 0.25 }

        init?(_ mask: MaskData) {
            let width = mask.size.width, height = mask.size.height
            var spans: [(left: Int, right: Int)?] = Array(repeating: nil, count: height)
            for y in 0..<height {
                let row = (0..<width).filter { mask.coverage[y * width + $0] >= 128 }
                if let left = row.first, let right = row.last { spans[y] = (left, right) }
            }
            guard let top = spans.firstIndex(where: { $0 != nil }), let bottom = spans.lastIndex(where: { $0 != nil }),
                  bottom - top >= 20 else { return nil }
            let reach = max(2, (bottom - top) / 40)
            func smoothed(_ value: (Int, Int) -> Double) -> [Double?] {
                (0..<height).map { y in
                    guard spans[y] != nil else { return nil }
                    let values = (max(top, y - reach)...min(bottom, y + reach)).compactMap { spans[$0].map { value($0.left, $0.right) } }
                    return values.reduce(0, +) / Double(values.count)
                }
            }
            let halves = smoothed { Double($1 - $0 + 1) / 2 }
            let span = Double(bottom - top)
            let band = (top + Int(span * 0.1))...max(top + Int(span * 0.1), top + Int(span * 0.4))
            guard let widest = band.max(by: { (halves[$0] ?? 0) < (halves[$1] ?? 0) }), let shoulderHalf = halves[widest] else { return nil }
            centre = smoothed { Double($0 + $1) / 2 }
            half = halves
            shoulders = widest
            shoulderWidth = shoulderHalf * 2
            waist = min(bottom, widest + Int(shoulderWidth.rounded()))
        }

        /// How much row `y` widens: full at the shoulders and the waist, falling off around each, and quickly above the
        /// shoulders so the neck and head stay as they are.
        func gain(at y: Int, shoulders amount: Double, waist narrowing: Double) -> Double {
            let fromShoulders = Double(y - shoulders), fromWaist = Double(y - waist)
            let above = shoulderWidth * 0.12, below = shoulderWidth * 0.3, aroundWaist = shoulderWidth * 0.3
            let spread = fromShoulders < 0 ? above : below
            let atShoulders: Double = exp(-0.5 * (fromShoulders / spread) * (fromShoulders / spread))
            let atWaist: Double = exp(-0.5 * (fromWaist / aroundWaist) * (fromWaist / aroundWaist))
            return amount * atShoulders + narrowing * atWaist
        }
    }
}

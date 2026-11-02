import Foundation
import LumenCore

/// The generator returns a finished antialiased photograph. Preserve those
/// pixels, and fit only where that finished crop belongs on the source photo.
enum RecolourEdges {
    private static let linear: [Double] = (0...255).map {
        let value = Double($0) / 255
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    static func prepare(_ generated: EncodedImage, over original: EncodedImage, within input: MaskData) throws -> PreparedPatch? {
        guard input.followsPhoto else { return nil }
        let source = try RGBAPixels(original)
        guard source.width == generated.size.width, source.height == generated.size.height,
              min(source.width, source.height) >= 16 else { return nil }
        let width = source.width, height = source.height, count = width * height
        let size = PixelSize(width: width, height: height), mask = input.resized(to: PixelSize(width: width, height: height))
        func neighbours(_ i: Int, _ body: (Int) -> Void) {
            let x = i % width, y = i / width
            if x > 0 { body(i - 1) }; if x + 1 < width { body(i + 1) }
            if y > 0 { body(i - width) }; if y + 1 < height { body(i + width) }
        }
        var owner = [Int](repeating: 0, count: count), component = 0
        let minimum = max(2, mask.coverage.filter { $0 >= 128 }.count / 10000)
        for start in 0..<count where mask.coverage[start] >= 128 && owner[start] == 0 {
            component += 1
            var queue = [start], head = 0; owner[start] = component
            while head < queue.count {
                let i = queue[head]; head += 1
                neighbours(i) { p in
                    if mask.coverage[p] >= 128 && owner[p] == 0 { owner[p] = component; queue.append(p) }
                }
            }
            if queue.count < minimum { for i in queue { owner[i] = -1 } }
        }
        let binary = MaskData(size: size, coverage: owner.map { $0 > 0 ? 255 : 0 })
        let core = binary.inverted().grown(by: 3).inverted()
        let foreground = core.coverage.map { $0 >= 250 }
        guard foreground.contains(true) else { return nil }
        var distance = owner.map { $0 > 0 ? 0 : -1 }
        var queue = (0..<count).filter { owner[$0] > 0 }, head = 0
        while head < queue.count {
            let i = queue[head]; head += 1
            guard distance[i] < 3 else { continue }
            neighbours(i) { p in
                if distance[p] < 0 && owner[p] == 0 { owner[p] = owner[i]; distance[p] = distance[i] + 1; queue.append(p) }
            }
        }
        // Enclosed SAM-zero holes can be cord, skin, or missed cloth. They do
        // not become confident background merely because SAM omitted them.
        var exterior = [Bool](repeating: false, count: count)
        queue = []; head = 0
        for i in 0..<count where (i < width || i >= count - width || i % width == 0 || i % width == width - 1) && mask.coverage[i] < 128 {
            exterior[i] = true; queue.append(i)
        }
        while head < queue.count {
            let i = queue[head]; head += 1
            neighbours(i) { p in
                if !exterior[p] && mask.coverage[p] < 128 { exterior[p] = true; queue.append(p) }
            }
        }
        let background = (0..<count).map { owner[$0] <= 0 && exterior[$0] }
        let rgb = (0..<count).map { i in
            let p = i * 4
            return SIMD3(linear[Int(source.bytes[p])], linear[Int(source.bytes[p + 1])], linear[Int(source.bytes[p + 2])])
        }
        let initial = mask.coverage.map { Double($0) / 255 }
        let matte = ColourMatte.refined(initial, rgb: rgb, width: width, height: height, foreground: foreground, background: background)
        let coverage = (0..<count).map { i -> UInt8 in
            guard owner[i] > 0, !background[i] else { return 0 }
            // Physical alpha describes a pixel already present in the crop,
            // not a second opacity. Only its almost-transparent tail blends
            // continuously into unchanged source background. Original full
            // semantic support cannot be punched out by a sampling failure.
            let support = max(initial[i], matte[i])
            return UInt8((min(1, support / 0.04) * 255).rounded())
        }
        return PreparedPatch(image: generated, mask: MaskData(size: size, coverage: coverage, followsPhoto: true))
    }
}

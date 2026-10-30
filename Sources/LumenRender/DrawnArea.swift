import Foundation
import LumenCore

/// Where a redraw drew past its mask. A costume is bigger than the clothes it replaces: a vampire's standing collar and
/// the hem of his cape reached past the jacket's outline, and the mask's soft edge cut them off. The redraw is of the
/// whole crop, so what it drew there is already in it.
enum DrawnArea {
    /// `mask` grown over the pixels joined to it, up to `reach` away, that `generated` changed clearly from `original`
    /// once the redraw's overall colour drift is taken out (measured beyond the reach): a colour difference over 18.
    /// Its new edge is where the two agree, so no seam shows there.
    static func drawn(_ generated: EncodedImage, over original: EncodedImage, beyond mask: MaskData, reach: Int) throws -> MaskData? {
        let size = mask.size
        guard size.width > 2, size.height > 2, reach > 0 else { return nil }
        let test = try Comparison(generated, original, size: size, steady: mask.grown(by: reach).inverted())
        var coverage = mask.coverage.map { $0 >= 128 ? UInt8(255) : 0 }
        var frontier = coverage.indices.filter { coverage[$0] == 255 }
        var seen = coverage.map { $0 == 255 }
        for _ in 0..<reach where !frontier.isEmpty {
            var next: [Int] = []
            for index in frontier {
                let x = index % size.width, y = index / size.width
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < size.width, ny >= 0, ny < size.height else { continue }
                    let near = ny * size.width + nx
                    guard !seen[near] else { continue }
                    seen[near] = true
                    if test.changed(near) { coverage[near] = 255; next.append(near) }
                }
            }
            frontier = next
        }
        // Speckles of noise it took in are let go; the gaps between strands of what it drew are closed.
        let gap = max(1, reach / 20)
        let grown = MaskData(size: size, coverage: coverage)
        let closed = grown.grown(by: gap).inverted().grown(by: gap).inverted()
        return closed.union(MaskData(size: size, coverage: mask.coverage))
    }

    /// The pockets of a region SAM left out with what crosses it, which the redraw turned into the new look: the sky
    /// between a bridge's cables and over a skyline under its deck, left pale and patchy behind a new sunset. A pocket
    /// is outside `mask`, had a colour the region has in `original`, was changed clearly by `generated`, and lies
    /// within `reach` of the mask; one that runs to the crop's lower edge is ground or water, never a pocket.
    /// The redraw drew its own hangers a few pixels off the photo's: inside the pockets, what it drew that isn't its new
    /// sky is filled from the new sky around it, so only the photo's own hangers show.
    static func pockets(_ generated: EncodedImage, over original: EncodedImage, outside mask: MaskData, reach: Int) throws -> Pockets? {
        let size = mask.size
        guard size.width > 2, size.height > 2, reach > 0 else { return nil }
        let before = try RGBAPixels(original)
        var after = try RGBAPixels(generated)
        // Colours in coarse CIELAB bins; a region's colours are the bins holding at least 1 in 2,000 of its pixels: a
        // sky's gradient and its clouds, not a stray pixel of a cable.
        func bin(_ pixels: RGBAPixels, _ x: Int, _ y: Int) -> Int {
            let at = (y * pixels.width + x) * 4
            let lab = ColourMeasuring.lab(red: pixels.bytes[at], green: pixels.bytes[at + 1], blue: pixels.bytes[at + 2])
            return Int((lab.lightness / 6).rounded()) * 10_000 + Int((lab.a / 6).rounded() + 50) * 100 + Int((lab.b / 6).rounded() + 50)
        }
        func bin(_ pixels: RGBAPixels, _ index: Int) -> Int {
            bin(pixels, min(pixels.width - 1, (index % size.width) * pixels.width / size.width),
                min(pixels.height - 1, (index / size.width) * pixels.height / size.height))
        }
        func colours(of pixels: RGBAPixels) -> Set<Int> {
            var counts: [Int: Int] = [:]
            var inside = 0
            for index in 0..<(size.width * size.height) where mask.coverage[index] >= 128 {
                counts[bin(pixels, index), default: 0] += 1
                inside += 1
            }
            return Set(counts.filter { $0.value * 2_000 >= max(1, inside) }.keys)
        }
        let old = colours(of: before)
        guard !old.isEmpty else { return nil }
        let near = mask.grown(by: reach)
        // Compared as drawn: a new sky changes far more than any drift, and around a sky the redraw may change water
        // and haze too, which a drift measured there would wrongly take out of the pockets.
        let test = try Comparison(generated, original, size: size, steady: MaskData(size: size, filledWith: 0))
        // A pocket is taken whole, all of it in the region's colours, once the redraw clearly changed a third of it:
        // taken only where it changed most, the haze over a skyline came out in orange blobs on the old pale sky.
        var candidate = [UInt8](repeating: 0, count: size.width * size.height)
        for index in candidate.indices where mask.coverage[index] < 128 && old.contains(bin(before, index)) {
            candidate[index] = 255
        }
        var coverage = [UInt8](repeating: 0, count: candidate.count)
        let least = max(4, size.width * size.height / 20_000)
        for pocket in MaskData(size: size, coverage: candidate).components() where pocket.count >= least {
            guard pocket.contains(where: { near.coverage[$0] >= 128 }),
                  !pocket.contains(where: { $0 / size.width == size.height - 1 }),
                  pocket.count(where: { test.changed($0) }) * 3 >= pocket.count else { continue }
            for index in pocket { coverage[index] = 255 }
        }
        // And a pixel into the soft edge of what crosses them, never its dark core: a pale sliver of the old sky
        // stayed along each hanger.
        let lightness = (0..<(size.width * size.height)).map { index -> Double in
            let x = min(before.width - 1, (index % size.width) * before.width / size.width)
            let y = min(before.height - 1, (index / size.width) * before.height / size.height)
            let at = (y * before.width + x) * 4
            return 0.299 * Double(before.bytes[at]) + 0.587 * Double(before.bytes[at + 1]) + 0.114 * Double(before.bytes[at + 2])
        }
        let pocketLight = coverage.indices.filter { coverage[$0] == 255 }.map { lightness[$0] }.sorted()
        if !pocketLight.isEmpty {
            let floor = pocketLight[pocketLight.count / 2] - 40
            let edge = MaskData(size: size, coverage: coverage).grown(by: 1)
            for index in coverage.indices where coverage[index] == 0 && mask.coverage[index] < 128 && edge.coverage[index] >= 128
                && lightness[index] >= floor && index / size.width < size.height - 1 {
                coverage[index] = 255
            }
        }
        let found = MaskData(size: size, coverage: coverage)
        guard found.boundingBox != nil else { return nil }
        // In the redraw's own pixels: the thin lines it drew in the pockets, dark or light against the new sky around
        // them (its copy of the hangers), are filled from the new sky beside them, a ring at a time. They are told by
        // shape, not colour: a sunset's darker clouds have a hanger's colours.
        let width = after.width, height = after.height
        let inPockets = found.size == PixelSize(width: width, height: height) ? found : found.resized(to: PixelSize(width: width, height: height))
        let light = (0..<(width * height)).map { index in
            0.299 * Double(after.bytes[index * 4]) + 0.587 * Double(after.bytes[index * 4 + 1]) + 0.114 * Double(after.bytes[index * 4 + 2])
        }
        let radius = max(2, min(4, width / 500))
        func filtered(_ values: [Double], _ pick: (Double, Double) -> Double) -> [Double] {
            var rows = values
            for y in 0..<height {
                for x in 0..<width {
                    var value = values[y * width + x]
                    for dx in -radius...radius where x + dx >= 0 && x + dx < width { value = pick(value, values[y * width + x + dx]) }
                    rows[y * width + x] = value
                }
            }
            var out = rows
            for y in 0..<height {
                for x in 0..<width {
                    var value = rows[y * width + x]
                    for dy in -radius...radius where y + dy >= 0 && y + dy < height { value = pick(value, rows[(y + dy) * width + x]) }
                    out[y * width + x] = value
                }
            }
            return out
        }
        let closed = filtered(filtered(light, max), min), opened = filtered(filtered(light, min), max)
        var hole = [Bool](repeating: false, count: width * height)
        for index in hole.indices where inPockets.coverage[index] >= 128
            && (closed[index] - light[index] > 16 || light[index] - opened[index] > 16) {
            hole[index] = true
        }
        for _ in 0..<max(4, reach) where hole.contains(true) {
            var filled: [(Int, (Int, Int, Int))] = []
            for index in hole.indices where hole[index] {
                let x = index % width, y = index / width
                var sum = (0, 0, 0), count = 0
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, -1), (1, -1), (-1, 1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height, !hole[ny * width + nx] else { continue }
                    let at = (ny * width + nx) * 4
                    sum = (sum.0 + Int(after.bytes[at]), sum.1 + Int(after.bytes[at + 1]), sum.2 + Int(after.bytes[at + 2]))
                    count += 1
                }
                if count > 0 { filled.append((index, (sum.0 / count, sum.1 / count, sum.2 / count))) }
            }
            for (index, colour) in filled {
                after.bytes[index * 4] = UInt8(colour.0)
                after.bytes[index * 4 + 1] = UInt8(colour.1)
                after.bytes[index * 4 + 2] = UInt8(colour.2)
                hole[index] = false
            }
        }
        return Pockets(mask: found, image: try after.encoded())
    }

    /// Two crops compared pixel by pixel at one size, the second's drift over what was meant to stay (`steady`, or all
    /// of it) taken out.
    private struct Comparison {
        let before: RGBAPixels, after: RGBAPixels, size: PixelSize
        var drift = (0.0, 0.0, 0.0)

        init(_ generated: EncodedImage, _ original: EncodedImage, size: PixelSize, steady: MaskData?) throws {
            before = try RGBAPixels(original)
            after = try RGBAPixels(generated)
            self.size = size
            var sum = (0.0, 0.0, 0.0), samples = 0.0
            for index in stride(from: 0, to: size.width * size.height, by: 3) where (steady?.coverage[index] ?? 255) >= 128 {
                let a = sample(before, index), b = sample(after, index)
                sum = (sum.0 + b.0 - a.0, sum.1 + b.1 - a.1, sum.2 + b.2 - a.2)
                samples += 1
            }
            if samples > 0 { drift = (sum.0 / samples, sum.1 / samples, sum.2 / samples) }
        }

        func sample(_ pixels: RGBAPixels, _ index: Int) -> (Double, Double, Double) {
            let x = min(pixels.width - 1, (index % size.width) * pixels.width / size.width)
            let y = min(pixels.height - 1, (index / size.width) * pixels.height / size.height)
            let at = (y * pixels.width + x) * 4
            return (Double(pixels.bytes[at]), Double(pixels.bytes[at + 1]), Double(pixels.bytes[at + 2]))
        }

        func changed(_ index: Int) -> Bool {
            let a = sample(before, index), b = sample(after, index)
            func byte(_ value: Double) -> UInt8 { UInt8(min(255, max(0, value.rounded()))) }
            let was = ColourMeasuring.lab(red: byte(a.0), green: byte(a.1), blue: byte(a.2))
            let now = ColourMeasuring.lab(red: byte(b.0 - drift.0), green: byte(b.1 - drift.1), blue: byte(b.2 - drift.2))
            let dl = was.lightness - now.lightness, da = was.a - now.a, db = was.b - now.b
            return (dl * dl + da * da + db * db).squareRoot() > 18
        }
    }
}

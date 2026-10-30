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
        let before = try RGBAPixels(original), after = try RGBAPixels(generated)
        let size = mask.size
        guard size.width > 2, size.height > 2, reach > 0 else { return nil }
        func sample(_ pixels: RGBAPixels, _ index: Int) -> (Double, Double, Double) {
            let x = min(pixels.width - 1, (index % size.width) * pixels.width / size.width)
            let y = min(pixels.height - 1, (index / size.width) * pixels.height / size.height)
            let at = (y * pixels.width + x) * 4
            return (Double(pixels.bytes[at]), Double(pixels.bytes[at + 1]), Double(pixels.bytes[at + 2]))
        }
        let count = size.width * size.height
        // The redraw's drift over what it wasn't asked to change.
        let far = mask.grown(by: reach)
        var drift = (0.0, 0.0, 0.0), samples = 0.0
        for index in stride(from: 0, to: count, by: 3) where far.coverage[index] < 128 {
            let a = sample(before, index), b = sample(after, index)
            drift = (drift.0 + b.0 - a.0, drift.1 + b.1 - a.1, drift.2 + b.2 - a.2)
            samples += 1
        }
        if samples > 0 { drift = (drift.0 / samples, drift.1 / samples, drift.2 / samples) }
        func changed(_ index: Int) -> Bool {
            let a = sample(before, index), b = sample(after, index)
            func byte(_ value: Double) -> UInt8 { UInt8(min(255, max(0, value.rounded()))) }
            let was = ColourMeasuring.lab(red: byte(a.0), green: byte(a.1), blue: byte(a.2))
            let now = ColourMeasuring.lab(red: byte(b.0 - drift.0), green: byte(b.1 - drift.1), blue: byte(b.2 - drift.2))
            let dl = was.lightness - now.lightness, da = was.a - now.a, db = was.b - now.b
            return (dl * dl + da * da + db * db).squareRoot() > 18
        }
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
                    if changed(near) { coverage[near] = 255; next.append(near) }
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
}

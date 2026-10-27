import Foundation
import LumenCore

/// Grows a recolour's mask over neighbouring pixels of the thing's own colour. SAM's mask, held to the photo's edges,
/// can stop just inside a fender's rim or leave out its shaded lower part; the redraw recoloured them, so they would
/// keep the old colour as a fringe.
enum MaskGrowth {
    /// `mask` grown from its covered pixels into connected pixels of the same colour as the median of what it covers,
    /// at most `reach` pixels out. A colourful thing grows by hue, so its shade counts; a grey one by lightness, so a
    /// light shirt doesn't grow into the black backpack beside it.
    static func alike(_ mask: MaskData, colours: [ColourMeasurement], reach: Int) -> MaskData {
        let width = mask.size.width, height = mask.size.height
        guard reach > 0, colours.count == width * height else { return mask }
        let inside = mask.coverage.indices.filter { mask.coverage[$0] >= 128 }
        guard !inside.isEmpty else { return mask }
        func median(_ values: [Double]) -> Double { let sorted = values.sorted(); return sorted[sorted.count / 2] }
        let thing = ColourMeasurement(lightness: median(inside.map { colours[$0].lightness }),
                                      a: median(inside.map { colours[$0].a }), b: median(inside.map { colours[$0].b }))
        let colourful = thing.chroma >= 12
        func alike(_ colour: ColourMeasurement) -> Bool {
            if colourful {
                var turn = abs(colour.hue - thing.hue)
                if turn > 180 { turn = 360 - turn }
                return colour.chroma >= max(6, thing.chroma * 0.35) && turn <= 30
            }
            return colour.chroma <= 14 && abs(colour.lightness - thing.lightness) <= 15
        }
        var coverage = mask.coverage
        var distance = [Int](repeating: -1, count: coverage.count)
        var queue = inside
        for index in inside { distance[index] = 0 }
        var head = 0
        while head < queue.count {
            let index = queue[head]
            head += 1
            guard distance[index] < reach else { continue }
            let x = index % width, y = index / width
            for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                let next = ny * width + nx
                guard distance[next] < 0, alike(colours[next]) else { continue }
                distance[next] = distance[index] + 1
                coverage[next] = 255
                queue.append(next)
            }
        }
        return MaskData(size: mask.size, coverage: coverage)
    }
}

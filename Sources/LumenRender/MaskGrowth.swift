import Foundation
import LumenCore

/// Grows a recolour's mask over neighbouring pixels of the thing's own colours. SAM's mask, held to the photo's edges,
/// can stop just inside a fender's rim, leave out its shaded lower part, or cover only one colour of a two-colour
/// jacket; the redraw recoloured them, so they would keep the old colour beside the new one.
enum MaskGrowth {
    /// `mask` grown from its covered pixels into connected pixels alike to one of its main colours, at most `reach`
    /// pixels out, then by a thin ring, `fringe` pixels wide, wherever the old colour still tints the pixels: an edge
    /// where a red coat blends into snow is pink, too pale to pass for the coat, and showed as a red outline round the
    /// new one. A colourful colour grows by hue, so its shade counts; a grey one by lightness, so a light shirt doesn't
    /// grow into the black backpack beside it.
    /// A colourful colour reaches `colourfulReach` pixels (at least `reach`): a coat's strap or tab sticks out further
    /// from SAM's mask than its rim, and only connected pixels of that colour are taken.
    static func alike(_ mask: MaskData, colours: [ColourMeasurement], reach: Int, colourfulReach: Int = 0, fringe: Int = 0) -> MaskData {
        let width = mask.size.width, height = mask.size.height
        guard reach > 0, colours.count == width * height else { return mask }
        let inside = mask.coverage.indices.filter { mask.coverage[$0] >= 128 }
        guard !inside.isEmpty else { return mask }
        let main = mainColours(inside.map { colours[$0] })
        guard !main.isEmpty else { return mask }
        func alike(_ colour: ColourMeasurement) -> Bool { main.contains { matches(colour, $0) } }
        var coverage = mask.coverage
        var distance = [Int](repeating: -1, count: coverage.count)
        var queue = inside
        for index in inside { distance[index] = 0 }
        func grow(limit: Int, accepts: (ColourMeasurement) -> Bool) {
            var head = 0
            while head < queue.count {
                let index = queue[head]
                head += 1
                guard distance[index] < limit else { continue }
                let x = index % width, y = index / width
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    let next = ny * width + nx
                    guard distance[next] < 0, accepts(colours[next]) else { continue }
                    distance[next] = distance[index] + 1
                    coverage[next] = 255
                    queue.append(next)
                }
            }
        }
        grow(limit: reach, accepts: alike)
        let tints = main.filter { $0.chroma >= 12 }
        if colourfulReach > reach, !tints.isEmpty {
            queue = coverage.indices.filter { coverage[$0] >= 128 }
            for index in distance.indices { distance[index] = coverage[index] >= 128 ? 0 : -1 }
            grow(limit: colourfulReach - reach) { colour in tints.contains { matches(colour, $0) } }
        }
        func tinted(_ colour: ColourMeasurement) -> Bool {
            tints.contains { tint in colour.chroma >= 6 && turn(colour.hue, tint.hue) <= 40 }
        }
        // The mask's own soft edge: a pixel it covers only partly shows that share of the old colour through the new
        // one, a red line along a sleeve redrawn navy. Where the pixel is the thing's colourful colour, or tinted by it,
        // it is covered fully.
        // Only a colourful thing's: firming a grey shirt's edge would take in a grey hand beside it, which the redraw
        // may have coloured.
        for index in coverage.indices where coverage[index] > 0 && coverage[index] < 255 {
            if tints.contains(where: { matches(colours[index], $0) }) || tinted(colours[index]) { coverage[index] = 255 }
        }
        // The ring: from everything covered so far, a few pixels more wherever a colourful main colour still tints them.
        if fringe > 0, !tints.isEmpty {
            queue = coverage.indices.filter { coverage[$0] >= 128 }
            for index in distance.indices { distance[index] = coverage[index] >= 128 ? 0 : -1 }
            grow(limit: fringe, accepts: tinted)
        }
        return MaskData(size: mask.size, coverage: coverage, followsPhoto: mask.followsPhoto)
    }

    /// The colours that each cover at least a tenth of `pixels` (at most three), each as the median of its pixels: a
    /// grey and red jacket has two, even when SAM's mask holds only a little of the red. Colourful pixels are grouped by
    /// 30° of hue, grey ones by lightness.
    static func mainColours(_ pixels: [ColourMeasurement]) -> [ColourMeasurement] {
        guard !pixels.isEmpty else { return [] }
        var groups: [Int: [ColourMeasurement]] = [:]
        for colour in pixels {
            let key = colour.chroma >= 12 ? Int(colour.hue / 30) % 12 : 100 + min(4, Int(colour.lightness / 20))
            groups[key, default: []].append(colour)
        }
        func median(_ values: [Double]) -> Double { let sorted = values.sorted(); return sorted[sorted.count / 2] }
        return groups.values.filter { $0.count * 10 >= pixels.count }.sorted { $0.count > $1.count }.prefix(3).map { group in
            ColourMeasurement(lightness: median(group.map(\.lightness)), a: median(group.map(\.a)), b: median(group.map(\.b)))
        }
    }

    private static func matches(_ colour: ColourMeasurement, _ main: ColourMeasurement) -> Bool {
        if main.chroma >= 12 {
            return colour.chroma >= max(6, main.chroma * 0.35) && turn(colour.hue, main.hue) <= 30
        }
        return colour.chroma <= 14 && abs(colour.lightness - main.lightness) <= 15
    }

    private static func turn(_ a: Double, _ b: Double) -> Double {
        let difference = abs(a - b).truncatingRemainder(dividingBy: 360)
        return difference > 180 ? 360 - difference : difference
    }
}

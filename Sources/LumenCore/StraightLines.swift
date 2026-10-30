import Foundation

/// The long straight lines of a photo's lightness (rows from the top, 0...1, on a sample of about 512 pixels), which
/// say whether its camera was rolled: walls and poles stand plumb, and a horizon lies level, unless it was.
public enum StraightLines {
    /// The lean of the photo's long upright lines (walls, poles, window frames), in degrees positive counterclockwise,
    /// from the straight lines within 12° of upright that run at least 12% of the photo's height: their lean at the
    /// photo's middle (`rollAtTheMiddle`), else their length-weighted median direction. A rolled camera leans them all.
    /// Nil when they add up to under three times the photo's height: forest, water or a crowd make few such lines, and
    /// their lean would read upright however the camera was rolled.
    public static func verticalLean(_ lightness: [Double], width: Int, height: Int) -> Double? {
        guard let lines = uprightLines(lightness, width: width, height: height),
              lines.reduce(0, { $0 + $1.length }) >= Double(height) * 3 else { return nil }
        return rollAtTheMiddle(of: lines, height: Double(height)) ?? median(of: lines.map { ($0.lean, $0.length) })
    }

    /// A camera pitched up or down converges upright lines: each leans in proportion to how far from the middle it
    /// stands, and a roll adds the same lean to all of them. So the roll is the lean that a straight-line fit of lean
    /// against position gives at the middle. A median follows whichever side has more lines: a café's door and window
    /// frames on its right read as a 1.6° roll, and straightening it by that leaned the rest of the room 2.4°.
    /// Nil unless lines stand on both sides of the middle, a photo's height of them on each, and the fit explains
    /// their leans clearly better than one lean for all.
    static func rollAtTheMiddle(of lines: [(lean: Double, length: Double, position: Double)], height: Double) -> Double? {
        let left = lines.filter { $0.position < -0.1 }.reduce(0) { $0 + $1.length }
        let right = lines.filter { $0.position > 0.1 }.reduce(0) { $0 + $1.length }
        guard left >= height, right >= height else { return nil }
        func fit(_ lines: [(lean: Double, length: Double, position: Double)]) -> (middle: Double, slope: Double)? {
            let total = lines.reduce(0) { $0 + $1.length }
            guard total > 0 else { return nil }
            let position = lines.reduce(0) { $0 + $1.length * $1.position } / total
            let lean = lines.reduce(0) { $0 + $1.length * $1.lean } / total
            let spread = lines.reduce(0) { $0 + $1.length * pow($1.position - position, 2) }
            guard spread > 0 else { return nil }
            let slope = lines.reduce(0) { $0 + $1.length * ($1.position - position) * ($1.lean - lean) } / spread
            return (lean - slope * position, slope)
        }
        func error(_ lines: [(lean: Double, length: Double, position: Double)], _ lean: (Double) -> Double) -> Double {
            let total = lines.reduce(0) { $0 + $1.length }
            return (lines.reduce(0) { $0 + $1.length * pow($1.lean - lean($1.position), 2) } / total).squareRoot()
        }
        // Once more without the lines that miss the first fit by over 1.5°: a table's edge or a leaning ladder.
        guard let first = fit(lines) else { return nil }
        let kept = lines.filter { abs($0.lean - (first.middle + first.slope * $0.position)) <= 1.5 }
        guard kept.reduce(0, { $0 + $1.length }) >= height * 2, let line = fit(kept),
              let flat = median(of: kept.map { ($0.lean, $0.length) }) else { return nil }
        return error(kept, { line.middle + line.slope * $0 }) <= 0.6 * error(kept, { _ in flat }) ? line.middle : nil
    }

    /// The tilt of the photo's long level lines (a horizon, a shoreline), in degrees positive counterclockwise like
    /// `tilt`: the length-weighted median of the straight lines within 12° of level that run at least 35% of the photo's
    /// width. Nil when they add up to under half its width: a canyon's ridge or water seen from above has none.
    public static func levelTilt(_ lightness: [Double], width: Int, height: Int) -> Double? {
        // The same search over the photo turned on its side: a level line becomes an upright one, leaning the other way.
        var turned = [Double](repeating: 0, count: lightness.count)
        for y in 0..<height { for x in 0..<width { turned[x * height + y] = lightness[y * width + x] } }
        return median(of: uprightLines(turned, width: height, height: width, longest: 0.35)?.map { ($0.lean, $0.length) },
                      atLeast: Double(width) * 0.5).map { -$0 }
    }

    /// The length-weighted median lean of some lines; nil when they add up to less than `atLeast` pixels.
    static func median(of lines: [(lean: Double, length: Double)]?, atLeast: Double = 0) -> Double? {
        guard let lines, !lines.isEmpty, lines.reduce(0, { $0 + $1.length }) >= max(1, atLeast) else { return nil }
        let sorted = lines.sorted { $0.lean < $1.lean }
        let total = sorted.reduce(0) { $0 + $1.length }
        var running = 0.0
        for line in sorted {
            running += line.length
            if running >= total / 2 { return line.lean }
        }
        return nil
    }

    /// Straight near-vertical lines found by a Hough transform over strong edges: each edge pixel votes, at its own
    /// direction and 1.5° either side (a faint edge's direction is that uncertain), for the line through it, by where
    /// that line crosses the middle row. A line's position is where it crosses that row, -0.5 at the left edge to 0.5
    /// at the right.
    static func uprightLines(_ lightness: [Double], width: Int, height: Int,
                             longest: Double = 0.12) -> [(lean: Double, length: Double, position: Double)]? {
        guard width > 2, height > 2 else { return nil }
        let steps = 49, half = Double(height) / 2
        let tangents = (0..<steps).map { tan((Double($0) / 2 - 12) * .pi / 180) }
        let span = width + 2 * Int(ceil(Double(height) * tan(12 * .pi / 180)))
        let offset = (span - width) / 2
        var votes = [Int](repeating: 0, count: steps * span)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let gx = (lightness[i - width + 1] + 2 * lightness[i + 1] + lightness[i + width + 1])
                    - (lightness[i - width - 1] + 2 * lightness[i - 1] + lightness[i + width - 1])
                let gy = (lightness[i + width - 1] + 2 * lightness[i + width] + lightness[i + width + 1])
                    - (lightness[i - width - 1] + 2 * lightness[i - width] + lightness[i - width + 1])
                guard gx * gx + gy * gy > 0.0144, gx != 0 else { continue }
                // An upright edge's gradient runs across it: the edge leans by the gradient's angle from horizontal.
                let deviation = atan(gy / gx) * 180 / .pi
                guard abs(deviation) <= 12.5 else { continue }
                let centre = Int(((deviation + 12) * 2).rounded())
                for step in max(0, centre - 3)...min(steps - 1, centre + 3) {
                    // Where the line through (x, y) at this lean crosses the middle row.
                    let crossing = Int((Double(x) + (Double(y) - half) * tangents[step]).rounded()) + offset
                    guard crossing >= 0, crossing < span else { continue }
                    votes[step * span + crossing] += 1
                }
            }
        }
        // A line holds the votes of a 3 px band (rounding scatters one line's votes across neighbouring cells) that
        // beats its neighbours within 3 px and a degree, and runs `longest` of the height.
        var bands = votes
        for step in 0..<steps {
            for crossing in 0..<span {
                let row = step * span
                bands[row + crossing] = votes[row + max(0, crossing - 1)] + votes[row + crossing] + votes[row + min(span - 1, crossing + 1)]
            }
        }
        let long = Int(Double(height) * longest)
        var lines: [(lean: Double, length: Double, position: Double)] = []
        for step in 0..<steps {
            for crossing in 0..<span {
                let count = bands[step * span + crossing]
                guard count >= long else { continue }
                var best = true
                for neighbour in max(0, step - 2)...min(steps - 1, step + 2) where best {
                    for other in max(0, crossing - 3)...min(span - 1, crossing + 3) where (neighbour, other) != (step, crossing) {
                        let rival = bands[neighbour * span + other]
                        if rival > count || (rival == count && (neighbour, other) < (step, crossing)) { best = false; break }
                    }
                }
                // Rows run down the photo, so a gradient's angle is clockwise; counterclockwise is its negative.
                if best { lines.append((-(Double(step) / 2 - 12), Double(count), Double(crossing - offset) / Double(width) - 0.5)) }
            }
        }
        return lines
    }
}

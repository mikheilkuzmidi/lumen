import Foundation

/// How sharp a photo's lightness is (rows from the top, 0...1): fine detail from 0 (none) to 1 (crisp).
public enum Sharpness {
    /// The sharpness of the photo's sharpest part: the second sharpest of a 6 × 6 grid of tiles, so one noisy tile
    /// doesn't decide. Soft clouds over a crisp town score low as a whole but high here; a shaken frame has no sharp
    /// part at all.
    public static func peak(_ lightness: [Double], width: Int, height: Int) -> Double {
        let columns = 6, rows = 6
        let tileWidth = width / columns, tileHeight = height / rows
        guard tileWidth > 2, tileHeight > 2 else { return of(lightness, width: width, height: height) }
        var scores: [Double] = []
        for row in 0..<rows {
            for column in 0..<columns {
                var tile = [Double]()
                tile.reserveCapacity(tileWidth * tileHeight)
                for y in (row * tileHeight)..<((row + 1) * tileHeight) {
                    let start = y * width + column * tileWidth
                    tile.append(contentsOf: lightness[start..<(start + tileWidth)])
                }
                scores.append(of(tile, width: tileWidth, height: tileHeight))
            }
        }
        return scores.sorted(by: >)[1]
    }

    /// Maps four-neighbour Laplacian variance v through v / (v + 0.01); variance 0.01 scores 0.5.
    public static func of(_ lightness: [Double], width: Int, height: Int) -> Double {
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
}

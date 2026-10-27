import CoreGraphics
import Foundation
import ImageIO
import LumenCore

/// Where a redraw lost the detail the photo had: a smeared headlight or a melted edge keeps its colour but loses its
/// fine detail, which a recolour keeps. Measured cell by cell on samples of at most 384 pixels, as how far each pixel
/// stands from its eight neighbours.
enum DetailMeasuring {
    /// A cell with less fine detail than this had none to lose.
    static let detailed = 0.01
    /// A cell left with less than this share of its fine detail lost it. A clean redraw keeps at least about 37% of
    /// it everywhere; a smeared headlight kept 15% and 25% (measured October 27).
    static let kept = 0.3
    /// Cells along the long edge.
    static let cellsAcross = 32

    static func lost(before: EncodedImage, after: EncodedImage) throws -> [LostDetail] {
        guard let was = try detail(before), let now = try detail(after, size: was.size) else { return [] }
        let width = was.size.width, height = was.size.height
        let cell = max(6, max(width, height) / cellsAcross)
        let columns = (width + cell - 1) / cell, rows = (height + cell - 1) / cell
        var shares = [Double?](repeating: nil, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                var then = 0.0, later = 0.0, count = 0.0
                for y in (row * cell)..<min(height, (row + 1) * cell) {
                    for x in (column * cell)..<min(width, (column + 1) * cell) {
                        then += was.values[y * width + x]
                        later += now.values[y * width + x]
                        count += 1
                    }
                }
                if count > 0, then / count >= detailed, later < then * kept { shares[row * columns + column] = later / then }
            }
        }
        // Neighbouring cells are one place, with the least any of them kept.
        var seen = [Bool](repeating: false, count: shares.count)
        var places: [LostDetail] = []
        for start in shares.indices where shares[start] != nil && !seen[start] {
            var stack = [start], left = columns, right = 0, top = rows, bottom = 0, least = 1.0
            seen[start] = true
            while let index = stack.popLast() {
                let column = index % columns, row = index / columns
                left = min(left, column); right = max(right, column); top = min(top, row); bottom = max(bottom, row)
                least = min(least, shares[index] ?? 1)
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1), (-1, 1), (1, -1)] {
                    let x = column + dx, y = row + dy
                    guard x >= 0, x < columns, y >= 0, y < rows else { continue }
                    let next = y * columns + x
                    if shares[next] != nil && !seen[next] { seen[next] = true; stack.append(next) }
                }
            }
            let x = Double(left * cell) / Double(width), y = Double(top * cell) / Double(height)
            let rect = NormalizedRect(x: x, y: y, width: min(1, Double((right + 1) * cell) / Double(width)) - x,
                                      height: min(1, Double((bottom + 1) * cell) / Double(height)) - y)
            places.append(LostDetail(rect: rect, kept: least))
        }
        return places.sorted { $0.kept < $1.kept }
    }

    /// Fine detail of an encoded image's lightness, at most 384 pixels on its long edge or at `size`: how far each
    /// pixel stands from the mean of its eight neighbours. A smear's own soft edges have little of it.
    private static func detail(_ image: EncodedImage, size: PixelSize? = nil) throws -> (values: [Double], size: PixelSize)? {
        guard let source = CGImageSourceCreateWithData(image.data as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil), decoded.width > 2, decoded.height > 2 else {
            throw LumenError.invalidResponse("The close-up could not be read for measurement.")
        }
        let scale = min(1, 384 / Double(max(decoded.width, decoded.height)))
        let target = size ?? PixelSize(width: max(3, Int((Double(decoded.width) * scale).rounded())),
                                       height: max(3, Int((Double(decoded.height) * scale).rounded())))
        var pixels = [UInt8](repeating: 0, count: target.width * target.height)
        try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: target.width, height: target.height,
                                          bitsPerComponent: 8, bytesPerRow: target.width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                throw LumenError.invalidResponse("The close-up could not be sampled for measurement.")
            }
            context.interpolationQuality = .high
            context.draw(decoded, in: CGRect(x: 0, y: 0, width: target.width, height: target.height))
        }
        var values = [Double](repeating: 0, count: pixels.count)
        for y in 1..<(target.height - 1) {
            for x in 1..<(target.width - 1) {
                let index = y * target.width + x
                var around = 0.0
                for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 { around += Double(pixels[index + dy * target.width + dx]) } }
                values[index] = abs(Double(pixels[index]) - around / 8) / 255
            }
        }
        return (values, target)
    }
}

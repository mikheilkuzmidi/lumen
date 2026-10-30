import Foundation
import LumenCore

/// A person's bare skin, found by the colour of their own face: their neck and ears, hands and arms, a bare chest. A
/// face made 30 years older over a young neck, or zombie make-up that stopped at the jaw, showed where the face's mask
/// ended.
enum SkinFinding {
    /// What `person` covers in `image` that has the colour of the skin `face` covers. The face's skin is its middle
    /// tones (eyes, brows, nostrils and stubble are darker, a shine lighter); skin elsewhere is that hue, as colourful
    /// give or take a half (shade and light change it), and no more than a little darker or lighter than the face goes.
    /// Clothes, hair and what is behind them differ in hue or colourfulness. Nil when the face shows too little skin.
    static func skin(_ image: EncodedImage, face: MaskData, person: MaskData) throws -> MaskData? {
        let pixels = try RGBAPixels(image)
        let size = PixelSize(width: pixels.width, height: pixels.height)
        let face = face.size == size ? face : face.resized(to: size)
        let person = person.size == size ? person : person.resized(to: size)
        func lab(_ index: Int) -> ColourMeasurement {
            ColourMeasuring.lab(red: pixels.bytes[index * 4], green: pixels.bytes[index * 4 + 1], blue: pixels.bytes[index * 4 + 2])
        }
        let faced = (0..<(size.width * size.height)).filter { face.coverage[$0] >= 128 }.map(lab)
        guard faced.count >= 64 else { return nil }
        let lightness = faced.map(\.lightness).sorted()
        let low = lightness[Int(Double(lightness.count) * 0.3)], high = lightness[Int(Double(lightness.count) * 0.95)]
        let tones = faced.filter { $0.lightness >= low && $0.lightness <= high }
        guard tones.count >= 32 else { return nil }
        let hues = tones.map { atan2($0.b, $0.a) * 180 / .pi }
        let chromas = tones.map { ($0.a * $0.a + $0.b * $0.b).squareRoot() }
        let hue = median(hues), chroma = median(chromas)
        // Skin has colour: a face that measures grey (a black-and-white photo, a mask) gives nothing to match.
        guard chroma >= 6 else { return nil }
        let spread = median(hues.map { abs($0 - hue) }) * 1.4826
        let hueReach = min(20, max(9, spread * 3))
        let middle = median(tones.map(\.lightness))
        // Two passes: skin as sure as the face's own, then, joined to it, skin a little redder, more or less colourful
        // or lit: fingertips and knuckles are redder than a face, and the hands made up as zombies kept pink thumbs.
        var coverage = [UInt8](repeating: 0, count: size.width * size.height)
        var likely = [Bool](repeating: false, count: coverage.count)
        for index in coverage.indices where person.coverage[index] >= 128 {
            let colour = lab(index)
            let c = (colour.a * colour.a + colour.b * colour.b).squareRoot()
            var signed = atan2(colour.b, colour.a) * 180 / .pi - hue
            if signed > 180 { signed -= 360 } else if signed <= -180 { signed += 360 }
            let turn = abs(signed)
            let lit = colour.lightness >= middle - 32 && colour.lightness <= middle + 26
            if c >= chroma * 0.5, c <= chroma * 1.7, colour.lightness >= middle - 28, colour.lightness <= middle + 20,
               turn <= hueReach {
                coverage[index] = 255
            } else if c >= chroma * 0.35, c <= chroma * 2.4, lit, turn <= min(35, hueReach * 2) {
                likely[index] = true
            } else if signed < 0, turn <= 75, c >= chroma * 0.35, c <= chroma * 1.6, lit {
                // Redder still, never yellower: a sunlit thumb over white trousers read 37° to 69° pinker than the face
                // and was left pink by zombie make-up. Wood and clothes in skin's tones lie the other way; a red
                // sleeve is more colourful than this.
                likely[index] = true
            }
        }
        // No further than a tenth of the face's height from sure skin: further, it ran along a wooden bench under a hand.
        let rows = Set((0..<(size.width * size.height)).filter { face.coverage[$0] >= 128 }.map { $0 / size.width })
        let reach = max(3, rows.count / 10)
        var frontier = coverage.indices.filter { coverage[$0] == 255 }
        for _ in 0..<reach where !frontier.isEmpty {
            var next: [Int] = []
            for index in frontier {
                let x = index % size.width, y = index / size.width
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < size.width, ny >= 0, ny < size.height else { continue }
                    let near = ny * size.width + nx
                    if likely[near] { likely[near] = false; coverage[near] = 255; next.append(near) }
                }
            }
            frontier = next
        }
        // Lone pixels of a skin-coloured print or a lit fold are not skin: each kept pixel has most of its neighbours.
        var cleaned = coverage
        for y in 1..<(size.height - 1) {
            for x in 1..<(size.width - 1) where coverage[y * size.width + x] == 255 {
                var around = 0
                for dy in -1...1 { for dx in -1...1 where coverage[(y + dy) * size.width + x + dx] == 255 { around += 1 } }
                if around < 5 { cleaned[y * size.width + x] = 0 }
            }
        }
        return MaskData(size: size, coverage: cleaned)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }
}

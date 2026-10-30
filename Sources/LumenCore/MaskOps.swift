import Foundation

extension MaskData {
    /// Measures shared coverage against combined coverage at this mask's size; empty masks overlap by zero.
    public func intersectionOverUnion(_ other: MaskData) -> Double {
        let other = other.size == size ? other : other.resized(to: size)
        var intersection = 0.0
        var union = 0.0
        for (first, second) in zip(coverage, other.coverage) {
            intersection += Double(min(first, second))
            union += Double(max(first, second))
        }
        return union > 0 ? intersection / union : 0
    }

    /// The smallest rectangle containing every pixel with coverage.
    public var boundingBox: NormalizedRect? {
        guard size.width > 0, size.height > 0 else { return nil }
        var left = size.width
        var top = size.height
        var right = 0
        var bottom = 0
        for y in 0..<size.height {
            for x in 0..<size.width where self[x, y] > 0 {
                left = min(left, x)
                top = min(top, y)
                right = max(right, x + 1)
                bottom = max(bottom, y + 1)
            }
        }
        guard left < right, top < bottom else { return nil }
        return NormalizedRect(x: Double(left) / Double(size.width), y: Double(top) / Double(size.height),
                              width: Double(right - left) / Double(size.width),
                              height: Double(bottom - top) / Double(size.height))
    }

    /// How much of the coverage lies inside a rectangle on the photo, 0...1; an empty mask has none inside.
    public func share(inside rect: NormalizedRect) -> Double {
        guard size.width > 0, size.height > 0 else { return 0 }
        let left = Int((rect.x * Double(size.width)).rounded()), right = Int(((rect.x + rect.width) * Double(size.width)).rounded())
        let top = Int((rect.y * Double(size.height)).rounded()), bottom = Int(((rect.y + rect.height) * Double(size.height)).rounded())
        var total = 0, inside = 0
        for y in 0..<size.height {
            let rowInside = y >= top && y < bottom
            for x in 0..<size.width {
                let value = Int(self[x, y])
                total += value
                if rowInside && x >= left && x < right { inside += value }
            }
        }
        return total > 0 ? Double(inside) / Double(total) : 0
    }

    /// Combines coverage, resizing the other mask to this mask's size if needed.
    public func union(_ other: MaskData) -> MaskData {
        let other = other.size == size ? other : other.resized(to: size)
        return MaskData(size: size, coverage: zip(coverage, other.coverage).map { max($0, $1) },
                        followsPhoto: followsPhoto || other.followsPhoto)
    }

    /// Selects the share of each pixel this mask leaves untouched.
    public func inverted() -> MaskData {
        MaskData(size: size, coverage: coverage.map { 255 - $0 }, followsPhoto: followsPhoto)
    }

    /// Keeps the pixels intersecting a rectangle on the photo.
    public func cropped(to rect: NormalizedRect) -> MaskData {
        guard size.width > 0, size.height > 0, let rect = rect.onPhoto else {
            return MaskData(size: PixelSize(width: 0, height: 0), coverage: [])
        }
        func edge(_ value: Double, length: Int) -> Double {
            let pixel = value * Double(length)
            let nearest = pixel.rounded()
            return abs(pixel - nearest) <= pixel.ulp * 4 ? nearest : pixel
        }
        let left = Int(floor(edge(rect.x, length: size.width)))
        let top = Int(floor(edge(rect.y, length: size.height)))
        let right = min(size.width, Int(ceil(edge(rect.x + rect.width, length: size.width))))
        let bottom = min(size.height, Int(ceil(edge(rect.y + rect.height, length: size.height))))
        let croppedSize = PixelSize(width: right - left, height: bottom - top)
        var pixels: [UInt8] = []
        pixels.reserveCapacity(croppedSize.width * croppedSize.height)
        for y in top..<bottom {
            pixels.append(contentsOf: coverage[(y * size.width + left)..<(y * size.width + right)])
        }
        return MaskData(size: croppedSize, coverage: pixels, followsPhoto: followsPhoto)
    }

    /// Resamples coverage with bilinear interpolation at pixel centers.
    public func resized(to target: PixelSize) -> MaskData {
        precondition(target.width >= 0 && target.height >= 0, "mask dimensions cannot be negative")
        guard size != target else { return self }
        guard size.width > 0, size.height > 0, target.width > 0, target.height > 0 else {
            return MaskData(size: target, filledWith: 0)
        }
        var pixels = [UInt8](repeating: 0, count: target.width * target.height)
        for y in 0..<target.height {
            let sourceY = min(Double(size.height - 1), max(0, (Double(y) + 0.5) * Double(size.height) / Double(target.height) - 0.5))
            let top = Int(sourceY)
            let bottom = min(top + 1, size.height - 1)
            let dy = sourceY - Double(top)
            for x in 0..<target.width {
                let sourceX = min(Double(size.width - 1), max(0, (Double(x) + 0.5) * Double(size.width) / Double(target.width) - 0.5))
                let left = Int(sourceX)
                let right = min(left + 1, size.width - 1)
                let dx = sourceX - Double(left)
                let above = Double(self[left, top]) * (1 - dx) + Double(self[right, top]) * dx
                let below = Double(self[left, bottom]) * (1 - dx) + Double(self[right, bottom]) * dx
                pixels[y * target.width + x] = UInt8((above * (1 - dy) + below * dy).rounded())
            }
        }
        return MaskData(size: target, coverage: pixels, followsPhoto: followsPhoto)
    }

    /// Extends coverage to pixels within a circular pixel radius.
    public func grown(by radius: Int) -> MaskData {
        guard radius > 0, size.width > 0, size.height > 0 else { return self }
        var pixels = coverage
        let verticalRadius = min(radius, size.height - 1)
        for offsetY in -verticalRadius...verticalRadius {
            let reach = sqrt(max(0, Double(radius) * Double(radius) - Double(offsetY) * Double(offsetY)))
            let horizontalRadius = Int(min(Double(size.width - 1), reach))
            for y in max(0, -offsetY)..<min(size.height, size.height - offsetY) {
                // A sliding maximum keeps wide growth radii from scanning each neighborhood again.
                var row: [Int] = []
                var head = 0
                var next = 0
                for x in 0..<size.width {
                    let end = min(size.width - 1, x + horizontalRadius)
                    while next <= end {
                        while row.count > head, self[row[row.count - 1], y + offsetY] <= self[next, y + offsetY] {
                            row.removeLast()
                        }
                        row.append(next)
                        next += 1
                    }
                    while row[head] < x - horizontalRadius { head += 1 }
                    let index = y * size.width + x
                    pixels[index] = max(pixels[index], self[row[head], y + offsetY])
                }
            }
        }
        return MaskData(size: size, coverage: pixels, followsPhoto: followsPhoto)
    }

    /// A ramp over a photo of `size`: full at `from`, none at `to` and beyond, eased in between (smoothstep), measured
    /// in pixels so its direction holds on a wide photo.
    public static func gradient(size: PixelSize, from: NormalizedPoint, to: NormalizedPoint) -> MaskData {
        let width = Double(size.width), height = Double(size.height)
        let dx = (to.x - from.x) * width, dy = (to.y - from.y) * height
        let length = dx * dx + dy * dy
        var coverage = [UInt8](repeating: 0, count: size.width * size.height)
        guard length > 0 else { return MaskData(size: size, coverage: coverage, followsPhoto: false) }
        for y in 0..<size.height {
            for x in 0..<size.width {
                let px = (Double(x) + 0.5) - from.x * width, py = (Double(y) + 0.5) - from.y * height
                let along = min(1, max(0, (px * dx + py * dy) / length))
                let eased = 1 - along * along * (3 - 2 * along)
                coverage[y * size.width + x] = UInt8((eased * 255).rounded())
            }
        }
        return MaskData(size: size, coverage: coverage, followsPhoto: false)
    }

    /// The shadow this mask's subject casts on the ground: its base row stays where it stands, and each row above it is
    /// laid along the ground toward `tip`, where the subject's top lands, so a low sun's long shadow stretches out from
    /// its feet. Each separate figure in it (a group of hikers on rocks) is laid from its own base, the same way and as
    /// long for its height. Soft, fading to 55% at the tip, and kept off the subject itself.
    public func castShadow(tip: NormalizedPoint) -> MaskData {
        let width = size.width, height = size.height
        let figures = components()
        guard let whole = Self.extent(of: figures.flatMap { $0 }, width: width) else { return MaskData(size: size, filledWith: 0) }
        // How far the top of a figure as tall as the whole subject lands from its base, per unit of height.
        let rise = Double(whole.bottom - whole.top)
        guard rise > 0 else { return MaskData(size: size, filledWith: 0) }
        let across = (tip.x * Double(width) - whole.crown) / rise, down = (tip.y * Double(height) - Double(whole.bottom)) / rise
        var coverage = [Double](repeating: 0, count: width * height)
        for figure in figures {
            guard let shape = Self.extent(of: figure, width: width), shape.bottom > shape.top else { continue }
            let tall = Double(shape.bottom - shape.top)
            // A shadow lying along the ground still has the figure's depth across it: at least 15% of its width or 6%
            // of its height, or a cyclist's sideways shadow is a hairline.
            let thickness = max(1.5, tall * 0.06, Double(shape.right - shape.left) * 0.15)
            var rows = [Int: [Int]]()
            for index in figure { rows[index / width, default: []].append(index % width) }
            // Each row (its height h above the base) is drawn over the target rows between where it and the row below
            // land, so a shadow longer than its figure has no gaps.
            for (y, columns) in rows {
                let h = Double(shape.bottom - y) / tall
                let below = Double(shape.bottom - min(shape.bottom, y + 1)) / tall
                let shift = h * tall * across
                let from = Double(shape.bottom) + below * tall * down, to = Double(shape.bottom) + h * tall * down
                let middle = (from + to) / 2, half = max(abs(to - from), thickness) / 2
                let strength = 1 - 0.45 * h
                for target in max(0, Int((middle - half).rounded()))...min(height - 1, max(0, Int((middle + half).rounded()))) {
                    for x in columns {
                        let column = Int((Double(x) + shift).rounded())
                        guard column >= 0, column < width else { continue }
                        let index = target * width + column
                        coverage[index] = max(coverage[index], strength * Double(self[x, y]) / 255)
                    }
                }
            }
        }
        // As soft as 2.5% of the subject's height.
        let cast = MaskData(size: size, coverage: coverage.map { UInt8(min(255, ($0 * 255).rounded())) })
            .blurred(by: max(1, rise * 0.025)).multiplied(by: inverted())
        return MaskData(size: size, coverage: cast.coverage, followsPhoto: false)
    }

    /// The covered pixels (over half covered) of each separate figure, 8-connected, ignoring specks under a thousandth
    /// of what is covered.
    public func components() -> [[Int]] {
        let width = size.width, height = size.height
        var seen = [Bool](repeating: false, count: coverage.count)
        var figures: [[Int]] = []
        for start in coverage.indices where coverage[start] > 127 && !seen[start] {
            var figure: [Int] = [], stack = [start]
            seen[start] = true
            while let index = stack.popLast() {
                figure.append(index)
                let x = index % width, y = index / width
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let next = ny * width + nx
                        if coverage[next] > 127 && !seen[next] { seen[next] = true; stack.append(next) }
                    }
                }
            }
            figures.append(figure)
        }
        let total = figures.reduce(0) { $0 + $1.count }
        return figures.filter { $0.count * 1000 >= total }
    }

    /// A figure's rows and columns, and the middle of its top rows.
    private static func extent(of figure: [Int], width: Int) -> (top: Int, bottom: Int, left: Int, right: Int, crown: Double)? {
        guard !figure.isEmpty else { return nil }
        var top = Int.max, bottom = Int.min, left = Int.max, right = Int.min
        for index in figure {
            top = min(top, index / width); bottom = max(bottom, index / width)
            left = min(left, index % width); right = max(right, index % width)
        }
        let band = top + max(1, (bottom - top) / 30)
        let crowns = figure.filter { $0 / width <= band }.map { Double($0 % width) }
        return (top, bottom, left, right, crowns.reduce(0, +) / Double(max(1, crowns.count)))
    }

    /// This mask, of the photo's part in `rect`, put back on a mask of the whole photo at `size`, covering nothing
    /// outside `rect`.
    public func placed(over rect: NormalizedRect, in size: PixelSize) -> MaskData {
        var coverage = [UInt8](repeating: 0, count: size.width * size.height)
        guard rect.width > 0, rect.height > 0, self.size.width > 0, self.size.height > 0 else {
            return MaskData(size: size, coverage: coverage)
        }
        let left = max(0, Int((rect.x * Double(size.width)).rounded(.down)))
        let right = min(size.width, Int(((rect.x + rect.width) * Double(size.width)).rounded(.up)))
        let top = max(0, Int((rect.y * Double(size.height)).rounded(.down)))
        let bottom = min(size.height, Int(((rect.y + rect.height) * Double(size.height)).rounded(.up)))
        for y in top..<max(top, bottom) {
            let v = ((Double(y) + 0.5) / Double(size.height) - rect.y) / rect.height * Double(self.size.height)
            guard v >= 0, v < Double(self.size.height) else { continue }
            for x in left..<max(left, right) {
                let u = ((Double(x) + 0.5) / Double(size.width) - rect.x) / rect.width * Double(self.size.width)
                guard u >= 0, u < Double(self.size.width) else { continue }
                coverage[y * size.width + x] = self[Int(u), Int(v)]
            }
        }
        return MaskData(size: size, coverage: coverage, followsPhoto: followsPhoto)
    }

    /// Coverage where both masks cover, resizing the other mask to this mask's size if needed.
    public func multiplied(by other: MaskData) -> MaskData {
        let other = other.size == size ? other : other.resized(to: size)
        return MaskData(size: size, coverage: zip(coverage, other.coverage).map { UInt8((Int($0) * Int($1) + 127) / 255) },
                        followsPhoto: followsPhoto || other.followsPhoto)
    }

    /// Softens coverage about as a Gaussian blur of `radius` pixels does: three box blurs each way, with the edge
    /// pixels repeated past the border.
    public func blurred(by radius: Double) -> MaskData {
        guard radius >= 0.5, size.width > 0, size.height > 0 else { return self }
        // Three boxes of 2h + 1 pixels have the variance of a Gaussian of `radius` when (2h + 1)² = 4 radius² + 1.
        let half = max(1, Int((((4 * radius * radius + 1).squareRoot() - 1) / 2).rounded()))
        let width = size.width, height = size.height
        var values = coverage.map(Double.init)
        func pass(count: Int, stride: Int, lines: Int, lineStride: Int) {
            var line = [Double](repeating: 0, count: count)
            for start in 0..<lines {
                for index in 0..<count { line[index] = values[start * lineStride + index * stride] }
                var sum = Double(half + 1) * line[0]
                for index in 1...half { sum += line[min(count - 1, index)] }
                for index in 0..<count {
                    values[start * lineStride + index * stride] = sum / Double(2 * half + 1)
                    sum += line[min(count - 1, index + half + 1)] - line[max(0, index - half)]
                }
            }
        }
        for _ in 0..<3 {
            pass(count: width, stride: 1, lines: height, lineStride: width)
            pass(count: height, stride: width, lines: width, lineStride: 1)
        }
        return MaskData(size: size, coverage: values.map { UInt8(min(255, max(0, $0.rounded()))) }, followsPhoto: followsPhoto)
    }
}

extension NormalizedRect {
    /// The part of a finite, positive rectangle that lies on the photo.
    var onPhoto: NormalizedRect? {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let left = max(0, x)
        let top = max(0, y)
        let right = min(1, x + width)
        let bottom = min(1, y + height)
        guard left < right, top < bottom else { return nil }
        return NormalizedRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// The smallest rectangle holding both.
    func union(_ other: NormalizedRect) -> NormalizedRect {
        let left = min(x, other.x), top = min(y, other.y)
        return NormalizedRect(x: left, y: top, width: max(x + width, other.x + other.width) - left,
                              height: max(y + height, other.y + other.height) - top)
    }
}

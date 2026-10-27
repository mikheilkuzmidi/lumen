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
        return MaskData(size: size, coverage: zip(coverage, other.coverage).map { max($0, $1) })
    }

    /// Selects the share of each pixel this mask leaves untouched.
    public func inverted() -> MaskData {
        MaskData(size: size, coverage: coverage.map { 255 - $0 })
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
        return MaskData(size: croppedSize, coverage: pixels)
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
        return MaskData(size: target, coverage: pixels)
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
        return MaskData(size: size, coverage: pixels)
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
        return MaskData(size: size, coverage: values.map { UInt8(min(255, max(0, $0.rounded()))) })
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
}

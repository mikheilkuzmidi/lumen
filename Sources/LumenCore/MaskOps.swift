import Foundation

extension MaskData {
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

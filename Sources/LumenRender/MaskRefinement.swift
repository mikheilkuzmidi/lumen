import CoreImage
import LumenCore

/// Fits a selection's edges to the photo with a guided filter, so a coarse or blocky mask follows the edges it
/// was meant to follow. Coverage further than twice the radius from the mask stays zero.
enum MaskRefinement {
    /// The filter's reach: about 1% of the mask's short side, at least 3 px.
    static func radius(for size: PixelSize) -> Int {
        max(3, Int((Double(min(size.width, size.height)) * 0.01).rounded()))
    }

    /// `guide` is the photo's lightness at the mask's size, row by row from the top, in 0...1.
    static func refined(_ mask: MaskData, guide: [Float], radius: Int, epsilon: Double = 0.001) -> MaskData {
        let width = mask.size.width, height = mask.size.height
        guard width > 0, height > 0, guide.count == width * height, mask.coverage.count == guide.count else { return mask }
        let light = guide.map(Double.init)
        let cover = mask.coverage.map { Double($0) / 255 }
        let meanLight = boxMean(light, width: width, height: height, radius: radius)
        let meanCover = boxMean(cover, width: width, height: height, radius: radius)
        let lightSquared = boxMean(light.map { $0 * $0 }, width: width, height: height, radius: radius)
        let lightCover = boxMean(zip(light, cover).map(*), width: width, height: height, radius: radius)
        var slope = [Double](repeating: 0, count: light.count)
        var offset = [Double](repeating: 0, count: light.count)
        for index in light.indices {
            let variance = lightSquared[index] - meanLight[index] * meanLight[index]
            let covariance = lightCover[index] - meanLight[index] * meanCover[index]
            slope[index] = covariance / (max(0, variance) + epsilon)
            offset[index] = meanCover[index] - slope[index] * meanLight[index]
        }
        let meanSlope = boxMean(slope, width: width, height: height, radius: radius)
        let meanOffset = boxMean(offset, width: width, height: height, radius: radius)
        let coverage = light.indices.map { index -> UInt8 in
            let value = meanSlope[index] * light[index] + meanOffset[index]
            return UInt8((min(1, max(0, value)) * 255).rounded())
        }
        return MaskData(size: mask.size, coverage: coverage)
    }

    /// The photo's lightness at `size`, for `refined(_:guide:radius:)`.
    static func guide(_ photo: CIImage, size: PixelSize, context: CIContext) -> [Float]? {
        guard size.width > 0, size.height > 0, photo.extent.width > 0, photo.extent.height > 0 else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        // Core Image writes a bitmap's top row first, as mask rows run.
        let scaled = PhotoCompositor.resized(photo, to: bounds)
        var pixels = [Float](repeating: 0, count: size.width * size.height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            context.render(scaled, toBitmap: buffer.baseAddress!, rowBytes: size.width * 16, bounds: bounds,
                           format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        return (0..<(size.width * size.height)).map { index in
            let pixel = index * 4
            return min(1, max(0, 0.2126 * pixels[pixel] + 0.7152 * pixels[pixel + 1] + 0.0722 * pixels[pixel + 2]))
        }
    }

    /// Mean over a square window, shrunk at the borders so the edges of the photo are not darkened.
    private static func boxMean(_ values: [Double], width: Int, height: Int, radius: Int) -> [Double] {
        let stride = width + 1
        var sums = [Double](repeating: 0, count: stride * (height + 1))
        for y in 0..<height {
            var row = 0.0
            for x in 0..<width {
                row += values[y * width + x]
                sums[(y + 1) * stride + x + 1] = sums[y * stride + x + 1] + row
            }
        }
        var means = [Double](repeating: 0, count: values.count)
        for y in 0..<height {
            let top = max(0, y - radius), bottom = min(height, y + radius + 1)
            for x in 0..<width {
                let left = max(0, x - radius), right = min(width, x + radius + 1)
                let sum = sums[bottom * stride + right] - sums[top * stride + right]
                    - sums[bottom * stride + left] + sums[top * stride + left]
                means[y * width + x] = sum / Double((bottom - top) * (right - left))
            }
        }
        return means
    }
}

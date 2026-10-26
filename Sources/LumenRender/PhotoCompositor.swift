import CoreImage

/// Masked blending and local colour matching for generated regions.
enum PhotoCompositor {
    static func scaledMask(_ mask: CIImage, to rect: CGRect) -> CIImage {
        mask.samplingLinear()
            .transformed(by: CGAffineTransform(translationX: -mask.extent.minX, y: -mask.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: rect.width / mask.extent.width,
                                               y: rect.height / mask.extent.height))
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
            .cropped(to: rect)
    }

    static func resized(_ image: CIImage, to rect: CGRect) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [
                "inputScale": rect.height / image.extent.height,
                "inputAspectRatio": (rect.width / image.extent.width) / (rect.height / image.extent.height),
            ])
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
            .cropped(to: rect)
    }

    static func feather(_ mask: CIImage, radius: CGFloat) -> CIImage {
        guard radius > 0 else { return mask }
        let padded = mask.composited(over: CIImage(color: .black))
        let softened = padded.applyingGaussianBlur(sigma: radius)
        return softened.applyingFilter("CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: padded])
            .cropped(to: mask.extent)
    }

    static func blend(_ foreground: CIImage, over background: CIImage, mask: CIImage?, opacity: Double) -> CIImage {
        guard opacity > 0 else { return background }
        if mask == nil && opacity == 1 { return foreground }
        let coverage = (mask ?? CIImage(color: .white)).composited(over: CIImage(color: .black))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: opacity, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: opacity, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: opacity, w: 0),
            ])
        return foreground.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: coverage,
        ]).cropped(to: background.extent)
    }

    static func colorMatched(_ patch: CIImage, to photo: CIImage, mask: CIImage, context: CIContext) -> CIImage {
        let radius = max(1, min(patch.extent.width, patch.extent.height) * 0.06)
        let padded = mask.composited(over: CIImage(color: .black))
        let outside = padded.applyingFilter("CIColorInvert")
        let ring = padded.applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": radius])
            .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: outside])
        let ringBounds = patch.extent.insetBy(dx: -radius, dy: -radius).intersection(photo.extent)
        guard let surroundings = statistics(photo, mask: ring, bounds: ringBounds, context: context),
              let generated = statistics(patch, mask: padded, bounds: patch.extent, context: context) else { return patch }
        var gain = [Double]()
        var offset = [Double]()
        for channel in 0..<3 {
            let spread = min(2, max(0.5, surroundings.spread[channel] / max(0.015, generated.spread[channel])))
            let scale = 1 + (spread - 1) * 0.65
            gain.append(scale)
            offset.append((surroundings.mean[channel] - generated.mean[channel]) * 0.65
                          + generated.mean[channel] * (1 - scale))
        }
        return patch.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: gain[0], y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: gain[1], z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: gain[2], w: 0),
            "inputBiasVector": CIVector(x: offset[0], y: offset[1], z: offset[2], w: 0),
        ])
    }

    private struct Statistics {
        var mean: [Double]
        var spread: [Double]
    }

    private static func statistics(_ image: CIImage, mask: CIImage, bounds: CGRect, context: CIContext) -> Statistics? {
        let scale = min(1, 128 / max(bounds.width, bounds.height))
        let width = max(1, Int((bounds.width * scale).rounded()))
        let height = max(1, Int((bounds.height * scale).rounded()))
        let sampleBounds = CGRect(x: 0, y: 0, width: width, height: height)
        let sample = resized(image.cropped(to: bounds), to: sampleBounds)
        let coverage = resized(mask.cropped(to: bounds), to: sampleBounds)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        var weights = pixels
        let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        pixels.withUnsafeMutableBytes { bytes in
            context.render(sample, toBitmap: bytes.baseAddress!, rowBytes: width * 16,
                           bounds: sampleBounds, format: .RGBAf, colorSpace: colorSpace)
        }
        weights.withUnsafeMutableBytes { bytes in
            context.render(coverage, toBitmap: bytes.baseAddress!, rowBytes: width * 16,
                           bounds: sampleBounds, format: .RGBAf, colorSpace: nil)
        }
        var total = 0.0
        var sum = [Double](repeating: 0, count: 3)
        var squares = sum
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let weight = min(1, max(0, Double(weights[index]))) * Double(pixels[index + 3])
            total += weight
            for channel in 0..<3 {
                let value = Double(pixels[index + channel])
                sum[channel] += value * weight
                squares[channel] += value * value * weight
            }
        }
        guard total > 0.5 else { return nil }
        let mean = sum.map { $0 / total }
        let spread = (0..<3).map { sqrt(max(0, squares[$0] / total - mean[$0] * mean[$0])) }
        return Statistics(mean: mean, spread: spread)
    }
}

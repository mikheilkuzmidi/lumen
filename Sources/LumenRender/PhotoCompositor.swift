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

    /// An opaque photo scaled to fill `rect`, opaque to its last pixel. Lanczos reads past the photo's edge, which left
    /// its border and corners part transparent, and some rows and columns a hair under opaque; a divide over those
    /// (saturation's) drew a white grid with black corners on a scaled-down sky.
    static func resized(_ image: CIImage, to rect: CGRect) -> CIImage {
        let extent = image.extent
        return image.clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [
                "inputScale": rect.height / extent.height,
                "inputAspectRatio": (rect.width / extent.width) / (rect.height / extent.height),
            ])
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
            .cropped(to: rect)
            .settingAlphaOne(in: rect)
    }

    static func feather(_ mask: CIImage, radius: CGFloat) -> CIImage {
        guard radius > 0 else { return mask }
        // Clamped rather than padded with black, so coverage that reaches the photo's border is not dimmed there.
        let softened = mask.clampedToExtent().applyingGaussianBlur(sigma: radius)
        return softened.applyingFilter("CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: mask])
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

    /// The generator draws at a fixed size, so an enlarged patch is soft. The photo's own fine detail under it
    /// (fabric, grain, edges) is added back at the scale the enlargement lost, so a recoloured coat keeps its weave.
    /// Only its lightness: a red coat's detail is nearly all in its red channel, and added as it was it brought red
    /// ripples back onto the coat redrawn navy.
    /// Only where the patch still shows what the photo did: its lightness, less the photo's softened to the same scale
    /// and less any shift the two share over a wider area (a recolour's), stays within a few percent. Where the patch
    /// drew something new, the old detail stayed off: added back everywhere, a jacket's logo showed through the
    /// pirate's coat and the vampire's cape drawn over it.
    static func restoringDetail(_ patch: CIImage, from photo: CIImage, enlargement: CGFloat, strength: CGFloat = 0.7) -> CIImage {
        guard enlargement > 1.2 else { return patch }
        let base = photo.cropped(to: patch.extent)
        let sigma = min(8, max(0.8, enlargement * 0.6))
        let blurred = base.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: patch.extent)
        // Every image below stays opaque so Core Image keeps its values; a sum of two opaque images has alpha 2, which
        // `sum` multiplies back out.
        func lightness(_ image: CIImage, _ factor: CGFloat) -> CIImage {
            let row = CIVector(x: 0.2126 * factor, y: 0.7152 * factor, z: 0.0722 * factor, w: 0)
            return image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": row, "inputGVector": row, "inputBVector": row, "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        }
        func scaled(_ image: CIImage, _ factor: CGFloat, plus bias: CGFloat = 0) -> CIImage {
            image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: factor, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: factor, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: factor, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
            ])
        }
        func sum(_ a: CIImage, _ b: CIImage) -> CIImage {
            a.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: b])
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 2, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 2, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 2, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                ]).cropped(to: patch.extent)
        }
        func product(_ a: CIImage, _ b: CIImage) -> CIImage {
            a.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: b]).cropped(to: patch.extent)
        }
        let detail = sum(lightness(base, 1), lightness(blurred, -1))
        // How far the patch strays from the softened photo, less what it strays by over a wider area.
        let strays = sum(lightness(patch, 1), lightness(blurred, -1))
        let wide = strays.clampedToExtent().applyingGaussianBlur(sigma: min(40, sigma * 10)).cropped(to: patch.extent)
        let local = sum(strays, scaled(wide, -1))
        // 1 where it keeps the photo, down to none at 0.1 of linear lightness off it.
        let kept = product(local, local).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: -100, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: -100, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: -100, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0),
        ]).applyingFilter("CIColorClamp")
        return sum(scaled(patch, 1), scaled(product(detail, kept), strength))
    }

    /// Moves a redrawn patch's overall light and colour back to the photo's, measured in a ring just outside its mask.
    static func colorMatched(_ patch: CIImage, to photo: CIImage, mask: CIImage, context: CIContext) -> CIImage {
        let short = min(patch.extent.width, patch.extent.height)
        let radius = max(1, short * 0.06)
        // The ring starts a little outside the mask: a mask often misses the thing's own edge by a few pixels, and
        // the generator redrew that edge too, which would read as drift.
        let gap = max(1, short * 0.015)
        let padded = mask.composited(over: CIImage(color: .black))
        let clear = padded.applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": gap])
            .applyingFilter("CIColorInvert")
        let ring = padded.applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": radius])
            .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: clear])
        // The redrawn crop's own surroundings against the photo's in the same ring: that measures how the
        // generator shifted the light and colour overall, without pulling an intended new colour inside the mask
        // toward what is around it.
        let ringBounds = patch.extent.intersection(photo.extent)
        guard let (surroundings, generated) = agreeing(photo, patch, ring: ring, bounds: ringBounds, context: context) else {
            return patch
        }
        var gain = [Double]()
        var offset = [Double]()
        for channel in 0..<3 {
            // Contrast is matched only where both rings have texture to compare, and only so far: beside a flat
            // sky or wall, a contrast ratio would squeeze the new colour toward grey.
            let textured = surroundings.spread[channel] > 0.04 && generated.spread[channel] > 0.04
            let spread = textured ? min(1.25, max(0.8, surroundings.spread[channel] / generated.spread[channel])) : 1
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

    /// The photo's and the patch's colour in the ring, over the pixels where the two differ only by the generator's
    /// overall drift: within 0.08 (linear) of their median difference. Pixels whose content the generator changed,
    /// such as a red sweater's edge it redrew green, are left out. Nil when too few agree to tell the drift.
    private static func agreeing(_ photo: CIImage, _ patch: CIImage, ring: CIImage, bounds: CGRect,
                                 context: CIContext) -> (Statistics, Statistics)? {
        let scale = min(1, 128 / max(bounds.width, bounds.height))
        let width = max(1, Int((bounds.width * scale).rounded()))
        let height = max(1, Int((bounds.height * scale).rounded()))
        let sampleBounds = CGRect(x: 0, y: 0, width: width, height: height)
        let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        func sample(_ image: CIImage, colorSpace: CGColorSpace?) -> [Float] {
            var pixels = [Float](repeating: 0, count: width * height * 4)
            pixels.withUnsafeMutableBytes { bytes in
                context.render(resized(image.cropped(to: bounds), to: sampleBounds), toBitmap: bytes.baseAddress!,
                               rowBytes: width * 16, bounds: sampleBounds, format: .RGBAf, colorSpace: colorSpace)
            }
            return pixels
        }
        let theirs = sample(photo, colorSpace: colorSpace), ours = sample(patch, colorSpace: colorSpace)
        let weights = sample(ring, colorSpace: nil)
        let inRing = stride(from: 0, to: weights.count, by: 4).filter {
            weights[$0] > 0.5 && theirs[$0 + 3] > 0.5 && ours[$0 + 3] > 0.5
        }
        guard inRing.count >= 8 else { return nil }
        let drift = (0..<3).map { channel in
            median(inRing.map { Double(theirs[$0 + channel] - ours[$0 + channel]) })
        }
        let agree = inRing.filter { index in
            (0..<3).allSatisfy { abs(Double(theirs[index + $0] - ours[index + $0]) - drift[$0]) <= 0.08 }
        }
        guard agree.count >= max(8, inRing.count / 4) else { return nil }
        func statistics(_ pixels: [Float]) -> Statistics {
            let mean = (0..<3).map { channel in agree.reduce(0) { $0 + Double(pixels[$1 + channel]) } / Double(agree.count) }
            let spread = (0..<3).map { channel in
                (agree.reduce(0) { $0 + pow(Double(pixels[$1 + channel]) - mean[channel], 2) } / Double(agree.count)).squareRoot()
            }
            return Statistics(mean: mean, spread: spread)
        }
        return (statistics(theirs), statistics(ours))
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}

import CoreImage
import LumenCore

/// Develop settings in the order light, colour and detail are usually corrected.
enum PhotoAdjustments {
    static func apply(_ values: [AdjustmentKey: Double], to photo: CIImage) -> CIImage {
        func value(_ key: AdjustmentKey) -> Double {
            guard let value = values[key], value.isFinite else { return 0 }
            return min(key.range.upperBound, max(key.range.lowerBound, value))
        }
        var image = photo
        let temperature = value(.temperature)
        let tint = value(.tint)
        if temperature != 0 || tint != 0 {
            // Even steps in mireds, as the eye judges colour temperature: +100 warms about as much as -100 cools.
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 1_000_000 / (1_000_000 / 6500 - temperature * 1.2), y: tint),
                "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ])
        }
        if value(.exposure) != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: ["inputEV": value(.exposure)])
        }
        if value(.noiseReduction) != 0 {
            image = image.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": value(.noiseReduction) * 0.0008,
                "inputSharpness": 0,
            ])
        }
        let highlights = value(.highlights) / 100
        let shadows = value(.shadows) / 100
        if highlights != 0 || shadows != 0 {
            image = toneCurve(image, points: [
                (0, 0), (0.25, 0.25 + shadows * 0.13),
                (0.5, 0.5 + (shadows + highlights) * 0.025),
                (0.75, 0.75 + highlights * 0.13), (1, 1),
            ])
        }
        let whites = value(.whites) / 100
        let blacks = value(.blacks) / 100
        if whites != 0 || blacks != 0 {
            image = toneCurve(image, points: [
                (max(0, -blacks * 0.08), max(0, blacks * 0.12)),
                (0.25, 0.25 + blacks * 0.10),
                (0.5, 0.5 + (whites + blacks) * 0.025),
                (0.75, 0.75 + whites * 0.10),
                (1 - max(0, whites * 0.08), 1 + min(0, whites * 0.20)),
            ])
        }
        let contrast = value(.contrast) / 100
        if contrast != 0 {
            image = toneCurve(image, points: [
                (0, 0), (0.2, 0.2 - contrast * 0.12), (sqrt(0.18), sqrt(0.18)),
                (0.7, 0.7 + contrast * 0.12), (1, 1),
            ])
        }
        let dehaze = value(.dehaze) / 100
        if dehaze != 0 {
            // On sRGB-encoded values, as CIToneCurve's curves work on perceptual ones: in the linear light Core Image
            // works in, a contrast pivot of 0.5 is a light grey and every shadow goes to black.
            image = image.applyingFilter("CILinearToSRGBToneCurve")
                .applyingFilter("CIColorControls", parameters: ["inputContrast": 1 + dehaze * 0.25])
                .applyingFilter("CIColorPolynomial", parameters: [
                    "inputRedCoefficients": CIVector(x: -dehaze * 0.035, y: 1, z: 0, w: 0),
                    "inputGreenCoefficients": CIVector(x: -dehaze * 0.035, y: 1, z: 0, w: 0),
                    "inputBlueCoefficients": CIVector(x: -dehaze * 0.035, y: 1, z: 0, w: 0),
                ])
                .applyingFilter("CISRGBToneCurveToLinear")
        }
        // A colour grade: the highlights and the shadows warmed or cooled on their own, each through a weight from
        // its lightness as seen (highlights from 0.45 up to full by 0.85, shadows full to 0.15 and gone by 0.55).
        for (key, weight) in [(AdjustmentKey.highlightWarmth, (from: 0.45, to: 0.85)), (.shadowWarmth, (from: 0.55, to: 0.15))] {
            let amount = value(key) / 100
            guard amount != 0 else { continue }
            let lightness = image.applyingFilter("CILinearToSRGBToneCurve").applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
                "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
                "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            ])
            let gain = 1 / (weight.to - weight.from)
            let ramp = CIVector(x: gain, y: 0, z: 0, w: 0)
            let mask = lightness.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": ramp, "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
                "inputBiasVector": CIVector(x: -weight.from * gain, y: -weight.from * gain, z: -weight.from * gain, w: 0),
            ]).applyingFilter("CIColorClamp")
            // An amber light in linear light: full warmth lifts red by 30% and green by 10% and takes 30% from blue, gold
            // rather than orange; cooling does the opposite.
            let warmed = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1 + 0.3 * amount, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1 + 0.1 * amount, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1 - 0.3 * amount, w: 0),
            ])
            image = PhotoCompositor.blend(warmed, over: image, mask: mask, opacity: 1)
        }
        if value(.vibrance) != 0 {
            image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": value(.vibrance) / 100])
        }
        if value(.saturation) != 0 {
            image = saturated(image, by: 1 + value(.saturation) / 100)
        }
        let clarity = value(.clarity) / 100
        if clarity != 0 {
            image = clarified(image, by: clarity, radius: min(photo.extent.width, photo.extent.height) * 0.02)
        }
        if value(.sharpness) != 0 {
            image = image.clampedToExtent().applyingFilter("CISharpenLuminance", parameters: [
                "inputSharpness": value(.sharpness) * 0.012,
            ]).cropped(to: photo.extent)
        }
        return image.cropped(to: photo.extent)
    }

    /// Saturation on sRGB-encoded values, as the eye sees it, with each channel's share of the pixel's lightness
    /// raised to `factor` and the lightness kept. A channel can near zero but never pass it: in linear light, +30 took
    /// a sunset's blue from 79 to 8, and with contrast to below zero, where it clipped into a flat orange patch.
    static func saturated(_ image: CIImage, by factor: Double) -> CIImage {
        // The divides below are of premultiplied colour, so the photo is made fully opaque first: a pixel a hair under
        // opaque came out white.
        let encoded = image.applyingFilter("CILinearToSRGBToneCurve")
            .applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                                                         "inputMaxComponents": CIVector(x: 4, y: 4, z: 4, w: 1)])
            .settingAlphaOne(in: image.extent)
        // Core Image's divide blend caps its result at 1, so each share is taken of 16 × the lightness and the 16 put
        // back after: a pure blue's share of its lightness is about 14.
        let power = max(0, factor)
        let shares = lightness(of: encoded, times: 16).applyingFilter("CIDivideBlendMode", parameters: [kCIInputBackgroundImageKey: encoded])
        let raised = scaled(shares.applyingFilter("CIGammaAdjust", parameters: ["inputPower": power]), by: pow(16, power))
        let coloured = raised.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: lightness(of: encoded)])
        // Raising the shares lightens a colourful pixel a little; its own lightness is put back.
        let kept = scaled(lightness(of: coloured, times: 16).applyingFilter("CIDivideBlendMode", parameters: [kCIInputBackgroundImageKey: coloured]), by: 16)
            .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: lightness(of: encoded)])
        return kept.applyingFilter("CISRGBToneCurveToLinear").cropped(to: image.extent)
    }

    /// Clarity as local contrast against an edge-preserving base: a guided filter (He, Sun and Tang) on the lightness,
    /// which keeps a strong edge, such as a lit spire against a night sky, in the base, so the sky beside it gets no dark
    /// rim, while texture in between is lifted (or softened when negative). On sRGB-encoded values; the detail is the
    /// lightness's, added to each channel, so colours keep their hue.
    static func clarified(_ image: CIImage, by amount: Double, radius: CGFloat) -> CIImage {
        let extent = image.extent
        let encoded = image.applyingFilter("CILinearToSRGBToneCurve")
        let light = lightness(of: encoded)
        func mean(_ image: CIImage) -> CIImage {
            image.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: extent)
        }
        func product(_ a: CIImage, _ b: CIImage) -> CIImage {
            a.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: b])
        }
        let average = mean(light)
        let variance = combined([(mean(product(light, light)), 1), (product(average, average), -1)], extent: extent)
        // a = variance / (variance + ε): near 1 across an edge, near 0 over texture finer than ε (a spread of 0.05).
        let epsilon = 0.0025
        let weight = scaled(variance, by: 1, plus: epsilon)
            .applyingFilter("CIDivideBlendMode", parameters: [kCIInputBackgroundImageKey: scaled(variance, by: 1, plus: 0)])
        let offset = product(scaled(weight, by: -1, plus: 1), average)
        let base = combined([(product(mean(weight), light), 1), (mean(offset), 1)], extent: extent)
        let strength = amount > 0 ? amount * 2 : amount * 0.8
        return combined([(encoded, 1), (light, strength), (base, -strength)], extent: extent)
            .applyingFilter("CISRGBToneCurveToLinear").cropped(to: extent)
    }

    /// Σ factor × image, for any signs: each term is kept opaque, so Core Image keeps its colour, and the sum's alpha
    /// (the number of terms) is divided back out.
    private static func combined(_ terms: [(CIImage, Double)], extent: CGRect) -> CIImage {
        let opaque = terms.map { image, factor in
            image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: factor, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: factor, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: factor, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        }
        let sum = opaque.dropFirst().reduce(opaque[0]) {
            $1.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: $0])
        }
        let count = CGFloat(terms.count)
        return sum.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: count, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: count, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: count, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ]).cropped(to: extent)
    }

    /// Each pixel's lightness (Rec. 709 weights) times `factor`, in all three channels, a little above zero so it can
    /// divide.
    private static func lightness(of image: CIImage, times factor: Double = 1) -> CIImage {
        let weights = CIVector(x: 0.2126 * factor, y: 0.7152 * factor, z: 0.0722 * factor, w: 0)
        let floor = 0.0005 * factor
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": weights, "inputGVector": weights, "inputBVector": weights,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputBiasVector": CIVector(x: floor, y: floor, z: floor, w: 0),
        ])
    }

    private static func scaled(_ image: CIImage, by factor: Double, plus bias: Double = 0) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: factor, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: factor, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: factor, w: 0), "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
        ])
    }

    private static func toneCurve(_ image: CIImage, points: [(Double, Double)]) -> CIImage {
        var parameters: [String: Any] = [:]
        for (index, point) in points.enumerated() {
            parameters["inputPoint\(index)"] = CIVector(x: point.0, y: point.1)
        }
        return image.applyingFilter("CIToneCurve", parameters: parameters)
    }
}

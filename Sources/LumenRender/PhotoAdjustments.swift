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
            image = image.applyingFilter("CIColorControls", parameters: ["inputSaturation": 1 + value(.saturation) / 100])
        }
        let clarity = value(.clarity) / 100
        let radius = min(photo.extent.width, photo.extent.height) * 0.02
        if clarity > 0 {
            image = image.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: [
                "inputRadius": radius, "inputIntensity": clarity * 0.7,
            ]).cropped(to: photo.extent)
        } else if clarity < 0 {
            let softened = image.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: photo.extent)
            image = PhotoCompositor.blend(softened, over: image, mask: nil, opacity: -clarity * 0.35)
        }
        if value(.sharpness) != 0 {
            image = image.clampedToExtent().applyingFilter("CISharpenLuminance", parameters: [
                "inputSharpness": value(.sharpness) * 0.012,
            ]).cropped(to: photo.extent)
        }
        return image.cropped(to: photo.extent)
    }

    private static func toneCurve(_ image: CIImage, points: [(Double, Double)]) -> CIImage {
        var parameters: [String: Any] = [:]
        for (index, point) in points.enumerated() {
            parameters["inputPoint\(index)"] = CIVector(x: point.0, y: point.1)
        }
        return image.applyingFilter("CIToneCurve", parameters: parameters)
    }
}

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
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500 + temperature * 30, y: tint),
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
            image = image.applyingFilter("CIColorControls", parameters: ["inputContrast": 1 + dehaze * 0.25])
                .applyingFilter("CIColorPolynomial", parameters: [
                    "inputRedCoefficients": CIVector(x: -dehaze * 0.035, y: 1, z: 0, w: 0),
                    "inputGreenCoefficients": CIVector(x: -dehaze * 0.035, y: 1, z: 0, w: 0),
                    "inputBlueCoefficients": CIVector(x: -dehaze * 0.035, y: 1, z: 0, w: 0),
                ])
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

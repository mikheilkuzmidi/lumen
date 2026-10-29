import CoreGraphics
import CoreImage
import Foundation
import LumenCore

/// What an edit host gives Lumen beyond rendering and layers, worked out from the photo as it is rendered now. Lumen's
/// own document and an app's editor get the same masks and measurements from it: a recolour held to the photo's edges
/// and grown over the thing's own colours, and the colour and detail numbers the critic reads.
public enum EditSupport {
    /// `mask` held to the photo's own edges. `photo` is the photo as rendered now, cut to the mask's region.
    /// Masks under 64 px on a side carry no edge detail worth fitting and are kept as they are.
    public static func fitted(_ mask: MaskData, photo: CIImage, context: CIContext) -> MaskData {
        guard min(mask.size.width, mask.size.height) >= 64,
              let guide = MaskRefinement.guide(photo, size: mask.size, context: context) else { return mask }
        // A window a few times SAM's usual miss, so the photo's own colours decide each side of the edge; then what
        // they decided clearly (a quarter either side of the middle) is taken all in or all out.
        let radius = MaskRefinement.radius(for: mask.size) * 3
        let fitted = MaskRefinement.refined(MaskRefinement.refined(mask, guide: guide, radius: radius), guide: guide, radius: radius)
        return MaskData(size: fitted.size, coverage: fitted.coverage.map { value in
            UInt8((min(1, max(0, (Double(value) / 255 - 0.3) / 0.4)) * 255).rounded())
        })
    }

    /// `mask` grown over the neighbouring pixels of the thing's own colours (`MaskGrowth.alike`). `photo` is the photo
    /// as rendered now, cut to the mask's region.
    public static func extended(_ mask: MaskData, photo: CIImage, context: CIContext) -> MaskData {
        let size = mask.size
        guard size.width >= 16, size.height >= 16 else { return mask }
        let colours = sampledColours(photo, size: size, context: context)
        let short = Double(min(size.width, size.height))
        return MaskGrowth.alike(mask, colours: colours, reach: max(1, Int((short * 0.03).rounded())),
                                colourfulReach: max(1, Int((short * 0.08).rounded())),
                                fringe: max(2, Int((short * 0.006).rounded())))
    }

    /// The colour of `image` under `mask` (all of it when nil), in CIELAB, for the critic.
    public static func measure(_ image: EncodedImage, mask: MaskData?) throws -> ColourMeasurement? {
        try ColourMeasuring.measure(image, mask: mask)
    }

    /// Fine detail `after` lost against `before`, where a redraw smoothed it away.
    public static func lostDetail(before: EncodedImage, after: EncodedImage) throws -> [LostDetail] {
        try DetailMeasuring.lost(before: before, after: after)
    }

    /// `photo` at `size`, in CIELAB, rows from the top.
    static func sampledColours(_ photo: CIImage, size: PixelSize, context: CIContext) -> [ColourMeasurement] {
        let sample = PhotoCompositor.resized(photo, to: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        var pixels = [UInt8](repeating: 0, count: size.width * size.height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            // Core Image writes a bitmap's top row first, as mask rows run.
            context.render(sample, toBitmap: buffer.baseAddress!, rowBytes: size.width * 4,
                           bounds: CGRect(x: 0, y: 0, width: size.width, height: size.height), format: .RGBA8,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        return (0..<(size.width * size.height)).map {
            ColourMeasuring.lab(red: pixels[$0 * 4], green: pixels[$0 * 4 + 1], blue: pixels[$0 * 4 + 2])
        }
    }
}

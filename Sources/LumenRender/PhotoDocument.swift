import Foundation
import CoreImage
import ImageIO
import LumenCore

/// A photo and its layers, rendered with Core Image. It is the host the command-line tool and Lumen Studio edit.
public actor PhotoDocument: EditHost {
    public let url: URL
    public private(set) var stack = LayerStack()
    /// The photo's layers, from bottom to top.
    public var layers: [Layer] { stack.layers }
    /// Rotation before the layers, in degrees counterclockwise.
    public private(set) var straighteningAngle: Double = 0

    private let photo: CIImage
    private var canvas: CIImage
    private let sourceColorSpace: CGColorSpace
    private let context: CIContext
    private let capturedAt: Date?
    private var masks: [UUID: CIImage] = [:]
    private var patches: [UUID: CIImage] = [:]

    public init(contentsOf url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw LumenError.invalidResponse("The photo could not be opened.")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
        let oriented = CIImage(cgImage: image).oriented(forExifOrientation: orientation)
        photo = oriented.transformed(by: CGAffineTransform(translationX: -oriented.extent.minX,
                                                         y: -oriented.extent.minY))
        canvas = photo
        capturedAt = PhotoStatistics.capturedAt(in: properties)
        let colorSpace = image.colorSpace
        sourceColorSpace = (colorSpace?.model == .indexed ? colorSpace?.baseColorSpace : colorSpace)
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        context = CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false,
        ])
        self.url = url
    }

    public func size() async -> PixelSize {
        PixelSize(width: Int(canvas.extent.width), height: Int(canvas.extent.height))
    }

    /// Rotates the original, then keeps the largest centred rectangle of its aspect, rounded down to pixels.
    public func straighten(degrees: Double) throws {
        guard degrees.isFinite else {
            throw LumenError.invalidResponse("The straightening angle must be finite.")
        }
        straighteningAngle = degrees
        let radians = degrees.truncatingRemainder(dividingBy: 360) * .pi / 180
        let width = photo.extent.width, height = photo.extent.height
        let cosine = abs(cos(radians)), sine = abs(sin(radians))
        let scale = min(width / (width * cosine + height * sine),
                        height / (width * sine + height * cosine))
        let cropWidth = max(1, floor(width * min(1, scale) + 0.000001))
        let cropHeight = max(1, floor(height * min(1, scale) + 0.000001))
        let rotated = photo.transformed(by: CGAffineTransform(translationX: -width / 2, y: -height / 2))
            .transformed(by: CGAffineTransform(rotationAngle: radians))
        let bounds = CGRect(x: -cropWidth / 2, y: -cropHeight / 2, width: cropWidth, height: cropHeight)
        canvas = rotated.cropped(to: bounds)
            .transformed(by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
    }

    public func render(maxLongEdge: Int) async throws -> EncodedImage {
        try preview(in: cropBounds(), maxLongEdge: maxLongEdge)
    }

    public func render(region: NormalizedRect, maxLongEdge: Int) async throws -> EncodedImage {
        let bounds = try Self.bounds(of: region, in: cropBounds())
        return try preview(in: bounds, maxLongEdge: maxLongEdge)
    }

    public func fitted(_ mask: MaskData, region: NormalizedRect) async throws -> MaskData {
        guard min(mask.size.width, mask.size.height) >= 64 else { return mask }
        let bounds = try Self.bounds(of: region, in: cropBounds())
        guard let guide = MaskRefinement.guide(rendered(scale: 1).cropped(to: bounds), size: mask.size, context: context) else { return mask }
        // A window a few times SAM's usual miss, so the photo's own colours decide each side of the edge; then what
        // they decided clearly (a quarter either side of the middle) is taken all in or all out.
        let radius = MaskRefinement.radius(for: mask.size) * 3
        let fitted = MaskRefinement.refined(MaskRefinement.refined(mask, guide: guide, radius: radius), guide: guide, radius: radius)
        return MaskData(size: fitted.size, coverage: fitted.coverage.map { value in
            UInt8((min(1, max(0, (Double(value) / 255 - 0.3) / 0.4)) * 255).rounded())
        })
    }

    public func extended(_ mask: MaskData, region: NormalizedRect) async throws -> MaskData {
        let size = mask.size
        guard size.width >= 16, size.height >= 16 else { return mask }
        let bounds = try Self.bounds(of: region, in: cropBounds())
        let sample = PhotoCompositor.resized(rendered(scale: 1).cropped(to: bounds), to: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        var pixels = [UInt8](repeating: 0, count: size.width * size.height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            // Core Image writes a bitmap's top row first, as mask rows run.
            context.render(sample, toBitmap: buffer.baseAddress!, rowBytes: size.width * 4,
                           bounds: CGRect(x: 0, y: 0, width: size.width, height: size.height), format: .RGBA8,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        let colours = (0..<(size.width * size.height)).map {
            ColourMeasuring.lab(red: pixels[$0 * 4], green: pixels[$0 * 4 + 1], blue: pixels[$0 * 4 + 2])
        }
        return MaskGrowth.alike(mask, colours: colours, reach: max(1, Int((Double(min(size.width, size.height)) * 0.03).rounded())))
    }

    public func measure(_ image: EncodedImage, mask: MaskData?) async throws -> ColourMeasurement? {
        // A render shows the photo as it is framed now; a mask over the whole photo is cut to that frame first.
        let framed = mask.map { mask in cropRect().map { mask.cropped(to: $0) } ?? mask }
        return try ColourMeasuring.measure(image, mask: framed)
    }

    public func lostDetail(before: EncodedImage, after: EncodedImage) async throws -> [LostDetail] {
        try DetailMeasuring.lost(before: before, after: after)
    }

    public func apply(_ layer: Layer, assets: AssetStore) async throws {
        var mask: CIImage?
        var patch: CIImage?
        switch layer.content {
        case .adjustment(_, let id):
            // A selection's edge is fitted to the photo once, when its layer is added.
            if let id { mask = try Self.image(of: refined(try await maskData(id, assets: assets))) }
        case .patch(let imageID, let maskID, let rect):
            _ = try Self.bounds(of: rect, in: canvas.extent)
            mask = try Self.image(of: try await maskData(maskID, assets: assets))
            guard case .image(let encoded) = await assets.get(imageID),
                  let image = CIImage(data: encoded.data, options: [.applyOrientationProperty: true]),
                  image.extent.width.isFinite, image.extent.height.isFinite,
                  image.extent.width > 0, image.extent.height > 0 else {
                throw LumenError.invalidResponse("The layer's generated image is missing or unreadable.")
            }
            patch = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX,
                                                            y: -image.extent.minY))
        case .crop(let rect):
            _ = try Self.bounds(of: rect, in: canvas.extent)
        }
        var layer = layer
        layer.opacity = Self.opacity(layer.opacity)
        if let index = stack.layers.firstIndex(where: { $0.id == layer.id }) {
            stack.layers[index] = layer
        } else {
            stack.layers.append(layer)
        }
        masks[layer.id] = mask
        patches[layer.id] = patch
    }

    public func remove(_ layer: Layer.ID) async throws {
        stack.layers.removeAll { $0.id == layer }
        masks[layer] = nil
        patches[layer] = nil
    }

    /// Turns a layer on or off without changing its pixels.
    public func setEnabled(_ enabled: Bool, for layer: Layer.ID) {
        guard let index = stack.layers.firstIndex(where: { $0.id == layer }) else { return }
        stack.layers[index].isEnabled = enabled
    }

    /// Sets how much of a layer is visible, from zero to one.
    public func setOpacity(_ opacity: Double, for layer: Layer.ID) {
        guard let index = stack.layers.firstIndex(where: { $0.id == layer }) else { return }
        stack.layers[index].opacity = Self.opacity(opacity)
    }

    /// Writes the photo with its layers at full size.
    public func export(to url: URL, format: EncodedImage.Format) async throws {
        _ = try exportSnapshot(to: url, format: format)
    }

    /// Exports pixels and returns the edit state from the same moment.
    func exportSnapshot(to url: URL, format: EncodedImage.Format) throws -> (labels: [String], angle: Double) {
        let image = rendered(scale: 1).cropped(to: cropBounds())
        let data = try encoded(image, format: format, colorSpace: exportColorSpace)
        try data.write(to: url, options: .atomic)
        return (layers.map(\.label), straighteningAngle)
    }

    /// The source's colour space, unless the source is greyscale and an edit gave it colour (a redraw, or a colour
    /// setting): written in grey, a black-and-white photo whose shirts were redrawn blue came out grey again.
    private var exportColorSpace: CGColorSpace {
        guard sourceColorSpace.model == .monochrome, layers.contains(where: { $0.isEnabled && Self.addsColour($0) }) else {
            return sourceColorSpace
        }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    private static func addsColour(_ layer: Layer) -> Bool {
        switch layer.content {
        case .patch: true
        case .adjustment(let values, _): [AdjustmentKey.temperature, .tint, .vibrance, .saturation].contains { (values[$0] ?? 0) != 0 }
        default: false
        }
    }

    func statistics() throws -> PhotoStatistics {
        try PhotoStatistics(photo: rendered(scale: 1).cropped(to: cropBounds()), context: context, capturedAt: capturedAt)
    }

    private func maskData(_ id: AssetID, assets: AssetStore) async throws -> MaskData {
        guard case .mask(let mask) = await assets.get(id) else {
            throw LumenError.invalidResponse("The layer's mask is missing or unreadable.")
        }
        return mask
    }

    /// Masks under 64 px on a side carry no edge detail worth fitting and are used as they are, as are masks drawn as
    /// they should be (a gradient, a cast shadow).
    private func refined(_ mask: MaskData) -> MaskData {
        guard mask.followsPhoto, min(mask.size.width, mask.size.height) >= 64,
              let guide = MaskRefinement.guide(canvas, size: mask.size, context: context) else { return mask }
        // A second pass fits the edge again from the first pass's better start; then smooth parts of the photo
        // get a wider transition, about 8% of the mask's short side.
        let radius = MaskRefinement.radius(for: mask.size)
        let fitted = MaskRefinement.refined(MaskRefinement.refined(mask, guide: guide, radius: radius), guide: guide, radius: radius)
        return MaskRefinement.softenedWhereFlat(fitted, guide: guide, radius: radius * 8)
    }

    private static func image(of mask: MaskData) throws -> CIImage {
        guard mask.size.width > 0, mask.size.height > 0,
              mask.size.width <= Int.max / mask.size.height,
              mask.coverage.count == mask.size.width * mask.size.height,
              let provider = CGDataProvider(data: Data(mask.coverage) as CFData),
              let image = CGImage(width: mask.size.width, height: mask.size.height,
                                  bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: mask.size.width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider,
                                  decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw LumenError.invalidResponse("The layer's mask is missing or unreadable.")
        }
        return CIImage(cgImage: image, options: [.colorSpace: NSNull()])
    }

    private func cropRect() -> NormalizedRect? {
        for layer in stack.layers.reversed() where layer.isEnabled && layer.opacity > 0 {
            if case .crop(let rect) = layer.content, (try? Self.bounds(of: rect, in: canvas.extent)) != nil { return rect }
        }
        return nil
    }

    private func cropBounds() -> CGRect {
        for layer in stack.layers.reversed() where layer.isEnabled && layer.opacity > 0 {
            if case .crop(let rect) = layer.content,
               let bounds = try? Self.bounds(of: rect, in: canvas.extent) { return bounds }
        }
        return canvas.extent
    }

    private func preview(in bounds: CGRect, maxLongEdge: Int) throws -> EncodedImage {
        guard maxLongEdge > 0 else {
            throw LumenError.invalidResponse("The render size must be greater than zero.")
        }
        let scale = min(1, CGFloat(maxLongEdge) / max(bounds.width, bounds.height))
        let scaledBounds = bounds.applying(CGAffineTransform(scaleX: scale, y: scale))
        let image = rendered(scale: scale).cropped(to: scaledBounds)
            .transformed(by: CGAffineTransform(translationX: -scaledBounds.minX, y: -scaledBounds.minY))
        let size = PixelSize(width: max(1, Int(scaledBounds.width.rounded())),
                             height: max(1, Int(scaledBounds.height.rounded())))
        let output = image.transformed(by: CGAffineTransform(scaleX: CGFloat(size.width) / scaledBounds.width,
                                                             y: CGFloat(size.height) / scaledBounds.height))
            .cropped(to: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return EncodedImage(data: try encoded(output, format: .jpeg,
                                              colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!),
                            format: .jpeg, size: size)
    }

    private func rendered(scale: CGFloat) -> CIImage {
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        let extent = canvas.extent.applying(transform)
        var image = PhotoCompositor.resized(canvas, to: extent)
        for layer in stack.layers where layer.isEnabled && layer.opacity > 0 {
            switch layer.content {
            case .adjustment(let values, _):
                let adjusted = PhotoAdjustments.apply(values, to: image)
                let mask = masks[layer.id].map { PhotoCompositor.scaledMask($0, to: extent) }
                let feathered = mask.map { PhotoCompositor.feather($0, radius: max(0.35, min(extent.width, extent.height) * 0.001)) }
                image = PhotoCompositor.blend(adjusted, over: image, mask: feathered, opacity: layer.opacity)
            case .patch(_, _, let rect):
                guard let patch = patches[layer.id], let mask = masks[layer.id],
                      let bounds = try? Self.bounds(of: rect, in: canvas.extent) else { continue }
                let patchBounds = bounds.applying(transform)
                let placed = PhotoCompositor.resized(patch, to: patchBounds)
                // A patch's mask is the size of its own crop, so it is placed on the patch, not stretched over the photo.
                let coverage = PhotoCompositor.scaledMask(mask, to: patchBounds)
                let enlargement = min(patchBounds.width / patch.extent.width, patchBounds.height / patch.extent.height)
                let matched = PhotoCompositor.restoringDetail(
                    PhotoCompositor.colorMatched(placed, to: image, mask: coverage, context: context),
                    from: image, enlargement: enlargement)
                // A patch's mask carries its own edge: a recolour's is held to the photo's edges, a removal's is
                // softened outside the thing. A wider blend here would let the old colour show along the edge (a red
                // sweater redrawn green kept a red rim), so it only smooths the mask's pixel steps.
                let feathered = PhotoCompositor.feather(coverage, radius: min(patchBounds.width, patchBounds.height) * 0.003)
                image = PhotoCompositor.blend(matched, over: image, mask: feathered, opacity: layer.opacity)
            case .crop:
                continue
            }
            image = image.cropped(to: extent)
        }
        return image
    }

    private func encoded(_ image: CIImage, format: EncodedImage.Format, colorSpace: CGColorSpace) throws -> Data {
        let image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX,
                                                           y: -image.extent.minY))
        let data: Data?
        switch format {
        case .jpeg:
            data = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: [
                CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92,
            ])
        case .png:
            data = context.pngRepresentation(of: image, format: colorSpace.model == .monochrome ? .L8 : .RGBA8,
                                             colorSpace: colorSpace)
        }
        guard let data else { throw LumenError.invalidResponse("The photo could not be encoded.") }
        return data
    }

    private static func opacity(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }

    private static func bounds(of rect: NormalizedRect, in extent: CGRect) throws -> CGRect {
        guard [rect.x, rect.y, rect.width, rect.height].allSatisfy(\.isFinite),
              rect.width > 0, rect.height > 0 else {
            throw LumenError.invalidResponse("The region must have a finite, positive size.")
        }
        let left = min(1, max(0, rect.x))
        let top = min(1, max(0, rect.y))
        let right = min(1, max(0, rect.x + rect.width))
        let bottom = min(1, max(0, rect.y + rect.height))
        let bounds = CGRect(x: extent.minX + left * extent.width,
                            y: extent.maxY - bottom * extent.height,
                            width: (right - left) * extent.width, height: (bottom - top) * extent.height)
            .integral.intersection(extent)
        guard !bounds.isNull, !bounds.isEmpty else {
            throw LumenError.invalidResponse("The region is outside the photo.")
        }
        return bounds
    }
}

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
    private let originalIsKnownSDR: Bool
    private let originalMaterialSourceIsComplete: Bool
    private let originalAlphaImage: CIImage?
    private var masks: [UUID: CIImage] = [:]
    private var patches: [UUID: CIImage] = [:]
    private var renderRevision = UUID()
    struct MaterialSource {
        let id: UUID
        let revision: UUID
        let region: NormalizedRect
        let input: EncodedImage
        let image: CIImage
        let allowsSDRGamutMapping: Bool
    }
    private var materialSources: [MaterialSource] = []
    /// First insertion must still match the source revision. After successful
    /// insertion the asset is ordinary retained history and can be replayed.
    private var pendingMaterialRevisions: [UUID: UUID] = [:]

    public init(contentsOf url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw LumenError.invalidResponse("The photo could not be opened.")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let oriented: CIImage
        let mayHaveAlpha: Bool
        if PhotoFormats.isRaw(url) {
            // A camera RAW is developed by Core Image with the camera's own defaults (white balance, exposure, lens
            // corrections), upright, and kept at full precision; it is saved as sRGB.
            guard let raw = CIRAWFilter(imageURL: url), let developed = raw.outputImage,
                  !developed.extent.isInfinite, !developed.extent.isEmpty else {
                throw LumenError.invalidResponse("This RAW photo could not be developed on this Mac.")
            }
            oriented = developed
            originalIsKnownSDR = false
            originalMaterialSourceIsComplete = true // CIRAWFilter retains scene-linear precision.
            mayHaveAlpha = false
            sourceColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        } else {
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw LumenError.invalidResponse("The photo could not be opened.")
            }
            let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
            oriented = CIImage(cgImage: image).oriented(forExifOrientation: orientation)
            let sourceDepth = (properties?[kCGImagePropertyDepth] as? NSNumber)?.intValue
            let hasGainMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
                || CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
            // Default ImageIO decoding can reduce a floating TIFF or a gain
            // map to an SDR CGImage. That is not evidence the original was
            // bounded SDR, so it cannot authorize this optional pixel path.
            originalMaterialSourceIsComplete = sourceDepth.map { $0 <= image.bitsPerComponent } == true && !hasGainMap
            originalIsKnownSDR = sourceDepth == 8 && image.bitsPerComponent == 8 && !image.bitmapInfo.contains(.floatComponents)
                && image.contentHeadroom.isFinite && image.contentHeadroom <= 1
                && !hasGainMap
            mayHaveAlpha = ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
            let colorSpace = image.colorSpace
            sourceColorSpace = (colorSpace?.model == .indexed ? colorSpace?.baseColorSpace : colorSpace)
                ?? CGColorSpace(name: CGColorSpace.sRGB)!
        }
        photo = oriented.transformed(by: CGAffineTransform(translationX: -oriented.extent.minX,
                                                         y: -oriented.extent.minY))
        originalAlphaImage = mayHaveAlpha ? photo : nil
        canvas = photo
        capturedAt = PhotoStatistics.capturedAt(in: properties)
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
        invalidateMaterialSources()
    }

    public func render(maxLongEdge: Int) async throws -> EncodedImage {
        try preview(in: cropBounds(), maxLongEdge: maxLongEdge)
    }

    public func render(region: NormalizedRect, maxLongEdge: Int) async throws -> EncodedImage {
        let bounds = try Self.bounds(of: region, in: cropBounds())
        return try preview(in: bounds, maxLongEdge: maxLongEdge, materialRegion: region)
    }

    public func fitted(_ mask: MaskData, region: NormalizedRect) async throws -> MaskData {
        EditSupport.fitted(mask, photo: try photo(in: region), context: context)
    }

    public func extended(_ mask: MaskData, region: NormalizedRect) async throws -> MaskData {
        EditSupport.extended(mask, photo: try photo(in: region), context: context)
    }

    public func recolourEdges(_ generated: EncodedImage, over original: EncodedImage, within mask: MaskData) async throws -> PreparedPatch? {
        try EditSupport.recolourEdges(generated, over: original, within: mask)
    }

    public func materialRecolour(_ generated: EncodedImage, over original: EncodedImage, in region: NormalizedRect,
                                instances: [MaskData]) async throws -> PreparedPatch? {
        try Task.checkCancellation()
        guard originalMaterialSourceIsComplete else { return nil }
        // Old recordings and other hosts carry no local render provenance.
        // They retain the established edge path, rather than rereading a
        // possibly changed photo under an old generation result.
        guard let id = original.renderContextID else { return nil }
        let source = try materialSource(id, original: original, region: region)
        let alphaImage = originalAlphaImage
        guard pendingMaterialRevisions.count < 8 else {
            throw LumenError.invalidResponse("Too many material edits are waiting to be applied.")
        }
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let context = CIContext(options: [
                .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false,
            ])
            let bounds = CGRect(x: 0, y: 0, width: original.size.width, height: original.size.height)
            let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
            // The ordinary preview flattens alpha for its JPEG. Verify actual
            // source opacity before that representation can hide transparency.
            if let alphaImage {
                let alphaBounds = alphaImage.extent
                let width = Int(alphaBounds.width), height = Int(alphaBounds.height)
                var alpha = [Float](repeating: 0, count: width * height)
                context.render(alphaImage, toBitmap: &alpha, rowBytes: width * 4,
                               bounds: alphaBounds, format: .Af, colorSpace: nil)
                for i in alpha.indices {
                    if i & 8191 == 0 { try Task.checkCancellation() }
                    guard alpha[i].isFinite, abs(alpha[i] - 1) <= 0.00001 else { return nil as PreparedPatch? }
                }
            }
            var samples = [Float](repeating: 0, count: original.size.width * original.size.height * 4)
            context.render(source.image, toBitmap: &samples, rowBytes: original.size.width * 16,
                           bounds: bounds, format: .RGBAf, colorSpace: space)
            // Known untouched 8-bit SDR can contain extended finite codec /
            // colour-conversion values even before any scaling. Its normal
            // sRGB PNG representation is the canonical display gamut. Unknown
            // or edited sources retain strict HDR/radiance bounds.
            for pixel in stride(from: 0, to: samples.count, by: 4) {
                if pixel & 32767 == 0 { try Task.checkCancellation() }
                guard (0..<3).allSatisfy({ samples[pixel + $0].isFinite
                          && (source.allowsSDRGamutMapping || (samples[pixel + $0] >= 0 && samples[pixel + $0] <= 1)) }),
                      samples[pixel + 3].isFinite, abs(samples[pixel + 3] - 1) <= 0.00001 else {
                    return nil as PreparedPatch?
                }
            }
            try Task.checkCancellation()
            guard let data = context.pngRepresentation(of: source.image, format: .RGBA8,
                                                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
                throw LumenError.invalidResponse("The captured material source could not be encoded.")
            }
            let lossless = EncodedImage(data: data, format: .png, size: original.size)
            let result = try EditSupport.materialRecolour(generated, over: lossless, instances: instances)
            try Task.checkCancellation()
            return result
        }
        var result = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        _ = try materialSource(id, original: original, region: region)
        if result != nil {
            guard pendingMaterialRevisions.count < 8 else {
                throw LumenError.invalidResponse("Too many material edits are waiting to be applied.")
            }
            let preparedID = UUID()
            result?.image.renderContextID = preparedID
            pendingMaterialRevisions[preparedID] = source.revision
        }
        return result
    }

    func materialSource(_ id: UUID, original: EncodedImage, region: NormalizedRect) throws -> MaterialSource {
        guard let source = materialSources.first(where: { $0.id == id }), source.revision == renderRevision,
              source.region == region, source.input.size == original.size, source.input == original else {
            throw LumenError.invalidResponse("The photo changed after its material source was rendered.")
        }
        return source
    }

    private func invalidateMaterialSources() {
        renderRevision = UUID()
        materialSources.removeAll()
    }

    /// The photo as it is now, framed, over `region`.
    private func photo(in region: NormalizedRect) throws -> CIImage {
        rendered(scale: 1).cropped(to: try Self.bounds(of: region, in: cropBounds()))
    }

    public func measure(_ image: EncodedImage, mask: MaskData?) async throws -> ColourMeasurement? {
        // A render shows the photo as it is framed now; a mask over the whole photo is cut to that frame first.
        let framed = mask.map { mask in cropRect().map { mask.cropped(to: $0) } ?? mask }
        return try EditSupport.measure(image, mask: framed)
    }

    public func lostDetail(before: EncodedImage, after: EncodedImage) async throws -> [LostDetail] {
        try EditSupport.lostDetail(before: before, after: after)
    }

    public func reshaped(_ image: EncodedImage, mask: MaskData, face: MaskData?, keep: MaskData?, shoulders: Double,
                         waist: Double) async throws -> Reshaped? {
        try EditSupport.reshaped(image, mask: mask, face: face, keep: keep, shoulders: shoulders, waist: waist)
    }

    public func toneMatched(_ generated: EncodedImage, to original: EncodedImage, under mask: MaskData) async throws -> EncodedImage? {
        try EditSupport.toneMatched(generated, to: original, under: mask)
    }

    public func skin(_ image: EncodedImage, face: MaskData, person: MaskData) async throws -> MaskData? {
        try EditSupport.skin(image, face: face, person: person)
    }

    public func drawn(_ generated: EncodedImage, over original: EncodedImage, beyond mask: MaskData, reach: Int) async throws -> MaskData? {
        try EditSupport.drawn(generated, over: original, beyond: mask, reach: reach)
    }

    public func pockets(_ generated: EncodedImage, over original: EncodedImage, outside mask: MaskData, reach: Int) async throws -> Pockets? {
        try EditSupport.pockets(generated, over: original, outside: mask, reach: reach)
    }

    public func shaded(_ generated: EncodedImage, onto original: EncodedImage, within mask: MaskData) async throws -> EncodedImage? {
        try EditSupport.shaded(generated, onto: original, within: mask)
    }

    public func laid(_ top: EncodedImage, over base: EncodedImage, within mask: MaskData) async throws -> EncodedImage? {
        try EditSupport.laid(top, over: base, within: mask)
    }

    public func apply(_ layer: Layer, assets: AssetStore) async throws {
        var mask: CIImage?
        var patch: CIImage?
        var materialContextID: UUID?
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
            materialContextID = encoded.renderContextID
        case .crop(let rect):
            _ = try Self.bounds(of: rect, in: canvas.extent)
        }
        if let id = materialContextID, let expected = pendingMaterialRevisions[id] {
            guard expected == renderRevision else {
                throw LumenError.invalidResponse("The photo changed before its prepared material edit could be applied.")
            }
            pendingMaterialRevisions[id] = nil
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
        invalidateMaterialSources()
    }

    public func remove(_ layer: Layer.ID) async throws {
        stack.layers.removeAll { $0.id == layer }
        masks[layer] = nil
        patches[layer] = nil
        invalidateMaterialSources()
    }

    /// Turns a layer on or off without changing its pixels.
    public func setEnabled(_ enabled: Bool, for layer: Layer.ID) {
        guard let index = stack.layers.firstIndex(where: { $0.id == layer }) else { return }
        stack.layers[index].isEnabled = enabled
        invalidateMaterialSources()
    }

    /// Sets how much of a layer is visible, from zero to one.
    public func setOpacity(_ opacity: Double, for layer: Layer.ID) {
        guard let index = stack.layers.firstIndex(where: { $0.id == layer }) else { return }
        stack.layers[index].opacity = Self.opacity(opacity)
        invalidateMaterialSources()
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

    private func preview(in bounds: CGRect, maxLongEdge: Int, materialRegion: NormalizedRect? = nil) throws -> EncodedImage {
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
        var result = EncodedImage(data: try encoded(output, format: .jpeg,
                                              colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!),
                            format: .jpeg, size: size)
        if let region = materialRegion {
            let id = UUID()
            result.renderContextID = id
            materialSources.append(MaterialSource(id: id, revision: renderRevision, region: region, input: result, image: output,
                                                  allowsSDRGamutMapping: originalIsKnownSDR && stack.layers.isEmpty && straighteningAngle == 0))
            if materialSources.count > 4 { materialSources.removeFirst(materialSources.count - 4) }
        }
        return result
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
                let placed = EditSupport.placedPatch(patch, in: patchBounds)
                // A patch's mask is the size of its own crop, so it is placed on the patch, not stretched over the photo.
                let coverage = EditSupport.placedMask(mask, in: patchBounds, precompositedEdges: layer.precompositedEdges == true)
                let enlargement = min(patchBounds.width / patch.extent.width, patchBounds.height / patch.extent.height)
                let matched = EditSupport.matchedPatch(placed, to: image, within: coverage, enlargement: enlargement,
                                                      restoresDetail: layer.drawsNew != true,
                                                      precompositedEdges: layer.precompositedEdges == true,
                                                      sourceReferenced: layer.sourceReferenced == true, context: context)
                // A prepared recolour already carries a physical object edge;
                // inward feathering would matte it twice. Other patch kinds
                // retain their existing, explicitly softened blending path.
                let matte: CIImage
                if layer.precompositedEdges == true {
                    matte = coverage
                } else {
                    let step = max(patchBounds.width / mask.extent.width, patchBounds.height / mask.extent.height)
                    matte = PhotoCompositor.feather(coverage, radius: max(0.5, step * 0.7))
                }
                image = PhotoCompositor.blend(matched, over: image, mask: matte, opacity: layer.opacity)
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

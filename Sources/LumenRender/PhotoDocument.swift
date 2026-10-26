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

    private let photo: CIImage
    private let sourceColorSpace: CGColorSpace
    private let context: CIContext
    private let photoSize: PixelSize
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
        photoSize = PixelSize(width: Int(oriented.extent.width), height: Int(oriented.extent.height))
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

    public func size() async -> PixelSize { photoSize }

    public func render(maxLongEdge: Int) async throws -> EncodedImage {
        try preview(in: cropBounds(), maxLongEdge: maxLongEdge)
    }

    public func render(region: NormalizedRect, maxLongEdge: Int) async throws -> EncodedImage {
        let bounds = try Self.bounds(of: region, in: cropBounds())
        return try preview(in: bounds, maxLongEdge: maxLongEdge)
    }

    public func apply(_ layer: Layer, assets: AssetStore) async throws {
        var mask: CIImage?
        var patch: CIImage?
        switch layer.content {
        case .adjustment(_, let id):
            if let id { mask = try await loadMask(id, assets: assets) }
        case .patch(let imageID, let maskID, let rect):
            _ = try Self.bounds(of: rect, in: photo.extent)
            mask = try await loadMask(maskID, assets: assets)
            guard case .image(let encoded) = await assets.get(imageID),
                  let image = CIImage(data: encoded.data, options: [.applyOrientationProperty: true]),
                  image.extent.width.isFinite, image.extent.height.isFinite,
                  image.extent.width > 0, image.extent.height > 0 else {
                throw LumenError.invalidResponse("The layer's generated image is missing or unreadable.")
            }
            patch = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX,
                                                            y: -image.extent.minY))
        case .crop(let rect):
            _ = try Self.bounds(of: rect, in: photo.extent)
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
        let image = rendered(scale: 1).cropped(to: cropBounds())
        let data = try encoded(image, format: format, colorSpace: sourceColorSpace)
        try data.write(to: url, options: .atomic)
    }

    private func loadMask(_ id: AssetID, assets: AssetStore) async throws -> CIImage {
        guard case .mask(let mask) = await assets.get(id),
              mask.size.width > 0, mask.size.height > 0,
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

    private func cropBounds() -> CGRect {
        for layer in stack.layers.reversed() where layer.isEnabled && layer.opacity > 0 {
            if case .crop(let rect) = layer.content,
               let bounds = try? Self.bounds(of: rect, in: photo.extent) { return bounds }
        }
        return photo.extent
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
        let extent = photo.extent.applying(transform)
        var image = PhotoCompositor.resized(photo, to: extent)
        for layer in stack.layers where layer.isEnabled && layer.opacity > 0 {
            switch layer.content {
            case .adjustment(let values, _):
                let adjusted = PhotoAdjustments.apply(values, to: image)
                let mask = masks[layer.id].map { PhotoCompositor.scaledMask($0, to: extent) }
                let feathered = mask.map { PhotoCompositor.feather($0, radius: max(0.35, min(extent.width, extent.height) * 0.001)) }
                image = PhotoCompositor.blend(adjusted, over: image, mask: feathered, opacity: layer.opacity)
            case .patch(_, _, let rect):
                guard let patch = patches[layer.id], let mask = masks[layer.id],
                      let bounds = try? Self.bounds(of: rect, in: photo.extent) else { continue }
                let patchBounds = bounds.applying(transform)
                let placed = PhotoCompositor.resized(patch, to: patchBounds)
                // A patch's mask is the size of its own crop, so it is placed on the patch, not stretched over the photo.
                let coverage = PhotoCompositor.scaledMask(mask, to: patchBounds)
                let matched = PhotoCompositor.colorMatched(placed, to: image, mask: coverage,
                                                           context: context)
                let feathered = PhotoCompositor.feather(coverage, radius: min(patchBounds.width, patchBounds.height) * 0.015)
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

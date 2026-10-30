import Foundation
import LumenCore
import LumenRender

/// A document that Studio can preview, edit, and export.
protocol StudioPhoto: EditHost {
    var layers: [Layer] { get async }
    func export(to url: URL, format: EncodedImage.Format) async throws
}

extension PhotoDocument: StudioPhoto {}

/// A photo whose horizon can be restored alongside its layers.
protocol StudioStraighteningPhoto: StudioPhoto {
    var straighteningAngle: Double { get async }
    func straighten(degrees: Double) async throws
}

extension PhotoDocument: StudioStraighteningPhoto {}

struct StudioLayerSnapshot: Equatable {
    var layers: [Layer] = []
    var straightening: Double = 0
}

/// Keeps a layer's assets available when the document restores an earlier edit.
actor StudioPhotoHost: EditHost {
    let photo: any StudioPhoto
    private var layerAssets: [UUID: AssetStore] = [:]

    init(photo: any StudioPhoto) {
        self.photo = photo
    }

    func size() async -> PixelSize { await photo.size() }

    func render(maxLongEdge: Int) async throws -> EncodedImage {
        try await photo.render(maxLongEdge: maxLongEdge)
    }

    func render(region: NormalizedRect, maxLongEdge: Int) async throws -> EncodedImage {
        try await photo.render(region: region, maxLongEdge: maxLongEdge)
    }

    func apply(_ layer: Layer, assets: AssetStore) async throws {
        try await photo.apply(layer, assets: assets)
        layerAssets[layer.id] = assets
    }

    func remove(_ layer: Layer.ID) async throws {
        try await photo.remove(layer)
    }

    // What the document works out from its pixels, passed on: without them Studio's recolours had no edge fitting,
    // its critic no colour numbers, and an athletic build was asked of Muse Image, which changed the shoulders by 1%.
    func fitted(_ mask: MaskData, region: NormalizedRect) async throws -> MaskData {
        try await photo.fitted(mask, region: region)
    }

    func extended(_ mask: MaskData, region: NormalizedRect) async throws -> MaskData {
        try await photo.extended(mask, region: region)
    }

    func measure(_ image: EncodedImage, mask: MaskData?) async throws -> ColourMeasurement? {
        try await photo.measure(image, mask: mask)
    }

    func lostDetail(before: EncodedImage, after: EncodedImage) async throws -> [LostDetail] {
        try await photo.lostDetail(before: before, after: after)
    }

    func reshaped(_ image: EncodedImage, mask: MaskData, face: MaskData?, keep: MaskData?, shoulders: Double,
                  waist: Double) async throws -> Reshaped? {
        try await photo.reshaped(image, mask: mask, face: face, keep: keep, shoulders: shoulders, waist: waist)
    }

    func toneMatched(_ generated: EncodedImage, to original: EncodedImage, under mask: MaskData) async throws -> EncodedImage? {
        try await photo.toneMatched(generated, to: original, under: mask)
    }

    func skin(_ image: EncodedImage, face: MaskData, person: MaskData) async throws -> MaskData? {
        try await photo.skin(image, face: face, person: person)
    }

    func drawn(_ generated: EncodedImage, over original: EncodedImage, beyond mask: MaskData, reach: Int) async throws -> MaskData? {
        try await photo.drawn(generated, over: original, beyond: mask, reach: reach)
    }

    func shaded(_ generated: EncodedImage, onto original: EncodedImage, within mask: MaskData) async throws -> EncodedImage? {
        try await photo.shaded(generated, onto: original, within: mask)
    }

    func layers() async -> [Layer] { await photo.layers }

    func straightening() async -> Double {
        await (photo as? any StudioStraighteningPhoto)?.straighteningAngle ?? 0
    }

    /// Retains the asset-free layers added by the library's automatic pass.
    func retainAutoLayers() async {
        for layer in await photo.layers where layerAssets[layer.id] == nil {
            if case .adjustment(_, nil) = layer.content { layerAssets[layer.id] = AssetStore() }
        }
    }

    /// Replays a snapshot in order because the host has no layer update or undo API.
    func restore(_ layers: [Layer], straightening: Double? = nil) async throws {
        for layer in layers where layerAssets[layer.id] == nil {
            throw StudioPhotoError.missingAssets(layer.label)
        }
        let previous = await self.layers()
        let previousAngle = await self.straightening()
        do {
            try await replay(layers, straightening: straightening)
        } catch {
            let changeError = error
            do {
                try await replay(previous, straightening: previousAngle)
            } catch {
                throw StudioPhotoError.restoreFailed(change: changeError.localizedDescription,
                                                     recovery: error.localizedDescription)
            }
            throw changeError
        }
    }

    private func replay(_ layers: [Layer], straightening: Double?) async throws {
        for layer in await self.layers().reversed() {
            try await photo.remove(layer.id)
        }
        if let straightening, let photo = photo as? any StudioStraighteningPhoto {
            try await photo.straighten(degrees: straightening)
        }
        for layer in layers {
            guard let assets = layerAssets[layer.id] else {
                throw StudioPhotoError.missingAssets(layer.label)
            }
            try await photo.apply(layer, assets: assets)
        }
    }
}

enum StudioPhotoError: LocalizedError {
    case unreadablePreview
    case missingAssets(String)
    case restoreFailed(change: String, recovery: String)

    var errorDescription: String? {
        switch self {
        case .unreadablePreview:
            "The renderer returned a preview that macOS couldn't open."
        case .missingAssets(let label):
            "The assets for “\(label)” are no longer available."
        case .restoreFailed(let change, let recovery):
            "\(change) Restoring the previous layers also failed: \(recovery)"
        }
    }
}

import Foundation
import LumenCore
import LumenRender

/// A document that Studio can preview, edit, and export.
protocol StudioPhoto: EditHost {
    var layers: [Layer] { get async }
    func export(to url: URL, format: EncodedImage.Format) async throws
}

extension PhotoDocument: StudioPhoto {}

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

    func layers() async -> [Layer] { await photo.layers }

    /// Replays a snapshot in order because the host has no layer update or undo API.
    func restore(_ layers: [Layer]) async throws {
        for layer in layers where layerAssets[layer.id] == nil {
            throw StudioPhotoError.missingAssets(layer.label)
        }
        let previous = await self.layers()
        do {
            try await replay(layers)
        } catch {
            let changeError = error
            do {
                try await replay(previous)
            } catch {
                throw StudioPhotoError.restoreFailed(change: changeError.localizedDescription,
                                                     recovery: error.localizedDescription)
            }
            throw changeError
        }
    }

    private func replay(_ layers: [Layer]) async throws {
        for layer in await self.layers().reversed() {
            try await photo.remove(layer.id)
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

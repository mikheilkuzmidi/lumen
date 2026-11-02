import Foundation
import LumenCore

/// Keeps the library's documents and layer assets available to the photo window.
actor StudioLibraryHost: LibraryHost {
    let library: any LibraryHost
    private var hosts: [PhotoID: StudioPhotoHost] = [:]

    init(_ library: any LibraryHost) { self.library = library }

    func photos() async throws -> [PhotoID] { try await library.photos() }
    func thumbnail(_ photo: PhotoID, maxLongEdge: Int) async throws -> EncodedImage {
        try await library.thumbnail(photo, maxLongEdge: maxLongEdge)
    }
    func facts(_ photo: PhotoID) async throws -> PhotoFacts { try await library.facts(photo) }
    func applyAuto(_ photo: PhotoID) async throws -> String {
        let host = try await photoHost(photo)
        let label = try await library.applyAuto(photo)
        await host.retainAutoLayers()
        return label
    }
    func straighten(_ photo: PhotoID, degrees: Double) async throws { try await library.straighten(photo, degrees: degrees) }
    func flag(_ photo: PhotoID, reason: String) async throws { try await library.flag(photo, reason: reason) }
    func save(_ photo: PhotoID) async throws { try await library.save(photo) }
    func editHost(_ photo: PhotoID) async throws -> any EditHost { try await photoHost(photo) }

    /// Only documents already opened in a photo window need an in-memory revision check. Reading a whole
    /// library's stamps must not decode every full-resolution photo just to show a plan.
    func revisionSnapshot(_ photos: [PhotoID]) async -> [PhotoID: StudioLayerSnapshot] {
        var snapshots: [PhotoID: StudioLayerSnapshot] = [:]
        for photo in photos {
            guard let host = hosts[photo] else { continue }
            snapshots[photo] = await StudioLayerSnapshot(layers: host.layers(), straightening: host.straightening())
        }
        return snapshots
    }

    func photoHost(_ photo: PhotoID) async throws -> StudioPhotoHost {
        if let host = hosts[photo] { return host }
        guard let document = try await library.editHost(photo) as? any StudioPhoto else {
            throw StudioScriptError.message("This library cannot open a photo in Studio.")
        }
        // Another request may have opened this photo while its document was loading.
        if let host = hosts[photo] { return host }
        let host = StudioPhotoHost(photo: document)
        await host.retainAutoLayers()
        hosts[photo] = host
        return host
    }
}

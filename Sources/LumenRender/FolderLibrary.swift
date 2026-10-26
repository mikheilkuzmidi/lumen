import Foundation
import LumenCore

/// A folder's photos and their retained edit documents, exported to a separate folder.
public actor FolderLibrary: LibraryHost {
    public let folder: URL
    public let output: URL
    public private(set) var flagged: [PhotoID: String] = [:]

    private let orderedPhotos: [PhotoID]
    private let originals: [PhotoID: URL]
    private let destinations: [PhotoID: URL]
    private var documents: [PhotoID: PhotoDocument] = [:]

    /// Lists JPEG, PNG and HEIC files directly in the folder. HEIC exports keep their base name with .jpg.
    public init(folder: URL, output: URL) throws {
        self.folder = folder.standardizedFileURL
        self.output = output.standardizedFileURL
        guard !Self.sameFolder(folder, output) else {
            throw LumenError.invalidResponse("The output folder must be separate from the originals.")
        }
        let entries = try FileManager.default.contentsOfDirectory(at: folder,
                                                                  includingPropertiesForKeys: [.isRegularFileKey])
        let photos = try entries.filter { url in
            guard ["jpg", "jpeg", "png", "heic"].contains(url.pathExtension.lowercased()) else { return false }
            return try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var originals: [PhotoID: URL] = [:]
        var destinations: [PhotoID: URL] = [:]
        var names: Set<String> = []
        for url in photos {
            let id = PhotoID(url.lastPathComponent)
            let name = url.pathExtension.lowercased() == "heic"
                ? url.deletingPathExtension().lastPathComponent + ".jpg" : url.lastPathComponent
            guard names.insert(name.lowercased()).inserted else {
                throw LumenError.invalidResponse("More than one photo would export as \(name).")
            }
            originals[id] = url
            destinations[id] = output.appendingPathComponent(name)
        }
        orderedPhotos = photos.map { PhotoID($0.lastPathComponent) }
        self.originals = originals
        self.destinations = destinations
    }

    public func photos() async throws -> [PhotoID] { orderedPhotos }

    public func thumbnail(_ photo: PhotoID, maxLongEdge: Int) async throws -> EncodedImage {
        try await document(for: photo).render(maxLongEdge: maxLongEdge)
    }

    public func facts(_ photo: PhotoID) async throws -> PhotoFacts {
        let document = try document(for: photo)
        return try await document.statistics().facts
    }

    /// Adds modest tone and colour corrections from the photo's median, tail percentiles and grey-world estimate.
    public func applyAuto(_ photo: PhotoID) async throws -> String {
        let document = try document(for: photo)
        let values = try await document.statistics().autoValues
        let changes = AdjustmentKey.allCases.compactMap { key -> String? in
            guard let value = values[key] else { return nil }
            let amount = String(format: key == .exposure ? "%+.2f" : "%+.1f",
                                locale: Locale(identifier: "en_US_POSIX"), value)
            return "\(key.rawValue) \(amount)"
        }
        let label = "Auto: " + (changes.isEmpty ? "no change" : changes.joined(separator: ", "))
        try await document.apply(Layer(label: label, content: .adjustment(values: values, mask: nil)), assets: AssetStore())
        return label
    }

    public func straighten(_ photo: PhotoID, degrees: Double) async throws {
        try await document(for: photo).straighten(degrees: degrees)
    }

    public func flag(_ photo: PhotoID, reason: String) async throws {
        _ = try original(for: photo)
        flagged[photo] = reason
    }

    public func editHost(_ photo: PhotoID) async throws -> any EditHost {
        try document(for: photo)
    }

    /// Exports at full size and writes <exported name>.lumen.json with labels, rotation and any flag.
    public func save(_ photo: PhotoID) async throws {
        let document = try document(for: photo)
        guard let destination = destinations[photo], !Self.sameFolder(folder, output) else {
            throw LumenError.invalidResponse("The output folder must be separate from the originals.")
        }
        let sidecar = destination.appendingPathExtension("lumen.json")
        let sourcePaths = Set(originals.values.map { $0.resolvingSymlinksInPath().standardizedFileURL })
        guard !sourcePaths.contains(destination.resolvingSymlinksInPath().standardizedFileURL),
              !sourcePaths.contains(sidecar.resolvingSymlinksInPath().standardizedFileURL) else {
            throw LumenError.invalidResponse("An export must not replace an original photo.")
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let format: EncodedImage.Format = destination.pathExtension.lowercased() == "png" ? .png : .jpeg
        let state = try await document.exportSnapshot(to: destination, format: format)
        let record = Sidecar(layers: state.labels, straighteningAngle: state.angle, flag: flagged[photo])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: sidecar, options: .atomic)
    }

    private func document(for photo: PhotoID) throws -> PhotoDocument {
        if let document = documents[photo] { return document }
        let document = try PhotoDocument(contentsOf: original(for: photo))
        documents[photo] = document
        return document
    }

    private func original(for photo: PhotoID) throws -> URL {
        guard let url = originals[photo] else {
            throw LumenError.invalidResponse("No photo named \(photo.rawValue) is in this library.")
        }
        return url
    }

    private static func sameFolder(_ first: URL, _ second: URL) -> Bool {
        if first.resolvingSymlinksInPath().standardizedFileURL == second.resolvingSymlinksInPath().standardizedFileURL {
            return true
        }
        let firstID = try? first.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject
        let secondID = try? second.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject
        return firstID != nil && secondID != nil && firstID == secondID
    }

    private struct Sidecar: Encodable {
        var layers: [String]
        var straighteningAngle: Double
        var flag: String?
    }
}

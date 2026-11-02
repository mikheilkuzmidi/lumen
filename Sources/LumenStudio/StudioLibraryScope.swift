import Foundation
import LumenCore

enum StudioLibraryScope: String, CaseIterable {
    case selected = "Selected photos"
    case currentView = "Current view"
    case entireLibrary = "Entire library"
}

private struct StudioSourceStamp: Equatable, Sendable {
    var modified: Date?
    var size: Int?
    var identity: String?

    init(_ url: URL) throws {
        let value = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .fileResourceIdentifierKey])
        modified = value.contentModificationDate
        size = value.fileSize
        identity = value.fileResourceIdentifier.map { String(describing: $0) }
    }
}

/// Freezes which photos the engine can see, rather than filtering only the window's count.
actor ScopedStudioLibrary: LibraryHost {
    let base: StudioLibraryHost
    let targets: [PhotoID]
    private let folder: URL
    private let stamps: [PhotoID: StudioSourceStamp]
    private let revisions: [PhotoID: StudioLayerSnapshot]

    init(base: StudioLibraryHost, targets: [PhotoID], folder: URL) async throws {
        self.base = base
        self.targets = targets
        self.folder = folder
        stamps = try await Task.detached {
            try Dictionary(uniqueKeysWithValues: targets.map { ($0, try StudioSourceStamp(folder.appendingPathComponent($0.rawValue))) })
        }.value
        revisions = await base.revisionSnapshot(targets)
    }

    func validateSources() async throws {
        let current = try await Task.detached { [folder, targets] in
            try Dictionary(uniqueKeysWithValues: targets.map { ($0, try StudioSourceStamp(folder.appendingPathComponent($0.rawValue))) })
        }.value
        guard current == stamps else {
            throw StudioScriptError.message("A source photo changed while this plan was being prepared. Discard it and plan again.")
        }
        let currentRevisions = await base.revisionSnapshot(targets)
        // Opening an unchanged photo after planning is harmless; adding, removing or changing a layer is not.
        for photo in targets {
            guard (currentRevisions[photo] ?? StudioLayerSnapshot()) == (revisions[photo] ?? StudioLayerSnapshot()) else {
                throw StudioScriptError.message("The edits to \(photo.rawValue) changed while this plan was being prepared. Discard it and plan again.")
            }
        }
    }

    private func check(_ photo: PhotoID) throws {
        guard stamps[photo] != nil else { throw StudioScriptError.message("This photo is outside the selected batch scope.") }
        guard try StudioSourceStamp(folder.appendingPathComponent(photo.rawValue)) == stamps[photo] else {
            throw StudioScriptError.message("The source for \(photo.rawValue) changed during this edit. Plan it again.")
        }
    }

    func photos() async throws -> [PhotoID] { targets }
    func thumbnail(_ photo: PhotoID, maxLongEdge: Int) async throws -> EncodedImage {
        try check(photo); return try await base.thumbnail(photo, maxLongEdge: maxLongEdge)
    }
    func facts(_ photo: PhotoID) async throws -> PhotoFacts { try check(photo); return try await base.facts(photo) }
    func applyAuto(_ photo: PhotoID) async throws -> String { try check(photo); return try await base.applyAuto(photo) }
    func straighten(_ photo: PhotoID, degrees: Double) async throws { try check(photo); try await base.straighten(photo, degrees: degrees) }
    func flag(_ photo: PhotoID, reason: String) async throws { try check(photo); try await base.flag(photo, reason: reason) }
    func editHost(_ photo: PhotoID) async throws -> any EditHost { try check(photo); return try await base.editHost(photo) }
    func save(_ photo: PhotoID) async throws { try check(photo); try await base.save(photo) }
}

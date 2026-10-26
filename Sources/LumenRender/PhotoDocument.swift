import Foundation
import LumenCore

/// A photo and its layers, rendered with Core Image. It is the host the command-line tool and Lumen Studio edit.
public actor PhotoDocument: EditHost {
    public let url: URL
    public private(set) var stack = LayerStack()

    public init(contentsOf url: URL) throws {
        self.url = url
    }

    public func size() async -> PixelSize { PixelSize(width: 0, height: 0) }

    public func render(maxLongEdge: Int) async throws -> EncodedImage { throw LumenError.notBuilt("The renderer") }

    public func render(region: NormalizedRect, maxLongEdge: Int) async throws -> EncodedImage { throw LumenError.notBuilt("The renderer") }

    public func apply(_ layer: Layer, assets: AssetStore) async throws { throw LumenError.notBuilt("The renderer") }

    public func remove(_ layer: Layer.ID) async throws { throw LumenError.notBuilt("The renderer") }

    /// Writes the photo with its layers at full size.
    public func export(to url: URL, format: EncodedImage.Format) async throws { throw LumenError.notBuilt("Export") }
}

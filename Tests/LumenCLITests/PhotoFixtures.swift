import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import LumenCore
import Synchronization
import UniformTypeIdentifiers
@testable import lumen

enum PhotoFixtures {
    static var renderingAvailable: Bool {
        let context = CIContext()
        return context.jpegRepresentation(of: CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2)),
                                          colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) != nil
    }

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-cli-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func image(size: PixelSize = PixelSize(width: 20, height: 10), gray: CGFloat = 0.4) throws -> EncodedImage {
        let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw CLIError("Could not generate a test photo.") }
        return EncodedImage(data: data as Data, format: .png, size: size)
    }

    static func size(of url: URL) -> PixelSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return PixelSize(width: image.width, height: image.height)
    }

    static func options() throws -> EditOptions { try EditOptions.parse(["--preview", "10"]) }

    static func models(planner: any Planner = ScriptedPlanner()) -> EditModels {
        EditModels(planner: planner, segmenter: ScriptedSegmenter(), generator: ScriptedGenerator())
    }
}

final class LineRecorder: Sendable {
    private let storage = Mutex<[String]>([])
    var lines: [String] { storage.withLock { $0 } }
    func append(_ line: String) { storage.withLock { $0.append(line) } }
}

actor ScriptedPlanner: Planner {
    let modelID = "muse-spark-1.3"
    private var critiques: [Critique]
    private let failingInstruction: String?
    private(set) var requests: [PlanRequest] = []

    init(critiques: [Critique] = [Critique(satisfied: true, notes: "The coat is navy.")], failingInstruction: String? = nil) {
        self.critiques = critiques
        self.failingInstruction = failingInstruction
    }

    func plan(_ request: PlanRequest) async throws -> EditPlan {
        requests.append(request)
        if request.instruction == failingInstruction { throw LumenError.refused("Cannot edit this photo.") }
        return EditPlan(summary: "Make the coat navy.", steps: [
            .select(Selection(id: "coat", concept: "coat")),
            .regenerate(Regeneration(region: "coat", prompt: "A navy coat")),
        ])
    }

    func critique(_ request: CritiqueRequest) async throws -> Critique {
        critiques.isEmpty ? Critique(satisfied: true, notes: "The coat is navy.") : critiques.removeFirst()
    }
}

struct ScriptedSegmenter: Segmenter {
    let modelID = "sam-3.1"
    func segment(_ request: SegmentRequest) async throws -> [Segment] {
        let size = request.image.size
        var coverage = [UInt8](repeating: 0, count: size.width * size.height)
        for index in 0..<(coverage.count * 18 / 100) { coverage[index] = 255 }
        let mask = MaskData(size: size, coverage: coverage)
        return [Segment(label: "coat", box: mask.boundingBox!, mask: mask)]
    }
}

struct ScriptedGenerator: Generator {
    let modelID = "muse-image-1.0"
    func generate(_ request: GenerateRequest) async throws -> EncodedImage {
        try PhotoFixtures.image(size: request.image.size, gray: 0.2)
    }
}

actor ScriptedPhoto: EditHost {
    let image: EncodedImage
    private(set) var layers: [Layer] = []

    init() throws { image = try PhotoFixtures.image() }
    func size() async -> PixelSize { image.size }
    func render(maxLongEdge: Int) async throws -> EncodedImage { image }
    func render(region: NormalizedRect, maxLongEdge: Int) async throws -> EncodedImage { image }
    func apply(_ layer: Layer, assets: AssetStore) async throws { layers.append(layer) }
    func remove(_ id: Layer.ID) async throws { layers.removeAll { $0.id == id } }
}

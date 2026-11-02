import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import LumenCore
import LumenMeta
import Testing
@testable import LumenRender

/// An explicit local recording is required. This diagnostic never makes a
/// network call; it extracts the actual layer assets and reconstructs the
/// production composite before changing one operation at a time.
@Test(.enabled(if: ProcessInfo.processInfo.environment["LUMEN_EDGE_RUN"] != nil,
               "Set LUMEN_EDGE_RUN and LUMEN_EDGE_OUTPUT for a no-cost edge replay."))
func recordedEdgeReplayAblations() async throws {
    let environment = ProcessInfo.processInfo.environment
    let recording = try #require(environment["LUMEN_EDGE_RUN"])
    let destination = URL(fileURLWithPath: try #require(environment["LUMEN_EDGE_OUTPUT"]), isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let run = try RecordedRun.read(URL(fileURLWithPath: recording))
    let photoURL = repository.appendingPathComponent("Fixtures/photos").appendingPathComponent(run.photo)
    let originalURL = FileManager.default.fileExists(atPath: photoURL.path) ? photoURL
        : repository.appendingPathComponent("Fixtures/library").appendingPathComponent(run.photo)
    let document = try PhotoDocument(contentsOf: originalURL)
    let transport = ReplayingMetaTransport(run)
    let configuration = MetaConfiguration(apiKey: "recording-only", recordsCost: false)
    let generator = EdgeRecordingGenerator(delegate: MetaGenerator(configuration: configuration, transport: transport), output: destination)
    let agent = EditAgent(planner: MetaPlanner(configuration: configuration, transport: transport),
                          segmenter: MetaSegmenter(configuration: configuration, transport: transport),
                          generator: generator, host: document)
    var selected: MaskData?
    for try await event in agent.run(run.instruction) {
        if case .selected(_, let segment) = event { selected = segment.mask }
        if case .trace(let trace) = event { #expect(trace.kind != .failure) }
    }
    #expect(await transport.unused == 0)
    try await document.export(to: destination.appendingPathComponent("replay.png"), format: .png)
    let layers = await document.layers
    let layer = try #require(layers.last)
    guard case .patch(let imageID, let maskID, let rect) = layer.content else {
        Issue.record("Expected the recorded patch layer"); return
    }
    let assets = await agent.assets
    guard case .image(let encoded) = await assets.get(imageID), case .mask(let mask) = await assets.get(maskID) else {
        Issue.record("Recorded layer assets missing"); return
    }
    try encoded.data.write(to: destination.appendingPathComponent("generated-placed.png"))
    let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                      .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
    let source = try #require(CGImageSourceCreateWithURL(originalURL as CFURL, nil))
    let sourceImage = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let outputSpace = sourceImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
    let original = PhotoCompositor.resized(CIImage(cgImage: sourceImage),
                                           to: CGRect(x: 0, y: 0, width: sourceImage.width, height: sourceImage.height))
    let patch = try #require(CIImage(data: encoded.data))
    let extent = original.extent
    let bounds = CGRect(x: rect.x * extent.width, y: (1 - rect.y - rect.height) * extent.height,
                        width: rect.width * extent.width, height: rect.height * extent.height).integral.intersection(extent)
    let placed = PhotoCompositor.resized(patch, to: bounds)
    func image(_ data: MaskData) throws -> CIImage {
        let provider = try #require(CGDataProvider(data: Data(data.coverage) as CFData))
        let cg = try #require(CGImage(width: data.size.width, height: data.size.height, bitsPerComponent: 8,
                                      bitsPerPixel: 8, bytesPerRow: data.size.width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: [], provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        return CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
    }
    func write(_ image: CIImage, _ name: String) throws {
        let bytes = try #require(context.pngRepresentation(of: image, format: .RGBA8, colorSpace: outputSpace))
        try bytes.write(to: destination.appendingPathComponent(name + ".png"))
    }
    try write(original, "original")
    try write(try image(mask), "final-mask")
    try Data(mask.coverage).write(to: destination.appendingPathComponent("final-mask-values.bin"))
    let coverage = PhotoCompositor.scaledMask(try image(mask), to: bounds)
    let corrected = PhotoCompositor.colorMatched(placed, to: original, mask: coverage, context: context)
    let enlargement = min(bounds.width / patch.extent.width, bounds.height / patch.extent.height)
    let detailed = layer.drawsNew == true ? corrected : PhotoCompositor.restoringDetail(corrected, from: original, enlargement: enlargement)
    let step = max(bounds.width / Double(mask.size.width), bounds.height / Double(mask.size.height))
    let feathered = PhotoCompositor.feather(coverage, radius: max(0.5, step * 0.7))
    try write(PhotoCompositor.blend(detailed, over: original, mask: coverage, opacity: layer.opacity), "reconstructed")
    try write(PhotoCompositor.blend(detailed, over: original, mask: feathered, opacity: layer.opacity), "with-inward-feather")
    try write(PhotoCompositor.blend(corrected, over: original, mask: feathered, opacity: layer.opacity), "without-detail")
    try write(PhotoCompositor.blend(detailed, over: original, mask: coverage, opacity: layer.opacity), "without-final-feather")
    try write(PhotoCompositor.blend(placed, over: original, mask: coverage, opacity: layer.opacity), "without-colour-match")
    try write(PhotoCompositor.blend(corrected, over: original, mask: CIImage(color: .white).cropped(to: bounds), opacity: 1),
              "opaque-patch-oracle")
    // Diagnostic ablation, not a candidate fix: it deliberately violates soft
    // coverage so its face/background spill can be measured as well as its rim.
    let firm = MaskData(size: mask.size, coverage: mask.coverage.map { $0 > 0 ? 255 : 0 })
    let firmCoverage = PhotoCompositor.scaledMask(try image(firm), to: bounds)
    try write(PhotoCompositor.blend(corrected, over: original, mask: firmCoverage, opacity: layer.opacity), "all-positive-support")
    if let selected {
        let crop = selected.cropped(to: rect).resized(to: mask.size)
        let guide = original.cropped(to: bounds)
        let fitted = EditSupport.fitted(crop, photo: guide, context: context)
        let extended = EditSupport.extended(fitted, photo: guide, context: context)
        for (name, sample) in [("original-sam-mask", crop), ("fitted-mask", fitted), ("extended-mask", extended)] {
            try write(try image(sample), name)
            try Data(sample.coverage).write(to: destination.appendingPathComponent(name + "-values.bin"))
        }
    }
    let summary: [String: Any] = ["imageWidth": encoded.size.width, "imageHeight": encoded.size.height,
                                "maskWidth": mask.size.width, "maskHeight": mask.size.height,
                                "patchBounds": [bounds.minX, bounds.minY, bounds.width, bounds.height],
                                "rect": [rect.x, rect.y, rect.width, rect.height], "opacity": layer.opacity,
                                "precompositedEdges": layer.precompositedEdges ?? false,
                                "followsPhoto": mask.followsPhoto,
                                "enlargement": enlargement, "partialMaskPixels": mask.coverage.filter { $0 > 0 && $0 < 255 }.count,
                                "drawsNew": layer.drawsNew ?? false]
    try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        .write(to: destination.appendingPathComponent("assets.json"))
}

private struct EdgeRecordingGenerator: Generator {
    let delegate: MetaGenerator
    let output: URL
    var modelID: String { delegate.modelID }
    init(delegate: MetaGenerator, output: URL) { self.delegate = delegate; self.output = output }
    func generate(_ request: GenerateRequest) async throws -> EncodedImage {
        try request.image.data.write(to: output.appendingPathComponent("original-crop-for-edge.jpg"))
        try RGBAPixels(request.image).encoded().data.write(to: output.appendingPathComponent("srgb-original-crop.png"))
        let image = try await delegate.generate(request)
        try image.data.write(to: output.appendingPathComponent("model-generated-crop.png"))
        try RGBAPixels(image).encoded().data.write(to: output.appendingPathComponent("srgb-model-generated-crop.png"))
        return image
    }
}

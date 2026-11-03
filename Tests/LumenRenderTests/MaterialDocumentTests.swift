import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import LumenCore
import Testing
@testable import LumenRender

@Suite("Material document provenance", .serialized)
struct MaterialDocumentTests {
    private let size = PixelSize(width: 240, height: 160)

    private func instances() -> [MaskData] {
        [20, 140].map { left in
            var mask = MaskData(size: size, filledWith: 0)
            for y in 24..<136 { for x in left..<(left + 80) { mask.coverage[y * size.width + x] = 255 } }
            return mask
        }
    }

    @Test func actualFourSAMInstancesAndRecordedColourTraverseRealAgentDocumentPlacement() async throws {
        let fixture = try #require(Bundle.module.url(forResource: "Material", withExtension: nil))
            .appendingPathComponent("four-shirts")
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = repo.appendingPathComponent("Fixtures/library/men-laughing-by-green-valley.jpg")
        let sourceBytes = try Data(contentsOf: source)
        let fullSize = PixelSize(width: 1280, height: 853)
        let masks = try (0..<4).map { index in
            let path = fixture.appendingPathComponent("instance-\(index).png")
            let decoded = try RGBAPixels(EncodedImage(data: Data(contentsOf: path), format: .png, size: fullSize))
            return MaskData(size: fullSize, coverage: stride(from: 0, to: decoded.bytes.count, by: 4).map { decoded.bytes[$0] })
        }
        let proposed = EncodedImage(data: try Data(contentsOf: fixture.appendingPathComponent("proposed-colour-crop.png")),
                                    format: .png, size: PixelSize(width: 1239, height: 385))
        // The independently recorded proposal has its own documented crop.
        // Register that observation on the full photo before the real agent
        // asks for its current integral generation crop (one row different).
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
        let graph = try #require(CIImage(data: sourceBytes, options: [.applyOrientationProperty: true]))
        let sourcePNG = try #require(context.pngRepresentation(of: graph, format: .RGBA8,
                                                              colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        var registered = try RGBAPixels(EncodedImage(data: sourcePNG, format: .png, size: fullSize))
        let recordedCrop = try RGBAPixels(proposed)
        for y in 0..<recordedCrop.height { for x in 0..<recordedCrop.width {
            for c in 0..<4 { registered.bytes[((y + 360) * fullSize.width + x + 20) * 4 + c] = recordedCrop.bytes[(y * recordedCrop.width + x) * 4 + c] }
        } }
        let document = try PhotoDocument(contentsOf: source)
        let host = MaterialDocumentHost(document: document)
        let generator = MaterialRecordedGenerator(proposal: try registered.encoded(), host: host)
        let agent = EditAgent(planner: MaterialDocumentPlanner(), segmenter: MaterialRecordedSegmenter(masks: masks),
                              generator: generator, host: host, configuration: AgentConfiguration(maxRevisions: 0))
        for try await _ in agent.run("Make the shirts in these selected photos blue") {}
        #expect(await generator.calls == 1)
        #expect(await host.materialCalls == 1)
        #expect(await host.preparedCount == 1, "Real SAM masks and recorded colour must reach the optional document helper")
        let layer = try #require(await document.layers.last)
        #expect(layer.precompositedEdges == true)
        #expect(layer.sourceReferenced == true)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("material-four-shirts-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: output) }
        try await document.export(to: output, format: .png)
        let result = try RGBAPixels(EncodedImage(data: Data(contentsOf: output), format: .png, size: fullSize))
        let before = try RGBAPixels(EncodedImage(data: sourceBytes, format: .jpeg, size: fullSize))
        guard case .patch(let imageID, let maskID, _) = layer.content,
              case .image(let preparedImage) = await agent.assets.get(imageID),
              case .mask(let preparedMask) = await agent.assets.get(maskID) else {
            Issue.record("Actual prepared material assets missing"); return
        }
        let preparedPixels = try RGBAPixels(preparedImage)
        for (x, y) in [(230, 520), (550, 510), (780, 530), (1020, 530)] {
            let i = (y * fullSize.width + x) * 4
            #expect(Int(result.bytes[i + 2]) > Int(result.bytes[i]) + 8, "Each independently selected shirt is blue")
            let local = (y - 360) * preparedPixels.width + x - 20
            #expect(preparedMask.coverage[local] == 255)
            #expect((0..<3).allSatisfy { abs(Int(result.bytes[i + $0]) - Int(preparedPixels.bytes[local * 4 + $0])) <= 2 },
                    "A source-referenced material keeps prepared illumination instead of getting globally darkened again")
        }
        for (x, y) in [(0, 0), (100, 250), (450, 370), (870, 443), (1140, 750)] {
            let i = (y * fullSize.width + x) * 4
            #expect((0..<3).allSatisfy { abs(Int(result.bytes[i + $0]) - Int(before.bytes[i + $0])) <= 2 },
                    "Protected background/skin keeps its source pixels")
        }
        if let target = ProcessInfo.processInfo.environment["LUMEN_MATERIAL_DOCUMENT_OUTPUT"], target.hasPrefix("/") {
            try Data(contentsOf: output).write(to: URL(fileURLWithPath: target), options: .atomic)
        }
        let replayed = try JSONDecoder().decode(Layer.self, from: JSONEncoder().encode(layer))
        var legacy = layer; legacy.sourceReferenced = nil
        try await document.apply(legacy, assets: agent.assets)
        let legacyOutput = output.deletingPathExtension().appendingPathExtension("legacy.png")
        defer { try? FileManager.default.removeItem(at: legacyOutput) }
        try await document.export(to: legacyOutput, format: .png)
        let legacyPixels = try RGBAPixels(EncodedImage(data: Data(contentsOf: legacyOutput), format: .png, size: fullSize))
        #expect(zip(legacyPixels.bytes, result.bytes).contains { abs(Int($0) - Int($1)) > 2 },
                "Nil metadata retains the legacy correction path, as measured by the colour-matching counterfactual")
        try await document.apply(replayed, assets: agent.assets)
        let replayOutput = output.deletingPathExtension().appendingPathExtension("replayed.png")
        defer { try? FileManager.default.removeItem(at: replayOutput) }
        try await document.export(to: replayOutput, format: .png)
        let replayPixels = try RGBAPixels(EncodedImage(data: Data(contentsOf: replayOutput), format: .png, size: fullSize))
        #expect(replayed.sourceReferenced == true)
        #expect(zip(replayPixels.bytes, result.bytes).allSatisfy { abs(Int($0) - Int($1)) <= 1 },
                "Saved/replayed metadata preserves the accepted source-referenced rendering")
        try await document.remove(layer.id)
        let untouched = try await document.render(region: .whole, maxLongEdge: 1280)
        let manual = Layer(label: "User edit record", content: .adjustment(values: [.exposure: 0], mask: nil))
        try await document.apply(manual, assets: AssetStore())
        let edited = try await document.render(region: .whole, maxLongEdge: 1280)
        #expect(edited == untouched, "This counterfactual changes provenance while retaining the same generation pixels")
        #expect(try await document.materialRecolour(registered.encoded(), over: edited, in: .whole, instances: masks) == nil,
                "Edited source state must not inherit the known-untouched-SDR exception merely from equal JPEG bytes")
        #expect(await document.layers.map(\.id) == [manual.id])
        #expect(try Data(contentsOf: source) == sourceBytes)
    }

    @Test func realAgentUsesCapturedLosslessSourceThroughHelperAndPlacement() async throws {
        let folder = try LibraryFolder(); defer { folder.remove() }
        let source = try folder.photo(name: "source.png", width: size.width, height: size.height) { x, y in
            guard (24..<136).contains(y), (20..<100).contains(x) || (140..<220).contains(x) else { return (24, 70, 32) }
            let base: UInt8 = x < 120 ? 185 : 225
            let fold: UInt8 = y >= 75 && y < 85 ? 25 : 0
            return (base - fold, base - fold, base - fold)
        }
        let document = try PhotoDocument(contentsOf: source)
        let host = MaterialDocumentHost(document: document)
        let generator = MaterialDocumentGenerator()
        let agent = EditAgent(planner: MaterialDocumentPlanner(), segmenter: MaterialDocumentSegmenter(masks: instances()),
                              generator: generator, host: host, configuration: AgentConfiguration(maxRevisions: 0))
        for try await _ in agent.run("Make the shirts in these selected photos blue") {}
        #expect(await generator.calls == 1)
        #expect(await host.preparedCount == 1, "The actual document helper must accept, rather than taking a default-nil fake route")
        #expect(await document.layers.last?.precompositedEdges == true)
        let output = folder.root.appendingPathComponent("result.png")
        try await document.export(to: output, format: .png)
        let pixels = try RGBAPixels(EncodedImage(data: Data(contentsOf: output), format: .png, size: size))
        let before = try RGBAPixels(EncodedImage(data: Data(contentsOf: source), format: .png, size: size))
        for (x, y) in [(60, 60), (180, 60)] {
            let i = (y * size.width + x) * 4
            #expect(pixels.bytes[i + 2] > pixels.bytes[i] + 20)
        }
        for (x, y) in [(0, 0), (12, 70), (115, 70), (230, 70)] {
            let i = (y * size.width + x) * 4
            #expect((0..<3).allSatisfy { abs(Int(pixels.bytes[i + $0]) - Int(before.bytes[i + $0])) <= 2 })
        }
        let layer = try #require(await document.layers.last)
        await document.setOpacity(0, for: layer.id)
        let hidden = folder.root.appendingPathComponent("hidden.png")
        try await document.export(to: hidden, format: .png)
        let hiddenPixels = try RGBAPixels(EncodedImage(data: Data(contentsOf: hidden), format: .png, size: size))
        #expect(zip(hiddenPixels.bytes, before.bytes).allSatisfy { abs(Int($0) - Int($1)) <= 1 },
                "Zero opacity restores original pixels; export container bytes need not match source metadata")
        try await document.remove(layer.id)
        #expect(await document.layers.isEmpty)
    }

    @Test func tokenRegionBytesSizeRevisionAndRetentionAreChecked() async throws {
        let folder = try LibraryFolder(); defer { folder.remove() }
        let document = try PhotoDocument(contentsOf: folder.photo(name: "source.png"))
        let input = try await document.render(region: .whole, maxLongEdge: 128)
        #expect(input.renderContextID != nil)
        var legacy = input; legacy.renderContextID = nil
        #expect(try await document.materialRecolour(input, over: legacy, in: .whole, instances: instances()) == nil)
        var changed = input; changed.data.append(0)
        await #expect(throws: LumenError.self) { _ = try await document.materialRecolour(input, over: changed, in: .whole, instances: instances()) }
        changed = input; changed.size.width += 1
        await #expect(throws: LumenError.self) { _ = try await document.materialRecolour(input, over: changed, in: .whole, instances: instances()) }
        await #expect(throws: LumenError.self) {
            _ = try await document.materialRecolour(input, over: input, in: NormalizedRect(x: 0.1, y: 0, width: 0.9, height: 1), instances: instances())
        }
        for _ in 0..<4 { _ = try await document.render(region: .whole, maxLongEdge: 128) }
        await #expect(throws: LumenError.self) { _ = try await document.materialRecolour(input, over: input, in: .whole, instances: instances()) }
        let current = try await document.render(region: .whole, maxLongEdge: 128)
        try await document.apply(Layer(label: "Manual exposure", content: .adjustment(values: [.exposure: 0.5], mask: nil)), assets: AssetStore())
        await #expect(throws: LumenError.self) { _ = try await document.materialRecolour(current, over: current, in: .whole, instances: instances()) }
    }

    @Test func cancelledWorkAndNonopaqueSourceCannotProduceMaterialPixels() async throws {
        let folder = try LibraryFolder(); defer { folder.remove() }
        let path = folder.input.appendingPathComponent("alpha.png")
        let image = CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        try LibraryImages.write(image, to: path)
        let document = try PhotoDocument(contentsOf: path)
        let input = try await document.render(region: .whole, maxLongEdge: 240)
        let proposal = try RGBAPixels(width: size.width, height: size.height,
            bytes: Array(repeating: [UInt8(25), 55, 105, 255], count: size.width * size.height).flatMap { $0 }).encoded()
        #expect(try await document.materialRecolour(proposal, over: input, in: .whole, instances: instances()) == nil)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await document.materialRecolour(input, over: input, in: .whole, instances: instances())
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await document.layers.isEmpty)
    }

    @Test(arguments: ["straighten", "opacity", "enabled", "remove"])
    func everyDocumentMutationRejectsEarlierGenerationState(_ mutation: String) async throws {
        let folder = try LibraryFolder(); defer { folder.remove() }
        let document = try PhotoDocument(contentsOf: folder.photo(name: "source.png"))
        let layer = Layer(label: "Existing edit", content: .adjustment(values: [.exposure: 0.2], mask: nil))
        try await document.apply(layer, assets: AssetStore())
        let input = try await document.render(region: .whole, maxLongEdge: 128)
        switch mutation {
        case "straighten": try await document.straighten(degrees: 1)
        case "opacity": await document.setOpacity(0.5, for: layer.id)
        case "enabled": await document.setEnabled(false, for: layer.id)
        default: try await document.remove(layer.id)
        }
        await #expect(throws: LumenError.self) {
            _ = try await document.materialRecolour(input, over: input, in: .whole, instances: instances())
        }
    }

    @Test func highDynamicRangeSourceDeclinesInsteadOfClippingToTheMaterialWorkingRange() async throws {
        let folder = try LibraryFolder(); defer { folder.remove() }
        let path = folder.input.appendingPathComponent("hdr.tif")
        let bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let image = CIImage(color: .white).cropped(to: bounds).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 2, y: 1.2, z: 0.4, w: 1),
        ]).cropped(to: bounds)
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
        try context.writeTIFFRepresentation(of: image, to: path, format: .RGBAh,
                                           colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        let decoded = try #require(CIImage(contentsOf: path))
        var hdr = [Float](repeating: 0, count: 4)
        context.render(decoded, toBitmap: &hdr, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        #expect(hdr[0] > 1.5, "The encoded fixture must independently retain actual above-white radiance")
        let document = try PhotoDocument(contentsOf: path)
        let input = try await document.render(region: .whole, maxLongEdge: 240)
        let proposal = try RGBAPixels(width: size.width, height: size.height,
            bytes: Array(repeating: [UInt8(25), 55, 105, 255], count: size.width * size.height).flatMap { $0 }).encoded()
        #expect(try await document.materialRecolour(proposal, over: input, in: .whole, instances: instances()) == nil)
        #expect(await document.layers.isEmpty)
    }

    @Test func preparedPatchRejectsInterveningEditButConsumedAssetsCanReplayHistory() async throws {
        let folder = try LibraryFolder(); defer { folder.remove() }
        let path = try folder.photo(name: "source.png", width: size.width, height: size.height) { x, y in
            ((20..<100).contains(x) || (140..<220).contains(x)) && (24..<136).contains(y) ? (200, 200, 200) : (20, 65, 25)
        }
        let document = try PhotoDocument(contentsOf: path)
        func prepare() async throws -> PreparedPatch {
            let input = try await document.render(region: .whole, maxLongEdge: 240)
            let proposal = try RGBAPixels(width: size.width, height: size.height,
                bytes: Array(repeating: [UInt8(25), 55, 105, 255], count: size.width * size.height).flatMap { $0 }).encoded()
            return try #require(await document.materialRecolour(proposal, over: input, in: .whole, instances: instances()))
        }
        func layer(_ prepared: PreparedPatch, assets: AssetStore) async -> Layer {
            Layer(label: "Prepared material", content: .patch(image: await assets.put(.image(prepared.image)),
                mask: await assets.put(.mask(prepared.mask)), rect: .whole), precompositedEdges: true)
        }
        let stale = try await prepare(), staleAssets = AssetStore()
        let staleLayer = await layer(stale, assets: staleAssets)
        let manual = Layer(label: "Manual edit", content: .adjustment(values: [.exposure: 0.1], mask: nil))
        try await document.apply(manual, assets: AssetStore())
        await #expect(throws: LumenError.self) { try await document.apply(staleLayer, assets: staleAssets) }
        #expect(await document.layers.map(\.id) == [manual.id])
        let fresh = try await prepare(), assets = AssetStore()
        let freshLayer = await layer(fresh, assets: assets)
        try await document.apply(freshLayer, assets: assets)
        try await document.remove(freshLayer.id)
        try await document.apply(freshLayer, assets: assets)
        #expect(await document.layers.map(\.id) == [manual.id, freshLayer.id],
                "A successfully applied retained asset must still support history replay")
    }

    @Test func abandonedPreparationsDeclineInsteadOfBlockingAndStayRejectedWhenStale() async throws {
        let folder = try LibraryFolder(); defer { folder.remove() }
        let path = try folder.photo(name: "source.png", width: size.width, height: size.height) { x, y in
            ((20..<100).contains(x) || (140..<220).contains(x)) && (24..<136).contains(y) ? (200, 200, 200) : (20, 65, 25)
        }
        let document = try PhotoDocument(contentsOf: path)
        let proposal = try RGBAPixels(width: size.width, height: size.height,
            bytes: Array(repeating: [UInt8(25), 55, 105, 255], count: size.width * size.height).flatMap { $0 }).encoded()
        func prepare() async throws -> PreparedPatch? {
            let input = try await document.render(region: .whole, maxLongEdge: 240)
            return try await document.materialRecolour(proposal, over: input, in: .whole, instances: instances())
        }
        // Eight preparations a cancelled or rejected step never applied.
        var abandoned: [PreparedPatch] = []
        for _ in 0..<8 { abandoned.append(try #require(await prepare())) }
        #expect(try await prepare() == nil, "Too many waiting preparations decline to the established path")
        let manual = Layer(label: "Manual edit", content: .adjustment(values: [.exposure: 0.1], mask: nil))
        try await document.apply(manual, assets: AssetStore())
        let fresh = try #require(await prepare(), "Stale preparations no longer occupy the waiting limit")
        let assets = AssetStore()
        let staleLayer = Layer(label: "Stale material", content: .patch(image: await assets.put(.image(abandoned[0].image)),
            mask: await assets.put(.mask(abandoned[0].mask)), rect: .whole), precompositedEdges: true)
        await #expect(throws: LumenError.self) { try await document.apply(staleLayer, assets: assets) }
        await #expect(throws: LumenError.self, "A rejected stale preparation stays rejected on retry") {
            try await document.apply(staleLayer, assets: assets)
        }
        let freshLayer = Layer(label: "Fresh material", content: .patch(image: await assets.put(.image(fresh.image)),
            mask: await assets.put(.mask(fresh.mask)), rect: .whole), precompositedEdges: true)
        try await document.apply(freshLayer, assets: assets)
        #expect(await document.layers.map(\.id) == [manual.id, freshLayer.id])
    }
}

private struct MaterialDocumentPlanner: Planner {
    let modelID = "recorded planner"
    func plan(_ request: PlanRequest) async throws -> EditPlan {
        EditPlan(summary: "Recolour", steps: [.select(Selection(id: "shirts", concept: "shirt", every: true)),
            .regenerate(Regeneration(region: "shirts", prompt: "Make all shirts blue, preserving texture and lighting"))])
    }
    func critique(_ request: CritiqueRequest) async throws -> Critique { Critique(satisfied: true, notes: "Checked") }
}
private struct MaterialDocumentSegmenter: Segmenter {
    let modelID = "recorded SAM"
    let masks: [MaskData]
    func segment(_ request: SegmentRequest) async throws -> [Segment] {
        masks.compactMap { mask in mask.boundingBox.map { Segment(label: "shirt", box: $0, mask: mask) } }
    }
}
private actor MaterialDocumentGenerator: Generator {
    let modelID = "recorded generator"
    private(set) var calls = 0
    func generate(_ request: GenerateRequest) async throws -> EncodedImage {
        calls += 1
        let n = request.image.size.width * request.image.size.height
        return try RGBAPixels(width: request.image.size.width, height: request.image.size.height,
                              bytes: Array(repeating: [UInt8(25), 55, 105, 255], count: n).flatMap { $0 }).encoded()
    }
}
private actor MaterialDocumentHost: EditHost {
    let document: PhotoDocument
    private(set) var preparedCount = 0
    private(set) var materialCalls = 0
    private var regions: [UUID: NormalizedRect] = [:]
    init(document: PhotoDocument) { self.document = document }
    func size() async -> PixelSize { await document.size() }
    func render(maxLongEdge: Int) async throws -> EncodedImage { try await document.render(maxLongEdge: maxLongEdge) }
    func render(region: NormalizedRect, maxLongEdge: Int) async throws -> EncodedImage {
        let image = try await document.render(region: region, maxLongEdge: maxLongEdge)
        if let id = image.renderContextID { regions[id] = region }
        return image
    }
    func region(for image: EncodedImage) -> NormalizedRect? { image.renderContextID.flatMap { regions[$0] } }
    func apply(_ layer: Layer, assets: AssetStore) async throws { try await document.apply(layer, assets: assets) }
    func remove(_ layer: Layer.ID) async throws { try await document.remove(layer) }
    func materialRecolour(_ generated: EncodedImage, over original: EncodedImage, in region: NormalizedRect, instances: [MaskData]) async throws -> PreparedPatch? {
        materialCalls += 1
        let target = ProcessInfo.processInfo.environment["LUMEN_MATERIAL_DOCUMENT_OUTPUT"]
        if let target, target.hasPrefix("/"), let id = original.renderContextID {
            let source = try await document.materialSource(id, original: original, region: region)
            let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                              .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
            let base = URL(fileURLWithPath: target).deletingPathExtension()
            let png = try #require(context.pngRepresentation(of: source.image, format: .RGBA8,
                                                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
            try png.write(to: base.appendingPathExtension("captured-source.png"))
            try generated.data.write(to: base.appendingPathExtension("generator.png"))
            for (index, mask) in instances.enumerated() {
                try Data(mask.coverage).write(to: base.appendingPathExtension("instance-\(index).bin"))
            }
            let info: [String: Any] = ["region": [region.x, region.y, region.width, region.height],
                                      "size": [original.size.width, original.size.height], "instances": instances.count,
                                      "instanceSizes": instances.map { [$0.size.width, $0.size.height] },
                                      "instanceFollowsPhoto": instances.map(\.followsPhoto)]
            try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
                .write(to: base.appendingPathExtension("geometry.json"))
        }
        let result = try await document.materialRecolour(generated, over: original, in: region, instances: instances)
        if result != nil { preparedCount += 1 }
        if let target, target.hasPrefix("/"), let result {
            let base = URL(fileURLWithPath: target).deletingPathExtension()
            try result.image.data.write(to: base.appendingPathExtension("prepared.png"))
            try Data(result.mask.coverage).write(to: base.appendingPathExtension("prepared-mask.bin"))
        }
        return result
    }
}

private actor MaterialRecordedGenerator: Generator {
    let modelID = "recorded Muse Image proposal"
    let proposal: EncodedImage
    let host: MaterialDocumentHost
    private(set) var calls = 0
    init(proposal: EncodedImage, host: MaterialDocumentHost) { self.proposal = proposal; self.host = host }
    func generate(_ request: GenerateRequest) async throws -> EncodedImage {
        calls += 1
        let region = try #require(await host.region(for: request.image))
        let w = Double(proposal.size.width), h = Double(proposal.size.height)
        let ciBounds = CGRect(x: region.x * w, y: h - (region.y + region.height) * h,
                              width: region.width * w, height: region.height * h).integral
        let topLeft = CGRect(x: ciBounds.minX, y: h - ciBounds.maxY, width: ciBounds.width, height: ciBounds.height)
        let source = try #require(CGImageSourceCreateWithData(proposal.data as CFData, nil))
        let full = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let crop = try #require(full.cropping(to: topLeft))
        #expect(PixelSize(width: crop.width, height: crop.height) == request.image.size)
        let data = try #require(CIContext().pngRepresentation(of: CIImage(cgImage: crop), format: .RGBA8,
                                                            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        return EncodedImage(data: data, format: .png, size: request.image.size)
    }
}
private struct MaterialRecordedSegmenter: Segmenter {
    let modelID = "recorded SAM instances"
    let masks: [MaskData]
    func segment(_ request: SegmentRequest) async throws -> [Segment] {
        let crop = NormalizedRect(x: 20.0 / 1280, y: 360.0 / 853, width: 1239.0 / 1280, height: 385.0 / 853)
        return masks.compactMap { original in
            let mask = request.image.size == original.size ? original : original.cropped(to: crop).resized(to: request.image.size)
            return mask.boundingBox.map { Segment(label: "t-shirt", box: $0, mask: mask) }
        }
    }
}

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import LumenCore
import Testing
import UniformTypeIdentifiers
@testable import LumenRender

@Suite(.enabled(if: Rendering.isAvailable, "Core Image rendering is unavailable on this host."))
struct PhotoPixelTests {
    @Test(arguments: [UTType.png, .jpeg, .heic])
    func loadsPhotosWithOrientation(type: UTType) async throws {
        let folder = try PhotoFolder()
        defer { folder.remove() }
        let url = try folder.photo(width: 80, height: 48, type: type, orientation: 6) { x, _ in
            x < 40 ? RGB(220, 30, 20) : RGB(20, 40, 220)
        }
        let document = try PhotoDocument(contentsOf: url)
        #expect(await document.size() == PixelSize(width: 48, height: 80))
        let rendered = try await document.render(maxLongEdge: 200)
        let pixels = try Pixels(data: rendered.data)
        #expect(rendered.format == .jpeg)
        #expect(rendered.size == PixelSize(width: 48, height: 80))
        #expect(pixels[24, 15].red > 0.7)
        #expect(pixels[24, 65].blue > 0.7)
    }

    @Test
    func exposureDoublesLinearLight() async throws {
        let folder = try PhotoFolder()
        defer { folder.remove() }
        let document = try PhotoDocument(contentsOf: folder.photo { _, _ in RGB(90, 90, 90) })
        let before = try await folder.pixels(document)
        try await document.apply(Layer(label: "Exposure", content: .adjustment(values: [.exposure: 1], mask: nil)),
                                 assets: AssetStore())
        let after = try await folder.pixels(document)
        let ratio = linear(after[64, 48].red) / linear(before[64, 48].red)
        #expect(abs(ratio - 2) < 0.06)
    }

    /// Contrast pivots on middle grey as it is seen, not on 0.5 in linear light.
    @Test
    func contrastKeepsMiddleGreyAndSpreadsTheTonesAroundIt() async throws {
        let folder = try PhotoFolder()
        defer { folder.remove() }
        let document = try PhotoDocument(contentsOf: folder.photo { x, _ in x < 43 ? RGB(50, 50, 50) : x < 86 ? RGB(118, 118, 118) : RGB(200, 200, 200) })
        let before = try await folder.pixels(document)
        try await document.apply(Layer(label: "Contrast", content: .adjustment(values: [.contrast: 50], mask: nil)), assets: AssetStore())
        let after = try await folder.pixels(document)
        #expect(abs(after[64, 48].red - before[64, 48].red) < 0.02)
        #expect(after[20, 48].red < before[20, 48].red - 0.02 && after[20, 48].red > 0.1)
        #expect(after[108, 48].red > before[108, 48].red + 0.02)
    }

    /// The night photo that went darker: dehaze in linear light sent every shadow to black.
    @Test
    func dehazeDeepensShadowsWithoutCrushingThem() async throws {
        let folder = try PhotoFolder()
        defer { folder.remove() }
        let document = try PhotoDocument(contentsOf: folder.photo { _, _ in RGB(40, 30, 15) })
        let before = try await folder.pixels(document)
        try await document.apply(Layer(label: "Dehaze", content: .adjustment(values: [.dehaze: 10], mask: nil)), assets: AssetStore())
        let after = try await folder.pixels(document)
        for (channel, was, now) in [("red", before[64, 48].red, after[64, 48].red), ("blue", before[64, 48].blue, after[64, 48].blue)] {
            #expect(now < was && now > was - 0.025, "\(channel): \(was) → \(now)")
        }
        try await document.apply(Layer(label: "Night", content: .adjustment(values: [
            .exposure: 0.35, .shadows: 15, .highlights: 20, .whites: 15, .contrast: 15, .vibrance: 25,
        ], mask: nil)), assets: AssetStore())
        let lifted = try await folder.pixels(document)
        #expect(lifted[64, 48].red + lifted[64, 48].green > before[64, 48].red + before[64, 48].green, "+0.35 stop brightens a night photo")
    }

    @Test
    func temperatureWarmsAboutAsMuchAsItCools() async throws {
        let folder = try PhotoFolder()
        defer { folder.remove() }
        var shifts: [Double] = []
        for temperature in [35.0, -35.0] {
            let document = try PhotoDocument(contentsOf: folder.photo { _, _ in RGB(128, 128, 128) })
            try await document.apply(Layer(label: "White balance", content: .adjustment(values: [.temperature: temperature], mask: nil)),
                                     assets: AssetStore())
            let pixel = try await folder.pixels(document)[64, 48]
            shifts.append(pixel.red - pixel.blue)
        }
        #expect(shifts[0] > 0.07, "+35 is visibly warmer")
        #expect(shifts[1] < -0.07, "-35 is visibly cooler")
        #expect(abs(shifts[0] / shifts[1]) > 0.7 && abs(shifts[0] / shifts[1]) < 1.4)
    }

    @Test
    func maskUsesTopRowsAndLeavesOutsidePixelsUnchanged() async throws {
        let folder = try PhotoFolder()
        defer { folder.remove() }
        let document = try PhotoDocument(contentsOf: folder.photo { _, _ in RGB(90, 90, 90) })
        let assets = AssetStore()
        let mask = MaskData(size: PixelSize(width: 16, height: 12),
                            coverage: (0..<192).map { $0 / 16 < 6 && $0 % 16 < 8 ? 255 : 0 })
        let id = await assets.put(.mask(mask))
        let before = try await folder.pixels(document)
        try await document.apply(Layer(label: "Top left", content: .adjustment(values: [.exposure: 1], mask: id)), assets: assets)
        let after = try await folder.pixels(document)
        #expect(after[20, 20].red > before[20, 20].red + 0.1)
        #expect(abs(after[20, 75].red - before[20, 75].red) <= 1.0 / 255)
        for y in 0..<after.height {
            for x in 68..<after.width {
                #expect(after[x, y].distance(to: before[x, y]) <= 1.0 / 255)
            }
        }
    }

    @Test
    func layerControlsPreserveTheOriginalAndCachedAssets() async throws {
        let folder = try PhotoFolder()
        defer { folder.remove() }
        let document = try PhotoDocument(contentsOf: folder.photo { x, y in RGB(UInt8(40 + x), UInt8(60 + y), 90) })
        let original = try await document.render(maxLongEdge: 128)
        let layer = Layer(label: "Exposure", content: .adjustment(values: [.exposure: 1], mask: nil))
        try await document.apply(layer, assets: AssetStore())
        await document.setEnabled(false, for: layer.id)
        #expect(try await document.render(maxLongEdge: 128) == original)
        await document.setEnabled(true, for: layer.id)
        await document.setOpacity(0, for: layer.id)
        #expect(try await document.render(maxLongEdge: 128) == original)
        await document.setOpacity(0.5, for: layer.id)
        let half = try await folder.pixels(document)
        await document.setOpacity(1, for: layer.id)
        let full = try await folder.pixels(document)
        #expect(half[30, 30].red < full[30, 30].red)
        #expect(await document.layers.count == 1)
        try await document.remove(layer.id)
        #expect(await document.layers.isEmpty)
        #expect(try await document.render(maxLongEdge: 128) == original)
    }

    @Test
    func cachedMasksSurviveAssetRemovalAndLayerReplacement() async throws {
        let folder = try PhotoFolder()
        defer { folder.remove() }
        let document = try PhotoDocument(contentsOf: folder.photo { _, _ in RGB(90, 90, 90) })
        let original = try await folder.pixels(document)
        let assets = AssetStore()
        let maskID = await assets.put(.mask(MaskData(size: PixelSize(width: 2, height: 2), filledWith: 255)))
        var layer = Layer(label: "Exposure", content: .adjustment(values: [.exposure: 1], mask: maskID))
        try await document.apply(layer, assets: assets)
        await assets.remove(maskID)
        let cached = try await folder.pixels(document)
        #expect(cached[64, 48].red > original[64, 48].red)
        layer.content = .adjustment(values: [.exposure: -1], mask: nil)
        try await document.apply(layer, assets: assets)
        #expect(await document.layers.count == 1)
        let replaced = try await folder.pixels(document)
        #expect(replaced[64, 48].red < original[64, 48].red)
    }

    /// A redrawn crop whose surroundings came back 40 levels brighter than the photo, with a new colour inside
    /// the mask: the drift is taken out, the new colour stays, and only the mask shows.
    @Test
    func patchShowsThroughItsMaskWithTheGeneratorsDriftTakenOut() async throws {
        let folder = try PhotoFolder()
        defer { folder.remove() }
        let document = try PhotoDocument(contentsOf: folder.photo { _, _ in RGB(100, 120, 140) })
        let before = try await folder.pixels(document)
        let assets = AssetStore()
        // The patch covers x 32..<96, y 12..<60 of the 128 × 96 photo; its mask is its middle half.
        let inside: (Int, Int) -> Bool = { x, y in x >= 16 && x < 48 && y >= 12 && y < 36 }
        let patchURL = try folder.photo(width: 64, height: 48) { x, y in inside(x, y) ? RGB(220, 170, 120) : RGB(140, 160, 180) }
        let imageID = await assets.put(.image(EncodedImage(data: try Data(contentsOf: patchURL), format: .png, size: PixelSize(width: 64, height: 48))))
        let coverage = (0..<(64 * 48)).map { inside($0 % 64, $0 / 64) ? UInt8(255) : 0 }
        let maskID = await assets.put(.mask(MaskData(size: PixelSize(width: 64, height: 48), coverage: coverage)))
        try await document.apply(Layer(label: "Coat", content: .patch(image: imageID, mask: maskID,
                                                                       rect: NormalizedRect(x: 0.25, y: 0.125, width: 0.5, height: 0.5))), assets: assets)
        let after = try await folder.pixels(document)
        let middle = after[64, 36], generated = RGB(220, 170, 120)
        #expect(middle.red > before[64, 36].red + 0.15, "the new colour shows inside the mask")
        #expect(middle.red < generated.red - 0.03, "and is brought down by the generator's drift")
        #expect(after[40, 20].distance(to: before[40, 20]) <= 2.0 / 255, "the patch's own surroundings never show")
        #expect(after[64, 80].distance(to: before[64, 80]) <= 1.0 / 255, "outside the patch nothing changes")
    }

    /// A red sweater redrawn forest green came out brown with a red rim: SAM's mask missed the sweater's edge, so
    /// the ring the drift is measured in held red sweater in the photo and green in the redraw, and the whole patch
    /// was moved toward red. The drift is measured only where the two agree, a little outside the mask.
    @Test
    func aRecolourIsNotPulledBackTowardTheColourItReplaced() async throws {
        let folder = try PhotoFolder()
        defer { folder.remove() }
        // A red sweater at x 60..<132, y 30..<114 on a grey wall.
        let document = try PhotoDocument(contentsOf: folder.photo(width: 192, height: 144) { x, y in
            (60..<132).contains(x) && (30..<114).contains(y) ? RGB(220, 20, 30) : RGB(200, 200, 200)
        })
        let assets = AssetStore()
        // The redraw covers x 36..<156, y 12..<132: the whole sweater green, the wall as it was.
        let green = RGB(30, 110, 50)
        let patchURL = try folder.photo(width: 120, height: 120) { x, y in
            (24..<96).contains(x) && (18..<102).contains(y) ? green : RGB(200, 200, 200)
        }
        let imageID = await assets.put(.image(EncodedImage(data: try Data(contentsOf: patchURL), format: .png,
                                                          size: PixelSize(width: 120, height: 120))))
        // SAM's mask misses the sweater's outer 3 px.
        let coverage = (0..<(120 * 120)).map { (27..<93).contains($0 % 120) && (21..<99).contains($0 / 120) ? UInt8(255) : 0 }
        let maskID = await assets.put(.mask(MaskData(size: PixelSize(width: 120, height: 120), coverage: coverage)))
        try await document.apply(Layer(label: "Sweater", content: .patch(image: imageID, mask: maskID,
                                                                          rect: NormalizedRect(x: 36.0 / 192, y: 12.0 / 144,
                                                                                               width: 120.0 / 192, height: 120.0 / 144))),
                                 assets: assets)
        let after = try await folder.pixels(document)
        let middle = after[96, 72]
        #expect(middle.distance(to: green) <= 3.0 / 255, "the sweater is the green it was redrawn: \(middle.red), \(middle.green), \(middle.blue)")
        #expect(after[10, 10].distance(to: RGB(200, 200, 200)) <= 1.0 / 255)
    }

    /// A small, flat redraw enlarged over fine stripes gets the stripes back at about 70% of their contrast.
    @Test
    func anEnlargedPatchGetsThePhotosFineDetailBack() async throws {
        let folder = try PhotoFolder()
        defer { folder.remove() }
        let document = try PhotoDocument(contentsOf: folder.photo { x, _ in x % 4 < 2 ? RGB(150, 150, 150) : RGB(90, 90, 90) })
        let before = try await folder.pixels(document)
        let assets = AssetStore()
        let patchURL = try folder.photo(width: 16, height: 12) { _, _ in RGB(60, 140, 60) }
        let imageID = await assets.put(.image(EncodedImage(data: try Data(contentsOf: patchURL), format: .png, size: PixelSize(width: 16, height: 12))))
        let maskID = await assets.put(.mask(MaskData(size: PixelSize(width: 16, height: 12), filledWith: 255)))
        try await document.apply(Layer(label: "Patch", content: .patch(image: imageID, mask: maskID,
                                                                       rect: NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))), assets: assets)
        let after = try await folder.pixels(document)
        let original = abs(linear(before[64, 48].green) - linear(before[66, 48].green))
        let restored = abs(linear(after[64, 48].green) - linear(after[66, 48].green))
        #expect(restored > original * 0.45 && restored < original * 0.95, "restored \(restored) of \(original)")
        #expect(after[64, 48].green > after[64, 48].red, "still the patch's colour")
    }

    @Test
    func patchShowsOnlyThroughItsOwnMask() async throws {
        let folder = try PhotoFolder()
        defer { folder.remove() }
        let document = try PhotoDocument(contentsOf: folder.photo { _, _ in RGB(80, 80, 80) })
        let before = try await folder.pixels(document)
        let assets = AssetStore()
        let patchURL = try folder.photo(width: 64, height: 48) { _, _ in RGB(200, 180, 160) }
        let imageID = await assets.put(.image(EncodedImage(data: try Data(contentsOf: patchURL), format: .png,
                                                          size: PixelSize(width: 64, height: 48))))
        // The left half of the patch only; the patch sits over x 32..<96 of the photo.
        let coverage = (0..<(64 * 48)).map { $0 % 64 < 32 ? UInt8(255) : 0 }
        let maskID = await assets.put(.mask(MaskData(size: PixelSize(width: 64, height: 48), coverage: coverage)))
        try await document.apply(Layer(label: "Patch", content: .patch(image: imageID, mask: maskID,
                                                                       rect: NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))), assets: assets)
        let after = try await folder.pixels(document)
        #expect(after[44, 48].red > before[44, 48].red + 0.05)
        #expect(after[84, 48].distance(to: before[84, 48]) <= 1.0 / 255)
        #expect(after[10, 48].distance(to: before[10, 48]) <= 1.0 / 255)
    }

    /// On a black-and-white photo, shirts redrawn blue bled blue onto the strap and arms beside them: the redraw's
    /// colour came in through the same soft edge as its brightness.
    @Test
    func aRedrawsColourStaysInsideItsMaskWhileItsEdgeBlends() async throws {
        let folder = try PhotoFolder()
        defer { folder.remove() }
        let document = try PhotoDocument(contentsOf: folder.photo(width: 800, height: 600) { _, _ in RGB(128, 128, 128) })
        let assets = AssetStore()
        // The patch covers x 200..<600; the generator drew the blue shirt 8 px past the mask's edge at x 400.
        let patchURL = try folder.photo(width: 400, height: 300) { x, _ in x < 208 ? RGB(40, 70, 200) : RGB(128, 128, 128) }
        let imageID = await assets.put(.image(EncodedImage(data: try Data(contentsOf: patchURL), format: .png,
                                                          size: PixelSize(width: 400, height: 300))))
        let coverage = (0..<(400 * 300)).map { $0 % 400 < 200 ? UInt8(255) : 0 }
        let maskID = await assets.put(.mask(MaskData(size: PixelSize(width: 400, height: 300), coverage: coverage)))
        try await document.apply(Layer(label: "Shirt", content: .patch(image: imageID, mask: maskID,
                                                                       rect: NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))), assets: assets)
        let after = try await folder.pixels(document)
        #expect(after[380, 300].blue > after[380, 300].red + 0.3, "the shirt is blue")
        for x in [403, 406] {
            let pixel = after[x, 300]
            #expect(pixel.blue - pixel.red < 0.03, "no blue past the mask's edge at x \(x): \(pixel.red), \(pixel.blue)")
        }
    }

    /// A removed sign left a faint outline: the patch was blended in through a soft edge that reached inward from its
    /// mask, over the sign's rim. A patch's mask now carries its own edge: a removal's reaches 6% of the crop past the
    /// thing and is softened there, clear of it; one softened right at the thing lets its rim show.
    @Test(arguments: [false, true])
    func aRemovalSoftenedClearOfTheThingLeavesNoOutline(reachesPast: Bool) async throws {
        let folder = try PhotoFolder()
        defer { folder.remove() }
        // A white sign with a black rim at x and y 200..<300, on grey.
        let document = try PhotoDocument(contentsOf: folder.photo(width: 800, height: 600) { x, y in
            guard (200..<300).contains(x), (200..<300).contains(y) else { return RGB(180, 180, 180) }
            return min(x - 200, 299 - x, y - 200, 299 - y) < 4 ? RGB(0, 0, 0) : RGB(255, 255, 255)
        })
        let assets = AssetStore()
        // The generator's fill: grey where the sign was, over x and y 100..<400.
        let patchURL = try folder.photo(width: 300, height: 300) { _, _ in RGB(180, 180, 180) }
        let imageID = await assets.put(.image(EncodedImage(data: try Data(contentsOf: patchURL), format: .png,
                                                          size: PixelSize(width: 300, height: 300))))
        var sign = [UInt8](repeating: 0, count: 300 * 300)
        for y in 100..<200 { for x in 100..<200 { sign[y * 300 + x] = 255 } }
        let mask = MaskData(size: PixelSize(width: 300, height: 300), coverage: sign)
            .grown(by: reachesPast ? 18 : 4).blurred(by: 4.5)
        let maskID = await assets.put(.mask(mask))
        try await document.apply(Layer(label: "Sign: removed", content: .patch(image: imageID, mask: maskID,
                                                                               rect: NormalizedRect(x: 0.125, y: 1.0 / 6, width: 0.375, height: 0.5))),
                                 assets: assets)
        let after = try await folder.pixels(document)
        let rim = after[201, 250]
        let grey = RGB(180, 180, 180)
        if reachesPast {
            #expect(rim.distance(to: grey) < 2.0 / 255, "no trace of the rim: \(rim.red)")
            #expect(after[250, 250].distance(to: grey) < 2.0 / 255)
        } else {
            #expect(rim.red < grey.red - 0.02, "the rim shows through the soft edge: \(rim.red)")
        }
    }

    /// The compositor only smooths a mask's pixel steps: a hard mask shows the patch right up to its edge.
    @Test
    func aPatchShowsFullyUpToItsMasksEdge() async throws {
        let folder = try PhotoFolder()
        defer { folder.remove() }
        let document = try PhotoDocument(contentsOf: folder.photo(width: 800, height: 600) { _, _ in RGB(220, 20, 30) })
        let assets = AssetStore()
        // The redraw is green over its left half and keeps the photo's red beyond it, as a redraw keeps its surroundings.
        let patchURL = try folder.photo(width: 400, height: 300) { x, _ in x < 200 ? RGB(30, 110, 50) : RGB(220, 20, 30) }
        let imageID = await assets.put(.image(EncodedImage(data: try Data(contentsOf: patchURL), format: .png,
                                                          size: PixelSize(width: 400, height: 300))))
        // The left half of the patch, which covers x 200..<600: the edge is at x 400.
        let coverage = (0..<(400 * 300)).map { $0 % 400 < 200 ? UInt8(255) : 0 }
        let maskID = await assets.put(.mask(MaskData(size: PixelSize(width: 400, height: 300), coverage: coverage)))
        try await document.apply(Layer(label: "Sweater", content: .patch(image: imageID, mask: maskID,
                                                                          rect: NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))),
                                 assets: assets)
        let after = try await folder.pixels(document)
        #expect(after[396, 300].distance(to: RGB(30, 110, 50)) <= 3.0 / 255, "no red 4 px inside the edge: \(after[396, 300].red)")
        #expect(after[404, 300].distance(to: RGB(220, 20, 30)) <= 3.0 / 255)
    }

    /// The critic is told each region's colour before and after, so a change too slight to see or a colour short of
    /// the one asked for is a number, not a judgment from two small photos.
    @Test
    func measuresTheColourMostOfAMaskedRenderHas() async throws {
        let folder = try PhotoFolder()
        defer { folder.remove() }
        // The left 40% black, the rest a mid teal.
        let document = try PhotoDocument(contentsOf: folder.photo(width: 100, height: 50) { x, _ in
            x < 40 ? RGB(0, 0, 0) : RGB(40, 110, 120)
        })
        let render = try await document.render(maxLongEdge: 100)
        let left = MaskData(size: PixelSize(width: 10, height: 5), coverage: (0..<50).map { $0 % 10 < 4 ? 255 : 0 })
        let black = try #require(await document.measure(render, mask: left))
        #expect(black.lightness < 3 && black.name == "black")
        #expect(black.families == ["black": 1])
        let teal = try #require(await document.measure(render, mask: left.inverted()))
        #expect(abs(teal.lightness - 42.7) < 2 && teal.name.hasSuffix("teal"), "\(teal)")
        // Most of the photo is teal: a black part doesn't pull it toward grey, but shows in its darkest tenth.
        let whole = try #require(await document.measure(render, mask: nil))
        #expect(abs(whole.lightness - teal.lightness) < 1 && whole.name == teal.name)
        #expect(abs((whole.families?["black"] ?? 0) - 0.4) < 0.03 && abs((whole.families?["teal"] ?? 0) - 0.6) < 0.03,
                "the black part shows in the families: \(whole.families ?? [:])")
        #expect(try #require(whole.darkest) < 3 && abs(try #require(whole.brightest) - teal.lightness) < 2)
        #expect(try await document.measure(render, mask: MaskData(size: left.size, filledWith: 0)) == nil)
        // Cropped to its right half, the render shows none of the left half's mask.
        try await document.apply(Layer(label: "Photo: cropped", content: .crop(NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1))),
                                 assets: AssetStore())
        let cropped = try await document.render(maxLongEdge: 100)
        #expect(try await document.measure(cropped, mask: left) == nil)
        #expect(try await document.measure(cropped, mask: left.inverted())?.name.hasSuffix("teal") == true)
        let white = ColourMeasuring.lab(red: 255, green: 255, blue: 255)
        #expect(abs(white.lightness - 100) < 0.01 && white.chroma < 0.01)
    }

    /// A recolour's mask held to the photo: SAM's mask a few pixels off a light shirt's edge moves onto it, so the
    /// redraw neither spills onto the black backpack beside it nor misses the shirt's last pixels.
    @Test
    func aMaskIsFittedToThePhotosOwnEdges() async throws {
        let folder = try PhotoFolder()
        defer { folder.remove() }
        // A light square at x 300..<500, y 200..<400 on black.
        let document = try PhotoDocument(contentsOf: folder.photo(width: 800, height: 600) { x, y in
            x >= 300 && x < 500 && y >= 200 && y < 400 ? RGB(200, 200, 200) : RGB(10, 10, 10)
        })
        // The region x 250..<550, y 150..<450 at one mask pixel per photo pixel, where the square is x 50..<250. SAM's
        // mask sits 3 pixels to the right of it.
        let region = NormalizedRect(x: 250.0 / 800, y: 150.0 / 600, width: 300.0 / 800, height: 300.0 / 600)
        let shifted = MaskData(size: PixelSize(width: 300, height: 300), coverage: (0..<(300 * 300)).map { i in
            let x = i % 300, y = i / 300
            return x >= 53 && x < 253 && y >= 50 && y < 250 ? 255 : 0
        })
        let fitted = try await document.fitted(shifted, region: region)
        #expect(fitted[150, 150] > 240, "the square's middle")
        #expect(fitted[51, 150] > 230, "the shirt's edge SAM missed is taken in: \(fitted[51, 150])")
        #expect(fitted[251, 150] < 20 && fitted[256, 150] == 0, "the black SAM took is let go: \(fitted[251, 150])")
        #expect(fitted[48, 150] == 0, "and nothing past the shirt on the other side")
    }

    /// Golden-hour light is warm highlights over shadows a little less warm: each tonal range is warmed on its own.
    @Test
    func highlightAndShadowWarmthWarmTheirOwnTones() async throws {
        let folder = try PhotoFolder()
        defer { folder.remove() }
        // Dark grey on the left, light grey on the right.
        func photo() throws -> PhotoDocument {
            try PhotoDocument(contentsOf: folder.photo { x, _ in x < 64 ? RGB(40, 40, 40) : RGB(220, 220, 220) })
        }
        func warmth(_ pixel: RGB) -> Double { pixel.red - pixel.blue }
        let highlights = try photo()
        try await highlights.apply(Layer(label: "Grade", content: .adjustment(values: [.highlightWarmth: 60], mask: nil)), assets: AssetStore())
        let h = try await folder.pixels(highlights)
        #expect(warmth(h[100, 48]) > 0.08, "the light grey is gold: \(warmth(h[100, 48]))")
        #expect(abs(warmth(h[20, 48])) < 0.01, "the dark grey is left: \(warmth(h[20, 48]))")
        let shadows = try photo()
        try await shadows.apply(Layer(label: "Grade", content: .adjustment(values: [.shadowWarmth: -60], mask: nil)), assets: AssetStore())
        let s = try await folder.pixels(shadows)
        #expect(warmth(s[20, 48]) < -0.02, "the dark grey is cooled: \(warmth(s[20, 48]))")
        #expect(abs(warmth(s[100, 48])) < 0.01, "the light grey is left: \(warmth(s[100, 48]))")
        #expect(AdjustmentKey.highlightWarmth.title == "highlight warmth" && AdjustmentKey.noiseReduction.title == "noise reduction")
    }

    @Test(arguments: [AdjustmentKey.highlights, .shadows, .whites, .blacks])
    func positiveTonalSettingsLiftTheirRange(key: AdjustmentKey) async throws {
        let folder = try PhotoFolder()
        defer { folder.remove() }
        let document = try PhotoDocument(contentsOf: folder.photo { x, _ in
            x < 64 ? RGB(60, 60, 60) : RGB(210, 210, 210)
        })
        let original = try await folder.pixels(document)
        var layer = Layer(label: "Tone", content: .adjustment(values: [key: 50], mask: nil))
        try await document.apply(layer, assets: AssetStore())
        let lifted = try await folder.pixels(document)
        layer.content = .adjustment(values: [key: -50], mask: nil)
        try await document.apply(layer, assets: AssetStore())
        let lowered = try await folder.pixels(document)
        let x = key == .shadows || key == .blacks ? 30 : 100
        #expect(lifted[x, 48].red > original[x, 48].red + 0.01)
        #expect(lowered[x, 48].red < original[x, 48].red - 0.01)
    }

    @Test
    func lastEnabledCropWinsWithoutChangingOriginalSize() async throws {
        let folder = try PhotoFolder()
        defer { folder.remove() }
        let document = try PhotoDocument(contentsOf: folder.photo { _, _ in RGB(100, 120, 140) })
        let first = Layer(label: "First crop", content: .crop(NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5)))
        let second = Layer(label: "Second crop", content: .crop(NormalizedRect(x: 0.25, y: 0, width: 0.75, height: 1)))
        try await document.apply(first, assets: AssetStore())
        try await document.apply(second, assets: AssetStore())
        #expect(try await document.render(maxLongEdge: 1000).size == PixelSize(width: 96, height: 96))
        #expect(await document.size() == PixelSize(width: 128, height: 96))
        await document.setEnabled(false, for: second.id)
        #expect(try await document.render(maxLongEdge: 1000).size == PixelSize(width: 64, height: 48))
        await document.setOpacity(0, for: first.id)
        #expect(try await document.render(maxLongEdge: 1000).size == PixelSize(width: 128, height: 96))
    }

    @Test
    func regionUsesFullResolutionAndTopLeftCoordinates() async throws {
        let folder = try PhotoFolder()
        defer { folder.remove() }
        let document = try PhotoDocument(contentsOf: folder.photo(width: 320, height: 240) { x, y in
            x < 160 && y < 120 ? RGB(200, 60, 30) : RGB(30, 60, 200)
        })
        #expect(try await document.render(maxLongEdge: 80).size == PixelSize(width: 80, height: 60))
        let region = NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5)
        let full = try await document.render(region: region, maxLongEdge: 1000)
        #expect(full.size == PixelSize(width: 160, height: 120))
        #expect(try Pixels(data: full.data)[80, 60].red > 0.7)
        let capped = try await document.render(region: region, maxLongEdge: 80)
        #expect(capped.size == PixelSize(width: 80, height: 60))
        try await document.apply(Layer(label: "Light", content: .adjustment(values: [.exposure: -1], mask: nil)), assets: AssetStore())
        let adjusted = try await document.render(region: region, maxLongEdge: 1000)
        #expect(try Pixels(data: adjusted.data)[80, 60].red < Pixels(data: full.data)[80, 60].red - 0.1)
        try await document.apply(Layer(label: "Crop", content: .crop(region)), assets: AssetStore())
        let croppedRegion = try await document.render(region: NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1), maxLongEdge: 1000)
        #expect(croppedRegion.size == PixelSize(width: 80, height: 120))
        #expect(try Pixels(data: croppedRegion.data)[40, 60].red > 0.5)
    }

    @Test(arguments: [EncodedImage.Format.jpeg, .png])
    func exportReopensInSourceColorSpaceWithAppliedOrientation(format: EncodedImage.Format) async throws {
        let folder = try PhotoFolder()
        defer { folder.remove() }
        let url = try folder.photo(width: 80, height: 48, orientation: 6,
                                   colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!) { _, _ in RGB(180, 80, 40) }
        let document = try PhotoDocument(contentsOf: url)
        try await document.apply(Layer(label: "Crop", content: .crop(NormalizedRect(x: 0, y: 0, width: 1, height: 0.5))), assets: AssetStore())
        let destination = folder.url.appendingPathComponent("export.\(format.rawValue)")
        try await document.export(to: destination, format: format)
        let reopened = try PhotoDocument(contentsOf: destination)
        #expect(await reopened.size() == PixelSize(width: 48, height: 40))
        let source = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.colorSpace?.name == CGColorSpace.displayP3)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        #expect((properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1 == 1)
    }

    /// A black-and-white photo whose shirts were redrawn blue came out grey: the export kept the source's grey space.
    @Test func aGreyscalePhotoGivenColourIsExportedInColourAndOtherwiseStaysGrey() async throws {
        let folder = try PhotoFolder()
        defer { folder.remove() }
        let grey = try #require(CGColorSpace(name: CGColorSpace.genericGrayGamma2_2))
        let context = try #require(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 64, space: grey,
                                             bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let source = folder.url.appendingPathComponent("grey.jpg")
        let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        func model(_ url: URL) throws -> CGColorSpaceModel? {
            let image = try #require(CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            return image.colorSpace?.model
        }

        let document = try PhotoDocument(contentsOf: source)
        try await document.apply(Layer(label: "Light", content: .adjustment(values: [.exposure: 0.5], mask: nil)), assets: AssetStore())
        let tonal = folder.url.appendingPathComponent("tonal.jpg")
        try await document.export(to: tonal, format: .jpeg)
        #expect(try model(tonal) == .monochrome, "a tonal edit keeps it greyscale")
        try await document.apply(Layer(label: "Warm", content: .adjustment(values: [.temperature: 60], mask: nil)), assets: AssetStore())
        let warm = folder.url.appendingPathComponent("warm.jpg")
        try await document.export(to: warm, format: .jpeg)
        #expect(try model(warm) == .rgb)
        let pixel = try Pixels(data: Data(contentsOf: warm))[32, 24]
        #expect(pixel.red > pixel.blue + 0.05, "the warmth is kept: \(pixel.red) vs \(pixel.blue)")
    }

    /// "Make the sunset more vivid" left a flat orange patch: saturation +30 in linear light took the glow's blue from
    /// 79 to 8, and with contrast below zero. On encoded values, by shares of the lightness, it moves gently and never
    /// passes zero.
    @Test
    func saturationMovesColourAsTheEyeSeesItAndNeverPastZero() async throws {
        let folder = try PhotoFolder()
        defer { folder.remove() }
        let document = try PhotoDocument(contentsOf: folder.photo { x, _ in x < 64 ? RGB(222, 133, 79) : RGB(240, 120, 12) })
        let before = try await folder.pixels(document)
        for (value, check) in [(30.0, "more"), (100, "most"), (-100, "grey"), (0, "same")] {
            let layer = Layer(label: "Saturation", content: .adjustment(values: [.saturation: value], mask: nil))
            try await document.apply(layer, assets: AssetStore())
            let after = try await folder.pixels(document)
            let glow = after[20, 40], deep = after[100, 40]
            switch check {
            case "more":
                #expect(glow.red > before[20, 40].red && glow.blue < before[20, 40].blue)
                #expect(glow.blue > 0.2, "the glow's blue eases from 0.31, not to nothing: \(glow.blue)")
                #expect(deep.blue > 0, "an orange already near the edge keeps some blue: \(deep.blue)")
            case "most":
                #expect(glow.blue > 0.05 && deep.blue > 0)
            case "grey":
                #expect(abs(glow.red - glow.blue) < 2.0 / 255 && abs(glow.green - glow.blue) < 2.0 / 255)
            default:
                #expect(glow.distance(to: before[20, 40]) <= 2.0 / 255)
            }
            try await document.remove(layer.id)
        }
    }

    /// "Bring out the city lights" left a dark rim round a lit spire: clarity was an unsharp mask in linear light, which
    /// pushed the night sky beside the spire below black. Against an edge-preserving base, the sky beside a strong edge
    /// keeps its value while fine texture still gains contrast.
    @Test
    func clarityLiftsTextureWithoutARimBesideABrightEdge() async throws {
        let folder = try PhotoFolder()
        defer { folder.remove() }
        // A night sky with a lit tower at x 290..<310; on the right, faint stripes. Clarity's radius here is 6 px.
        let document = try PhotoDocument(contentsOf: folder.photo(width: 600, height: 300) { x, _ in
            if (290..<310).contains(x) { return RGB(255, 200, 80) }
            if x >= 420 { return x % 4 < 2 ? RGB(120, 120, 120) : RGB(140, 140, 140) }
            return RGB(10, 12, 20)
        })
        let before = try await folder.pixels(document)
        let layer = Layer(label: "Clarity", content: .adjustment(values: [.clarity: 60], mask: nil))
        try await document.apply(layer, assets: AssetStore())
        let after = try await folder.pixels(document)
        // At 60, a guided filter leaves at most a few levels' dip right beside so strong an edge; the old unsharp mask
        // took this sky to black (20 to below 0).
        for x in [278, 282, 286, 313, 317, 321] {
            #expect(after[x, 150].blue >= before[x, 150].blue - 5.0 / 255, "no dark rim at x \(x): \(after[x, 150].blue)")
        }
        let was = before[502, 150].red - before[501, 150].red
        let now = after[502, 150].red - after[501, 150].red
        #expect(abs(now) > abs(was) * 1.3, "the stripes gain contrast: \(was) → \(now)")
    }

    /// A smeared headlight kept its colour but lost its fine detail; the critic missed it two times in three from the
    /// close-up alone. A recolour keeps its detail, so only the smear is named.
    @Test
    func aSmearIsFoundWhereARecolourIsNot() async throws {
        let folder = try PhotoFolder()
        defer { folder.remove() }
        func texture(_ x: Int, _ y: Int) -> UInt8 { UInt8(90 + (x * 7 + y * 13) % 5 * 18) }
        let before = try folder.photo(width: 200, height: 200) { x, y in RGB(texture(x, y), texture(x, y), 200) }
        // Recoloured: the same texture in red.
        let recoloured = try folder.photo(width: 200, height: 200) { x, y in RGB(200, texture(x, y), texture(x, y) / 2) }
        // Smeared: a 30 px patch at x and y 120..<150 flattened to its mean.
        let smeared = try folder.photo(width: 200, height: 200) { x, y in
            (120..<150).contains(x) && (120..<150).contains(y) ? RGB(126, 126, 200) : RGB(texture(x, y), texture(x, y), 200)
        }
        func image(_ url: URL) throws -> EncodedImage {
            EncodedImage(data: try Data(contentsOf: url), format: .png, size: PixelSize(width: 200, height: 200))
        }
        let document = try PhotoDocument(contentsOf: before)
        #expect(try await document.lostDetail(before: image(before), after: image(recoloured)).isEmpty)
        let lost = try await document.lostDetail(before: image(before), after: image(smeared))
        let place = try #require(lost.first)
        #expect(lost.count == 1 && place.kept < 0.1)
        #expect(place.rect.x <= 0.6 && place.rect.x + place.rect.width >= 0.75, "\(place.rect)")
        #expect(place.rect.y <= 0.6 && place.rect.y + place.rect.height >= 0.75, "\(place.rect)")
    }

    @Test(arguments: AdjustmentKey.allCases)
    func everyAdjustmentRenders(key: AdjustmentKey) async throws {
        let folder = try PhotoFolder()
        defer { folder.remove() }
        let document = try PhotoDocument(contentsOf: folder.photo { x, y in RGB(UInt8(40 + x), UInt8(60 + y), 90) })
        for value in [key.range.lowerBound, 0, key.range.upperBound] {
            let layer = Layer(label: key.rawValue, content: .adjustment(values: [key: value], mask: nil))
            try await document.apply(layer, assets: AssetStore())
            let rendered = try await document.render(maxLongEdge: 64)
            #expect(rendered.size == PixelSize(width: 64, height: 48))
            #expect(try Pixels(data: rendered.data).width == 64)
            try await document.remove(layer.id)
        }
    }
}

@Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8], [UTType.png, .jpeg])
func loadingUsesOrientedDimensions(orientation: Int, type: UTType) async throws {
    let folder = try PhotoFolder()
    defer { folder.remove() }
    let url = try folder.photo(width: 80, height: 48, type: type, orientation: orientation) { _, _ in RGB(100, 120, 140) }
    let document = try PhotoDocument(contentsOf: url)
    let size = orientation >= 5 ? PixelSize(width: 48, height: 80) : PixelSize(width: 80, height: 48)
    #expect(await document.size() == size)
}

@Test
func layerStateKeepsOrderAndClampsOpacity() async throws {
    let folder = try PhotoFolder()
    defer { folder.remove() }
    let document = try PhotoDocument(contentsOf: folder.photo { _, _ in RGB(100, 120, 140) })
    let assets = AssetStore()
    let maskID = await assets.put(.mask(MaskData(size: PixelSize(width: 4, height: 3), filledWith: 255)))
    var first = Layer(label: "Light", content: .adjustment(values: [.exposure: 1], mask: maskID))
    let second = Layer(label: "Crop", content: .crop(.whole), opacity: 2)
    try await document.apply(first, assets: assets)
    try await document.apply(second, assets: assets)
    await assets.remove(maskID)
    await document.setEnabled(false, for: first.id)
    await document.setOpacity(-1, for: first.id)
    var layers = await document.layers
    #expect(layers.map(\.id) == [first.id, second.id])
    #expect(layers[0].isEnabled == false)
    #expect(layers[0].opacity == 0)
    #expect(layers[1].opacity == 1)
    first.label = "Updated light"
    first.content = .adjustment(values: [.exposure: -1], mask: nil)
    try await document.apply(first, assets: assets)
    layers = await document.layers
    #expect(layers.count == 2)
    #expect(layers[0].label == "Updated light")
    await document.setOpacity(.nan, for: first.id)
    #expect(await document.layers[0].opacity == 0)
    try await document.remove(first.id)
    try await document.remove(first.id)
    #expect(await document.layers.map(\.id) == [second.id])
}

@Test
func missingAndUnreadablePhotosFail() throws {
    let folder = try PhotoFolder()
    defer { folder.remove() }
    #expect(throws: LumenError.self) { try PhotoDocument(contentsOf: folder.url.appendingPathComponent("missing.png")) }
    let url = folder.url.appendingPathComponent("broken.png")
    try Data("not a photo".utf8).write(to: url)
    #expect(throws: LumenError.self) { try PhotoDocument(contentsOf: url) }
}

@Test
func invalidAssetsAndRegionsDoNotChangeTheStack() async throws {
    let folder = try PhotoFolder()
    defer { folder.remove() }
    let document = try PhotoDocument(contentsOf: folder.photo { _, _ in RGB(90, 90, 90) })
    let layer = Layer(label: "Missing", content: .adjustment(values: [.exposure: 1], mask: AssetID()))
    await #expect(throws: LumenError.self) { try await document.apply(layer, assets: AssetStore()) }
    #expect(await document.layers.isEmpty)
    await #expect(throws: LumenError.self) { try await document.render(maxLongEdge: 0) }
    await #expect(throws: LumenError.self) {
        try await document.render(region: NormalizedRect(x: 2, y: 0, width: 1, height: 1), maxLongEdge: 128)
    }
    await #expect(throws: LumenError.self) {
        try await document.render(region: NormalizedRect(x: .nan, y: 0, width: 1, height: 1), maxLongEdge: 128)
    }
    await #expect(throws: LumenError.self) {
        try await document.apply(Layer(label: "Empty crop", content: .crop(NormalizedRect(x: 0, y: 0, width: 0, height: 1))), assets: AssetStore())
    }
    #expect(await document.layers.isEmpty)
}

private enum Rendering {
    static let isAvailable: Bool = {
        let image = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        return CIContext().createCGImage(image, from: image.extent) != nil
    }()
}

private struct PhotoFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }

    func photo(width: Int = 128, height: Int = 96, type: UTType = .png, orientation: Int = 1,
               colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!,
               pixel: (Int, Int) -> RGB) throws -> URL {
        var bytes = [UInt8]()
        for y in 0..<height {
            for x in 0..<width {
                let value = pixel(x, y)
                bytes.append(contentsOf: [UInt8((value.red * 255).rounded()), UInt8((value.green * 255).rounded()),
                                          UInt8((value.blue * 255).rounded()), 255])
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                        bytesPerRow: width * 4, space: colorSpace,
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destinationURL = url.appendingPathComponent(UUID().uuidString).appendingPathExtension(type.preferredFilenameExtension ?? "png")
        let destination = try #require(CGImageDestinationCreateWithURL(destinationURL as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation,
                                                       kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return destinationURL
    }

    func pixels(_ document: PhotoDocument) async throws -> Pixels {
        let destination = url.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        try await document.export(to: destination, format: .png)
        return try Pixels(data: Data(contentsOf: destination))
    }
}

private struct RGB {
    var red: Double
    var green: Double
    var blue: Double

    init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
        self.red = Double(red) / 255
        self.green = Double(green) / 255
        self.blue = Double(blue) / 255
    }

    func distance(to other: RGB) -> Double {
        max(abs(red - other.red), abs(green - other.green), abs(blue - other.blue))
    }
}

private struct Pixels {
    var width: Int
    var height: Int
    var bytes: [UInt8]

    init(data: Data) throws {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        width = image.width
        height = image.height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
        let width = width
        let height = height
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: width, height: height,
                                                 bitsPerComponent: 8, bytesPerRow: width * 4,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    subscript(x: Int, y: Int) -> RGB {
        let index = (y * width + x) * 4
        return RGB(bytes[index], bytes[index + 1], bytes[index + 2])
    }
}

private func linear(_ value: Double) -> Double {
    value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
}

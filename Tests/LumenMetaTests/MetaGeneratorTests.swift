import Foundation
import ImageIO
import LumenCore
import Testing
import UniformTypeIdentifiers
@testable import LumenMeta

@Test func generatorSendsPNGWithoutMaskAndResizesAnswer() async throws {
    let transport = ReplayTransport([try .init(file: "image.json")])
    let generator = MetaGenerator(configuration: testConfiguration, transport: transport)
    let source = try recordedPhoto()
    let size = PixelSize(width: 6, height: 4)
    let photo = try PhotoPNG.encode(source.data, size: size)
    let generated = try await generator.generate(GenerateRequest(image: photo, mask: MaskData(size: size, filledWith: 255), prompt: "Navy wool coat"))
    #expect(generated.format == .png)
    #expect(generated.size == size)
    #expect(generated.data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]))
    let decoded = try #require(CGImageSourceCreateWithData(generated.data as CFData, nil))
    let pixels = try #require(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
    #expect(pixels.width == 6)
    #expect(pixels.height == 4)
    let call = try #require(await transport.requests.first)
    #expect(call.url?.absoluteString == "https://models.example/v1/images/edits")
    #expect(call.httpMethod == "POST")
    #expect(call.timeoutInterval == 180)
    // Muse Image keeps a small crop's layout better at its own scale, so the crop is sent at a 1024 px long edge.
    let sent = try PhotoPNG.encode(photo.data, size: PixelSize(width: 1024, height: 683))
    try expectJSON(#require(call.httpBody), equals: [
        "model": "muse-image-1.0", "prompt": "Navy wool coat", "images": [["image_url": sent.dataURL]],
        "n": 1, "output_format": "png", "response_format": "b64_json",
    ])
}

@Test func generatorReadsSameSizeAnswerAndCustomTimeout() async throws {
    let photo = try recordedPhoto()
    var configuration = testConfiguration
    configuration.timeout = 240
    let transport = ReplayTransport([try .init(file: "image.json")])
    let generated = try await MetaGenerator(configuration: configuration, transport: transport).generate(
        GenerateRequest(image: photo, mask: MaskData(size: photo.size, filledWith: 0), prompt: "Red coat"))
    #expect(generated.size == photo.size)
    #expect(generated.data == photo.data)
    #expect(await transport.requests.first?.timeoutInterval == 240)
}

@Test func generatorConvertsOrientedJPEGToPNG() async throws {
    let photo = try recordedPhoto()
    let source = try #require(CGImageSourceCreateWithData(photo.data as CFData, nil))
    let pixels = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let jpeg = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, pixels, [kCGImagePropertyOrientation: 6] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    let size = PixelSize(width: 1, height: 2)
    let oriented = EncodedImage(data: jpeg as Data, format: .jpeg, size: size)
    let transport = ReplayTransport([try .init(file: "image.json")])
    let generator = MetaGenerator(configuration: testConfiguration, transport: transport)
    let generated = try await generator.generate(GenerateRequest(image: oriented, mask: MaskData(size: size, filledWith: 255), prompt: "Edit"))
    #expect(generated.size == size)
    let call = try #require(await transport.requests.first)
    let body = try #require(call.httpBody)
    let images = try #require(json(body)["images"] as? [[String: String]])
    let url = try #require(images.first?["image_url"])
    #expect(url.hasPrefix("data:image/png;base64,"))
    let data = try #require(Data(base64Encoded: String(url.dropFirst("data:image/png;base64,".count))))
    let png = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let sent = try #require(CGImageSourceCreateImageAtIndex(png, 0, nil))
    #expect(sent.width == 512)
    #expect(sent.height == 1024)
}

/// Given a crop 1335 × 2048, Muse Image scaled it to fill 1280 × 1984 and cut the extra off the sides; stretched back,
/// its content came out too wide around the middle. An answer cut to its own shape goes back as it was fitted.
@Test func anAnswerCutToMuseImagesOwnShapeGoesBackWhereItWas() async throws {
    // A 200 × 100 crop with dark lines at x 50 and 150; the answer is it cut to 180 × 100 (x 10..<190), as Muse Image fits.
    func png(width: Int, height: Int, dark: (Int) -> Bool) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let v: UInt8 = dark(x) ? 10 : 230
            bytes[(y * width + x) * 4 ..< (y * width + x) * 4 + 4] = [v, v, v, 255]
        } }
        let context = try #require(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }
    let crop = EncodedImage(data: try png(width: 200, height: 100) { $0 == 50 || $0 == 150 }, format: .png, size: PixelSize(width: 200, height: 100))
    let answer = try png(width: 180, height: 100) { $0 == 40 || $0 == 140 }
    let placed = try PhotoPNG.placed(answer, over: crop)
    let source = try #require(CGImageSourceCreateWithData(placed.data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    var bytes = [UInt8](repeating: 0, count: 200 * 100 * 4)
    let context = try #require(CGContext(data: &bytes, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 800,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: 200, height: 100))
    func darkest(_ columns: Range<Int>) -> Int { columns.min { bytes[(50 * 200 + $0) * 4] < bytes[(50 * 200 + $1) * 4] }! }
    #expect(darkest(30..<70) == 50 && darkest(130..<170) == 150, "the lines where the crop had them, not stretched outward")
    #expect(bytes[(50 * 200 + 3) * 4] > 200, "the strip the answer cut off is the crop's")
}

@Test func generatorRejectsMalformedAnswers() async throws {
    let photo = try recordedPhoto()
    for answer in [#"{"data":[]}"#, #"{"data":[{"b64_json":"?"}]}"#, #"{"data":[{"b64_json":"AQID"}]}"#, "broken"] {
        let generator = MetaGenerator(configuration: testConfiguration, transport: ReplayTransport([.init(text: answer)]))
        await #expect(throws: LumenError.self) {
            try await generator.generate(GenerateRequest(image: photo, mask: MaskData(size: photo.size, filledWith: 255), prompt: "Edit"))
        }
    }
}

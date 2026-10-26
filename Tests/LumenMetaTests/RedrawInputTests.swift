import Foundation
import ImageIO
import LumenCore
import Testing
@testable import LumenMeta

@Test(arguments: [PixelSize(width: 200, height: 150), PixelSize(width: 150, height: 200),
                  PixelSize(width: 1024, height: 768), PixelSize(width: 1200, height: 900)])
func redrawInputKeepsItsAspectAndHasEnoughPixels(size: PixelSize) async throws {
    let photo = try PhotoPNG.encode(recordedPhoto().data, size: size)
    let transport = ReplayTransport([try .init(file: "image.json")])
    let generator = MetaGenerator(configuration: testConfiguration, transport: transport)
    let result = try await generator.generate(GenerateRequest(image: photo, mask: MaskData(size: size, filledWith: 255),
                                                              prompt: "A matte black cup, keeping its shape"))
    let call = try #require(await transport.requests.first)
    let body = try json(#require(call.httpBody))
    let images = try #require(body["images"] as? [[String: String]])
    let url = try #require(images.first?["image_url"])
    let sentData = try #require(Data(base64Encoded: String(url.dropFirst("data:image/png;base64,".count))))
    let sentSource = try #require(CGImageSourceCreateWithData(sentData as CFData, nil))
    let sent = try #require(CGImageSourceCreateImageAtIndex(sentSource, 0, nil))
    #expect(max(sent.width, sent.height) == max(1024, size.longEdge))
    #expect(sent.width * size.height == sent.height * size.width)
    #expect(body["mask"] == nil)
    let resultSource = try #require(CGImageSourceCreateWithData(result.data as CFData, nil))
    let pixels = try #require(CGImageSourceCreateImageAtIndex(resultSource, 0, nil))
    #expect(result.size == size)
    #expect(pixels.width == size.width && pixels.height == size.height)
}


import CoreGraphics
import Foundation
import ImageIO
import LumenCore
import UniformTypeIdentifiers

/// Muse Image takes no mask; the renderer composites the returned crop through the region's mask.
public struct MetaGenerator: Generator {
    public let configuration: MetaConfiguration
    public let transport: any MetaTransport
    public var modelID: String { configuration.imageModel }

    public init(configuration: MetaConfiguration, transport: any MetaTransport = URLSessionMetaTransport()) {
        self.configuration = configuration
        self.transport = transport
    }

    public func generate(_ request: GenerateRequest) async throws -> EncodedImage {
        do {
            let png = try PhotoPNG.encode(request.image.data, size: request.image.size)
            let call = try MetaHTTP.request(baseURL: configuration.baseURL, path: "images/edits", key: configuration.apiKey,
                                            timeout: configuration.timeout, body: [
                "model": modelID, "prompt": request.prompt, "images": [["image_url": png.dataURL]],
                "n": 1, "output_format": "png", "response_format": "b64_json",
            ])
            let (data, response) = try await transport.data(for: call)
            try Task.checkCancellation()
            try MetaHTTP.validate(response, data: data)
            let answer: Answer
            do { answer = try JSONDecoder().decode(Answer.self, from: data) }
            catch { throw MetaHTTP.invalid(String(decoding: data, as: UTF8.self)) }
            guard let base64 = answer.data.first?.b64_json, let image = Data(base64Encoded: base64) else {
                throw MetaHTTP.invalid("No valid image in data[0].b64_json.")
            }
            return try PhotoPNG.encode(image, size: request.image.size)
        } catch { throw MetaHTTP.error(error) }
    }

    private struct Answer: Decodable {
        struct Image: Decodable { var b64_json: String }
        var data: [Image]
    }
}

enum PhotoPNG {
    static func encode(_ data: Data, size: PixelSize) throws -> EncodedImage {
        guard size.width > 0, size.height > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw MetaHTTP.invalid("Could not decode the photo.")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1
        if orientation == 1, decoded.width == size.width, decoded.height == size.height,
           data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) {
            return EncodedImage(data: data, format: .png, size: size)
        }
        let photo: CGImage
        if orientation == 1 {
            photo = decoded
        } else {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                          kCGImageSourceCreateThumbnailWithTransform: true,
                                          kCGImageSourceThumbnailMaxPixelSize: max(decoded.width, decoded.height)]
            guard let oriented = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw MetaHTTP.invalid("Could not orient the photo.")
            }
            photo = oriented
        }
        guard let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw MetaHTTP.invalid("Could not resize the photo.")
        }
        context.interpolationQuality = .high
        context.draw(photo, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        let output = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw MetaHTTP.invalid("Could not encode the photo as PNG.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw MetaHTTP.invalid("Could not finish the PNG.") }
        return EncodedImage(data: output as Data, format: .png, size: size)
    }
}

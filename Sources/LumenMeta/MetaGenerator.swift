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

    public init(configuration: MetaConfiguration, transport: any MetaTransport = RetryingMetaTransport()) {
        self.configuration = configuration
        self.transport = transport
    }

    public func generate(_ request: GenerateRequest) async throws -> EncodedImage {
        do {
            ModelUsageReporting.report?(ModelUsage(cost: configuration.recordsCost ? MetaPricing.cost(model: modelID, images: 0) : nil))
            var inputSize = request.image.size
            if inputSize.width > 0, inputSize.height > 0, inputSize.longEdge < 1024 {
                let scale = 1024.0 / Double(inputSize.longEdge)
                inputSize = PixelSize(width: max(1, Int((Double(inputSize.width) * scale).rounded())),
                                      height: max(1, Int((Double(inputSize.height) * scale).rounded())))
            }
            let png = try PhotoPNG.encode(request.image.data, size: inputSize)
            let call = try MetaHTTP.request(baseURL: configuration.baseURL, path: "images/edits", key: configuration.apiKey,
                                            timeout: configuration.timeout, body: [
                "model": modelID, "prompt": request.prompt, "images": [["image_url": png.dataURL]],
                "n": 1, "output_format": "png", "response_format": "b64_json",
            ])
            let (data, response) = try await transport.data(for: call)
            try MetaHTTP.validate(response, data: data)
            let answer: Answer
            do { answer = try JSONDecoder().decode(Answer.self, from: data) }
            catch { throw MetaHTTP.invalid(String(decoding: data, as: UTF8.self)) }
            var usage = ModelUsage(cost: configuration.recordsCost ? MetaPricing.cost(model: modelID, images: 0) : nil,
                                   inputTokens: answer.usage?.input_tokens, outputTokens: answer.usage?.output_tokens)
            ModelUsageReporting.report?(usage)
            guard let base64 = answer.data.first?.b64_json, let image = Data(base64Encoded: base64) else {
                throw MetaHTTP.invalid("No valid image in data[0].b64_json.")
            }
            let photo = try PhotoPNG.placed(image, over: request.image)
            usage.cost = configuration.recordsCost ? MetaPricing.cost(model: modelID, images: answer.data.count) : nil
            ModelUsageReporting.report?(usage)
            return photo
        } catch { throw MetaHTTP.error(error) }
    }

    private struct Answer: Decodable {
        struct Image: Decodable { var b64_json: String }
        struct Usage: Decodable { var input_tokens: Int; var output_tokens: Int }
        var data: [Image]
        var usage: Usage?
    }
}

enum PhotoPNG {
    /// Muse Image's `answer` put back over the crop it was given. It answers at sizes of its own: given a crop 1335 ×
    /// 2048, it scaled it to fill 1280 × 1984 and cut the 13 px it had too many off the sides. Stretched back to the
    /// crop's shape, its content came out 0.8% too wide around the middle, and a body redrawn in it sat 15 to 20 px in
    /// from where it was. The answer is scaled back as it was fitted, centred, and the strips it cut off are the crop's.
    static func placed(_ answer: Data, over original: EncodedImage) throws -> EncodedImage {
        let size = original.size
        guard size.width > 0, size.height > 0,
              let source = CGImageSourceCreateWithData(answer as CFData, nil),
              let drawn = CGImageSourceCreateImageAtIndex(source, 0, nil), drawn.width > 0, drawn.height > 0 else {
            throw MetaHTTP.invalid("Could not decode the photo.")
        }
        let scale = max(Double(drawn.width) / Double(size.width), Double(drawn.height) / Double(size.height))
        let width = Double(drawn.width) / scale, height = Double(drawn.height) / scale
        // The same shape, near enough: a plain resize.
        if Double(size.width) - width < 0.5, Double(size.height) - height < 0.5 { return try encode(answer, size: size) }
        let crop = try encode(original.data, size: size)
        guard let base = CGImageSourceCreateWithData(crop.data as CFData, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }),
              let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw MetaHTTP.invalid("Could not place the answer.")
        }
        context.interpolationQuality = .high
        context.draw(base, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        context.draw(drawn, in: CGRect(x: (Double(size.width) - width) / 2, y: (Double(size.height) - height) / 2,
                                       width: width, height: height))
        let output = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw MetaHTTP.invalid("Could not encode the photo as PNG.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw MetaHTTP.invalid("Could not finish the PNG.") }
        return EncodedImage(data: output as Data, format: .png, size: size)
    }

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

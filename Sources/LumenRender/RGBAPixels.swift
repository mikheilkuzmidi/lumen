import CoreGraphics
import Foundation
import ImageIO
import LumenCore
import UniformTypeIdentifiers

/// An encoded image as 8-bit sRGB RGBA bytes, rows from the top, for work done pixel by pixel.
struct RGBAPixels {
    var width: Int
    var height: Int
    var bytes: [UInt8]

    init(width: Int, height: Int, bytes: [UInt8]) {
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    init(_ image: EncodedImage) throws {
        guard let source = CGImageSourceCreateWithData(image.data as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw LumenError.invalidResponse("The image could not be read.")
        }
        width = decoded.width
        height = decoded.height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
        let (width, height) = (width, height)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: Self.space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw LumenError.invalidResponse("The image could not be sampled.")
            }
            context.draw(decoded, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// The pixels as a PNG.
    func encoded() throws -> EncodedImage {
        var bytes = bytes
        let (width, height) = (width, height)
        let data = try bytes.withUnsafeMutableBytes { buffer -> Data in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: Self.space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let image = context.makeImage() else {
                throw LumenError.invalidResponse("The image could not be made.")
            }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
                throw LumenError.invalidResponse("The image could not be encoded.")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw LumenError.invalidResponse("The image could not be encoded.") }
            return data as Data
        }
        return EncodedImage(data: data, format: .png, size: PixelSize(width: width, height: height))
    }

    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!
}

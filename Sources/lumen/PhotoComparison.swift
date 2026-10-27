import CoreGraphics
import Foundation
import ImageIO
import LumenCore
import UniformTypeIdentifiers

enum PhotoComparison {
    /// Writes the original on the left and the result on the right, without cropping either.
    static func write(before: URL, after: URL, to url: URL) async throws {
        let left = try thumbnail(before)
        let right = try thumbnail(after)
        let leftHeight: Double = 800 * Double(left.height) / Double(left.width)
        let rightHeight: Double = 800 * Double(right.height) / Double(right.width)
        let height = max(1, Int(max(leftHeight, rightHeight).rounded()))
        guard let context = CGContext(data: nil, width: 1600, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw CLIError("The comparison image could not be created.")
        }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1600, height: height))
        context.interpolationQuality = CGInterpolationQuality.high
        for (image, x) in [(left, 0.0), (right, 800.0)] {
            let scale = min(800 / Double(image.width), Double(height) / Double(image.height))
            let width = Double(image.width) * scale
            let imageHeight = Double(image.height) * scale
            context.draw(image, in: CGRect(x: x + (800 - width) / 2, y: (Double(height) - imageHeight) / 2,
                                          width: width, height: imageHeight))
        }
        let data = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CLIError("The comparison image could not be encoded.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CLIError("The comparison image could not be written.") }
        try (data as Data).write(to: url, options: .atomic)
    }

    private static func thumbnail(_ url: URL) throws -> CGImage {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: 800]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw CLIError("A comparison photo could not be opened.")
        }
        return image
    }
}

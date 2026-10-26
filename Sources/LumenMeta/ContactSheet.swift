import CoreGraphics
import CoreText
import Foundation
import ImageIO
import LumenCore
import UniformTypeIdentifiers

/// A numbered grid that lets the reviewer compare photos together.
enum ContactSheet {
    static func make(_ photos: [ReviewPhoto]) throws -> EncodedImage {
        guard (1...20).contains(photos.count) else {
            throw MetaHTTP.invalid("A contact sheet needs 1 through 20 photos.")
        }
        let columns = 5
        let cell = 256
        let size = PixelSize(width: columns * cell, height: ((photos.count + columns - 1) / columns) * cell)
        guard let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw MetaHTTP.invalid("Could not draw the contact sheet.")
        }
        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        context.interpolationQuality = .high
        for (index, photo) in photos.enumerated() {
            try Task.checkCancellation()
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                          kCGImageSourceCreateThumbnailWithTransform: true,
                                          kCGImageSourceThumbnailMaxPixelSize: cell]
            guard let source = CGImageSourceCreateWithData(photo.thumbnail.data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw MetaHTTP.invalid("Could not decode photo \(index + 1) for the contact sheet.")
            }
            let x = CGFloat((index % columns) * cell)
            let y = CGFloat(size.height - (index / columns + 1) * cell)
            let scale = CGFloat(cell) / CGFloat(max(image.width, image.height))
            let width = CGFloat(image.width) * scale
            let height = CGFloat(image.height) * scale
            context.draw(image, in: CGRect(x: x + (CGFloat(cell) - width) / 2, y: y + (CGFloat(cell) - height) / 2,
                                          width: width, height: height))
            number(index + 1, at: CGPoint(x: x + 8, y: y + CGFloat(cell) - 56), in: context)
        }
        let output = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw MetaHTTP.invalid("Could not encode the contact sheet as JPEG.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw MetaHTTP.invalid("Could not finish the contact sheet JPEG.") }
        return EncodedImage(data: output as Data, format: .jpeg, size: size)
    }

    private static func number(_ number: Int, at origin: CGPoint, in context: CGContext) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 36, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(number), attributes: attributes))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let plate = CGRect(origin: origin, size: CGSize(width: max(48, ceil(width) + 20), height: 48))
        context.setFillColor(CGColor(gray: 0.03, alpha: 1))
        context.fill(plate)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: plate.midX - width / 2, y: plate.midY - (ascent - descent) / 2)
        CTLineDraw(line, context)
    }
}

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import LumenCore
import UniformTypeIdentifiers

enum BatchContactSheet {
    static let photoEdge = 160
    static let cellWidth = 184
    static let cellHeight = 192

    /// Writes every kept photo in library order, with its name beneath it.
    static func write(_ photos: [PhotoID], to url: URL,
                      image: @Sendable (PhotoID) async throws -> EncodedImage?) async throws {
        let columns = min(8, max(1, photos.count))
        let rows = max(1, (photos.count + columns - 1) / columns)
        let width = columns * cellWidth
        let height = rows * cellHeight
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw CLIError("The batch contact sheet could not be created.")
        }
        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        for (index, photo) in photos.enumerated() {
            try Task.checkCancellation()
            let x = Double((index % columns) * cellWidth)
            let y = Double(height - (index / columns + 1) * cellHeight)
            if let encoded = try await image(photo),
               let source = CGImageSourceCreateWithData(encoded.data as CFData, nil),
               let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                   kCGImageSourceCreateThumbnailFromImageAlways: true,
                   kCGImageSourceCreateThumbnailWithTransform: true,
                   kCGImageSourceThumbnailMaxPixelSize: photoEdge,
               ] as CFDictionary) {
                let scale = min(Double(photoEdge) / Double(thumbnail.width), Double(photoEdge) / Double(thumbnail.height))
                let w = Double(thumbnail.width) * scale
                let h = Double(thumbnail.height) * scale
                context.draw(thumbnail, in: CGRect(x: x + (Double(cellWidth) - w) / 2,
                                                   y: y + 24 + (Double(photoEdge) - h) / 2, width: w, height: h))
            }
            label(oneLine(photo.rawValue), x: x + 6, y: y + 8, context: context)
        }
        if photos.isEmpty { label("No kept photos", x: 6, y: 8, context: context) }
        try Task.checkCancellation()
        let data = NSMutableData()
        guard let raster = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CLIError("The batch contact sheet could not be encoded.")
        }
        CGImageDestinationAddImage(destination, raster, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CLIError("The batch contact sheet could not be written.") }
        try (data as Data).write(to: url, options: .atomic)
    }

    private static func label(_ text: String, x: Double, y: Double, context: CGContext) {
        let attributes: [CFString: Any] = [kCTFontAttributeName: CTFontCreateWithName("Helvetica" as CFString, 11, nil),
                                          kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1)]
        let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.saveGState()
        context.translateBy(x: x, y: y)
        context.scaleBy(x: min(1, Double(cellWidth - 12) / max(1, width)), y: 1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

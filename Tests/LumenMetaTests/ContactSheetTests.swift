import CoreGraphics
import Foundation
import ImageIO
import LumenCore
import Testing
import UniformTypeIdentifiers
@testable import LumenMeta

@Test(arguments: [1, 5, 6, 20])
func contactSheetHasFiveColumnsAndEnoughRows(count: Int) throws {
    let photo = try sheetPhoto(gray: 0.5)
    let sheet = try ContactSheet.make(Array(repeating: photo, count: count))
    #expect(sheet.format == .jpeg)
    #expect(sheet.data.starts(with: [0xff, 0xd8]))
    #expect(sheet.size == PixelSize(width: 1280, height: ((count + 4) / 5) * 256))
    #expect(sheet.size.longEdge <= 1600)
    let source = try #require(CGImageSourceCreateWithData(sheet.data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(image.width == sheet.size.width)
    #expect(image.height == sheet.size.height)
}

@Test func contactSheetKeepsPhotosAndLegibleNumbersInCellOrder() throws {
    let photos = try (0..<20).map { try sheetPhoto(gray: CGFloat(40 + $0 * 8) / 255) }
    let sheet = try ContactSheet.make(photos)
    let source = try #require(CGImageSourceCreateWithData(sheet.data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let pixels = try sheetPixels(image)
    // Coarse label silhouettes from a visually checked sheet, in number order.
    let labels: [UInt64] = [
        0xf0f0f0f0f0fdfff8, 0xffff1e7cf0e3f77f, 0x7effe3f878e3e77f, 0x7070ffff777e7c78, 0x3effe3e37f3f07ff,
        0x7effe3f77f13e77e, 0x0e0e1c1c383070ff, 0x7effe3ff7e67f77f, 0x3e7fe0ffe7e3f77f, 0x76f6d6d6d6d7f776,
        0xc6c6c6c6c6e7e7c6, 0xf6f63666c6d7f776, 0xe6f696e6e6c7f7e6, 0x4646f6f6766767c6, 0x76f6d6d6f67777f6,
        0x66f6d6f6f617f776, 0x262626664647f7f6, 0x76f6d6f6f6f7f776, 0x76f6c6f6d6d7f776, 0x6ffff3f6dcfdff67,
    ]
    for index in photos.indices {
        let x = (index % 5) * 256
        let y = (index / 5) * 256
        #expect(abs(Int(pixels[((y + 128) * image.width + x + 128) * 4]) - (40 + index * 8)) <= 3)
        let label = try sheetLabel(pixels, width: image.width, x: x + 8, y: y + 8)
        #expect((label ^ labels[index]).nonzeroBitCount <= 2)
        let closest = labels.indices.min { (label ^ labels[$0]).nonzeroBitCount < (label ^ labels[$1]).nonzeroBitCount }
        #expect(closest == index)
        #expect(pixels[((y + 10) * image.width + x + 10) * 4] < 20)
    }
}

@Test func contactSheetFitsPhotosWithoutStretchingAndOrientsThem() throws {
    let landscape = try sheetPhoto(gray: 0.8, size: PixelSize(width: 100, height: 50))
    let portrait = try sheetPhoto(gray: 0.8, size: PixelSize(width: 50, height: 100))
    let rotated = try sheetPhoto(gray: 0.8, size: PixelSize(width: 100, height: 50), orientation: 6)
    let sheet = try ContactSheet.make([landscape, portrait, rotated])
    let source = try #require(CGImageSourceCreateWithData(sheet.data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let pixels = try sheetPixels(image)
    func value(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * image.width + x) * 4] }
    #expect(value(128, 32) < 30)
    #expect(value(128, 128) > 190)
    #expect(value(128, 224) < 30)
    for column in [1, 2] {
        #expect(value(column * 256 + 32, 128) < 30)
        #expect(value(column * 256 + 128, 128) > 190)
        #expect(value(column * 256 + 224, 128) < 30)
    }
    #expect(value(3 * 256 + 128, 128) < 30)
}

private func sheetPhoto(gray: CGFloat, size: PixelSize = PixelSize(width: 32, height: 32), orientation: Int = 1) throws -> ReviewPhoto {
    let context = try #require(CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
    let image = try #require(context.makeImage())
    let output = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return ReviewPhoto(photo: PhotoID("photo"), thumbnail: EncodedImage(data: output as Data, format: .jpeg, size: size),
                       facts: PhotoFacts(size: size, sharpness: 0.5, exposure: Double(gray)))
}

private func sheetPixels(_ image: CGImage) throws -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    try pixels.withUnsafeMutableBytes { bytes in
        let context = try #require(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                             bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return pixels
}

private func sheetLabel(_ pixels: [UInt8], width: Int, x: Int, y: Int) throws -> UInt64 {
    var ink: [(x: Int, y: Int)] = []
    for row in 0..<48 {
        for column in 0..<80 where pixels[((y + row) * width + x + column) * 4] > 220 {
            ink.append((column, row))
        }
    }
    let left = try #require(ink.map(\.x).min())
    let top = try #require(ink.map(\.y).min())
    let right = try #require(ink.map(\.x).max()) + 1
    let bottom = try #require(ink.map(\.y).max()) + 1
    #expect(right - left >= 10)
    #expect(bottom - top >= 24)
    var bins = [Int](repeating: 0, count: 64)
    for point in ink {
        let column = min(7, (point.x - left) * 8 / (right - left))
        let row = min(7, (point.y - top) * 8 / (bottom - top))
        bins[row * 8 + column] += 1
    }
    let area = Double((right - left) * (bottom - top)) / 64
    return bins.enumerated().reduce(UInt64(0)) { result, bin in
        bin.element > Int(area * 0.25) ? result | (UInt64(1) << bin.offset) : result
    }
}

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import LumenCore
import Testing
import UniformTypeIdentifiers
@testable import LumenRender

struct LibraryFolder {
    let root: URL
    var input: URL { root.appendingPathComponent("photos", isDirectory: true) }
    var output: URL { root.appendingPathComponent("edited", isDirectory: true) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func photo(name: String, width: Int = 128, height: Int = 96, orientation: Int = 1,
               exif: [CFString: Any]? = nil,
               pixel: (Int, Int) -> (UInt8, UInt8, UInt8) = { _, _ in (90, 90, 90) }) throws -> URL {
        let image = try LibraryImages.image(width: width, height: height, pixel: pixel)
        let url = input.appendingPathComponent(name)
        let type: UTType = switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": .jpeg
        case "heic": .heic
        default: .png
        }
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation,
                                          kCGImageDestinationLossyCompressionQuality: 1]
        if let exif { properties[kCGImagePropertyExifDictionary] = exif }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }
}

enum LibraryImages {
    static let canRender = CIContext().createCGImage(CIImage(color: .white), from: CGRect(x: 0, y: 0, width: 1, height: 1)) != nil

    static let horizon: CIImage = {
        let sky = CIImage(color: CIColor(red: 0.4, green: 0.7, blue: 1))
        let ground = CIImage(color: CIColor(red: 0.25, green: 0.35, blue: 0.12))
            .cropped(to: CGRect(x: -1024, y: -1024, width: 2048, height: 1024))
        return ground.composited(over: sky)
            .transformed(by: CGAffineTransform(rotationAngle: 8 * .pi / 180))
            .cropped(to: CGRect(x: -256, y: -192, width: 512, height: 384))
            .transformed(by: CGAffineTransform(translationX: 256, y: 192))
    }()

    static let horizonTilt = PhotoStatistics.tilt(in: horizon)

    static func image(width: Int, height: Int, pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> CGImage {
        var bytes = [UInt8]()
        bytes.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                bytes += [r, g, b, 255]
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    static func write(_ image: CIImage, to url: URL) throws {
        let data = try #require(CIContext().pngRepresentation(of: image, format: .RGBA8,
                                                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        try data.write(to: url)
    }

    static func size(of data: Data) throws -> PixelSize {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return PixelSize(width: image.width, height: image.height)
    }

    static func pixels(_ data: Data) throws -> (size: PixelSize, bytes: [UInt8]) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                                 bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return (PixelSize(width: image.width, height: image.height), bytes)
    }

    static func pixel(_ data: Data, x: Int, y: Int) throws -> (UInt8, UInt8, UInt8) {
        let pixels = try pixels(data)
        let index = (y * pixels.size.width + x) * 4
        return (pixels.bytes[index], pixels.bytes[index + 1], pixels.bytes[index + 2])
    }

    static func minimumAlpha(_ data: Data) throws -> UInt8 {
        let pixels = try pixels(data)
        return stride(from: 3, to: pixels.bytes.count, by: 4).map { pixels.bytes[$0] }.min() ?? 0
    }
}

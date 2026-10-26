import AppKit

// Draws the same mark at every icon resolution without a source image.
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
var entries = Data()

func integer(_ value: Int) -> Data {
    var bigEndian = UInt32(value).bigEndian
    return withUnsafeBytes(of: &bigEndian) { Data($0) }
}

let iconTypes = [(16, "icp4", "ic11"), (32, "icp5", "ic12"), (128, "ic07", "ic13"),
                 (256, "ic08", "ic14"), (512, "ic09", "ic10")]

for (size, standard, retina) in iconTypes {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            fatalError("Couldn't create the icon bitmap.")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let background = NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884),
                                      xRadius: 204, yRadius: 204)
        NSGradient(starting: NSColor(calibratedWhite: 0.18, alpha: 1),
                   ending: NSColor(calibratedWhite: 0.065, alpha: 1))!.draw(in: background, angle: -75)
        NSColor(calibratedWhite: 1, alpha: 0.09).setStroke()
        background.lineWidth = 3
        background.stroke()

        let mark = NSBezierPath()
        for (x, y, dx, dy) in [(300.0, 300.0, 1.0, 1.0), (724, 300, -1, 1),
                               (300, 724, 1, -1), (724, 724, -1, -1)] {
            mark.move(to: NSPoint(x: x, y: y + dy * 108))
            mark.line(to: NSPoint(x: x, y: y + dy * 28))
            mark.curve(to: NSPoint(x: x + dx * 28, y: y),
                       controlPoint1: NSPoint(x: x, y: y + dy * 8),
                       controlPoint2: NSPoint(x: x + dx * 8, y: y))
            mark.line(to: NSPoint(x: x + dx * 108, y: y))
        }
        mark.lineWidth = 28
        mark.lineCapStyle = .round
        NSColor(calibratedRed: 0.80, green: 0.91, blue: 0.66, alpha: 1).setStroke()
        mark.stroke()
        NSColor(calibratedRed: 0.80, green: 0.91, blue: 0.66, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 480, y: 480, width: 64, height: 64)).fill()
        NSGraphicsContext.restoreGraphicsState()

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Couldn't encode the icon.")
        }
        entries.append(Data((scale == 1 ? standard : retina).utf8))
        entries.append(integer(png.count + 8))
        entries.append(png)
    }
}

var icon = Data("icns".utf8)
icon.append(integer(entries.count + 8))
icon.append(entries)
try icon.write(to: destination, options: .atomic)
guard let image = NSImage(contentsOf: destination), image.isValid else {
    fatalError("macOS couldn't read the generated icon.")
}

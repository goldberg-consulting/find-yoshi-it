import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else { exit(2) }
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = root.appendingPathComponent("FindAnything.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
var iconBlocks = Data()
let blockTypes = [16: "icp4", 32: "icp5", 64: "icp6", 128: "ic07", 256: "ic08", 512: "ic09", 1024: "ic10"]
var savedSizes = Set<Int>()

func bigEndianLength(_ length: Int) -> Data {
    var value = UInt32(length).bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let factor = CGFloat(pixels) / 1024
        let transform = NSAffineTransform()
        transform.scale(by: factor)
        transform.concat()
        let background = NSBezierPath(roundedRect: NSRect(x: 75, y: 75, width: 874, height: 874), xRadius: 196, yRadius: 196)
        NSColor(red: 0.10, green: 0.38, blue: 0.35, alpha: 1).setFill()
        background.fill()
        let gradient = NSGradient(starting: NSColor(white: 1, alpha: 0.10), ending: NSColor(white: 0, alpha: 0.08))
        gradient?.draw(in: background, angle: -75)

        let document = NSBezierPath(roundedRect: NSRect(x: 261, y: 230, width: 436, height: 567), xRadius: 34, yRadius: 34)
        NSColor(red: 0.95, green: 0.95, blue: 0.88, alpha: 1).setFill()
        document.fill()
        NSColor(red: 0.10, green: 0.38, blue: 0.35, alpha: 0.3).setStroke()
        for y in [682, 609, 536] {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: 328, y: y))
            line.line(to: NSPoint(x: y == 536 ? 470 : 620, y: y))
            line.lineWidth = 23
            line.lineCapStyle = .round
            line.stroke()
        }
        let glass = NSBezierPath(ovalIn: NSRect(x: 461, y: 256, width: 245, height: 245))
        NSColor(red: 0.56, green: 0.80, blue: 0.68, alpha: 1).setFill()
        glass.fill()
        NSColor(red: 0.08, green: 0.29, blue: 0.28, alpha: 1).setStroke()
        glass.lineWidth = 38
        glass.stroke()
        let handle = NSBezierPath()
        handle.move(to: NSPoint(x: 674, y: 286))
        handle.line(to: NSPoint(x: 786, y: 174))
        handle.lineWidth = 55
        handle.lineCapStyle = .round
        handle.stroke()
        NSGraphicsContext.restoreGraphicsState()
        if let data = bitmap.representation(using: .png, properties: [:]) {
            let suffix = scale == 2 ? "@2x" : ""
            try data.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
            if savedSizes.insert(pixels).inserted, let blockType = blockTypes[pixels] {
                iconBlocks.append(Data(blockType.utf8))
                iconBlocks.append(bigEndianLength(data.count + 8))
                iconBlocks.append(data)
            }
        }
    }
}
var icns = Data("icns".utf8)
icns.append(bigEndianLength(iconBlocks.count + 8))
icns.append(iconBlocks)
try icns.write(to: root.appendingPathComponent("AppIcon.icns"))

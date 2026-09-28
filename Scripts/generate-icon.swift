// Draws the DisplayManager app icon into an .iconset folder. Used by Scripts/generate-icon.sh.
//
// Usage: swift Scripts/generate-icon.swift <output.iconset>
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: generate-icon.swift <output.iconset>\n".utf8))
    exit(64)
}
let outputURL = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

/// Draws the icon in a 1024 × 1024 coordinate space.
func drawIcon(in context: CGContext) {
    let canvas = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    // Background: rounded square with a blue gradient (macOS icon grid: 824 pt body, 100 pt margin).
    let body = canvas.insetBy(dx: 100, dy: 100)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    context.addPath(bodyPath)
    context.setFillColor(NSColor(calibratedRed: 0.12, green: 0.36, blue: 0.86, alpha: 1).cgColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(bodyPath)
    context.clip()
    let colors = [
        NSColor(calibratedRed: 0.29, green: 0.62, blue: 1.0, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.10, green: 0.30, blue: 0.80, alpha: 1).cgColor,
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
        context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])
    }
    context.restoreGState()

    // Two displays side by side: a large one and a smaller rotated-portrait one, like an arrangement view.
    func display(_ rect: CGRect, menuBar: Bool) {
        let frame = CGPath(roundedRect: rect, cornerWidth: 26, cornerHeight: 26, transform: nil)
        context.addPath(frame)
        context.setFillColor(NSColor.white.withAlphaComponent(0.96).cgColor)
        context.fillPath()
        let screen = rect.insetBy(dx: 22, dy: 22)
        let screenPath = CGPath(roundedRect: screen, cornerWidth: 10, cornerHeight: 10, transform: nil)
        context.addPath(screenPath)
        context.setFillColor(NSColor(calibratedRed: 0.16, green: 0.42, blue: 0.92, alpha: 0.28).cgColor)
        context.fillPath()
        if menuBar {
            context.saveGState()
            context.addPath(screenPath)
            context.clip()
            context.setFillColor(NSColor(calibratedRed: 0.10, green: 0.30, blue: 0.80, alpha: 0.75).cgColor)
            context.fill(CGRect(x: screen.minX, y: screen.maxY - 30, width: screen.width, height: 30))
            context.restoreGState()
        }
    }

    let main = CGRect(x: 196, y: 420, width: 420, height: 280)
    display(main, menuBar: true)
    let side = CGRect(x: 652, y: 360, width: 176, height: 300)
    display(side, menuBar: false)

    // Stand under the main display.
    context.setFillColor(NSColor.white.withAlphaComponent(0.96).cgColor)
    context.fill(CGRect(x: 376, y: 330, width: 60, height: 90))
    let foot = CGPath(roundedRect: CGRect(x: 300, y: 300, width: 212, height: 40), cornerWidth: 18, cornerHeight: 18, transform: nil)
    context.addPath(foot)
    context.fillPath()
}

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for size in sizes {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size.pixels, pixelsHigh: size.pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let graphics = NSGraphicsContext(bitmapImageRep: rep)
    else {
        FileHandle.standardError.write(Data("could not create a bitmap for \(size.name)\n".utf8))
        exit(1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.clear(CGRect(x: 0, y: 0, width: size.pixels, height: size.pixels))
    context.scaleBy(x: CGFloat(size.pixels) / 1024, y: CGFloat(size.pixels) / 1024)
    context.interpolationQuality = .high
    drawIcon(in: context)
    graphics.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("could not encode \(size.name)\n".utf8))
        exit(1)
    }
    try png.write(to: outputURL.appendingPathComponent("\(size.name).png"))
}
print("Wrote \(sizes.count) images to \(outputURL.path)")

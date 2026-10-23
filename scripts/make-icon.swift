// Draws Resources/AppIcon.icns: a rounded tile with a table grid and a key, for DSQL's IAM tokens.
import AppKit

func drawIcon(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let inset = size * 0.1
        let tile = rect.insetBy(dx: inset, dy: inset)
        let path = NSBezierPath(roundedRect: tile, xRadius: size * 0.18, yRadius: size * 0.18)
        NSGradient(starting: NSColor(red: 0.20, green: 0.45, blue: 0.95, alpha: 1),
                   ending: NSColor(red: 0.47, green: 0.27, blue: 0.86, alpha: 1))!.draw(in: path, angle: -60)

        let grid = tile.insetBy(dx: tile.width * 0.2, dy: tile.height * 0.24)
        let gridPath = NSBezierPath(roundedRect: grid, xRadius: size * 0.04, yRadius: size * 0.04)
        NSColor.white.withAlphaComponent(0.95).setFill()
        gridPath.fill()
        NSColor(red: 0.30, green: 0.40, blue: 0.90, alpha: 1).setFill()
        let header = NSRect(x: grid.minX, y: grid.maxY - grid.height * 0.26, width: grid.width, height: grid.height * 0.26)
        NSBezierPath(roundedRect: header, xRadius: size * 0.04, yRadius: size * 0.04).fill()
        NSBezierPath(rect: NSRect(x: header.minX, y: header.minY, width: header.width, height: header.height / 2)).fill()
        NSColor(red: 0.30, green: 0.40, blue: 0.90, alpha: 0.35).setFill()
        let line = max(1, size * 0.012)
        for row in 1...2 {
            let y = grid.minY + grid.height * 0.74 * CGFloat(row) / 3
            NSBezierPath(rect: NSRect(x: grid.minX, y: y, width: grid.width, height: line)).fill()
        }
        for column in 1...2 {
            let x = grid.minX + grid.width * CGFloat(column) / 3
            NSBezierPath(rect: NSRect(x: x, y: grid.minY, width: line, height: grid.height * 0.74)).fill()
        }
        return true
    }
}

let iconset = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = CGFloat(base * scale)
        let image = drawIcon(size: pixels)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels), pixelsHigh: Int(pixels), bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}

// Draws the 1024 px app icon to the path in argv[1]. Scripts/package_app.sh turns it into Putaway.icns.
import AppKit

let size = 1024.0
let inset = 100.0
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let tile = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGradient(starting: NSColor(srgbRed: 0.30, green: 0.62, blue: 0.98, alpha: 1),
               ending: NSColor(srgbRed: 0.13, green: 0.36, blue: 0.85, alpha: 1))!
        .draw(in: shape, angle: -90)
    let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .medium)
        .applying(.init(paletteColors: [.white]))
    let glyph = NSImage(systemSymbolName: "tray.and.arrow.down.fill", accessibilityDescription: nil)!
        .withSymbolConfiguration(config)!
    let glyphRect = NSRect(x: (size - glyph.size.width) / 2, y: (size - glyph.size.height) / 2,
                           width: glyph.size.width, height: glyph.size.height)
    glyph.draw(in: glyphRect)
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(filePath: CommandLine.arguments[1]))

// Draws the MacMonitor app icon (a fan over a chip-like tile, blue to orange) into an .iconset.
// Usage: swift scripts/make-icon.swift <out.iconset>, then iconutil -c icns <out.iconset>.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.09
    let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: tile, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(colors: [NSColor(srgbRed: 0.05, green: 0.07, blue: 0.10, alpha: 1), NSColor(srgbRed: 0.10, green: 0.13, blue: 0.19, alpha: 1)])!
        .draw(in: path, angle: -90)
    // Heat glow, blue to orange.
    let glow = NSBezierPath(ovalIn: tile.insetBy(dx: s * 0.12, dy: s * 0.12))
    NSGradient(colors: [NSColor(srgbRed: 1.0, green: 0.62, blue: 0.04, alpha: 0.55), NSColor(srgbRed: 0.35, green: 0.65, blue: 1.0, alpha: 0.0)])!
        .draw(in: glow, relativeCenterPosition: .zero)
    // Pads on the edges, like a chip.
    NSColor(white: 1, alpha: 0.18).setFill()
    let n = 6
    for i in 0..<n {
        let x = tile.minX + tile.width * (CGFloat(i) + 1.5) / CGFloat(n + 2)
        NSBezierPath(roundedRect: NSRect(x: x, y: tile.minY + s * 0.035, width: s * 0.045, height: s * 0.02), xRadius: 2, yRadius: 2).fill()
        NSBezierPath(roundedRect: NSRect(x: x, y: tile.maxY - s * 0.055, width: s * 0.045, height: s * 0.02), xRadius: 2, yRadius: 2).fill()
    }
    // Fan blades symbol.
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .semibold)
        .applying(.init(paletteColors: [NSColor(srgbRed: 0.35, green: 0.65, blue: 1.0, alpha: 1)]))
    if let sym = NSImage(systemSymbolName: "fanblades.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let sz = sym.size
        sym.draw(in: NSRect(x: (s - sz.width) / 2, y: (s - sz.height) / 2, width: sz.width, height: sz.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px).write(to: out.appendingPathComponent("icon_\(name).png"))
}
print("wrote", out.path)

// Renders the app icon: a glowing T-tetromino of bevelled cubes on a dark rounded tile.
// Usage: swift scripts/make_icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Background tile (macOS icon grid: 824pt tile centred in 1024).
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor.black.withAlphaComponent(0.5).cgColor)
ctx.addPath(tilePath)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let background = CGGradient(colorsSpace: space, colors: [
    NSColor(red: 0.10, green: 0.05, blue: 0.22, alpha: 1).cgColor,
    NSColor(red: 0.02, green: 0.02, blue: 0.06, alpha: 1).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// Neon floor grid.
ctx.setStrokeColor(NSColor(red: 0.95, green: 0.25, blue: 0.75, alpha: 0.35).cgColor)
ctx.setLineWidth(4)
for i in 0...12 {
    let x = 100 + CGFloat(i) * 824 / 12
    ctx.move(to: CGPoint(x: 512 + (x - 512) * 0.35, y: 380))
    ctx.addLine(to: CGPoint(x: 512 + (x - 512) * 1.6, y: 100))
}
for j in 0..<6 {
    let t = CGFloat(j) / 6
    let y = 380 - 280 * t * t
    ctx.move(to: CGPoint(x: 100, y: y))
    ctx.addLine(to: CGPoint(x: 924, y: y))
}
ctx.strokePath()

// T piece.
let cube: CGFloat = 170
let cells = [(0, 1), (1, 1), (2, 1), (1, 0)]
let origin = CGPoint(x: 512 - cube * 1.5, y: 430)
let fill = NSColor(red: 0.62, green: 0.22, blue: 1.0, alpha: 1)
for (cx, cy) in cells {
    let rect = CGRect(x: origin.x + CGFloat(cx) * cube, y: origin.y + CGFloat(cy) * cube, width: cube, height: cube)
        .insetBy(dx: 6, dy: 6)
    let path = CGPath(roundedRect: rect, cornerWidth: 26, cornerHeight: 26, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 50, color: fill.withAlphaComponent(0.9).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(fill.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let shade = CGGradient(colorsSpace: space, colors: [
        NSColor(red: 0.85, green: 0.6, blue: 1, alpha: 1).cgColor,
        NSColor(red: 0.45, green: 0.1, blue: 0.85, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(shade, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    ctx.restoreGState()

    let inner = CGPath(roundedRect: rect.insetBy(dx: 22, dy: 22), cornerWidth: 12, cornerHeight: 12, transform: nil)
    ctx.addPath(inner)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.75).cgColor)
    ctx.setLineWidth(7)
    ctx.strokePath()
}
ctx.restoreGState()
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

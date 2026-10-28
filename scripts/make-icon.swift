// Draws Lookout's app icon, a scope with a check in it on Claude's coral, and writes AppIcon.icns.
// Run from the repo root: swift scripts/make-icon.swift
import AppKit

func draw(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s / 1024, y: s / 1024)  // drawn on Apple's 1024 grid, y up

    // The tile: the macOS icon shape, inset to the grid, with a soft shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.addPath(tilePath)
    ctx.setFillColor(NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let colors = [NSColor(red: 0.93, green: 0.57, blue: 0.42, alpha: 1).cgColor,
                  NSColor(red: 0.78, green: 0.36, blue: 0.22, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // A scope's lens and reticle marks, watching; inside it, a check, a task done.
    let white = NSColor.white.cgColor
    let c = CGPoint(x: 512, y: 512)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: NSColor.black.withAlphaComponent(0.2).cgColor)
    // The glass: a shade darker than the tile, so the ring reads as a lens.
    ctx.addEllipse(in: CGRect(x: c.x - 262, y: c.y - 262, width: 524, height: 524))
    ctx.setFillColor(NSColor(red: 0.70, green: 0.30, blue: 0.18, alpha: 0.35).cgColor)
    ctx.fillPath()
    ctx.setStrokeColor(white)
    ctx.setLineWidth(60)
    ctx.addEllipse(in: CGRect(x: c.x - 262, y: c.y - 262, width: 524, height: 524))
    ctx.strokePath()
    // Reticle marks just outside the ring, top, bottom, left and right.
    ctx.setLineWidth(48)
    ctx.setLineCap(.round)
    for (dx, dy) in [(0.0, 1.0), (0.0, -1.0), (1.0, 0.0), (-1.0, 0.0)] as [(CGFloat, CGFloat)] {
        ctx.move(to: CGPoint(x: c.x + dx * 312, y: c.y + dy * 312))
        ctx.addLine(to: CGPoint(x: c.x + dx * 372, y: c.y + dy * 372))
    }
    ctx.strokePath()
    // The check.
    ctx.setLineWidth(78)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 392, y: 520))
    ctx.addLine(to: CGPoint(x: 478, y: 430))
    ctx.addLine(to: CGPoint(x: 646, y: 612))
    ctx.strokePath()
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let set = URL(fileURLWithPath: "AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! draw(size: base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(size: base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", set.path, "-o", "AppIcon.icns"]
try! task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: set)
print(task.terminationStatus == 0 ? "wrote AppIcon.icns" : "iconutil failed")

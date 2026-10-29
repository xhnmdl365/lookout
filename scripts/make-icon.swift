// Draws Lookout's app icon, a task panel with Claude's spark scanning it, and writes AppIcon.icns.
// Run from the repo root: swift scripts/make-icon.swift
import AppKit

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    NSColor(red: r, green: g, blue: b, alpha: a).cgColor
}

func roundedRect(_ ctx: CGContext, _ r: CGRect, _ radius: CGFloat, _ color: CGColor) {
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(color)
    ctx.fillPath()
}

func disc(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ color: CGColor) {
    ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    ctx.setFillColor(color)
    ctx.fillPath()
}

// A four-point spark with curved sides, like the panel's Triage spark.
func spark(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ color: CGColor) {
    let tips = (0..<4).map { k -> CGPoint in
        let a = CGFloat(k) * .pi / 2 + .pi / 2
        return CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
    }
    let path = CGMutablePath()
    path.move(to: tips[0])
    for k in 0..<4 {
        let next = tips[(k + 1) % 4]
        // Pulling each side in towards the centre gives the spark its waist.
        let pull = CGPoint(x: c.x + ((tips[k].x + next.x) / 2 - c.x) * 0.12,
                           y: c.y + ((tips[k].y + next.y) / 2 - c.y) * 0.12)
        path.addQuadCurve(to: next, control: pull)
    }
    ctx.addPath(path)
    ctx.setFillColor(color)
    ctx.fillPath()
}

func draw(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s / 1024, y: s / 1024)  // drawn on Apple's 1024 grid, y up

    // The tile: the macOS icon shape, inset to the grid, with a soft shadow, in a blue gradient.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    let top = rgb(0.38, 0.47, 0.98), bottom = rgb(0.22, 0.24, 0.72)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0, 0, 0, 0.28))
    ctx.addPath(tilePath)
    ctx.setFillColor(bottom)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top, bottom] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // The panel, floating, centred in the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: rgb(0, 0, 0.15, 0.35))
    roundedRect(ctx, CGRect(x: 242, y: 222, width: 540, height: 580), 70, rgb(1, 1, 1))
    ctx.restoreGState()

    // Its rows, in the panel's own status colours: waiting on you, active, done.
    let line = rgb(0.82, 0.84, 0.90)
    let x: CGFloat = 330
    disc(ctx, CGPoint(x: x, y: 658), 52, rgb(1.0, 0.62, 0.04, 0.3))
    disc(ctx, CGPoint(x: x, y: 658), 30, rgb(1.0, 0.62, 0.04))
    roundedRect(ctx, CGRect(x: 396, y: 636, width: 220, height: 44), 22, line)  // short, clear of the waves
    disc(ctx, CGPoint(x: x, y: 512), 30, rgb(0.0, 0.48, 1.0))
    roundedRect(ctx, CGRect(x: 396, y: 490, width: 290, height: 44), 22, line)
    disc(ctx, CGPoint(x: x, y: 366), 38, rgb(0.20, 0.78, 0.35))
    ctx.setStrokeColor(rgb(1, 1, 1))
    ctx.setLineWidth(10)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: x - 17, y: 367))
    ctx.addLine(to: CGPoint(x: x - 5, y: 354))
    ctx.addLine(to: CGPoint(x: x + 18, y: 379))
    ctx.strokePath()
    roundedRect(ctx, CGRect(x: 396, y: 344, width: 210, height: 44), 22, line)

    // Claude's spark over the panel's corner, with a small one beside it; both kept inside the
    // tile's rounded corner. Waves go out from it over the list: it looks over the tasks by itself.
    let sparkCentre = CGPoint(x: 792, y: 806)
    ctx.setLineWidth(16)
    for (i, r) in ([110, 160, 210] as [CGFloat]).enumerated() {
        ctx.setStrokeColor(rgb(0.38, 0.47, 0.98, 0.85 - CGFloat(i) * 0.25))
        ctx.addArc(center: sparkCentre, radius: r, startAngle: .pi * 1.08, endAngle: .pi * 1.42, clockwise: false)
        ctx.strokePath()
    }
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: rgb(0, 0, 0.2, 0.35))
    spark(ctx, sparkCentre, 82, rgb(1, 1, 1))
    ctx.restoreGState()
    spark(ctx, CGPoint(x: 690, y: 872), 30, rgb(1, 1, 1, 0.85))

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

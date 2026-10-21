// Draws the app icon into an .iconset folder: swift scripts/make-icon.swift <out.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func drawIcon(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(pixels) / 1024
    ctx.scaleBy(x: s, y: s)

    // Body: the standard macOS icon square, 824pt on a 1024 canvas, with a soft shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        NSColor(srgbRed: 0.27, green: 0.36, blue: 0.95, alpha: 1).cgColor,
        NSColor(srgbRed: 0.53, green: 0.26, blue: 0.86, alpha: 1).cgColor
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
    ctx.restoreGState()

    // Viewfinder corners.
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(52)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let inner = CGRect(x: 262, y: 262, width: 500, height: 500)
    let arm: CGFloat = 130
    for (corner, dx, dy) in [
        (CGPoint(x: inner.minX, y: inner.minY), 1.0, 1.0),
        (CGPoint(x: inner.maxX, y: inner.minY), -1.0, 1.0),
        (CGPoint(x: inner.minX, y: inner.maxY), 1.0, -1.0),
        (CGPoint(x: inner.maxX, y: inner.maxY), -1.0, -1.0)
    ] {
        ctx.move(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
        ctx.addLine(to: corner)
        ctx.addLine(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
        ctx.strokePath()
    }

    // An annotation arrow pointing into the frame.
    let coral = NSColor(srgbRed: 1.0, green: 0.42, blue: 0.36, alpha: 1).cgColor
    ctx.setStrokeColor(coral)
    ctx.setFillColor(coral)
    ctx.setLineWidth(46)
    let tail = CGPoint(x: 395, y: 395), tip = CGPoint(x: 640, y: 640)
    let head: CGFloat = 150
    let ux = (tip.x - tail.x) / hypot(tip.x - tail.x, tip.y - tail.y)
    let uy = (tip.y - tail.y) / hypot(tip.x - tail.x, tip.y - tail.y)
    let base = CGPoint(x: tip.x - ux * head, y: tip.y - uy * head)
    ctx.move(to: tail)
    ctx.addLine(to: CGPoint(x: base.x + ux * 4, y: base.y + uy * 4))
    ctx.strokePath()
    ctx.move(to: tip)
    ctx.addLine(to: CGPoint(x: base.x - uy * head * 0.55, y: base.y + ux * head * 0.55))
    ctx.addLine(to: CGPoint(x: base.x + uy * head * 0.55, y: base.y - ux * head * 0.55))
    ctx.closePath()
    ctx.fillPath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (pixels, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"),
                       (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
    try! drawIcon(pixels: pixels).write(to: output.appendingPathComponent("icon_\(name).png"))
}

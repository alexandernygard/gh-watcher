// Renders the app icon: a gradient squircle with a stylised commit graph.
// Usage: swift Scripts/make-icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [NSColor(red: 0.16, green: 0.12, blue: 0.36, alpha: 1),
                        NSColor(red: 0.36, green: 0.22, blue: 0.78, alpha: 1),
                        NSColor(red: 0.22, green: 0.52, blue: 0.98, alpha: 1)])!.draw(in: shape, angle: 60)

    // Soft top highlight
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    let u = rect.width / 10
    let ox = rect.minX, oy = rect.minY
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + x * u, y: oy + y * u) }

    let white = NSColor.white
    let green = NSColor(red: 0.30, green: 0.90, blue: 0.50, alpha: 1)
    let pink = NSColor(red: 1.0, green: 0.55, blue: 0.75, alpha: 1)

    func line(_ path: NSBezierPath, _ color: NSColor) {
        path.lineWidth = u * 0.55
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }
    let trunk = NSBezierPath(); trunk.move(to: p(3.4, 1.8)); trunk.line(to: p(3.4, 8.2)); line(trunk, white)
    let branch = NSBezierPath(); branch.move(to: p(3.4, 3.4))
    branch.curve(to: p(6.6, 5.6), controlPoint1: p(3.4, 4.8), controlPoint2: p(6.6, 4.2))
    branch.line(to: p(6.6, 6.2))
    branch.curve(to: p(3.4, 7.4), controlPoint1: p(6.6, 7.0), controlPoint2: p(3.4, 6.6))
    line(branch, white.withAlphaComponent(0.85))

    func node(_ c: NSPoint, _ r: CGFloat, _ color: NSColor, ring: Bool = false) {
        let rr = NSRect(x: c.x - r * u, y: c.y - r * u, width: r * 2 * u, height: r * 2 * u)
        let path = NSBezierPath(ovalIn: rr)
        color.setFill(); path.fill()
        if ring {
            NSColor(red: 0.30, green: 0.20, blue: 0.70, alpha: 1).setStroke()
            path.lineWidth = u * 0.28
            path.stroke()
        }
    }
    node(p(3.4, 2.2), 0.75, white)
    node(p(3.4, 5.0), 0.75, white)
    node(p(6.6, 5.9), 0.95, green, ring: true)
    node(p(3.4, 7.8), 0.95, pink, ring: true)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

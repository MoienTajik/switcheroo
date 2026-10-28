// Generates AppIcon.icns: swiftc make-icon.swift -o /tmp/make-icon && /tmp/make-icon (see make-icon.sh)
import Cocoa

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func pill(_ r: NSRect) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2) }

/// Draws the icon in a 1024 x 1024 space (origin bottom-left).
func draw() {
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)

    // Soft drop shadow under the tile, per the macOS icon grid.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.shadowBlurRadius = 28
    shadow.set()
    color(0x0e0f11).setFill(); squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Tile: subtle top-lit gradient + hairline highlight.
    NSGradient(starting: color(0x23262b), ending: color(0x0e0f11))!.draw(in: squircle, angle: -90)
    color(0xffffff, 0.10).setStroke(); squircle.lineWidth = 4
    NSBezierPath(roundedRect: tile.insetBy(dx: 2, dy: 2), xRadius: 184, yRadius: 184).stroke()

    // Top bar: the URL being replaced (light, filled red dot), shifted left.
    let h: CGFloat = 156, w: CGFloat = 548
    let top = NSRect(x: 160, y: 566, width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    let s2 = NSShadow()
    s2.shadowColor = NSColor.black.withAlphaComponent(0.35); s2.shadowOffset = NSSize(width: 0, height: -10); s2.shadowBlurRadius = 18
    s2.set()
    color(0xf2f3f3).setFill(); pill(top).fill()
    NSGraphicsContext.restoreGraphicsState()
    color(0xff5346).setFill()
    NSBezierPath(ovalIn: NSRect(x: top.minX + 46, y: top.midY - 36, width: 72, height: 72)).fill()
    color(0xc9ccd0).setFill()
    pill(NSRect(x: top.minX + 150, y: top.midY - 15, width: 260, height: 30)).fill()

    // Bottom bar: what is served instead (red, hollow ring), shifted right.
    let bot = NSRect(x: 1024 - 160 - w, y: 302, width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    s2.set()
    color(0xff5346).setFill(); pill(bot).fill()
    NSGraphicsContext.restoreGraphicsState()
    color(0xf2f3f3).setStroke()
    let ring = NSBezierPath(ovalIn: NSRect(x: bot.maxX - 46 - 72, y: bot.midY - 36, width: 72, height: 72).insetBy(dx: 8, dy: 8))
    ring.lineWidth = 16; ring.stroke()
    color(0x0e0f11, 0.28).setFill()
    pill(NSRect(x: bot.maxX - 150 - 260, y: bot.midY - 15, width: 260, height: 30)).fill()

    // Swap marks between the bars: a down arrow on the left, an up arrow on the right.
    color(0xf2f3f3).setStroke()
    for (x, down) in [(top.minX + 110, true), (bot.maxX - 110, false)] as [(CGFloat, Bool)] {
        let y0: CGFloat = down ? 548 : 480, y1: CGFloat = down ? 480 : 548
        let p = NSBezierPath()
        p.lineWidth = 28; p.lineCapStyle = .round; p.lineJoinStyle = .round
        p.move(to: NSPoint(x: x, y: y0)); p.line(to: NSPoint(x: x, y: y1))
        let d: CGFloat = down ? 1 : -1
        p.move(to: NSPoint(x: x - 36, y: y1 + 36 * d)); p.line(to: NSPoint(x: x, y: y1)); p.line(to: NSPoint(x: x + 36, y: y1 + 36 * d))
        p.stroke()
    }
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let t = NSAffineTransform(); t.scaleX(by: CGFloat(size) / 1024, yBy: CGFloat(size) / 1024); t.concat()
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! png(size: base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! png(size: base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
print("wrote \(out)")

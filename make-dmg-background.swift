// Draws the installer window's background: swiftc make-dmg-background.swift -o bg && ./bg out.png
// Window is 660 x 400 pt (drawn @2x). make-dmg.sh sets the icons at (165, 215) and (495, 215); Finder draws their centers
// about 44 pt lower (y = 259 from the top), so the arrow is drawn at that height.
import Cocoa

let W: CGFloat = 660, H: CGFloat = 400, S: CGFloat = 2
func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * S), pixelsHigh: Int(H * S), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)   // 144 dpi, so Finder shows it at 660 x 400 pt, sharp on Retina
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
// rep.size is in points, so the context already maps points to pixels: no extra scaling here.

NSGradient(starting: color(0xf7f8f8), ending: color(0xe6e8ea))!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, _ c: NSColor, y: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: c]
    let w = (s as NSString).size(withAttributes: attrs).width
    (s as NSString).draw(at: NSPoint(x: (W - w) / 2, y: y), withAttributes: attrs)
}
text("Install Switcheroo", size: 24, weight: .bold, color(0x15171b), y: H - 62)
text("Drag the app onto the Applications folder", size: 14, weight: .regular, color(0x565b63), y: H - 90)

// Arrow between the two icons (CG origin is bottom-left, so y = H - 259).
let y: CGFloat = H - 259
let accent = color(0xdc2d21)
accent.setStroke()
let arrow = NSBezierPath()
arrow.lineWidth = 6; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 262, y: y)); arrow.line(to: NSPoint(x: 398, y: y))
arrow.move(to: NSPoint(x: 378, y: y + 18)); arrow.line(to: NSPoint(x: 400, y: y)); arrow.line(to: NSPoint(x: 378, y: y - 18))
arrow.stroke()

NSGraphicsContext.restoreGraphicsState()
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "background.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")

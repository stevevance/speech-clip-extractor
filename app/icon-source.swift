import AppKit
import CoreGraphics

/*
 * Draws the 1024×1024 app icon: a film-strip speech bubble with a play button.
 * Usage: ./draw out.png [topHex bottomHex]  (the tile's two gradient colors;
 * the play button and frame lines use the same two).
 */
let size = 1024.0
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Work top-left origin.
ctx.translateBy(x: 0, y: size); ctx.scaleBy(x: 1, y: -1)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

let args = CommandLine.arguments
let top = args.count > 3 ? UInt32(args[2], radix: 16)! : 0xFF8A65
let bottom = args.count > 3 ? UInt32(args[3], radix: 16)! : 0xD81B60

// macOS icon grid: an 824-pt rounded square centered on the 1024 canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Soft shadow under the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(bodyPath); ctx.setFillColor(rgb(bottom)); ctx.fillPath()
ctx.restoreGState()

// Two-color gradient tile.
ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [rgb(top), rgb(bottom)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
// A faint highlight across the top.
let shine = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.18), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(shine, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 460), options: [])
ctx.restoreGState()

// Speech bubble = rounded film strip + tail as one solid shape; sprocket holes are painted with the tile's gradient after.
let strip = CGRect(x: 205, y: 250, width: 614, height: 430)
let bubble = CGPath(roundedRect: strip, cornerWidth: 80, cornerHeight: 80, transform: nil)
// Tail at lower left, a separate shape so its direction can't cancel out the overlap.
let tail = CGMutablePath()
tail.move(to: CGPoint(x: 315, y: strip.maxY - 18))
tail.addLine(to: CGPoint(x: 282, y: 812))
tail.addQuadCurve(to: CGPoint(x: 445, y: strip.maxY - 18), control: CGPoint(x: 360, y: 760))
tail.closeSubpath()

let holes = CGMutablePath()
let holeW = 46.0, holeH = 34.0, count = 8
let left = strip.minX + 48, right = strip.maxX - 48
let step = (right - left - holeW) / Double(count - 1)
for row in [strip.minY + 30, strip.maxY - 30 - holeH] {
    for i in 0..<count {
        holes.addRoundedRect(in: CGRect(x: left + Double(i) * step, y: row, width: holeW, height: holeH), cornerWidth: 9, cornerHeight: 9)
    }
}

// Strip and tail filled separately on one layer, so the overlap stays solid white and casts one shadow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 30, color: rgb(0x10063D, 0.45))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.setFillColor(rgb(0xFFFFFF))
ctx.addPath(bubble); ctx.fillPath()
ctx.addPath(tail); ctx.fillPath()
ctx.endTransparencyLayer()
ctx.restoreGState()

// The holes show the tile underneath: redraw the same background gradient clipped to them.
ctx.saveGState()
ctx.addPath(holes); ctx.clip()
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
ctx.drawLinearGradient(shine, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 460), options: [])
ctx.restoreGState()

// Thin frame lines between the sprocket rows, like film frames.
ctx.setStrokeColor(rgb(bottom, 0.2)); ctx.setLineWidth(6)
let frameTop = strip.minY + 30 + holeH + 22, frameBottom = strip.maxY - 30 - holeH - 22
for x in [strip.minX + 150, strip.maxX - 150] {
    ctx.move(to: CGPoint(x: x, y: frameTop)); ctx.addLine(to: CGPoint(x: x, y: frameBottom))
}
ctx.strokePath()

// Play button in the tile's two colors, in the middle frame, with rounded corners.
let cx = strip.midX + 12, cy = strip.midY
let r = 108.0
let p1 = CGPoint(x: cx - r * 0.75, y: cy - r), p2 = CGPoint(x: cx - r * 0.75, y: cy + r), p3 = CGPoint(x: cx + r, y: cy)
let tri = CGMutablePath()
tri.move(to: CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2))
tri.addArc(tangent1End: p2, tangent2End: p3, radius: 26)
tri.addArc(tangent1End: p3, tangent2End: p1, radius: 26)
tri.addArc(tangent1End: p1, tangent2End: p2, radius: 26)
tri.closeSubpath()
ctx.saveGState()
ctx.addPath(tri); ctx.clip()
let playFill = CGGradient(colorsSpace: cs, colors: [rgb(top), rgb(bottom)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(playFill, start: CGPoint(x: cx, y: cy - r), end: CGPoint(x: cx, y: cy + r), options: [])
ctx.restoreGState()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

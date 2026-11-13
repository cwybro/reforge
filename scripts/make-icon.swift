// Draws the Reforge app icon (a glowing ᚱ rune inside an arcane ring) and writes
// Resources/AppIcon.icns plus Resources/AppIcon-preview.png.
//
//   swift scripts/make-icon.swift      (or: make icon)
import AppKit

let canvas: CGFloat = 1024
let mid = CGPoint(x: 512, y: 512)

// MARK: - Palette

let deepNavy = NSColor(red: 0.05, green: 0.04, blue: 0.15, alpha: 1)
let arcane   = NSColor(red: 0.36, green: 0.16, blue: 0.62, alpha: 1)
let dusk     = NSColor(red: 0.16, green: 0.07, blue: 0.33, alpha: 1)
let violet   = NSColor(red: 0.55, green: 0.25, blue: 1.00, alpha: 1)
let magenta  = NSColor(red: 1.00, green: 0.31, blue: 0.85, alpha: 1)
let cyan     = NSColor(red: 0.31, green: 0.94, blue: 1.00, alpha: 1)
let gold     = NSColor(red: 1.00, green: 0.83, blue: 0.42, alpha: 1)
let ember    = NSColor(red: 1.00, green: 0.55, blue: 0.20, alpha: 1)

// MARK: - Helpers

/// A four-pointed sparkle centred on `c`.
func sparkle(_ c: CGPoint, _ r: CGFloat, inner: CGFloat = 0.18) -> NSBezierPath {
    let p = NSBezierPath()
    for i in 0..<8 {
        let a = CGFloat(i) * .pi / 4 + .pi / 2
        let rad = i % 2 == 0 ? r : r * inner
        let pt = CGPoint(x: c.x + cos(a) * rad, y: c.y + sin(a) * rad)
        i == 0 ? p.move(to: pt) : p.line(to: pt)
    }
    p.close()
    return p
}

/// Fills `path` with `color` plus a soft coloured glow around it.
func glowFill(_ ctx: CGContext, _ path: NSBezierPath, _ color: NSColor, glow: NSColor? = nil, blur: CGFloat = 30) {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: blur, color: (glow ?? color).cgColor)
    color.setFill(); path.fill()
    ctx.restoreGState()
}

/// Strokes `path` with a glow, then paints a gradient inside the stroke.
func glowStroke(_ ctx: CGContext, _ path: CGPath, width: CGFloat, colors: [NSColor], angle: CGFloat = -90,
                glow: NSColor, blur: CGFloat) {
    ctx.saveGState()
    ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.setLineWidth(width)
    ctx.setShadow(offset: .zero, blur: blur, color: glow.cgColor)
    ctx.setStrokeColor(colors[0].cgColor)
    ctx.addPath(path); ctx.strokePath()
    ctx.restoreGState()
    guard colors.count > 1 else { return }
    ctx.saveGState()
    ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.setLineWidth(width)
    ctx.addPath(path); ctx.replacePathWithStrokedPath(); ctx.clip()
    NSGradient(colors: colors)!.draw(in: path.boundingBox.insetBy(dx: -width, dy: -width), angle: angle)
    ctx.restoreGState()
}

/// The rounded-square icon body with drop shadow; clips everything after it.
func iconBody(_ ctx: CGContext, fill: NSColor) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.5).cgColor)
    fill.setFill(); shape.fill()
    ctx.restoreGState()
    shape.addClip()
}

/// Arcane purple background pooling around `focus`, with warm forge light below.
func arcaneBackground(_ ctx: CGContext, focus: CGPoint = CGPoint(x: 512, y: 580), forgeLight: Bool = true) {
    iconBody(ctx, fill: deepNavy)
    NSGradient(colors: [arcane, dusk, deepNavy], atLocations: [0, 0.55, 1], colorSpace: .deviceRGB)!
        .draw(fromCenter: focus, radius: 0, toCenter: focus, radius: 560, options: [.drawsAfterEndingLocation])
    if forgeLight {
        NSGradient(colors: [ember.withAlphaComponent(0.4), .clear])!
            .draw(fromCenter: CGPoint(x: 512, y: 260), radius: 0, toCenter: CGPoint(x: 512, y: 260), radius: 340, options: [])
    }
}

/// Magenta→cyan glowing ring with rune diamonds and optional tick marks.
func arcaneRing(_ ctx: CGContext, center c: CGPoint, radius r: CGFloat, thickness t: CGFloat = 14, ticks: Int = 0) {
    let ring = NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    ring.appendOval(in: CGRect(x: c.x - r + t, y: c.y - r + t, width: (r - t) * 2, height: (r - t) * 2))
    ring.windingRule = .evenOdd
    glowFill(ctx, ring, magenta, blur: 40)
    ctx.saveGState(); ring.addClip()
    NSGradient(colors: [magenta, cyan])!.draw(in: ring.bounds, angle: 35)
    ctx.restoreGState()
    for i in 0..<ticks {
        let a = CGFloat(i) / CGFloat(ticks) * 2 * .pi
        let p = CGMutablePath()
        p.move(to: CGPoint(x: c.x + cos(a) * (r + 14), y: c.y + sin(a) * (r + 14)))
        p.addLine(to: CGPoint(x: c.x + cos(a) * (r + (i % 3 == 0 ? 38 : 26)), y: c.y + sin(a) * (r + (i % 3 == 0 ? 38 : 26))))
        glowStroke(ctx, p, width: 6, colors: [i % 2 == 0 ? cyan : magenta], glow: i % 2 == 0 ? cyan : magenta, blur: 10)
    }
    for i in 0..<8 {
        let a = CGFloat(i) * .pi / 4 + .pi / 8
        let d = CGPoint(x: c.x + cos(a) * (r - t / 2), y: c.y + sin(a) * (r - t / 2))
        let dia = NSBezierPath()
        dia.move(to: CGPoint(x: d.x, y: d.y + 22)); dia.line(to: CGPoint(x: d.x + 13, y: d.y))
        dia.line(to: CGPoint(x: d.x, y: d.y - 22)); dia.line(to: CGPoint(x: d.x - 13, y: d.y)); dia.close()
        glowFill(ctx, dia, i % 2 == 0 ? cyan : magenta, blur: 18)
    }
}

func embers(_ ctx: CGContext, _ list: [(CGFloat, CGFloat, CGFloat)]) {
    for (x, y, r) in list {
        glowFill(ctx, NSBezierPath(ovalIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), gold, glow: ember, blur: 14)
    }
}

func sparkles(_ ctx: CGContext, _ list: [(CGFloat, CGFloat, CGFloat, NSColor)]) {
    for (x, y, r, c) in list { glowFill(ctx, sparkle(CGPoint(x: x, y: y), r), .white, glow: c, blur: 20) }
}

/// ᚱ (Raidō), the runic letter R: stem, angular bowl, diagonal leg.
func runeR(scale s: CGFloat = 1, offset o: CGPoint = .zero) -> CGPath {
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: mid.x + (x - mid.x) * s + o.x, y: mid.y + (y - mid.y) * s + o.y) }
    let p = CGMutablePath()
    p.move(to: pt(420, 280)); p.addLine(to: pt(420, 760))
    p.addLine(to: pt(620, 650)); p.addLine(to: pt(420, 540))
    p.addLine(to: pt(630, 280))
    return p
}

// MARK: - Icon

func drawRuneRing(_ ctx: CGContext) {
    arcaneBackground(ctx, focus: mid, forgeLight: true)
    arcaneRing(ctx, center: mid, radius: 330, thickness: 12, ticks: 36)

    // Halo behind the rune.
    NSGradient(colors: [gold.withAlphaComponent(0.55), magenta.withAlphaComponent(0.25), .clear],
               atLocations: [0, 0.5, 1], colorSpace: .deviceRGB)!
        .draw(fromCenter: mid, radius: 0, toCenter: mid, radius: 300, options: [])

    let rune = runeR(scale: 0.92, offset: CGPoint(x: -4, y: 0))
    glowStroke(ctx, rune, width: 78, colors: [gold, .white, gold], angle: -90, glow: magenta, blur: 60)
    glowStroke(ctx, rune, width: 22, colors: [NSColor.white.withAlphaComponent(0.9)], glow: .white, blur: 16)

    // A spark flaring where the bowl meets the leg, plus rising embers.
    glowFill(ctx, sparkle(CGPoint(x: 615, y: 650), 90, inner: 0.14), .white, glow: gold, blur: 40)
    embers(ctx, [(660, 560, 9), (700, 480, 6), (380, 820, 7), (300, 640, 6), (720, 700, 5), (560, 380, 6), (330, 420, 5)])
    sparkles(ctx, [(240, 790, 30, cyan), (800, 790, 36, magenta), (805, 260, 22, gold), (220, 250, 20, magenta)])
}

// MARK: - Rendering

func image(_ draw: @escaping (CGContext) -> Void) -> NSImage {
    NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        draw(ctx)
        return true
    }
}

func png(_ img: NSImage, px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
let icon = image(drawRuneRing)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try! png(icon, px: points * scale).write(to: iconset.appendingPathComponent(name))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
let preview = URL(fileURLWithPath: "Resources/AppIcon-preview.png")
try? fm.removeItem(at: preview)
try! fm.copyItem(at: iconset.appendingPathComponent("icon_512x512@2x.png"), to: preview)
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")

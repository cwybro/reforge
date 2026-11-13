// Draws the README hero banner (docs/banner.png) in Reforge's arcane style.
// Run from the project root after the icon exists:  swift scripts/make-banner.swift
import AppKit

let width: CGFloat = 1600, height: CGFloat = 560

let navy    = NSColor(red: 0.05, green: 0.04, blue: 0.15, alpha: 1)
let arcane  = NSColor(red: 0.36, green: 0.16, blue: 0.62, alpha: 1)
let dusk    = NSColor(red: 0.16, green: 0.07, blue: 0.33, alpha: 1)
let magenta = NSColor(red: 1.00, green: 0.31, blue: 0.85, alpha: 1)
let cyan    = NSColor(red: 0.31, green: 0.94, blue: 1.00, alpha: 1)
let gold    = NSColor(red: 1.00, green: 0.83, blue: 0.42, alpha: 1)
let ember   = NSColor(red: 1.00, green: 0.55, blue: 0.20, alpha: 1)

func sparkle(_ c: CGPoint, _ r: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    for i in 0..<8 {
        let a = CGFloat(i) * .pi / 4 + .pi / 2
        let rad = i % 2 == 0 ? r : r * 0.18
        let pt = CGPoint(x: c.x + cos(a) * rad, y: c.y + sin(a) * rad)
        i == 0 ? p.move(to: pt) : p.line(to: pt)
    }
    p.close()
    return p
}

func glowFill(_ ctx: CGContext, _ path: NSBezierPath, _ color: NSColor, glow: NSColor, blur: CGFloat) {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: blur, color: glow.cgColor)
    color.setFill(); path.fill()
    ctx.restoreGState()
}

func roundedFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: size) ?? base
}

/// Draws text filled with a vertical gradient, with an optional glow.
func gradientText(_ ctx: CGContext, _ text: String, font: NSFont, at origin: CGPoint, colors: [NSColor], glow: NSColor) {
    let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
    let size = attr.size()
    let rect = CGRect(origin: origin, size: size)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 28, color: glow.cgColor)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    attr.draw(at: origin)
    ctx.setBlendMode(.sourceIn)
    NSGradient(colors: colors)!.draw(in: rect, angle: -90)
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

let banner = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
    guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
    let card = NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), xRadius: 40, yRadius: 40)
    card.addClip()
    navy.setFill(); card.fill()

    let iconCenter = CGPoint(x: 360, y: height / 2)
    NSGradient(colors: [arcane, dusk, navy], atLocations: [0, 0.5, 1], colorSpace: .deviceRGB)!
        .draw(fromCenter: iconCenter, radius: 0, toCenter: iconCenter, radius: 900, options: [.drawsAfterEndingLocation])
    NSGradient(colors: [ember.withAlphaComponent(0.25), .clear])!
        .draw(fromCenter: CGPoint(x: 900, y: -60), radius: 0, toCenter: CGPoint(x: 900, y: -60), radius: 520, options: [])

    // A large, faint arcane ring behind the icon.
    let ring = NSBezierPath(ovalIn: CGRect(x: iconCenter.x - 222, y: iconCenter.y - 222, width: 444, height: 444))
    ring.lineWidth = 3
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 24, color: magenta.cgColor)
    magenta.withAlphaComponent(0.45).setStroke(); ring.stroke()
    ctx.restoreGState()
    for i in 0..<48 {
        let a = CGFloat(i) / 48 * 2 * .pi
        let inner: CGFloat = 232, outer: CGFloat = i % 4 == 0 ? 256 : 244
        let tick = NSBezierPath()
        tick.move(to: CGPoint(x: iconCenter.x + cos(a) * inner, y: iconCenter.y + sin(a) * inner))
        tick.line(to: CGPoint(x: iconCenter.x + cos(a) * outer, y: iconCenter.y + sin(a) * outer))
        tick.lineWidth = 3
        (i % 2 == 0 ? cyan : magenta).withAlphaComponent(0.55).setStroke()
        tick.stroke()
    }

    // The app icon with a magenta glow.
    if let icon = NSImage(contentsOfFile: "Resources/AppIcon-preview.png") {
        let side: CGFloat = 400
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 60, color: magenta.withAlphaComponent(0.7).cgColor)
        icon.draw(in: CGRect(x: iconCenter.x - side / 2, y: iconCenter.y - side / 2, width: side, height: side))
        ctx.restoreGState()
    }

    // Wordmark and tagline.
    let textX: CGFloat = 680
    gradientText(ctx, "Reforge", font: roundedFont(168, .heavy), at: CGPoint(x: textX - 6, y: 268),
                 colors: [.white, gold], glow: gold.withAlphaComponent(0.55))
    NSAttributedString(string: "Your addons, freshly forged.",
                       attributes: [.font: roundedFont(50, .semibold), .foregroundColor: NSColor.white.withAlphaComponent(0.95)])
        .draw(at: CGPoint(x: textX, y: 198))
    NSAttributedString(string: "The fast, ad-free World of Warcraft addon updater for macOS.",
                       attributes: [.font: NSFont.systemFont(ofSize: 29, weight: .regular),
                                    .foregroundColor: NSColor.white.withAlphaComponent(0.62)])
        .draw(at: CGPoint(x: textX, y: 140))

    // Embers and sparkles.
    for (x, y, r) in [(590.0, 120.0, 6.0), (640.0, 440.0, 5.0), (1420.0, 120.0, 7.0), (1500.0, 300.0, 5.0),
                      (1180.0, 470.0, 6.0), (980.0, 80.0, 5.0), (120.0, 90.0, 6.0), (90.0, 400.0, 5.0)] {
        glowFill(ctx, NSBezierPath(ovalIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), gold, glow: ember, blur: 14)
    }
    for (x, y, r, c) in [(1500.0, 470.0, 30.0, cyan), (1350.0, 420.0, 16.0, magenta), (1540.0, 140.0, 20.0, magenta),
                         (620.0, 500.0, 18.0, cyan), (110.0, 470.0, 22.0, gold), (60.0, 190.0, 14.0, cyan),
                         (1100.0, 120.0, 14.0, gold), (1250.0, 520.0, 12.0, cyan)] {
        glowFill(ctx, sparkle(CGPoint(x: x, y: y), r), .white, glow: c, blur: 20)
    }
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
banner.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
NSGraphicsContext.restoreGraphicsState()
try! FileManager.default.createDirectory(atPath: "docs", withIntermediateDirectories: true)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "docs/banner.png"))
print("Wrote docs/banner.png")

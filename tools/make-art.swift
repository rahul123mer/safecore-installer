// Draws the SafeCore app icon and the DMG window background in SafeSpace brand colours.
// Usage: swift tools/make-art.swift <out-dir> <version> <arch-label> <mark.png>
// Writes: <out-dir>/icon-1024.png, <out-dir>/dmg-background.png (660x400), <out-dir>/dmg-background@2x.png
import AppKit

let args = CommandLine.arguments
let outDir = URL(fileURLWithPath: args.count > 1 ? args[1] : ".")
let version = args.count > 2 ? args[2] : "1.0.0"
let archLabel = args.count > 3 ? args[3] : "Universal"

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let markPath = args.count > 4 ? args[4] : "brand/safespace-mark.png"
let markImage = NSImage(contentsOfFile: markPath)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!

/// The real SafeSpace mark (brand/safespace-mark.png), recoloured to a single colour.
func drawMark(in rect: CGRect, color fill: NSColor, ctx: CGContext) {
    ctx.saveGState()
    ctx.interpolationQuality = .high
    ctx.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
    ctx.draw(markImage, in: rect)
    ctx.setBlendMode(.sourceIn)
    ctx.setFillColor(fill.cgColor)
    ctx.fill(rect)
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

func render(width: Int, height: Int, to url: URL, draw: (CGContext, CGFloat) -> Void, scale: CGFloat = 1) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = g
    g.cgContext.scaleBy(x: scale, y: scale)
    draw(g.cgContext, scale)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

// MARK: App icon (macOS squircle-ish rounded square with 10% margin)
render(width: 1024, height: 1024, to: outDir.appendingPathComponent("icon-1024.png")) { ctx, _ in
    let r = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: r, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x081F5C, 0.45).cgColor)
    ctx.addPath(path); ctx.setFillColor(color(0x2387F7).cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [color(0x23BFFE).cgColor, color(0x2387F7).cgColor, color(0x1B53E5).cgColor] as CFArray,
                          locations: [0, 0.6, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 150, y: 924), end: CGPoint(x: 874, y: 100), options: [])
    ctx.restoreGState()
    drawMark(in: CGRect(x: 287, y: 287, width: 450, height: 450), color: .white, ctx: ctx)
}

// MARK: DMG background (660x400 points). App icon sits at (470, 190) in Finder coordinates.
func drawBackground(_ ctx: CGContext, _ scale: CGFloat) {
    let W: CGFloat = 660, H: CGFloat = 400
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [color(0x081F5C).cgColor, color(0x05162B).cgColor] as CFArray, locations: [0, 0.8])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: H), end: CGPoint(x: W * 0.5, y: 0), options: [.drawsAfterEndLocation])
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [color(0x123C8F, 0.9).cgColor, color(0x123C8F, 0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: W * 0.85, y: H), startRadius: 0,
                           endCenter: CGPoint(x: W * 0.85, y: H), endRadius: 420, options: [])
    drawMark(in: CGRect(x: W - 210, y: -50, width: 260, height: 260), color: NSColor.white.withAlphaComponent(0.07), ctx: ctx)

    func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ c: NSColor, x: CGFloat, top: CGFloat, kern: CGFloat = 0, width: CGFloat = 300) {
        let p = NSMutableParagraphStyle(); p.lineSpacing = 2
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: c, .kern: kern, .paragraphStyle: p]
        let str = NSAttributedString(string: s, attributes: attrs)
        let bounds = str.boundingRect(with: CGSize(width: width, height: 400), options: [.usesLineFragmentOrigin])
        str.draw(with: CGRect(x: x, y: H - top - bounds.height, width: width, height: bounds.height), options: [.usesLineFragmentOrigin])
    }
    text("SAFESPACE · SAFECORE", 11, .bold, color(0x9EECFA), x: 52, top: 104, kern: 1.6)
    text("Technology that\nhelps save lives.", 28, .heavy, .white, x: 52, top: 126)
    text("Double-click Install SafeCore to install\nand enrol this box.", 13, .regular, color(0xBFD3F2), x: 52, top: 212)

    // chips
    var x: CGFloat = 52
    for label in [archLabel, "v\(version)"] {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: color(0xCFF6FD)]
        let s = NSAttributedString(string: label, attributes: attrs)
        let w = s.size().width + 18
        let r = CGRect(x: x, y: H - 282, width: w, height: 22)
        let p = CGPath(roundedRect: r, cornerWidth: 11, cornerHeight: 11, transform: nil)
        ctx.addPath(p); ctx.setFillColor(color(0x9EECFA, 0.14).cgColor); ctx.fillPath()
        ctx.addPath(p); ctx.setStrokeColor(color(0x9EECFA, 0.3).cgColor); ctx.setLineWidth(1); ctx.strokePath()
        s.draw(at: CGPoint(x: x + 9, y: H - 278))
        x += w + 8
    }
    text("Double-click to open", 11, .regular, color(0x9FB6DA), x: 412, top: 292, width: 120)
}
render(width: 660, height: 400, to: outDir.appendingPathComponent("dmg-background.png"), draw: drawBackground)
render(width: 1320, height: 800, to: outDir.appendingPathComponent("dmg-background@2x.png"), draw: drawBackground, scale: 2)
print("art written to \(outDir.path)")

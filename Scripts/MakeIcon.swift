// Renders icon-master.png: a document with a rename pencil on an indigo squircle.
// Run: swift Scripts/MakeIcon.swift <output-dir>   (Scripts/make-icns.sh wraps this)
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Support"
let canvas: CGFloat = 1024, square: CGFloat = 824
let radius = square * 0.2237
let inset = (canvas - square) / 2

let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()
let box = NSRect(x: inset, y: inset, width: square, height: square)
let squircle = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
NSGradient(colors: [NSColor(srgbRed: 0.36, green: 0.34, blue: 0.86, alpha: 1),
                    NSColor(srgbRed: 0.14, green: 0.13, blue: 0.42, alpha: 1)])!.draw(in: squircle, angle: -90)
squircle.addClip()
NSGradient(colors: [NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0)])!
    .draw(fromCenter: NSPoint(x: canvas / 2, y: canvas * 0.78), radius: 0,
          toCenter: NSPoint(x: canvas / 2, y: canvas * 0.78), radius: 520, options: [])

func symbol(_ name: String, pt: CGFloat, weight: NSFont.Weight = .semibold) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: pt, weight: weight))
}
func tinted(_ img: NSImage, _ top: NSColor, _ bottom: NSColor) -> NSImage {
    let out = NSImage(size: img.size)
    out.lockFocus()
    img.draw(in: NSRect(origin: .zero, size: img.size))
    NSGradient(colors: [top, bottom])!.draw(in: NSRect(origin: .zero, size: img.size), angle: -90)
    out.unlockFocus()
    // sourceAtop-style: redraw the glyph as an alpha mask over the gradient.
    let masked = NSImage(size: img.size)
    masked.lockFocus()
    out.draw(in: NSRect(origin: .zero, size: img.size))
    img.draw(in: NSRect(origin: .zero, size: img.size), from: .zero, operation: .destinationIn, fraction: 1)
    masked.unlockFocus()
    return masked
}

let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)

// Document with a folded corner and two text lines, drawn by hand.
do {
    let w: CGFloat = 400, h: CGFloat = 520, fold: CGFloat = 120, r: CGFloat = 44
    let x0 = (canvas - w) / 2 - 50, y0 = (canvas - h) / 2 + 10
    let page = NSBezierPath()
    page.move(to: NSPoint(x: x0 + r, y: y0))
    page.line(to: NSPoint(x: x0 + w - r, y: y0))
    page.appendArc(withCenter: NSPoint(x: x0 + w - r, y: y0 + r), radius: r, startAngle: -90, endAngle: 0)
    page.line(to: NSPoint(x: x0 + w, y: y0 + h - fold))
    page.line(to: NSPoint(x: x0 + w - fold, y: y0 + h))
    page.line(to: NSPoint(x: x0 + r, y: y0 + h))
    page.appendArc(withCenter: NSPoint(x: x0 + r, y: y0 + h - r), radius: r, startAngle: 90, endAngle: 180)
    page.line(to: NSPoint(x: x0, y: y0 + r))
    page.appendArc(withCenter: NSPoint(x: x0 + r, y: y0 + r), radius: r, startAngle: 180, endAngle: 270)
    page.close()
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSGradient(colors: [.white, NSColor(srgbRed: 0.86, green: 0.87, blue: 1, alpha: 1)])!.draw(in: page, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    let corner = NSBezierPath()
    corner.move(to: NSPoint(x: x0 + w - fold, y: y0 + h))
    corner.line(to: NSPoint(x: x0 + w - fold, y: y0 + h - fold + 28))
    corner.appendArc(withCenter: NSPoint(x: x0 + w - fold + 28, y: y0 + h - fold + 28), radius: 28, startAngle: 180, endAngle: 270)
    corner.line(to: NSPoint(x: x0 + w, y: y0 + h - fold))
    corner.close()
    NSColor(srgbRed: 0.70, green: 0.71, blue: 0.95, alpha: 1).setFill()
    corner.fill()
    NSColor(srgbRed: 0.36, green: 0.34, blue: 0.86, alpha: 0.55).setFill()
    for (i, frac) in [0.70, 0.52, 0.34].enumerated() {
        let lw = (w - 2 * 64) * CGFloat(frac + 0.3)
        NSBezierPath(roundedRect: NSRect(x: x0 + 64, y: y0 + 150 + CGFloat(i) * 58, width: min(lw, w - 128), height: 26), xRadius: 13, yRadius: 13).fill()
    }
}
// Pencil badge, bottom right.
let badge = NSRect(x: 560, y: 218, width: 250, height: 250)
NSGraphicsContext.saveGraphicsState()
shadow.set()
NSGradient(colors: [NSColor(srgbRed: 0.45, green: 0.95, blue: 0.78, alpha: 1),
                    NSColor(srgbRed: 0.15, green: 0.72, blue: 0.56, alpha: 1)])!
    .draw(in: NSBezierPath(ovalIn: badge), angle: -90)
NSGraphicsContext.restoreGraphicsState()
if let pen = symbol("pencil", pt: 150, weight: .bold) {
    let g = tinted(pen, NSColor(srgbRed: 0.05, green: 0.25, blue: 0.2, alpha: 1), NSColor(srgbRed: 0.05, green: 0.25, blue: 0.2, alpha: 1))
    let s = 130 / max(g.size.width, g.size.height)
    let sz = NSSize(width: g.size.width * s, height: g.size.height * s)
    g.draw(in: NSRect(x: badge.midX - sz.width / 2, y: badge.midY - sz.height / 2, width: sz.width, height: sz.height))
}
image.unlockFocus()

guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fputs("render failed\n", stderr); exit(1) }
let master = "\(outDir)/icon-master.png"
try! png.write(to: URL(fileURLWithPath: master))
print(master)

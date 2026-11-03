import AppKit
// Islet mark: the Dynamic Island pill with its camera lens cut out.
func canvas(_ draw: (CGContext) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
func pill(_ c: CGContext, center: CGPoint, width: CGFloat, color: CGColor) {
    let h = width * 0.34
    let r = CGRect(x: center.x - width / 2, y: center.y - h / 2, width: width, height: h)
    c.addPath(CGPath(roundedRect: r, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
    // Lens: a ring, the camera the island wraps.
    let lens = h * 0.42
    let lc = CGPoint(x: r.maxX - h / 2, y: center.y)
    c.addEllipse(in: CGRect(x: lc.x - lens / 2, y: lc.y - lens / 2, width: lens, height: lens))
    let dot = lens * 0.45
    c.addEllipse(in: CGRect(x: lc.x - dot / 2, y: lc.y - dot / 2, width: dot, height: dot))
    // Three text lines: the teleprompter's script reading across the island.
    c.setFillColor(color)
    c.fillPath(using: .evenOdd)
    let lineH = h * 0.1
    for (i, len) in [0.46, 0.34].enumerated() {
        let y = center.y + (i == 0 ? lineH * 0.9 : -lineH * 1.9)
        let line = CGRect(x: r.minX + h * 0.42, y: y, width: width * len, height: lineH)
        c.addPath(CGPath(roundedRect: line, cornerWidth: lineH / 2, cornerHeight: lineH / 2, transform: nil))
    }
    c.setBlendMode(.clear)
    c.fillPath()
    c.setBlendMode(.normal)
}
let out = CommandLine.arguments[1]
try! canvas { c in pill(c, center: CGPoint(x: 512, y: 512), width: 900, color: .black) }
    .write(to: URL(fileURLWithPath: out + "/logo.png"))
try! canvas { c in
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.35))
    c.addPath(shape); c.setFillColor(.black); c.fillPath()
    c.restoreGState()
    c.saveGState()
    c.addPath(shape); c.clip()
    let colors = [CGColor(srgbRed: 0.20, green: 0.16, blue: 0.42, alpha: 1),
                  CGColor(srgbRed: 0.04, green: 0.04, blue: 0.09, alpha: 1)] as CFArray
    c.drawLinearGradient(CGGradient(colorsSpace: nil, colors: colors, locations: [0, 1])!,
                         start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    let glow = [CGColor(srgbRed: 1, green: 0.62, blue: 0.2, alpha: 0.45), CGColor(srgbRed: 1, green: 0.62, blue: 0.2, alpha: 0)] as CFArray
    c.drawRadialGradient(CGGradient(colorsSpace: nil, colors: glow, locations: [0, 1])!,
                         startCenter: CGPoint(x: 512, y: 540), startRadius: 0,
                         endCenter: CGPoint(x: 512, y: 540), endRadius: 420, options: [])
    c.restoreGState()
    // The mark is punched through a white layer so its holes show the gradient.
    c.beginTransparencyLayer(auxiliaryInfo: nil)
    pill(c, center: CGPoint(x: 512, y: 540), width: 620, color: .white)
    c.endTransparencyLayer()
}.write(to: URL(fileURLWithPath: out + "/AppIcon-Default.png"))

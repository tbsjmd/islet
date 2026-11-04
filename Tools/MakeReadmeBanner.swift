// SPDX-License-Identifier: GPL-3.0-or-later

// Renders the README banner: the island glowing over Islet's night sky, the
// name, one line about it and its three headline features.
// Usage: swift Tools/MakeReadmeBanner.swift docs/assets/readme/banner.png
import AppKit

let W: CGFloat = 1600, H: CGFloat = 640
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "banner.png"
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let c = NSGraphicsContext.current!.cgContext
c.translateBy(x: 0, y: H); c.scaleBy(x: 1, y: -1)
NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

// Rounded card so it sits well on GitHub's light and dark pages.
let card = CGPath(roundedRect: CGRect(x: 0, y: 0, width: W, height: H), cornerWidth: 36, cornerHeight: 36, transform: nil)
c.addPath(card); c.clip()
c.drawLinearGradient(CGGradient(colorsSpace: space, colors: [rgb(0.16, 0.12, 0.34), rgb(0.03, 0.03, 0.07)] as CFArray, locations: [0, 1])!,
                     start: .zero, end: CGPoint(x: 0, y: H), options: [])
func glow(_ at: CGPoint, _ r: CGFloat, _ color: CGColor) {
    c.drawRadialGradient(CGGradient(colorsSpace: space, colors: [color, color.copy(alpha: 0)!] as CFArray, locations: [0, 1])!,
                         startCenter: at, startRadius: 0, endCenter: at, endRadius: r, options: [])
}
glow(CGPoint(x: W / 2, y: 40), 520, rgb(1, 0.6, 0.22, 0.4))
glow(CGPoint(x: W * 0.85, y: H), 420, rgb(0.45, 0.4, 1, 0.25))
var seed: UInt64 = 11
func random() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
for _ in 0..<140 {
    let p = CGPoint(x: random() * W, y: random() * H), r = 0.5 + random() * 1.4
    c.setFillColor(rgb(1, 1, 1, 0.12 + random() * 0.4)); c.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
}

// The island, listening.
let island = CGRect(x: W / 2 - 260, y: 34, width: 520, height: 76)
c.saveGState()
c.setShadow(offset: .zero, blur: 40, color: rgb(1, 0.6, 0.25, 0.8))
c.addPath(CGPath(roundedRect: island, cornerWidth: 38, cornerHeight: 38, transform: nil)); c.setFillColor(rgb(0, 0, 0)); c.fillPath()
c.restoreGState()
for (i, h) in [16.0, 30, 22, 40, 18, 28, 12].enumerated() {
    c.addPath(CGPath(roundedRect: CGRect(x: island.minX + 40 + CGFloat(i) * 11, y: island.midY - h / 2, width: 5, height: h),
                     cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
}
c.setFillColor(rgb(0.72, 0.62, 1)); c.fillPath()
c.setFillColor(rgb(0.13, 0.13, 0.2)); c.fillEllipse(in: CGRect(x: island.maxX - 60, y: island.midY - 15, width: 30, height: 30))
c.setFillColor(rgb(0.25, 0.3, 0.55)); c.fillEllipse(in: CGRect(x: island.maxX - 51, y: island.midY - 6, width: 12, height: 12))
let said = NSAttributedString(string: "“Reply to this email for me”", attributes: [
    .font: NSFont.systemFont(ofSize: 22, weight: .medium), .foregroundColor: NSColor(calibratedRed: 0.84, green: 0.78, blue: 1, alpha: 1)])
said.draw(at: NSPoint(x: island.minX + 132, y: island.midY - said.size().height / 2))

func centred(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, y: CGFloat, kern: CGFloat = 0) {
    let s = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                          .foregroundColor: color, .kern: kern])
    s.draw(at: NSPoint(x: (W - s.size().width) / 2, y: y))
}
centred("Islet", size: 132, weight: .heavy, color: .white, y: 168, kern: -3)
centred("Your Mac's Dynamic Island, finally doing something.", size: 34, weight: .semibold,
        color: NSColor(white: 1, alpha: 0.72), y: 336)

// Feature chips.
let chips = [("Voice agent that sees and uses your screen", NSColor(calibratedRed: 0.72, green: 0.62, blue: 1, alpha: 1)),
             ("Teleprompter under the camera", NSColor(calibratedRed: 1, green: 0.65, blue: 0.28, alpha: 1)),
             ("Video downloader", NSColor(calibratedRed: 0.3, green: 0.85, blue: 0.95, alpha: 1)),
             ("70+ Mac tools", NSColor(white: 0.85, alpha: 1))]
let font = NSFont.systemFont(ofSize: 21, weight: .semibold)
let widths = chips.map { NSAttributedString(string: $0.0, attributes: [.font: font]).size().width + 58 }
var x = (W - widths.reduce(0, +) - CGFloat(chips.count - 1) * 16) / 2
for (i, chip) in chips.enumerated() {
    let r = CGRect(x: x, y: 432, width: widths[i], height: 52)
    c.addPath(CGPath(roundedRect: r, cornerWidth: 26, cornerHeight: 26, transform: nil))
    c.setFillColor(rgb(1, 1, 1, 0.07)); c.fillPath()
    c.addPath(CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 26, cornerHeight: 26, transform: nil))
    c.setStrokeColor(rgb(1, 1, 1, 0.14)); c.setLineWidth(1); c.strokePath()
    c.setFillColor(chip.1.cgColor); c.fillEllipse(in: CGRect(x: r.minX + 22, y: r.midY - 5, width: 10, height: 10))
    let t = NSAttributedString(string: chip.0, attributes: [.font: font, .foregroundColor: NSColor.white])
    t.draw(at: NSPoint(x: r.minX + 42, y: r.midY - t.size().height / 2))
    x += widths[i] + 16
}
centred("FREE  ·  OPEN-SOURCED  ·  macOS 14+  ·  APPLE SILICON", size: 16, weight: .bold,
        color: NSColor(white: 1, alpha: 0.4), y: 552, kern: 2.5)

NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))

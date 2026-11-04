// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

// Renders the installer (DMG) window background: Islet's night-sky gradient,
// a Dynamic Island glowing at the top, the one instruction in large type, and
// two light pads where Finder puts the app and the Applications folder, joined
// by a glowing arrow. Finder draws icon labels in black, so they sit on the pads.
// Usage: swift Tools/MakeDMGBackground.swift <output.png>
import AppKit

// The window is 660×440 pt; render at 2× for Retina.
let scale: CGFloat = 2
let W: CGFloat = 660, H: CGFloat = 440
/// Icon centres as make-dmg.sh places them, in Finder's top-left coordinates.
let appCentre = CGPoint(x: 170, y: 262), appsCentre = CGPoint(x: 490, y: 262)

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dmg-background.png"
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let ns = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ns
let c = ns.cgContext
c.scaleBy(x: scale, y: scale)
// Draw in Finder's top-left coordinates.
c.translateBy(x: 0, y: H); c.scaleBy(x: 1, y: -1)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}
let space = CGColorSpace(name: CGColorSpace.sRGB)!

// Night sky: deep indigo at the top to near black.
c.drawLinearGradient(CGGradient(colorsSpace: space, colors: [rgb(0.17, 0.13, 0.36), rgb(0.04, 0.04, 0.09)] as CFArray,
                                locations: [0, 1])!,
                     start: .zero, end: CGPoint(x: 0, y: H), options: [])
// The island's warm glow, and a cooler one where the arrow lands.
func glow(_ at: CGPoint, _ radius: CGFloat, _ color: CGColor) {
    c.drawRadialGradient(CGGradient(colorsSpace: space, colors: [color, color.copy(alpha: 0)!] as CFArray,
                                    locations: [0, 1])!,
                         startCenter: at, startRadius: 0, endCenter: at, endRadius: radius, options: [])
}
glow(CGPoint(x: W / 2, y: 26), 260, rgb(1, 0.6, 0.22, 0.42))
glow(appsCentre, 200, rgb(0.45, 0.4, 1, 0.22))

// A few stars.
var seed: UInt64 = 7
func random() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
for _ in 0..<70 {
    let p = CGPoint(x: random() * W, y: random() * H * 0.85)
    let r = 0.4 + random() * 1.1
    c.setFillColor(rgb(1, 1, 1, 0.15 + random() * 0.45))
    c.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
}

// The Dynamic Island hanging from the top edge, mid-reading.
let island = CGRect(x: W / 2 - 118, y: 14, width: 236, height: 40)
c.saveGState()
c.setShadow(offset: .zero, blur: 22, color: rgb(1, 0.6, 0.25, 0.75))
c.addPath(CGPath(roundedRect: island, cornerWidth: 20, cornerHeight: 20, transform: nil))
c.setFillColor(rgb(0, 0, 0)); c.fillPath()
c.restoreGState()
c.addPath(CGPath(roundedRect: island, cornerWidth: 20, cornerHeight: 20, transform: nil))
c.setStrokeColor(rgb(1, 1, 1, 0.12)); c.setLineWidth(1); c.strokePath()
// Waveform on the left (the assistant listening).
for (i, h) in [8.0, 16, 11, 20, 9, 14].enumerated() {
    let x = island.minX + 20 + CGFloat(i) * 6
    c.addPath(CGPath(roundedRect: CGRect(x: x, y: island.midY - h / 2, width: 3, height: h), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
}
c.setFillColor(rgb(0.72, 0.62, 1)); c.fillPath()
// Camera lens on the right.
c.setFillColor(rgb(0.13, 0.13, 0.2)); c.fillEllipse(in: CGRect(x: island.maxX - 32, y: island.midY - 8, width: 16, height: 16))
c.setFillColor(rgb(0.25, 0.3, 0.55)); c.fillEllipse(in: CGRect(x: island.maxX - 27, y: island.midY - 3, width: 6, height: 6))

// Text, drawn with AppKit, which expects a flipped context here.
NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, y: CGFloat, kern: CGFloat = 0) {
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                .foregroundColor: color, .kern: kern]
    let s = NSAttributedString(string: string, attributes: attrs)
    s.draw(at: NSPoint(x: (W - s.size().width) / 2, y: y))
}
let said = NSAttributedString(string: "“Hey, put on some focus music”", attributes: [
    .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor(calibratedRed: 0.82, green: 0.76, blue: 1, alpha: 1)])
said.draw(at: NSPoint(x: island.minX + 64, y: island.midY - said.size().height / 2))
text("Drag Islet into Applications", size: 25, weight: .bold, color: .white, y: 72)
text("Then open it from Applications, and hold ⌃ control + ⌥ option to talk to it.",
     size: 12.5, weight: .medium, color: NSColor(white: 1, alpha: 0.66), y: 106)

// Light pads under the two icons, so Finder's black labels stay readable.
func pad(_ centre: CGPoint) {
    let r = CGRect(x: centre.x - 92, y: centre.y - 84, width: 184, height: 172)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: 6), blur: 24, color: rgb(0, 0, 0, 0.45))
    c.addPath(CGPath(roundedRect: r, cornerWidth: 26, cornerHeight: 26, transform: nil))
    c.setFillColor(rgb(0.93, 0.91, 1, 0.9)); c.fillPath()
    c.restoreGState()
}
pad(appCentre); pad(appsCentre)

// The arrow: a glowing arc from the app to Applications.
let start = CGPoint(x: appCentre.x + 104, y: appCentre.y - 6)
let end = CGPoint(x: appsCentre.x - 112, y: appsCentre.y - 6)
let control = CGPoint(x: W / 2, y: appCentre.y - 64)
let arc = CGMutablePath(); arc.move(to: start); arc.addQuadCurve(to: end, control: control)
c.saveGState()
c.setShadow(offset: .zero, blur: 14, color: rgb(1, 0.62, 0.25, 0.9))
c.addPath(arc)
c.setStrokeColor(rgb(1, 0.68, 0.3)); c.setLineWidth(5); c.setLineCap(.round)
c.setLineDash(phase: 0, lengths: [1, 11])
c.strokePath()
c.restoreGState()
// Arrowhead along the curve's final direction.
let angle = atan2(end.y - control.y, end.x - control.x)
let head = CGMutablePath()
head.move(to: CGPoint(x: end.x + cos(angle) * 10, y: end.y + sin(angle) * 10))
head.addLine(to: CGPoint(x: end.x + cos(angle + 2.5) * 13, y: end.y + sin(angle + 2.5) * 13))
head.addLine(to: CGPoint(x: end.x + cos(angle - 2.5) * 13, y: end.y + sin(angle - 2.5) * 13))
head.closeSubpath()
c.saveGState()
c.setShadow(offset: .zero, blur: 10, color: rgb(1, 0.62, 0.25, 0.9))
c.addPath(head); c.setFillColor(rgb(1, 0.68, 0.3)); c.fillPath()
c.restoreGState()

// Feature line along the bottom.
text("ASSISTANT  ·  TELEPROMPTER  ·  VIDEO DOWNLOADER  ·  AND 70+ MAC TOOLS",
     size: 10, weight: .semibold, color: NSColor(white: 1, alpha: 0.42), y: 404, kern: 1.4)

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: out))

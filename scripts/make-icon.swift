// Draws the JadyxDrop app icon and writes Resources/AppIcon.icns.
// usage: swift scripts/make-icon.swift   (run from the repo root)
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    // macOS icon grid: 824×824 body centred in 1024 with a soft shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(squircle); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(red: 0.10, green: 0.82, blue: 0.62, alpha: 1).cgColor,   // mint
        NSColor(red: 0.09, green: 0.46, blue: 0.86, alpha: 1).cgColor,   // azure
        NSColor(red: 0.30, green: 0.18, blue: 0.70, alpha: 1).cgColor,   // violet
    ] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 160, y: 940), end: CGPoint(x: 880, y: 80), options: [])
    // soft top highlight
    let hi = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor.white.withAlphaComponent(0.22).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(hi, startCenter: CGPoint(x: 360, y: 860), startRadius: 0,
                           endCenter: CGPoint(x: 360, y: 860), endRadius: 560, options: [])
    ctx.restoreGState()

    // Game cartridge card (white) with a notched top-right corner and label window.
    let card = CGMutablePath()
    let cx: CGFloat = 322, cy: CGFloat = 300, cw: CGFloat = 380, ch: CGFloat = 470, r: CGFloat = 46, notch: CGFloat = 70
    card.move(to: CGPoint(x: cx + r, y: cy))
    card.addLine(to: CGPoint(x: cx + cw - r, y: cy))
    card.addQuadCurve(to: CGPoint(x: cx + cw, y: cy + r), control: CGPoint(x: cx + cw, y: cy))
    card.addLine(to: CGPoint(x: cx + cw, y: cy + ch - notch))
    card.addLine(to: CGPoint(x: cx + cw - notch, y: cy + ch))
    card.addLine(to: CGPoint(x: cx + r, y: cy + ch))
    card.addQuadCurve(to: CGPoint(x: cx, y: cy + ch - r), control: CGPoint(x: cx, y: cy + ch))
    card.addLine(to: CGPoint(x: cx, y: cy + r))
    card.addQuadCurve(to: CGPoint(x: cx + r, y: cy), control: CGPoint(x: cx, y: cy))
    card.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.addPath(card); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
    ctx.restoreGState()

    // Contact ridges at the bottom of the cartridge.
    ctx.setFillColor(NSColor(red: 0.80, green: 0.86, blue: 0.93, alpha: 1).cgColor)
    for i in 0..<6 {
        ctx.fill(CGRect(x: cx + 62 + CGFloat(i) * 46, y: cy + 34, width: 26, height: 54))
    }

    // Down arrow on the label, in the background gradient colours.
    let arrow = CGMutablePath()
    let ax: CGFloat = 512, top: CGFloat = 700, stemW: CGFloat = 70, headW: CGFloat = 210, headTop: CGFloat = 545, tip: CGFloat = 420
    arrow.move(to: CGPoint(x: ax - stemW / 2, y: top))
    arrow.addLine(to: CGPoint(x: ax + stemW / 2, y: top))
    arrow.addLine(to: CGPoint(x: ax + stemW / 2, y: headTop))
    arrow.addLine(to: CGPoint(x: ax + headW / 2, y: headTop))
    arrow.addLine(to: CGPoint(x: ax, y: tip))
    arrow.addLine(to: CGPoint(x: ax - headW / 2, y: headTop))
    arrow.addLine(to: CGPoint(x: ax - stemW / 2, y: headTop))
    arrow.closeSubpath()
    ctx.saveGState()
    ctx.addPath(arrow); ctx.clip()
    ctx.drawLinearGradient(bg, start: CGPoint(x: ax, y: top), end: CGPoint(x: ax, y: tip), options: [])
    ctx.restoreGState()

    // Tray line under the cartridge (where it "drops" to).
    let tray = CGPath(roundedRect: CGRect(x: 262, y: 196, width: 500, height: 40), cornerWidth: 20, cornerHeight: 20, transform: nil)
    ctx.addPath(tray); ctx.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor); ctx.fillPath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try fm.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
try render(1024).write(to: URL(fileURLWithPath: "Resources/AppIcon-1024.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")

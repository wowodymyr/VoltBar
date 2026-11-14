// Generates Resources/AppIcon.icns: a yellow lightning bolt on a dark rounded square.
// Usage: swift Tools/make-icon.swift <output.icns>

import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns"

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let s = CGFloat(px) / 1024.0
    let t = NSAffineTransform(); t.scale(by: s); t.concat()

    // Background tile (macOS icon grid: 824×824, centered, corner radius ≈ 185).
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 24
    shadow.set()
    NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.20, alpha: 1).setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(calibratedRed: 0.22, green: 0.24, blue: 0.28, alpha: 1),
               ending: NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.11, alpha: 1))!
        .draw(in: tilePath, angle: -90)

    // Lightning bolt.
    let bolt = NSBezierPath()
    bolt.move(to: NSPoint(x: 598, y: 860))
    bolt.line(to: NSPoint(x: 300, y: 480))
    bolt.line(to: NSPoint(x: 492, y: 480))
    bolt.line(to: NSPoint(x: 426, y: 164))
    bolt.line(to: NSPoint(x: 724, y: 552))
    bolt.line(to: NSPoint(x: 532, y: 552))
    bolt.close()
    bolt.lineJoinStyle = .round

    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = NSColor(calibratedRed: 1, green: 0.78, blue: 0.1, alpha: 0.55)
    glow.shadowOffset = .zero
    glow.shadowBlurRadius = 60
    glow.set()
    NSColor(calibratedRed: 1, green: 0.8, blue: 0.1, alpha: 1).setFill()
    bolt.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: NSColor(calibratedRed: 1.0, green: 0.92, blue: 0.35, alpha: 1),
               ending: NSColor(calibratedRed: 1.0, green: 0.66, blue: 0.0, alpha: 1))!
        .draw(in: bolt, angle: -90)
    NSColor(calibratedRed: 0.85, green: 0.52, blue: 0.0, alpha: 1).setStroke()
    bolt.lineWidth = 10
    bolt.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = NSTemporaryDirectory() + "VoltBar-\(getpid()).iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", out]
try! p.run(); p.waitUntilExit()
try? fm.removeItem(atPath: iconset)
if p.terminationStatus != 0 { fputs("iconutil failed\n", stderr); exit(1) }
print("Icon written: \(out)")

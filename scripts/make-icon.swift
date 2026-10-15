// Renders Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
import AppKit

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    // macOS icon grid: 824pt body centred in 1024.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    // A flat fill keeps the PNGs, and so the app, small.
    NSColor(red: 0.27, green: 0.42, blue: 0.96, alpha: 1).setFill()
    shape.fill()
    // Menu bar strip.
    let strip = NSRect(x: 190 * s, y: 560 * s, width: 644 * s, height: 150 * s)
    NSColor.white.withAlphaComponent(0.22).setFill()
    NSBezierPath(roundedRect: strip, xRadius: 75 * s, yRadius: 75 * s).fill()
    // Visible items.
    NSColor.white.setFill()
    for x in [560.0, 650.0, 740.0] {
        NSBezierPath(ovalIn: NSRect(x: x * s, y: 605 * s, width: 60 * s, height: 60 * s)).fill()
    }
    // Hidden items tucked below.
    NSColor.white.withAlphaComponent(0.55).setFill()
    for x in [250.0, 340.0, 430.0] {
        NSBezierPath(ovalIn: NSRect(x: x * s, y: 330 * s, width: 60 * s, height: 60 * s)).fill()
    }
    // Chevron.
    let chevron = NSBezierPath()
    chevron.move(to: NSPoint(x: 330 * s, y: 525 * s))
    chevron.line(to: NSPoint(x: 400 * s, y: 455 * s))
    chevron.line(to: NSPoint(x: 470 * s, y: 525 * s))
    chevron.lineWidth = 34 * s
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    NSColor.white.setStroke()
    chevron.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = render(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try! data.write(to: iconset.appendingPathComponent(name))
    }
}

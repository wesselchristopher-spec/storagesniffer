// Renders Resources/AppIcon.icns: a rounded tile with a small treemap.
// Usage: swift scripts/make-icon.swift
import AppKit

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = body.width * 0.225

    // Base plate.
    let plate = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    NSGradient(starting: NSColor(calibratedRed: 0.13, green: 0.15, blue: 0.22, alpha: 1),
               ending: NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.12, alpha: 1))!
        .draw(in: plate, angle: -90)

    // Treemap tiles (unit coordinates inside the plate, origin bottom-left).
    let tiles: [(CGFloat, CGFloat, CGFloat, CGFloat, NSColor)] = [
        (0.00, 0.00, 0.58, 1.00, NSColor(calibratedHue: 0.59, saturation: 0.62, brightness: 0.92, alpha: 1)),
        (0.58, 0.45, 0.42, 0.55, NSColor(calibratedHue: 0.08, saturation: 0.66, brightness: 0.95, alpha: 1)),
        (0.58, 0.00, 0.24, 0.45, NSColor(calibratedHue: 0.40, saturation: 0.55, brightness: 0.82, alpha: 1)),
        (0.82, 0.20, 0.18, 0.25, NSColor(calibratedHue: 0.83, saturation: 0.50, brightness: 0.88, alpha: 1)),
        (0.82, 0.00, 0.18, 0.20, NSColor(calibratedHue: 0.14, saturation: 0.55, brightness: 0.95, alpha: 1)),
    ]
    let pad = body.width * 0.09
    let area = body.insetBy(dx: pad, dy: pad)
    let gap = body.width * 0.025
    for (x, y, w, h, color) in tiles {
        let r = NSRect(x: area.minX + x * area.width, y: area.minY + y * area.height,
                       width: w * area.width, height: h * area.height).insetBy(dx: gap / 2, dy: gap / 2)
        let path = NSBezierPath(roundedRect: r, xRadius: body.width * 0.04, yRadius: body.width * 0.04)
        NSGradient(starting: color.blended(withFraction: 0.18, of: .white)!, ending: color)!
            .draw(in: path, angle: -90)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = NSTemporaryDirectory() + "AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(size: base).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(base)x\(base).png"))
    try! render(size: base * 2).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset, "-o", "Resources/AppIcon.icns"]
try! task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")

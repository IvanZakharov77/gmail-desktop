// Draws a simple envelope icon and writes Resources/AppIcon.icns.
import AppKit
let set = "build/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
for (size, name) in [(16,"16x16"),(32,"16x16@2x"),(32,"32x32"),(64,"32x32@2x"),(128,"128x128"),(256,"128x128@2x"),(256,"256x256"),(512,"256x256@2x"),(512,"512x512"),(1024,"512x512@2x")] {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let bg = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s - 2*inset, height: s - 2*inset), xRadius: s*0.18, yRadius: s*0.18)
    NSColor.white.setFill(); bg.fill()
    let env = NSRect(x: s*0.22, y: s*0.3, width: s*0.56, height: s*0.4)
    let lw = max(1, s*0.06)
    let flap = NSBezierPath(); flap.lineWidth = lw; flap.lineJoinStyle = .round; flap.lineCapStyle = .round
    flap.move(to: NSPoint(x: env.minX, y: env.minY)); flap.line(to: NSPoint(x: env.minX, y: env.maxY))
    flap.line(to: NSPoint(x: env.midX, y: env.midY - s*0.02)); flap.line(to: NSPoint(x: env.maxX, y: env.maxY))
    flap.line(to: NSPoint(x: env.maxX, y: env.minY))
    NSColor(red: 0.92, green: 0.26, blue: 0.21, alpha: 1).setStroke(); flap.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(set)/icon_\(name).png"))
}

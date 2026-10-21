// Editable vector master for the app icon. Run with: swift render-icon.swift output.png
import AppKit

let size = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let context = NSGraphicsContext.current!.cgContext
context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// macOS icon safe area, with transparent corners and a restrained drop shadow.
let tile = NSBezierPath(roundedRect: NSRect(x: 96, y: 96, width: 832, height: 832),
                        xRadius: 188, yRadius: 188)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
shadow.shadowBlurRadius = 26
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
color(19, 36, 64).setFill()
tile.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: color(40, 66, 103), ending: color(14, 28, 50))!.draw(in: tile, angle: -70)
color(255, 255, 255, 0.13).setStroke()
tile.lineWidth = 2
tile.stroke()

// One continuous W: two peers connected through a central routing junction.
// Broad strokes and generous counters retain their silhouette at 16–32 px.
func route(_ points: [NSPoint], _ ink: NSColor) {
    let path = NSBezierPath()
    path.move(to: points[0])
    for p in points.dropFirst() { path.line(to: p) }
    path.lineWidth = 78
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    ink.setStroke()
    path.stroke()
}
let left = NSPoint(x: 282, y: 650)
let valleyL = NSPoint(x: 390, y: 370)
let junction = NSPoint(x: 512, y: 592)
let valleyR = NSPoint(x: 634, y: 370)
let right = NSPoint(x: 742, y: 650)
route([left, valleyL, junction, valleyR], color(241, 247, 255))
route([valleyR, right], color(109, 231, 208))

// Small inset in the mint terminal makes the endpoint read as a connector.
color(23, 49, 69).setFill()
NSBezierPath(ovalIn: NSRect(x: right.x - 13, y: right.y - 13, width: 26, height: 26)).fill()

NSGraphicsContext.restoreGraphicsState()
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try bitmap.representation(using: .png, properties: [:])!.write(to: destination)

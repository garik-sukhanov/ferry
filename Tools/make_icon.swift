#!/usr/bin/env swift
import AppKit

// Renders the app icon: a rounded squircle with the two-way transfer arrows.
func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); return image }

    let inset = size * 0.055
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.225, yRadius: size * 0.225)

    ctx.saveGState()
    path.addClip()
    let colors = [NSColor(calibratedRed: 0.23, green: 0.51, blue: 0.96, alpha: 1).cgColor,
                  NSColor(calibratedRed: 0.11, green: 0.29, blue: 0.75, alpha: 1).cgColor]
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colors as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: size),
                               end: CGPoint(x: size, y: 0),
                               options: [])
    }
    ctx.restoreGState()

    // Two arrows: one heading up, one heading down.
    let stroke = size * 0.075
    NSColor.white.setStroke()
    NSColor.white.setFill()

    func arrow(x: CGFloat, up: Bool) {
        let top = size * 0.735, bottom = size * 0.265
        let shaft = NSBezierPath()
        shaft.lineWidth = stroke
        shaft.lineCapStyle = .round
        shaft.move(to: CGPoint(x: x, y: up ? bottom : top))
        shaft.line(to: CGPoint(x: x, y: up ? top - size * 0.09 : bottom + size * 0.09))
        shaft.stroke()

        let tipY = up ? top : bottom
        let dir: CGFloat = up ? -1 : 1
        let head = NSBezierPath()
        head.move(to: CGPoint(x: x, y: tipY))
        head.line(to: CGPoint(x: x - size * 0.105, y: tipY + dir * size * 0.115))
        head.line(to: CGPoint(x: x + size * 0.105, y: tipY + dir * size * 0.115))
        head.close()
        head.fill()
    }

    arrow(x: size * 0.375, up: true)
    arrow(x: size * 0.625, up: false)

    image.unlockFocus()
    return image
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let img = drawIcon(size: CGFloat(size))
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    let scale = size >= 32 && [32, 64, 256, 512, 1024].contains(size)
    let base = "\(outDir)/icon_\(size)x\(size).png"
    try? png.write(to: URL(fileURLWithPath: base))
    _ = scale
}
print("icons written to \(outDir)")

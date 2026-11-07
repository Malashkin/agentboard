// AgentBoard logo: a hero mask (agents are superheroes) with glowing AI eyes over three board columns.
// Usage: swift scripts/make-icon.swift <out.iconset> [preview.png]
import AppKit

func maskPath(_ r: NSRect) -> NSBezierPath {
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
    let m = NSBezierPath()
    m.move(to: p(-0.02, 0.80))
    m.curve(to: p(0.5, 0.84), controlPoint1: p(0.14, 0.96), controlPoint2: p(0.36, 0.96))
    m.curve(to: p(1.02, 0.80), controlPoint1: p(0.64, 0.96), controlPoint2: p(0.86, 0.96))
    m.curve(to: p(0.70, 0.06), controlPoint1: p(1.00, 0.40), controlPoint2: p(0.90, 0.04))
    m.curve(to: p(0.5, 0.28), controlPoint1: p(0.58, 0.08), controlPoint2: p(0.55, 0.28))
    m.curve(to: p(0.30, 0.06), controlPoint1: p(0.45, 0.28), controlPoint2: p(0.42, 0.08))
    m.curve(to: p(-0.02, 0.80), controlPoint1: p(0.10, 0.04), controlPoint2: p(0.00, 0.40))
    m.close()
    return m
}

func eyePath(_ r: NSRect, left: Bool) -> NSBezierPath {
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        let xx = left ? x : 1 - x
        return NSPoint(x: r.minX + xx * r.width, y: r.minY + y * r.height)
    }
    let e = NSBezierPath()
    e.move(to: p(0.17, 0.56))
    e.curve(to: p(0.43, 0.52), controlPoint1: p(0.24, 0.70), controlPoint2: p(0.38, 0.68))
    e.curve(to: p(0.17, 0.56), controlPoint1: p(0.36, 0.40), controlPoint2: p(0.22, 0.42))
    e.close()
    return e
}

func draw(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high

    // macOS icon grid: 824/1024 body with soft shadow.
    let inset = s * 0.098
    let body = NSRect(x: inset, y: inset * 1.15, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    bg.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    bg.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.33, green: 0.20, blue: 0.85, alpha: 1),
                        NSColor(srgbRed: 0.13, green: 0.11, blue: 0.36, alpha: 1),
                        NSColor(srgbRed: 0.05, green: 0.06, blue: 0.16, alpha: 1)],
               atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: body, angle: -90)
    // Soft light from above.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSBezierPath(ovalIn: NSRect(x: body.minX - body.width * 0.2, y: body.midY, width: body.width * 1.4, height: body.height * 0.9)),
              relativeCenterPosition: NSPoint(x: 0, y: 0.3))

    // Mask.
    let mr = NSRect(x: body.minX + body.width * 0.12, y: body.minY + body.height * 0.36,
                    width: body.width * 0.76, height: body.height * 0.42)
    let mask = maskPath(mr)
    NSGraphicsContext.saveGraphicsState()
    let ms = NSShadow()
    ms.shadowColor = NSColor.black.withAlphaComponent(0.45)
    ms.shadowBlurRadius = s * 0.03
    ms.shadowOffset = NSSize(width: 0, height: -s * 0.015)
    ms.set()
    NSColor.white.setFill()
    mask.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor.white, NSColor(srgbRed: 0.84, green: 0.86, blue: 0.96, alpha: 1)])!.draw(in: mask, angle: -90)

    // Glowing eyes.
    for left in [true, false] {
        let eye = eyePath(mr, left: left)
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = NSColor(srgbRed: 0.25, green: 0.95, blue: 1.0, alpha: 0.95)
        glow.shadowBlurRadius = s * 0.035
        glow.set()
        NSColor(srgbRed: 0.20, green: 0.88, blue: 1.0, alpha: 1).setFill()
        eye.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(colors: [NSColor(srgbRed: 0.75, green: 1.0, blue: 1.0, alpha: 1),
                            NSColor(srgbRed: 0.10, green: 0.75, blue: 1.0, alpha: 1)])!.draw(in: eye, angle: -90)
    }

    // Board: three columns of cards = agents by status (working / waiting / idle).
    let colors = [NSColor(srgbRed: 0.24, green: 0.86, blue: 0.47, alpha: 1),
                  NSColor(srgbRed: 1.0, green: 0.66, blue: 0.16, alpha: 1),
                  NSColor(srgbRed: 0.35, green: 0.62, blue: 1.0, alpha: 1)]
    let cards = [3, 1, 2]
    let colW = body.width * 0.17, gap = body.width * 0.05
    let cardH = body.height * 0.052, cardGap = body.height * 0.022
    let startX = body.midX - (3 * colW + 2 * gap) / 2
    let topY = body.minY + body.height * 0.30
    for i in 0..<3 {
        let x = startX + CGFloat(i) * (colW + gap)
        // column lane
        let laneH = 3 * cardH + 2 * cardGap + body.height * 0.03
        let lane = NSRect(x: x - body.width * 0.012, y: topY - laneH, width: colW + body.width * 0.024, height: laneH + body.height * 0.012)
        NSColor.white.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: lane, xRadius: colW * 0.18, yRadius: colW * 0.18).fill()
        for c in 0..<cards[i] {
            let y = topY - CGFloat(c + 1) * cardH - CGFloat(c) * cardGap - body.height * 0.004
            let r = NSRect(x: x, y: y, width: colW, height: cardH)
            colors[i].withAlphaComponent(c == 0 ? 1 : 0.55).setFill()
            NSBezierPath(roundedRect: r, xRadius: cardH * 0.35, yRadius: cardH * 0.35).fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()

    // Thin inner border.
    NSColor.white.withAlphaComponent(0.12).setStroke()
    bg.lineWidth = max(1, s * 0.004)
    bg.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! draw(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! draw(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
if CommandLine.arguments.count > 2 {
    try! draw(1024).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}

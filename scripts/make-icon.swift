// AgentBoard logo: several agent terminals fanned out, each with a status light; the front one shows a green prompt.
// Usage: swift scripts/make-icon.swift <out.iconset> [preview.png]
import AppKit

func c(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
func withShadow(_ color: NSColor, _ blur: CGFloat, _ dy: CGFloat = 0, _ f: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = color; sh.shadowBlurRadius = blur; sh.shadowOffset = NSSize(width: 0, height: dy); sh.set()
    f()
    NSGraphicsContext.restoreGraphicsState()
}

func render(_ size: Int, bg: [NSColor], _ content: (NSRect, CGFloat) -> Void) -> NSBitmapImageRep {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    let inset = s * 0.098
    let body = NSRect(x: inset, y: inset * 1.15, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    withShadow(.black.withAlphaComponent(0.35), s * 0.025, -s * 0.012) { NSColor.black.setFill(); shape.fill() }
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: bg)!.draw(in: body, angle: -90)
    content(body, s)
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.12).setStroke(); shape.lineWidth = max(1, s * 0.004); shape.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let green = c(0x3DDC78), orange = c(0xFFA829), blue = c(0x5A9EFF)

// B — «Терминалы»: несколько окон-агентов веером, на переднем курсор, у каждого статус-огонёк.
func terminals(_ size: Int) -> NSBitmapImageRep {
    render(size, bg: [c(0x2B2D35), c(0x16171C), c(0x0B0B0E)]) { b, s in
        let w = b.width * 0.56, h = b.height * 0.42
        let offs: [(CGFloat, CGFloat, NSColor)] = [(-0.13, 0.14, blue), (0.0, 0.05, orange), (0.11, -0.05, green)]
        for (i, (dx, dy, col)) in offs.enumerated() {
            let r = NSRect(x: b.midX - w / 2 + dx * b.width, y: b.midY - h / 2 + dy * b.height - b.height * 0.03, width: w, height: h)
            let p = NSBezierPath(roundedRect: r, xRadius: w * 0.09, yRadius: w * 0.09)
            let front = i == offs.count - 1
            withShadow(.black.withAlphaComponent(0.6), s * 0.035, -s * 0.012) {
                (front ? c(0x1E2028) : c(0x2A2D38)).setFill(); p.fill()
            }
            NSGraphicsContext.saveGraphicsState(); p.addClip()
            let bar = NSRect(x: r.minX, y: r.maxY - h * 0.2, width: w, height: h * 0.2)
            (front ? c(0x343846) : c(0x3A3E4C)).setFill(); bar.fill()
            NSGraphicsContext.restoreGraphicsState()
            c(0xFFFFFF, 0.10).setStroke(); p.lineWidth = s * 0.004; p.stroke()
            let d = h * 0.1
            let dot = NSBezierPath(ovalIn: NSRect(x: r.minX + w * 0.07, y: bar.midY - d / 2, width: d, height: d))
            withShadow(col, s * 0.03) { col.setFill(); dot.fill() }
            if front {
                let font = NSFont.monospacedSystemFont(ofSize: h * 0.36, weight: .heavy)
                let str = NSAttributedString(string: ">_", attributes: [.font: font, .foregroundColor: green])
                withShadow(green.withAlphaComponent(0.8), s * 0.03) {
                    str.draw(at: NSPoint(x: r.minX + w * 0.1, y: r.minY + h * 0.22))
                }
                for (j, lw) in [0.32, 0.22].enumerated() {
                    let lr = NSRect(x: r.minX + w * 0.52, y: r.minY + h * (0.48 - CGFloat(j) * 0.17), width: w * lw, height: h * 0.07)
                    c(0xFFFFFF, 0.25).setFill(); NSBezierPath(roundedRect: lr, xRadius: lr.height / 2, yRadius: lr.height / 2).fill()
                }
            }
        }
    }
}

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! terminals(base).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! terminals(base * 2).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
if CommandLine.arguments.count > 2 {
    try! terminals(1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}

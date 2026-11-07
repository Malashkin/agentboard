// Draws the app icon into an .iconset folder: swift scripts/make-icon.swift <out.iconset>
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func draw(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.22, alpha: 1),
                        NSColor(calibratedRed: 0.20, green: 0.16, blue: 0.42, alpha: 1)])!.draw(in: bg, angle: -90)
    // Three columns of a board.
    let colors: [NSColor] = [.systemGreen, .systemOrange, .systemBlue]
    let colW = rect.width * 0.2, gap = rect.width * 0.08
    let startX = rect.minX + (rect.width - 3 * colW - 2 * gap) / 2
    let heights: [CGFloat] = [0.55, 0.38, 0.47]
    for i in 0..<3 {
        let x = startX + CGFloat(i) * (colW + gap)
        let top = rect.maxY - rect.height * 0.2
        var y = top
        let cards = i == 1 ? 2 : 3
        for c in 0..<cards {
            let h = rect.height * heights[i] / CGFloat(cards) - rect.height * 0.025
            y -= h + rect.height * 0.03
            let card = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: colW, height: h), xRadius: colW * 0.15, yRadius: colW * 0.15)
            colors[i].withAlphaComponent(c == 0 ? 1 : 0.55).setFill()
            card.fill()
        }
    }
    // Dots = agents.
    for i in 0..<3 {
        let d = rect.width * 0.09
        let x = startX + CGFloat(i) * (colW + gap) + (colW - d) / 2
        let dot = NSBezierPath(ovalIn: NSRect(x: x, y: rect.minY + rect.height * 0.1, width: d, height: d))
        NSColor.white.withAlphaComponent(0.9).setFill()
        dot.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! draw(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! draw(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}

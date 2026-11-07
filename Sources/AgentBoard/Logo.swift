import AppKit

/// The hero mask from the app icon, as a menu bar template image.
enum Logo {
    static let menuBarImage: NSImage = {
        let size = NSSize(width: 22, height: 16)
        let img = NSImage(size: size, flipped: false) { rect in
            let r = rect.insetBy(dx: 0.5, dy: 1.5)
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
            let m = NSBezierPath()
            m.move(to: p(0.0, 0.92))
            m.curve(to: p(0.5, 0.94), controlPoint1: p(0.16, 1.06), controlPoint2: p(0.36, 1.06))
            m.curve(to: p(1.0, 0.92), controlPoint1: p(0.64, 1.06), controlPoint2: p(0.84, 1.06))
            m.curve(to: p(0.70, 0.0), controlPoint1: p(0.98, 0.40), controlPoint2: p(0.90, 0.0))
            m.curve(to: p(0.5, 0.26), controlPoint1: p(0.58, 0.02), controlPoint2: p(0.55, 0.26))
            m.curve(to: p(0.30, 0.0), controlPoint1: p(0.45, 0.26), controlPoint2: p(0.42, 0.02))
            m.curve(to: p(0.0, 0.92), controlPoint1: p(0.10, 0.0), controlPoint2: p(0.02, 0.40))
            m.close()
            for left in [true, false] {
                func q(_ x: CGFloat, _ y: CGFloat) -> NSPoint { p(left ? x : 1 - x, y) }
                m.move(to: q(0.15, 0.58))
                m.curve(to: q(0.44, 0.52), controlPoint1: q(0.22, 0.76), controlPoint2: q(0.38, 0.74))
                m.curve(to: q(0.15, 0.58), controlPoint1: q(0.36, 0.36), controlPoint2: q(0.21, 0.38))
                m.close()
            }
            m.windingRule = .evenOdd
            NSColor.black.setFill()
            m.fill()
            return true
        }
        img.isTemplate = true
        return img
    }()
}

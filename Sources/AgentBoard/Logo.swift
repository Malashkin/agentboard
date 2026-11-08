import AppKit

/// The app icon's fanned terminals as a menu bar template image: a back window outline
/// and a solid front window with a `>_` prompt cut out of it.
enum Logo {
    static let menuBarImage: NSImage = {
        let img = NSImage(size: NSSize(width: 22, height: 16), flipped: false) { _ in
            NSColor.black.set()
            let back = NSBezierPath(roundedRect: NSRect(x: 2.5, y: 6.5, width: 13, height: 8.5), xRadius: 2, yRadius: 2)
            back.lineWidth = 1.3
            back.stroke()
            let front = NSRect(x: 6, y: 1, width: 15, height: 10.5)
            let ctx = NSGraphicsContext.current
            // Transparent gap around the front window so it reads as lying on top.
            ctx?.compositingOperation = .clear
            NSBezierPath(roundedRect: front.insetBy(dx: -1.3, dy: -1.3), xRadius: 3, yRadius: 3).fill()
            ctx?.compositingOperation = .sourceOver
            NSBezierPath(roundedRect: front, xRadius: 2.2, yRadius: 2.2).fill()
            // Cut the prompt out so the menu bar shows through.
            ctx?.compositingOperation = .clear
            let chevron = NSBezierPath()
            chevron.move(to: NSPoint(x: 9, y: 8.3))
            chevron.line(to: NSPoint(x: 11.8, y: 6))
            chevron.line(to: NSPoint(x: 9, y: 3.7))
            chevron.lineWidth = 1.5
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            chevron.stroke()
            NSBezierPath(roundedRect: NSRect(x: 13, y: 3.2, width: 4.5, height: 1.5), xRadius: 0.7, yRadius: 0.7).fill()
            return true
        }
        img.isTemplate = true
        return img
    }()
}

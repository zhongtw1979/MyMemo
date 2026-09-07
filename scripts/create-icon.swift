import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let p = CGFloat(pixels)
        let rectangle = NSRect(x: p * 0.07, y: p * 0.07, width: p * 0.86, height: p * 0.86)
        let shape = NSBezierPath(roundedRect: rectangle, xRadius: p * 0.21, yRadius: p * 0.21)
        NSGradient(starting: NSColor(red: 0.12, green: 0.58, blue: 0.46, alpha: 1), ending: NSColor(red: 0.05, green: 0.31, blue: 0.32, alpha: 1))!.draw(in: shape, angle: -60)
        NSColor.white.setStroke()
        for (index, height) in [0.16, 0.33, 0.48, 0.28, 0.40, 0.19].enumerated() {
            let x = p * (0.275 + Double(index) * 0.09)
            let line = NSBezierPath(); line.lineWidth = p * 0.045; line.lineCapStyle = .round
            line.move(to: NSPoint(x: x, y: p * (0.5 - height / 2)))
            line.line(to: NSPoint(x: x, y: p * (0.5 + height / 2))); line.stroke()
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}

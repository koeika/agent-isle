import AppKit
import Foundation
let root = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
let pixels = ["  XX   XX  ", " XXXXXXXXX ", "XXXXXXXXXXX", "XXX XXX XXX", "XXX XXX XXX", "XXXXXXXXXXX", " XXXXXXXXX ", "  XX   XX  ", " XX     XX "]
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let side = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let d = CGFloat(side)
        NSColor(red: 0.035, green: 0.07, blue: 0.055, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x:d*0.06,y:d*0.06,width:d*0.88,height:d*0.88), xRadius:d*0.20, yRadius:d*0.20).fill()
        NSColor(red:0.27,green:0.90,blue:0.74,alpha:1).setFill()
        let unit = d / 17
        for (y, row) in pixels.enumerated() {
            for (x, char) in row.enumerated() where char == "X" {
                NSBezierPath(rect:NSRect(x:CGFloat(x+3)*unit,y:CGFloat(12-y)*unit,width:unit*0.92,height:unit*0.92)).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:root).appendingPathComponent(name))
    }
}

// Renders assets/app_icon.svg to a square PNG with a transparent background.
// Usage: swift scripts/render-app-icon.swift <svg> <size> <png>
// For the app icon: swift scripts/render-app-icon.swift assets/app_icon.svg 1024 assets/app_icon.png
// then ./scripts/build-icon.sh
import AppKit

let a = CommandLine.arguments
guard a.count == 4, let size = Int(a[2]),
      let img = NSImage(contentsOf: URL(fileURLWithPath: a[1])), img.isValid else {
    fputs("usage: render-app-icon.swift <svg> <size> <png>\n", stderr); exit(2)
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
img.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[3]))

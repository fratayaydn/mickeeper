// Draws the MicKeeper app icon: a studio microphone kept inside a ring closed by a small padlock, on a dark plum
// rounded square.
// Usage: swift scripts/make-icon.swift <project-dir>
// Writes Resources/AppIcon.icns and .build/AppIcon-preview.png.
import AppKit

let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [UInt32], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: colors.map { color($0) } as CFArray, locations: locations)!
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// Drawn on a 1024 canvas, origin bottom-left.
func drawIcon(_ ctx: CGContext) {
    let body = roundedRect(CGRect(x: 100, y: 100, width: 824, height: 824), 185)

    // Background: dark plum, lighter behind the microphone.
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.drawLinearGradient(gradient([0x3A2050, 0x1F1030, 0x0D0714], [0, 0.55, 1]),
                           start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
    ctx.drawRadialGradient(CGGradient(colorsSpace: sRGB, colors: [color(0xC9A2FF, 0.24), color(0xC9A2FF, 0)] as CFArray,
                                      locations: [0, 1])!,
                           startCenter: CGPoint(x: 512, y: 560), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 560), endRadius: 430, options: [])
    ctx.restoreGState()

    // The microphone, drawn at 70% so the ring fits around it.
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 540)
    ctx.scaleBy(x: 0.7, y: 0.7)
    ctx.translateBy(x: -512, y: -540)
    let silver = gradient([0xFFFFFF, 0xE4DDF0, 0xB9AFCB], [0, 0.55, 1])

    // Microphone head: a capsule with grille slots. Its lower half is a circle around (512, 560).
    let head = roundedRect(CGRect(x: 412, y: 460, width: 200, height: 340), 100)
    ctx.saveGState()
    ctx.addPath(head)
    ctx.clip()
    ctx.drawLinearGradient(silver, start: CGPoint(x: 412, y: 0), end: CGPoint(x: 612, y: 0), options: [])
    ctx.setFillColor(color(0x3A2A4E, 0.55))
    for y in stride(from: 550.0, through: 730.0, by: 45.0) {
        ctx.addPath(roundedRect(CGRect(x: 448, y: y, width: 128, height: 14), 7))
    }
    ctx.fillPath()
    ctx.restoreGState()

    // Holder: a U that follows the head at an even gap (same center as the capsule's lower half), with arms
    // running up beside it, then the stem and the base.
    let holderRadius: CGFloat = 100 + 52
    ctx.setStrokeColor(color(0xEDE6F7))
    ctx.setLineWidth(30)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 512 - holderRadius, y: 605))
    ctx.addLine(to: CGPoint(x: 512 - holderRadius, y: 560))
    ctx.addArc(center: CGPoint(x: 512, y: 560), radius: holderRadius, startAngle: .pi, endAngle: 0, clockwise: false)
    ctx.addLine(to: CGPoint(x: 512 + holderRadius, y: 605))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: 512, y: 560 - holderRadius))
    ctx.addLine(to: CGPoint(x: 512, y: 300))
    ctx.strokePath()
    ctx.addPath(roundedRect(CGRect(x: 402, y: 270, width: 220, height: 36), 18))
    ctx.setFillColor(color(0xEDE6F7))
    ctx.fillPath()
    ctx.restoreGState()

    // A closed ring around the microphone with a small padlock at the bottom: the microphone stays in place.
    ctx.setStrokeColor(color(0xD9C8F2, 0.85))
    ctx.setLineWidth(22)
    ctx.setLineCap(.round)
    ctx.addArc(center: CGPoint(x: 512, y: 540), radius: 300, startAngle: -.pi / 2 + 0.31, endAngle: -.pi / 2 - 0.31, clockwise: false)
    ctx.strokePath()
    let c = CGPoint(x: 512, y: 240)
    ctx.addPath(roundedRect(CGRect(x: c.x - 46, y: c.y - 40, width: 92, height: 72), 14))
    ctx.setFillColor(color(0xD9C8F2))
    ctx.fillPath()
    ctx.setStrokeColor(color(0xD9C8F2))
    ctx.setLineWidth(18)
    ctx.addArc(center: CGPoint(x: c.x, y: c.y + 30), radius: 30, startAngle: 0, endAngle: .pi, clockwise: false)
    ctx.strokePath()
}

func render(_ px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    drawIcon(ctx)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, _ path: String) {
    try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: path))
}

let build = "\(root)/.build"
let iconset = "\(build)/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    writePNG(render(size), "\(iconset)/icon_\(size)x\(size).png")
    writePNG(render(size * 2), "\(iconset)/icon_\(size)x\(size)@2x.png")
}
writePNG(render(1024), "\(build)/AppIcon-preview.png")

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset, "-o", "\(root)/Resources/AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()

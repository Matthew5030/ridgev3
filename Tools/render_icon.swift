import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Original vector artwork. Full-square opaque output lets iOS apply its mask.
// Run: xcrun swift Tools/render_icon.swift
let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = project.appendingPathComponent("ridge v3/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ value: UInt32) -> CGColor {
    CGColor(red: CGFloat((value >> 16) & 255) / 255,
            green: CGFloat((value >> 8) & 255) / 255,
            blue: CGFloat(value & 255) / 255, alpha: 1)
}

func ridgeShape() -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 145, y: 767))
    path.addCurve(to: CGPoint(x: 338, y: 449), control1: CGPoint(x: 206, y: 684), control2: CGPoint(x: 278, y: 534))
    path.addCurve(to: CGPoint(x: 483, y: 247), control1: CGPoint(x: 401, y: 358), control2: CGPoint(x: 433, y: 281))
    path.addCurve(to: CGPoint(x: 558, y: 260), control1: CGPoint(x: 512, y: 221), control2: CGPoint(x: 533, y: 223))
    path.addCurve(to: CGPoint(x: 719, y: 490), control1: CGPoint(x: 606, y: 330), control2: CGPoint(x: 661, y: 411))
    path.addCurve(to: CGPoint(x: 881, y: 765), control1: CGPoint(x: 788, y: 587), control2: CGPoint(x: 833, y: 692))
    path.addCurve(to: CGPoint(x: 859, y: 813), control1: CGPoint(x: 907, y: 802), control2: CGPoint(x: 898, y: 819))
    path.addCurve(to: CGPoint(x: 590, y: 788), control1: CGPoint(x: 770, y: 800), control2: CGPoint(x: 687, y: 755))
    path.addCurve(to: CGPoint(x: 362, y: 813), control1: CGPoint(x: 498, y: 824), control2: CGPoint(x: 459, y: 840))
    path.addCurve(to: CGPoint(x: 168, y: 823), control1: CGPoint(x: 275, y: 791), control2: CGPoint(x: 223, y: 839))
    path.addCurve(to: CGPoint(x: 145, y: 767), control1: CGPoint(x: 125, y: 812), control2: CGPoint(x: 125, y: 797))
    path.closeSubpath()
    return path
}

func drawIcon(size: Int, background: UInt32, foreground: UInt32, filename: String) throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let bitmap = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: space, bitmapInfo: bitmap)!
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    context.translateBy(x: 0, y: 1024)
    context.scaleBy(x: 1, y: -1)
    context.setFillColor(color(background))
    context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    let mountain = ridgeShape()
    context.setFillColor(color(foreground))
    context.addPath(mountain)
    context.fillPath()

    // Contour rings are vector paths with rounded joins, not raster textures.
    for scale in [0.82, 0.63, 0.44, 0.25] {
        var transform = CGAffineTransform(translationX: 512, y: 540)
        transform = transform.scaledBy(x: scale, y: scale)
        transform = transform.translatedBy(x: -512, y: -540)
        let ring = mountain.copy(using: &transform)!
        context.setStrokeColor(color(background))
        context.setLineWidth(16)
        context.setLineJoin(.round)
        context.addPath(ring)
        context.strokePath()
    }

    // One unmistakable route accent and its summit waypoint.
    let route = CGMutablePath()
    route.move(to: CGPoint(x: 306, y: 737))
    route.addCurve(to: CGPoint(x: 404, y: 638), control1: CGPoint(x: 332, y: 685), control2: CGPoint(x: 390, y: 694))
    route.addCurve(to: CGPoint(x: 476, y: 562), control1: CGPoint(x: 416, y: 585), control2: CGPoint(x: 457, y: 607))
    route.addCurve(to: CGPoint(x: 517, y: 476), control1: CGPoint(x: 495, y: 520), control2: CGPoint(x: 533, y: 530))
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(color(0xE58B6D))
    context.setLineWidth(18)
    context.addPath(route)
    context.strokePath()
    context.setFillColor(color(background))
    context.fillEllipse(in: CGRect(x: 485, y: 444, width: 64, height: 64))
    context.setFillColor(color(0xDE795C))
    context.fillEllipse(in: CGRect(x: 494, y: 453, width: 46, height: 46))

    let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent(filename) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "RidgeIcon", code: 1) }
}

try drawIcon(size: 1024, background: 0xF3F0E6, foreground: 0x233D37, filename: "ridge-icon.png")
let contents: [String: Any] = [
    "images": [["filename": "ridge-icon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"]],
    "info": ["author": "xcode", "version": 1]
]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("Contents.json"))
print("Rendered opaque 1024px Ridge AppIcon from native vector paths.")

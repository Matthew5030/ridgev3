// Format-only App Store export of a native Simulator screenshot.
// Preserve the full viewport and pixel dimensions; remove the alpha channel.
import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: export_screenshot input.png output.png")
}
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let context = CGContext(data: nil, width: image.width, height: image.height,
                              bitsPerComponent: 8, bytesPerRow: image.width * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("Cannot decode the native capture")
}
context.setFillColor(CGColor(gray: 1, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
guard let opaque = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Cannot create the export")
}
CGImageDestinationAddImage(destination, opaque, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Cannot save the export") }
print("Exported \(image.width) × \(image.height) RGB screenshot")

import Foundation
import CoreGraphics

/// One shared cartographic style. Output pixels are a disposable render cache;
/// changing the palette never changes or redownloads the underlying map features.
enum WorldCartography {
    static func draw(_ map: WorldVectorMap, pixels: Int) throws -> CGImage {
        guard map.width.isFinite, map.height.isFinite, map.width > 0, map.height > 0,
              [64,128,256,512,1024].contains(pixels), map.paths.count <= 50_000 else { throw RidgeError.message("Invalid vector map.") }
        let size = pixels + 8
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw RidgeError.message("Not enough memory to draw the map.") }
        func color(_ hex: UInt32) -> CGColor { CGColor(srgbRed: CGFloat((hex >> 16) & 255)/255, green: CGFloat((hex >> 8)&255)/255, blue: CGFloat(hex&255)/255, alpha: 1) }
        ctx.setFillColor(color(0xede9d9)); ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.translateBy(x: 4, y: CGFloat(size - 4)); ctx.scaleBy(x: CGFloat(pixels)/map.width, y: -CGFloat(pixels)/map.height)
        ctx.setAllowsAntialiasing(true); ctx.setShouldAntialias(true); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        let fills: [(String, UInt32)] = [("openLand",0xe3e3ce),("accessLand",0xe3ddd6),("woodland",0xc8d8bc),("water",0xa8cbd1),("building",0x9d9485)]
        let lines: [(String,UInt32,Double,[CGFloat])] = [("contour",0xc5b99f,0.48,[]),("contourIndex",0xa79a80,0.96,[]),
            ("water",0x76adb8,0.95,[]),("majorRoad",0xd8a979,3.35,[]),("minorRoad",0xb5a68b,2.4,[]),
            ("track",0x9b8d70,1.43,[4.78,2.87]),("footpath",0xab6471,1.43,[4.78,2.87]),("bridleway",0x866891,1.43,[4.78,2.87]),
            ("unknownPath",0xa49b95,1.43,[4.78,2.87]),("boundary",0xada79f,1,[4.78,2.87])]
        func path(_ item: WorldVectorMap.Path) throws -> CGPath {
            let path = CGMutablePath()
            for ring in item.rings {
                guard ring.count <= 100_000 else { throw RidgeError.message("Map path is too large.") }
                for (index, point) in ring.enumerated() {
                    guard point.count == 2, point.allSatisfy({ $0.isFinite && abs($0) < 1_000_000 }) else { throw RidgeError.message("Invalid map coordinates.") }
                    let p = CGPoint(x: point[0],y: point[1]); if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                if item.closed { path.closeSubpath() }
            }
            return path
        }
        for (kind,fill) in fills { for item in map.paths where item.closed && item.kind == kind {
            ctx.addPath(try path(item)); ctx.setFillColor(color(fill)); ctx.drawPath(using: .eoFill)
        } }
        for (kind,ink,width,dash) in lines { for item in map.paths where !item.closed && item.kind == kind {
            let p = try path(item)
            ctx.setLineDash(phase: CGFloat(item.phase ?? 0), lengths: dash)
            if kind.hasSuffix("Road") { ctx.addPath(p); ctx.setStrokeColor(color(0xfffdf3)); ctx.setLineWidth(width+1.43); ctx.strokePath() }
            ctx.addPath(p); ctx.setStrokeColor(color(ink)); ctx.setLineWidth(width); ctx.strokePath()
        } }
        guard let image = ctx.makeImage() else { throw RidgeError.message("Map drawing failed.") }; return image
    }
}

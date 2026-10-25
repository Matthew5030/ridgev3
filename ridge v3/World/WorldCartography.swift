import Foundation
import CoreGraphics

/// One shared cartographic style. Output pixels are a disposable render cache;
/// changing the palette never changes or redownloads the underlying map features.
enum WorldCartography {
    static let groundColourStrength = 0.66
    private static let linear: [Double] = (0...255).map {
        let c = Double($0) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    private static let encoded: [UInt8] = (0...4096).map {
        let c = Double($0) / 4096
        let s = c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
        return UInt8(max(0, min(255, Int((s * 255).rounded()))))
    }
    static func draw(_ map: WorldVectorMap, pixels: Int,overview:Bool=false,overviewBackground:Data?=nil) throws -> CGImage {
        guard map.width.isFinite, map.height.isFinite, map.width > 0, map.height > 0,
              [32,64,128,256,512,1024,2048,4096].contains(pixels), map.paths.count <= (overview ? 500_000 : 50_000) else { throw RidgeError.message("Invalid vector map.") }
        // The build tool captures a whole UK section once. Runtime tile limits
        // and their neighbour gutters remain unchanged.
        try map.groundColour?.validate(maximumSide:overview ? 4096 : 256,minimumBorder:overview ? 4 : nil)
        let size = pixels + 8
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw RidgeError.message("Not enough memory to draw the map.") }
        func color(_ hex: UInt32) -> CGColor { CGColor(srgbRed: CGFloat((hex >> 16) & 255)/255, green: CGFloat((hex >> 8)&255)/255, blue: CGFloat(hex&255)/255, alpha: 1) }
        ctx.setFillColor(color(0xede9d9)); ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        if overview,let overviewBackground {
            guard overviewBackground.count==size*size*4,let destination=ctx.data else { throw RidgeError.message("Invalid overview coastline") }
            overviewBackground.withUnsafeBytes { bytes in destination.copyMemory(from:bytes.baseAddress!,byteCount:bytes.count) }
        }
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
        for (kind,fill) in fills.prefix(2) { for item in map.paths where item.closed && item.kind == kind {
            ctx.addPath(try path(item)); ctx.setFillColor(color(fill)); ctx.drawPath(using: .eoFill)
        } }
        if let ground = map.groundColour { try blendGround(ground, into: ctx, pixels: pixels) }
        // Mapped woodland, water and buildings retain their original fill. Drawing
        // them once, after the ground, preserves antialiased edges and holes.
        for (kind, fill) in fills.dropFirst(2) { for item in map.paths where item.closed && item.kind == kind {
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

    private static func blendGround(_ ground: WorldVectorMap.GroundColour, into ctx: CGContext, pixels: Int) throws {
        guard let data = ctx.data else { throw RidgeError.message("Missing map pixels.") }
        let destination = data.assumingMemoryBound(to: UInt8.self), size = pixels + 8
        let coreWidth = ground.width - 2 * ground.border, coreHeight = ground.height - 2 * ground.border
        let samples = [UInt8](ground.rgba)
        // The bitmap rows are north-up after the map's flipped drawing transform.
        // Match pixel centres, including the four-pixel map gutter at every LOD.
        for y in 0..<size {
            if y % 32 == 0 { try Task.checkCancellation() }
            let sy = max(0, min(Double(ground.height - 1), (Double(y) - 3.5) / Double(pixels) * Double(coreHeight) + Double(ground.border) - 0.5))
            let y0 = Int(sy), y1 = min(y0 + 1, ground.height - 1), fy = sy - Double(y0)
            for x in 0..<size {
                let sx = max(0, min(Double(ground.width - 1), (Double(x) - 3.5) / Double(pixels) * Double(coreWidth) + Double(ground.border) - 0.5))
                let x0 = Int(sx), x1 = min(x0 + 1, ground.width - 1), fx = sx - Double(x0)
                let indices = SIMD4<Int>((y0 * ground.width + x0) * 4, (y0 * ground.width + x1) * 4,
                                         (y1 * ground.width + x0) * 4, (y1 * ground.width + x1) * 4)
                let weights = SIMD4<Double>((1-fx)*(1-fy), fx*(1-fy), (1-fx)*fy, fx*fy)
                var alpha = 0.0
                var rgb = SIMD3<Double>(repeating: 0)
                for k in 0..<4 {
                    let i = indices[k], weight = weights[k] * Double(samples[i+3]) / 255
                    alpha += weight
                    rgb += SIMD3(linear[Int(samples[i])], linear[Int(samples[i+1])], linear[Int(samples[i+2])]) * weight
                }
                guard alpha > 0 else { continue }
                let amount = alpha * groundColourStrength, offset = y * ctx.bytesPerRow + x * 4
                for c in 0..<3 {
                    let value = linear[Int(destination[offset+c])] * (1-amount) + rgb[c] * groundColourStrength
                    destination[offset+c] = encoded[max(0, min(4096, Int((value * 4096).rounded())))]
                }
            }
        }
    }
}

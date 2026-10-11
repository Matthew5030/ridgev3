import Foundation
import SceneKit
import CoreGraphics
import ImageIO

/// One small local elevation surface and one atlas texture. Independent of LAN
/// availability and fine-tile preparation; it supplies geography, not route data.
struct WorldDistantTerrain: @unchecked Sendable {
    struct Cell { let key: String; let indices: [Int32] }
    let id = UUID()
    let center: GeoPoint
    let frame: GeoBounds
    let sources: [SCNGeometrySource]
    let cells: [Cell]
    let image: CGImage
    let positions: [SCNVector3]
    let left: Int
    let top: Int
    struct Boundary: @unchecked Sendable { let key: String; let geometry: SCNGeometry }
    static func neighbor(_ key:String,edge:Int) -> String {
        var v=key.split(separator:":").map { Int($0)! }
        if edge==0 { v[2]-=1 };if edge==1 { v[2]+=1 };if edge==2 { v[3]-=1 };if edge==3 { v[3]+=1 }
        if v[2]<0 {v[0]-=1;v[2]=47};if v[2]>47 {v[0]+=1;v[2]=0}
        if v[3]<0 {v[1]-=1;v[3]=47};if v[3]>47 {v[1]+=1;v[3]=0}
        return v.map(String.init).joined(separator:":")
    }
    /// Join the actual rendered edge to the coarse surface, rather than relying
    /// on a fixed skirt depth to conceal differences between elevation sources.
    func seams(_ boundaries:[Boundary],covered:Set<String>) -> SCNGeometry? {
        var p:[SCNVector3]=[],uv:[CGPoint]=[],indices:[Int32]=[]
        func texture(_ position:SCNVector3) -> CGPoint {
            let point=frame.point(u:Double(position.x)/frame.widthMeters+0.5,v:Double(position.z)/frame.depthMeters+0.5)
            return CGPoint(x:((point.longitude+180)/360*1024-Double(left))/9,y:(Self.mercatorY(point.latitude)*1024-Double(top))/9)
        }
        func values(_ source:SCNGeometrySource) -> [[Double]] {
            source.data.withUnsafeBytes { bytes in
                (0..<source.vectorCount).map { i in (0..<source.componentsPerVector).map { j in
                    let offset=source.dataOffset+i*source.dataStride+j*source.bytesPerComponent
                    return source.bytesPerComponent==4 ? Double(bytes.loadUnaligned(fromByteOffset:offset,as:Float.self)) : bytes.loadUnaligned(fromByteOffset:offset,as:Double.self)
                } }
            }
        }
        for boundary in boundaries {
            let k=boundary.key.split(separator:":").map { Int($0)! },x=k[0]-left,y=k[1]-top
            guard (0..<9).contains(x),(0..<9).contains(y),let vertices=boundary.geometry.sources(for:.vertex).first,let coords=boundary.geometry.sources(for:.texcoord).first else { continue }
            let start=(y*9+x)*49*49+k[3]*49+k[2]
            let corners=[positions[start],positions[start+1],positions[start+49],positions[start+50]]
            let v=values(vertices),t=values(coords)
            for edge in 0..<4 where !covered.contains(Self.neighbor(boundary.key,edge:edge)) {
                var side:[Double:SCNVector3]=[:]
                for i in 0..<min(v.count,t.count) {
                    let value=edge<2 ? t[i][0] : t[i][1], expected=edge==0 || edge==2 ? 0.0 : 1.0
                    guard abs(value-expected)<1e-6 else { continue }
                    let along=edge<2 ? t[i][1] : t[i][0],position=SCNVector3(Float(v[i][0]),Float(v[i][1]),Float(v[i][2]))
                    // Skirt duplicates share UVs: retain the actual surface top.
                    if side[along] == nil || position.y>side[along]!.y { side[along]=position }
                }
                let sorted=side.sorted { $0.key<$1.key }
                let a=corners[edge==1 ? 1 : edge==3 ? 2 : 0],b=corners[edge==0 ? 2 : edge==2 ? 1 : 3]
                for pair in zip(sorted,sorted.dropFirst()) {
                    let first=pair.0,second=pair.1
                    var c=first.value,d=second.value
                    c.y = .init(Double(a.y)+Double(b.y-a.y)*first.key);d.y = .init(Double(a.y)+Double(b.y-a.y)*second.key)
                    let n=Int32(p.count);p += [first.value,second.value,c,d]
                    let u=texture(first.value),w=texture(second.value);uv += [u,w,u,w]
                    indices += [n,n+1,n+2,n+1,n+3,n+2]
                }
            }
        }
        return indices.isEmpty ? nil : WorldGeometry.build(positions:p,uv:uv,indices:indices)
    }
    func geometry(excluding covered: Set<String>) -> SCNGeometry {
        let indices = cells.filter { !covered.contains($0.key) }.flatMap(\.indices)
        return SCNGeometry(sources:sources,elements:[SCNGeometryElement(indices:indices,primitiveType:.triangles)])
    }
    static func key(for bounds: GeoBounds) -> String? {
        let p = bounds.center, x = Int(floor((p.longitude+180)/360*1024))
        let y = Int(floor(mercatorY(p.latitude)*1024))
        let b = pageBounds(x:x,y:y), uv = b.uv(p)
        let column = min(47,max(0,Int(uv.u*48))), row = min(47,max(0,Int(uv.v*48)))
        let a = b.point(u:Double(column)/48,v:Double(row)/48), z = b.point(u:Double(column+1)/48,v:Double(row+1)/48)
        // Never remove a coarse cell unless the actual detailed tile fills it.
        guard abs(bounds.minLongitude-a.longitude)<1e-7, abs(bounds.maxLongitude-z.longitude)<1e-7,
              abs(bounds.maxLatitude-a.latitude)<1e-7, abs(bounds.minLatitude-z.latitude)<1e-7 else { return nil }
        return "\(x):\(y):\(column):\(row)"
    }
    static func mercatorY(_ latitude: Double) -> Double { (1-asinh(tan(latitude * .pi/180)) / .pi)/2 }
    static func latitude(_ y: Double) -> Double { atan(sinh(.pi*(1-2*y))) * 180 / .pi }
    static func pageBounds(x:Int,y:Int) -> GeoBounds {
        GeoBounds(minLatitude:latitude(Double(y+1)/1024),minLongitude:Double(x)/1024*360-180,maxLatitude:latitude(Double(y)/1024),maxLongitude:Double(x+1)/1024*360-180)
    }
}

actor WorldDistantTerrainStore {
    private struct Index: Decodable {
        struct Part: Decodable { let id: String; let bounds: GeoBounds; let file: String; let sha256: String }
        let schemaVersion: Int; let side: Int; let scaleMetres: Double; let parts: [Part]
    }
    private let root: URL?
    private let atlas: URL?
    init(root: URL? = Bundle.main.url(forResource:"WorldContext",withExtension:"bundle"), atlas: URL? = Bundle.main.url(forResource:"WorldAtlas",withExtension:"bundle")) { self.root=root;self.atlas=atlas }
    func build(center: GeoPoint,frame: GeoBounds) throws -> WorldDistantTerrain? {
        guard let root, let atlas else { return nil }
        let index = try JSONDecoder().decode(Index.self,from:Data(contentsOf:root.appendingPathComponent("index.json")))
        guard index.schemaVersion == 1,index.side == 49,index.scaleMetres == 0.1 else { throw RidgeError.message("Unsupported overview elevation.") }
        let parts = Dictionary(uniqueKeysWithValues:index.parts.map { ($0.id,$0) })
        let cx=(center.longitude+180)/360*1024,cy=WorldDistantTerrain.mercatorY(center.latitude)*1024
        // Fixed nine-by-nine pages: roughly 180–220 km across in the UK.
        let left=Int(floor(cx))-4,top=Int(floor(cy))-4,count=9
        var positions:[SCNVector3]=[],uv:[CGPoint]=[],cells:[WorldDistantTerrain.Cell]=[]
        for y in top..<top+count { for x in left..<left+count {
            try Task.checkCancellation()
            let b=WorldDistantTerrain.pageBounds(x:x,y:y),start=Int32(positions.count)
            var heights=[Int16](repeating:0,count:49*49)
            if let part=parts["z10-x\(x)-y\(y)"] {
                let data=try Data(contentsOf:root.appendingPathComponent(part.file))
                guard data.count==49*49*2, AdaptiveTerrainCodec.hash(data)==part.sha256 else { throw RidgeError.message("Damaged overview elevation.") }
                heights=data.withUnsafeBytes { bytes in (0..<49*49).map { Int16(littleEndian:bytes.loadUnaligned(fromByteOffset:$0*2,as:Int16.self)) } }
            }
            for row in 0...48 { for column in 0...48 {
                let p=b.point(u:Double(column)/48,v:Double(row)/48),s=frame.uv(p),h=heights[row*49+column]
                positions.append(SCNVector3(Float((s.u-0.5)*frame.widthMeters),h == -32768 ? 0 : Float(h)*0.1,Float((s.v-0.5)*frame.depthMeters)))
                uv.append(CGPoint(x:(Double(x-left)+Double(column)/48)/Double(count),y:(WorldDistantTerrain.mercatorY(p.latitude)*1024-Double(top))/Double(count)))
            } }
            for row in 0..<48 { for column in 0..<48 {
                let i=start+Int32(row*49+column)
                cells.append(.init(key:"\(x):\(y):\(column):\(row)",indices:[i,i+49,i+1,i+1,i+49,i+50]))
            } }
        } }
        let surface=WorldGeometry.build(positions:positions,uv:uv,indices:cells.flatMap(\.indices))
        let size=2048
        guard let space=CGColorSpace(name:CGColorSpace.sRGB),let ctx=CGContext(data:nil,width:size,height:size,bitsPerComponent:8,bytesPerRow:size*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw RidgeError.message("Could not prepare distant map.") }
        ctx.setFillColor(CGColor(srgbRed:0.66,green:0.80,blue:0.82,alpha:1));ctx.fill(CGRect(x:0,y:0,width:size,height:size))
        let inventory=try WorldAtlasIndex(data:Data(contentsOf:atlas.appendingPathComponent("index.json")))
        let scale=Double(size)*1024/Double(count)
        let pages=inventory.pages(centerX:Double(left)*1/1024+Double(count)/2048,centerY:Double(top)*1/1024+Double(count)/2048,scale:scale,width:Double(size),height:Double(size))
        for page in pages {
            try Task.checkCancellation()
            guard let source=CGImageSourceCreateWithURL(atlas.appendingPathComponent(page.key) as CFURL,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil) else { continue }
            let factor=1024/page.divisions,side=factor/Double(count)*Double(size)
            let px=(Double(page.x)*factor-Double(left))/Double(count)*Double(size)
            let py=(Double(page.y)*factor-Double(top))/Double(count)*Double(size)
            ctx.draw(image,in:CGRect(x:px,y:Double(size)-py-side,width:side,height:side))
        }
        guard let image=ctx.makeImage() else { throw RidgeError.message("Could not prepare distant map.") }
        return WorldDistantTerrain(center:center,frame:frame,sources:surface.sources,cells:cells,image:image,positions:positions,left:left,top:top)
    }
}

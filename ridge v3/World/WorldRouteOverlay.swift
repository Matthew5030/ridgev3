import Foundation
import SceneKit
import Metal
import simd

/// Vector route ink evaluated on the actual terrain fragments. No second surface,
/// elevation samples, depth override, or raster route image is needed.
enum WorldRouteOverlay {
    static let side = 16
    static let reach: Float = 40 // Shader widths, markers and AA never extend this far.
    struct Tile {
        var origin: SIMD2<Float>
        var extent: SIMD2<Float>
        // Each cell header: segment start/count, waypoint start/count. Following
        // float4 records are segment endpoints or waypoint coordinates in metres.
        var records: [SIMD4<Float>]
        var largestBucket: Int
    }
    struct Binding {
        var buffer: MTLBuffer
        var tile: Tile
        func apply(to material: SCNMaterial, pixelScale: Float) {
            material.shaderModifiers = [.geometry: WorldRouteOverlay.geometryShader, .fragment: WorldRouteOverlay.fragmentShader]
            material.setValue(buffer, forKey:"ridgeRouteRecords")
            material.setValue(NSValue(scnVector4:SCNVector4(originX,originY,tile.extent.x,tile.extent.y)),forKey:"ridgeRouteTile")
            material.setValue(NSNumber(value:pixelScale),forKey:"ridgeRoutePixelScale")
        }
        private var originX: Float { tile.origin.x }
        private var originY: Float { tile.origin.y }
    }
    static func binding(_ tile: Tile, device: MTLDevice) -> Binding? {
        let buffer=tile.records.withUnsafeBytes { bytes in device.makeBuffer(bytes:bytes.baseAddress!,length:bytes.count,options:.storageModeShared) }
        return buffer.map { Binding(buffer:$0,tile:tile) }
    }
    static func build(source: WorldSource, paths: [[GeoPoint]], waypoints: [GeoPoint]) -> [String:Tile] {
        func position(_ point: GeoPoint) -> SIMD2<Float> {
            let uv=source.bounds.uv(point)
            return SIMD2(Float((uv.u-0.5)*source.bounds.widthMeters),Float((uv.v-0.5)*source.bounds.depthMeters))
        }
        let segments=paths.flatMap { path in zip(path,path.dropFirst()).compactMap { a,b -> SIMD4<Float>? in
            guard a.isValid,b.isValid else { return nil }
            let p=position(a),q=position(b)
            guard simd_length_squared(q-p)>0.000001 else { return nil }
            return SIMD4(p.x,p.y,q.x,q.y)
        } }
        let markers=waypoints.filter(\.isValid).map(position)
        var result:[String:Tile]=[:]
        for tile in source.tiles {
            let origin=position(tile.mesh.bounds.point(u:0,v:0))
            let extent=position(tile.mesh.bounds.point(u:1,v:1))-origin
            var lines=[[SIMD4<Float>]](repeating:[],count:side*side)
            var dots=[[SIMD4<Float>]](repeating:[],count:side*side)
            func bins(_ a:SIMD2<Float>,_ b:SIMD2<Float>,add:(Int)->Void) {
                // Clip before deriving indices: imported GPX can extend far outside this source.
                guard let clipped=clip(a,b,minimum:SIMD2(repeating:-reach),maximum:extent+SIMD2(repeating:reach)) else { return }
                let lo=simd_min(clipped.0,clipped.1)-SIMD2(repeating:reach),hi=simd_max(clipped.0,clipped.1)+SIMD2(repeating:reach)
                let x0=max(0,min(side-1,Int(floor(lo.x/extent.x*Float(side))))),x1=max(0,min(side-1,Int(floor(hi.x/extent.x*Float(side)))))
                let y0=max(0,min(side-1,Int(floor(lo.y/extent.y*Float(side))))),y1=max(0,min(side-1,Int(floor(hi.y/extent.y*Float(side)))))
                for y in y0...y1 { for x in x0...x1 {
                    let low=SIMD2(Float(x),Float(y))*extent/Float(side)-SIMD2(repeating:reach)
                    let high=SIMD2(Float(x+1),Float(y+1))*extent/Float(side)+SIMD2(repeating:reach)
                    if clip(a,b,minimum:low,maximum:high) != nil { add(y*side+x) }
                } }
            }
            for segment in segments {
                let a=SIMD2(segment.x,segment.y)-origin,b=SIMD2(segment.z,segment.w)-origin
                bins(a,b) { lines[$0].append(SIMD4(a.x,a.y,b.x,b.y)) }
            }
            for marker in markers { let p=marker-origin; bins(p,p) { dots[$0].append(SIMD4(p.x,p.y,0,0)) } }
            guard lines.contains(where:{!$0.isEmpty}) || dots.contains(where:{!$0.isEmpty}) else { continue }
            var records=[SIMD4<Float>](repeating:.zero,count:side*side)
            var largest=0
            for cell in records.indices {
                let first=records.count;records.append(contentsOf:lines[cell]);let markerStart=records.count;records.append(contentsOf:dots[cell])
                records[cell]=SIMD4(Float(first),Float(lines[cell].count),Float(markerStart),Float(dots[cell].count))
                largest=max(largest,lines[cell].count)
            }
            result[tile.id]=Tile(origin:origin,extent:extent,records:records,largestBucket:largest)
        }
        return result
    }
    private static func clip(_ a:SIMD2<Float>,_ b:SIMD2<Float>,minimum:SIMD2<Float>,maximum:SIMD2<Float>) -> (SIMD2<Float>,SIMD2<Float>)? {
        let d=b-a;var low:Float=0,high:Float=1
        for axis in 0..<2 {
            if abs(d[axis])<0.000001 { if a[axis]<minimum[axis] || a[axis]>maximum[axis] { return nil } }
            else {
                let p=(minimum[axis]-a[axis])/d[axis],q=(maximum[axis]-a[axis])/d[axis]
                low=max(low,min(p,q));high=min(high,max(p,q));if low>high { return nil }
            }
        }
        return (a+d*low,a+d*high)
    }
    static let geometryShader = """
    #pragma varyings
    float2 ridgeRoutePosition;
    #pragma body
    out.ridgeRoutePosition = _geometry.position.xz;
    """
    static let fragmentShader = """
    #pragma arguments
    // SceneKit expands this pointer argument to a device-const Metal buffer.
    float4* ridgeRouteRecords;
    float4 ridgeRouteTile;
    float ridgeRoutePixelScale;
    #pragma body
    float2 rp = in.ridgeRoutePosition - ridgeRouteTile.xy;
    float2 rx = dfdx(rp), ry = dfdy(rp);
    int2 cell = clamp(int2(floor(rp / ridgeRouteTile.zw * 16.0)), int2(0), int2(15));
    float4 header = ridgeRouteRecords[cell.y * 16 + cell.x];
    float nearest = 1e20;
    float2 normal = float2(1.0, 0.0);
    for (int i = 0; i < int(header.y); ++i) {
        float4 line = ridgeRouteRecords[int(header.x) + i];
        float2 ab = line.zw - line.xy;
        float t = clamp(dot(rp-line.xy,ab) / max(dot(ab,ab),1e-8),0.0,1.0);
        float2 delta = rp - (line.xy+t*ab);
        float d = length(delta);
        if (d < nearest) {
            nearest = d;
            normal = d > 1e-5 ? delta/d : normalize(float2(-ab.y,ab.x));
        }
    }
    float metresPerPixel = max(length(float2(dot(rx,normal),dot(ry,normal))),0.001);
    float aa = clamp(metresPerPixel*0.8,0.01,2.0);
    float inner = min(24.0,2.0*ridgeRoutePixelScale*metresPerPixel);
    float outer = min(32.0,2.8*ridgeRoutePixelScale*metresPerPixel);
    float edge = 1.0-smoothstep(outer-aa,outer+aa,nearest);
    float ink = 1.0-smoothstep(inner-aa,inner+aa,nearest);
    _output.color.rgb = mix(_output.color.rgb,float3(0.98,0.97,0.92),edge);
    _output.color.rgb = mix(_output.color.rgb,float3(0.85,0.23,0.12),ink);
    for (int i = 0; i < int(header.w); ++i) {
        float2 delta = rp-ridgeRouteRecords[int(header.z)+i].xy;
        float d=length(delta);
        float2 n=d>1e-5 ? delta/d : float2(1.0,0.0);
        float scale=max(length(float2(dot(rx,n),dot(ry,n))),0.001);
        float radius=min(30.0,5.0*ridgeRoutePixelScale*scale);
        float soft=clamp(scale*0.8,0.01,2.0);
        float border=1.0-smoothstep(radius-soft,radius+soft,d);
        float core=1.0-smoothstep(max(0.0,radius-1.4*ridgeRoutePixelScale*scale)-soft,max(0.0,radius-1.4*ridgeRoutePixelScale*scale)+soft,d);
        _output.color.rgb=mix(_output.color.rgb,float3(0.98,0.97,0.92),border);
        _output.color.rgb=mix(_output.color.rgb,float3(0.85,0.23,0.12),core);
    }
    """
}

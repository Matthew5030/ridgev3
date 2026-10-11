import SceneKit
import CoreGraphics
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A non-interactive annotation, never a collision wall or route hit target.
enum WorldOfflineBoundary {
    static func geometry(edges: [WorldOfflineCoverage.Edge], focus: GeoPoint, frame: GeoBounds,
                         elevation: (GeoPoint) -> Float) -> SCNGeometry? {
        var positions: [SCNVector3] = [], uv: [CGPoint] = [], indices: [Int32] = []
        let latReach=3000.0/111195, lonReach=latReach/max(0.01,cos(focus.latitude * .pi/180))
        // Clip long merged edges to a small neighbourhood; complexity never
        // grows with the area of a national download.
        for edge in edges.filter({ $0.distance(to:focus)<3000 }).sorted(by: { $0.distance(to:focus)<$1.distance(to:focus) }).prefix(64) {
            let horizontal=edge.start.latitude==edge.end.latitude
            let a=GeoPoint(latitude:horizontal ? edge.start.latitude : max(edge.start.latitude,focus.latitude-latReach),
                           longitude:horizontal ? max(edge.start.longitude,focus.longitude-lonReach) : edge.start.longitude)
            let b=GeoPoint(latitude:horizontal ? edge.end.latitude : min(edge.end.latitude,focus.latitude+latReach),
                           longitude:horizontal ? min(edge.end.longitude,focus.longitude+lonReach) : edge.end.longitude)
            guard a.latitude<=b.latitude,a.longitude<=b.longitude else { continue }
            let steps=max(1,Int(ceil(a.distance(to:b)/15)))
            guard positions.count+(steps+1)*2<=24000 else { break }
            let base=Int32(positions.count)
            for i in 0...steps {
                let t=Double(i)/Double(steps),point=GeoPoint(latitude:a.latitude+(b.latitude-a.latitude)*t,longitude:a.longitude+(b.longitude-a.longitude)*t)
                let p=frame.uv(point),x=Float((p.u-0.5)*frame.widthMeters),z=Float((p.v-0.5)*frame.depthMeters),y=elevation(point)+2
                positions += [SCNVector3(x,y,z),SCNVector3(x,y+90,z)]
                uv += [CGPoint(x:0,y:0),CGPoint(x:0,y:1)]
                if i<steps { let k=base+Int32(i*2);indices += [k,k+2,k+1,k+1,k+2,k+3] }
            }
        }
        guard !indices.isEmpty else { return nil }
        let geometry=WorldGeometry.build(positions:positions,uv:uv,indices:indices)
        let material=SCNMaterial();material.lightingModel = .constant
        #if canImport(UIKit)
        material.diffuse.contents=UIColor(red:0.66,green:0.43,blue:0.16,alpha:1)
        #else
        material.diffuse.contents=NSColor(calibratedRed:0.66,green:0.43,blue:0.16,alpha:1)
        #endif
        material.isDoubleSided=true;material.writesToDepthBuffer=false;material.readsFromDepthBuffer=true
        material.blendMode = .alpha;material.transparencyMode = .aOne
        material.shaderModifiers = [.geometry:"""
        #pragma varyings
        float3 ridgeBoundaryPosition;
        #pragma body
        out.ridgeBoundaryPosition = float3(_geometry.position.xz, _geometry.texcoords[0].y);
        """,.fragment:"""
        #pragma arguments
        float4 ridgeBoundaryFocus;
        #pragma transparent
        #pragma body
        float d = distance(in.ridgeBoundaryPosition.xy, ridgeBoundaryFocus.xy);
        float fade = 1.0 - smoothstep(600.0, 1800.0, d);
        float h = in.ridgeBoundaryPosition.z;
        float base = 0.48 * (1.0 - smoothstep(0.0, 0.035, h));
        // SceneKit blends the final fragment as premultiplied colour.
        _output.color *= (base + 0.22 * pow(1.0-h, 2.0)) * fade * ridgeBoundaryFocus.z;
        """]
        geometry.materials=[material]
        return geometry
    }
}

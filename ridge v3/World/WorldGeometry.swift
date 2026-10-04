import Foundation
import SceneKit
import simd

/// SceneKit objects are created on the source worker and transferred once. The
/// main thread owns them after installation. No attached geometry is mutated by a worker.
enum WorldGeometry {
    static func build(positions: [SCNVector3], uv: [CGPoint], indices: [Int32]) -> SCNGeometry {
        var normals = [SIMD3<Float>](repeating:.zero,count:positions.count)
        for t in stride(from:0,to:indices.count,by:3) {
            let a=Int(indices[t]),b=Int(indices[t+1]),c=Int(indices[t+2]);let p=positions[a],q=positions[b],r=positions[c]
            let n=simd_cross(SIMD3<Float>(Float(q.x-p.x),Float(q.y-p.y),Float(q.z-p.z)),SIMD3<Float>(Float(r.x-p.x),Float(r.y-p.y),Float(r.z-p.z)))
            normals[a]+=n;normals[b]+=n;normals[c]+=n
        }
        let ns=normals.map { n -> SCNVector3 in let n=simd_length_squared(n)>0 ? simd_normalize(n) : SIMD3<Float>(0,1,0);return SCNVector3(n.y<0 ? -n:n) }
        return SCNGeometry(sources:[SCNGeometrySource(vertices:positions),SCNGeometrySource(normals:ns),SCNGeometrySource(textureCoordinates:uv)],elements:[SCNGeometryElement(indices:indices,primitiveType:.triangles)])
    }
    static func fine(_ mesh: AdaptiveMesh, sourceBounds: GeoBounds, pixels: Int) -> SCNGeometry {
        var p:[SCNVector3]=[],uv:[CGPoint]=[],indices:[Int32]=[]
        for i in 0..<mesh.chunk.vertices {
            let v=mesh.vertex(i),u=Double(v.x)/512,w=Double(v.z)/512
            let point=mesh.chunk.bounds.point(u:u,v:w),s=sourceBounds.uv(point)
            p.append(SCNVector3(Float((s.u-0.5)*sourceBounds.widthMeters),v.y,Float((s.v-0.5)*sourceBounds.depthMeters)))
            uv.append(CGPoint(x:u,y:w))
        }
        for i in 0..<mesh.chunk.triangles*3 { indices.append(Int32(mesh.index(i))) }
        // Thin skirts cover fine/coarse T-junctions without altering surface elevations.
        for edge in 0..<4 {
            let ids=(0..<mesh.chunk.vertices).filter { i in let v=mesh.vertex(i);return edge==0 ? v.x==0 : edge==1 ? v.x==512 : edge==2 ? v.z==0 : v.z==512 }.sorted { a,b in let x=mesh.vertex(a),y=mesh.vertex(b);return edge<2 ? x.z<y.z : x.x<y.x }
            for (a,b) in zip(ids,ids.dropFirst()) {
                let start=Int32(p.count);var x=p[a],y=p[b];x.y-=20;y.y-=20;p += [p[a],p[b],x,y];uv += [uv[a],uv[b],uv[a],uv[b]]
                indices += [start,start+1,start+2,start+1,start+3,start+2]
            }
        }
        return build(positions:p,uv:uv,indices:indices)
    }
    static func coarse(tile: WorldTile, source: WorldSource, overview: WorldOverview) -> SCNGeometry {
        var p:[SCNVector3]=[],uv:[CGPoint]=[],indices:[Int32]=[]
        for y in 0...16 { for x in 0...16 {
            let point=tile.mesh.bounds.point(u:Double(x)/16,v:Double(y)/16),s=source.bounds.uv(point)
            p.append(SCNVector3(Float((s.u-0.5)*source.bounds.widthMeters),overview.elevation(point,bounds:source.bounds),Float((s.v-0.5)*source.bounds.depthMeters)))
            uv.append(CGPoint(x:Double(x)/16,y:Double(y)/16))
        } }
        for y in 0..<16 { for x in 0..<16 { let i=Int32(y*17+x);indices += [i,i+17,i+1,i+1,i+17,i+18] } }
        return build(positions:p,uv:uv,indices:indices)
    }
}

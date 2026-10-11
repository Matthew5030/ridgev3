import Foundation
import SceneKit
@main struct WorldDistantTerrainTests {
    static func main() async throws {
        let resources=URL(fileURLWithPath:CommandLine.arguments[1]).deletingLastPathComponent()
        let store=WorldDistantTerrainStore(root:resources.appendingPathComponent("WorldContext.bundle"),atlas:resources.appendingPathComponent("WorldAtlas.bundle"))
        let center=GeoPoint(latitude:53.0685,longitude:-4.0763)
        let frame=WorldDistantTerrain.pageBounds(x:500,y:333)
        let start=Date()
        guard let terrain=try await store.build(center:center,frame:frame) else { fatalError("Missing bundled context") }
        var checks=0
        func check(_ condition:Bool,_ text:String) { precondition(condition,text);checks+=1 }
        check(terrain.image.width==2048 && terrain.image.height==2048,"Bounded one-texture context")
        check(terrain.cells.count==81*48*48,"Bounded surface including sea/context")
        let full=terrain.geometry(excluding:[])
        check(full.elements.count==1,"One terrain draw element")
        check(full.elements[0].primitiveCount==81*48*48*2,"Complete uncut surface")
        let key="500:333:20:11",cell=terrain.cells.first { $0.key==key }!
        let cut=terrain.geometry(excluding:[key])
        check(cut.elements[0].primitiveCount==full.elements[0].primitiveCount-2,"Only the loaded cell is removed")
        let b=frame,a=b.point(u:20.0/48,v:11.0/48),z=b.point(u:21.0/48,v:12.0/48)
        let tile=GeoBounds(minLatitude:z.latitude,minLongitude:a.longitude,maxLatitude:a.latitude,maxLongitude:z.longitude)
        check(WorldDistantTerrain.key(for:tile)==key,"Detailed-grid alignment")
        check(WorldDistantTerrain.key(for:frame)==nil,"Larger or partial coverage never punches a false hole")
        check(cell.indices.count==6,"Exactly one coarse cell per detailed tile")
        let bytes=full.sources.reduce(0){$0+$1.data.count}+full.elements.reduce(0){$0+$1.data.count}
        check(bytes<16*1024*1024,"Geometry within 16 MiB")
        let index=try JSONSerialization.jsonObject(with:Data(contentsOf:resources.appendingPathComponent("WorldContext.bundle/index.json"))) as! [String:Any]
        let parts=index["parts"] as! [[String:Any]]
        for part in parts {
            let path=resources.appendingPathComponent("WorldContext.bundle").appendingPathComponent(part["file"] as! String)
            let data=try Data(contentsOf:path)
            check(data.count==49*49*2 && AdaptiveTerrainCodec.hash(data)==part["sha256"] as! String,"Verified bundled elevation")
        }
        let root=try WorldLibrary.root(mode:"local",local:"http://127.0.0.1:8787")
        let catalog=try await WorldCatalogStore().open(root:root)
        let region=catalog.region(at:center)!
        let source=try await WorldSourceStore().manifest(address:root.appendingPathComponent(region.path).absoluteString)
        for tile in source.tiles { check(WorldDistantTerrain.key(for:tile.mesh.bounds) != nil,"Actual published terrain aligns with context holes") }
        print("PASS \(checks) distant terrain checks; geometry \(bytes) bytes, local preparation \(Date().timeIntervalSince(start)) s")
    }
}

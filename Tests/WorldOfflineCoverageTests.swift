import Foundation
import SceneKit
@main struct WorldOfflineCoverageTests {
    static func main() throws {
        var checks=0
        func check(_ value: Bool,_ reason: String) { precondition(value,reason);checks+=1 }
        func cell(_ x:Int,_ y:Int) -> GeoBounds { .init(minLatitude:53+Double(y)*0.01,minLongitude:-4+Double(x)*0.01,maxLatitude:53+Double(y+1)*0.01,maxLongitude:-4+Double(x+1)*0.01) }
        let a=cell(0,0), b=cell(1,0), c=cell(0,1), d=cell(1,1)
        check(WorldOfflineCoverage.outline([]).isEmpty,"No invented coverage")
        check(WorldOfflineCoverage.outline([a]).count==4,"Single area perimeter")
        check(WorldOfflineCoverage.outline([a,a,b,c,d]).count==4,"Duplicate saves and all shared tile edges disappear")
        let ring=(0..<3).flatMap { y in (0..<3).filter { x in x != 1 || y != 1 }.map { cell($0,y) } }
        check(WorldOfflineCoverage.outline(ring).count==8,"Missing download in centre keeps its boundary")
        check(WorldOfflineCoverage.outline([a,cell(3,0)]).count==8,"Disconnected downloads stay separate")
        let partial=GeoBounds(minLatitude:53,minLongitude:-3.99,maxLatitude:53.005,maxLongitude:-3.98)
        check(WorldOfflineCoverage.outline([a,partial]).count==6,"Partial neighbour removes only the shared portion")
        let edge=WorldOfflineCoverage.Edge(start:a.point(u:0,v:0),end:a.point(u:1,v:0))
        check(edge.distance(to:a.point(u:0.5,v:0))<0.01,"Distance to middle of edge, not corners")
        check(WorldOfflineCoverage.visibility(distance:600)==1 && WorldOfflineCoverage.visibility(distance:1800)==0,"Local fade without a faraway fence")
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let hash=String(repeating:"a",count:64), asset=WorldOfflineCoverage.Asset(hash:hash,bytes:3)
        try WorldOfflineCoverage.record([.init(bounds:a,assets:[asset])],at:root)
        check(WorldOfflineCoverage.savedBounds(at:root).isEmpty,"Receipt alone cannot claim saved coverage")
        try JSONEncoder().encode(Set([hash])).write(to:root.appendingPathComponent("pins.json"))
        check(WorldOfflineCoverage.savedBounds(at:root).isEmpty,"Reserved but unfinished download is not saved")
        try Data([1,2,3]).write(to:root.appendingPathComponent(hash))
        check(WorldOfflineCoverage.savedBounds(at:root)==[a],"Completed pinned data survives a fresh read")
        try WorldOfflineCoverage.record([.init(bounds:b,assets:[asset])],at:root)
        check(Set(WorldOfflineCoverage.savedBounds(at:root))==Set([a,b]),"Adjacent saves persist together")
        try Data([1]).write(to:root.appendingPathComponent(hash))
        check(WorldOfflineCoverage.savedBounds(at:root).isEmpty,"Truncated assets cannot be advertised as saved")
        try Data([1,2,3]).write(to:root.appendingPathComponent(hash))
        try JSONEncoder().encode(Set<String>()).write(to:root.appendingPathComponent("pins.json"))
        check(WorldOfflineCoverage.savedBounds(at:root).isEmpty,"Unpinned cache is not permanent coverage")
        let geometry=WorldOfflineBoundary.geometry(edges:WorldOfflineCoverage.outline([a,b,c,d]),focus:a.center,frame:a,elevation:{ _ in 200 })!
        check(geometry.sources(for:.vertex)[0].vectorCount<=24000,"Bounded annotation geometry")
        check(geometry.firstMaterial?.writesToDepthBuffer==false && geometry.firstMaterial?.readsFromDepthBuffer==true,"Curtain cannot occlude terrain, but respects mountains")
        check(WorldOfflineBoundary.geometry(edges:[edge],focus:cell(20,20).center,frame:a,elevation:{ _ in 0 })==nil,"No distant wall allocations")
        print("PASS \(checks) offline boundary checks")
    }
}

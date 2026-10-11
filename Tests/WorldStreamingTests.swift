import Foundation
import SceneKit

@main struct WorldStreamingTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool,_ reason: String) throws {
            guard value else { throw RidgeError.message(reason) }; checks += 1
        }
        let root = try WorldLibrary.root(mode:"local",local:"http://127.0.0.1:8787")
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("ridge-stream-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:cache) }
        let catalog = try await WorldCatalogStore(cacheURL:cache).open(root:root)
        let point = GeoPoint(latitude:53.0685,longitude:-4.0763)
        let anchor = catalog.region(at:point)!
        try check(WorldWindow.distance(point,to:anchor.bounds) == 0,"Containing rectangle has zero distance")
        try check(!WorldWindow.needsUpdate(center:point,radius:18000,loadedCenter:point,loadedRadius:21000),"Retention avoids repeated loads while stationary")
        try check(WorldWindow.radius(distance:12000,pitch:0.3)>WorldWindow.radius(distance:1500,pitch:1.4),"A wide low view gets more surroundings")
        let first = WorldLandscapeStore(cacheURL:cache)
        let began = Date()
        let (source,_,graph,background,pages) = try await first.window(center:point,radius:5000,frame:anchor.bounds,catalog:catalog,root:root,previous:nil)
        print("First window: \(source.tiles.count) tiles, \(Date().timeIntervalSince(began)) s")
        try check(source.tiles.count == background.geometries.count && source.tiles.count == pages.count,"Complete textured terrain before publishing")
        try check(source.tiles.contains { !$0.id.hasPrefix(anchor.id + "__") },"Window crosses storage boundaries")
        try check(!FileManager.default.fileExists(atPath:cache.appendingPathComponent("pins.json").path),"Browsing does not pin downloads permanently")
        let shifted = GeoPoint(latitude:point.latitude,longitude:point.longitude+0.045)
        let second = WorldLandscapeStore(cacheURL:cache)
        let nextBegan = Date()
        let (next,_,nextGraph,nextBackground,nextPages) = try await second.window(center:shifted,radius:5000,frame:source.frame,catalog:catalog,root:root,previous:await first.snapshot())
        print("Shifted window: \(next.tiles.count) tiles, \(Date().timeIntervalSince(nextBegan)) s")
        try check(source.frame == next.frame,"Camera frame stays fixed across region boundaries")
        let shared = Set(source.tiles.map(\.id)).intersection(next.tiles.map(\.id))
        let removed = Set(source.tiles.map(\.id)).subtracting(next.tiles.map(\.id))
        let added = Set(next.tiles.map(\.id)).subtracting(source.tiles.map(\.id))
        try check(!shared.isEmpty && !removed.isEmpty && !added.isEmpty,"Window moves, rather than accumulating every visited tile")
        for id in shared {
            try check(pages[id]!.image === nextPages[id]!.image,"Existing vector textures are reused")
            if (background.meshes[id] != nil) == (nextBackground.meshes[id] != nil) {
                try check(background.geometries[id] === nextBackground.geometries[id],"Existing terrain geometry is reused")
            }
        }
        let adaptiveBytes = next.tiles.filter { nextBackground.meshes[$0.id] != nil }.reduce(Int64(0)) { $0 + ($1.background?.residentBytes ?? 0) }
        try check(adaptiveBytes <= WorldWindow.backgroundBudget,"One background memory budget for every region")
        let requests = WorldWorkingSet.requests(source:next,center:shifted,distance:2000)
        let fineIDs = Set(requests.filter(\.fine).map(\.id))
        try check(next.tiles.filter { fineIDs.contains($0.id) }.reduce(Int64(0)) { $0+$1.mesh.residentBytes } <= WorldWorkingSet.meshBudget,"Fine geometry remains bounded")
        try check(!graph.nodes.isEmpty && !nextGraph.nodes.isEmpty,"Walking paths survive window changes")
        let byID = Dictionary(uniqueKeysWithValues:nextGraph.nodes.map { ($0.id,$0) })
        let edge = nextGraph.edges.first { edge in
            guard ["footway","path","track","bridleway","steps"].contains(edge.kind), ["","unknown","yes","designated","permissive","public","official"].contains(edge.access), let a=byID[edge.from],let b=byID[edge.to] else { return false }
            return catalog.region(at:a.coordinate)?.id != catalog.region(at:b.coordinate)?.id && a.coordinate.distance(to:b.coordinate)>2
        }
        try check(edge != nil,"Connected walking edges cross storage regions")
        if let edge {
            let route = try RouteEngine.walkingSegment(from:byID[edge.from]!.coordinate,to:byID[edge.to]!.coordinate,graph:nextGraph)
            try check(route.points.count >= 2,"Route solver follows paths across a region boundary")
        }
        let third = WorldLandscapeStore(cacheURL:cache)
        let cancelled = Task { try await third.window(center:point,radius:6000,frame:source.frame,catalog:catalog,root:root,previous:await second.snapshot()) }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw RidgeError.message("Cancelled candidate published") }
        catch is CancellationError { checks += 1 }
        try check((await second.snapshot()).pages.count == nextPages.count,"Cancelling a candidate leaves the visible store intact")
        print("PASS \(checks) streaming, retention, geometry reuse, memory and routing checks")
    }
}

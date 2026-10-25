import Foundation
import SceneKit
import CoreGraphics
import ImageIO

@MainActor private final class ProgressProbe {
    var batches: [(Set<String>,Set<String>)] = []
    var surfaceBeforePaths=false
    func receive(_ background:WorldBackdrop,_ pages:[String:WorldPreparedTile]) {
        batches.append((Set(background.geometries.keys),Set(pages.keys)))
    }
}
@main struct WorldStreamingTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool,_ reason: String) throws {
            guard value else { throw RidgeError.message(reason) }; checks += 1
        }
        let root = try WorldLibrary.root(mode:"local",local:ProcessInfo.processInfo.environment["RIDGE_TEST_SERVER"] ?? "http://127.0.0.1:8787")
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("ridge-stream-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:cache) }
        let catalog = try await WorldCatalogStore(cacheURL:cache).open(root:root)
        let point = GeoPoint(latitude:53.0685,longitude:-4.0763)
        let anchor = catalog.region(at:point)!
        try check(WorldWindow.distance(point,to:anchor.bounds) == 0,"Containing rectangle has zero distance")
        try check(!WorldWindow.needsUpdate(center:point,radius:18000,loadedCenter:point,loadedRadius:21000),"Retention avoids repeated loads while stationary")
        try check(WorldWindow.radius(distance:12000,pitch:0.3)>WorldWindow.radius(distance:1500,pitch:1.4),"A wide low view gets more surroundings")
        var radius = WorldWindow.nextRadius(desired:23200,loaded:0)
        try check(radius == WorldWindow.entryRadius && radius<5000,"Entry stays small")
        for _ in 0..<7 {
            let next = WorldWindow.nextRadius(desired:23200,loaded:radius)
            try check(next-radius <= 3000 && next >= radius,"Horizon publishes in bounded growth steps")
            radius = next
        }
        try check(radius == 23200,"Progressive growth still reaches the full horizon")
        try check(WorldWindow.nextRadius(desired:20000,loaded:24000) == 20000,"Zooming in does not retain an ever-growing window")
        let first = WorldLandscapeStore(cacheURL:cache)
        let began = Date()
        let firstProgress=ProgressProbe()
        let (source,_,graph,background,pages) = try await first.window(center:point,radius:5000,frame:anchor.bounds,catalog:catalog,root:root,previous:nil,progress: { metadata,_,background,pages in
            await MainActor.run {
                if !pages.isEmpty,!FileManager.default.fileExists(atPath:cache.appendingPathComponent(metadata.graph.sha256).path) { firstProgress.surfaceBeforePaths=true }
                firstProgress.receive(background,pages)
            }
        })
        try check(firstProgress.surfaceBeforePaths,"Visible terrain publishes before walking-graph decoding")
        try check(pages.values.allSatisfy { $0.request.pixels>=WorldMapSurface.minimumPixels },"Every initial terrain page meets close-map quality")
        print("First window: \(source.tiles.count) tiles, \(Date().timeIntervalSince(began)) s")
        try check(source.tiles.count == background.geometries.count && source.tiles.count == pages.count,"Complete textured terrain before publishing")
        try check(source.tiles.contains { !$0.id.hasPrefix(anchor.id + "__") },"Window crosses storage boundaries")
        try check(!FileManager.default.fileExists(atPath:cache.appendingPathComponent("pins.json").path),"Browsing does not pin downloads permanently")
        if let path=ProcessInfo.processInfo.environment["RIDGE_ENTRY_QA_OUTPUT"] {
            let viewport=WorldCameraTransition.viewport(center:point,span:WorldCameraTransition.minimumAtlasSpan,aspect:4.0/3)
            try check(WorldMapSurface.covers(viewport,tiles:source.tiles.map { $0.mesh.bounds }),"The close-map viewport is filled by actual prepared terrain")
            let surfaces=source.tiles.compactMap { tile -> WorldPreview.Surface? in
                guard let geometry=background.geometries[tile.id],let page=pages[tile.id] else { return nil }
                return .init(geometry:geometry,image:page.image,bounds:tile.mesh.bounds)
            }
            let image=try WorldPreview.overhead(viewport:viewport,frame:source.frame,surfaces:surfaces,background:nil,width:1024,height:768)
            guard let destination=CGImageDestinationCreateWithURL(URL(fileURLWithPath:path) as CFURL,"public.png" as CFString,1,nil) else { throw RidgeError.message("Could not export close-map fixture") }
            CGImageDestinationAddImage(destination,image,nil)
            try check(CGImageDestinationFinalize(destination),"Actual prepared close-map surface exports for visual inspection")
        }

        // A semantic routing update must replace a retained graph even when
        // every terrain tile and the camera position are unchanged.
        var staleSnapshot = await first.snapshot()
        guard let changedPart = staleSnapshot.parts.firstIndex(where: { !$0.graph.edges.isEmpty && $0.connected }) else { throw RidgeError.message("Missing routing update fixture") }
        staleSnapshot.parts[changedPart].source.graph.sha256 = String(repeating:"0",count:64)
        staleSnapshot.parts[changedPart].graph = WalkingGraph(nodes:[],edges:[])
        let refreshedStore = WorldLandscapeStore(cacheURL:cache)
        _ = try await refreshedStore.window(center:point,radius:5000,frame:anchor.bounds,catalog:catalog,root:root,previous:staleSnapshot)
        let refreshedSnapshot = await refreshedStore.snapshot()
        let restoredPart = refreshedSnapshot.parts.first { $0.source.id == staleSnapshot.parts[changedPart].source.id }
        try check(restoredPart?.graph.edges.isEmpty == false,"A routing-only publication replaces an old resident graph")
        try check(restoredPart?.source.graph.sha256 != String(repeating:"0",count:64),"Reload uses the catalogue's current graph checksum")

        let shifted = GeoPoint(latitude:point.latitude,longitude:point.longitude+0.045)
        let second = WorldLandscapeStore(cacheURL:cache)
        let nextBegan = Date()
        let progress = ProgressProbe()
        let (next,_,nextGraph,nextBackground,nextPages) = try await second.window(center:shifted,radius:5000,frame:source.frame,catalog:catalog,root:root,previous:await first.snapshot(),priority:WorldWindow.leadingPoint(from:point,to:shifted),progress: { _,_,background,pages in
            await progress.receive(background,pages)
        })
        print("Shifted window: \(next.tiles.count) tiles, \(Date().timeIntervalSince(nextBegan)) s")
        try check(progress.batches.count > 1,"Additions publish in multiple batches before the final window")
        for (geometry,maps) in progress.batches {
            try check(geometry==maps && maps.count<=32,"Each published batch contains complete textured terrain and at most 32 tiles")
        }
        let streamed=progress.batches.reduce(into:Set<String>()) { $0.formUnion($1.1) }
        let lead=WorldWindow.leadingPoint(from:point,to:shifted)
        try check(lead.longitude>shifted.longitude && lead.distance(to:shifted)<1510,"Preparation leads actual travel by at most 1.5 km")
        try check(source.frame == next.frame,"Camera frame stays fixed across region boundaries")
        let shared = Set(source.tiles.map(\.id)).intersection(next.tiles.map(\.id))
        let removed = Set(source.tiles.map(\.id)).subtracting(next.tiles.map(\.id))
        let added = Set(next.tiles.map(\.id)).subtracting(source.tiles.map(\.id))
        try check(added.isSubset(of:streamed),"Every new tile is published incrementally, not held until completion")
        try check(!shared.isEmpty && !removed.isEmpty && !added.isEmpty,"Window moves, rather than accumulating every visited tile")
        for id in shared {
            try check(pages[id]!.image === nextPages[id]!.image,"Existing vector textures are reused")
            if (background.meshes[id] != nil) == (nextBackground.meshes[id] != nil) {
                try check(background.geometries[id] === nextBackground.geometries[id],"Existing terrain geometry is reused")
            }
        }
        let index = WorldTileIndex(tiles:next.tiles)
        for tile in next.tiles {
            for point in [tile.mesh.bounds.center,tile.mesh.bounds.point(u:0,v:0),tile.mesh.bounds.point(u:1,v:1)] {
                try check(index.tile(at:point)?.id == next.tiles.first(where: { $0.mesh.bounds.contains(point) })?.id,"Spatial lookup matches terrain selection at centres and shared corners")
            }
        }
        try check(index.tile(at:GeoPoint(latitude:0,longitude:0)) == nil,"No terrain invented outside the index")
        let adaptiveBytes = next.tiles.filter { nextBackground.meshes[$0.id] != nil }.reduce(Int64(0)) { $0 + ($1.background?.residentBytes ?? 0) }
        try check(adaptiveBytes <= WorldWindow.backgroundBudget,"One background memory budget for every region")
        let requests = WorldWorkingSet.requests(source:next,center:shifted,distance:2000)
        let fineIDs = Set(requests.filter(\.fine).map(\.id))
        try check(next.tiles.filter { fineIDs.contains($0.id) }.reduce(Int64(0)) { $0+$1.mesh.residentBytes } <= WorldWorkingSet.meshBudget,"Fine geometry remains bounded")
        try check(!graph.nodes.isEmpty && !nextGraph.nodes.isEmpty,"Walking paths survive window changes")
        var flightTiles:[WorldTile]=[],flightRegions=Set<String>(),expected:[Float]=[]
        for tile in next.tiles {
            guard let region=catalog.region(at:tile.mesh.bounds.center),flightRegions.insert(region.id).inserted else { continue }
            let prepared=try await second.prepare(tile,request:.init(id:tile.id,pixels:128,fine:true),sourceBounds:next.frame,previous:nextPages[tile.id])
            flightTiles.append(tile);expected.append(Float(prepared.mesh!.elevation(at:tile.mesh.bounds.center)!))
            if flightTiles.count==3 { break }
        }
        let preflightReader=WorldLandscapeStore(cacheURL:cache)
        let (flightHeights,_)=try await preflightReader.flightElevations(flightTiles.map { $0.mesh.bounds.center },catalog:catalog,root:root,saved:flightTiles.map { $0.mesh.bounds })
        try check(flightTiles.count==3,"Flight preflight fixture crosses three storage regions")
        for i in expected.indices { try check(abs((flightHeights[i] ?? -9999)-expected[i])<0.001,"Whole-route preflight reads exact cached fine heights across source boundaries") }
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

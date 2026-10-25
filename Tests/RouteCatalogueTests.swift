import Foundation

@main struct RouteCatalogueTests {
    @MainActor static func main() async throws {
        var checks=0
        func check(_ condition:Bool,_ message:String) throws { checks+=1;if !condition { throw RidgeError.message(message) } }
        func point(_ x:Double,_ y:Double=0.5)->RoutePoint { .init(coordinate:.init(latitude:53+y*0.01,longitude:-4+x*0.01),elevation:100) }
        func box(_ lo:Double,_ hi:Double)->GeoBounds { .init(minLatitude:53,minLongitude:-4+lo*0.01,maxLatitude:53.01,maxLongitude:-4+hi*0.01) }
        func route(_ points:[RoutePoint])->RidgeRoute { .init(name:"Saved route",regionID:"old-window-id",segments:[.init(points:points,mode:"imported")]) }
        let track=route([point(0.1),point(1.9)]),saved=[box(0,1),box(1,2)]
        let full=RouteEngine.offlineCoverage(for:track,in:saved)
        try check(full.isComplete && full.openingPoint==track.points[0].coordinate,"Adjacent downloaded tiles cover a route without matching its old region ID")
        let hole=[box(0,0.6),box(1.4,2)]
        let partial=RouteEngine.offlineCoverage(for:track,in:hole)
        try check(!partial.isComplete && partial.openingPoint != nil,"Saved endpoints cannot hide a gap along a sparse GPX leg")
        let passing=RouteEngine.offlineCoverage(for:route([point(-1),point(3)]),in:[box(0,2)])
        try check(!passing.isComplete && passing.openingPoint.map { box(0,2).contains($0) } == true,"A saved part between GPX samples can still be opened")
        let disconnected=RidgeRoute(name:"Disconnected GPX",regionID:"old",segments:[.init(points:[point(0.1),point(0.4)],mode:"imported"),.init(points:[point(1.6),point(1.9)],mode:"imported")])
        try check(RouteEngine.offlineCoverage(for:disconnected,in:hole).isComplete,"GPX breaks do not invent an uncovered connecting leg")
        try check(RouteEngine.offlineCoverage(for:track,in:[]).openingPoint==nil,"No completed download means no world-map opening")
        try check(RouteEngine.offlineCoverage(for:route([point(4),point(5)]),in:saved).openingPoint==nil,"A download elsewhere does not make this route available")
        let draft=RidgeRoute(name:"Draft",regionID:"old",waypoints:[.init(point:point(0.2))])
        try check(RouteEngine.offlineCoverage(for:draft,in:saved).isComplete,"One-point saved drafts remain reopenable")
        let invalid=route([.init(coordinate:.init(latitude:.nan,longitude:0),elevation:nil)])
        try check(RouteEngine.offlineCoverage(for:invalid,in:saved).openingPoint==nil,"Invalid route coordinates cannot enter terrain")
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("ridge-route-catalogue-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let routeStore=RouteStore(directory:root.appendingPathComponent("Routes"))
        try await routeStore.save(track)
        let preferencesName="ridge-route-catalogue-"+UUID().uuidString,preferences=UserDefaults(suiteName:preferencesName)!
        defer { preferences.removePersistentDomain(forName:preferencesName) }
        // Fresh AppStore, no legacy packs and no resident terrain: this is the
        // catalogue's broken reopening case after leaving Explore or relaunching.
        let store=AppStore(packs:PackStore(root:root.appendingPathComponent("Areas")),routeStore:routeStore,preferences:preferences)
        store.routes=try await routeStore.load();store.tab = .routes
        try check(store.entries.isEmpty && store.worldTerrain==nil,"Regression starts without old packs or a render window")
        store.openRoute(track,savedWorldBounds:saved)
        try check(store.activeRoute?.id==track.id && store.tab == .explore && store.isWorldBrowsing,"A persisted world route reopens directly into Explore")
        try check(store.worldRouteFocus==track.points[0].coordinate && store.errorMessage==nil,"The saved route queues a geographic focus without a false missing-map error")
        try check(store.activeTerrain==nil && !store.editing,"Map geometry can load after selecting the route, without a legacy planner sheet")
        try check(store.activeRoute?.regionID=="old-window-id","Reopening does not rewrite the route's source association")
        for _ in 0..<3 {
            store.closeTerrain();store.worldTerrain=nil;store.worldRouteFocus=nil;store.tab = .routes
            store.openRoute(track,savedWorldBounds:saved)
            try check(store.activeRoute?.id==track.id && store.worldRouteFocus != nil && store.errorMessage==nil,"The same route can be reopened repeatedly")
        }
        let level=TerrainLOD(spacing:4,width:2,height:2,file:"unused",byteCount:16,sha256:String(repeating:"0",count:64))
        let manifest=RegionManifest(schemaVersion:1,id:"resident-window",name:"Window",subtitle:"",bounds:box(4,6),sourceResolution:4,heightScale:1,noDataValue:-9999,levels:[level],textures:[],graphFile:nil,graphSHA256:nil,graphByteCount:nil,places:[],sources:[],defaultSpacing:4,version:"1",summary:"",verticalDatum:nil)
        store.worldTerrain=LoadedTerrain(manifest:manifest,level:level,heights:[100,100,100,100],textureURLs:[],graph:nil,directory:root)
        store.activeTerrain=store.worldTerrain
        store.openRoute(track,savedWorldBounds:saved)
        try check(store.activeRoute?.id==track.id && store.activeTerrain==nil,"An unrelated loaded window cannot block a route on another saved map")
        store.closeTerrain();store.errorMessage=nil;store.worldRouteFocus=nil
        store.openRoute(route([point(-0.5),point(0.5)]),savedWorldBounds:saved)
        try check(store.activeRoute != nil && store.worldRouteFocus.map { box(0,2).contains($0) } == true,"Partly downloaded routes open at a saved position")
        store.closeTerrain();store.errorMessage=nil;store.worldRouteFocus=nil;store.tab = .routes
        var cached=store.worldTerrain!;cached.manifest.bounds=box(0,2);store.worldTerrain=cached
        store.openRoute(track,savedWorldBounds:[])
        try check(store.activeRoute==nil && store.errorMessage != nil && store.tab == .routes,"Resident cached geometry cannot masquerade as a completed offline download")
        let persisted=try await routeStore.load()
        try check(persisted.count==1 && persisted[0].id==track.id && persisted[0].regionID==track.regionID,"Reopening leaves saved route data intact")
        let village=MapPlace(id:"village",name:"Llanberis",coordinate:point(0.2).coordinate,kind:"village",elevation:nil)
        try check(RouteEngine.suggestedRouteName(start:nil,places:[village])=="New route","An unplaced draft has a plain title")
        try check(RouteEngine.suggestedRouteName(start:point(0.2).coordinate,places:[village])=="Walk from Llanberis","The start point supplies a nearby place name")
        try check(RouteEngine.suggestedRouteName(start:point(0.2).coordinate,places:[],areaName:"Eryri")=="Eryri walk","A meaningful named area is a fallback")
        try check(RouteEngine.suggestedRouteName(start:point(0.2).coordinate,places:[],areaName:"z10-x500-y333 (3, 3)")=="My walk","Storage tile codes never become user-facing titles")
        try check(RouteEngine.suggestedRouteName(start:point(0.2).coordinate,places:[],areaName:"Terrain 53.0, -4.0")=="My walk","Coordinate-like area names stay out of the title")
        let naming=RouteStore(directory:root.appendingPathComponent("Naming"))
        var legacy=track;legacy.name="z10-x500-y333 (3, 3) route";legacy.notes="Keep my notes"
        var personal=track;personal.id=UUID();personal.name="My 2026 ridge walk"
        try await naming.save(legacy);try await naming.save(personal)
        let before=try await naming.load(),repaired=try await naming.repairTileNames(places:[village])
        try check(repaired.first(where:{$0.id==legacy.id})?.name=="Walk from Llanberis","Existing tile-style titles are repaired")
        try check(repaired.first(where:{$0.id==personal.id})?.name==personal.name,"Existing custom titles stay unchanged")
        for original in before {
            var expected=original
            if original.id==legacy.id { expected.name="Walk from Llanberis" }
            try check(repaired.first(where:{$0.id==original.id})==expected,"Title repair preserves dates, notes, waypoints and geometry")
        }
        let again=try await naming.repairTileNames(places:[])
        try check(again==repaired,"Title repair is idempotent")
        let draftStore=AppStore(packs:PackStore(root:root.appendingPathComponent("Draft areas")),routeStore:RouteStore(directory:root.appendingPathComponent("Draft routes")),preferences:preferences)
        var namingTerrain=cached;namingTerrain.manifest.places=[village]
        draftStore.activeTerrain=namingTerrain;draftStore.startRoute();draftStore.planningMode = .direct
        try check(draftStore.activeRoute?.name=="New route","The actual editor starts with a readable draft name")
        draftStore.tapTerrain(point(0.2).coordinate)
        while draftStore.isRouting { try await Task.sleep(for:.milliseconds(10)) }
        try check(draftStore.activeRoute?.name=="Walk from Llanberis","Adding the actual first waypoint assigns its place name")
        draftStore.startRoute();draftStore.planningMode = .direct
        draftStore.renameRoute(draftStore.activeRoute!,to:"My birthday walk")
        while draftStore.isRouting { try await Task.sleep(for:.milliseconds(10)) }
        draftStore.tapTerrain(point(0.2).coordinate)
        while draftStore.isRouting { try await Task.sleep(for:.milliseconds(10)) }
        try check(draftStore.activeRoute?.name=="My birthday walk","A custom draft title survives the first waypoint")
        print("PASS \(checks) saved-route catalogue, download union, missing-map and repeated reopen checks")
    }
}

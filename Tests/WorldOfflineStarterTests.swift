import Foundation

@main struct WorldOfflineStarterTests {
    static func main() async throws {
        var checks=0
        func check(_ value:Bool,_ message:String) throws {
            guard value else { throw RidgeError.message(message) }
            checks+=1;print("PASS: \(message)");fflush(stdout)
        }
        guard let included=WorldBundledMaps.included else { throw RidgeError.message("Bundled test fixture not found at \(Bundle.main.bundleURL)") }
        try check(!WorldBundledMaps.downloadsEnabled,"An included-only build opens without the Apple download framework")
        let cache=FileManager.default.temporaryDirectory.appendingPathComponent("ridge-starter-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:cache) }
        let root=try WorldLibrary.root(mode:"cloud",local:"")
        try check(root==WorldAppleAssets.root,"Map addresses retain the identities used by later Apple downloads and saved routes")
        try check(try WorldLibrary.root(mode:"local",local:"bad")==root,"An old development-server preference cannot block the offline release")
        let catalog=try await WorldCatalogStore(cacheURL:cache).open(root:root)
        try check(catalog.sources.count==282,"Fresh catalogue opens directly from the 282 included sections")
        let areas=try WorldRegionPack.load(url:URL(fileURLWithPath:CommandLine.arguments[1]))
        let selected=["park-eryri","park-lake-district","park-peak-district","area-chilterns-thames-valley"]
        try check(Set(try WorldRegionPack.load().map(\.id))==Set(selected),"The starter map highlights only its four included areas")
        let bounds=WorldOfflineCoverage.savedBounds(at:cache)
        try check(bounds.count==included.index.coverage.count && !bounds.isEmpty,"Included terrain is available on a fresh offline installation")
        try check(try FileManager.default.contentsOfDirectory(atPath:cache.path).isEmpty,"Opening included coverage does not duplicate terrain into the download cache")
        for id in selected {
            let area=areas.first { $0.id==id }!,regions=area.sources(in:catalog)
            try check(!regions.isEmpty && included.contains(regions),"Included sections available for \(area.name)")
            let plan=WorldRegionDownloadPlan.completed(pack:area,catalog:catalog,root:root,cache:cache,saved:bounds)
            try check(plan?.bytes==0,"\(area.name) is ready without a download or a pack integrity scan")
            let region=regions[regions.count/2]
            let files=WorldSourceStore(cacheURL:cache,allowsNetwork:false)
            let source=try await files.manifest(address:root.appendingPathComponent(region.path).absoluteString,routing:region.routing,preferCached:true,recoverCoverage:false)
            let (_,overview,graph)=try await files.contents(of:source)
            try check(!overview.heights.isEmpty && !graph.nodes.isEmpty,"\(area.name) elevation and connected walking paths open with networking disabled")
            let reader=WorldSectionPack.open(sourceID:source.id,cache:cache)!
            let tile=source.tiles[source.tiles.count/2]
            let mesh=try reader.read(WorldMapAsset(file:tile.mesh.path,byteCount:tile.mesh.byteCount,sha256:tile.mesh.sha256))
            let vector=try reader.read(tile.map)
            try check(!mesh.isEmpty && !vector.isEmpty,"\(area.name) detailed terrain and cartography verify from the app bundle")
            print("COVERAGE: \(area.name): \(area.missingTerrain(in:catalog).count) missing land rectangles")
        }
        // Aylesbury town centre and established Chiltern walking locations.
        for point in [GeoPoint(latitude:51.8168,longitude:-0.8148),GeoPoint(latitude:51.752,longitude:-0.743),GeoPoint(latitude:51.739,longitude:-0.608)] {
            try check(bounds.contains { $0.contains(point) },"Offline terrain covers the Aylesbury / Chilterns sample at \(point.latitude), \(point.longitude)")
        }
        // Exercise the real section seam with the same graph join and walking
        // router used by the app, with network access disabled throughout.
        let west=catalog.region(at:GeoPoint(latitude:51.752,longitude:-0.743))!
        let east=catalog.region(at:GeoPoint(latitude:west.bounds.center.latitude,longitude:west.bounds.maxLongitude+0.001))!
        var parts:[WorldLandscapeStore.Part]=[]
        for region in [west,east] {
            let files=WorldSourceStore(cacheURL:cache,allowsNetwork:false)
            let source=try await files.manifest(address:root.appendingPathComponent(region.path).absoluteString,routing:region.routing,preferCached:true,recoverCoverage:false)
            let (_,overview,graph)=try await files.contents(of:source)
            parts.append(.init(source:source,overview:overview,graph:graph,files:files,connected:region.routing != nil))
        }
        let joined=try WorldLandscapeStore.joinGraphs(parts)
        let crossing=try RouteEngine.walkingSegment(from:west.bounds.center,to:east.bounds.center,graph:joined,snapDistance:5000)
        try check(west.id != east.id && crossing.points.count>2 &&
                  crossing.points.first!.coordinate.longitude<west.bounds.maxLongitude &&
                  crossing.points.last!.coordinate.longitude>west.bounds.maxLongitude,
                  "A real Chilterns walking route crosses a bundled section boundary offline")
        try WorldOfflineCoverage.removeDownloads(in:nil,catalog:catalog,at:cache)
        try check(WorldOfflineCoverage.savedBounds(at:cache).count==bounds.count,"Removing downloaded maps preserves all included terrain")
        let first=catalog.sources[0],asset=first.pack!
        let address=root.appendingPathComponent(first.path).absoluteString
        var updated=try JSONDecoder().decode(WorldSource.self,from:included.metadata(id:first.id))
        updated.name="Updated cached map"
        try JSONEncoder().encode(updated).write(to:cache.appendingPathComponent(AdaptiveTerrainCodec.hash(Data(address.utf8))+".index"))
        let upgraded=try await WorldSourceStore(cacheURL:cache,allowsNetwork:false).manifest(address:address,preferCached:true,recoverCoverage:false)
        try check(upgraded.name==updated.name,"A future downloaded manifest takes precedence during an offline reopen")
        let dir=WorldSectionPack.directory(cache);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let local=WorldSectionPack.file(asset,cache:cache)
        try FileManager.default.copyItem(at:included.root.appendingPathComponent(included.index.sections[first.id]!.packPath),to:local)
        try WorldSectionPack.install(asset,sourceID:first.id,cache:cache)
        try check(WorldSectionPack.open(sourceID:first.id,cache:cache)?.url==local,"An installed download takes precedence over the bundled baseline")
        try FileManager.default.removeItem(at:local)
        try check(WorldSectionPack.open(sourceID:first.id,cache:cache)?.url != local,"A missing downloaded copy falls back to the immutable bundled map")
        print("Offline starter: \(checks) checks passed")
    }
}

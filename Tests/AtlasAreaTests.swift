import Foundation

private struct AreaFailure: Error, CustomStringConvertible { let description: String }
@MainActor @main struct AtlasAreaTests {
    static var assertions = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        if !value() { throw AreaFailure(description: message) }
    }
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        var source = try JSONDecoder().decode(RegionManifest.self, from: Data(contentsOf: directory.appendingPathComponent("pack.json")))
        // Exercise selection and persistence without repeatedly copying context imagery.
        source.horizon = nil; source.cartography = nil
        let original = source
        let entry = PackEntry(manifest: source, directory: directory, installed: false)
        let context = BudgetFixtures.capable
        for row in 0..<source.grid!.rows { for column in 0..<source.grid!.columns {
            for fraction in [0.1, 0.9] {
                let point = source.bounds.point(u: (Double(column) + fraction) / Double(source.grid!.columns), v: (Double(row) + fraction) / Double(source.grid!.rows))
                let tile = AtlasAreaPlanner.tile(at: point, entries: [entry])!
                let picked = AtlasAreaPlanner.propose(bounds: tile, entries: [entry], context: context).preview!
                try check(picked.grid?.columns == 1 && picked.grid?.rows == 1 && picked.bounds.contains(point), "Taps throughout a visible cell choose exactly that cell")
                try check(AtlasAreaPlanner.snapped(tile, entries: [entry]) == tile, "Exact tile edges remain stable through repeated snapping")
            }
        } }
        var tileMove = AtlasAreaPlanner.tile(at: source.bounds.center, entries: [entry])!
        for index in 0..<60 {
            let point = source.bounds.point(u: Double(index % 13 + 1) / 15, v: Double(index % 11 + 1) / 13)
            tileMove = AtlasAreaPlanner.snapped(AtlasAreaPlanner.recentered(tileMove, on: point), entries: [entry], preservingSize: true)!
            let grid = AtlasAreaPlanner.propose(bounds: tileMove, entries: [entry], context: context).preview!.grid!
            try check(grid.columns == 1 && grid.rows == 1, "Moving a snapped tile never adds rows or columns")
        }
        let edgeMove = AtlasAreaPlanner.recentered(tileMove, on: source.bounds.point(u: 0, v: 0))
        let edge = AtlasAreaPlanner.snapped(edgeMove, entries: [entry], preservingSize: true)!
        try check(AtlasAreaPlanner.contains(source.bounds, edge), "Moving across an outer edge stops at complete prepared tiles")
        try check(AtlasAreaPlanner.tile(at: source.bounds.point(u: 2, v: 2), entries: [entry]) == nil, "An unprepared location never selects a distant tile")
        func rect(_ u0: Double, _ v0: Double, _ u1: Double, _ v1: Double) -> GeoBounds {
            let a = source.bounds.point(u: u0, v: v0), b = source.bounds.point(u: u1, v: v1)
            return GeoBounds(minLatitude: min(a.latitude,b.latitude), minLongitude: min(a.longitude,b.longitude), maxLatitude: max(a.latitude,b.latitude), maxLongitude: max(a.longitude,b.longitude))
        }
        let requested = rect(6.1/16, 9.1/16, 6.9/16, 9.9/16)
        let proposal = AtlasAreaPlanner.propose(bounds: requested, entries: [entry], context: context)
        try check(proposal.canOpen && proposal.source?.id == source.id, "Rectangle resolves to local source without a pack-selection page")
        let preview = proposal.preview!
        try check(AtlasAreaPlanner.contains(preview.bounds, requested), "Outward alignment never cuts off requested ground")
        try check(preview.grid?.columns == 1 && preview.grid?.rows == 1, "Internal storage alignment is minimal")
        try check(preview.name.hasPrefix("Around ") && !preview.name.contains("tiles"), "User-facing area name describes a place")
        let repeatProposal = AtlasAreaPlanner.propose(bounds: preview.bounds, entries: [entry], context: context)
        try check(repeatProposal.preview?.bounds == preview.bounds && repeatProposal.preview?.id == preview.id, "Snapped selection is stable without accumulating extra cells")
        for coordinates in [(0.01,0.01,0.06,0.06), (0.94,0.01,0.99,0.06), (0.01,0.94,0.06,0.99), (0.94,0.94,0.99,0.99)] {
            let bounds = rect(coordinates.0, coordinates.1, coordinates.2, coordinates.3)
            let selected = AtlasAreaPlanner.propose(bounds: bounds, entries: [entry], context: context)
            try check(selected.preview.map { AtlasAreaPlanner.contains($0.bounds,bounds) } == true, "Selection preserves coverage in each corner")
        }
        let beyond = rect(-0.1,0.2,0.3,0.4)
        let unavailable = AtlasAreaPlanner.propose(bounds: beyond, entries: [entry], context: context)
        try check(!unavailable.canOpen && unavailable.preview == nil, "Unavailable coverage is not silently clipped or claimed downloadable")
        var poor = context; poor.availableMemory = 1
        let rejected = AtlasAreaPlanner.propose(bounds: requested, entries: [entry], context: poor)
        try check(!rejected.canOpen && rejected.reason?.contains("smaller") == true, "Low memory rejects the area instead of silently reducing detail")
        try check(rejected.preview?.levels.contains(where: { $0.spacing == 4 }) == true, "Fixed detail remains the requested 4 m")
        var coarse = source; coarse.levels.removeAll { $0.spacing != 8 }; coarse.defaultSpacing = 8
        try check(!AtlasAreaPlanner.propose(bounds: requested, entries: [PackEntry(manifest: coarse, directory: directory, installed: true)], context: context).canOpen, "A coarse-only source does not pretend to provide 4 m")
        var savedManifest = preview; savedManifest.levels.removeAll { $0.spacing != 4 }; savedManifest.defaultSpacing = 4
        let saved = PackEntry(manifest: savedManifest, directory: directory, installed: true)
        try check(AtlasAreaPlanner.propose(bounds: preview.bounds, entries: [entry,saved], context: context).saved?.id == saved.id, "An exact saved rectangle can open directly")
        var widerScene = savedManifest
        widerScene.horizon = TerrainHorizon(far: TerrainBackdrop(bounds: source.bounds, levels: [], textures: []))
        try check(!AtlasAreaPlanner.reusable(savedManifest, for: widerScene, spacing: 4), "A saved primary rectangle must not hide newly available surroundings")
        try check(AtlasAreaPlanner.reusable(widerScene, for: savedManifest, spacing: 4), "A save with broader surroundings still satisfies a smaller scene")
        try check(AtlasAreaPlanner.reusable(widerScene, for: widerScene, spacing: 4), "A refreshed horizon reopens without repeated preparation")
        var different = savedManifest; different.defaultSpacing = 8; different.levels = preview.levels.filter { $0.spacing == 8 }
        try check(AtlasAreaPlanner.propose(bounds: preview.bounds, entries: [entry,PackEntry(manifest:different,directory:directory,installed:true)], context: context).saved == nil, "Saved coarse terrain does not satisfy a finer selection")
        let larger = rect(5.0/16,8.0/16,8.0/16,11.0/16)
        try check(AtlasAreaPlanner.propose(bounds:larger,entries:[entry],required:preview.bounds,context:context).canOpen, "Expansion accepts a containing rectangle")
        try check(!AtlasAreaPlanner.propose(bounds:requested,entries:[entry],required:preview.bounds,context:context).canOpen, "Expansion keeps the current area")
        var route = RidgeRoute(name:"Preserved route",regionID:preview.id)
        route.waypoints = [RouteWaypoint(point:RoutePoint(coordinate:source.bounds.point(u:0.9,v:0.9),elevation:nil),name:"Outside")]
        try check(!AtlasAreaPlanner.propose(bounds:larger,entries:[entry],required:preview.bounds,route:route,context:context).canOpen, "Expansion keeps every waypoint even before a segment exists")
        try check(source == original, "Preview operations never alter source manifests")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ridge-area-journey-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:root) }
        let packs = PackStore(root:root.appendingPathComponent("Areas"),bundledDirectory:nil)
        let store = AppStore(packs:packs,routeStore:RouteStore(directory:root.appendingPathComponent("Routes")))
        store.entries = [entry]
        store.openAtlasArea(proposal)
        let deadline = Date().addingTimeInterval(45)
        while store.activeTerrain == nil || store.isPreparing {
            guard Date() < deadline, store.errorMessage == nil else { throw AreaFailure(description:store.errorMessage ?? "Inline save timed out") }
            try await Task.sleep(for:.milliseconds(20))
        }
        try check(store.pendingPack == nil && !store.preparingFromAtlas, "Inline save reaches terrain without an intermediate selection sheet")
        try check(store.activeTerrain?.manifest.bounds == preview.bounds && store.activeTerrain?.level.spacing == 4, "Opened terrain matches the approved area and detail")
        try check(store.activeTerrain?.manifest.name == preview.name, "Saved landscape keeps its readable name")
        let installed = try await packs.installedManifest(id:preview.id)!
        try check(installed.bounds == preview.bounds, "Prepared rectangle is durable")
        let reopen = AtlasAreaPlanner.propose(bounds:preview.bounds,entries:[entry,PackEntry(manifest:installed,directory:root.appendingPathComponent("Areas").appendingPathComponent(installed.id),installed:true)],context:context)
        try check(reopen.saved != nil, "Repeating the selection reuses its saved area")
        store.closeTerrain(); store.openAtlasArea(reopen)
        while store.activeTerrain == nil || store.isPreparing { try await Task.sleep(for:.milliseconds(20)); guard Date() < deadline else { throw AreaFailure(description:"Reopen timed out") } }
        try check(store.activeTerrain?.manifest.id == installed.id, "Open saved area preserves identity")
        let firstHeights = store.activeTerrain!.heights
        let secondPoint = source.bounds.point(u: 12.5/16, v: 3.5/16)
        let moved = AtlasAreaPlanner.recentered(preview.bounds, on: secondPoint)
        try check(moved.center.distance(to: secondPoint) < 0.001, "A place tap moves the footprint to the tapped coordinate")
        try check(abs((moved.maxLatitude - moved.minLatitude) - (preview.bounds.maxLatitude - preview.bounds.minLatitude)) < 1e-10,
                  "Moving an area preserves the chosen span")
        var movingFootprint = requested
        for i in 0..<30 {
            movingFootprint = AtlasAreaPlanner.recentered(movingFootprint, on: source.bounds.point(u: i.isMultiple(of: 2) ? 0.25 : 0.7, v: 0.5))
            let checked = AtlasAreaPlanner.propose(bounds: movingFootprint, entries: [entry], context: context)
            try check(checked.preview!.grid!.columns <= 2 && checked.preview!.grid!.rows <= 2,
                      "Repeated moves keep the user's footprint small while storage rounds outward")
        }
        let second = AtlasAreaPlanner.propose(bounds: moved, entries: [entry, saved], context: context)
        try check(second.canOpen && second.saved == nil && second.preview?.id != preview.id,
                  "A second location cannot reuse the first location's saved area")
        store.closeTerrain(); store.openAtlasArea(second)
        let secondDeadline = Date().addingTimeInterval(45)
        while store.activeTerrain == nil || store.isPreparing {
            guard Date() < secondDeadline, store.errorMessage == nil else { throw AreaFailure(description: store.errorMessage ?? "Second location timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
        try check(store.activeTerrain?.manifest.bounds == second.preview?.bounds && store.activeTerrain?.manifest.bounds.contains(secondPoint) == true,
                  "Opening a moved selection loads the second geographic footprint")
        try check(store.activeTerrain!.heights != firstHeights, "Different selected locations load different native height samples")
        let unavailableMove = AtlasAreaPlanner.recentered(preview.bounds, on: source.bounds.point(u: 1.5, v: 1.5))
        let outside = AtlasAreaPlanner.propose(bounds: unavailableMove, entries: [entry, saved], context: context)
        try check(!outside.canOpen && outside.saved == nil, "Moving beyond coverage rejects the new location instead of opening the old save")
        print("PASS atlas rectangle journey: \(assertions) assertions")
    }
}

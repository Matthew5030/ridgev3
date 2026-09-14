import Foundation

private struct ExtensionFailure: Error, CustomStringConvertible { var description: String }

@MainActor @main struct AreaExtensionTests {
    private static var assertions = 0
    private static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        guard value() else { throw ExtensionFailure(description: message) }
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw ExtensionFailure(description: "Pass RidgeData.bundle") }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("regions/eryri-grid")
        var source = try JSONDecoder().decode(RegionManifest.self, from: Data(contentsOf: directory.appendingPathComponent("pack.json")))
        let independentMap = source.cartography
        source.cartography = nil // Existing checks exercise older band-map sources.
        try PackStore.validate(source)
        guard let grid = source.grid else { throw ExtensionFailure(description: "The real source has no original grid") }
        let entry = PackEntry(manifest: source, directory: directory, installed: false)
        let context = BudgetFixtures.capable
        func point(_ column: Double, _ row: Double) -> GeoPoint {
            source.bounds.point(u: column / Double(grid.columns), v: row / Double(grid.rows))
        }
        func loaded(_ column: Int, _ row: Int, columns: Int = 1, rows: Int = 1) -> LoadedTerrain {
            let selection = grid.rectangle(from: TerrainCell(column: column, row: row),
                                           to: TerrainCell(column: column + columns - 1, row: row + rows - 1))!
            var manifest = AreaCropper.preview(manifest: source, selection: selection, context: context)
            manifest.horizon = nil
            let level = manifest.levels.first { $0.spacing == 32 }!
            manifest.levels = [level]; manifest.defaultSpacing = 32
            return LoadedTerrain(manifest: manifest, level: level, heights: Array(repeating: 100, count: level.sampleCount),
                                 textureURLs: [], graph: nil, directory: directory)
        }
        let terrain = loaded(5, 5)
        func propose(_ destination: GeoPoint, _ entries: [PackEntry] = [entry], route: RidgeRoute? = nil,
                     in current: LoadedTerrain? = nil, budget: TerrainBudget.Context? = nil) -> AreaExtensionProposal {
            AreaExtensionPlanner.propose(destination: destination, terrain: current ?? terrain, route: route,
                                         entries: entries, context: budget ?? context)
        }
        func assertContains(_ proposal: AreaExtensionProposal, _ points: [GeoPoint], _ label: String) throws {
            try check(proposal.unavailableReason == nil && proposal.source != nil && proposal.selection != nil && proposal.preview != nil,
                      label + " has a complete, available proposal")
            try check(points.allSatisfy(proposal.preview!.bounds.contains), label + " contains every required geographic point")
        }

        let destination = point(8.5, 5.5)
        let basic = propose(destination)
        try assertContains(basic, [destination, terrain.manifest.bounds.point(u: 0, v: 0), terrain.manifest.bounds.point(u: 1, v: 1)], "Eastward extension")
        try check(basic.source!.id == source.id && basic.source!.directory == directory, "The proposed source is the real local pack")
        try check(basic.preview!.grid!.originColumn == grid.originColumn + 5 && basic.preview!.grid!.originRow == grid.originRow + 4,
                  "The halo surrounds the destination without padding the old western edge")
        try check(basic.preview!.grid!.columns == 5 && basic.preview!.grid!.rows == 3 && basic.additionalTileCount == 14,
                  "Destination padding gives the expected minimal original tile rectangle and additional count")
        try check(basic.preview!.levels.map(\.spacing) == [1, 2, 4, 8, 16, 32], "Proposal keeps all real source LODs for an explicit choice")
        try check(basic.preview!.id == basic.preview!.grid!.stableID && basic.preview!.name == basic.preview!.grid!.name(sourceName: source.name),
                  "The review uses stable original-grid identity and the actual source collection name")
        try check(basic.preview!.horizon?.near?.levels.map(\.spacing) == [8, 16], "Cached proposal retains raw surrounding-terrain alternatives")
        print("PASS exact real-grid extension, destination-only halo and reusable preview metadata")

        let eastEdge = propose(point(8, 5.5))
        try check(eastEdge.preview!.grid!.columns == 4 && eastEdge.preview!.grid!.rows == 3 && eastEdge.additionalTileCount == 11,
                  "An exact eastern grid edge does not add an accidental extra column")
        let northEdge = propose(point(5.5, 3))
        try check(northEdge.preview!.grid!.originColumn == grid.originColumn + 4 && northEdge.preview!.grid!.originRow == grid.originRow + 2
                  && northEdge.preview!.grid!.columns == 3 && northEdge.preview!.grid!.rows == 4,
                  "Exact north/south edges respect the grid's reversed latitude direction")
        let corner = propose(point(0, 0))
        try check(corner.preview!.grid!.originColumn == grid.originColumn && corner.preview!.grid!.originRow == grid.originRow
                  && corner.preview!.grid!.columns == 6 && corner.preview!.grid!.rows == 6,
                  "Destination padding clips at source boundaries without growing around the old area")
        for cell in [(0,0), (15,0), (0,15), (15,15), (0,7), (15,7), (7,0), (7,15)] {
            let current = loaded(cell.0, cell.1)
            let target = point(cell.0 < 8 ? 8.5 : 7.5, cell.1 < 8 ? 8.5 : 7.5)
            let proposal = propose(target, in: current)
            try assertContains(proposal, [target, current.manifest.bounds.point(u: 0, v: 0), current.manifest.bounds.point(u: 1, v: 1)], "Boundary-cell extension")
        }
        print("PASS exact edges, source clipping and all boundary directions")

        var route = RidgeRoute(name: "Saved route with a detour", regionID: terrain.manifest.id,
                               createdAt: Date(timeIntervalSince1970: 10), modifiedAt: Date(timeIntervalSince1970: 20))
        let start = RoutePoint(coordinate: point(5.5, 5.5), elevation: 101)
        let detour = RoutePoint(coordinate: point(2.5, 2.5), elevation: 812)
        let finish = RoutePoint(coordinate: point(7.5, 5.5), elevation: nil)
        route.waypoints = [RouteWaypoint(point: start, name: "Start"), RouteWaypoint(point: finish, name: "Finish")]
        route.segments = [RouteSegment(points: [start, detour, finish], mode: "paths")]
        route.notes = "Keep this draft exactly as saved."
        let unchangedRoute = route, unchangedManifest = terrain.manifest
        let following = propose(destination, route: route)
        try assertContains(following, route.points.map(\.coordinate) + [destination], "Route-aware extension")
        try check(following.preview!.grid!.originColumn == grid.originColumn + 2 && following.preview!.grid!.originRow == grid.originRow + 2,
                  "Actual segment detours determine coverage, not only waypoints")
        try check(following.preview!.grid!.columns == 8 && following.preview!.grid!.rows == 5,
                  "Old route geometry is preserved without adding a halo to every detour")
        try check(route == unchangedRoute && terrain.manifest == unchangedManifest, "Proposal never changes saved route identity, coordinates, elevations, notes or current-area metadata")
        let wide = loaded(1, 1, columns: 8, rows: 8)
        let wideProposal = propose(point(10.5, 5.5), in: wide)
        try check(wideProposal.preview!.grid!.originColumn == grid.originColumn + 1 && wideProposal.preview!.grid!.originRow == grid.originRow + 1
                  && wideProposal.preview!.grid!.columns == 11 && wideProposal.preview!.grid!.rows == 8,
                  "The complete old planning area remains, even where it has no route points")
        print("PASS real route geometry, saved draft preservation and complete old-area coverage")

        var coarse = source; coarse.id = "saved-coarse-source"; coarse.name = "Saved coarse source"
        coarse.levels = coarse.levels.filter { $0.spacing >= 8 }; coarse.defaultSpacing = 8
        let coarseEntry = PackEntry(manifest: coarse, directory: directory, installed: true)
        try check(propose(destination, [coarseEntry, entry]).source!.id == source.id, "Fine original data takes priority over an installed coarse source")
        var legacy = source; legacy.id = "legacy-rectangle"; legacy.grid = nil
        let legacyEntry = PackEntry(manifest: legacy, directory: directory, installed: false)
        try check(propose(destination, [legacyEntry, coarseEntry]).source!.id == coarse.id, "Compatible original grid takes priority over an unrelated finer rectangle")
        let legacyProposal = propose(destination, [legacyEntry])
        try assertContains(legacyProposal, [destination, terrain.manifest.bounds.point(u: 0, v: 0), terrain.manifest.bounds.point(u: 1, v: 1)], "Legacy rectangular fallback")
        try check(legacyProposal.additionalTileCount == nil && legacyProposal.preview!.grid == nil, "Legacy selection never invents original tile IDs or counts")
        var savedFine = source; savedFine.id = "saved-fine-source"
        let savedEntry = PackEntry(manifest: savedFine, directory: directory, installed: true)
        try check(propose(destination, [entry, savedEntry]).source!.id == savedFine.id, "Equally capable saved coverage can be reused")
        var oldCrop = AreaCropper.preview(manifest: source,
            selection: grid.rectangle(from: TerrainCell(column: 5, row: 4), to: TerrainCell(column: 8, row: 7))!, context: context)
        oldCrop.levels = oldCrop.levels.filter { $0.spacing == 1 }; oldCrop.defaultSpacing = 1
        oldCrop.detailTextures = nil
        // Reproduce an older installed crop with one quiet image per surrounding
        // band. File payloads are deliberately irrelevant to this metadata-only
        // proposal test; preparation still verifies actual files before use.
        func quiet(_ layer: TerrainBackdrop?, name: String, pixels: Int) -> TerrainBackdrop? {
            guard var layer, let texture = layer.textures.first else { return nil }
            layer.levels = [layer.levels[0]]
            layer.textures = [MapTexture(file: name, width: pixels, height: pixels, byteCount: 1024,
                sha256: texture.sha256, bounds: layer.bounds)]
            return layer
        }
        oldCrop.horizon = TerrainHorizon(near: quiet(oldCrop.horizon?.near, name: "old-near-map.png", pixels: 2048),
                                         far: quiet(oldCrop.horizon?.far, name: "old-far-map.png", pixels: 1024))
        try PackStore.validate(oldCrop)
        let oldCropEntry = PackEntry(manifest: oldCrop, directory: directory, installed: true)
        let refreshed = propose(destination, [oldCropEntry, entry])
        try check(refreshed.source?.id == source.id && refreshed.preview == basic.preview,
                  "The complete original source wins over an older installed 1m crop with quiet surrounding maps")
        try check(refreshed.preview!.horizon!.near!.textures.count > 1 && refreshed.preview!.horizon!.far!.textures.count > 1,
                  "Extending from an old crop retains current tiled cartography and broad prepared coverage")
        oldCrop.levels = AreaCropper.preview(manifest: source,
            selection: grid.rectangle(from: TerrainCell(column: 5, row: 4), to: TerrainCell(column: 8, row: 7))!, context: context).levels
        try check(propose(destination, [PackEntry(manifest: oldCrop, directory: directory, installed: true), entry]).source?.id == source.id,
                  "Original detail-map availability outranks saved status even when both sources offer every terrain level")
        var fullWithoutDetails = source; fullWithoutDetails.detailTextures = nil
        oldCrop.levels = oldCrop.levels.filter { $0.spacing == 1 }
        try check(propose(destination, [oldCropEntry, PackEntry(manifest: fullWithoutDetails, directory: directory, installed: false)]).source?.id == source.id,
                  "A complete local collection retains coarser terrain choices instead of selecting a saved 1m-only crop")
        var bad = source; bad.id = "unsafe/manifest"
        try check(propose(destination, [PackEntry(manifest: bad, directory: directory, installed: true), entry]).source!.id == source.id,
                  "Invalid source metadata is skipped in favour of a valid local pack")
        print("PASS deterministic local-source ranking and legacy rectangle support")
        if let independentMap {
            var current = source; current.id = "current-cartography"; current.cartography = independentMap
            let modern = propose(destination, [entry, PackEntry(manifest: current, directory: directory, installed: false)])
            try check(modern.source?.id == current.id && modern.preview?.cartography != nil, "A compatible independent map source wins over legacy image bands")
            try check(modern.preview?.textures.isEmpty == true && modern.preview?.horizon?.layers.allSatisfy { $0.textures.isEmpty } == true,
                      "Extending with independent cartography never restores legacy band maps")
        }

        let inside = propose(point(5.5, 5.5))
        try check(inside.source == nil && inside.unavailableReason?.contains("already inside") == true, "A point already available for planning does not create needless extra tiles")
        let beyond = GeoPoint(latitude: source.bounds.maxLatitude + 0.005, longitude: source.bounds.center.longitude)
        try check(source.horizon!.far!.bounds.contains(beyond), "Unavailable destination fixture is visibly inside the saved broad horizon")
        let viewOnly = propose(beyond)
        try check(viewOnly.source == nil && viewOnly.unavailableReason?.contains("Import a compatible terrain pack") == true, "Horizon imagery never masquerades as a source of planning coverage")
        let remote = PackEntry(manifest: source, directory: URL(string: "https://example.invalid/terrain")!, installed: false)
        try check(propose(destination, [remote]).source == nil, "A remote URL is never turned into an automatic download")
        var left = AreaCropper.preview(manifest: source, selection: grid.rectangle(from: TerrainCell(column: 0, row: 0), to: TerrainCell(column: 6, row: 15))!, context: context)
        var right = AreaCropper.preview(manifest: source, selection: grid.rectangle(from: TerrainCell(column: 7, row: 0), to: TerrainCell(column: 15, row: 15))!, context: context)
        left.horizon = nil; right.horizon = nil
        let halves = [PackEntry(manifest: left, directory: directory, installed: true), PackEntry(manifest: right, directory: directory, installed: true)]
        try check(propose(destination, halves).source == nil, "Separate partial sources are never silently stitched into an unsupported union")
        let outsideRoute = RidgeRoute(name: "Outside source", regionID: terrain.manifest.id, waypoints: [RouteWaypoint(point: RoutePoint(coordinate: beyond, elevation: nil))])
        try check(propose(destination, route: outsideRoute).source == nil, "A source covering destination alone cannot drop an outlying saved route point")
        try check(propose(GeoPoint(latitude: .nan, longitude: 0)).source == nil, "Invalid destinations fail before coordinate arithmetic")
        var invalidRoute = route; invalidRoute.segments[0].points[1].coordinate.latitude = .infinity
        try check(propose(destination, route: invalidRoute).unavailableReason?.contains("invalid coordinate") == true, "Invalid route geometry fails safely")
        var invalidTerrain = terrain; invalidTerrain.manifest.grid!.columns = Int.max
        try check(propose(destination, in: invalidTerrain).source == nil, "Malformed current grid dimensions fail safely")
        var noGraph = source; noGraph.graphFile = nil; noGraph.graphSHA256 = nil; noGraph.graphByteCount = nil
        let noGraphProposal = propose(destination, [PackEntry(manifest: noGraph, directory: directory, installed: false)])
        try check(noGraphProposal.source != nil && noGraphProposal.preview!.graphFile == nil, "Coverage proposal preserves missing graph metadata and never claims path connectivity")
        print("PASS view-only horizon, partial coverage, malformed input and absent-path honesty")

        var pressured = context; pressured.availableMemory = 0
        let lowMemory = propose(destination, budget: pressured)
        try check(lowMemory.preview?.bounds == basic.preview?.bounds && lowMemory.selection == basic.selection && lowMemory.unavailableReason == nil,
                  "Temporary device headroom does not rewrite geographic coverage or masquerade as missing source data")
        try check(TerrainBudget.recommendedSpacing(for: lowMemory.preview!, context: pressured) == nil,
                  "A valid extension is still subject to the independent live device budget")
        for _ in 0..<10 {
            let repeated = propose(destination, [legacyEntry, coarseEntry, entry])
            try check(repeated.source?.id == basic.source?.id && repeated.selection == basic.selection && repeated.preview == basic.preview,
                      "Repeated proposals are stable without mutation, loading or remote requests")
        }
        print("PASS \(assertions) planning-area extension assertions")
    }
}

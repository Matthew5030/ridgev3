import Foundation
import Observation

@MainActor @Observable final class WorldModel {
    @ObservationIgnored var cameraPose: TerrainCameraPose?
    var source: WorldSource?
    var overview: WorldOverview?
    var backdrop: WorldBackdrop?
    var routeTerrain: LoadedTerrain?
    var tiles: [String: WorldPreparedTile] = [:]
    var revision = 0
    var isLoading = false
    var message: String?
    var center = GeoPoint(latitude: 53.0763, longitude: -4.0546)
    var distance = 6000.0
    var in3D = false
    var pending = 0
    var saving = false
    var offlineMessage: String?
    var requestFocus: GeoPoint?
    @ObservationIgnored private let files = WorldSourceStore()
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var wanted: [WorldTileRequest] = []
    @ObservationIgnored private var failed: Set<String> = []
    @ObservationIgnored private var openedAddress = ""
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var policyCenter: GeoPoint?
    @ObservationIgnored private var policyDistance = 0.0
    @ObservationIgnored private var reduceDetailUntil = Date.distantPast

    func open(address: String) async {
        guard source == nil || openedAddress != address else { return }
        cameraPose = nil
        generation += 1; let token = generation
        work?.cancel(); work = nil; wanted = []; tiles = [:]; failed = []; message = nil; isLoading = true; source = nil; overview = nil; backdrop = nil; routeTerrain = nil; policyCenter = nil
        defer { if token == generation { isLoading = false } }
        do {
            let (source, overview, graph) = try await files.open(address: address)
            let backdrop=try await files.backdrop(source:source,overview:overview)
            guard token == generation, !Task.isCancelled else { return }
            self.source = source; self.overview = overview; self.backdrop=backdrop; openedAddress = address
            let spacing=max(1,Int((source.bounds.widthMeters/Double(overview.width-1)).rounded()))
            let level = TerrainLOD(spacing: spacing, width: overview.width, height: overview.height, file: source.overview.file, byteCount: Int64(source.overview.byteCount), sha256: source.overview.sha256)
            let manifest = RegionManifest(schemaVersion: 1, id: source.id, name: source.name, subtitle: "", bounds: source.bounds, sourceResolution: 1, heightScale: 1, noDataValue: -32768,
                levels: [level], textures: [], graphFile: source.graph.file, graphSHA256: source.graph.sha256, graphByteCount: Int64(source.graph.byteCount), places: source.places,
                sources: source.sources, defaultSpacing: spacing, version: source.revision, summary: "", verticalDatum: "Source EGM96")
            routeTerrain = LoadedTerrain(manifest: manifest, level: level, heights: overview.heights, textureURLs: [], graph: graph, directory: Bundle.main.bundleURL)
            center = source.places.first(where: { $0.name == "Crib Goch" })?.coordinate ?? source.bounds.center
            revision += 1
        } catch { if token == generation { message = error.localizedDescription } }
    }
    func update(center: GeoPoint, distance: Double) {
        guard let source else { return }
        if let previous = policyCenter, previous.distance(to: center) < 140, abs(distance / max(1,policyDistance) - 1) < 0.22 { return }
        self.center = center; self.distance = distance
        policyCenter = center; policyDistance = distance
        let proposed = WorldWorkingSet.requests(source: source, center: center, distance: distance, previous:wanted)
        let next = Date() < reduceDetailUntil ? proposed.prefix(12).map { WorldTileRequest(id: $0.id, pixels: 128, fine: false) } : proposed
        guard next != wanted else { return }
        wanted = next; failed = []
        let requests = Dictionary(uniqueKeysWithValues: next.map { ($0.id,$0) })
        // Retire geometry outside the bounded working set, but leave the image
        // attached until its replacement is ready. A detail change must never
        // expose an untextured tile.
        for id in Array(tiles.keys) {
            guard let desired=requests[id] else { tiles.removeValue(forKey:id);continue }
            if tiles[id]?.request.fine == true && !desired.fine {
                tiles[id]?.mesh=nil;tiles[id]?.geometry=nil;tiles[id]?.request.fine=false
            }
        }
        revision += 1
        pump()
    }
    private func pump() {
        guard work == nil, let source else { return }
        let token = generation
        // Only one tile is decoded/rasterized at once. Movement changes the queue,
        // not the camera or the scene; superseded results are discarded.
        work = Task { [weak self] in
            guard let self else { return }
            defer { if token == generation { work = nil; pending = 0 } }
            while !Task.isCancelled && token == generation {
                let requests = WorldWorkingSet.pending(wanted:wanted,current:tiles.mapValues(\.request)).filter { !failed.contains($0.id) }
                pending = requests.count
                guard let request = requests.first, let tile = source.tiles.first(where: { $0.id == request.id }) else { return }
                do {
                    let prepared = try await files.prepare(tile, request: request, sourceBounds: source.bounds, previous:tiles[request.id])
                    guard token == generation, !Task.isCancelled else { return }
                    let firstPage = tiles[request.id] == nil && !request.fine && wanted.contains(where: { $0.id == request.id && $0.pixels >= request.pixels })
                    if wanted.contains(request) || firstPage { tiles[request.id] = prepared; revision += 1 }
                } catch {
                    guard token == generation, !Task.isCancelled else { return }
                    failed.insert(request.id); message = "Some detail is unavailable. The overview is still usable."
                }
            }
        }
    }
    func retry() { failed = []; message = nil; pump() }
    func suspend() { generation += 1; work?.cancel(); work = nil; pending = 0; tiles = [:]; revision += 1 }
    func resume() { pump() }
    func memoryWarning() {
        reduceDetailUntil = Date().addingTimeInterval(30)
        tiles = [:]; wanted = wanted.prefix(12).map { WorldTileRequest(id: $0.id, pixels: 256, fine: false) }; revision += 1
        message = "Detail reduced to free memory."; pump()
    }
    func keepOffline() {
        guard let source, !saving else { return }
        if openedAddress.isEmpty { offlineMessage = "This Snowdon map is already included and works offline."; return }
        let ids = Set(wanted.prefix(36).map(\.id)); let chosen = source.tiles.filter { ids.contains($0.id) }
        guard !chosen.isEmpty else { return }
        saving = true; offlineMessage = "Saving this area…"
        Task {
            defer { saving = false }
            do { try await files.pin(chosen, source: source, surroundings: source.tiles.map(\.map)); offlineMessage = "This area is available offline." }
            catch { offlineMessage = "Could not finish saving. Completed files remain cached; try again." }
        }
    }
}

import Foundation
import CoreGraphics

/// Independent app reader check for an arbitrary newly published world source.
@main struct WorldBatchSourceTests {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let store = WorldSourceStore(bundledURL: root, cacheURL: cache)
        let (source, overview, graph) = try await store.open(address: "")
        try source.validate()
        guard !source.tiles.isEmpty, source.tiles.count <= 256,
              graph.edges.allSatisfy({ $0.distance.isFinite && $0.distance > 0 }) else {
            throw RidgeError.message("Invalid batch graph or coverage")
        }
        let nodes = Set(graph.nodes.map(\.id))
        guard graph.edges.allSatisfy({ nodes.contains($0.from) && nodes.contains($0.to) }) else {
            throw RidgeError.message("Dangling routing edge")
        }
        var triangles = 0
        for tile in source.tiles {
            let fine = try AdaptiveTerrainCodec.decode(Data(contentsOf: root.appendingPathComponent(tile.mesh.path)), chunk: tile.mesh)
            guard fine.elevation(at: tile.mesh.bounds.center) != nil else { throw RidgeError.message("Missing fine surface") }
            let background = tile.background!
            _ = try AdaptiveTerrainCodec.decode(Data(contentsOf: root.appendingPathComponent(background.path)), chunk: background, maximumErrorMetres: 2)
            let page = try await store.prepare(tile, request: WorldTileRequest(id: tile.id, pixels: 128, fine: false), sourceBounds: source.bounds)
            guard page.image.width == 136 else { throw RidgeError.message("Vector render failed") }
            triangles += tile.mesh.triangles
        }
        let backdrop = try await store.backdrop(source: source, overview: overview)
        let (preview, _) = try await store.preview(source: source, backdrop: backdrop)
        guard preview.height == 2048 else { throw RidgeError.message("Overhead preview failed") }
        print("Batch source passed native app validation: \(source.id); \(source.tiles.count) tiles; \(triangles) fine triangles; \(graph.nodes.count) route nodes; \(source.places.count) places")
    }
}

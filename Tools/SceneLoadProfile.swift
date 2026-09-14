import Foundation
import MetalKit

/// Read-only host measurements, not a physical iPhone performance guarantee.
@main struct SceneLoadProfile {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 2 || args.count == 4 else {
            print("Pass RidgeData.bundle, optionally followed by saved Areas directory and area ID.")
            return
        }
        let bundle = URL(fileURLWithPath: args[1])
        let source = try JSONDecoder().decode(RegionManifest.self, from: Data(contentsOf: bundle.appendingPathComponent("regions/eryri-grid/pack.json")))
        let grid = source.grid!
        for (name, ram, tier) in [("4 GiB/basic", 4, TerrainBudget.GPUTier.basic), ("6 GiB/Apple", 6, .apple), ("8 GiB/modern", 8, .modern)] {
            let context = TerrainBudget.Context(physicalMemory: Int64(ram) * 1_073_741_824, gpuTier: tier, useDeviceTextureAllocation: true)
            var best: (Int, RegionManifest, TerrainAllowance)?
            for side in 1...min(grid.columns, grid.rows) {
                let selection = grid.rectangle(from: TerrainCell(column: 0, row: 0), to: TerrainCell(column: side - 1, row: side - 1))!
                let preview = AreaCropper.preview(manifest: source, selection: selection, spacing: 4, context: context)
                let allowance = TerrainBudget.allowance(for: preview, spacing: 4, context: context)
                if allowance.allowed { best = (side, preview, allowance) }
            }
            if let (side, area, allowance) = best {
                let level = area.levels.first { $0.spacing == 4 }!
                print("CAPACITY \(name): \(side)x\(side) cells, \(area.bounds.widthMeters/1000)x\(area.bounds.depthMeters/1000) km, \(level.sampleCount) samples, \(allowance.estimatedMemory) scene bytes, \(allowance.bytesOnDisk) disk bytes, horizon \(area.horizon?.layers.compactMap { $0.levels.first?.spacing } ?? [])")
            }
        }
        guard args.count == 4, let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
        let packs = PackStore(root: URL(fileURLWithPath: args[2]), bundledDirectory: bundle)
        let start = Date()
        let terrain = try await packs.load(id: args[3])
        let loadedAt = Date()
        #if os(iOS)
        let renderer = try TerrainRenderer(device: device, colorPixelFormat: .bgra8Unorm_srgb, depthPixelFormat: .depth32Float, sampleCount: 4, terrain: terrain)
        let ready = Date()
        print("SIMULATOR LOAD \(args[3]): \(terrain.level.spacing)m, \(terrain.heights.count) primary samples")
        print("SECONDS pack-load=\(loadedAt.timeIntervalSince(start)) full-renderer=\(ready.timeIntervalSince(loadedAt))")
        renderer.stop()
        #else
        let minimum = ([terrain.heights] + (terrain.horizon?.layers.map(\.heights) ?? [])).compactMap { $0.lazy.filter(\.isFinite).min() }.min()!
        let scale = Float(max(terrain.manifest.bounds.widthMeters, terrain.manifest.bounds.depthMeters))
        let maps = try CartographyRenderer(device: device, queue: queue, loaded: terrain.cartography!, primaryBounds: terrain.manifest.bounds,
                                           terrain: terrain, minimumHeight: minimum, metersPerUnit: scale)
        let ready = Date()
        print("LOAD \(args[3]): \(terrain.level.spacing)m, \(terrain.heights.count) primary samples, \(terrain.cartography!.metadata.tiles.count) map cells")
        print("SECONDS pack-load=\(loadedAt.timeIntervalSince(start)) map-renderer=\(ready.timeIntervalSince(loadedAt)); excludes terrain mesh construction; native Mac host")
        maps.stop()
        #endif
    }
}

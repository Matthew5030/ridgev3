import Foundation

@main struct SelectionPerformance {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            print("Pass the local RidgeData.bundle path.")
            return
        }
        let bundle = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = bundle.appendingPathComponent("regions/eryri-grid", isDirectory: true)
        let manifest = try JSONDecoder().decode(RegionManifest.self, from: Data(contentsOf: directory.appendingPathComponent("pack.json")))
        guard let grid = manifest.grid else { throw RidgeError.message("Eryri grid metadata is missing.") }

        for side in [1, 4, 8] {
            let origin = (grid.columns - side) / 2
            guard let selection = grid.rectangle(from: TerrainCell(column: origin, row: origin),
                                                  to: TerrainCell(column: origin + side - 1, row: origin + side - 1)) else { continue }
            let previewStart = ContinuousClock.now
            for _ in 0..<100 { _ = AreaCropper.preview(manifest: manifest, selection: selection, spacing: 4) }
            let previewSeconds = seconds(previewStart.duration(to: .now)) / 100

            let prepareStart = ContinuousClock.now
            let crop = try AreaCropper.prepare(directory: directory, manifest: manifest, selection: selection, spacing: 4,
                                               cartographySourceID: manifest.id)
            let prepareSeconds = seconds(prepareStart.duration(to: .now))
            defer { try? FileManager.default.removeItem(at: crop.directory) }

            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ridge-selection-profile-\(UUID().uuidString)", isDirectory: true)
            let packs = PackStore(root: root, bundledDirectory: bundle)
            defer { try? FileManager.default.removeItem(at: root) }
            let installStart = ContinuousClock.now
            try await packs.install(from: crop.directory, manifest: crop.manifest, spacing: 4) { _ in }
            let installSeconds = seconds(installStart.duration(to: .now))
            let loadStart = ContinuousClock.now
            _ = try await packs.load(id: crop.manifest.id, spacing: 4)
            let loadSeconds = seconds(loadStart.duration(to: .now))

            print(String(format: "SELECTION %dx%d cells · %.2f × %.2f km", side, side,
                         crop.manifest.bounds.widthMeters / 1000, crop.manifest.bounds.depthMeters / 1000))
            print(String(format: "SECONDS preview=%.4f prepare=%.3f install=%.3f load=%.3f total=%.3f",
                         previewSeconds, prepareSeconds, installSeconds, loadSeconds,
                         prepareSeconds + installSeconds + loadSeconds))
            print("FILES map=\(crop.manifest.cartography?.tiles.count ?? 0) terrain=\(crop.manifest.levels.first?.byteCount ?? 0) bytes")
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

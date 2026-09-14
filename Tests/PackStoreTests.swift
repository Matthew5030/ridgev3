import Foundation
import CryptoKit

private struct TestFailure: Error, CustomStringConvertible {
    var description: String
}

@MainActor private var assertionCount = 0
@MainActor private func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    assertionCount += 1
    guard value() else { throw TestFailure(description: message) }
}

@MainActor private func expectError(_ label: String, _ operation: () async throws -> Void) async throws {
    do { try await operation() }
    catch { assertionCount += 1; print("PASS reject \(label)"); return }
    throw TestFailure(description: "Expected rejection: \(label)")
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private actor ProgressLog {
    var values: [Double] = []
    func append(_ value: Double) { values.append(value) }
    func isComplete() -> Bool {
        values.last == 1 && values.allSatisfy { (0...1).contains($0) } && zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }
    }
}

@MainActor @main struct PackStoreTests {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw TestFailure(description: "Pass RidgeData.bundle path") }
        let bundle = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let decoder = JSONDecoder(), encoder = JSONEncoder(), fm = FileManager.default
        let catalog = try decoder.decode([RegionManifest].self, from: Data(contentsOf: bundle.appendingPathComponent("catalog.json")))
        try check(!catalog.isEmpty && Set(catalog.map(\.id)).count == catalog.count, "The source catalogue contains unique real regions")
        let atlas = try decoder.decode(AtlasData.self, from: Data(contentsOf: bundle.appendingPathComponent("atlas.json")))
        try check(atlas.land.count > 100 && atlas.coverage.count > 400, "World atlas and actual source-coverage audit are present")
        for manifest in catalog {
            try PackStore.validate(manifest)
            try check(manifest.sourceResolution == 1, "Source spacing is retained")
            let allowance = TerrainBudget.allowance(for: manifest, spacing: manifest.defaultSpacing, context: BudgetFixtures.basic)
            print("BUDGET \(manifest.id) \(manifest.defaultSpacing)m: \(allowance.estimatedMemory / 1_048_576) MiB on a fixed basic-device fixture")
            try check(allowance.allowed, "Starter default should fit the basic-device allowance")
        }
        let snowdon = try decoder.decode(RegionManifest.self, from: Data(contentsOf: bundle.appendingPathComponent("regions/snowdon-horseshoe/pack.json")))
        let summit = try decoder.decode(RegionManifest.self, from: Data(contentsOf: bundle.appendingPathComponent("regions/snowdon-summit/pack.json")))
        try check(!TerrainBudget.allowance(for: snowdon, spacing: 4, context: BudgetFixtures.basic).allowed, "Basic GPU cannot load whole 4m Snowdon")
        try check(!TerrainBudget.allowance(for: snowdon, spacing: 1, context: BudgetFixtures.basic).allowed, "Absent 1m Snowdon must be blocked")
        try check(TerrainBudget.allowance(for: summit, spacing: 1, context: BudgetFixtures.basic).allowed, "Genuine 513-square 1m summit should fit")
        try check(summit.levels.map(\.spacing) == [1, 2, 4, 8, 16, 32], "Summit has all six real levels")
        try check(snowdon.grid == nil && summit.grid == nil, "Legacy manifests decode without grid metadata")
        let missing = TerrainBudget.allowance(for: snowdon, spacing: 1, context: BudgetFixtures.basic)
        let oversized = TerrainBudget.allowance(for: snowdon, spacing: 4, context: BudgetFixtures.basic)
        try check(missing.reason?.contains("not included") == true && oversized.reason != nil && oversized.reason != missing.reason && !oversized.allowed, "Missing source data and excessive geometry have different explanations")
        var textureHeavy = summit
        textureHeavy.textures = (0..<8).map { index in
            var texture = summit.textures[0]; texture.file = "heavy-\(index).png"; texture.width = 4096; texture.height = 4096; return texture
        }
        let textureAllowance = TerrainBudget.allowance(for: textureHeavy, spacing: 32, context: BudgetFixtures.basic)
        try check(!textureAllowance.allowed && textureAllowance.reason?.contains("Coarser terrain alone") == true, "Texture memory must not be described as missing terrain data")

        var gridManifest = try decoder.decode(RegionManifest.self, from: Data(contentsOf: bundle.appendingPathComponent("regions/eryri-grid/pack.json")))
        gridManifest.cartography = nil // Preserve coverage of legacy fine/overview installations.
        try PackStore.validate(gridManifest)
        let detailTextures = try required(gridManifest.detailTextures, "Fine original-cell map layer")
        try check(detailTextures.count == 16 && detailTextures.allSatisfy { $0.width == 4096 && $0.height == 4096 }, "Source retains sixteen full-resolution parent map images")
        try check(gridManifest.grid?.columns == 16 && gridManifest.grid?.rows == 16, "Actual source carries its original 16-square precision grid")
        try check(!TerrainBudget.allowance(for: gridManifest, spacing: 1, context: BudgetFixtures.basic).allowed, "Large source 1m metadata can be read without allowing its whole scene to load")
        var invalidGrid = gridManifest; invalidGrid.grid?.originColumn = 48
        awaitValidationFailure(invalidGrid, "grid extends beyond world tile")
        invalidGrid = gridManifest; invalidGrid.grid?.columns = Int.max
        awaitValidationFailure(invalidGrid, "overflow-sized original tile grid")
        invalidGrid = gridManifest; invalidGrid.grid?.originColumn = Int.max
        awaitValidationFailure(invalidGrid, "overflow-sized original tile origin")
        invalidGrid = gridManifest; invalidGrid.grid?.rows = 0
        awaitValidationFailure(invalidGrid, "empty original tile grid")
        invalidGrid = gridManifest; invalidGrid.grid?.worldTileID = "../outside"
        awaitValidationFailure(invalidGrid, "unsafe world tile identifier")
        invalidGrid = gridManifest; invalidGrid.levels[0].width -= 1
        invalidGrid.levels[0].byteCount = Int64(invalidGrid.levels[0].width) * Int64(invalidGrid.levels[0].height) * 2
        awaitValidationFailure(invalidGrid, "terrain intervals differ from original tile grid")
        var invalidDetail = gridManifest; invalidDetail.detailTextures?[0].file = "../outside.png"
        awaitValidationFailure(invalidDetail, "fine-map asset traversal")
        invalidDetail = gridManifest; invalidDetail.detailTextures?[0].file = gridManifest.textures[0].file
        awaitValidationFailure(invalidDetail, "fine-map asset duplicates overview")
        invalidDetail = gridManifest; invalidDetail.detailTextures?[0].width = 4097
        awaitValidationFailure(invalidDetail, "fine-map source image exceeds bounded size")
        invalidDetail = gridManifest; invalidDetail.detailTextures?[0].bounds.maxLongitude -= 0.001
        awaitValidationFailure(invalidDetail, "fine-map coverage gap")
        invalidDetail = gridManifest; invalidDetail.detailTextures?[0].bounds.minLatitude -= 1
        awaitValidationFailure(invalidDetail, "fine-map outside area bounds")
        invalidDetail = gridManifest; invalidDetail.detailTextures = Array(repeating: detailTextures[0], count: 33)
        awaitValidationFailure(invalidDetail, "too many fine-map source images")
        invalidDetail = gridManifest; invalidDetail.detailTextures = []
        awaitValidationFailure(invalidDetail, "empty optional fine-map layer")

        var invalid = summit
        invalid.id = "../escape"
        awaitValidationFailure(invalid, "area traversal")
        invalid = summit; invalid.levels[0].file = "../terrain.bin"
        awaitValidationFailure(invalid, "asset traversal")
        invalid = summit; invalid.levels[0].width = Int.max; invalid.levels[0].height = Int.max
        awaitValidationFailure(invalid, "overflow-sized terrain dimensions")
        invalid = summit; invalid.levels[0].width = Int.min
        awaitValidationFailure(invalid, "negative terrain dimensions")
        invalid = summit; invalid.levels[0].byteCount += 2
        awaitValidationFailure(invalid, "terrain byte dimensions")
        invalid = summit; invalid.textures[0].width = 100_000
        awaitValidationFailure(invalid, "oversized texture")
        invalid = summit; invalid.bounds.minLatitude = invalid.bounds.maxLatitude
        awaitValidationFailure(invalid, "empty bounds")
        invalid = summit; invalid.defaultSpacing = 3
        awaitValidationFailure(invalid, "missing default level")
        invalid = summit; invalid.textures[0].file = invalid.levels[0].file
        awaitValidationFailure(invalid, "duplicate file names")
        invalid = summit; invalid.textures[0].file = "Pack.json"
        awaitValidationFailure(invalid, "case insensitive manifest collision")
        invalid = summit; invalid.textures[0].bounds.maxLongitude += 0.1
        awaitValidationFailure(invalid, "texture outside area bounds")
        invalid = summit; invalid.textures[0].bounds.maxLongitude -= 0.001
        awaitValidationFailure(invalid, "texture coverage gap")

        let workspace = fm.temporaryDirectory.appendingPathComponent("ridge-pack-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workspace) }
        let store = PackStore(root: workspace.appendingPathComponent("installed"))
        let gridStore = PackStore(root: workspace.appendingPathComponent("grid-installed"))
        try await gridStore.install(from: bundle.appendingPathComponent("regions/eryri-grid"), manifest: gridManifest, spacing: 8) { _ in }
        let installedGrid = try await gridStore.installedManifest(id: gridManifest.id)
        let wholeGrid = try await gridStore.load(id: gridManifest.id)
        try check(installedGrid?.detailTextures == nil && wholeGrid.textureURLs.count == 4, "Whole source installs only overview textures and drops unused detail metadata")
        let wholeFiles = try fm.contentsOfDirectory(atPath: workspace.appendingPathComponent("grid-installed/\(gridManifest.id)").path)
        try check(!detailTextures.contains { wholeFiles.contains($0.file) }, "Whole source never copies or depends on optional fine-map assets")
        try check(TerrainBudget.allowance(for: wholeGrid.manifest, spacing: 8, context: BudgetFixtures.basic).allowed, "Whole 8m scene keeps its existing overview memory budget")
        print("PASS optional fine-map validation and bounded overview-only whole-area installation")
        let source = bundle.appendingPathComponent("regions/snowdon-horseshoe")
        let inspected = try await store.inspect(directory: source)
        try check(inspected == snowdon, "Source inspection must match catalog")
        let progress = ProgressLog()
        try await store.install(from: source, manifest: snowdon, spacing: 8) { await progress.append($0) }
        let progressComplete = await progress.isComplete()
        try check(progressComplete, "Install progress should be bounded, monotonic and complete")
        let loaded = try await store.load(id: snowdon.id)
        try check(loaded.level.width == 769 && loaded.heights.count == 769 * 769, "Real 8m terrain dimensions")
        try check(loaded.heights.allSatisfy(\.isFinite), "Starter source has complete terrain")
        try check((loaded.heights.max() ?? 0) > 1000, "Yr Wyddfa relief contains a real mountain summit")
        try check(loaded.graph?.nodes.count == 9565 && loaded.graph?.edges.count == 9636, "Real clipped OSM graph survives loading")
        try check(loaded.textureURLs.count == 4, "Four independent sharp map textures are retained")
        print("PASS install and decode real Snowdon at 8m")

        try await store.install(from: source, manifest: snowdon, spacing: 16) { _ in }
        let replacement = try await store.load(id: snowdon.id)
        try check(replacement.level.spacing == 16 && replacement.heights.count == 385 * 385, "Atomic resolution replacement")
        let stored = try await store.installedManifest(id: snowdon.id)
        try check(stored?.levels.count == 1 && stored?.defaultSpacing == 16, "Only chosen resolution is installed")
        print("PASS replace 8m scene with bounded 16m scene")

        let corrupted = workspace.appendingPathComponent("corrupt-source")
        try fm.copyItem(at: source, to: corrupted)
        let terrain8 = try required(snowdon.levels.first { $0.spacing == 8 }, "8m level")
        let corruptFile = corrupted.appendingPathComponent(terrain8.file)
        var bytes = try Data(contentsOf: corruptFile)
        bytes[0] ^= 0x55
        try bytes.write(to: corruptFile)
        try await expectError("corrupt heightfield") {
            try await store.install(from: corrupted, manifest: snowdon, spacing: 8) { _ in }
        }
        try await assertSaved16(store, snowdon.id)

        let symlinkSource = workspace.appendingPathComponent("symlink-source")
        try fm.copyItem(at: source, to: symlinkSource)
        try fm.removeItem(at: symlinkSource.appendingPathComponent(terrain8.file))
        try fm.createSymbolicLink(at: symlinkSource.appendingPathComponent(terrain8.file), withDestinationURL: source.appendingPathComponent(terrain8.file))
        try await expectError("asset symlink outside chosen area") {
            try await store.install(from: symlinkSource, manifest: snowdon, spacing: 8) { _ in }
        }
        try await assertSaved16(store, snowdon.id)

        let cancelled = Task {
            try await store.install(from: source, manifest: snowdon, spacing: 8) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        try await expectError("cancelled installation") { try await cancelled.value }
        try await assertSaved16(store, snowdon.id)

        // Correct hashes alone do not establish that payloads can be used. These
        // fixtures must fail before activation and preserve the known-good area.
        var wrongDimensions = snowdon
        wrongDimensions.textures[0].width = 1024
        try await expectError("correctly hashed image with false dimensions") {
            try await store.install(from: source, manifest: wrongDimensions, spacing: 8) { _ in }
        }
        try await assertSaved16(store, snowdon.id)

        let badGraphSource = workspace.appendingPathComponent("invalid-graph-source")
        try fm.copyItem(at: source, to: badGraphSource)
        let graphFile = try required(snowdon.graphFile, "graph file")
        let graphURL = badGraphSource.appendingPathComponent(graphFile)
        var graph = try decoder.decode(WalkingGraph.self, from: Data(contentsOf: graphURL))
        graph.edges[0].to = Int.max
        let graphBytes = try encoder.encode(graph)
        try graphBytes.write(to: graphURL)
        var badGraphManifest = snowdon
        badGraphManifest.graphSHA256 = sha256(graphBytes)
        badGraphManifest.graphByteCount = Int64(graphBytes.count)
        try await expectError("correctly hashed graph with dangling edge") {
            try await store.install(from: badGraphSource, manifest: badGraphManifest, spacing: 8) { _ in }
        }
        try await assertSaved16(store, snowdon.id)

        let noTerrainSource = workspace.appendingPathComponent("no-terrain-source")
        try fm.copyItem(at: source, to: noTerrainSource)
        var noTerrain = Data(count: Int(terrain8.byteCount))
        for offset in stride(from: 0, to: noTerrain.count, by: 2) { noTerrain[offset] = 0; noTerrain[offset + 1] = 128 }
        try noTerrain.write(to: noTerrainSource.appendingPathComponent(terrain8.file))
        var noTerrainManifest = snowdon
        noTerrainManifest.levels[noTerrainManifest.levels.firstIndex { $0.spacing == 8 }!].sha256 = sha256(noTerrain)
        try await expectError("correctly hashed all-no-data terrain") {
            try await store.install(from: noTerrainSource, manifest: noTerrainManifest, spacing: 8) { _ in }
        }
        try await assertSaved16(store, snowdon.id)

        let summitSource = bundle.appendingPathComponent("regions/snowdon-summit")
        try await store.install(from: summitSource, manifest: summit, spacing: 1) { _ in }
        let summitLoaded = try await store.load(id: summit.id)
        try check(summitLoaded.heights.count == 513 * 513 && summitLoaded.level.spacing == 1, "Actual precision child loads at 1m")
        try check((summitLoaded.heights.max() ?? 0) > 1000, "Precision child retains summit elevation")
        let installed = try await store.catalogue()
        try check(installed.filter(\.installed).count == 2, "Two independently saved regions")
        let brokenFolder = workspace.appendingPathComponent("installed/broken-area")
        try fm.createDirectory(at: brokenFolder, withIntermediateDirectories: true)
        try Data("{broken json".utf8).write(to: brokenFolder.appendingPathComponent("pack.json"))
        let survivingCatalog = try await store.catalogue()
        let issues = await store.issues()
        try check(survivingCatalog.filter(\.installed).count == 2 && issues.count == 1, "One corrupt area must not hide all valid areas; report an issue")
        try fm.removeItem(at: brokenFolder)
        let wrongIDFolder = workspace.appendingPathComponent("installed/wrong-identifier")
        try fm.createDirectory(at: wrongIDFolder, withIntermediateDirectories: true)
        try encoder.encode(summit).write(to: wrongIDFolder.appendingPathComponent("pack.json"))
        try await expectError("installed area identifier mismatch") { _ = try await store.installedManifest(id: "wrong-identifier") }
        try fm.removeItem(at: wrongIDFolder)
        try await store.remove(id: summit.id)
        try await expectError("removed area") { _ = try await store.load(id: summit.id) }
        try await assertSaved16(store, snowdon.id)
        let leftovers = try fm.contentsOfDirectory(atPath: workspace.appendingPathComponent("installed").path)
        try check(!leftovers.contains { $0.hasPrefix(".install-") }, "All successful, failed and cancelled staging folders are removed")
        print("PASS all PackStore real-data integration checks: \(assertionCount) assertions")
    }

    static func required<T>(_ value: T?, _ label: String) throws -> T {
        guard let value else { throw TestFailure(description: "Missing \(label)") }
        return value
    }

    static func awaitValidationFailure(_ manifest: RegionManifest, _ label: String) {
        do { try PackStore.validate(manifest); fatalError("Expected manifest rejection: \(label)") }
        catch { assertionCount += 1; print("PASS reject \(label)") }
    }

    static func assertSaved16(_ store: PackStore, _ id: String) async throws {
        let loaded = try await store.load(id: id)
        try check(loaded.level.spacing == 16 && loaded.heights.count == 385 * 385, "Previous valid 16m installation must survive failure")
    }
}

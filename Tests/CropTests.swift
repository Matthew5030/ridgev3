import Foundation
import CoreGraphics
import ImageIO

private struct CropFailure: Error, CustomStringConvertible { var description: String }
@MainActor private var assertionCount = 0
@MainActor private func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    assertionCount += 1
    guard value() else { throw CropFailure(description: message) }
}
private func rgba(_ image: CGImage) -> Data {
    let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Data(bytes: context.data!, count: image.width * image.height * 4)
}
private func image(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CropFailure(description: "Cannot decode \(url.lastPathComponent)") }
    return image
}

@MainActor @main struct CropTests {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw CropFailure(description: "Pass the real bundle path") }
        let fm = FileManager.default
        let bundle = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let directory = bundle.appendingPathComponent("regions/snowdon-horseshoe")
        let manifest = try JSONDecoder().decode(RegionManifest.self, from: Data(contentsOf: directory.appendingPathComponent("pack.json")))
        let selection = AreaSelection(minU: 0.25, minV: 0.25, maxU: 0.75, maxV: 0.75)
        try check(AreaSelection().isWhole && !selection.isWhole, "Whole-area recognition")
        let preview = AreaCropper.preview(manifest: manifest, selection: selection)
        try check(!TerrainBudget.allowance(for: manifest, spacing: 4, context: BudgetFixtures.basic).allowed, "Whole 4m area exceeds the basic GPU allowance")
        try check(TerrainBudget.allowance(for: preview, spacing: 4, context: BudgetFixtures.basic).allowed, "Quarter area must make native 4m terrain available")
        try check(preview.levels.first { $0.spacing == 4 }?.width == 769, "Quarter dimensions are native 769-square samples")
        try check(preview.levels.map(\.spacing) == [4, 8, 16, 32], "A crop cannot invent absent 1m/2m source levels")
        try check(preview.textures.count == 4 && preview.textures.allSatisfy { $0.width == 1024 && $0.height == 1024 }, "Cartographic pixel detail is preserved, not stretched")
        try check(abs(preview.bounds.areaSquareKilometers / manifest.bounds.areaSquareKilometers - 0.25) < 0.001, "Geographic quarter area")

        let crop = try AreaCropper.prepare(directory: directory, manifest: manifest, selection: selection, spacing: 4)
        defer { try? fm.removeItem(at: crop.directory) }
        try check(crop.manifest.bounds == preview.bounds, "Preview and prepared bounds are identical")
        try check(crop.manifest.levels.count == 1 && crop.manifest.defaultSpacing == 4, "Only chosen LOD is prepared")
        try check(crop.manifest.id.hasPrefix(manifest.id + "-") && crop.manifest.id != manifest.id, "Selected area receives a unique identity")
        try check(AreaCropper.preview(manifest: manifest, selection: selection).id == crop.manifest.id, "Legacy selection identity matches preparation for repeat-area reuse")
        try check(crop.manifest.sources == manifest.sources, "Source attribution is retained")
        try PackStore.validate(crop.manifest)
        let sourceLevel = manifest.levels.first { $0.spacing == 4 }!
        let sourceBytes = try Data(contentsOf: directory.appendingPathComponent(sourceLevel.file))
        let croppedBytes = try Data(contentsOf: crop.directory.appendingPathComponent(crop.manifest.levels[0].file))
        for y in 0..<769 {
            let sourceOffset = ((384 + y) * 1537 + 384) * 2
            try check(croppedBytes[(y * 769 * 2)..<((y + 1) * 769 * 2)] == sourceBytes[sourceOffset..<(sourceOffset + 769 * 2)], "Every terrain row must be an exact native byte window")
        }
        let sourceMap = try image(directory.appendingPathComponent(manifest.textures[0].file))
        let expectedMap = sourceMap.cropping(to: CGRect(x: 1024, y: 1024, width: 1024, height: 1024))!
        let actualMap = try image(crop.directory.appendingPathComponent(crop.manifest.textures[0].file))
        let expectedRGBA = rgba(expectedMap), actualRGBA = rgba(actualMap)
        try check(expectedRGBA.count == actualRGBA.count, "Map crop dimensions")
        var difference = 0, maximumDifference = 0
        for i in stride(from: 0, to: actualRGBA.count, by: 17) {
            let delta = abs(Int(actualRGBA[i]) - Int(expectedRGBA[i]))
            difference += delta; maximumDifference = max(maximumDifference, delta)
        }
        try check(maximumDifference <= 2, "Integer-aligned map crop must preserve pixel colors and north orientation (max difference \(maximumDifference), sum \(difference))")
        print("PASS exact native terrain windows and source-map pixel/orientation preservation")

        let installed = fm.temporaryDirectory.appendingPathComponent("ridge-crop-tests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: installed) }
        let store = PackStore(root: installed)
        try await store.install(from: crop.directory, manifest: crop.manifest, spacing: 4) { _ in }
        let loaded = try await store.load(id: crop.manifest.id)
        try check(loaded.heights.count == 769 * 769 && loaded.heights.allSatisfy(\.isFinite), "Cropped area loads through production PackStore")
        let graph = loaded.graph!
        let ids = Set(graph.nodes.map(\.id))
        try check(!graph.edges.isEmpty && graph.edges.count < 9636, "Real OSM graph is spatially clipped")
        try check(graph.nodes.allSatisfy { crop.manifest.bounds.contains($0.coordinate) }, "Graph nodes stay inside the new model")
        try check(graph.edges.allSatisfy { ids.contains($0.from) && ids.contains($0.to) }, "No fabricated or dangling cross-boundary edges")
        try check(crop.manifest.places.allSatisfy { crop.manifest.bounds.contains($0.coordinate) }, "Labels stay inside the new area")
        let centerSourceHeight = sourceBytes.withUnsafeBytes { raw in Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: (768 * 1537 + 768) * 2, as: Int16.self))) * 0.1 }
        try check(abs((loaded.elevation(at: loaded.manifest.bounds.center) ?? -9999) - centerSourceHeight) < 0.05, "Coordinate/elevation georeferencing survives crop")
        print("PASS crop installation, graph clipping and geographically aligned elevation lookup")

        // A non-grid-aligned drag snaps outward consistently at all source levels.
        let arbitrary = AreaSelection(minU: 0.313, minV: 0.207, maxU: 0.691, maxV: 0.733)
        let arbitraryPreview = AreaCropper.preview(manifest: manifest, selection: arbitrary)
        let nw = manifest.bounds.uv(GeoPoint(latitude: arbitraryPreview.bounds.maxLatitude, longitude: arbitraryPreview.bounds.minLongitude))
        let se = manifest.bounds.uv(GeoPoint(latitude: arbitraryPreview.bounds.minLatitude, longitude: arbitraryPreview.bounds.maxLongitude))
        try check(nw.u <= arbitrary.minU + 1e-10 && nw.v <= arbitrary.minV + 1e-10 && se.u >= arbitrary.maxU - 1e-10 && se.v >= arbitrary.maxV - 1e-10, "Outward snapping includes the complete selected rectangle")
        let fractional = try AreaCropper.prepare(directory: directory, manifest: manifest, selection: arbitrary, spacing: 8)
        defer { try? fm.removeItem(at: fractional.directory) }
        try check(fractional.manifest.bounds == arbitraryPreview.bounds, "Arbitrary preview/prepare bounds agree")
        try PackStore.validate(fractional.manifest) // Includes exact coverage and no-overlap tests.
        try await store.install(from: fractional.directory, manifest: fractional.manifest, spacing: 8) { _ in }
        _ = try await store.load(id: fractional.manifest.id)
        print("PASS fractional map crops and exact nonoverlapping texture coverage")

        let invalidSelections = [AreaSelection(minU: .nan), AreaSelection(minU: -0.1), AreaSelection(minU: 0.8, maxU: 0.2),
                                 AreaSelection(minU: 0.5, minV: 0.5, maxU: 0.50001, maxV: 0.50001)]
        for selection in invalidSelections {
            try check(AreaCropper.preview(manifest: manifest, selection: selection).levels.isEmpty, "Invalid preview exposes no installable resolution")
            do { _ = try AreaCropper.prepare(directory: directory, manifest: manifest, selection: selection, spacing: 8); throw CropFailure(description: "Invalid selection was accepted") }
            catch is CropFailure { throw CropFailure(description: "Invalid selection was accepted") }
            catch { }
        }
        print("PASS reject invalid and tiny selections before allocation")
        try await originalPrecisionGrid(bundle: bundle)
        print("PASS all real-data crop tests: \(assertionCount) assertions, including native sample and map-pixel comparisons")
    }

    static func originalPrecisionGrid(bundle: URL) async throws {
        let fm = FileManager.default
        let directory = bundle.appendingPathComponent("regions/eryri-grid")
        var manifest = try JSONDecoder().decode(RegionManifest.self, from: Data(contentsOf: directory.appendingPathComponent("pack.json")))
        manifest.cartography = nil // Legacy fine/overview pixel-preservation coverage.
        try PackStore.validate(manifest)
        guard let grid = manifest.grid, grid.isValid else { throw CropFailure(description: "New source is missing its original precision grid") }
        try check(grid.originColumn == 16 && grid.originRow == 0 && grid.columns == 16 && grid.rows == 16, "Original source extent is preserved")
        try check(manifest.levels.map(\.spacing) == [1, 2, 4, 8, 16, 32], "New collection includes all six genuine source resolutions")
        try check(manifest.detailTextures?.count == 16, "New source includes its optional fine-map layer")
        let wholePreview = AreaCropper.preview(manifest: manifest, selection: AreaSelection())
        try check(wholePreview.textures.map(\.file) == manifest.textures.map(\.file), "Whole-area selection keeps the small overview maps")
        try check(wholePreview.detailTextures == nil && TerrainBudget.allowance(for: wholePreview, spacing: 8, context: BudgetFixtures.basic).allowed, "Whole-area preview does not budget unused fine-map images")
        let allIDs = (0..<grid.rows).flatMap { row in (0..<grid.columns).compactMap { grid.cellID(column: $0, row: row) } }
        try check(allIDs.count == 256 && Set(allIDs).count == 256, "Every original precision cell has a unique stable identity")
        try check(grid.cellID(column: 0, row: 0) == "z10-x500-y333-c04-00-p00-00", "Original parent/child identity is retained")
        try check(grid.cellID(column: 15, row: 15) == "z10-x500-y333-c07-03-p03-03", "Far-edge parent/child identity is retained")
        try check(grid.cellName(column: 0, row: 0) == "Tile c04-00 · p00-00", "Tile names expose their original reference")
        try check(grid.selection(column: -1, row: 0) == nil && grid.selection(column: 16, row: 0) == nil, "Out-of-grid selections are rejected")

        for row in 0..<grid.rows {
            for column in 0..<grid.columns {
                let selection = grid.selection(column: column, row: row)!
                let preview = AreaCropper.preview(manifest: manifest, selection: selection)
                try check(preview.grid?.originColumn == 16 + column && preview.grid?.originRow == row, "Selection retains global grid coordinates")
                try check(preview.id == grid.cellID(column: column, row: row), "Preview identity is the original stable cell ID")
                try check(TerrainBudget.allowance(for: preview, spacing: 1, context: BudgetFixtures.basic).allowed, "Every complete original cell fits the basic-device 1m allowance")
                try check(preview.textures.count == 1 && preview.textures[0].width == 1024 && preview.textures[0].height == 1024, "Each original precision cell receives a true 1024-square map window")
                try check(preview.detailTextures == nil, "A selected cell exposes only the chosen map layer")
                for level in preview.levels {
                    let expected = 512 / level.spacing + 1
                    try check(level.width == expected && level.height == expected, "Every LOD keeps exact native tile dimensions")
                }
                let northWest = manifest.bounds.point(u: Double(column) / 16, v: Double(row) / 16)
                let southEast = manifest.bounds.point(u: Double(column + 1) / 16, v: Double(row + 1) / 16)
                try check(preview.bounds == GeoBounds(minLatitude: southEast.latitude, minLongitude: northWest.longitude, maxLatitude: northWest.latitude, maxLongitude: southEast.longitude), "Cell bounds are exact source-grid bounds")
                try check(grid.cellsSelection(selection) == selection, "Grid selection is stable under repeated normalization")
                let interior = AreaSelection(minU: selection.minU + 0.001, minV: selection.minV + 0.001, maxU: selection.maxU - 0.001, maxV: selection.maxV - 0.001)
                try check(AreaCropper.preview(manifest: manifest, selection: interior).bounds == preview.bounds, "Tapping and dragging inside the same source cell have identical snapping")
            }
        }
        print("PASS all 256 original cell IDs, bounds, six-LOD dimensions, 1m budgets and snapping parity")

        let twoByTwo = grid.rectangle(from: TerrainCell(column: 0, row: 0), to: TerrainCell(column: 1, row: 1))!
        let twoPreview = AreaCropper.preview(manifest: manifest, selection: twoByTwo)
        try check(twoPreview.levels.first { $0.spacing == 1 }?.width == 1025, "Two-cell width is 1025 native 1m points")
        try check(TerrainBudget.allowance(for: twoPreview, spacing: 1, context: BudgetFixtures.basic).allowed, "A 2×2-cell selection fits the basic-device allowance")
        try check(twoPreview.textures.reduce(0) { $0 + $1.width * $1.height } == 2048 * 2048, "Two-by-two tiles retain full fine-map pixel density")
        try check(twoPreview.id == "z10-x500-y333-r16-00-02x02" && twoPreview.grid?.columns == 2, "Multicell identity and grid metadata are deterministic")
        try check(grid.rectangle(from: TerrainCell(column: 1, row: 1), to: TerrainCell(column: 0, row: 0)) == twoByTwo, "Reverse drag direction produces the same rectangle")
        let threeByThree = grid.rectangle(from: TerrainCell(column: 0, row: 0), to: TerrainCell(column: 2, row: 2))!
        let threePreview = AreaCropper.preview(manifest: manifest, selection: threeByThree)
        try check(!TerrainBudget.allowance(for: threePreview, spacing: 1, context: BudgetFixtures.basic).allowed, "3×3 cells at 1m exceed the basic GPU allowance")
        try check(TerrainBudget.allowance(for: threePreview, spacing: 2, context: BudgetFixtures.basic).allowed, "The same 3×3 footprint offers genuine 2m data")
        try check(TerrainBudget.allowance(for: threePreview, spacing: 1, context: BudgetFixtures.capable).allowed, "Capable devices unlock genuine 1m on the same 3×3 selection")
        try check(threePreview.textures.reduce(0) { $0 + $1.width * $1.height } == 3072 * 3072, "Three-by-three tiles retain the same source pixel density")
        let four = AreaCropper.preview(manifest: manifest, selection: grid.rectangle(from: TerrainCell(column: 2, row: 2), to: TerrainCell(column: 5, row: 5))!)
        try check(four.textures.reduce(0) { $0 + $1.width * $1.height } == 4096 * 4096, "Fine-map selection includes the exact 4096-pixel threshold across source image seams")
        let wide = AreaCropper.preview(manifest: manifest, selection: grid.rectangle(from: TerrainCell(column: 0, row: 0), to: TerrainCell(column: 4, row: 0))!)
        try check(wide.textures.allSatisfy { manifest.textures.map(\.file).contains($0.file) }, "Selections wider than 4096 fine pixels fall back to bounded overview maps")
        do { _ = try AreaCropper.prepare(directory: directory, manifest: manifest, selection: AreaSelection(), spacing: 1); throw CropFailure(description: "Whole 16×16 fine grid was prepared beyond the absolute limit") }
        catch is CropFailure { throw CropFailure(description: "Whole 16×16 fine grid was prepared beyond the absolute limit") }
        catch { }

        let selection = grid.selection(column: 0, row: 0)!
        let crop = try AreaCropper.prepare(directory: directory, manifest: manifest, selection: selection, spacing: 1)
        defer { try? fm.removeItem(at: crop.directory) }
        try check(crop.manifest.id == grid.cellID(column: 0, row: 0), "Prepared original cell gets its stable ID")
        try check(crop.manifest.grid?.columns == 1 && crop.manifest.grid?.rows == 1 && crop.manifest.grid?.originColumn == 16, "Prepared single-cell source grid is retained")
        try check(crop.manifest.detailTextures == nil && crop.manifest.textures.count == 1 && crop.manifest.textures[0].width == 1024 && crop.manifest.textures[0].height == 1024, "Prepared tile installs only its genuine 1024-square fine map")
        let sourceDetail = manifest.detailTextures!.first { $0.bounds.contains(crop.manifest.bounds.center) }!
        let sourceDetailImage = try image(directory.appendingPathComponent(sourceDetail.file))
        let expectedFineMap = sourceDetailImage.cropping(to: CGRect(x: 0, y: 0, width: 1024, height: 1024))!
        let actualFineMap = try image(crop.directory.appendingPathComponent(crop.manifest.textures[0].file))
        let expectedFineRGBA = rgba(expectedFineMap), actualFineRGBA = rgba(actualFineMap)
        try check(expectedFineRGBA.count == actualFineRGBA.count, "Fine map crop pixel dimensions match the original source")
        for index in stride(from: 0, to: actualFineRGBA.count, by: 37) {
            try check(abs(Int(expectedFineRGBA[index]) - Int(actualFineRGBA[index])) <= 2, "Fine map pixels and north orientation match source cartography")
        }
        let sourceLevel = manifest.levels.first { $0.spacing == 1 }!, targetLevel = crop.manifest.levels[0]
        let croppedBytes = try Data(contentsOf: crop.directory.appendingPathComponent(targetLevel.file))
        let sourceHandle = try FileHandle(forReadingFrom: directory.appendingPathComponent(sourceLevel.file))
        defer { try? sourceHandle.close() }
        for row in 0..<513 {
            try sourceHandle.seek(toOffset: UInt64(row * sourceLevel.width * 2))
            let bytes = try sourceHandle.read(upToCount: 513 * 2)
            try check(bytes == croppedBytes.subdata(in: (row * 513 * 2)..<((row + 1) * 513 * 2)), "Cell cropping copies every original native 1m row exactly")
        }
        let installRoot = fm.temporaryDirectory.appendingPathComponent("ridge-grid-tests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: installRoot) }
        let store = PackStore(root: installRoot)
        try await store.install(from: crop.directory, manifest: crop.manifest, spacing: 1) { _ in }
        let loaded = try await store.load(id: crop.manifest.id)
        try check(loaded.heights.count == 263_169 && loaded.level.spacing == 1 && loaded.heights.allSatisfy(\.isFinite), "A real original precision cell loads at 1m through production PackStore")
        let allowance = TerrainBudget.allowance(for: crop.manifest, spacing: 1)
        print("PASS original cell 1m prepare/install/load: \(loaded.heights.count) samples, \(allowance.estimatedMemory / 1_048_576) MiB estimate / \(TerrainBudget.memoryLimit / 1_048_576) MiB cap")

        let coarser = try AreaCropper.prepare(directory: directory, manifest: manifest, selection: selection, spacing: 2)
        defer { try? fm.removeItem(at: coarser.directory) }
        try check(coarser.manifest.id == crop.manifest.id && coarser.manifest.bounds == crop.manifest.bounds, "Changing resolution preserves original tile identity and footprint")
        try check(coarser.manifest.textures.map(\.sha256) == crop.manifest.textures.map(\.sha256), "Terrain resolution does not alter chosen map pixels or sharpness")
        try await store.install(from: coarser.directory, manifest: coarser.manifest, spacing: 2) { _ in }
        let replacement = try await store.load(id: crop.manifest.id)
        try check(replacement.level.spacing == 2 && replacement.heights.count == 257 * 257, "Resolution replacement keeps the same installed tile")
        print("PASS bounded multi-tile choices and stable original-cell resolution replacement")
    }
}

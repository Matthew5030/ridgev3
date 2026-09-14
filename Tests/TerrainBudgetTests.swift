import Foundation

private struct BudgetFailure: Error, CustomStringConvertible { var description: String }

@MainActor @main struct TerrainBudgetTests {
    private static var assertions = 0
    private static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        guard value() else { throw BudgetFailure(description: message) }
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw BudgetFailure(description: "Pass RidgeData.bundle path") }
        let bundle = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var source = try JSONDecoder().decode(RegionManifest.self, from: Data(contentsOf: bundle.appendingPathComponent("regions/eryri-grid/pack.json")))
        try PackStore.validate(source)
        // Preserve coverage of the legacy resident map policy; the dedicated
        // cartography suite tests the independent bounded atlas policy.
        source.cartography = nil
        let sourceWithHorizon = source
        // The established admission cases measure the primary scene alone;
        // combined scene admission has separate horizon assertions below.
        source.horizon = nil
        guard let grid = source.grid else { throw BudgetFailure(description: "Real source has no original grid") }
        func square(_ side: Int) -> RegionManifest {
            let selection = grid.rectangle(from: TerrainCell(column: 0, row: 0), to: TerrainCell(column: side - 1, row: side - 1))!
            return AreaCropper.preview(manifest: source, selection: selection)
        }
        let one = square(1), two = square(2), three = square(3), four = square(4), five = square(5)
        let basic = BudgetFixtures.basic, capable = BudgetFixtures.capable
        try check(TerrainBudget.defaultSpacing(for: one, context: capable) == 4, "New selections default to 4m even when 1m fits")
        var defaultSource = one
        defaultSource.levels.removeAll { $0.spacing == 4 }
        try check(TerrainBudget.defaultSpacing(for: defaultSource, context: capable) == 8, "Missing 4m defaults to the next coarser available level")
        defaultSource.levels.removeAll { $0.spacing >= 4 }
        try check(TerrainBudget.defaultSpacing(for: defaultSource, context: capable) == 2, "A fine-only import still has a usable default")
        var noHeadroom = capable; noHeadroom.availableMemory = 0
        try check(TerrainBudget.defaultSpacing(for: one, context: noHeadroom) == nil, "Default detail cannot bypass memory admission")
        let mib = BudgetFixtures.mebibyte, gib = BudgetFixtures.gibibyte
        func allowed(_ manifest: RegionManifest, _ spacing: Int = 1, _ context: TerrainBudget.Context) -> Bool {
            TerrainBudget.allowance(for: manifest, spacing: spacing, context: context).allowed
        }

        try check(allowed(one, 1, basic) && allowed(two, 1, basic), "Basic devices retain single-cell and 2×2 1m terrain")
        try check(!allowed(three, 1, basic) && allowed(three, 2, basic), "Basic devices offer 2m when 3×3 native 1m geometry exceeds their GPU allowance")
        try check(allowed(three, 1, capable) && allowed(four, 1, capable) && allowed(five, 1, capable), "Capable devices unlock larger real 1m selections")
        var olderGPU = capable; olderGPU.gpuTier = .apple
        try check(allowed(four, 1, olderGPU) && !allowed(five, 1, olderGPU), "GPU family constrains geometry independently of abundant RAM")
        var limitedRAM = capable; limitedRAM.physicalMemory = gib
        try check(allowed(one, 1, limitedRAM) && !allowed(four, 1, limitedRAM), "Physical RAM constrains a capable GPU independently")
        var limitedGPUWorkingSet = capable; limitedGPUWorkingSet.recommendedGPUWorkingSet = 512 * mib
        try check(allowed(two, 1, limitedGPUWorkingSet) && !allowed(four, 1, limitedGPUWorkingSet), "Recommended GPU working set constrains resident maps and terrain")
        var smallBuffer = capable; smallBuffer.maximumBufferLength = 64 * mib
        try check(allowed(two, 1, smallBuffer) && !allowed(three, 1, smallBuffer), "Per-buffer limit rejects a large mesh even when total RAM is ample")
        try check(TerrainBudget.allowance(for: three, spacing: 1, context: smallBuffer).reason?.contains("buffer") == true, "Buffer rejection identifies the actionable constraint")
        var unavailableGPUReport = capable; unavailableGPUReport.recommendedGPUWorkingSet = 0; unavailableGPUReport.maximumBufferLength = 0
        var absentGPUReport = capable; absentGPUReport.recommendedGPUWorkingSet = nil; absentGPUReport.maximumBufferLength = nil
        try check(unavailableGPUReport.memoryLimit == absentGPUReport.memoryLimit && allowed(four, 1, unavailableGPUReport) == allowed(four, 1, absentGPUReport), "Zero GPU reports behave like unavailable metrics, as on Metal Simulator")
        var zeroMemory = capable; zeroMemory.availableMemory = 0
        try check(!allowed(one, 32, zeroMemory), "Zero live process memory is an actual limit and fails closed")
        zeroMemory = capable; zeroMemory.physicalMemory = 0
        try check(!allowed(one, 32, zeroMemory), "Zero physical memory fails closed even with absent GPU metrics")
        let captured = TerrainBudget.currentContext()
        try check(captured.recommendedGPUWorkingSet.map { $0 > 0 } ?? true, "Device capture treats a zero unavailable Metal working-set metric as absent")
        try check(captured.maximumBufferLength.map { $0 > 0 } ?? true, "Device capture provides only a usable Metal buffer limit")
        print("PASS real grid selections respond independently to RAM, GPU family, GPU working set and maximum buffer length")

        var pressured = capable; pressured.availableMemory = 96 * mib
        try check(!allowed(one, 32, pressured), "Low process headroom cannot admit even coarse geometry plus its fixed map allocation")
        try check(TerrainBudget.recommendedSpacing(for: one, context: pressured) == nil, "No supported resolution is recommended when fixed scene costs cannot fit")
        var serious = capable; serious.thermalPressure = .serious
        try check(allowed(five, 1, capable) && !allowed(five, 1, serious), "Serious thermal pressure reduces allowable geometry on the same device")
        try check(allowed(five, 2, serious), "Thermal pressure retains a coarser valid choice")
        let thermalStates: [TerrainBudget.ThermalPressure] = [.nominal, .fair, .serious, .critical]
        var previousLimit = Int64.max, previousSamples = Int.max
        for thermal in thermalStates {
            var context = capable; context.thermalPressure = thermal
            try check(context.memoryLimit <= previousLimit && context.maximumSamples <= previousSamples, "Increasing thermal pressure cannot increase the scene allowance")
            previousLimit = context.memoryLimit; previousSamples = context.maximumSamples
        }
        print("PASS live process headroom and thermal pressure reduce admission without changing source availability")

        try check(TerrainBudget.recommendedSpacing(for: three, context: basic) == 2, "Recommendation is the finest fitting source LOD on a basic device")
        try check(TerrainBudget.recommendedSpacing(for: three, context: capable) == 1, "Recommendation unlocks real 1m on a capable device")
        try check(TerrainBudget.recommendedSpacing(for: five, context: serious) == 2, "Recommendation respects the captured thermal allowance")
        try check(TerrainBudget.recommendedSpacing(for: source, context: capable) == 4, "Whole source chooses a safe coarse LOD instead of loading its huge native 1m grid")
        var reordered = three; reordered.levels.reverse(); reordered.defaultSpacing = 32
        try check(TerrainBudget.recommendedSpacing(for: reordered, context: capable) == 1, "Recommendation ignores manifest ordering and coarse default preferences")
        var missingFine = three; missingFine.levels.removeAll { $0.spacing < 4 }; missingFine.defaultSpacing = 4
        try check(TerrainBudget.recommendedSpacing(for: missingFine, context: capable) == 4, "Recommendation never invents absent 1m or 2m source data")
        try check(!allowed(missingFine, 1, capable), "Ample device resources cannot enable missing source data")
        try check(TerrainBudget.allowance(for: missingFine, spacing: 1, context: capable).reason?.contains("not included") == true, "Absent source data is distinguished from device restrictions")
        let stableRecommendation = TerrainBudget.recommendedSpacing(for: three, context: basic)
        let stableAllowances = three.levels.map { TerrainBudget.allowance(for: three, spacing: $0.spacing, context: basic).allowed }
        for _ in 0..<50 {
            try check(TerrainBudget.recommendedSpacing(for: reordered, context: basic) == stableRecommendation, "A captured context returns the same recommendation across repeated UI evaluations")
            try check(three.levels.map { TerrainBudget.allowance(for: three, spacing: $0.spacing, context: basic).allowed } == stableAllowances, "Availability does not oscillate within a captured context")
            try check(TerrainBudget.recommendedSpacing(for: one, context: pressured) == nil && !allowed(one, 3, capable), "Unsupported recommendations remain absent across repeated evaluation")
        }
        for manifest in [one, two, three, four, five, source, missingFine] {
            for context in [basic, capable, pressured, serious, smallBuffer] {
                if let recommendation = TerrainBudget.recommendedSpacing(for: manifest, context: context) {
                    try check(manifest.levels.contains { $0.spacing == recommendation } && allowed(manifest, recommendation, context), "Every recommendation names an available, allowed source level")
                    try check(!manifest.levels.contains { $0.spacing < recommendation && allowed(manifest, $0.spacing, context) }, "No finer fitting LOD is skipped")
                }
            }
        }
        print("PASS finest available recommendations and stable decisions from one device snapshot")

        // The primary selected map layer alone affects resident memory. Optional
        // full-source detail assets must never silently enter the GPU estimate.
        let fine = TerrainBudget.allowance(for: three, spacing: 2, context: capable)
        var withUnusedDetails = three; withUnusedDetails.detailTextures = source.detailTextures
        try check(TerrainBudget.allowance(for: withUnusedDetails, spacing: 2, context: capable).estimatedMemory == fine.estimatedMemory, "Unused source detail layers do not consume selected-scene memory")
        var smallerMap = three
        smallerMap.textures = three.textures.map { original in
            var texture = original; texture.width /= 2; texture.height /= 2; return texture
        }
        try check(fine.estimatedMemory > TerrainBudget.allowance(for: smallerMap, spacing: 2, context: capable).estimatedMemory, "Map pixels and mipmaps remain part of the memory allowance independent of terrain spacing")
        let vertices = three.levels.first { $0.spacing == 2 }!.sampleCount
        let cells = (three.levels.first { $0.spacing == 2 }!.width - 1) * (three.levels.first { $0.spacing == 2 }!.height - 1)
        let expanded = TerrainBudget.validateGeometry(for: three, spacing: 2, meshVertexCount: vertices + 1_000, indexCount: cells * 6 + 6_000, context: capable)
        try check(expanded.allowed && expanded.estimatedMemory > fine.estimatedMemory, "Renderer boundary insertion is charged before GPU allocation")
        let repeatedPhase = TerrainBudget.validateGeometry(for: three, spacing: 2, meshVertexCount: vertices, indexCount: cells * 6, context: capable)
        try check(repeatedPhase.estimatedMemory == fine.estimatedMemory, "Unexpanded rendering and selection use the same memory estimate")
        var loadedPhaseContext = capable
        // The process has spent some of its allowance on these same resident
        // heights since admission. The renderer may credit those known bytes,
        // while hardware and GPU limits remain in force.
        let residentHeights = Int64(vertices) * 4
        loadedPhaseContext.availableMemory = 64 * mib + (fine.estimatedMemory - residentHeights / 2) * 100 / 65
        try check(!TerrainBudget.validateGeometry(for: three, spacing: 2, meshVertexCount: vertices, indexCount: cells * 6, context: loadedPhaseContext).allowed, "A later live headroom check detects already-consumed memory")
        try check(TerrainBudget.validateGeometry(for: three, spacing: 2, meshVertexCount: vertices, indexCount: cells * 6, context: loadedPhaseContext, residentBytes: residentHeights).allowed, "Known resident heights are not charged twice during renderer preparation")
        try check(loadedPhaseContext.sceneMemoryLimit(residentBytes: Int64.max) <= capable.memoryLimit, "Resident allocation credit never bypasses physical or GPU working-set limits")
        try check(!TerrainBudget.validateGeometry(for: three, spacing: 2, meshVertexCount: Int.max, indexCount: Int.max, context: capable).allowed, "Malicious expanded geometry is rejected before arithmetic or allocation")

        for dimension in [Int.min, -1, 0, 1, Int.max, TerrainBudget.absoluteMaximumSamples] {
            var malformed = one
            malformed.levels[0].width = dimension; malformed.levels[0].height = dimension
            try check(!allowed(malformed, 1, capable), "Invalid or overflow-sized grid dimensions cannot be admitted")
        }
        var beyondAbsolute = one
        beyondAbsolute.levels[0].width = 4097; beyondAbsolute.levels[0].height = 4097
        try check(!allowed(beyondAbsolute, 1, capable), "Absolute source safety ceiling survives abundant memory")
        var invalidGrid = grid; invalidGrid.columns = Int.max; invalidGrid.originColumn = Int.max
        try check(!invalidGrid.isValid && invalidGrid.selection(column: 0, row: 0) == nil, "Malformed precision-grid extents cannot overflow selection arithmetic")
        for dimension in [Int.min, -1, 0, Int.max] {
            var malformed = one; malformed.textures[0].width = dimension
            try check(!allowed(malformed, 1, capable), "Invalid map dimensions cannot overflow texture estimation")
        }
        var extremeCost = one; extremeCost.graphByteCount = Int64.max
        try check(!allowed(extremeCost, 1, capable), "Overflow-sized graph costs saturate to rejection")
        var invalidContext = capable; invalidContext.availableMemory = Int64.min
        try check(!allowed(one, 32, invalidContext), "Invalid negative process headroom fails closed without overflow")
        invalidContext = capable; invalidContext.physicalMemory = Int64.min
        try check(!allowed(one, 32, invalidContext), "Invalid negative physical memory fails closed")
        print("PASS bounded expanded geometry and malicious dimensions fail safely before allocation")

        for (name, manifest, spacing, context) in [("basic 2×2", two, 1, basic), ("modern 4×4", four, 1, capable), ("modern 5×5", five, 1, capable)] {
            let result = TerrainBudget.allowance(for: manifest, spacing: spacing, context: context)
            print("MEASURE \(name) @\(spacing)m: \(result.estimatedMemory / mib) MiB scene / \(context.memoryLimit / mib) MiB allowance, \(result.allowed ? "allowed" : "blocked")")
        }
        try horizonBudget(source: sourceWithHorizon)
        print("PASS \(assertions) deterministic terrain-budget assertions")
    }

    private static func horizonBudget(source: RegionManifest) throws {
        guard let grid = source.grid, source.horizon != nil else { throw BudgetFailure(description: "Real source is missing horizon metadata") }
        let mib = BudgetFixtures.mebibyte
        let selection = grid.rectangle(from: TerrainCell(column: 0, row: 0), to: TerrainCell(column: 3, row: 3))!
        let simulator = TerrainBudget.Context(physicalMemory: 6 * BudgetFixtures.gibibyte, maximumBufferLength: 256 * mib, gpuTier: .apple)
        let alternatives = AreaCropper.preview(manifest: source, selection: selection, context: simulator)
        let selected = AreaCropper.preview(manifest: source, selection: selection, spacing: 1, context: simulator)
        var primary = selected; primary.horizon = nil
        let combined = TerrainBudget.allowance(for: selected, spacing: 1, context: simulator)
        let primaryAllowance = TerrainBudget.allowance(for: primary, spacing: 1, context: simulator)
        try check(selected.horizon?.near?.levels.map(\.spacing) == [8] && selected.horizon?.far?.levels.map(\.spacing) == [32], "The 4×4 1m simulator scene keeps its nearby 8m and distant 32m terrain")
        try check(combined.allowed && combined.estimatedMemory <= simulator.memoryLimit, "The real combined 4×4 scene and complete cartography fit the unchanged simulator policy")
        try check(combined.estimatedMemory > primaryAllowance.estimatedMemory && combined.bytesOnDisk > primaryAllowance.bytesOnDisk, "Both disk and memory admission include the surrounding terrain")
        try check(selected.levels == primary.levels && selected.levels.first { $0.spacing == 1 }?.width == 2049, "Surrounding terrain retains the selected native 1m planning grid")
        try check(selected.bounds == primary.bounds && selected.grid == primary.grid && selected.textures == primary.textures, "Context never expands the planning footprint or changes sharp primary cartography")
        try check(TerrainBudget.recommendedSpacing(for: alternatives, context: simulator) == 1, "Nearby context does not force a coarser primary resolution when the combined scene fits")
        try check(alternatives.horizon?.near?.levels.map(\.spacing) == [8, 16], "Preview alternatives retain the source near-layer choices for later admission")

        // Independently compose full-grid estimates to catch charging the 64 MiB
        // app baseline or primary path graph once per surrounding layer. Explicit
        // geometry removes the ring/cutout difference from this accounting check.
        let layers = selected.horizon!.layers
        let geometry = layers.map { layer -> TerrainBudget.Geometry in
            let level = layer.levels[0]
            return TerrainBudget.Geometry(meshVertexCount: level.sampleCount, indexCount: (level.width - 1) * (level.height - 1) * 6)
        }
        let mainLevel = selected.levels.first { $0.spacing == 1 }!
        let fullGeometry = TerrainBudget.validateGeometry(for: selected, spacing: 1, meshVertexCount: mainLevel.sampleCount,
            indexCount: (mainLevel.width - 1) * (mainLevel.height - 1) * 6, context: BudgetFixtures.capable, horizonGeometry: geometry)
        var composed = primaryAllowance.estimatedMemory + 8 * mib // One collar reserve for the complete scene.
        var composedDisk = primaryAllowance.bytesOnDisk
        for layer in layers {
            var isolated = primary
            isolated.bounds = layer.bounds; isolated.levels = layer.levels; isolated.textures = layer.textures
            isolated.defaultSpacing = layer.levels[0].spacing; isolated.grid = nil; isolated.places = []
            isolated.graphFile = nil; isolated.graphSHA256 = nil; isolated.graphByteCount = nil
            let cost = TerrainBudget.allowance(for: isolated, spacing: isolated.defaultSpacing, context: BudgetFixtures.capable)
            composed += cost.estimatedMemory - 64 * mib
            composedDisk += cost.bytesOnDisk
        }
        try check(fullGeometry.allowed && fullGeometry.estimatedMemory == composed, "Combined admission charges one app baseline and one path graph, with every layer’s actual geometry and maps")
        try check(fullGeometry.bytesOnDisk == composedDisk, "Combined save size charges every selected asset exactly once")
        try check(!TerrainBudget.validateGeometry(for: selected, spacing: 1, meshVertexCount: mainLevel.sampleCount,
            indexCount: (mainLevel.width - 1) * (mainLevel.height - 1) * 6, context: BudgetFixtures.capable,
            horizonGeometry: [geometry[0]]).allowed, "Incomplete renderer context geometry is rejected")

        // Derive pressure intervals from the real prepared maps, so a legitimate
        // cartography update does not freeze tests to one old PNG's pixel count.
        // Ordering remains explicit: protect the distant view before falling
        // back to nearby context alone, and never change the primary detail.
        let candidateBands: [(Int?, Int?)] = [(8, 32), (16, 32), (nil, 32), (8, nil), (16, nil), (nil, nil)]
        var candidates: [(cost: Int64, near: Int?, far: Int?)] = []
        for (near, far) in candidateBands {
            var candidate = alternatives
            var nearLayer = near == nil ? nil : alternatives.horizon?.near
            if let near, let levels = nearLayer?.levels { nearLayer?.levels = levels.filter { $0.spacing == near } }
            let farLayer = far == nil ? nil : alternatives.horizon?.far
            candidate.horizon = nearLayer == nil && farLayer == nil ? nil : TerrainHorizon(near: nearLayer, far: farLayer)
            let cost = TerrainBudget.validateGeometry(for: candidate, spacing: 1, meshVertexCount: mainLevel.sampleCount,
                indexCount: (mainLevel.width - 1) * (mainLevel.height - 1) * 6, context: BudgetFixtures.capable).estimatedMemory
            if cost < (candidates.last?.cost ?? .max) { candidates.append((cost, near, far)) }
        }
        var fallbacks: [(limit: Int64, near: Int?, far: Int?, fits: Bool)] = []
        for (index, candidate) in candidates.enumerated() {
            let upper = index == 0 ? simulator.memoryLimit : candidates[index - 1].cost
            let limit = candidate.cost + max(1, (upper - candidate.cost) / 2)
            fallbacks.append((limit, candidate.near, candidate.far, true))
        }
        fallbacks.append((primaryAllowance.estimatedMemory - mib, nil, nil, false))
        for (limit, nearSpacing, farSpacing, shouldFit) in fallbacks {
            var context = simulator
            context.availableMemory = 64 * mib + limit * 100 / 65 + 100
            let headroom = context.availableMemory! / mib
            let preview = AreaCropper.preview(manifest: source, selection: selection, spacing: 1, context: context)
            let allowance = TerrainBudget.allowance(for: preview, spacing: 1, context: context)
            try check(preview.horizon?.near?.levels.first?.spacing == nearSpacing && preview.horizon?.far?.levels.first?.spacing == farSpacing,
                "Headroom preserves far context first, then nearby maps, before primary-only admission")
            try check(allowance.allowed == shouldFit, "Context fallback remains subject to the complete memory allowance")
            try check(preview.levels == selected.levels && preview.bounds == selected.bounds && preview.textures == selected.textures,
                "Every headroom fallback preserves the explicitly selected primary spacing and map pixels")
            if let near = preview.horizon?.near {
                try check(near.textures == selected.horizon?.near?.textures, "Changing nearby LiDAR detail preserves every map tile and its pixel density")
            }
            if let far = preview.horizon?.far {
                try check(far.textures == selected.horizon?.far?.textures, "Removing a nearer terrain band never changes the distant cartography")
            }
            if shouldFit { try check(allowance.estimatedMemory <= context.memoryLimit, "A fallback is never reported available beyond its captured headroom") }
            for _ in 0..<5 {
                let repeatPreview = AreaCropper.preview(manifest: source, selection: selection, spacing: 1, context: context)
                try check(repeatPreview.horizon == preview.horizon, "Context fallback is stable within the same device snapshot")
            }
            print("MEASURE 4×4 @1m, \(headroom) MiB headroom: near \(nearSpacing.map(String.init) ?? "none"), far \(farSpacing.map(String.init) ?? "none"), \(allowance.estimatedMemory / mib) MiB scene, \(allowance.allowed ? "allowed" : "blocked")")
        }
        print("MEASURE full cartography 4×4 @1m: \(combined.estimatedMemory / mib) MiB; near \(selected.horizon!.near!.textures.count) maps, far \(selected.horizon!.far!.textures.count) maps")
        try check(source.horizon?.near?.levels.map(\.spacing) == [8, 16], "Admission does not mutate reusable source horizon alternatives")
        print("PASS combined horizon accounting, selected primary resolution and deterministic headroom fallbacks")
    }
}

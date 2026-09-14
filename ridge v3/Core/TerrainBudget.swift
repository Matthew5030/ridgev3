import Foundation
#if canImport(Metal)
import Metal
#endif
#if os(iOS)
import os
#endif

struct TerrainAllowance: Sendable {
    let allowed: Bool
    let bytesOnDisk: Int64
    /// Conservative scene allocation estimate, including preparation headroom.
    let estimatedMemory: Int64
    let reason: String?
}

/// Admission policy for a single, fully resident terrain scene. These are
/// engineering limits, not a frame-rate guarantee or an iOS termination limit.
enum TerrainBudget {
    static let absoluteMaximumSamples = 16_777_216
    static let absoluteMaximumMeshVertices = 18_454_937
    private static let mib: Int64 = 1_048_576

    enum GPUTier: Sendable, Equatable {
        case basic, apple, modern
        /// Bounded initial policy based on Metal feature support, not model names.
        var maximumSamples: Int {
            switch self {
            case .basic: return 1_100_000
            case .apple: return 4_500_000
            case .modern: return 8_500_000
            }
        }
    }

    enum ThermalPressure: Sendable, Equatable {
        case nominal, fair, serious, critical
        var percent: Int64 {
            switch self {
            case .nominal: return 100
            case .fair: return 85
            case .serious: return 65
            case .critical: return 50
            }
        }
    }

    /// Injectable so admission decisions can be tested independently of the
    /// build machine. Available memory means this process's remaining allowance.
    struct Context: Sendable, Equatable {
        var physicalMemory: Int64
        var availableMemory: Int64? = nil
        var recommendedGPUWorkingSet: Int64? = nil
        var maximumBufferLength: Int64? = nil
        var gpuTier: GPUTier = .modern
        var thermalPressure: ThermalPressure = .nominal
        /// Captured device contexts query Metal texture allocation. Explicit
        /// test contexts use the deterministic conservative layout allowance.
        var useDeviceTextureAllocation = false

        var maximumSamples: Int {
            min(absoluteMaximumSamples, gpuTier.maximumSamples * Int(thermalPressure.percent) / 100)
        }

        var memoryLimit: Int64 { sceneMemoryLimit() }

        /// Credit only allocations known to be resident already when checking a
        /// later load phase; this prevents charging the height array twice.
        func sceneMemoryLimit(residentBytes: Int64 = 0) -> Int64 {
            var limit = max(0, physicalMemory) / 5
            // Some Metal implementations (including Simulator) report zero
            // when this advisory value is unavailable. It is not a zero-byte
            // resource limit; RAM and process-headroom guards still apply.
            if let recommendedGPUWorkingSet, recommendedGPUWorkingSet > 0 {
                limit = min(limit, recommendedGPUWorkingSet / 2)
            }
            limit = limit / 100 * thermalPressure.percent
            if let availableMemory {
                let headroom = max(0, max(0, availableMemory) - 64 * mib)
                let usableHeadroom = headroom / 100 * 65
                limit = min(limit, saturatedAdd(usableHeadroom, max(0, residentBytes)))
            }
            return limit
        }
    }

    static func currentContext() -> Context {
        var context = Context(physicalMemory: Int64(clamping: ProcessInfo.processInfo.physicalMemory), gpuTier: .basic)
        #if os(iOS) && !targetEnvironment(simulator)
        // Unlike system free RAM, this accounts for the process's current limit.
        context.availableMemory = Int64(clamping: os_proc_available_memory())
        #endif
        #if canImport(Metal)
        if let device = MTLCreateSystemDefaultDevice() {
            context.useDeviceTextureAllocation = true
            let workingSet = Int64(clamping: device.recommendedMaxWorkingSetSize)
            let bufferLength = Int64(clamping: device.maxBufferLength)
            context.recommendedGPUWorkingSet = workingSet > 0 ? workingSet : nil
            context.maximumBufferLength = bufferLength > 0 ? bufferLength : nil
            if device.supportsFamily(.apple7) || device.supportsFamily(.mac2) {
                context.gpuTier = .modern
            } else if device.supportsFamily(.apple1) {
                context.gpuTier = .apple
            }
        }
        #endif
        #if targetEnvironment(simulator)
        // A simulator reports its Mac host's resources, not an iPhone's. Keep
        // its preview useful without presenting the host's RAM as device proof.
        context.physicalMemory = min(context.physicalMemory, 6 * 1_024 * mib)
        context.gpuTier = .apple
        #endif
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: context.thermalPressure = .nominal
        case .fair: context.thermalPressure = .fair
        case .serious: context.thermalPressure = .serious
        case .critical: context.thermalPressure = .critical
        @unknown default: context.thermalPressure = .serious
        }
        return context
    }

    /// Compatibility for diagnostics; use one Context snapshot for a UI update.
    static var memoryLimit: Int64 { currentContext().memoryLimit }

    struct Geometry: Sendable {
        var meshVertexCount: Int
        var indexCount: Int
    }

    static func allowance(for manifest: RegionManifest, spacing: Int, context: Context = currentContext()) -> TerrainAllowance {
        guard let level = manifest.levels.first(where: { $0.spacing == spacing }) else {
            return rejected("\(spacing) m terrain is not included in this source. Choose an available resolution or import a source containing it.")
        }
        guard let samples = sampleCount(width: level.width, height: level.height) else {
            return rejected("This terrain grid exceeds the supported scene size. Select fewer tiles or use a coarser resolution.")
        }
        let cells = (level.width - 1) * (level.height - 1)
        var last: TerrainAllowance?
        for horizon in horizonCandidates(manifest.horizon) {
            var candidate = manifest; candidate.horizon = horizon
            let allowance = evaluate(manifest: candidate, level: level, sourceSamples: samples, meshVertices: samples,
                                     indexCount: cells * 6, context: context, residentBytes: 0)
            if allowance.allowed { return allowance }
            last = allowance
        }
        return last ?? rejected("This terrain cannot be prepared on this device.")
    }

    /// Deterministic context fallback for a fixed primary spacing. Source
    /// alternatives are reduced to one level per saved layer before copying.
    static func selectedHorizon(for manifest: RegionManifest, spacing: Int, context: Context = currentContext()) -> TerrainHorizon? {
        guard let level = manifest.levels.first(where: { $0.spacing == spacing }),
              let samples = sampleCount(width: level.width, height: level.height) else { return nil }
        for horizon in horizonCandidates(manifest.horizon) {
            var candidate = manifest; candidate.horizon = horizon
            if evaluate(manifest: candidate, level: level, sourceSamples: samples, meshVertices: samples,
                        indexCount: (level.width - 1) * (level.height - 1) * 6, context: context, residentBytes: 0).allowed { return horizon }
        }
        return nil
    }

    private static func horizonCandidates(_ horizon: TerrainHorizon?) -> [TerrainHorizon?] {
        guard let horizon else { return [nil] }
        func at(_ source: TerrainBackdrop?, spacing: Int) -> TerrainBackdrop? {
            guard var source, let level = source.levels.first(where: { $0.spacing == spacing }) else { return nil }
            source.levels = [level]; return source
        }
        let far = at(horizon.far, spacing: 32)
        var candidates: [TerrainHorizon?] = []
        for spacing in [8, 16, 32] {
            if let near = at(horizon.near, spacing: spacing) { candidates.append(TerrainHorizon(near: near, far: far)) }
        }
        if far != nil { candidates.append(TerrainHorizon(far: far)) }
        // A detailed distant map can cost more than the nearby band. Retain
        // useful mapped surroundings if only the farther extent exceeds memory.
        if far != nil {
            for spacing in [8, 16, 32] {
                if let near = at(horizon.near, spacing: spacing) { candidates.append(TerrainHorizon(near: near)) }
            }
        }
        candidates.append(nil)
        return candidates
    }

    static func recommendedSpacing(for manifest: RegionManifest, context: Context = currentContext()) -> Int? {
        manifest.levels.map(\.spacing).sorted().first { allowance(for: manifest, spacing: $0, context: context).allowed }
    }

    /// Start new selections at 4 m for faster preparation and lighter geometry.
    /// Finer detail remains an explicit choice; Auto still finds the finest fit.
    static func defaultSpacing(for manifest: RegionManifest, context: Context = currentContext()) -> Int? {
        let levels = manifest.levels.map(\.spacing)
        let choices = levels.filter { $0 >= 4 }.sorted() + levels.filter { $0 < 4 }.sorted(by: >)
        return choices.first { allowance(for: manifest, spacing: $0, context: context).allowed }
    }

    /// Called after inserting map boundaries into the mesh, before allocating
    /// GPU resources. indexCount is a safe upper bound (six per valid grid cell).
    static func validateGeometry(for manifest: RegionManifest, spacing: Int, meshVertexCount: Int,
                                 indexCount: Int, context: Context, residentBytes: Int64 = 0,
                                 horizonGeometry: [Geometry] = []) -> TerrainAllowance {
        guard let level = manifest.levels.first(where: { $0.spacing == spacing }),
              let samples = sampleCount(width: level.width, height: level.height),
              meshVertexCount >= samples, meshVertexCount <= absoluteMaximumMeshVertices,
              indexCount >= 0, indexCount <= absoluteMaximumMeshVertices * 6 else {
            return rejected("The terrain and map boundaries exceed the supported scene size. Select a smaller area.")
        }
        return evaluate(manifest: manifest, level: level, sourceSamples: samples, meshVertices: meshVertexCount,
                        indexCount: indexCount, context: context, residentBytes: residentBytes, horizonGeometry: horizonGeometry)
    }

    private static func sampleCount(width: Int, height: Int) -> Int? {
        guard width >= 2, height >= 2, width <= absoluteMaximumSamples, height <= absoluteMaximumSamples else { return nil }
        let product = width.multipliedReportingOverflow(by: height)
        return !product.overflow && product.partialValue <= absoluteMaximumSamples ? product.partialValue : nil
    }

    private static func evaluate(manifest: RegionManifest, level: TerrainLOD, sourceSamples: Int,
                                 meshVertices: Int, indexCount: Int, context: Context, residentBytes: Int64,
                                 horizonGeometry: [Geometry] = []) -> TerrainAllowance {
        let vertexBytes = Int64(meshVertices) * 48
        let indexBytes = Int64(indexCount) * 4
        // Vertices and triangle indices are filled directly in shared Metal
        // buffers. Float heights stay resident; validity and minor grid overhead
        // bring the normal full grid estimate to approximately 80 bytes/sample.
        var geometry = vertexBytes + indexBytes + Int64(sourceSamples) * 4 + Int64(meshVertices) * 4
        var totalSamples = sourceSamples, totalVertices = meshVertices
        var largestVertexBuffer = vertexBytes, largestIndexBuffer = indexBytes
        var terrainDisk = max(0, level.byteCount)
        let layers = manifest.horizon?.layers ?? []
        guard horizonGeometry.isEmpty || horizonGeometry.count == layers.count else { return rejected("The surrounding terrain geometry is incomplete.") }
        var innerBounds = manifest.bounds
        for (index, layer) in layers.enumerated() {
            guard layer.bounds.isValid, layer.levels.count == 1, let level = layer.levels.first,
                  [8, 16, 32].contains(level.spacing), let samples = sampleCount(width: level.width, height: level.height) else {
                return rejected("The surrounding terrain has invalid dimensions or detail levels.")
            }
            let mesh = horizonGeometry.isEmpty
                ? ringGeometry(level: level, bounds: layer.bounds, innerBounds: innerBounds)
                : horizonGeometry[index]
            guard mesh.meshVertexCount >= 0, mesh.meshVertexCount <= absoluteMaximumMeshVertices,
                  mesh.indexCount >= 0, mesh.indexCount <= absoluteMaximumMeshVertices * 6 else { return rejected("The surrounding terrain exceeds the supported scene size.") }
            totalSamples += samples; totalVertices += mesh.meshVertexCount
            let vertices = Int64(mesh.meshVertexCount) * 48, indices = Int64(mesh.indexCount) * 4
            geometry += vertices + indices + Int64(samples) * 4 + Int64(mesh.meshVertexCount) * 4
            largestVertexBuffer = max(largestVertexBuffer, vertices); largestIndexBuffer = max(largestIndexBuffer, indices)
            terrainDisk = saturatedAdd(terrainDisk, max(0, level.byteCount))
            innerBounds = layer.bounds
        }
        // A small fixed allowance for collars joining fine and coarse surfaces.
        if !layers.isEmpty { geometry += 8 * mib }
        let mapMemory: Int64, mapDisk: Int64
        if let atlas = manifest.cartography {
            // Terrain detail changes geometry only. All layers share one
            // native map atlas and one bounded preview/native image cache.
            guard let footprint = atlas.footprint(covering: layers.last?.bounds ?? manifest.bounds) else {
                return rejected("The shared map atlas is incomplete or exceeds its bounded memory allowance.")
            }
            mapMemory = context.useDeviceTextureAllocation ? footprint.estimatedMemoryBytes : footprint.conservativeMemoryBytes
            guard mapMemory <= CartographyAtlas.maximumMemoryBytes else {
                return rejected("The shared map atlas exceeds its bounded memory allowance on this device.")
            }
            mapDisk = footprint.bytesOnDisk
        } else {
            var mapBytes: Int64 = 0, disk: Int64 = 0
            for texture in manifest.textures + layers.flatMap(\.textures) {
                guard (1...16_384).contains(texture.width), (1...16_384).contains(texture.height), texture.byteCount >= 0 else {
                    return rejected("A map texture has unsupported dimensions or size.")
                }
                mapBytes = saturatedAdd(mapBytes, Int64(texture.width) * Int64(texture.height) * 16 / 3)
                disk = saturatedAdd(disk, texture.byteCount)
            }
            mapMemory = saturatedMultiply(mapBytes, 2)
            mapDisk = disk
        }
        let graph = max(0, manifest.graphByteCount ?? 0)
        let mapAndGraphMemory = saturatedAdd(mapMemory, saturatedAdd(saturatedMultiply(graph, 4), 64 * mib))
        let memory = saturatedAdd(geometry, mapAndGraphMemory)
        let disk = saturatedAdd(terrainDisk, saturatedAdd(mapDisk, graph))
        let limit = context.sceneMemoryLimit(residentBytes: residentBytes)
        let reason: String?
        // Context has a separate bounded geometry reserve. It is coarser and
        // excludes the centre covered by the detailed area, but its full height
        // arrays are still charged above. The reserve is an engineering policy.
        let meshLimit = min(absoluteMaximumMeshVertices, context.maximumSamples * (layers.isEmpty ? 110 : 125) / 100)
        if sourceSamples > context.maximumSamples || totalSamples > absoluteMaximumSamples || totalVertices > meshLimit {
            reason = "This selection exceeds the terrain detail budget for this device\(context.thermalPressure == .nominal ? "" : " at its current temperature"). Select fewer tiles or use a coarser resolution."
        } else if let bufferLimit = context.maximumBufferLength, bufferLimit > 0, largestVertexBuffer > bufferLimit || largestIndexBuffer > bufferLimit {
            reason = "This terrain exceeds the graphics buffer size supported by this device. Select fewer tiles or use a coarser resolution."
        } else if memory > limit {
            reason = mapAndGraphMemory > limit
                ? "The map textures and paths exceed the memory currently available for this scene. Select fewer tiles. Coarser terrain alone will not fit these map assets."
                : "This selection needs more memory than is currently available for terrain and maps. Select fewer tiles or use a coarser resolution."
        } else { reason = nil }
        return TerrainAllowance(allowed: reason == nil, bytesOnDisk: disk, estimatedMemory: memory, reason: reason)
    }

    private static func ringGeometry(level: TerrainLOD, bounds: GeoBounds, innerBounds: GeoBounds) -> Geometry {
        let a = bounds.uv(GeoPoint(latitude: innerBounds.maxLatitude, longitude: innerBounds.minLongitude))
        let b = bounds.uv(GeoPoint(latitude: innerBounds.minLatitude, longitude: innerBounds.maxLongitude))
        let x0 = max(0, min(Double(level.width - 1), a.u * Double(level.width - 1)))
        let x1 = max(0, min(Double(level.width - 1), b.u * Double(level.width - 1)))
        let y0 = max(0, min(Double(level.height - 1), a.v * Double(level.height - 1)))
        let y1 = max(0, min(Double(level.height - 1), b.v * Double(level.height - 1)))
        let interiorColumns = max(0, Int(ceil(x1 - 1e-8)) - Int(floor(x0 + 1e-8)) - 1)
        let interiorRows = max(0, Int(ceil(y1 - 1e-8)) - Int(floor(y0 + 1e-8)) - 1)
        let innerCellColumns = max(0, Int(floor(x1 + 1e-8)) - Int(ceil(x0 - 1e-8)))
        let innerCellRows = max(0, Int(floor(y1 + 1e-8)) - Int(ceil(y0 - 1e-8)))
        let samples = level.width * level.height - interiorColumns * interiorRows
        let cells = (level.width - 1) * (level.height - 1) - innerCellColumns * innerCellRows
        return Geometry(meshVertexCount: samples, indexCount: cells * 6)
    }

    private static func rejected(_ reason: String) -> TerrainAllowance {
        TerrainAllowance(allowed: false, bytesOnDisk: 0, estimatedMemory: 0, reason: reason)
    }

    private static func saturatedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }

    private static func saturatedMultiply(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        return result.overflow ? .max : result.partialValue
    }
}

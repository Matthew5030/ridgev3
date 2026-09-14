import Foundation
#if canImport(Metal)
import Metal
#endif

/// One geographic map, shared by every terrain resolution. Image bounds name
/// the inner tile; the four-pixel gutters extend its sampling footprint only.
struct CartographyTile: Codable, Hashable, Sendable {
    var image: MapTexture
    var preview: MapTexture
}

struct LoadedCartography: Sendable {
    var metadata: CartographyAtlas
    var imageURLs: [URL]
    var previewURLs: [URL]
}

struct CartographyAtlas: Codable, Hashable, Sendable {
    var columns: Int
    var rows: Int
    var longitudeEdges: [Double]
    var latitudeEdges: [Double]
    /// Northwest first, then east across each row before moving south.
    var tiles: [CartographyTile]
    /// Large disk catalogue only; cropped scenes retain the 64-cell GPU limit.
    var sourceOnly: Bool? = nil

    static let maximumTiles = 4_096
    static let maximumAxisTiles = 64
    static let imageCoreSize = 1_024
    static let previewCoreSize = 64
    static let gutter = 4
    static let imageSize = imageCoreSize + 2 * gutter
    static let previewSize = previewCoreSize + 2 * gutter
    static let maximumResidentImages = 16
    static let mediumCoreSize = 256
    static let mediumGutter = 4
    static let mediumSize = mediumCoreSize + 2 * mediumGutter
    static let maximumResidentMediumImages = 192
    static let maximumMemoryBytes: Int64 = 384 * 1_048_576
    static let maximumImageFileBytes: Int64 = 16 * 1_048_576
    static let maximumPreviewFileBytes: Int64 = 1_048_576
    /// Residency includes one sequential decode/upload job. No task may queue
    /// another decoded image while this job is waiting for its cache slot.
    static let decodeUploadMemoryBytes: Int64 = 32 * 1_048_576
    static let metadataMemoryBytes: Int64 = 2 * 1_048_576

    static func mipmappedRGBABytes(size: Int) -> Int64 {
        guard size > 0, size <= imageSize else { return .max }
        var dimension = size, bytes: Int64 = 0
        repeat {
            bytes += Int64(dimension) * Int64(dimension) * 4
            dimension /= 2
        } while dimension > 0
        return bytes
    }

    var estimatedMemoryBytes: Int64 { Self.memoryBytes(columns: columns, rows: rows, useDevice: true) }
    var conservativeMemoryBytes: Int64 { Self.memoryBytes(columns: columns, rows: rows, useDevice: false) }

    private static func memoryBytes(columns: Int, rows: Int, useDevice: Bool) -> Int64 {
        guard validAllocationDimensions(columns: columns, rows: rows) else { return .max }
        #if canImport(Metal)
        if useDevice, let device = MTLCreateSystemDefaultDevice(),
           let bytes = deviceMemoryBytes(columns: columns, rows: rows, device: device) { return bytes }
        #endif
        // Deterministic fallback for injected contexts and unavailable device
        // queries. Renderer preflight still checks the actual Metal allocations.
        // The array-slot ceilings include padding observed above raw mip texels.
        let count = columns * rows
        var width = columns * previewCoreSize, height = rows * previewCoreSize, preview: Int64 = 0
        repeat {
            preview += Int64(width * height * 4)
            if width == 1 && height == 1 { break }
            width = max(1, width / 2); height = max(1, height / 2)
        } while true
        preview = ((preview + 65_535) / 65_536 + 1) * 65_536
        let native = Int64(min(count, maximumResidentImages)) * 7 * 1_048_576
        let medium = Int64(min(count, maximumResidentMediumImages)) * 768 * 1_024
        return preview + native + medium + decodeUploadMemoryBytes + metadataMemoryBytes
    }

    private static func validAllocationDimensions(columns: Int, rows: Int) -> Bool {
        (1...maximumAxisTiles).contains(columns) && (1...maximumAxisTiles).contains(rows)
    }

    #if canImport(Metal)
    /// Query the same descriptors the renderer allocates. Small array images
    /// can have far more driver padding than their nominal mip texel count.
    func estimatedMemoryBytes(device: MTLDevice) -> Int64 {
        Self.deviceMemoryBytes(columns: columns, rows: rows, device: device) ?? conservativeMemoryBytes
    }

    private static func deviceMemoryBytes(columns: Int, rows: Int, device: MTLDevice) -> Int64? {
        guard validAllocationDimensions(columns: columns, rows: rows) else { return nil }
        let count = columns * rows
        let formats: [(Int, Int, Int, MTLTextureType)] = [
            (columns * previewCoreSize, rows * previewCoreSize, 1, .type2D),
            (imageSize, imageSize, min(count, maximumResidentImages), .type2DArray),
            (mediumSize, mediumSize, min(count, maximumResidentMediumImages), .type2DArray)
        ]
        var total: Int64 = decodeUploadMemoryBytes + metadataMemoryBytes
        for (width, height, slices, type) in formats {
            let descriptor = MTLTextureDescriptor()
            descriptor.textureType = type; descriptor.pixelFormat = .rgba8Unorm_srgb
            descriptor.width = width; descriptor.height = height; descriptor.arrayLength = slices
            descriptor.mipmapLevelCount = Int(floor(log2(Double(max(width, height))))) + 1
            descriptor.storageMode = .private
            descriptor.usage = type == .type2D ? .shaderRead : [.shaderRead, .pixelFormatView]
            let allocation = device.heapTextureSizeAndAlign(descriptor: descriptor)
            let size = Int64(clamping: allocation.size), alignment = max(65_536, Int64(clamping: allocation.align))
            guard size > 0, allocation.align > 0 else { return nil }
            let padded = size.addingReportingOverflow(alignment - 1)
            guard !padded.overflow else { return nil }
            let rounded = (padded.partialValue / alignment).multipliedReportingOverflow(by: alignment)
            guard !rounded.overflow else { return nil }
            // Standalone textures can slightly exceed the heap query. Reserve
            // another 64 KiB per resource; an actual-size guard remains mandatory.
            let guarded = rounded.partialValue.addingReportingOverflow(65_536)
            guard !guarded.overflow else { return nil }
            let sum = total.addingReportingOverflow(guarded.partialValue)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return total
    }
    #endif

    var bounds: GeoBounds {
        GeoBounds(minLatitude: latitudeEdges.last ?? .nan, minLongitude: longitudeEdges.first ?? .nan,
                  maxLatitude: latitudeEdges.first ?? .nan, maxLongitude: longitudeEdges.last ?? .nan)
    }

    var allTextures: [MapTexture] { tiles.flatMap { [$0.image, $0.preview] } }

    /// Saturation makes even an unvalidated manifest safe to display in a list.
    var totalBytes: Int64 {
        tiles.reduce(0) { sum, tile in
            [tile.image.byteCount, tile.preview.byteCount].reduce(sum) { sum, size in
                let result = sum.addingReportingOverflow(max(0, size))
                return result.overflow ? .max : result.partialValue
            }
        }
    }

    /// Pure metadata checks. PackStore separately checks file containment,
    /// payload hashes and decoded image dimensions before activating the pack.
    func validate(covering coverage: GeoBounds? = nil) throws {
        try validateAllocationMetadata()
        if let coverage, !contains(coverage) {
            throw ValidationError("The cartography atlas does not cover all of this terrain.")
        }
        var filenames = Set<String>()
        for tile in tiles {
            for texture in [tile.image, tile.preview] {
                guard Self.safeName(texture.file), Self.validHash(texture.sha256),
                      texture.file.lowercased() != "pack.json", filenames.insert(texture.file.lowercased()).inserted else {
                    throw ValidationError("A cartography tile has an invalid filename or integrity metadata.")
                }
            }
        }
    }

    struct Footprint: Sendable {
        let tileCount: Int
        let columns: Int
        let rows: Int
        let bytesOnDisk: Int64
        var estimatedMemoryBytes: Int64 { CartographyAtlas.memoryBytes(columns: columns, rows: rows, useDevice: true) }
        var conservativeMemoryBytes: Int64 { CartographyAtlas.memoryBytes(columns: columns, rows: rows, useDevice: false) }
    }

    /// Allocation-only estimate: validate all dimensions, geographic cells and
    /// byte limits, then total the covered rectangle without copying its tiles.
    /// This never authorizes asset access; validate/cropped and PackStore still
    /// check filenames and hashes before preparing, installing or loading files.
    func footprint(covering requested: GeoBounds) -> Footprint? {
        guard (try? validateAllocationMetadata()) != nil, contains(requested),
              let left = (0..<columns).last(where: { longitudeEdges[$0] <= requested.minLongitude }),
              let right = (1...columns).first(where: { longitudeEdges[$0] >= requested.maxLongitude }),
              let top = (0..<rows).last(where: { latitudeEdges[$0] >= requested.maxLatitude }),
              let bottom = (1...rows).first(where: { latitudeEdges[$0] <= requested.minLatitude }),
              left < right, top < bottom else { return nil }
        var bytes: Int64 = 0
        for row in top..<bottom {
            for column in left..<right {
                let tile = tiles[row * columns + column]
                bytes += tile.image.byteCount + tile.preview.byteCount
            }
        }
        // Both the cell count and per-image byte counts have fixed, checked
        // upper bounds, so these products and sums cannot overflow.
        return Footprint(tileCount: (right - left) * (bottom - top), columns: right - left, rows: bottom - top, bytesOnDisk: bytes)
    }

    private func validateAllocationMetadata() throws {
        let axisLimit = sourceOnly == true ? 256 : Self.maximumAxisTiles
        guard (1...axisLimit).contains(columns), (1...axisLimit).contains(rows) else {
            throw ValidationError("The cartography atlas has invalid grid dimensions.")
        }
        let count = columns.multipliedReportingOverflow(by: rows)
        guard !count.overflow, count.partialValue <= axisLimit * axisLimit, tiles.count == count.partialValue,
              longitudeEdges.count == columns + 1, latitudeEdges.count == rows + 1 else {
            throw ValidationError("The cartography atlas is incomplete or exceeds its tile limit.")
        }
        guard longitudeEdges.allSatisfy({ $0.isFinite && (-180...180).contains($0) }),
              latitudeEdges.allSatisfy({ $0.isFinite && (-90...90).contains($0) }),
              zip(longitudeEdges, longitudeEdges.dropFirst()).allSatisfy({ $0 < $1 }),
              zip(latitudeEdges, latitudeEdges.dropFirst()).allSatisfy({ $0 > $1 }), bounds.isValid else {
            throw ValidationError("The cartography atlas has invalid geographic edges.")
        }
        for (index, tile) in tiles.enumerated() {
            let column = index % columns, row = index / columns
            let cell = GeoBounds(minLatitude: latitudeEdges[row + 1], minLongitude: longitudeEdges[column],
                                 maxLatitude: latitudeEdges[row], maxLongitude: longitudeEdges[column + 1])
            for (texture, size, maximumBytes) in [(tile.image, Self.imageSize, Self.maximumImageFileBytes),
                                                 (tile.preview, Self.previewSize, Self.maximumPreviewFileBytes)] {
                guard texture.width == size, texture.height == size, texture.bounds == cell,
                      texture.byteCount > 0, texture.byteCount <= maximumBytes else {
                    throw ValidationError("A cartography tile has invalid dimensions, geographic bounds or encoded size.")
                }
            }
        }
    }

    /// Select whole existing cells without resampling their images. Exact
    /// boundary matches include only the cells on the requested side.
    func cropped(to requested: GeoBounds) -> CartographyAtlas? {
        guard (try? validate(covering: requested)) != nil,
              let left = (0..<columns).last(where: { longitudeEdges[$0] <= requested.minLongitude }),
              let right = (1...columns).first(where: { longitudeEdges[$0] >= requested.maxLongitude }),
              let top = (0..<rows).last(where: { latitudeEdges[$0] >= requested.maxLatitude }),
              let bottom = (1...rows).first(where: { latitudeEdges[$0] <= requested.minLatitude }),
              left < right, top < bottom else { return nil }
        var selected: [CartographyTile] = []
        selected.reserveCapacity((right - left) * (bottom - top))
        for row in top..<bottom { selected.append(contentsOf: tiles[(row * columns + left)..<(row * columns + right)]) }
        return CartographyAtlas(columns: right - left, rows: bottom - top,
                                longitudeEdges: Array(longitudeEdges[left...right]),
                                latitudeEdges: Array(latitudeEdges[top...bottom]), tiles: selected)
    }

    private func contains(_ requested: GeoBounds) -> Bool {
        requested.isValid && bounds.minLatitude <= requested.minLatitude && bounds.maxLatitude >= requested.maxLatitude
            && bounds.minLongitude <= requested.minLongitude && bounds.maxLongitude >= requested.maxLongitude
    }

    private static func safeName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 150 && value != "." && value != ".."
            && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }
    }

    private static func validHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }

    private struct ValidationError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

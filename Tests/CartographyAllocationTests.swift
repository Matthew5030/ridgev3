import Foundation
import Metal

private struct AllocationFailure: Error, CustomStringConvertible { let description: String }

/// Uses real driver allocation, rather than nominal RGBA mip texel counts.
/// Run on a Metal-capable Mac; these results do not stand in for iPhone profiling.
@MainActor @main struct CartographyAllocationTests {
    private static var assertions = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        if !condition() { throw AllocationFailure(description: message) }
    }

    private static func atlas(columns: Int, rows: Int) -> CartographyAtlas {
        let x = (0...columns).map { -4.0 + Double($0) * 0.001 }
        let y = (0...rows).map { 54.0 - Double($0) * 0.001 }
        let checksum = String(repeating: "a", count: 64)
        let tiles = (0..<(columns * rows)).map { index -> CartographyTile in
            let row = index / columns, column = index % columns
            let bounds = GeoBounds(minLatitude: y[row + 1], minLongitude: x[column], maxLatitude: y[row], maxLongitude: x[column + 1])
            return CartographyTile(image: MapTexture(file: "image-\(index).png", width: 1032, height: 1032, byteCount: 1, sha256: checksum, bounds: bounds),
                                   preview: MapTexture(file: "preview-\(index).png", width: 72, height: 72, byteCount: 1, sha256: checksum, bounds: bounds))
        }
        return CartographyAtlas(columns: columns, rows: rows, longitudeEdges: x, latitudeEdges: y, tiles: tiles)
    }

    private static func texture(device: MTLDevice, width: Int, height: Int, slices: Int, array: Bool) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = array ? .type2DArray : .type2D
        descriptor.pixelFormat = .rgba8Unorm_srgb
        descriptor.width = width; descriptor.height = height; descriptor.arrayLength = slices
        descriptor.mipmapLevelCount = Int(floor(log2(Double(max(width, height))))) + 1
        descriptor.storageMode = .private
        descriptor.usage = array ? [.shaderRead, .pixelFormatView] : .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw AllocationFailure(description: "Texture allocation failed") }
        return texture
    }

    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("SKIP actual cartography allocation: no Metal device")
            return
        }
        print("DEVICE \(device.name)")
        try check(CartographyAtlas.maximumAxisTiles == 64 && CartographyAtlas.maximumResidentImages == 16
                  && CartographyAtlas.maximumResidentMediumImages == 192, "Allocation harness matches the supported production layout")
        let reserve = CartographyAtlas.decodeUploadMemoryBytes + CartographyAtlas.metadataMemoryBytes
        for (columns, rows) in [(1, 1), (1, 64), (43, 43), (50, 47), (56, 56), (64, 64)] {
            try autoreleasepool {
                let metadata = atlas(columns: columns, rows: rows)
                try metadata.validate()
                let count = columns * rows
                let preview = try texture(device: device, width: columns * 64, height: rows * 64, slices: 1, array: false)
                let native = try texture(device: device, width: 1032, height: 1032, slices: min(count, 16), array: true)
                let medium = try texture(device: device, width: 264, height: 264, slices: min(count, 192), array: true)
                let actual = Int64(preview.allocatedSize + native.allocatedSize + medium.allocatedSize) + reserve
                let estimated = metadata.estimatedMemoryBytes(device: device)
                let report = String(format: "MEASURE %dx%d: preview %.5f MiB; native %.5f MiB; medium %.5f MiB; actual with reserves %.5f MiB; estimate %.5f MiB; fallback %.5f MiB\n",
                             columns, rows, Double(preview.allocatedSize) / 1_048_576, Double(native.allocatedSize) / 1_048_576,
                             Double(medium.allocatedSize) / 1_048_576, Double(actual) / 1_048_576,
                             Double(estimated) / 1_048_576, Double(metadata.conservativeMemoryBytes) / 1_048_576)
                FileHandle.standardOutput.write(Data(report.utf8))
                try check(estimated >= actual, "Device query admission underestimates actual texture allocation for \(columns)×\(rows)")
                try check(estimated <= CartographyAtlas.maximumMemoryBytes || actual > CartographyAtlas.maximumMemoryBytes,
                          "A supported actual allocation should not be needlessly rejected by the device query")
                withExtendedLifetime([preview, native, medium]) { }
            }
        }
        // Preserve the original failure as a reproducible comparison: every
        // tiny preview occupied an array slice, magnifying per-slice alignment.
        let obsoleteTextures: Int64 = try autoreleasepool {
            let preview = try texture(device: device, width: 72, height: 72, slices: 2048, array: true)
            let native = try texture(device: device, width: 1032, height: 1032, slices: 16, array: true)
            let medium = try texture(device: device, width: 264, height: 264, slices: 256, array: true)
            return Int64(preview.allocatedSize * 2 + native.allocatedSize + medium.allocatedSize)
        }
        let obsoleteNominal = Int64(4096) * CartographyAtlas.mipmappedRGBABytes(size: 72)
            + Int64(16) * CartographyAtlas.mipmappedRGBABytes(size: 1032)
            + Int64(256) * CartographyAtlas.mipmappedRGBABytes(size: 264)
        let obsoleteEstimate = obsoleteNominal * 110 / 100 + reserve
        print(String(format: "REGRESSION old tiny-array layout: actual with reserves %.5f MiB; obsolete texel-plus10%% estimate %.5f MiB",
                     Double(obsoleteTextures + reserve) / 1_048_576, Double(obsoleteEstimate) / 1_048_576))
        print("PASS actual Metal cartography allocation: \(assertions) assertions")
    }
}

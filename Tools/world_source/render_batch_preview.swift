import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Uses the exact app cartography, material, lighting and overhead camera.
@main struct RenderBatchPreview {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { throw RidgeError.message("Expected world source directory and output JPEG") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let store = WorldSourceStore(bundledURL: root, cacheURL: cache)
        let (source, overview, _) = try await store.open(address: "")
        let backdrop = try await store.backdrop(source: source, overview: overview)
        let (image, _) = try await store.preview(source: source, backdrop: backdrop)
        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw RidgeError.message("Cannot create preview") }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw RidgeError.message("Cannot save preview") }
        let record: [String: Any] = ["width":image.width,"height":image.height,"sourceID":source.id]
        print(String(decoding: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), as: UTF8.self))
    }
}

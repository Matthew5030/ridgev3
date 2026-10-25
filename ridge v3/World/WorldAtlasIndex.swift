import Foundation

/// Standard Web Mercator XYZ pages. Keys are also safe, flat bundle filenames.
struct WorldAtlasPage: Hashable, Comparable {
    let zoom: Int
    let x: Int
    let y: Int
    var key: String { "z\(zoom)-x\(x)-y\(y).jpg" }
    var divisions: Double { Double(1 << zoom) }
    var parent: WorldAtlasPage? { zoom > 0 ? WorldAtlasPage(zoom: zoom - 1, x: x / 2, y: y / 2) : nil }
    init(zoom: Int, x: Int, y: Int) { self.zoom = zoom; self.x = x; self.y = y }
    init?(key: String) {
        let stem = key.hasSuffix(".jpg") ? String(key.dropLast(4)) : key
        let parts = stem.split(separator: "-")
        guard parts.count == 3, parts[0].first == "z", parts[1].first == "x", parts[2].first == "y",
              let z = Int(parts[0].dropFirst()), (0...18).contains(z),
              let x = Int(parts[1].dropFirst()), let y = Int(parts[2].dropFirst()),
              x >= 0, y >= 0, x < (1 << z), y < (1 << z) else { return nil }
        self.init(zoom: z, x: x, y: y)
    }
    static func < (a: Self, b: Self) -> Bool {
        if a.zoom != b.zoom { return a.zoom < b.zoom }
        if a.y != b.y { return a.y < b.y }
        return a.x < b.x
    }
}

struct WorldAtlasIndex {
    let minZoom: Int
    let maxZoom: Int
    let tileSize: Int
    let renderer:String?
    let capturedSections:Int
    let available: Set<WorldAtlasPage>
    private struct Manifest: Decodable {
        let schemaVersion: Int
        let minZoom: Int
        let maxZoom: Int
        let tileSize: Int
        let tiles: [String]
        var renderer:String?
        var semanticSectionCount:Int?
    }
    enum Invalid: Error { case manifest }
    init(data: Data) throws {
        let value = try JSONDecoder().decode(Manifest.self, from: data)
        guard value.schemaVersion == 1, value.tileSize == 256,
              (0...18).contains(value.minZoom), (value.minZoom...18).contains(value.maxZoom) else { throw Invalid.manifest }
        minZoom = value.minZoom; maxZoom = value.maxZoom; tileSize = value.tileSize
        renderer=value.renderer;capturedSections=value.semanticSectionCount ?? 0
        available = Set(value.tiles.compactMap(WorldAtlasPage.init(key:)).filter { (value.minZoom...value.maxZoom).contains($0.zoom) })
    }

    /// At most 64 screen pages plus their parents, regardless of zoom or device size.
    /// Coarse pages remain beneath detail, including where the pyramid is incomplete.
    func pages(centerX: Double, centerY: Double, scale: Double, width: Double, height: Double, pixelScale: Double = 1, coarseOnly: Bool = false) -> [WorldAtlasPage] {
        guard scale.isFinite, scale > 0, width.isFinite, height.isFinite, width > 0, height > 0,
              centerX.isFinite, centerY.isFinite else { return [] }
        let left = max(0, centerX - width / (2 * scale)), right = min(1, centerX + width / (2 * scale))
        let top = max(0, centerY - height / (2 * scale)), bottom = min(1, centerY + height / (2 * scale))
        guard right > left, bottom > top else { return [] }
        let density = pixelScale.isFinite ? min(3, max(1, pixelScale)) : 1
        var zoom = coarseOnly ? minZoom : min(maxZoom, max(minZoom, Int(floor(log2(max(1, scale * density / Double(tileSize)))))))
        func range(_ low: Double, _ high: Double, _ z: Int) -> ClosedRange<Int> {
            let n = 1 << z
            return max(0, min(n - 1, Int(floor(low * Double(n)))))...max(0, min(n - 1, Int(ceil(high * Double(n))) - 1))
        }
        while zoom > minZoom, range(left, right, zoom).count * range(top, bottom, zoom).count > 64 { zoom -= 1 }
        var selected = Set<WorldAtlasPage>()
        for z in minZoom...zoom {
            let xs = range(left, right, z), ys = range(top, bottom, z)
            if xs.count * ys.count > 96 {
                // An unusually high minimum zoom must not scan billions of empty cells.
                selected.formUnion(available.filter { $0.zoom == z && xs.contains($0.x) && ys.contains($0.y) }.sorted().prefix(96))
                continue
            }
            for y in ys {
                for x in xs {
                    let page = WorldAtlasPage(zoom: z, x: x, y: y)
                    if available.contains(page) { selected.insert(page) }
                }
            }
        }
        // A malformed minZoom with thousands of visible pages must not defeat the budget.
        return Array(selected.sorted().prefix(96))
    }
}

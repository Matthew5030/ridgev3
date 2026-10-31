import Foundation

/// Immutable starter maps use the same identities and indexed packs as later
/// Apple downloads. Cached updates take precedence; bundled files are never
/// copied into, pruned from, or removed with the download cache.
final class WorldBundledMaps: @unchecked Sendable {
    struct Section: Decodable {
        let metadataPath: String
        let metadataSHA256: String
        let packPath: String
        let pack: WorldMapAsset
    }
    struct IncludedRegion: Decodable { let id:String; let name:String }
    struct Index: Decodable {
        let includedRegions:[IncludedRegion]
        let schemaVersion: Int
        let catalogSHA256: String
        let sections: [String: Section]
        let coverage: [GeoBounds]
    }
    static var downloadsEnabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "RidgeAppleDownloadsEnabled") as? Bool ?? (included == nil)
    }
    static let included: WorldBundledMaps? = {
        let url = Bundle.main.url(forResource: "OfflineMaps", withExtension: "bundle")
            ?? Bundle.main.bundleURL.appendingPathComponent("OfflineMaps.bundle")
        return try? WorldBundledMaps(root: url)
    }()
    let root: URL
    let index: Index
    let catalog: WorldCatalog
    let catalogData: Data
    init(root: URL) throws {
        self.root = root
        let data = try Data(contentsOf: root.appendingPathComponent("index.json"))
        guard data.count < 24_000_000 else { throw RidgeError.message("Included map index is too large.") }
        index = try JSONDecoder().decode(Index.self, from: data)
        catalogData = try Data(contentsOf: root.appendingPathComponent("catalog.json"))
        guard index.schemaVersion == 1, index.sections.count <= 1000,
              AdaptiveTerrainCodec.hash(catalogData) == index.catalogSHA256,
              index.coverage.allSatisfy(\.isValid) else { throw RidgeError.message("Included maps failed verification.") }
        catalog = try JSONDecoder().decode(WorldCatalog.self, from: catalogData)
        try catalog.validate()
        guard Set(catalog.sources.map(\.id)) == Set(index.sections.keys) else { throw RidgeError.message("Included map catalogue does not match its files.") }
        for region in catalog.sources {
            guard let section = index.sections[region.id],
                  section.metadataPath == "sources/\(region.id)/world.json",
                  section.packPath == "sources/\(region.id)/\(section.pack.file)",
                  section.pack.sha256 == region.pack?.sha256,
                  section.pack.byteCount == region.pack?.byteCount,
                  WorldSectionPack.valid(section.pack),
                  (try root.appendingPathComponent(section.packPath).resourceValues(forKeys: [.fileSizeKey])).fileSize == section.pack.byteCount else {
                throw RidgeError.message("An included map section is missing or invalid.")
            }
        }
    }
    func metadata(id: String) throws -> Data {
        guard let section = index.sections[id] else { throw RidgeError.message("This area is not included in this version of Ridge.") }
        let data = try Data(contentsOf: root.appendingPathComponent(section.metadataPath))
        guard data.count < 16_000_000, AdaptiveTerrainCodec.hash(data) == section.metadataSHA256 else {
            throw RidgeError.message("An included map index is damaged. Reinstall Ridge to restore its included maps.")
        }
        return data
    }
    func reader(id: String) -> WorldSectionPack.Reader? {
        guard let section = index.sections[id] else { return nil }
        return try? WorldSectionPack.Reader(url: root.appendingPathComponent(section.packPath), asset: section.pack, sourceID: id)
    }
    func contains(_ regions: [WorldCatalog.Region]) -> Bool {
        !regions.isEmpty && regions.allSatisfy { region in
            guard let section = index.sections[region.id] else { return false }
            return section.pack.sha256 == region.pack?.sha256 && section.pack.byteCount == region.pack?.byteCount
        }
    }
}

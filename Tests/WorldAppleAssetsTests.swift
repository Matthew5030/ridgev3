import Foundation
import Security

actor AppleFixtureBackend: WorldAppleAssetBackend {
    let root: URL
    var ready=Set<String>()
    var requests=[String]()
    var overrides=[String:Data]()
    var blocked: String?
    init(_ root:URL) { self.root=root }
    func override(_ path:String,_ data:Data) { overrides[path]=data }
    func block(_ pack:String) { blocked=pack }
    func data(path:String,pack:String) async throws -> Data {
        guard ready.contains(pack) else { throw RidgeError.message("Read before pack was available") }
        return try overrides[path] ?? Data(contentsOf:root.appendingPathComponent("\(pack)/Contents/\(path)"))
    }
    func ensure(pack:String,progress:@escaping @Sendable(Int64) async -> Void) async throws -> Int64 {
        try Task.checkCancellation()
        requests.append(pack)
        if ready.contains(pack) { return 0 }
        if blocked==pack { try await Task.sleep(nanoseconds:30_000_000_000) }
        let bytes=try await size(pack:pack)
        await progress(bytes/2); try Task.checkCancellation()
        ready.insert(pack); await progress(bytes); return bytes
    }
    func available(pack:String) async -> Bool { ready.contains(pack) }
    func size(pack:String) async throws -> Int64 { 30_000_000 }
    func seen() -> [String] { requests }
}
actor AppleProgress {
    var values=[Int64]()
    func record(_ n:Int64) { values.append(n) }
    func monotonic() -> Bool { zip(values,values.dropFirst()).allSatisfy { $0 <= $1 } }
}

@main struct WorldAppleAssetsTests {
    static func main() async throws {
        // Each fixture owns its key. Reusing a prior unsigned executable's
        // Keychain item can wait for an unrelated access prompt on the Mac.
        let fixtureID="apple-fixture-"+UUID().uuidString
        UserDefaults.standard.set(fixtureID,forKey:"ridge.protectedInstallationID.v1")
        defer {
            let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,
                kSecAttrService as String:"com.bilellaworks.ridge.protected-downloads",
                kSecAttrAccount as String:"content-key-v1:"+fixtureID]
            SecItemDelete(query as CFDictionary)
        }
        var checks=0
        func check(_ value:Bool,_ message:String) throws {
            guard value else { throw RidgeError.message(message) }
            checks+=1;print("PASS: \(message)");fflush(stdout)
        }
        let root=URL(fileURLWithPath:CommandLine.arguments[1])
        let cache=FileManager.default.temporaryDirectory.appendingPathComponent("ridge-apple-test-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:cache) }
        let backend=AppleFixtureBackend(root),provider=WorldAppleAssets(backend:backend)
        let catalog=try JSONDecoder().decode(WorldCatalog.self,from:await provider.catalogData())
        let entry=catalog.sources[0],id=entry.id
        try check(await backend.seen()==[WorldAppleAssets.libraryPack],"Opening the library fetches only the essential catalogue")
        let url=WorldAppleAssets.root.appendingPathComponent(entry.path)
        let metadata=try await provider.sourceData(url)
        let source=try JSONDecoder().decode(WorldSource.self,from:metadata)
        let seen=await backend.seen()
        try check(seen.contains(where: { $0.contains("metadata") }) && !seen.contains(where: { $0.contains("terrain") }),"Preview metadata never downloads terrain")
        let estimate=try await provider.downloadBytes(sections:[id,id])
        try check(estimate==30_000_000,"Repeated sections count a geographic download once")
        let progress=AppleProgress()
        let bytes=try await provider.ensureTerrain(sections:[id,id]) { await progress.record($0) }
        let monotonic=await progress.monotonic()
        try check(bytes==estimate && monotonic,"Native download progress is monotonic and deduplicated")
        try check(try await provider.downloadBytes(sections:[id])==0,"Available Apple packs require no further network bytes")
        try await provider.prepareSection(id:id,cache:cache)
        let pack=entry.pack!,final=WorldSectionPack.file(pack,cache:cache)
        try check(ProtectedMapStorage.isEncrypted(final),"Imported section cache is encrypted")
        let reader=try WorldSectionPack.Reader(url:final,asset:pack,sourceID:id)
        try reader.verify()
        let graph=try reader.read(source.graph)
        try check(AdaptiveTerrainCodec.hash(graph)==entry.routing?.sha256,"Imported section contains the current walking graph")
        let overview=try reader.read(source.overview)
        try check(AdaptiveTerrainCodec.hash(overview)==source.overview.sha256,"Offline assets are verified directly from the installed section")
        let before=await backend.seen().count
        try await provider.prepareSection(id:id,cache:cache)
        try check(await backend.seen().count==before,"Saved sections reopen without accessing Apple")
        try check(!WorldAppleAssets.handles(URL(string:"https://apple-maps.ridge.invalid/world/?token=bad")!),"Internal identifiers reject query-string tampering")
        do { _=try await provider.sourceData(WorldAppleAssets.root.appendingPathComponent("sources/unknown/world.json"));throw RidgeError.message("Accepted unknown section") }
        catch { try check(error.localizedDescription != "Accepted unknown section","Unknown sections are rejected") }
        let libraryPath="RidgeMaps/library.json"
        let library=try Data(contentsOf:root.appendingPathComponent("\(WorldAppleAssets.libraryPack)/Contents/\(libraryPath)"))
        let index=try JSONDecoder().decode(WorldAppleAssetIndex.self,from:library)
        let section=index.sections[id]!
        let corruptBackend=AppleFixtureBackend(root)
        var broken=try Data(contentsOf:root.appendingPathComponent("\(section.terrainPack)/Contents/\(section.packPath)"));broken[broken.count-1] ^= 1
        await corruptBackend.override(section.packPath,broken)
        let corrupt=WorldAppleAssets(backend:corruptBackend),badCache=cache.appendingPathComponent("corrupt")
        do { try await corrupt.prepareSection(id:id,cache:badCache);throw RidgeError.message("Accepted corrupt terrain") }
        catch { try check(error.localizedDescription.contains("checksum"),"Corrupt terrain fails before installation") }
        try check(WorldSectionPack.open(sourceID:id,cache:badCache)==nil && !FileManager.default.fileExists(atPath:WorldSectionPack.partial(pack,cache:badCache).path),"A failed import leaves no installed section or partial file")
        var badIndex=try JSONSerialization.jsonObject(with:library) as! [String:Any]
        var sections=badIndex["sections"] as! [String:[String:Any]]
        sections[id]!["packPath"]="../outside.ridgepack";badIndex["sections"]=sections
        let invalidBackend=AppleFixtureBackend(root)
        await invalidBackend.override(libraryPath,try JSONSerialization.data(withJSONObject:badIndex))
        do { _=try await WorldAppleAssets(backend:invalidBackend).catalogData();throw RidgeError.message("Accepted traversal") }
        catch { try check(error.localizedDescription != "Accepted traversal","Library traversal paths are rejected") }
        let cancelBackend=AppleFixtureBackend(root)
        await cancelBackend.block(section.terrainPack)
        let cancelProvider=WorldAppleAssets(backend:cancelBackend),cancelCache=cache.appendingPathComponent("cancel")
        let operation=Task { try await cancelProvider.prepareSection(id:id,cache:cancelCache) }
        while !(await cancelBackend.seen()).contains(section.terrainPack) { await Task.yield() }
        operation.cancel()
        do { try await operation.value;throw RidgeError.message("Cancelled import completed") }
        catch is CancellationError { try check(true,"Cancellation reaches the native download wait") }
        try check(WorldSectionPack.open(sourceID:id,cache:cancelCache)==nil,"Cancellation never installs unfinished terrain")
        print("PASS \(checks) Apple map delivery checks")
    }
}

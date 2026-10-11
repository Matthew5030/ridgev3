#if DEBUG
import Foundation

/// Opt-in physical-device comparison. Uses isolated temporary caches and never
/// changes the user's saved maps. Launch with RIDGE_BENCHMARK_PACK=<source ID>.
enum WorldPackDiagnostics {
    static func run(sourceID:String) async {
        let cache=FileManager.default.temporaryDirectory.appendingPathComponent("pack-benchmark-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:cache) }
        let report=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("pack-benchmark.json")
        var result:[String:String]=["state":"running","source":sourceID]
        func save() { if let data=try? JSONEncoder().encode(result) { try? data.write(to:report,options:.atomic) } }
        save()
        do {
            let root=try WorldLibrary.root(mode:"local",local:UserDefaults.standard.string(forKey:"ridge.localMapServer") ?? WorldLibrary.defaultLocalServer)
            let catalog=try await WorldCatalogStore(cacheURL:cache).open(root:root)
            guard let region=catalog.sources.first(where: { $0.id==sourceID }),let pack=region.pack else { throw RidgeError.message("Pilot pack unavailable") }
            for bundled in [false,true] {
                let directory=cache.appendingPathComponent(bundled ? "packed" : "loose")
                let files=WorldSourceStore(cacheURL:directory)
                let address=root.appendingPathComponent(region.path).absoluteString
                let source=try await files.manifest(address:address,routing:region.routing,recoverCoverage:false)
                let start=Date()
                if bundled {
                    let bytes=try await files.downloadPack(pack,source:source,assetProgress:{ _,_ in },progress:{ _ in })
                    result["packedBytes"]=String(bytes)
                } else {
                    try await files.pin(source.tiles,source:source,countCachedInProgress:false,coverageID:source.id,progress:{ _ in })
                    result["looseBytes"]=String(WorldSourceStore.assets(tiles:source.tiles,source:source).reduce(0) { $0+$1.byteCount })
                }
                result[bundled ? "packedSeconds" : "looseSeconds"]=String(Date().timeIntervalSince(start))
                let offline=WorldSourceStore(cacheURL:directory,allowsNetwork:false)
                let reopened=try await offline.manifest(address:address,routing:region.routing,preferCached:true)
                _=try await offline.contents(of:reopened)
                let tile=reopened.tiles[0]
                _=try await offline.prepare(tile,request:.init(id:tile.id,pixels:128,fine:true),sourceBounds:reopened.bounds)
                result[bundled ? "packedOffline" : "looseOffline"]="passed"
                save()
            }
            result["state"]="complete"
        } catch { result["state"]="failed";result["error"]=String(describing:error) }
        save()
    }
}
#endif

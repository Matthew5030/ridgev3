#if DEBUG
import Foundation
import CryptoKit
import UIKit

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
            let root=try WorldLibrary.root(mode:"local",local:ProcessInfo.processInfo.environment["RIDGE_BENCHMARK_SERVER"] ?? UserDefaults.standard.string(forKey:"ridge.localMapServer") ?? WorldLibrary.defaultLocalServer)
            let catalog=try await WorldCatalogStore(cacheURL:cache).open(root:root)
            guard let region=catalog.sources.first(where: { $0.id==sourceID }),let pack=region.pack else { throw RidgeError.message("Pilot pack unavailable") }
            for bundled in (WorldProtectedAccess.protected(root) ? [true] : [false,true]) {
                let directory=cache.appendingPathComponent(bundled ? "packed" : "loose")
                let files=WorldSourceStore(cacheURL:directory)
                let address=root.appendingPathComponent(region.path).absoluteString
                let source=try await files.manifest(address:address,routing:region.routing,recoverCoverage:false)
                let start=Date()
                if bundled {
                    let bytes=try await files.downloadPack(pack,source:source,assetProgress:{ _,_ in },progress:{ _ in })
                    result["packedBytes"]=String(bytes)
                    if WorldProtectedAccess.protected(root) {
                        let file=WorldSectionPack.file(pack,cache:directory)
                        guard ProtectedMapStorage.isEncrypted(file) else { throw RidgeError.message("Downloaded pack was not encrypted.") }
                        result["packedEncrypted"]="passed"
                        var rejected=false
                        do { let wrong=try ProtectedMapStorage.Reader(url:file,masterKey:SymmetricKey(size:.bits256));defer { try? wrong.close() };_=try wrong.read(upToCount:16) } catch { rejected=true }
                        guard rejected else { throw RidgeError.message("Another device key could open this pack.") }
                        result["wrongDeviceKeyRejected"]="passed"
                    }
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
    @MainActor static func runRegion(id:String) async {
        let idle=UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled=true
        defer { UIApplication.shared.isIdleTimerDisabled=idle }
        let cache=FileManager.default.temporaryDirectory.appendingPathComponent("region-benchmark-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:cache) }
        let report=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("region-benchmark.json")
        var result:[String:String]=["state":"running","region":id,"phase":"catalogue"]
        func save() { if let data=try? JSONEncoder().encode(result) { try? data.write(to:report,options:.atomic) } }
        save()
        do {
            let root=try WorldLibrary.root(mode:"local",local:ProcessInfo.processInfo.environment["RIDGE_BENCHMARK_SERVER"] ?? UserDefaults.standard.string(forKey:"ridge.localMapServer") ?? WorldLibrary.defaultLocalServer)
            let catalog=try await WorldCatalogStore(cacheURL:cache).open(root:root)
            let library=try WorldRegionPack.loadLibrary()
            guard let region=(library.areas+library.parks).first(where: { $0.id==id }),
                  let candidate=WorldRegionDownloadPlan.estimate(pack:region,catalog:catalog,root:root),candidate.archive != nil else {
                throw RidgeError.message("Region pilot unavailable")
            }
            for bundled in [false,true] {
                let label=bundled ? "region" : "sections"
                let directory=cache.appendingPathComponent(label)
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                let store=WorldRegionDownloadStore(cacheURL:directory)
                var plan=candidate
                if !bundled { plan.archive=nil }
                result["phase"]=label+" download";save()
                let start=Date()
                try await store.download(plan,progress:{ _,_ in })
                result[label+"Seconds"]=String(Date().timeIntervalSince(start))
                result[label+"Bytes"]=String(bundled ? candidate.archive!.asset.byteCount : candidate.parts.reduce(0) { $0+($1.region.pack?.byteCount ?? 0) })
                result["phase"]=label+" offline verification";save()
                let offlineStart=Date()
                for (index,part) in plan.parts.enumerated() {
                    result["phase"]=label+" offline section \(index+1)/\(plan.parts.count)";save()
                    let files=WorldSourceStore(cacheURL:directory,allowsNetwork:false)
                    let source=try await files.manifest(address:root.appendingPathComponent(part.region.path).absoluteString,routing:part.region.routing,preferCached:true)
                    _=try await files.contents(of:source,includeGraph:part.region.id==plan.parts[0].region.id)
                    // Native integration tests render samples in every section.
                    // On-device checks sample the start, middle and far end of
                    // a large park while reopening every section with no network.
                    if plan.parts.count<=19 || [0,plan.parts.count/2,plan.parts.count-1].contains(index) {
                        for tile in [source.tiles.first!,source.tiles.last!] {
                            _=try await files.prepare(tile,request:.init(id:tile.id,pixels:32,fine:true),sourceBounds:source.bounds)
                        }
                    }
                }
                guard WorldOfflineCoverage.savedBounds(at:directory).count==candidate.tileCount else { throw RidgeError.message("Offline coverage mismatch") }
                result[label+"OfflineSeconds"]=String(Date().timeIntervalSince(offlineStart))
                result[label+"Offline"]="passed";save()
            }
            result["tiles"]=String(candidate.tileCount);result["sections"]=String(candidate.parts.count)
            result["state"]="complete";result["phase"]="complete"
        } catch { result["state"]="failed";result["error"]=String(describing:error) }
        save()
    }

}
#endif

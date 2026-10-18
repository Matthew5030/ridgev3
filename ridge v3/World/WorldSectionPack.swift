import Foundation
import CryptoKit

/// A section stays as one indexed file on disk. Entries retain their original
/// hashes and compression, so the terrain/vector decoders do not change.
enum WorldSectionPack {
    struct Entry:Codable,Sendable {
        let sha256:String
        let byteCount:Int
        let offset:Int
        let storedByteCount:Int
        let compressed:Bool
    }
    struct Index:Codable { let schemaVersion:Int;let sourceID:String;let entries:[Entry] }
    struct Container:Codable,Sendable { let asset:WorldMapAsset;let offset:Int }
    struct Installed:Codable { let sourceID:String;let asset:WorldMapAsset;var container:Container? = nil }
    static func validRegion(_ asset:WorldMapAsset)->Bool {
        asset.byteCount>12 && asset.byteCount<=1024*1024*1024 && asset.sha256.count==64 && asset.sha256.allSatisfy(\.isHexDigit)
            && asset.file=="region-"+asset.sha256+".ridgepack"
    }
    static func useBundle(_ pack:WorldMapAsset,missing:[WorldMapAsset])->Bool {
        let bytes=missing.reduce(Int64(0)) { $0+Int64($1.byteCount) }
        return bytes>pack.byteCount || (missing.count>=32 && Double(bytes)>=Double(pack.byteCount)*0.7)
    }
    static func remainingBytes(_ pack:WorldMapAsset,cache:URL)->Int64 {
        let saved=(try? partial(pack,cache:cache).resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0
        return Int64(pack.byteCount-(saved<=pack.byteCount ? saved : 0))
    }
    static func valid(_ asset:WorldMapAsset)->Bool {
        asset.byteCount>12 && asset.byteCount<=256*1024*1024 && asset.sha256.count==64 && asset.sha256.allSatisfy(\.isHexDigit)
            && asset.file=="section-"+asset.sha256+".ridgepack"
    }
    static func directory(_ cache:URL)->URL { cache.appendingPathComponent("section-packs",isDirectory:true) }
    static func file(_ asset:WorldMapAsset,cache:URL)->URL { directory(cache).appendingPathComponent(asset.sha256+".ridgepack") }
    static func partial(_ asset:WorldMapAsset,cache:URL)->URL { directory(cache).appendingPathComponent(asset.sha256+".partial") }
    static func reference(_ sourceID:String,cache:URL)->URL { directory(cache).appendingPathComponent(AdaptiveTerrainCodec.hash(Data(sourceID.utf8))+".json") }
    static func open(sourceID:String,cache:URL)->Reader? {
        guard let data=try? Data(contentsOf:reference(sourceID,cache:cache)),
              let installed=try? JSONDecoder().decode(Installed.self,from:data),installed.sourceID==sourceID else { return nil }
        return try? Reader(url:file(installed.container?.asset ?? installed.asset,cache:cache),asset:installed.asset,sourceID:sourceID,container:installed.container)
    }
    static func install(_ asset:WorldMapAsset,sourceID:String,cache:URL,container:Container?=nil) throws {
        let ref=Installed(sourceID:sourceID,asset:asset,container:container)
        try JSONEncoder().encode(ref).write(to:reference(sourceID,cache:cache),options:.atomic)
    }
    /// Owned by a single source actor; file reads never allocate the whole pack.
    final class Reader {
        let asset:WorldMapAsset
        let url:URL
        let entries:[String:Entry]
        let ordered:[Entry]
        let payloadOffset:Int
        let physicalAsset:WorldMapAsset
        private let start:Int
        private let partial:Bool
        private let handle:FileHandle
        private var verifiedStamp:Date?
        init(url:URL,asset:WorldMapAsset,sourceID:String,partial:Bool=false,container:Container?=nil) throws {
            guard valid(asset) else { throw RidgeError.message("Invalid section pack.") }
            let physical=container?.asset ?? asset,start=container?.offset ?? 0
            guard start>=0,start<=physical.byteCount-asset.byteCount,
                  container == nil || (validRegion(physical) && start>=12) else { throw RidgeError.message("Invalid region section range.") }
            let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
            guard partial ? size<=physical.byteCount : size==physical.byteCount else { throw RidgeError.message("Incomplete section pack.") }
            let handle=try FileHandle(forReadingFrom:url)
            do {
                try handle.seek(toOffset:UInt64(start))
                let header=try handle.read(upToCount:12) ?? Data()
                guard header.count==12,String(data:header.prefix(8),encoding:.utf8)=="RIDGEPK1" else { throw RidgeError.message("Invalid section pack header.") }
                let count=header.dropFirst(8).enumerated().reduce(0) { $0 | (Int($1.element)<<($1.offset*8)) }
                guard count>0,count<=2_000_000,count+12<asset.byteCount else { throw RidgeError.message("Invalid section pack index.") }
                let data=try handle.read(upToCount:count) ?? Data()
                guard data.count==count else { throw RidgeError.message("Incomplete section pack index.") }
                let index=try JSONDecoder().decode(Index.self,from:data)
                guard index.schemaVersion==1,index.sourceID==sourceID,index.entries.count<=1024,!index.entries.isEmpty else { throw RidgeError.message("Unsupported section pack.") }
                var end=0,hashes=Set<String>()
                for entry in index.entries {
                    guard entry.offset==end,(1...64_000_000).contains(entry.byteCount),
                          (1...64_000_000).contains(entry.storedByteCount),
                          entry.compressed || entry.storedByteCount==entry.byteCount,
                          entry.sha256.count==64,entry.sha256.allSatisfy(\.isHexDigit),hashes.insert(entry.sha256).inserted,
                          entry.storedByteCount<=asset.byteCount-12-count-end else { throw RidgeError.message("Invalid section pack entry.") }
                    end+=entry.storedByteCount
                }
                guard end+12+count==asset.byteCount else { throw RidgeError.message("Invalid section pack length.") }
                self.url=url;self.asset=asset;self.handle=handle;payloadOffset=start+12+count
                self.start=start;self.partial=partial;physicalAsset=physical
                ordered=index.entries;entries=Dictionary(uniqueKeysWithValues:index.entries.map { ($0.sha256,$0) })
            } catch { try? handle.close();throw error }
        }
        deinit { try? handle.close() }
        func contains(_ value:WorldMapAsset)->Bool { entries[value.sha256]?.byteCount==value.byteCount }
        func read(_ value:WorldMapAsset) throws -> Data {
            guard let entry=entries[value.sha256],entry.byteCount==value.byteCount else { throw RidgeError.message("Tile missing from section pack.") }
            try handle.seek(toOffset:UInt64(payloadOffset+entry.offset))
            let stored=try handle.read(upToCount:entry.storedByteCount) ?? Data()
            guard stored.count==entry.storedByteCount else { throw RidgeError.message("Incomplete section pack tile.") }
            let data=entry.compressed ? try AdaptiveTerrainCodec.inflate(stored,byteCount:entry.byteCount) : stored
            guard data.count==value.byteCount,AdaptiveTerrainCodec.hash(data)==value.sha256 else { throw RidgeError.message("A downloaded terrain pack is damaged. Download this region again to repair it.") }
            return data
        }
        func verify() throws {
            let attributes=try FileManager.default.attributesOfItem(atPath:url.path)
            let modified=attributes[.modificationDate] as? Date
            let size=(attributes[.size] as? NSNumber)?.intValue ?? 0
            guard partial ? size>=start+asset.byteCount && size<=physicalAsset.byteCount : size==physicalAsset.byteCount else { throw RidgeError.message("Incomplete section pack.") }
            if let verifiedStamp,verifiedStamp==modified { return }
            try handle.seek(toOffset:UInt64(start))
            var digest=SHA256(),count=0
            while count<asset.byteCount,let data=try handle.read(upToCount:min(1024*1024,asset.byteCount-count)),!data.isEmpty {
                try Task.checkCancellation();digest.update(data:data);count+=data.count
            }
            let hash=digest.finalize().map { String(format:"%02x",$0) }.joined()
            guard count==asset.byteCount,hash==asset.sha256 else { throw RidgeError.message("A downloaded terrain pack is damaged. Download this region again to repair it.") }
            verifiedStamp=modified
        }
    }
}

/// Streams directly into a resumable file on a serial delegate queue. UI progress
/// is consumed independently and cannot hold up the network or disk writer.
private final class WorldPackHTTP:NSObject,URLSessionDataDelegate,@unchecked Sendable {
    struct Progress:Sendable { let received:Int64;let transferred:Int64 }
    private let target:URL
    private let expected:Int64
    private let initial:Int64
    private let notify:AsyncStream<Progress>.Continuation
    private var output:FileHandle?
    private var session:URLSession?
    private var task:URLSessionDataTask?
    private var continuation:CheckedContinuation<Int64,Error>?
    private var received:Int64=0,transferred:Int64=0
    private var failure:Error?
    private var lastReport=Date.distantPast
    private let lock=NSLock()
    private var cancelled=false
    init(target:URL,expected:Int64,initial:Int64,notify:AsyncStream<Progress>.Continuation) {
        self.target=target;self.expected=expected;self.initial=initial;self.notify=notify
    }
    func start(url:URL,continuation:CheckedContinuation<Int64,Error>) {
        lock.lock();defer { lock.unlock() }
        if cancelled { notify.finish();continuation.resume(throwing:CancellationError());return }
        self.continuation=continuation
        let configuration=URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity=false
        configuration.timeoutIntervalForRequest=30
        configuration.timeoutIntervalForResource=15*60
        let queue=OperationQueue();queue.maxConcurrentOperationCount=1;queue.qualityOfService = .utility
        let session=URLSession(configuration:configuration,delegate:self,delegateQueue:queue)
        self.session=session
        var request=URLRequest(url:url,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:30)
        request.setValue("identity",forHTTPHeaderField:"Accept-Encoding")
        if initial>0 { request.setValue("bytes=\(initial)-",forHTTPHeaderField:"Range") }
        let task=session.dataTask(with:request);self.task=task;task.resume()
    }
    func cancel() {
        lock.lock();cancelled=true;let activeTask=self.task;lock.unlock();activeTask?.cancel()
    }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive response:URLResponse,completionHandler:@escaping (URLSession.ResponseDisposition)->Void) {
        do {
            guard let http=response as? HTTPURLResponse else { throw RidgeError.message("Invalid pack response.") }
            if http.statusCode==206 {
                guard initial>0,http.value(forHTTPHeaderField:"Content-Range")=="bytes \(initial)-\(expected-1)/\(expected)" else { throw RidgeError.message("The server returned an invalid resumed download.") }
                received=initial
            } else if http.statusCode==200 { received=0 }
            else { throw RidgeError.message("Pack download failed (HTTP \(http.statusCode)).") }
            guard response.expectedContentLength == -1 || response.expectedContentLength==expected-received else { throw RidgeError.message("Incorrect pack download length.") }
            if !FileManager.default.fileExists(atPath:target.path) { FileManager.default.createFile(atPath:target.path,contents:nil) }
            let output=try FileHandle(forWritingTo:target);self.output=output
            try output.truncate(atOffset:UInt64(received));try output.seek(toOffset:UInt64(received))
            notify.yield(.init(received:received,transferred:0));completionHandler(.allow)
        } catch { failure=error;completionHandler(.cancel) }
    }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive data:Data) {
        guard failure==nil else { return }
        do {
            guard Int64(data.count)<=expected-received,let output else { throw RidgeError.message("Pack download exceeded its expected size.") }
            try output.write(contentsOf:data);received+=Int64(data.count);transferred+=Int64(data.count)
            let now=Date()
            if now.timeIntervalSince(lastReport)>=0.08 || received==expected {
                lastReport=now;notify.yield(.init(received:received,transferred:transferred))
            }
        } catch { failure=error;dataTask.cancel() }
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?) {
        try? output?.close();output=nil
        notify.finish()
        if let error=failure ?? error { continuation?.resume(throwing:error) }
        else if received != expected { continuation?.resume(throwing:RidgeError.message("The pack download stopped early. Retry to continue.")) }
        else { continuation?.resume(returning:transferred) }
        continuation=nil;session.finishTasksAndInvalidate();self.session=nil
    }
    static func download(url:URL,asset:WorldMapAsset,cache:URL,progress:@escaping @Sendable (Int64,Int64) async -> Void) async throws -> Int64 {
        guard WorldSectionPack.valid(asset) || WorldSectionPack.validRegion(asset) else { throw RidgeError.message("Invalid section pack.") }
        let directory=WorldSectionPack.directory(cache)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let target=WorldSectionPack.partial(asset,cache:cache)
        let existing=Int64((try? target.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)
        if existing==asset.byteCount { await progress(existing,0);return 0 }
        if existing>asset.byteCount { try FileManager.default.removeItem(at:target) }
        let initial=existing>asset.byteCount ? 0 : existing
        let (stream,notifications)=AsyncStream<Progress>.makeStream(bufferingPolicy:.bufferingNewest(1))
        let delegate=WorldPackHTTP(target:target,expected:Int64(asset.byteCount),initial:initial,notify:notifications)
        let reports=Task { for await value in stream { await progress(value.received,value.transferred) } }
        do {
            let count=try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in delegate.start(url:url,continuation:continuation) }
            } onCancel: { delegate.cancel() }
            await reports.value;try Task.checkCancellation();return count
        } catch { await reports.value;throw error }
    }
}

extension WorldSectionPack {
    static func download(url:URL,asset:WorldMapAsset,cache:URL,progress:@escaping @Sendable (Int64,Int64) async -> Void) async throws -> Int64 {
        try await WorldPackHTTP.download(url:url,asset:asset,cache:cache,progress:progress)
    }
}

/// Verify complete entries as their bytes arrive, without extracting them.
/// Receipts become usable offline only after the whole pack is committed.
actor WorldPackProgress {
    private let asset:WorldMapAsset
    private let sourceID:String
    private let cache:URL
    private var reader:WorldSectionPack.Reader?
    private let container:WorldSectionPack.Container?
    private let fileOverride:URL?
    private var failure:Error?
    private var verified=Set<String>()
    init(asset:WorldMapAsset,sourceID:String,cache:URL,container:WorldSectionPack.Container?=nil,file:URL?=nil) { self.asset=asset;self.sourceID=sourceID;self.cache=cache;self.container=container;fileOverride=file }
    func update(received:Int64)->(Set<String>,Set<String>) {
        let file=fileOverride ?? WorldSectionPack.partial(asset,cache:cache)
        if reader==nil {
            reader=try? WorldSectionPack.Reader(url:file,asset:asset,sourceID:sourceID,partial:true,container:container)
        }
        guard let reader,failure==nil else { return (verified,[]) }
        var active=Set<String>()
        for entry in reader.ordered where !verified.contains(entry.sha256) {
            let start=reader.payloadOffset+entry.offset
            if start+entry.storedByteCount<=received {
                do {
                    _=try reader.read(.init(file:"packed",byteCount:entry.byteCount,sha256:entry.sha256))
                    verified.insert(entry.sha256)
                } catch { failure=error;break }
            } else if start<received { active.insert(entry.sha256) }
        }
        return (verified,active)
    }
    func finish(required:[WorldMapAsset]) throws {
        if let failure { throw failure }
        guard let reader,required.allSatisfy({ reader.contains($0) && verified.contains($0.sha256) }) else {
            throw RidgeError.message("The section pack is missing required map data.")
        }
        try reader.verify()
    }
}

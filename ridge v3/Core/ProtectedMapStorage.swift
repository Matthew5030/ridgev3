import Foundation
import CryptoKit
import Security

/// Keys are generated per installation and never included in a pack, bundle,
/// preference, backup or server request. ThisDeviceOnly prevents migration.
enum RidgeDeviceSecrets {
    enum Failure:Error { case keychain(OSStatus),invalidFile }
    private static let lock=NSLock()
    static let installationID:String = {
        let defaults=UserDefaults.standard,name="ridge.protectedInstallationID.v1"
        if let saved=defaults.string(forKey:name) { return saved }
        let value=UUID().uuidString;defaults.set(value,forKey:name);return value
    }()
    static func load(_ account:String) throws -> Data? {
        let q:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"com.bilellaworks.ridge.protected-downloads",kSecAttrAccount as String:account,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var value:CFTypeRef?;let status=SecItemCopyMatching(q as CFDictionary,&value)
        if status==errSecItemNotFound { return nil }
        guard status==errSecSuccess,let data=value as? Data else { throw Failure.keychain(status) };return data
    }
    static func store(_ data:Data,account:String) throws {
        let q:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"com.bilellaworks.ridge.protected-downloads",kSecAttrAccount as String:account]
        let attributes:[String:Any]=[kSecValueData as String:data,kSecAttrAccessible as String:kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status=SecItemUpdate(q as CFDictionary,attributes as CFDictionary)
        if status==errSecItemNotFound {
            var add=q;attributes.forEach { add[$0.key]=$0.value };let result=SecItemAdd(add as CFDictionary,nil)
            guard result==errSecSuccess else { throw Failure.keychain(result) }
        } else if status != errSecSuccess { throw Failure.keychain(status) }
    }
    static func contentKey() throws -> SymmetricKey {
        lock.lock();defer { lock.unlock() }
        let account="content-key-v1:"+installationID
        if let saved=try load(account) { guard saved.count==32 else { throw Failure.invalidFile };return SymmetricKey(data:saved) }
        let key=SymmetricKey(size:.bits256),data=key.withUnsafeBytes { Data($0) }
        try store(data,account:account);return key
    }
}

/// Random-access AES-GCM records. Each record authenticates the immutable
/// header and its index, preventing swaps, truncation masquerading as completion,
/// and reordering. Incomplete records are never counted as resumable bytes.
enum ProtectedMapStorage {
    static let chunk=65536,headerSize=36,overhead=28
    static let magic=Data("RIDGEC01".utf8)
    enum Failure:LocalizedError {
        case invalid,locked
        var errorDescription:String? { "This protected map cannot be opened. Unlock this device, or download the map again." }
    }
    private static func number(_ n:UInt64,count:Int)->Data { Data((0..<count).map { UInt8(truncatingIfNeeded:n>>($0*8)) }) }
    private static func number(_ bytes:Data)->UInt64 { bytes.enumerated().reduce(0) { $0 | (UInt64($1.element)<<($1.offset*8)) } }
    private static func key(_ master:SymmetricKey,header:Data)->SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial:master,salt:header.suffix(16),info:Data("Ridge cached map v1".utf8),outputByteCount:32)
    }
    static func isEncrypted(_ url:URL)->Bool {
        guard let h=try? FileHandle(forReadingFrom:url) else { return false };defer { try? h.close() };return (try? h.read(upToCount:8))==magic
    }
    static func expectedSize(_ url:URL) throws -> Int { let r=try Reader(url:url);defer { try? r.close() };return try r.expectedSize }
    static func migrateCache(at root:URL) throws {
        let folders=[root,root.appendingPathComponent("section-packs",isDirectory:true)]
        for folder in folders {
            let files=(try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:[.isRegularFileKey])) ?? []
            for file in files {
                let stem=file.deletingPathExtension().lastPathComponent
                guard stem.count==64,stem.allSatisfy(\.isHexDigit),
                      (folder==root ? file.pathExtension.isEmpty : ["ridgepack","partial"].contains(file.pathExtension)),
                      (try file.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey]).isRegularFile)==true,
                      ((try file.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)>0 else { continue }
                try protect(file)
            }
        }
    }
    static func logicalSize(_ url:URL) throws -> Int { let r=try Reader(url:url);defer { try? r.close() };return try r.size }
    static func read(_ url:URL) throws -> Data {
        let r=try Reader(url:url);defer { try? r.close() };guard try r.size<=64_000_000 else { throw Failure.invalid };return try r.read(upToCount:r.size) ?? Data()
    }
    static func write(_ data:Data,to url:URL) throws {
        let temporary=url.deletingLastPathComponent().appendingPathComponent(".protected-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let w=try Writer(url:temporary,expected:data.count,encrypt:true);try w.write(contentsOf:data);try w.finish();try w.close()
        if FileManager.default.fileExists(atPath:url.path) { _=try FileManager.default.replaceItemAt(url,withItemAt:temporary) }
        else { try FileManager.default.moveItem(at:temporary,to:url) }
    }
    static func protect(_ url:URL) throws {
        guard !isEncrypted(url) else { return }
        let h=try FileHandle(forReadingFrom:url);defer { try? h.close() }
        let total=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        let temporary=url.deletingLastPathComponent().appendingPathComponent(".protected-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let w=try Writer(url:temporary,expected:total,encrypt:true)
        while let data=try h.read(upToCount:chunk),!data.isEmpty { try Task.checkCancellation();try w.write(contentsOf:data) }
        try w.finish();try w.close();_=try FileManager.default.replaceItemAt(url,withItemAt:temporary)
    }
    final class Reader {
        private let handle:FileHandle
        private let header:Data
        private let key:SymmetricKey?
        private let expected:Int
        private var offset=0
        var expectedSize:Int { get throws { if key != nil { return expected };return try size } }
        var size:Int {
            get throws {
                let physical=Int(try handle.seekToEnd())
                if key==nil { return physical }
                let payload=max(0,physical-headerSize),full=payload/(chunk+overhead),tail=payload%(chunk+overhead)
                let available=full*chunk+max(0,tail-overhead)
                guard available<=expected,tail==0 || (available==expected && tail>overhead) else { throw Failure.invalid }
                return available
            }
        }
        init(url:URL,masterKey:SymmetricKey?=nil) throws {
            handle=try FileHandle(forReadingFrom:url)
            do {
                let prefix=try handle.read(upToCount:headerSize) ?? Data()
                if prefix.prefix(8)==magic {
                    guard prefix.count==headerSize,number(prefix.subdata(in:8..<12))==UInt64(chunk) else { throw Failure.invalid }
                    let length=number(prefix.subdata(in:12..<20));guard length>0,length<=1073741824 else { throw Failure.invalid }
                    header=prefix;expected=Int(length);key=ProtectedMapStorage.key(try masterKey ?? RidgeDeviceSecrets.contentKey(),header:prefix)
                } else { header=Data();expected=0;key=nil }
            }catch { try? handle.close();throw error }
        }
        func seek(toOffset n:UInt64) throws { guard n<=UInt64(Int.max) else { throw Failure.invalid };offset=Int(n) }
        func read(upToCount n:Int) throws -> Data? {
            guard n>=0,n<=64_000_000 else { throw Failure.invalid }
            guard let key else { try handle.seek(toOffset:UInt64(offset));let data=try handle.read(upToCount:n);offset+=data?.count ?? 0;return data }
            let available=try size;var result=Data();let end=min(available,offset+n)
            while offset<end {
                let index=offset/chunk,within=offset%chunk,plainCount=min(chunk,expected-index*chunk)
                try handle.seek(toOffset:UInt64(headerSize+index*(chunk+overhead)))
                let raw=try handle.read(upToCount:plainCount+overhead) ?? Data()
                guard raw.count==plainCount+overhead else { throw Failure.invalid }
                let sealed=try AES.GCM.SealedBox(combined:raw)
                let plain=try AES.GCM.open(sealed,using:key,authenticating:header+number(UInt64(index),count:8))
                let count=min(end-offset,plain.count-within);guard count>0 else { throw Failure.invalid }
                result.append(plain.subdata(in:within..<(within+count)));offset+=count
            }
            return result
        }
        func close() throws { try handle.close() }
    }
    final class Writer {
        private let handle:FileHandle
        private let expected:Int
        private let header:Data
        private let key:SymmetricKey?
        private var pending=Data()
        private(set) var committedLength:Int
        init(url:URL,expected:Int,encrypt:Bool,initial:Int=0,masterKey:SymmetricKey?=nil) throws {
            guard expected>0,expected<=1073741824,initial>=0,initial<=expected else { throw Failure.invalid }
            self.expected=expected;committedLength=initial
            if !FileManager.default.fileExists(atPath:url.path) { FileManager.default.createFile(atPath:url.path,contents:nil,attributes:[.protectionKey:FileProtectionType.complete]) }
            handle=try FileHandle(forWritingTo:url)
            do {
                if encrypt {
                    let master=try masterKey ?? RidgeDeviceSecrets.contentKey()
                    if initial>0 {
                        let r=try FileHandle(forReadingFrom:url);defer { try? r.close() }
                        let saved=try r.read(upToCount:headerSize) ?? Data()
                        guard saved.count==headerSize,saved.prefix(8)==magic,number(saved.subdata(in:12..<20))==UInt64(expected),initial%chunk==0 || initial==expected else { throw Failure.invalid }
                        header=saved
                    } else { header=magic+number(UInt64(chunk),count:4)+number(UInt64(expected),count:8)+Data(AES.GCM.Nonce())+Data((0..<4).map { _ in UInt8.random(in:0...255) }) }
                    key=ProtectedMapStorage.key(master,header:header)
                    let physical=initial==0 ? 0 : headerSize+initial+((initial+chunk-1)/chunk)*overhead
                    try handle.truncate(atOffset:UInt64(physical));try handle.seek(toOffset:UInt64(physical))
                    if initial==0 { try handle.write(contentsOf:header) }
                } else { header=Data();key=nil;try handle.truncate(atOffset:UInt64(initial));try handle.seek(toOffset:UInt64(initial)) }
                var mutable=url;var values=URLResourceValues();values.isExcludedFromBackup=true;try? mutable.setResourceValues(values)
            }catch { try? handle.close();throw error }
        }
        func write(contentsOf data:Data) throws {
            guard data.count<=expected-committedLength-pending.count else { throw Failure.invalid }
            guard let key else { try handle.write(contentsOf:data);committedLength+=data.count;return }
            pending.append(data)
            while pending.count>=chunk { let block=Data(pending.prefix(chunk));try record(block,key:key);pending.removeFirst(chunk) }
            if committedLength+pending.count==expected && !pending.isEmpty { try record(pending,key:key);pending.removeAll(keepingCapacity:true) }
        }
        private func record(_ data:Data,key:SymmetricKey) throws {
            let sealed=try AES.GCM.seal(data,using:key,authenticating:header+number(UInt64(committedLength/chunk),count:8))
            guard let combined=sealed.combined else { throw Failure.invalid };try handle.write(contentsOf:combined);committedLength+=data.count
        }
        func finish() throws { guard pending.isEmpty,committedLength==expected else { throw Failure.invalid };try handle.synchronize() }
        func close() throws { try handle.close() }
        deinit { try? handle.close() }
    }
}

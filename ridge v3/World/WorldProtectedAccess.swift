import Foundation
import CryptoKit
#if os(iOS)
import DeviceCheck
#endif

/// Only these exact HTTPS services receive attestation credentials. Entered LAN
/// sources retain their existing behaviour and never receive cloud credentials.
actor WorldProtectedAccess {
    static let shared=WorldProtectedAccess()
    static let productionHost="ridge-map-downloads.bilellaworks.workers.dev"
    static let stagingHost="ridge-map-downloads-test.bilellaworks.workers.dev"
    static var root:String {
        #if DEBUG
        return "https://\(stagingHost)/world/"
        #else
        return "https://\(productionHost)/world/"
        #endif
    }
    static func protected(_ url:URL)->Bool {
        url.scheme=="https" && url.port==nil && [productionHost,stagingHost].contains(url.host?.lowercased() ?? "")
    }
    enum Failure:LocalizedError {
        case unsupported,server(Int),invalid
        var errorDescription:String? {
            switch self {
            case .unsupported:return "Protected map downloads require a supported physical Apple device. Saved maps remain available offline."
            case .server(429):return "The map download allowance has been reached. Please try again later."
            case .server(let code):return "The protected map service could not authorise this download (HTTP \(code))."
            case .invalid:return "The protected map service returned an invalid response."
            }
        }
    }
    private struct Key:Codable { let id:String;var registered:Bool }
    private struct Challenge:Decodable { let challenge:String;let payload:String }
    private struct Grant:Decodable { let token:String }
    private var keys:[String:Key]=[:]
    private let session=URLSession(configuration:.ephemeral)
    // An actor may reenter at an await. This explicit queue keeps assertion
    // counters in order across the app's concurrent map downloads.
    private var migrated=false
    private var busy=false
    private var waiting:[CheckedContinuation<Void,Never>]=[]
    private func acquire() async { if busy { await withCheckedContinuation { waiting.append($0) } } else { busy=true } }
    private func release(){if waiting.isEmpty { busy=false }else{waiting.removeFirst().resume()} }
    private func post<T:Decodable>(_ path:String,body:[String:String],origin:URL,as:T.Type) async throws -> T {
        let url=origin.appendingPathComponent(path)
        var request=URLRequest(url:url,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:30)
        request.httpMethod="POST";request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody=try JSONEncoder().encode(body)
        let (data,response)=try await session.data(for:request)
        guard response.url?.host==origin.host,let http=response as? HTTPURLResponse else { throw Failure.invalid }
        guard http.statusCode==200 else { throw Failure.server(http.statusCode) }
        guard data.count<=32768 else { throw Failure.invalid };return try JSONDecoder().decode(T.self,from:data)
    }
    func authorised(_ original:URLRequest) async throws -> URLRequest {
        guard let url=original.url,Self.protected(url) else { return original }
        await acquire();defer { release() };try Task.checkCancellation()
        #if os(iOS)
        if !migrated {
            let cache=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("WorldCache",isDirectory:true)
            try await Task.detached(priority:.utility) { try ProtectedMapStorage.migrateCache(at:cache) }.value
            migrated=true
        }
        let service=DCAppAttestService.shared
        guard service.isSupported else { throw Failure.unsupported }
        guard let origin=URL(string:"https://\(url.host!)"),url.query==nil else { throw Failure.invalid }
        let account="attest-key-v1:"+url.host!+":"+RidgeDeviceSecrets.installationID
        var key:Key
        if let cached=keys[account] { key=cached }
        else if let raw=try RidgeDeviceSecrets.load(account),let saved=try? JSONDecoder().decode(Key.self,from:raw) { key=saved }
        else { key=Key(id:try await service.generateKey(),registered:false);try RidgeDeviceSecrets.store(JSONEncoder().encode(key),account:account) }
        let descriptor=["keyId":key.id,"method":original.httpMethod ?? "GET","path":url.path,"range":original.value(forHTTPHeaderField:"Range") ?? ""]
        if !key.registered {
            var body=descriptor;body["purpose"]="attest"
            let challenge=try await post("v1/challenge",body:body,origin:origin,as:Challenge.self)
            let digest=Data(SHA256.hash(data:Data(challenge.payload.utf8)))
            let attestation=try await service.attestKey(key.id,clientDataHash:digest)
            struct Verified:Decodable { let verified:Bool }
            let verified=try await post("v1/attest",body:["keyId":key.id,"challenge":challenge.challenge,"attestation":attestation.base64EncodedString()],origin:origin,as:Verified.self)
            guard verified.verified else { throw Failure.invalid }
            key.registered=true;try RidgeDeviceSecrets.store(JSONEncoder().encode(key),account:account)
        }
        keys[account]=key
        var body=descriptor;body["purpose"]="grant"
        let challenge=try await post("v1/challenge",body:body,origin:origin,as:Challenge.self)
        let assertion=try await service.generateAssertion(key.id,clientDataHash:Data(SHA256.hash(data:Data(challenge.payload.utf8))))
        let grant=try await post("v1/grant",body:["keyId":key.id,"challenge":challenge.challenge,"assertion":assertion.base64EncodedString()],origin:origin,as:Grant.self)
        guard grant.token.count==43 else { throw Failure.invalid }
        var request=original;request.setValue("Bearer "+grant.token,forHTTPHeaderField:"Authorization")
        return request
        #else
        throw Failure.unsupported
        #endif
    }
}

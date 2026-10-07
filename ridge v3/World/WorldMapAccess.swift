import Foundation
#if os(iOS)
import DeviceCheck
import CryptoKit
#endif

/// Authentication applies only to the service origin shipped in the app. Custom
/// map sources never receive a Ridge token or an installation attestation.
enum WorldMapAccess {
    static func isProtected(_ url: URL, service: URL?) -> Bool {
        guard let service else { return false }
        return url.scheme == "https" && service.scheme == "https"
            && url.host?.lowercased() == service.host?.lowercased()
            && (url.port ?? 443) == (service.port ?? 443)
            && url.user == nil && url.password == nil
    }
    static let serviceURL: URL? = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "RidgeMapServiceURL") as? String,
              let url = URL(string: value), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { return nil }
        return url
    }()
    static func download(_ request: URLRequest) async throws -> (URL, URLResponse) {
        guard let url = request.url, isProtected(url, service: serviceURL) else {
            return try await URLSession.shared.download(for: request)
        }
        #if os(iOS)
        for attempt in 0...1 {
            let token = try await WorldMapSession.shared.token()
            var authenticated = request
            authenticated.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let result = try await WorldMapSession.transport.download(for: authenticated)
            if let http = result.1 as? HTTPURLResponse, http.statusCode == 429 {
                try? FileManager.default.removeItem(at: result.0)
                await WorldMapSession.shared.backOff(seconds: Double(http.value(forHTTPHeaderField:"Retry-After") ?? "60") ?? 60)
                throw RidgeError.message("Map downloads are busy. Please try again in a minute.")
            }
            if (result.1 as? HTTPURLResponse)?.statusCode != 401 { return result }
            try? FileManager.default.removeItem(at: result.0)
            await WorldMapSession.shared.invalidate(token)
            if attempt == 1 { throw RidgeError.message("Map access could not be verified. Please try again.") }
        }
        throw RidgeError.message("Map access could not be verified.")
        #else
        throw RidgeError.message("Protected maps require Ridge on a physical iPhone or iPad.")
        #endif
    }
}

#if os(iOS)
/// Do not forward authenticated requests to redirects, including another origin.
private final class MapRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
private actor WorldMapSession {
    struct Session: Decodable { var token: String; var expiresAt: Double }
    struct ServiceFailure: Decodable, Error { var error: String }
    struct Identity: Codable { var keyID: String; var attested: Bool }
    static let shared = WorldMapSession()
    static let transport = URLSession(configuration: .ephemeral, delegate: MapRedirectPolicy(), delegateQueue: nil)
    private var current: Session?
    private var pending: Task<Session, Error>?
    private var retryAfter = Date.distantPast
    private let attest = DCAppAttestService.shared
    private var identityStorage: String { "ridge.mapIdentity." + (WorldMapAccess.serviceURL?.host ?? "unconfigured") }
    private var identity: Identity? {
        get { UserDefaults.standard.data(forKey: identityStorage).flatMap { try? JSONDecoder().decode(Identity.self, from: $0) } }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: identityStorage) }
            else { UserDefaults.standard.removeObject(forKey: identityStorage) }
        }
    }
    func invalidate(_ failedToken: String) { if current?.token == failedToken { current = nil } }
    func backOff(seconds: Double) { retryAfter = Date().addingTimeInterval(min(300,max(60,seconds))) }
    func token() async throws -> String {
        guard Date() >= retryAfter else { throw RidgeError.message("Map downloads are busy. Please try again in a minute.") }
        if let current, current.expiresAt > Date().timeIntervalSince1970 + 45 { return current.token }
        if let pending { return try await pending.value.token }
        let operation = Task { try await self.establish() }
        pending = operation
        defer { pending = nil }
        let session = try await operation.value
        guard session.expiresAt > Date().timeIntervalSince1970, !session.token.isEmpty, session.token.count < 2048 else {
            throw RidgeError.message("The map service returned an invalid session.")
        }
        current = session
        return session.token
    }
    private func post<T: Decodable>(_ path: String, _ body: [String:String]) async throws -> T {
        guard let origin = WorldMapAccess.serviceURL else { throw RidgeError.message("The map service is not configured.") }
        var request = URLRequest(url: origin.appendingPathComponent("auth").appendingPathComponent(path))
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await Self.transport.data(for: request)
        guard data.count <= 32_768, let http = response as? HTTPURLResponse else { throw RidgeError.message("The map service could not be reached.") }
        if http.statusCode == 429 {
            backOff(seconds: Double(http.value(forHTTPHeaderField:"Retry-After") ?? "60") ?? 60)
            throw RidgeError.message("Map downloads are busy. Please try again in a minute.")
        }
        guard http.statusCode == 200 else {
            if let failure = try? JSONDecoder().decode(ServiceFailure.self, from: data) { throw failure }
            throw RidgeError.message("The map service could not be reached. Your saved maps are still available.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    private func challenge(_ key: String, purpose: String) async throws -> String {
        let value: [String:String] = try await post("challenge", ["keyId":key,"purpose":purpose])
        guard let challenge = value["challenge"], challenge.count == 43 else { throw RidgeError.message("Map verification could not start.") }
        return challenge
    }
    private func establish() async throws -> Session {
        guard attest.isSupported else { throw RidgeError.message("Protected map downloads need a physical iPhone or iPad with App Attest support. You can still use saved maps.") }
        do {
            if let existing = identity {
                do {
                    return try await existing.attested ? renew(existing.keyID) : register(existing.keyID)
                }
                catch let failure as ServiceFailure where failure.error == "registration_required" { identity = nil }
                catch let error as DCError where error.code == .invalidKey { identity = nil }
            }
            let key = try await attest.generateKey()
            identity = Identity(keyID:key,attested:false)
            return try await register(key)
        } catch let failure as ServiceFailure {
            if failure.error == "installation_blocked" { throw RidgeError.message("Map downloads are unavailable for this installation. Your saved maps are still available.") }
            throw RidgeError.message("Map access could not be verified. Please try again when you have a connection.")
        }
    }
    private func register(_ key: String) async throws -> Session {
        let nonce = try await challenge(key,purpose:"register")
        // Persist the key before contacting Apple. A temporary Apple outage must
        // retry this key, rather than generating more attestation keys.
        let proof = try await attest.attestKey(key,clientDataHash:Data(SHA256.hash(data:Data(nonce.utf8))))
        identity = Identity(keyID:key,attested:true)
        // If this response is lost, the next attempt tries an assertion first.
        // An unregistered key is replaced only after the service confirms that.
        return try await post("register",["keyId":key,"challenge":nonce,"attestation":proof.base64EncodedString()])
    }
    private func renew(_ key: String) async throws -> Session {
        let nonce = try await challenge(key,purpose:"session")
        let proof = try await attest.generateAssertion(key,clientDataHash:Data(SHA256.hash(data:Data(nonce.utf8))))
        return try await post("session",["keyId":key,"challenge":nonce,"assertion":proof.base64EncodedString()])
    }
}
#endif

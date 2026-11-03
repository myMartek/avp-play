import Foundation
import CryptoKit

// Der App-Store-Connect-Schlüssel (Team-Schlüssel, .p8) im Schlüsselbund, und das eine, wofür er gebraucht wird: die
// Headsets von Freunden im eigenen Entwicklerkonto eintragen, damit ein Ad-hoc-Bau auf ihnen läuft (docs/friends.md).
// Der Schlüssel verlässt den Mac nicht; aus ihm entstehen kurzlebige Tokens (ES256, 20 Minuten).

public struct AppStoreConnectKey: Codable, Equatable, Sendable {
    public var issuerId: String
    public var keyId: String
    public var pem: String

    public init(issuerId: String, keyId: String, pem: String) { self.issuerId = issuerId; self.keyId = keyId; self.pem = pem }

    public static let service = "avpplay-asc"

    public static func load(store: TokenStore = TokenStore(service: service)) -> AppStoreConnectKey? {
        guard let hex = try? store.read(account: "key"), let data = RemoteWire.data(hex: hex) else { return nil }
        return try? JSONDecoder().decode(AppStoreConnectKey.self, from: data)
    }

    public func save(store: TokenStore = TokenStore(service: service)) throws {
        _ = try P256.Signing.PrivateKey(pemRepresentation: pem)   // ein Schlüssel, der nicht lädt, wird nicht gespeichert
        let encoded = try JSONEncoder().encode(self)
        try store.write(token: RemoteWire.hex(encoded), account: "key")
    }

    public static func forget(store: TokenStore = TokenStore(service: service)) { _ = try? store.delete(account: "key") }

    /// Ein Token für die Connect-API, gültig `minutes` Minuten (höchstens 20).
    public func token(now: Date = Date(), minutes: Int = 20) throws -> String {
        let key = try P256.Signing.PrivateKey(pemRepresentation: pem)
        func b64url(_ d: Data) -> String {
            d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyId, "typ": "JWT"], options: [.sortedKeys])
        let iat = Int(now.timeIntervalSince1970)
        let payload = try JSONSerialization.data(withJSONObject: ["iss": issuerId, "iat": iat, "exp": iat + min(minutes, 20) * 60, "aud": "appstoreconnect-v1"], options: [.sortedKeys])
        let signing = b64url(header) + "." + b64url(payload)
        let signature = try key.signature(for: Data(signing.utf8))
        return signing + "." + b64url(signature.rawRepresentation)
    }
}

public enum AppStoreConnectError: Error, LocalizedError {
    case noKey
    case refused(Int, String)
    case unreachable(String)

    public var errorDescription: String? {
        switch self {
        case .noKey: return L("no App Store Connect key (Settings › Friends)", "kein App-Store-Connect-Schlüssel (Einstellungen › Freunde)")
        case .refused(let status, let detail): return L("App Store Connect refused (\(status)): \(detail)", "App Store Connect hat abgelehnt (\(status)): \(detail)")
        case .unreachable(let why): return L("App Store Connect is not reachable: \(why)", "App Store Connect ist nicht erreichbar: \(why)")
        }
    }
}

/// Geräte im Entwicklerkonto: nachsehen und eintragen.
public struct AppStoreConnect {
    public static let base = URL(string: "https://api.appstoreconnect.apple.com")!
    public let key: AppStoreConnectKey
    let session: URLSession

    public init(key: AppStoreConnectKey, session: URLSession = .shared) { self.key = key; self.session = session }

    public struct RegisteredDevice: Equatable, Sendable {
        public var id: String
        public var udid: String
        public var name: String
        public var status: String
    }

    func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) throws -> URLRequest {
        var comps = URLComponents(url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var r = URLRequest(url: comps.url!)
        r.httpMethod = method
        r.httpBody = body
        r.timeoutInterval = 60
        r.setValue("Bearer " + (try key.token()), forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }

    func send(_ r: URLRequest) async throws -> (Int, Data) {
        do {
            let (data, response) = try await session.data(for: r)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch { throw AppStoreConnectError.unreachable(error.localizedDescription) }
    }

    static func detail(_ data: Data) -> String {
        struct Errors: Decodable { struct E: Decodable { var title: String?; var detail: String?; var code: String? }; var errors: [E] }
        guard let e = try? JSONDecoder().decode(Errors.self, from: data).errors.first else { return String(data: data.prefix(200), encoding: .utf8) ?? "" }
        return [e.code, e.title, e.detail].compactMap { $0 }.joined(separator: ": ")
    }

    static func parse(_ data: Data) -> [RegisteredDevice] {
        struct List: Decodable {
            struct Item: Decodable { struct A: Decodable { var udid: String?; var name: String?; var status: String? }; var id: String; var attributes: A }
            var data: [Item]
        }
        struct One: Decodable { var data: List.Item }
        if let l = try? JSONDecoder().decode(List.self, from: data) {
            return l.data.map { RegisteredDevice(id: $0.id, udid: $0.attributes.udid ?? "", name: $0.attributes.name ?? "", status: $0.attributes.status ?? "") }
        }
        if let o = try? JSONDecoder().decode(One.self, from: data) {
            return [RegisteredDevice(id: o.data.id, udid: o.data.attributes.udid ?? "", name: o.data.attributes.name ?? "", status: o.data.attributes.status ?? "")]
        }
        return []
    }

    /// Alle Geräte des Kontos.
    public func devices() async throws -> [RegisteredDevice] {
        let (status, data) = try await send(try request("GET", "v1/devices", query: [URLQueryItem(name: "limit", value: "200")]))
        guard status == 200 else { throw AppStoreConnectError.refused(status, Self.detail(data)) }
        return Self.parse(data)
    }

    /// Trägt ein Gerät ein, wenn es fehlt. Welche Plattform Apple für eine Vision Pro erwartet, sagt die Dokumentation
    /// nicht; IOS zuerst, UNIVERSAL als zweites. Ein schon eingetragenes Gerät ist kein Fehler.
    @discardableResult
    public func register(udid: String, name: String) async throws -> RegisteredDevice {
        let udid = udid.uppercased()
        if let known = try await devices().first(where: { $0.udid.uppercased() == udid }) { return known }
        var last: (Int, String) = (0, "")
        for platform in ["IOS", "UNIVERSAL"] {
            let body = try JSONSerialization.data(withJSONObject: ["data": ["type": "devices", "attributes": ["name": String(name.prefix(50)), "platform": platform, "udid": udid]]])
            let (status, data) = try await send(try request("POST", "v1/devices", body: body))
            if status == 201, let d = Self.parse(data).first { return d }
            if status == 409, let known = try await devices().first(where: { $0.udid.uppercased() == udid }) { return known }
            last = (status, Self.detail(data))
            if status == 401 || status == 403 { break }
        }
        throw AppStoreConnectError.refused(last.0, last.1)
    }
}

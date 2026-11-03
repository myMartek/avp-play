import Foundation
import CryptoKit

// Freunde: zwei Installationen von AVP Play finden sich über den Server des Projekts, tauschen aus, was ein geteilter
// SharePlay-Bau braucht, und reichen ihn weiter. Das Protokoll steht in docs/friends.md; hier die Seite des Macs:
// die Schlüssel im Schlüsselbund, das Versiegeln (Nachrichten und Blobs), der signierte Client und der Ereignisstrom.
// Der Server sieht Freundschaften und versiegelte Daten, nie Inhalt.

/// Die Schlüssel dieser Installation: einer zum Signieren der Anfragen (Ed25519), einer, an den Freunde versiegeln
/// (Curve25519). Beide liegen als Hex im Schlüsselbund (`avpplay-friends`); die Kennung ist aus dem Signaturschlüssel.
public struct FriendIdentity: Sendable {
    public let signing: Curve25519.Signing.PrivateKey
    public let sealing: Curve25519.KeyAgreement.PrivateKey

    /// Die ersten 16 Bytes des SHA-256 des öffentlichen Signaturschlüssels, hex – was der Server als Kennung führt.
    public var id: String {
        let sum = SHA256.hash(data: signing.publicKey.rawRepresentation)
        return RemoteWire.hex(Data(sum.prefix(16)))
    }
    public var signKeyBase64: String { signing.publicKey.rawRepresentation.base64EncodedString() }
    public var boxKeyBase64: String { sealing.publicKey.rawRepresentation.base64EncodedString() }

    public static let service = "avpplay-friends"

    /// Die gespeicherten Schlüssel, oder nil, wenn diese Installation noch keine hat.
    public static func load(store: TokenStore = TokenStore(service: service)) -> FriendIdentity? {
        guard let s = try? store.read(account: "sign"), let b = try? store.read(account: "box"),
              let sd = RemoteWire.data(hex: s), let bd = RemoteWire.data(hex: b),
              let signing = try? Curve25519.Signing.PrivateKey(rawRepresentation: sd),
              let sealing = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bd) else { return nil }
        return FriendIdentity(signing: signing, sealing: sealing)
    }

    /// Neue Schlüssel, in den Schlüsselbund geschrieben. Ersetzt vorhandene: Freunde kennen diese Installation dann
    /// nicht mehr (eine neue Kennung).
    @discardableResult
    public static func create(store: TokenStore = TokenStore(service: service)) throws -> FriendIdentity {
        let identity = FriendIdentity(signing: Curve25519.Signing.PrivateKey(), sealing: Curve25519.KeyAgreement.PrivateKey())
        try store.write(token: RemoteWire.hex(identity.signing.rawRepresentation), account: "sign")
        try store.write(token: RemoteWire.hex(identity.sealing.rawRepresentation), account: "box")
        return identity
    }

    /// Die Signatur einer Anfrage: über `<ts>\n<METHOD>\n<path>\n<sha256 des Bodys, hex>`.
    public func signature(ts: String, method: String, path: String, bodyHash: String) throws -> String {
        let message = Data("\(ts)\n\(method)\n\(path)\n\(bodyHash)".utf8)
        return try signing.signature(for: message).base64EncodedString()
    }
}

/// Versiegeln an den öffentlichen Schlüssel eines Freundes (eine „sealed box“): flüchtiger Schlüssel, Vereinbarung,
/// HKDF-SHA256 (Salz = Schlüssel des Empfängers, Info `avpplay-friends-v1`), ChaChaPoly.
/// Format: flüchtiger öffentlicher Schlüssel (32) || Nonce (12) || Chiffrat || Tag (16).
public enum FriendSealed {
    static let info = Data("avpplay-friends-v1".utf8)

    public static func seal(_ plain: Data, to boxKey: Data) throws -> Data {
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: boxKey)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: boxKey, sharedInfo: info, outputByteCount: 32)
        let nonce = ChaChaPoly.Nonce()
        let box = try ChaChaPoly.seal(plain, using: key, nonce: nonce)
        return ephemeral.publicKey.rawRepresentation + Data(nonce) + box.ciphertext + box.tag
    }

    public static func open(_ sealed: Data, with sealing: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
        guard sealed.count >= 32 + 12 + 16 else { throw FriendError.malformed }
        let ephemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: sealed.prefix(32))
        let shared = try sealing.sharedSecretFromKeyAgreement(with: ephemeral)
        let mine = sealing.publicKey.rawRepresentation
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: mine, sharedInfo: info, outputByteCount: 32)
        let nonce = try ChaChaPoly.Nonce(data: sealed[sealed.startIndex + 32 ..< sealed.startIndex + 44])
        let rest = sealed.suffix(from: sealed.startIndex + 44)
        let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: rest.dropLast(16), tag: rest.suffix(16))
        return try ChaChaPoly.open(box, using: key)
    }
}

/// Ein Blob (die .ipa) versiegelt in Stücken von 8 MiB mit einem zufälligen Schlüssel, der nur im Angebot reist:
/// Kopf `AVPB` + Version (1) + Stückgröße (4, big-endian) + 7 Bytes Null = 16; je Stück Nonce (12) || Chiffrat || Tag (16).
/// Die Nonce ist der Index des Stücks – jedes anders, keins doppelt.
public enum FriendBlobCipher {
    public static let chunk = 8 << 20
    static let magic = Data("AVPB".utf8)

    public static func newKey() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }

    static func nonce(_ index: UInt64) throws -> ChaChaPoly.Nonce {
        var n = Data(count: 12)
        var be = index.bigEndian
        withUnsafeBytes(of: &be) { n.replaceSubrange(4..<12, with: $0) }
        return try ChaChaPoly.Nonce(data: n)
    }

    /// Versiegelt `plain` nach `sealed`; liefert den SHA-256 des Klartexts (hex), der im Angebot mitreist.
    @discardableResult
    public static func seal(file plain: URL, to sealed: URL, key: Data, progress: ((Int64) -> Void)? = nil) throws -> String {
        let symmetric = SymmetricKey(data: key)
        let input = try FileHandle(forReadingFrom: plain)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: sealed.path, contents: nil)
        let output = try FileHandle(forWritingTo: sealed)
        defer { try? output.close() }
        var header = magic
        header.append(1)
        var size = UInt32(chunk).bigEndian
        withUnsafeBytes(of: &size) { header.append(contentsOf: $0) }
        header.append(Data(count: 7))
        try output.write(contentsOf: header)
        var hasher = SHA256()
        var index: UInt64 = 0
        var done: Int64 = 0
        while true {
            let data = try input.read(upToCount: chunk) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
            let box = try ChaChaPoly.seal(data, using: symmetric, nonce: try nonce(index))
            try output.write(contentsOf: Data(box.nonce) + box.ciphertext + box.tag)
            index += 1
            done += Int64(data.count)
            progress?(done)
            if data.count < chunk { break }
        }
        return RemoteWire.hex(Data(hasher.finalize()))
    }

    /// Öffnet `sealed` nach `plain` und liefert den SHA-256 des Ergebnisses (hex), zum Vergleich mit dem Angebot.
    @discardableResult
    public static func open(file sealed: URL, to plain: URL, key: Data, progress: ((Int64) -> Void)? = nil) throws -> String {
        let symmetric = SymmetricKey(data: key)
        let input = try FileHandle(forReadingFrom: sealed)
        defer { try? input.close() }
        guard let header = try input.read(upToCount: 16), header.count == 16, header.prefix(4) == magic, header[4] == 1 else {
            throw FriendError.malformed
        }
        let size = Int(UInt32(bigEndian: header[5..<9].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
        guard size > 0, size <= 64 << 20 else { throw FriendError.malformed }
        FileManager.default.createFile(atPath: plain.path, contents: nil)
        let output = try FileHandle(forWritingTo: plain)
        defer { try? output.close() }
        var hasher = SHA256()
        var index: UInt64 = 0
        var done: Int64 = 0
        while true {
            let data = try input.read(upToCount: size + 28) ?? Data()
            if data.isEmpty { break }
            guard data.count > 28 else { throw FriendError.malformed }
            let n = try ChaChaPoly.Nonce(data: data.prefix(12))
            guard Data(n) == Data(try nonce(index)) else { throw FriendError.malformed }
            let body = data.dropFirst(12)
            let box = try ChaChaPoly.SealedBox(nonce: n, ciphertext: body.dropLast(16), tag: body.suffix(16))
            let opened = try ChaChaPoly.open(box, using: symmetric)
            hasher.update(data: opened)
            try output.write(contentsOf: opened)
            index += 1
            done += Int64(opened.count)
            progress?(done)
        }
        return RemoteWire.hex(Data(hasher.finalize()))
    }
}

public enum FriendError: Error, LocalizedError {
    case malformed
    case noIdentity
    case refused(Int, String)
    case unreachable(String)
    case unexpected

    public var errorDescription: String? {
        switch self {
        case .malformed: return L("a message that does not fit the format", "eine Nachricht, die nicht ins Format passt")
        case .noIdentity: return L("this Mac has no friend keys yet", "dieser Mac hat noch keine Freunde-Schlüssel")
        case .refused(let status, let message):
            return status == 429
                ? L("the friends service asks for a pause (too many requests)", "der Freundedienst bittet um eine Pause (zu viele Anfragen)")
                : L("the friends service refused: \(status) \(message)", "der Freundedienst hat abgelehnt: \(status) \(message)")
        case .unreachable(let why): return L("the friends service is not reachable: \(why)", "der Freundedienst ist nicht erreichbar: \(why)")
        case .unexpected: return L("an answer that was not expected", "eine Antwort, die nicht erwartet war")
        }
    }
}

// MARK: - Was zwischen Freunden gesagt wird

public struct FriendPeer: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var boxKey: String?
    public var since: Int64
    public init(id: String, name: String, boxKey: String? = nil, since: Int64 = 0) { self.id = id; self.name = name; self.boxKey = boxKey; self.since = since }
}

public struct FriendMe: Codable, Equatable, Sendable {
    public var id: String
    public var code: String
    public var name: String
    public var friends: [FriendPeer]
    public var incoming: [FriendPeer]
    public var outgoing: [FriendPeer]
    public init(id: String, code: String, name: String, friends: [FriendPeer], incoming: [FriendPeer], outgoing: [FriendPeer]) {
        self.id = id; self.code = code; self.name = name; self.friends = friends; self.incoming = incoming; self.outgoing = outgoing
    }
}

public enum FriendMessageKind: String, Codable, Sendable { case status, offer, result }

public struct FriendInboxMessage: Codable, Sendable {
    public var seq: Int64
    public var from: String
    public var kind: FriendMessageKind
    public var body: String
    public var created: Int64
}

/// Der Stand einer Installation, wie Freunde ihn brauchen.
public struct FriendStatus: Codable, Equatable, Sendable {
    public struct Game: Codable, Equatable, Sendable {
        public var owned: Bool
        public var checked: Int64
        public init(owned: Bool, checked: Int64) { self.owned = owned; self.checked = checked }
    }
    public struct Device: Codable, Equatable, Sendable {
        public var udid: String
        public var name: String
        public var os: String
        public init(udid: String, name: String, os: String) { self.udid = udid; self.name = name; self.os = os }
    }
    public var app: String
    public var games: [String: Game]
    public var device: Device?
    public var canShare: Bool
    public var sent: Int64
    public init(app: String, games: [String: Game], device: Device?, canShare: Bool, sent: Int64 = Int64(Date().timeIntervalSince1970)) {
        self.app = app; self.games = games; self.device = device; self.canShare = canShare; self.sent = sent
    }
}

/// Ein Bau für einen Freund: wo der versiegelte Blob liegt und wie er aufgeht.
public struct FriendOffer: Codable, Equatable, Sendable {
    public var game: String
    public var blob: String
    public var key: String          // base64, 32 Bytes
    public var sha256: String       // der .ipa im Klartext, hex
    public var size: Int64
    public var bundleId: String
    public var stamp: String        // CFBundleVersion des Baus (AppStamp)
    public var appVersion: String   // CFBundleShortVersionString
    public var toolchain: Int
    public var spatialPersonas: Bool
    public var note: String
    public var sent: Int64
    public var expires: Int64
    public init(game: String, blob: String, key: String, sha256: String, size: Int64, bundleId: String, stamp: String,
                appVersion: String, toolchain: Int, spatialPersonas: Bool, note: String, sent: Int64, expires: Int64) {
        self.game = game; self.blob = blob; self.key = key; self.sha256 = sha256; self.size = size; self.bundleId = bundleId
        self.stamp = stamp; self.appVersion = appVersion; self.toolchain = toolchain; self.spatialPersonas = spatialPersonas
        self.note = note; self.sent = sent; self.expires = expires
    }
}

public struct FriendResult: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case installed, declined, failed }
    public var game: String
    public var blob: String
    public var state: State
    public var detail: String
    public init(game: String, blob: String, state: State, detail: String) { self.game = game; self.blob = blob; self.state = state; self.detail = detail }
}

/// Ein Ereignis vom Server.
public struct FriendEvent: Codable, Sendable {
    public var type: String
    public var seq: Int64?
}

// MARK: - Der Client

/// Spricht mit `/api/v1/friends/…`, jede Anfrage signiert. `base` ist der Katalogserver (`CatalogClient.defaultBase`).
public final class FriendsClient: @unchecked Sendable {
    public let base: URL
    public let identity: FriendIdentity
    private let session: URLSession

    public init(base: URL = CatalogClient.defaultBase, identity: FriendIdentity, session: URLSession? = nil) {
        self.base = base
        self.identity = identity
        if let session { self.session = session } else {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 60
            c.timeoutIntervalForResource = 4 * 3600
            self.session = URLSession(configuration: c)
        }
    }

    static func hex(_ data: Data) -> String { RemoteWire.hex(Data(SHA256.hash(data: data))) }

    /// Eine signierte Anfrage. `bodyHash` ist der SHA-256 dessen, was gesendet wird – bei einer Datei vorab berechnet.
    func signed(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil, bodyHash: String? = nil,
                contentType: String? = nil) throws -> URLRequest {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var r = URLRequest(url: comps.url!)
        r.httpMethod = method
        r.httpBody = body
        let hash = bodyHash ?? Self.hex(body ?? Data())
        let ts = String(Int(Date().timeIntervalSince1970))
        r.setValue(identity.id, forHTTPHeaderField: "X-AVP-Friend")
        r.setValue(ts, forHTTPHeaderField: "X-AVP-Ts")
        r.setValue(hash, forHTTPHeaderField: "X-AVP-Body")
        r.setValue(try identity.signature(ts: ts, method: method, path: "/" + path, bodyHash: hash), forHTTPHeaderField: "X-AVP-Sig")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType { r.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        return r
    }

    func send(_ r: URLRequest, expecting: Set<Int>) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: r) } catch { throw FriendError.unreachable(error.localizedDescription) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard expecting.contains(status) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? ""
            throw FriendError.refused(status, message)
        }
        return data
    }

    func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw FriendError.unexpected }
    }

    /// Meldet die Schlüssel an (oder erneut, mit neuem Namen) und liefert Kennung und Freundescode.
    public static func register(base: URL = CatalogClient.defaultBase, identity: FriendIdentity, name: String) async throws -> (id: String, code: String) {
        var r = URLRequest(url: base.appendingPathComponent("api/v1/friends/register"))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONEncoder().encode(["signKey": identity.signKeyBase64, "boxKey": identity.boxKeyBase64, "name": name])
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await URLSession.shared.data(for: r) } catch { throw FriendError.unreachable(error.localizedDescription) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 201 else { throw FriendError.refused(status, (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "") }
        let out = try JSONDecoder().decode([String: String].self, from: data)
        guard let id = out["id"], let code = out["code"] else { throw FriendError.unexpected }
        return (id, code)
    }

    public func me() async throws -> FriendMe {
        try decode(FriendMe.self, await send(try signed("GET", "api/v1/friends/me"), expecting: [200]))
    }

    public func setName(_ name: String) async throws {
        let body = try JSONEncoder().encode(["name": name])
        _ = try await send(try signed("POST", "api/v1/friends/name", body: body, contentType: "application/json"), expecting: [204])
    }

    public func newCode() async throws -> String {
        let data = try await send(try signed("POST", "api/v1/friends/code", body: Data()), expecting: [200])
        return try decode([String: String].self, data)["code"] ?? ""
    }

    /// Bittet um Freundschaft; `friends`, wenn die Gegenseite schon gebeten hatte.
    public func request(code: String) async throws -> (state: String, id: String, name: String) {
        let body = try JSONEncoder().encode(["code": code])
        let data = try await send(try signed("POST", "api/v1/friends/requests", body: body, contentType: "application/json"), expecting: [202])
        let out = try decode([String: String].self, data)
        return (out["state"] ?? "", out["id"] ?? "", out["name"] ?? "")
    }

    public func accept(_ id: String) async throws {
        _ = try await send(try signed("POST", "api/v1/friends/requests/\(id)/accept", body: Data()), expecting: [204])
    }

    public func unlink(_ id: String) async throws {
        _ = try await send(try signed("DELETE", "api/v1/friends/\(id)"), expecting: [204])
    }

    /// Versiegelt `value` an den Freund und schickt es.
    public func send<T: Encodable>(_ value: T, kind: FriendMessageKind, to peer: FriendPeer) async throws {
        guard let key = peer.boxKey.flatMap({ Data(base64Encoded: $0) }) else { throw FriendError.malformed }
        let sealed = try FriendSealed.seal(try JSONEncoder().encode(value), to: key)
        let body = try JSONEncoder().encode(["to": peer.id, "kind": kind.rawValue, "body": sealed.base64EncodedString()])
        _ = try await send(try signed("POST", "api/v1/friends/messages", body: body, contentType: "application/json"), expecting: [202])
    }

    public func inbox(after: Int64) async throws -> [FriendInboxMessage] {
        let data = try await send(try signed("GET", "api/v1/friends/messages", query: [URLQueryItem(name: "after", value: String(after))]), expecting: [200])
        return try decode([String: [FriendInboxMessage]].self, data)["messages"] ?? []
    }

    public func ack(upTo: Int64) async throws {
        let body = try JSONEncoder().encode(["upTo": upTo])
        _ = try await send(try signed("POST", "api/v1/friends/messages/ack", body: body, contentType: "application/json"), expecting: [204])
    }

    /// Öffnet eine Nachricht – nur von einem Freund, mit dem eigenen Schlüssel.
    public func open<T: Decodable>(_ message: FriendInboxMessage, as type: T.Type) throws -> T {
        guard let sealed = Data(base64Encoded: message.body) else { throw FriendError.malformed }
        let plain = try FriendSealed.open(sealed, with: identity.sealing)
        do { return try JSONDecoder().decode(type, from: plain) } catch { throw FriendError.malformed }
    }

    /// Lädt einen versiegelten Blob hoch; liefert seine Kennung und wann er verfällt.
    public func upload(blob: URL, progress: ((Double) -> Void)? = nil) async throws -> (id: String, expires: Int64) {
        let hash = try Self.fileHash(blob)
        var r = try signed("POST", "api/v1/friends/blobs", bodyHash: hash, contentType: "application/octet-stream")
        r.timeoutInterval = 4 * 3600
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.upload(for: r, fromFile: blob) } catch { throw FriendError.unreachable(error.localizedDescription) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 201 else { throw FriendError.refused(status, (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "") }
        struct Out: Decodable { var id: String; var expires: Int64 }
        let out = try decode(Out.self, data)
        return (out.id, out.expires)
    }

    /// Lädt einen Blob in eine Datei.
    public func download(blob id: String, to file: URL) async throws {
        let r = try signed("GET", "api/v1/friends/blobs/\(id)")
        let (tmp, response): (URL, URLResponse)
        do { (tmp, response) = try await session.download(for: r) } catch { throw FriendError.unreachable(error.localizedDescription) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { try? FileManager.default.removeItem(at: tmp); throw FriendError.refused(status, "") }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: tmp, to: file)
    }

    public func deleteBlob(_ id: String) async throws {
        _ = try await send(try signed("DELETE", "api/v1/friends/blobs/\(id)"), expecting: [204, 404])
    }

    /// Der Ereignisstrom (Server-Sent Events): ruft `handler` für jedes Ereignis, bis die Verbindung endet; dann kehrt
    /// die Funktion zurück und der Aufrufer verbindet neu.
    public func events(_ handler: @Sendable (FriendEvent) async -> Void) async throws {
        var r = try signed("GET", "api/v1/friends/events")
        r.timeoutInterval = 120
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do { (bytes, response) = try await session.bytes(for: r) } catch { throw FriendError.unreachable(error.localizedDescription) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw FriendError.refused(status, "") }
        for try await line in bytes.lines {
            guard line.hasPrefix("data: "), let data = line.dropFirst(6).data(using: .utf8),
                  let event = try? JSONDecoder().decode(FriendEvent.self, from: data) else { continue }
            await handler(event)
        }
    }

    public static func fileHash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 << 20), !data.isEmpty { hasher.update(data: data) }
        return RemoteWire.hex(Data(hasher.finalize()))
    }
}

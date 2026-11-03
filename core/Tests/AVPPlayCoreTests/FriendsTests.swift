import XCTest
import CryptoKit
@testable import AVPPlayCore

final class FriendsTests: XCTestCase {
    func testASealedMessageOpensOnlyForItsRecipient() throws {
        let bob = Curve25519.KeyAgreement.PrivateKey()
        let eve = Curve25519.KeyAgreement.PrivateKey()
        let plain = Data("{\"game\":\"walkabout\"}".utf8)
        let sealed = try FriendSealed.seal(plain, to: bob.publicKey.rawRepresentation)
        XCTAssertEqual(try FriendSealed.open(sealed, with: bob), plain)
        XCTAssertThrowsError(try FriendSealed.open(sealed, with: eve))
        var tampered = sealed
        tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try FriendSealed.open(tampered, with: bob))
        XCTAssertThrowsError(try FriendSealed.open(Data(count: 10), with: bob))
    }

    func testABlobRoundTripsInChunksAndNoticesTampering() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("friends-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = dir.appendingPathComponent("a.ipa"), sealed = dir.appendingPathComponent("a.blob"), back = dir.appendingPathComponent("b.ipa")
        var bytes = Data(count: 3 * FriendBlobCipher.chunk + 12345)
        bytes.withUnsafeMutableBytes { buf in for i in 0..<buf.count { buf[i] = UInt8((i * 31) & 0xff) } }
        try bytes.write(to: plain)
        let key = FriendBlobCipher.newKey()
        let hash = try FriendBlobCipher.seal(file: plain, to: sealed, key: key)
        XCTAssertEqual(hash, try FriendsClient.fileHash(plain))
        let size = try FileManager.default.attributesOfItem(atPath: sealed.path)[.size] as! Int
        XCTAssertEqual(size, 16 + 4 * 28 + bytes.count)
        XCTAssertEqual(try FriendBlobCipher.open(file: sealed, to: back, key: key), hash)
        XCTAssertEqual(try Data(contentsOf: back), bytes)
        // Der falsche Schlüssel, ein vertauschtes Stück: beides fällt auf.
        XCTAssertThrowsError(try FriendBlobCipher.open(file: sealed, to: back, key: FriendBlobCipher.newKey()))
        var swapped = try Data(contentsOf: sealed)
        let first = 16..<(16 + FriendBlobCipher.chunk + 28), second = (16 + FriendBlobCipher.chunk + 28)..<(16 + 2 * (FriendBlobCipher.chunk + 28))
        let a = swapped[first], b = swapped[second]
        swapped.replaceSubrange(first, with: b); swapped.replaceSubrange(second, with: a)
        try swapped.write(to: sealed)
        XCTAssertThrowsError(try FriendBlobCipher.open(file: sealed, to: back, key: key))
    }

    func testTheIdentityIdAndSignatureFollowTheProtocol() throws {
        let identity = FriendIdentity(signing: Curve25519.Signing.PrivateKey(), sealing: Curve25519.KeyAgreement.PrivateKey())
        XCTAssertEqual(identity.id.count, 32)
        XCTAssertEqual(identity.id, RemoteWire.hex(Data(SHA256.hash(data: identity.signing.publicKey.rawRepresentation).prefix(16))))
        let hash = RemoteWire.hex(Data(SHA256.hash(data: Data())))
        let sig = try identity.signature(ts: "1700000000", method: "GET", path: "/api/v1/friends/me", bodyHash: hash)
        let message = Data("1700000000\nGET\n/api/v1/friends/me\n\(hash)".utf8)
        XCTAssertTrue(identity.signing.publicKey.isValidSignature(Data(base64Encoded: sig)!, for: message))
        XCTAssertFalse(identity.signing.publicKey.isValidSignature(Data(base64Encoded: sig)!, for: Data("x".utf8)))
    }

    func testAnAppStoreConnectTokenIsAnES256JWT() throws {
        let p256 = P256.Signing.PrivateKey()
        let key = AppStoreConnectKey(issuerId: "69a6de8f-0000-47e3-e053-5b8c7c11a4d1", keyId: "ABC123DEFG", pem: p256.pemRepresentation)
        let token = try key.token(now: Date(timeIntervalSince1970: 1_700_000_000))
        let parts = token.split(separator: ".")
        XCTAssertEqual(parts.count, 3)
        func json(_ s: Substring) -> [String: Any] {
            var b = String(s).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b.count % 4 != 0 { b += "=" }
            return (try? JSONSerialization.jsonObject(with: Data(base64Encoded: b)!)) as? [String: Any] ?? [:]
        }
        XCTAssertEqual(json(parts[0])["alg"] as? String, "ES256")
        XCTAssertEqual(json(parts[0])["kid"] as? String, "ABC123DEFG")
        XCTAssertEqual(json(parts[1])["aud"] as? String, "appstoreconnect-v1")
        XCTAssertEqual(json(parts[1])["exp"] as? Int, 1_700_000_000 + 1200)
        var sigB64 = String(parts[2]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while sigB64.count % 4 != 0 { sigB64 += "=" }
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: Data(base64Encoded: sigB64)!)
        XCTAssertTrue(p256.publicKey.isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8)))
        // Ein Schlüssel, der nicht lädt, wird nicht gespeichert.
        XCTAssertThrowsError(try AppStoreConnectKey(issuerId: "x", keyId: "y", pem: "nonsense").save(store: TokenStore(service: "avpplay-test-asc-\(UUID().uuidString.prefix(8))")))
    }

    func testFriendMessagesEncodeAsTheProtocolSays() throws {
        let offer = FriendOffer(game: "walkabout", blob: "ab", key: "k", sha256: "s", size: 1, bundleId: "x.walkabout", stamp: "62568.853.512",
                                appVersion: "6.8", toolchain: 853, spatialPersonas: true, note: "", sent: 1, expires: 2)
        let data = try JSONEncoder().encode(offer)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(dict?["bundleId"] as? String, "x.walkabout")
        XCTAssertEqual(try JSONDecoder().decode(FriendOffer.self, from: data), offer)
        let status = FriendStatus(app: "1.10.2", games: ["walkabout": .init(owned: true, checked: 5)], device: .init(udid: "U", name: "N", os: "26.1"), canShare: false, sent: 9)
        XCTAssertEqual(try JSONDecoder().decode(FriendStatus.self, from: JSONEncoder().encode(status)), status)
    }
}

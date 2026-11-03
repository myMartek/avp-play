import XCTest
import CryptoKit
@testable import AVPPlayCore

/// Gegen einen laufenden Freundedienst (`AVPPLAY_FRIENDS_SERVER=http://127.0.0.1:8099`): zwei Macs werden Freunde,
/// tauschen eine versiegelte Nachricht und einen Blob. Sonst übersprungen.
final class FriendsClientTests: XCTestCase {
    func testTwoInstallationsBecomeFriendsAndExchangeSealedThings() async throws {
        guard let server = ProcessInfo.processInfo.environment["AVPPLAY_FRIENDS_SERVER"], let base = URL(string: server) else {
            throw XCTSkip("AVPPLAY_FRIENDS_SERVER not set")
        }
        let alice = FriendIdentity(signing: .init(), sealing: .init())
        let bob = FriendIdentity(signing: .init(), sealing: .init())
        let a = try await FriendsClient.register(base: base, identity: alice, name: "Alice")
        let b = try await FriendsClient.register(base: base, identity: bob, name: "Bob")
        XCTAssertEqual(a.id, alice.id)
        XCTAssertEqual(b.code.count, 8)
        let ca = FriendsClient(base: base, identity: alice), cb = FriendsClient(base: base, identity: bob)

        let r = try await ca.request(code: b.code.lowercased())
        XCTAssertEqual(r.state, "pending")
        var meB = try await cb.me()
        XCTAssertEqual(meB.incoming.map(\.name), ["Alice"])
        try await cb.accept(alice.id)
        meB = try await cb.me()
        let meA = try await ca.me()
        XCTAssertEqual(meA.friends.map(\.name), ["Bob"])
        XCTAssertEqual(meB.friends.first?.boxKey, alice.boxKeyBase64)

        // Eine Nachricht, versiegelt an Bob, von Bob geöffnet.
        let status = FriendStatus(app: "1.10.2", games: ["walkabout": .init(owned: true, checked: 1)], device: .init(udid: "U1", name: "Vision Pro", os: "26.1"), canShare: true, sent: 7)
        try await ca.send(status, kind: .status, to: meA.friends[0])
        let inbox = try await cb.inbox(after: 0)
        XCTAssertEqual(inbox.count, 1)
        XCTAssertEqual(inbox[0].from, alice.id)
        XCTAssertEqual(try cb.open(inbox[0], as: FriendStatus.self), status)
        XCTAssertThrowsError(try ca.open(inbox[0], as: FriendStatus.self))   // nicht an Alice versiegelt
        try await cb.ack(upTo: inbox[0].seq)
        let after = try await cb.inbox(after: 0)
        XCTAssertEqual(after.count, 0)

        // Ein Blob: versiegelt hochgeladen, von Bob geholt und geöffnet.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("friends-client-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = dir.appendingPathComponent("game.ipa"), sealed = dir.appendingPathComponent("game.blob")
        try Data((0..<(9 << 20)).map { UInt8($0 & 0xff) }).write(to: plain)
        let key = FriendBlobCipher.newKey()
        let sha = try FriendBlobCipher.seal(file: plain, to: sealed, key: key)
        let (blobId, expires) = try await ca.upload(blob: sealed)
        XCTAssertGreaterThan(expires, Int64(Date().timeIntervalSince1970))
        let got = dir.appendingPathComponent("got.blob"), back = dir.appendingPathComponent("back.ipa")
        try await cb.download(blob: blobId, to: got)
        XCTAssertEqual(try FriendBlobCipher.open(file: got, to: back, key: key), sha)
        XCTAssertEqual(try Data(contentsOf: back), try Data(contentsOf: plain))
        try await ca.deleteBlob(blobId)

        // Der Ereignisstrom: hello, dann die Anfrage eines Dritten.
        let carol = FriendIdentity(signing: .init(), sealing: .init())
        _ = try await FriendsClient.register(base: base, identity: carol, name: "Carol")
        let seen = expectation(description: "request event")
        let streaming = Task {
            try await cb.events { event in
                if event.type == "request" { seen.fulfill() }
            }
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        _ = try await FriendsClient(base: base, identity: carol).request(code: b.code)
        await fulfillment(of: [seen], timeout: 10)
        streaming.cancel()
    }
}

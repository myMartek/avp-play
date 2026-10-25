import Network
import XCTest
@testable import AVPPlayCore

final class RemoteProtocolTests: XCTestCase {
    func testMessagesSurviveTheWire() throws {
        let game = RemoteGame(id: "beatsaber", title: "Beat Saber", trust: .verified, onDevice: .update, downloaded: true, owned: true,
                              source: "meta", busy: false, installBlocker: nil, canDownload: false, downloadBlocker: nil, downloadSize: nil,
                              storeBytes: 1_234, mixedReality: true, handTracking: false, favourite: true, coverKey: "own-beatsaber",
                              builtWith: "Toolchain 776")
        let job = RemoteJob(id: "beatsaber-1", gameId: "beatsaber", title: "Beat Saber", state: .running, kind: .install, step: "Build",
                            stepIndex: 3, stepCount: 5, progress: 0.5, progressText: "1 / 2 GB", failure: nil, lastLine: "x",
                            updated: Date(timeIntervalSince1970: 1_000), canResume: false, canCancel: true)
        let messages: [RemoteServerMessage] = [
            .welcome(RemoteServerInfo(serverId: "abc", name: "Mac", appVersion: "1.4.8")),
            .library(RemoteLibrary(games: [game], filters: [RemoteFilter(id: "f", name: "32 Bit", games: ["beatsaber"])], onlineCatalog: true, horizonPlus: false)),
            .panel(RemotePanel(id: "game:beatsaber", sections: [RemoteSection(id: "s", title: "T", footer: nil, items: [
                RemoteItem(id: "t", kind: .toggle, title: "Favourite", on: true),
                RemoteItem(id: "c", kind: .choice, title: "Toolchain", value: "a", choices: [RemoteChoice(id: "a", title: "A", section: "S")]),
                RemoteItem(id: "x", kind: .action, title: "Remove", style: .destructive, confirm: "Sure?", prompt: nil),
                RemoteItem(id: "l", kind: .link, title: "Store", value: "https://example.com", shareable: true),
            ])])),
            .status(RemoteStatus(deviceName: "Vision Pro", deviceVia: "wifi", deviceProblem: nil, setupProblem: nil, refreshing: false,
                                 updatable: ["beatsaber"], jobs: [job], notice: nil)),
            .cover(gameId: "beatsaber", key: "own-beatsaber", jpeg: Data([1, 2, 3])),
            .reply(seq: 4, error: "nope"),
            .paired(RemotePairing(clientId: "c", key: Data(repeating: 7, count: 32), server: RemoteServerInfo(serverId: "s", name: "M", appVersion: "1"))),
            .refused("no"),
        ]
        for message in messages {
            let data = try RemoteWire.encoder.encode(message)
            XCTAssertEqual(try RemoteWire.decoder.decode(RemoteServerMessage.self, from: data), message)
        }
        let requests: [RemoteRequest] = [.hello(RemoteHello(clientId: "c", name: "AVP", language: "de")), .pair(name: "AVP"), .refresh,
                                         .install(gameId: "g"), .download(gameId: "g"), .updateAll, .cancel(jobId: "j"),
                                         .resume(jobId: "j"), .cover(gameId: "g"), .openPanel(id: "settings"), .closePanel(id: "settings"),
                                         .panelAction(panel: "game:g", item: "favourite", value: "1"), .clearJobs(kind: "finished")]
        for request in requests {
            let message = RemoteClientMessage(seq: 1, request: request)
            XCTAssertEqual(try RemoteWire.decoder.decode(RemoteClientMessage.self, from: RemoteWire.encoder.encode(message)), message)
        }
    }

    func testFraming() {
        let framed = RemoteWire.frame(Data("hello".utf8))
        XCTAssertEqual(framed.count, 9)
        XCTAssertEqual(RemoteWire.length(of: framed.prefix(4)), 5)
        XCTAssertNil(RemoteWire.length(of: Data([0xff, 0xff, 0xff, 0xff])), "zu groß")
        XCTAssertNil(RemoteWire.length(of: Data([0, 1])))
    }

    func testCodesAndKeys() {
        let code = RemoteWire.newCode()
        XCTAssertEqual(code.count, 6)
        XCTAssertEqual(RemoteWire.normalizedCode(code), code)
        XCTAssertEqual(RemoteWire.normalizedCode("123 456"), "123456")
        XCTAssertNil(RemoteWire.normalizedCode("12345"))
        XCTAssertNil(RemoteWire.normalizedCode("12345a"))
        XCTAssertNil(RemoteWire.normalizedCode("١٢٣٤٥٦"), "nur ASCII-Ziffern")
        XCTAssertEqual(RemoteWire.pairingKey(code: "123456"), RemoteWire.pairingKey(code: "123456"))
        XCTAssertNotEqual(RemoteWire.pairingKey(code: "123456"), RemoteWire.pairingKey(code: "123457"))
        let key = RemoteWire.newKey()
        XCTAssertEqual(key.count, 32)
        XCTAssertEqual(RemoteWire.data(hex: RemoteWire.hex(key)), key)
        XCTAssertNil(RemoteWire.data(hex: "abc"))
        XCTAssertNil(RemoteWire.data(hex: "zz"))
        XCTAssertEqual(RemoteWire.newId().count, 32)
    }

    /// Über eine echte Verbindung auf diesem Rechner: mit dem richtigen Schlüssel gehen Nachrichten hin und zurück,
    /// mit einem falschen oder einer fremden Kennung steht keine Verbindung.
    func testOnlyTheRightKeyConnects() throws {
        let key = RemoteWire.newKey()
        let queue = DispatchQueue(label: "remote-test")
        let listener = try NWListener(using: RemoteWire.parameters(psks: [(identity: "remote-a", key: key)]), on: .any)
        listener.newConnectionHandler = { connection in
            let channel = RemoteChannel(connection: connection, queue: queue)
            channel.receive({ data in
                guard let message = try? RemoteWire.decoder.decode(RemoteClientMessage.self, from: data) else { return }
                channel.send(RemoteServerMessage.reply(seq: message.seq, error: nil))
            }, closed: { _ in connection.cancel() })
            connection.start(queue: queue)
        }
        let ready = expectation(description: "listener")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: queue)
        wait(for: [ready], timeout: 5)
        defer { listener.cancel() }
        let port = listener.port!

        func attempt(identity: String, key: Data) -> Int? {
            let connection = NWConnection(host: "127.0.0.1", port: port, using: RemoteWire.parameters(psks: [(identity: identity, key: key)]))
            let channel = RemoteChannel(connection: connection, queue: queue)
            let done = expectation(description: identity)
            var answer: Int?
            var finished = false
            func finish() { queue.async { if !finished { finished = true; done.fulfill() } } }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    channel.send(RemoteClientMessage(seq: 42, request: .refresh))
                    channel.receive({ data in
                        if case .reply(let seq, _)? = try? RemoteWire.decoder.decode(RemoteServerMessage.self, from: data) { answer = seq }
                        finish()
                    }, closed: { _ in finish() })
                case .failed, .waiting: finish()
                default: break
                }
            }
            connection.start(queue: queue)
            wait(for: [done], timeout: 10)
            connection.cancel()
            return answer
        }
        XCTAssertEqual(attempt(identity: "remote-a", key: key), 42)
        XCTAssertNil(attempt(identity: "remote-a", key: RemoteWire.newKey()))
        XCTAssertNil(attempt(identity: "remote-b", key: key))
    }
}

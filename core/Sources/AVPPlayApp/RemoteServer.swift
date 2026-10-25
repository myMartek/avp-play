import AppKit
import AVPPlayCore
import Combine
import Network
import SwiftUI

/// Eine gekoppelte Fernbedienung. Ihr Schlüssel liegt im Schlüsselbund, nicht hier.
struct RemotePeer: Codable, Identifiable, Equatable {
    var clientId: String
    var name: String
    var paired: Date
    var lastSeen: Date?
    var id: String { clientId }
}

/// Die gekoppelten Fernbedienungen: Namen und Daten in den Voreinstellungen, die Schlüssel im Schlüsselbund – sie
/// sind so viel wert wie ein Zugang zu diesem Programm.
struct RemotePeerStore {
    static let defaultsKey = "remotePeers"
    let keychain = TokenStore(service: "avpplay-remote")

    func load() -> [RemotePeer] {
        guard let data = UserDefaults.standard.data(forKey: RemotePeerStore.defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([RemotePeer].self, from: data)) ?? []
    }

    func save(_ peers: [RemotePeer]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(peers), forKey: RemotePeerStore.defaultsKey)
    }

    func key(of clientId: String) -> Data? {
        (try? keychain.read(account: "peer-\(clientId)")).flatMap { RemoteWire.data(hex: $0) }
    }

    func setKey(_ key: Data, of clientId: String) throws {
        try keychain.write(token: RemoteWire.hex(key), account: "peer-\(clientId)")
    }

    func removeKey(of clientId: String) {
        _ = try? keychain.delete(account: "peer-\(clientId)")
    }
}

/// Eine Verbindung einer Fernbedienung.
@MainActor
final class RemoteSession {
    let channel: RemoteChannel
    /// Über den Kopplungsport gekommen: darf nur koppeln.
    let pairing: Bool
    var clientId: String?
    var name = ""
    var welcomed = false
    /// Was zuletzt geschickt wurde – Gleiches geht nicht noch einmal über die Leitung.
    var lastStatus: Data?
    var lastGames: Data?
    /// Die Seiten, die sie gerade zeigt, und was von jeder zuletzt geschickt wurde.
    var panels: Set<String> = []
    var lastPanels: [String: Data] = [:]

    init(channel: RemoteChannel, pairing: Bool) {
        self.channel = channel
        self.pairing = pairing
    }
}

/// Die Fernbedienung von der Vision Pro aus: Der Mac zeigt sich im lokalen Netz (Bonjour) und nimmt Verbindungen
/// der App „AVP Play Remote“ an. Wer sich verbindet, braucht einen Schlüssel – den bekommt er einmal beim Koppeln
/// mit dem Code, der hier in den Einstellungen steht. Gekoppelte Fernbedienungen sehen die Spiele und Aufträge und
/// können installieren, aktualisieren, laden, anhalten und fortsetzen – dasselbe, was die Knöpfe hier tun, mit
/// denselben Prüfungen.
@MainActor
final class RemoteServer: ObservableObject {
    static let enabledKey = "remoteControl"
    /// Nach so vielen fehlgeschlagenen Kopplungen gilt ein neuer Code, und eine Minute lang wird nicht gekoppelt.
    static let pairingAttempts = 5
    static let pairingPause: TimeInterval = 60

    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: RemoteServer.enabledKey)
    @Published private(set) var code = RemoteServer.firstCode
    @Published private(set) var peers: [RemotePeer] = []
    /// Kennungen der Fernbedienungen, die gerade verbunden sind.
    @Published private(set) var connected: Set<String> = []
    @Published private(set) var listening = false
    @Published private(set) var problem: String?
    @Published private(set) var pairingPausedUntil: Date?

    let serverId: String = {
        if let id = UserDefaults.standard.string(forKey: "remoteServerId") { return id }
        let id = RemoteWire.newId()
        UserDefaults.standard.set(id, forKey: "remoteServerId")
        return id
    }()

    private weak var model: AppModel?
    private let store = RemotePeerStore()
    private var keys: [String: Data] = [:]
    private var listener: NWListener?
    private var pairListener: NWListener?
    private var sessions: [ObjectIdentifier: RemoteSession] = [:]
    private let queue = DispatchQueue(label: "io.github.mymartek.avpplay.remote")
    private var watch: AnyCancellable?
    private var pushTask: Task<Void, Never>?
    private var lastGamesAt = Date.distantPast
    private var gamesForced = false
    private var failedPairs = 0
    private let panelCache = RemotePanelCache()
    private var awake: NSObjectProtocol?

    /// Zum Testen mit dem Simulator ein fester Code: `AVPPLAY_REMOTE_CODE=123456` (nur in Debug-Builds).
    private static var firstCode: String {
        #if DEBUG
        if let code = ProcessInfo.processInfo.environment["AVPPLAY_REMOTE_CODE"].flatMap(RemoteWire.normalizedCode) { return code }
        #endif
        return RemoteWire.newCode()
    }

    func attach(_ model: AppModel) {
        self.model = model
        guard enabled, Snapshot.directory == nil else { return }
        start()
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        UserDefaults.standard.set(on, forKey: RemoteServer.enabledKey)
        on ? start() : stop()
    }

    /// Der Name, unter dem sich der Mac zeigt.
    var macName: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }

    var info: RemoteServerInfo {
        RemoteServerInfo(serverId: serverId, name: macName, appVersion: model?.appVersion ?? "0")
    }

    // MARK: Lauschen

    private func start() {
        problem = nil
        peers = store.load()
        // Die Schlüssel kommen über `security` – nicht auf dem Hauptfaden warten.
        let ids = peers.map(\.clientId)
        let store = store
        Task.detached {
            var found: [String: Data] = [:]
            for id in ids { if let key = store.key(of: id) { found[id] = key } }
            let loaded = found
            await MainActor.run {
                guard self.enabled else { return }
                self.keys = loaded
                // Wessen Schlüssel fehlt, ist nicht mehr gekoppelt.
                if loaded.count != self.peers.count {
                    self.peers.removeAll { loaded[$0.clientId] == nil }
                    store.save(self.peers)
                }
                self.startListener()
                self.startPairListener()
                self.watch = self.model?.objectWillChange.sink { [weak server = self] _ in
                    Task { @MainActor in server?.schedulePush() }
                }
            }
        }
    }

    private func stop() {
        watch = nil
        listener?.cancel(); listener = nil
        pairListener?.cancel(); pairListener = nil
        for session in sessions.values { session.channel.connection.cancel() }
        sessions = [:]
        connected = []
        listening = false
        endAwake()
    }

    /// Der eigentliche Port: nimmt nur, wer einen der Schlüssel der gekoppelten Fernbedienungen hat. Ändert sich
    /// die Menge der Schlüssel, wird er neu aufgemacht; bestehende Verbindungen bleiben.
    private func startListener() {
        listener?.cancel()
        listener = nil
        guard enabled else { return }
        // Ohne gekoppelte Fernbedienung gibt es keinen Schlüssel – dann nimmt der Port einen, den niemand kennt,
        // und zeigt sich trotzdem im Netz, damit die Vision Pro den Mac zum Koppeln findet.
        var psks = keys.map { (identity: RemoteWire.clientIdentity($0.key), key: $0.value) }
        if psks.isEmpty { psks = [(identity: "none", key: RemoteWire.newKey())] }
        let parameters = RemoteWire.parameters(psks: psks)
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: RemoteWire.defaultPort)!)
            var txt = NWTXTRecord()
            txt[RemoteWire.txtServerId] = serverId
            txt[RemoteWire.txtVersion] = "\(RemoteWire.protocolVersion)"
            txt[RemoteWire.txtPairPort] = "\(RemoteWire.pairPort)"
            listener.service = NWListener.Service(name: macName, type: RemoteWire.serviceType, txtRecord: txt)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready: self.listening = true; self.problem = nil
                    case .failed(let error):
                        self.listening = false
                        self.problem = L("The remote control cannot listen on port \(RemoteWire.defaultPort): \(error)",
                                         "Die Fernbedienung kann nicht auf Port \(RemoteWire.defaultPort) lauschen: \(error)")
                        // Ein Port, den die vorige Fassung noch hält, wird gleich frei.
                        try? await Task.sleep(for: .seconds(3))
                        if self.listener === listener { self.startListener() }
                    case .cancelled: break
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection, pairing: false) }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            problem = "\(error)"
        }
    }

    /// Der Kopplungsport: nimmt nur, wer den Code kennt, und dort nichts als das Koppeln.
    private func startPairListener() {
        pairListener?.cancel()
        pairListener = nil
        guard enabled else { return }
        if let until = pairingPausedUntil, until > Date() { return }
        pairingPausedUntil = nil
        let parameters = RemoteWire.parameters(psks: [(identity: RemoteWire.pairIdentity, key: RemoteWire.pairingKey(code: code))])
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters, on: NWEndpoint.Port(rawValue: RemoteWire.pairPort)!) else { return }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection, pairing: true) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard case .failed = state else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                guard let self, let listener, self.pairListener === listener else { return }
                self.startPairListener()
            }
        }
        pairListener = listener
        listener.start(queue: queue)
    }

    /// Ein neuer Code; der alte gilt sofort nicht mehr.
    func newCode() {
        code = RemoteWire.newCode()
        failedPairs = 0
        pairingPausedUntil = nil
        startPairListener()
    }

    /// Eine Kopplung ist am Schlüssel gescheitert. Nach einigen davon ein neuer Code und eine Pause – sonst ließe
    /// sich der Code durchprobieren.
    private func pairingFailed() {
        failedPairs += 1
        guard failedPairs >= RemoteServer.pairingAttempts else { return }
        failedPairs = 0
        code = RemoteWire.newCode()
        pairingPausedUntil = Date().addingTimeInterval(RemoteServer.pairingPause)
        pairListener?.cancel()
        pairListener = nil
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(RemoteServer.pairingPause))
            self?.startPairListener()
        }
    }

    func remove(_ peer: RemotePeer) {
        peers.removeAll { $0.clientId == peer.clientId }
        store.save(peers)
        keys[peer.clientId] = nil
        let store = store
        Task.detached { store.removeKey(of: peer.clientId) }
        for session in sessions.values where session.clientId == peer.clientId {
            session.channel.sendAndClose(RemoteServerMessage.refused(L("This remote has been removed on the Mac.", "Diese Fernbedienung wurde auf dem Mac entfernt.")))
        }
        startListener()
    }

    // MARK: Verbindungen

    private func accept(_ connection: NWConnection, pairing: Bool) {
        guard enabled else { return connection.cancel() }
        let channel = RemoteChannel(connection: connection, queue: queue)
        let session = RemoteSession(channel: channel, pairing: pairing)
        let key = ObjectIdentifier(session)
        sessions[key] = session
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .failed(let error):
                    if pairing, case .tls = error { self.pairingFailed() }
                    self.drop(key)
                case .cancelled: self.drop(key)
                default: break
                }
            }
        }
        channel.receive({ [weak self] data in
            Task { @MainActor in self?.received(data, in: key) }
        }, closed: { [weak self] _ in
            Task { @MainActor in
                connection.cancel()
                self?.drop(key)
            }
        })
        connection.start(queue: queue)
    }

    /// Trägt eine Verbindung aus. Ist gerade eine letzte Nachricht unterwegs (`sendAndClose`), endet sie danach.
    private func drop(_ key: ObjectIdentifier, closing: Bool = true) {
        guard let session = sessions.removeValue(forKey: key) else { return }
        if closing { session.channel.connection.cancel() }
        updateConnected()
    }

    private func updateConnected() {
        let now = Set(sessions.values.filter(\.welcomed).compactMap(\.clientId))
        if now != connected { connected = now }
        // Solange eine Fernbedienung verbunden ist, soll macOS das Programm nicht in den Schlummer schicken.
        if now.isEmpty { endAwake() } else if awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                          reason: "Remote control from Apple Vision Pro")
        }
    }

    private func endAwake() {
        if let awake { ProcessInfo.processInfo.endActivity(awake) }
        awake = nil
    }

    private func received(_ data: Data, in key: ObjectIdentifier) {
        guard let session = sessions[key] else { return }
        guard let message = try? RemoteWire.decoder.decode(RemoteClientMessage.self, from: data) else {
            session.channel.sendAndClose(RemoteServerMessage.refused(L("Unknown message – please update AVP Play Remote.",
                                                               "Unbekannte Nachricht – bitte AVP Play Remote aktualisieren.")))
            return drop(key, closing: false)
        }
        switch message.request {
        case .hello(let hello):
            guard hello.protocolVersion == RemoteWire.protocolVersion else {
                session.channel.sendAndClose(RemoteServerMessage.refused(hello.protocolVersion < RemoteWire.protocolVersion
                    ? L("AVP Play Remote is older than AVP Play on this Mac. Please update it.", "AVP Play Remote ist älter als AVP Play auf diesem Mac. Bitte aktualisiere es.")
                    : L("AVP Play on this Mac is older than AVP Play Remote. Please update AVP Play.", "AVP Play auf diesem Mac ist älter als AVP Play Remote. Bitte aktualisiere AVP Play.")))
                return drop(key, closing: false)
            }
            session.name = hello.name
            if session.pairing { return session.channel.send(RemoteServerMessage.reply(seq: message.seq, error: nil)) }
            // Der Schlüssel hat schon gezeigt, dass die Fernbedienung gekoppelt ist; die Kennung sagt, welche.
            guard let id = hello.clientId, let index = peers.firstIndex(where: { $0.clientId == id }) else {
                session.channel.sendAndClose(RemoteServerMessage.refused(L("This remote is not paired with this Mac any more.",
                                                                   "Diese Fernbedienung ist nicht mehr mit diesem Mac gekoppelt.")))
                return drop(key, closing: false)
            }
            session.clientId = id
            session.welcomed = true
            peers[index].lastSeen = Date()
            if !hello.name.isEmpty { peers[index].name = hello.name }
            store.save(peers)
            updateConnected()
            session.channel.send(RemoteServerMessage.welcome(info))
            session.channel.send(RemoteServerMessage.reply(seq: message.seq, error: nil))
            gamesForced = true
            push()
        case .pair(let name):
            guard session.pairing else { return refuse(session, key) }
            pair(session, name: name, seq: message.seq)
        case .openPanel(let id):
            guard !session.pairing, session.welcomed else { return refuse(session, key) }
            session.panels.insert(id)
            session.lastPanels[id] = nil
            model?.remotePanelOpened(id)
            session.channel.send(RemoteServerMessage.reply(seq: message.seq, error: nil))
            gamesForced = true
            push()
        case .closePanel(let id):
            guard !session.pairing, session.welcomed else { return refuse(session, key) }
            session.panels.remove(id)
            session.lastPanels[id] = nil
            session.channel.send(RemoteServerMessage.reply(seq: message.seq, error: nil))
        default:
            guard !session.pairing, session.welcomed else { return refuse(session, key) }
            if case .cover(let id) = message.request { return sendCover(id, to: session) }
            let error = perform(message.request)
            session.channel.send(RemoteServerMessage.reply(seq: message.seq, error: error))
            gamesForced = true
            schedulePush()
        }
    }

    private func refuse(_ session: RemoteSession, _ key: ObjectIdentifier) {
        session.channel.sendAndClose(RemoteServerMessage.refused(L("Not allowed.", "Nicht erlaubt.")))
        drop(key, closing: false)
    }

    private func pair(_ session: RemoteSession, name: String, seq: Int) {
        let clientId = RemoteWire.newId()
        let key = RemoteWire.newKey()
        let display = name.isEmpty ? "Apple Vision Pro" : String(name.prefix(80))
        let store = store
        Task {
            do {
                try await Task.detached { try store.setKey(key, of: clientId) }.value
            } catch {
                session.channel.send(RemoteServerMessage.reply(seq: seq, error: L("The key could not be stored in the keychain: \(error)",
                                                                                 "Der Schlüssel ließ sich nicht im Schlüsselbund ablegen: \(error)")))
                return
            }
            self.keys[clientId] = key
            self.peers.append(RemotePeer(clientId: clientId, name: display, paired: Date(), lastSeen: nil))
            store.save(self.peers)
            // Ein Code gilt für eine Kopplung.
            self.code = RemoteWire.newCode()
            self.failedPairs = 0
            self.startListener()
            self.startPairListener()
            session.channel.send(RemoteServerMessage.paired(RemotePairing(clientId: clientId, key: key, server: self.info)))
            self.model?.notice = L("“\(display)” is now paired as a remote control.", "„\(display)“ ist jetzt als Fernbedienung gekoppelt.")
        }
    }

    // MARK: Bitten

    /// Führt eine Bitte aus; zurück kommt, was im Weg stand.
    private func perform(_ request: RemoteRequest) -> String? {
        guard let model else { return L("AVP Play is not ready.", "AVP Play ist nicht bereit.") }
        func game(_ id: String) -> Game? { model.allGames.first { $0.id == id } }
        func job(_ id: String) -> Job? { model.jobs.first { $0.id == id } }
        let unknownGame = L("This game is not in the list on the Mac.", "Dieses Spiel steht auf dem Mac nicht in der Liste.")
        let unknownJob = L("This job is not in the list on the Mac.", "Dieser Auftrag steht auf dem Mac nicht in der Liste.")
        switch request {
        case .refresh:
            model.refresh()
        case .install(let id):
            guard let game = game(id) else { return unknownGame }
            if let why = model.blocker(for: game) { return why }
            model.install(game)
        case .download(let id):
            guard let game = game(id) else { return unknownGame }
            guard model.hasDownloads(game) else { return L("Everything for this game is already on the Mac.", "Für dieses Spiel liegt schon alles auf dem Mac.") }
            if let why = model.downloadBlocker(for: game) { return why }
            model.download(game)
        case .updateAll:
            guard !model.updatable.isEmpty else { return L("There is nothing to update.", "Es gibt nichts zu aktualisieren.") }
            model.updateAll()
        case .cancel(let id):
            guard let job = job(id) else { return unknownJob }
            guard model.phase(of: job).canCancel else { return L("This job is no longer running.", "Dieser Auftrag läuft nicht mehr.") }
            model.cancel(job)
        case .resume(let id):
            guard let job = job(id) else { return unknownJob }
            guard model.phase(of: job).canResume, job.failureKind?.resumable ?? true else {
                return L("This job cannot be resumed.", "Dieser Auftrag lässt sich nicht fortsetzen.")
            }
            model.resume(job)
        case .panelAction(let panel, let item, let value):
            return model.remotePanelAction(panel: panel, item: item, value: value, cache: panelCache)
        case .clearJobs(let kind):
            let clearing: JobClearing
            switch kind {
            case "finished": clearing = .finished
            case "stopped": clearing = .stopped
            default: clearing = .all
            }
            guard !model.jobs(matching: clearing).isEmpty else { return L("There is nothing to clear.", "Es gibt nichts zu leeren.") }
            model.clearJobs(clearing)
        case .hello, .pair, .cover, .openPanel, .closePanel:
            break
        }
        return nil
    }

    private func sendCover(_ id: String, to session: RemoteSession) {
        guard let model, let game = model.allGames.first(where: { $0.id == id }) else {
            return session.channel.send(RemoteServerMessage.cover(gameId: id, key: nil, jpeg: nil))
        }
        let key = model.remoteCoverKey(game)
        if let own = game.cover {
            return session.channel.send(RemoteServerMessage.cover(gameId: id, key: key, jpeg: RemoteServer.jpeg(own)))
        }
        guard let appId = model.remoteStoreCoverId(game) else {
            return session.channel.send(RemoteServerMessage.cover(gameId: id, key: nil, jpeg: nil))
        }
        let catalogHasOne = game.catalog?.cover == true
        Task {
            let data = await model.covers.image(appId: appId, catalogHasOne: catalogHasOne)
            let jpeg = data.flatMap(NSImage.init(data:)).flatMap { RemoteServer.jpeg($0) }
            session.channel.send(RemoteServerMessage.cover(gameId: id, key: jpeg == nil ? nil : key, jpeg: jpeg))
        }
    }

    /// Ein Titelbild für die Leitung: höchstens 960 Punkte breit, als JPEG.
    static func jpeg(_ image: NSImage, maxWidth: Int = 960) -> Data? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil), source.width > 0 else { return nil }
        let scale = min(1, Double(maxWidth) / Double(source.width))
        let width = max(1, Int(Double(source.width) * scale)), height = max(1, Int(Double(source.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    // MARK: Stand schicken

    /// Nach einer Änderung am Zustand: gesammelt, höchstens gut zweimal in der Sekunde.
    private func schedulePush() {
        guard pushTask == nil, sessions.values.contains(where: \.welcomed) else { return }
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self else { return }
            self.pushTask = nil
            self.push()
        }
    }

    /// Schickt jeder Fernbedienung, was sich für sie geändert hat. Die Spieleliste ist größer und wird höchstens
    /// alle anderthalb Sekunden neu gebaut – während eines Downloads ändert sich sonst ständig etwas.
    private func push() {
        guard let model else { return }
        let targets = sessions.values.filter(\.welcomed)
        guard !targets.isEmpty else { return }
        let status = try? RemoteWire.encoder.encode(RemoteServerMessage.status(model.remoteStatus()))
        var games: Data?
        var panels: [String: Data] = [:]
        let since = Date().timeIntervalSince(lastGamesAt)
        if gamesForced || since > 1.5 {
            games = try? RemoteWire.encoder.encode(RemoteServerMessage.library(model.remoteLibrary()))
            // Jede Seite einmal, auch wenn mehrere Fernbedienungen sie zeigen.
            for id in Set(targets.flatMap(\.panels)) {
                if let panel = model.remotePanel(id, cache: panelCache) {
                    panels[id] = try? RemoteWire.encoder.encode(RemoteServerMessage.panel(panel))
                }
            }
            lastGamesAt = Date()
            gamesForced = false
        } else {
            // Was jetzt ausgelassen wurde, kommt mit dem nächsten Mal.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5 - since))
                self?.schedulePush()
            }
        }
        for session in targets {
            if let status, status != session.lastStatus {
                session.channel.send(encoded: status)
                session.lastStatus = status
            }
            if let games, games != session.lastGames {
                session.channel.send(encoded: games)
                session.lastGames = games
            }
            for id in session.panels {
                guard let panel = panels[id], panel != session.lastPanels[id] else { continue }
                session.channel.send(encoded: panel)
                session.lastPanels[id] = panel
            }
        }
    }

    /// Die IPv4-Adressen dieses Macs im lokalen Netz – für die Eingabe von Hand.
    static func addresses() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: host))
            }
        }
        return result
    }
}

// MARK: Was die Fernbedienung zu sehen bekommt

extension AppModel {
    /// Was auf diesem Mac noch fehlt, bevor sich überhaupt etwas installieren lässt.
    var remoteSetupProblem: String? {
        if let why = storeBlocker { return why }
        if xcodeProblem != nil { return L("Xcode is missing on the Mac (see “Setup”).", "Auf dem Mac fehlt Xcode (siehe „Einrichtung“).") }
        if toolchain == nil { return L("The toolchain is not installed on the Mac yet (see “Setup”).", "Auf dem Mac ist die Toolchain noch nicht installiert (siehe „Einrichtung“).") }
        if !teamValid { return L("The Apple team ID is still missing on the Mac (see “Setup”).", "Auf dem Mac fehlt noch die Apple-Team-ID (siehe „Einrichtung“).") }
        return nil
    }

    func remoteStatus() -> RemoteStatus {
        let via: String?
        switch device?.transport {
        case .wifi: via = "wifi"
        case .cable: via = "cable"
        default: via = nil
        }
        return RemoteStatus(deviceName: device?.name, deviceVia: via,
                            deviceProblem: device == nil ? (deviceProblem ?? L("The Vision Pro is not reachable.", "Die Vision Pro ist nicht erreichbar.")) : nil,
                            setupProblem: remoteSetupProblem, refreshing: refreshing, updatable: updatable.map(\.id),
                            jobs: jobs.prefix(40).map(remoteJob), notice: notice,
                            clearable: [(JobClearing.finished, "finished"), (.stopped, "stopped"), (.all, "all")].compactMap { clearing, id in
                                let count = self.jobs(matching: clearing).count
                                return count == 0 ? nil : RemoteChoice(id: id, title: "\(clearing.title) (\(count))")
                            })
    }

    func remoteJob(_ job: Job) -> RemoteJob {
        let phase = phase(of: job)
        let state: RemoteJob.State
        switch phase {
        case .running: state = .running
        case .queued: state = .queued
        case .finished: state = .finished
        case .cancelled: state = .cancelled
        case .stopped: state = .stopped
        case .interrupted: state = .interrupted
        }
        let kind: RemoteJob.Kind = job.isDownloadOnly ? .download : job.isAddonSync ? .addons : job.steps.contains(.build) ? .install : .content
        // Dieselben Balken wie auf der Seite des Auftrags hier (`JobDetail`).
        var bars: [RemoteProgress] = []
        var overall: Double?
        if phase == .running, job.current == .fetch {
            let copy = copyProgress[job.id].flatMap { $0.step == .fetch ? $0 : nil }
            if let loaded = downloadProgress(job) {
                bars.append(remoteBar(job.id, done: loaded.done, total: loaded.total, verb: L("downloaded", "geladen")))
            } else if let copy, copy.total > 0 {
                // Steam meldet den Stand des ganzen Spiels selbst.
                bars.append(remoteBar(job.id, done: copy.done, total: copy.total, verb: L("downloaded", "geladen")))
            }
            overall = bars.first?.value
            if let file = copy?.file {
                let fileShare = file.total.flatMap { $0 > 0 ? min(1, Double(file.done) / Double($0)) : nil }
                bars.append(RemoteProgress(title: L("File \(file.index) of \(file.count)", "Datei \(file.index) von \(file.count)") + " · " + file.name,
                                           value: file.count > 1 ? Double(file.index - 1) / Double(file.count) : nil, text: nil))
                if let total = file.total, total > 0 {
                    bars.append(RemoteProgress(value: fileShare, text: "\(Installer.megabytes(file.done)) \(L("of", "von")) \(Installer.megabytes(total))"))
                } else if file.done > 0 {
                    bars.append(RemoteProgress(value: nil, text: L("\(Installer.megabytes(file.done)) loaded", "\(Installer.megabytes(file.done)) geladen")))
                }
                // Ohne Größen im Rezept: grob aus „Datei x von y“ und dem Stand der Datei.
                if overall == nil, file.count > 0 { overall = (Double(file.index - 1) + (fileShare ?? 0)) / Double(file.count) }
            }
        } else if phase == .running, job.current == .stage, let copy = copyProgress[job.id], copy.step == .stage, copy.total > 0 {
            bars.append(remoteBar(job.id, done: copy.done, total: copy.total,
                                  verb: copy.via.map { L("copied to the Vision Pro over \($0.text)", "über \($0.text) auf die Vision Pro kopiert") }
                                      ?? L("copied to the Vision Pro", "auf die Vision Pro kopiert")))
            overall = bars.first?.value
        } else if phase == .running, let copy = copyProgress[job.id], copy.step == job.current, copy.total > 0 {
            bars.append(remoteBar(job.id, done: copy.done, total: copy.total, verb: ""))
            overall = bars.first?.value
        }
        let progress = overall
        let text = bars.first(where: { $0.value != nil && $0.title == nil })?.text ?? bars.first?.title
        // Nur der Verlauf, der ohnehin im Speicher liegt – die Dateien aller Aufträge zu lesen, wäre zu teuer.
        let line = logs[job.id]?.lines.last?.trimmingCharacters(in: .whitespaces)
        return RemoteJob(id: job.id, gameId: job.recipe.id, title: job.recipe.title, state: state, kind: kind,
                         step: job.current?.title, stepIndex: min(job.completed.count + (phase == .running ? 1 : 0), job.steps.count),
                         stepCount: job.steps.count, progress: progress.map { min(1, max(0, $0)) }, progressText: text,
                         failure: phase == .stopped ? job.failure : nil, lastLine: line, updated: job.updated,
                         canResume: phase.canResume && (job.failureKind?.resumable ?? true), canCancel: phase.canCancel)
            .with { $0.bars = bars.isEmpty ? nil : bars }
    }

    /// Ein Balken mit Stand in Gigabyte und, sobald es etwas zu rechnen gibt, der geschätzten Restzeit – wie
    /// `ProgressLine`. Der erste Stand, den die Fernbedienung zu sehen bekommt, ist der Anfang der Schätzung.
    private func remoteBar(_ id: String, done: Int64, total: Int64, verb: String) -> RemoteProgress {
        let key = "\(id) \(total)"
        let start = RemoteProgressClock.shared.start(key, done: done)
        var remaining: String?
        let elapsed = Date().timeIntervalSince(start.date)
        if done > start.done, done < total, elapsed >= 10 {
            remaining = ProgressLine.remainingText(seconds: Double(total - done) / (Double(done - start.done) / elapsed))
        }
        let words = "\(Installer.gigabytes(done)) \(L("of", "von")) \(Installer.gigabytes(total))" + (verb.isEmpty ? "" : " \(verb)")
        return RemoteProgress(value: min(1, max(0, Double(done) / Double(max(total, 1)))), text: words + (remaining.map { " · " + $0 } ?? ""))
    }

    func remoteGame(_ game: Game) -> RemoteGame {
        let onDevice: RemoteGame.OnDevice
        switch game.status.onDevice {
        case .unknown: onDevice = .unknown
        case .notInstalled: onDevice = .notInstalled
        case .current: onDevice = .current
        case .olderToolchain, .olderGame, .unstamped: onDevice = .update
        case .otherSource: onDevice = .otherSource
        }
        let trust: RemoteGame.Trust
        switch game.trust {
        case .verified: trust = .verified
        case .community: trust = .community
        case .untested: trust = .untested
        case .incompatible: trust = .incompatible
        }
        let owned: Bool?
        switch self.owned(game) {
        case .yes: owned = true
        case .no: owned = false
        case .unknown, .notApplicable: owned = nil
        }
        let canDownload = hasDownloads(game)
        let horizon: String?
        if let app = game.recipe.catalogAppId, let catalogue = horizonPlus?.catalogue(of: app) {
            horizon = catalogue == .indie ? "indie" : "games"
        } else {
            horizon = nil
        }
        let built = game.status.builtWith.map { "Toolchain \($0.toolchain)" + ($0.modified ? L(" (modified)", " (bearbeitet)") : "") }
        return RemoteGame(id: game.id, title: game.recipe.title, trust: trust, onDevice: onDevice, downloaded: game.downloaded,
                          owned: owned, source: game.recipe.source.map { $0 == .steam ? "steam" : "meta" }, busy: isBusy(game.id),
                          installBlocker: blocker(for: game), canDownload: canDownload,
                          downloadBlocker: canDownload ? downloadBlocker(for: game) : nil,
                          downloadSize: canDownload ? downloadSizeText(game) : nil, storeBytes: game.storeBytes,
                          mixedReality: game.mixedReality, handTracking: game.handTracking, favourite: isFavourite(game),
                          coverKey: remoteCoverKey(game), builtWith: built)
            .with { remote in
                remote.ownedAnywhere = ownedAnywhere(game)
                remote.fromMeta = game.fromMeta
                remote.fromSteam = game.fromSteam
                remote.horizonPlus = horizon
                remote.works = (game.recipe.source == .steam ? game.steamCatalog?.works : game.catalog?.works) ?? 0
            }
    }

    /// Die Spieleliste samt eigener Filter.
    func remoteLibrary() -> RemoteLibrary {
        RemoteLibrary(games: allGames.map(remoteGame),
                      filters: customFilters.map { RemoteFilter(id: $0.id, name: $0.name, games: $0.games.sorted()) },
                      onlineCatalog: onlineCatalog, horizonPlus: horizonPlus != nil)
    }

    /// Woher das Bild eines Spiels kommt; ändert sich, wenn es ein anderes wird.
    func remoteCoverKey(_ game: Game) -> String? {
        if game.cover != nil { return "own-\(game.id)" }
        return remoteStoreCoverId(game).map { "store-\($0)" }
    }

    /// Unter welcher Kennung das Bild von der Store-Seite kommt – wie in der Übersicht (`CoverImage`).
    func remoteStoreCoverId(_ game: Game) -> String? {
        guard storePictures else { return nil }
        let steam = game.recipe.catalogAppId == nil ? game.recipe.store.steamAppId.map { CoverCache.steamPrefix + $0 } : nil
        return game.recipe.catalogAppId ?? steam
    }
}

/// Wann ein Balken zuerst gesehen wurde – für die geschätzte Restzeit.
@MainActor
final class RemoteProgressClock {
    static let shared = RemoteProgressClock()
    private var starts: [String: (date: Date, done: Int64)] = [:]

    func start(_ key: String, done: Int64) -> (date: Date, done: Int64) {
        if let known = starts[key], known.done <= done { return known }
        if starts.count > 200 { starts = [:] }
        starts[key] = (Date(), done)
        return (Date(), done)
    }
}

private extension RemoteJob {
    func with(_ change: (inout RemoteJob) -> Void) -> RemoteJob {
        var copy = self
        change(&copy)
        return copy
    }
}

private extension RemoteGame {
    /// Ein Wert mit nachträglich gesetzten Feldern – die übrigen hat der Initialisierer schon.
    func with(_ change: (inout RemoteGame) -> Void) -> RemoteGame {
        var copy = self
        change(&copy)
        return copy
    }
}

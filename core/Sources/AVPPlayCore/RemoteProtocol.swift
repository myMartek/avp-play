import CryptoKit
import Foundation
import Network

// Die Fernbedienung: AVP Play auf dem Mac nimmt im lokalen Netz Verbindungen der App „AVP Play Remote“ auf der
// Vision Pro an. Diese Datei ist beiden gemeinsam – das Remote-Repository führt eine Kopie davon, ohne Änderungen.
// Sie braucht daher nichts aus dem übrigen AVPPlayCore.
//
// Die Leitung: TCP mit TLS 1.2 über einen vorab geteilten Schlüssel (PSK). Wer koppelt, verbindet sich mit dem
// Kopplungsport, der Kennung `pair` und einem Schlüssel, der aus dem sechsstelligen Code auf dem Mac abgeleitet ist;
// der Mac gibt ihm dort einen eigenen, zufälligen Schlüssel, mit dem er sich fortan am eigentlichen Port unter
// seiner eigenen Kennung meldet. Wer den
// Schlüssel nicht kennt, kommt nicht über den Handshake hinaus. Auf der Leitung: je Nachricht vier Bytes Länge
// (big-endian), dann JSON.

public enum RemoteWire {
    /// Der Bonjour-Dienst, unter dem sich der Mac im Netz zeigt.
    public static let serviceType = "_avpplay._tcp"
    /// Der feste Port – damit eine Verbindung auch über eine eingetippte Adresse klappt.
    public static let defaultPort: UInt16 = 47811
    /// Zum Koppeln ein eigener Port mit eigenem Schlüssel: Wer nur den Code kennt, kann dort nichts als koppeln.
    public static let pairPort: UInt16 = 47812
    /// Steigt, wenn sich Nachrichten so ändern, dass eine ältere Gegenseite sie nicht mehr versteht.
    public static let protocolVersion = 2
    /// Einträge im TXT-Eintrag des Dienstes.
    public static let txtServerId = "id"
    public static let txtVersion = "v"
    /// Der Port zum Koppeln, wenn er nicht der übliche ist.
    public static let txtPairPort = "pp"
    /// Die Kennung, unter der sich eine Fernbedienung zum Koppeln meldet.
    public static let pairIdentity = "pair"
    /// Länge des Kopplungscodes.
    public static let codeLength = 6
    /// Größte Nachricht, die angenommen wird.
    public static let maxFrame = 16 << 20

    /// Die Kennung, unter der sich eine gekoppelte Fernbedienung meldet.
    public static func clientIdentity(_ clientId: String) -> String { "remote-\(clientId)" }

    /// Der Schlüssel zum Koppeln, abgeleitet aus dem Code, den der Mac zeigt.
    public static func pairingKey(code: String) -> Data {
        Data(SHA256.hash(data: Data("avpplay-remote-pair-v1|\(code)".utf8)))
    }

    /// Ein neuer sechsstelliger Code.
    public static func newCode() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<codeLength).map { _ in String(Int.random(in: 0...9, using: &generator)) }.joined()
    }

    /// Ein neuer Schlüssel für eine gekoppelte Fernbedienung (256 Bit).
    public static func newKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    /// Eine neue Kennung für eine Fernbedienung oder einen Mac.
    public static func newId() -> String {
        hex(SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) })
    }

    public static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    public static func data(hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }

    /// Ein Code ist genau sechs Ziffern; Leerzeichen dazwischen (wie der Mac ihn zeigt) zählen nicht.
    public static func normalizedCode(_ text: String) -> String? {
        let digits = text.filter { !$0.isWhitespace && $0 != "-" }
        guard digits.count == codeLength, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return digits
    }

    /// TLS mit vorab geteilten Schlüsseln. Der Mac nennt alle, die er annimmt, die Fernbedienung genau einen.
    public static func parameters(psks: [(identity: String, key: Data)]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        for psk in psks {
            sec_protocol_options_add_pre_shared_key(options, dispatchData(psk.key), dispatchData(Data(psk.identity.utf8)))
        }
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        // PSK-Verfahren gibt es in Network.framework nur bis TLS 1.2.
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.connectionTimeout = 8
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = false
        return parameters
    }

    private static func dispatchData(_ data: Data) -> __DispatchData {
        data.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
    }

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    /// Eine Nachricht für die Leitung: Länge, dann Inhalt.
    public static func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var out = Data(bytes: &length, count: 4)
        out.append(payload)
        return out
    }

    /// Die Länge aus den ersten vier Bytes einer Nachricht.
    public static func length(of header: Data) -> Int? {
        guard header.count == 4 else { return nil }
        let value = header.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return Int(value) <= maxFrame ? Int(value) : nil
    }
}

/// Eine Verbindung, auf der ganze Nachrichten hin und her gehen. Beide Seiten nutzen sie gleich.
public final class RemoteChannel: @unchecked Sendable {
    public let connection: NWConnection
    private let queue: DispatchQueue

    public init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    public func send<T: Encodable>(_ value: T) {
        guard let payload = try? RemoteWire.encoder.encode(value) else { return }
        send(encoded: payload)
    }

    /// Eine letzte Nachricht: Die Verbindung endet erst, wenn sie hinaus ist – sonst ginge sie mit ihr verloren.
    public func sendAndClose<T: Encodable>(_ value: T) {
        guard let payload = try? RemoteWire.encoder.encode(value) else { return connection.cancel() }
        connection.send(content: RemoteWire.frame(payload), completion: .contentProcessed { [connection] _ in connection.cancel() })
    }

    /// Eine schon kodierte Nachricht – wenn dieselbe an mehrere geht.
    public func send(encoded payload: Data) {
        connection.send(content: RemoteWire.frame(payload), completion: .contentProcessed { _ in })
    }

    /// Liest Nachricht für Nachricht, bis die Verbindung endet. `closed` kommt genau einmal.
    public func receive(_ handler: @escaping (Data) -> Void, closed: @escaping (Error?) -> Void) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, done, error in
            guard let self else { return }
            if let error { return closed(error) }
            guard let header, let length = RemoteWire.length(of: header) else { return closed(nil) }
            if length == 0 {
                handler(Data())
                return done ? closed(nil) : self.receive(handler, closed: closed)
            }
            self.connection.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, done, error in
                if let error { return closed(error) }
                guard let body, body.count == length else { return closed(nil) }
                handler(body)
                if done { return closed(nil) }
                self.receive(handler, closed: closed)
            }
        }
    }
}

// MARK: Nachrichten

/// Was eine Fernbedienung über sich sagt, sobald die Verbindung steht.
public struct RemoteHello: Codable, Sendable, Equatable {
    /// Die Kennung aus der Kopplung; fehlt beim Koppeln selbst.
    public var clientId: String?
    public var name: String
    public var protocolVersion: Int
    /// Die Sprache der Fernbedienung (`de`, `en`); Texte des Macs kommen in der Sprache des Macs.
    public var language: String?
    public init(clientId: String?, name: String, protocolVersion: Int = RemoteWire.protocolVersion, language: String? = nil) {
        self.clientId = clientId; self.name = name; self.protocolVersion = protocolVersion; self.language = language
    }
}

/// Was der Mac über sich sagt.
public struct RemoteServerInfo: Codable, Sendable, Equatable {
    public var serverId: String
    public var name: String
    public var appVersion: String
    public var protocolVersion: Int
    public init(serverId: String, name: String, appVersion: String, protocolVersion: Int = RemoteWire.protocolVersion) {
        self.serverId = serverId; self.name = name; self.appVersion = appVersion; self.protocolVersion = protocolVersion
    }
}

/// Die Antwort auf eine Kopplung: der eigene Schlüssel der Fernbedienung und unter welcher Kennung sie sich meldet.
public struct RemotePairing: Codable, Sendable, Equatable {
    public var clientId: String
    public var key: Data
    public var server: RemoteServerInfo
    public init(clientId: String, key: Data, server: RemoteServerInfo) {
        self.clientId = clientId; self.key = key; self.server = server
    }
}

/// Ein Spiel, wie die Fernbedienung es zeigt.
public struct RemoteGame: Codable, Sendable, Equatable, Identifiable {
    public enum OnDevice: String, Codable, Sendable { case unknown, notInstalled, current, update, otherSource }
    public enum Trust: String, Codable, Sendable { case verified, community, untested, incompatible }

    public var id: String
    public var title: String
    public var trust: Trust
    public var onDevice: OnDevice
    /// Alles, woraus das Spiel gebaut wird, liegt auf dem Mac.
    public var downloaded: Bool
    /// Gehört dem Konto: `true`, `false`, oder `nil`, wenn unbekannt oder ohne Bedeutung.
    public var owned: Bool?
    /// `meta`, `steam` oder `nil` (Sonderapp).
    public var source: String?
    /// Für das Spiel läuft oder wartet ein Auftrag.
    public var busy: Bool
    /// Warum sich das Spiel gerade nicht installieren lässt; `nil` = es geht.
    public var installBlocker: String?
    /// Gibt es etwas zu laden, und was steht dem bloßen Laden im Weg?
    public var canDownload: Bool
    public var downloadBlocker: String?
    /// Wie viel noch zu laden ist, in Worten.
    public var downloadSize: String?
    /// Was das Spiel auf dem Mac belegt.
    public var storeBytes: Int64
    public var mixedReality: Bool
    public var handTracking: Bool
    public var favourite: Bool
    /// Ein Bild lässt sich abrufen; der Wert ändert sich, wenn es ein anderes wird.
    public var coverKey: String?
    /// Womit das installierte Spiel gebaut ist (Toolchain), in Worten.
    public var builtWith: String?
    /// Für die Filter wie auf dem Mac: gehört dem Konto bei Meta oder Steam, gibt es bei Meta oder Steam, steht in
    /// einem Horizon+-Katalog (`games`, `indie`), und wie viele Nutzer melden, dass es läuft (für die Reihenfolge).
    public var ownedAnywhere: Bool = false
    public var fromMeta: Bool = false
    public var fromSteam: Bool = false
    public var horizonPlus: String?
    public var works: Int = 0

    public init(id: String, title: String, trust: Trust, onDevice: OnDevice, downloaded: Bool, owned: Bool?, source: String?,
                busy: Bool, installBlocker: String?, canDownload: Bool, downloadBlocker: String?, downloadSize: String?,
                storeBytes: Int64, mixedReality: Bool, handTracking: Bool, favourite: Bool, coverKey: String?, builtWith: String?) {
        self.id = id; self.title = title; self.trust = trust; self.onDevice = onDevice; self.downloaded = downloaded
        self.owned = owned; self.source = source; self.busy = busy; self.installBlocker = installBlocker
        self.canDownload = canDownload; self.downloadBlocker = downloadBlocker; self.downloadSize = downloadSize
        self.storeBytes = storeBytes; self.mixedReality = mixedReality; self.handTracking = handTracking
        self.favourite = favourite; self.coverKey = coverKey; self.builtWith = builtWith
    }

    public var installed: Bool { onDevice == .current || onDevice == .update }
}

/// Ein Balken eines laufenden Auftrags, wie der Mac ihn zeigt: Gesamtstand, Datei x von y, Stand der Datei.
public struct RemoteProgress: Codable, Sendable, Equatable {
    /// Überschrift, etwa „Datei 3 von 12 · name.obb“.
    public var title: String?
    /// 0…1; `nil` = kein Balken, nur Text.
    public var value: Double?
    /// Stand in Worten, etwa „1,2 GB von 3,4 GB geladen · noch etwa 5 Minuten“.
    public var text: String?
    public init(title: String? = nil, value: Double?, text: String?) { self.title = title; self.value = value; self.text = text }
}

/// Ein Auftrag in der Liste des Macs.
public struct RemoteJob: Codable, Sendable, Equatable, Identifiable {
    /// Wie auf dem Mac: läuft, wartet, abgeschlossen, abgebrochen, angehalten (Fehler), unterbrochen.
    public enum State: String, Codable, Sendable { case running, queued, finished, cancelled, stopped, interrupted }
    public enum Kind: String, Codable, Sendable { case install, download, addons, content }

    public var id: String
    public var gameId: String
    public var title: String
    public var state: State
    public var kind: Kind
    /// Der Schritt, der läuft oder bei dem der Auftrag stehen blieb, in Worten.
    public var step: String?
    public var stepIndex: Int
    public var stepCount: Int
    /// Fortschritt des laufenden Schritts, 0…1, soweit bekannt.
    public var progress: Double?
    public var progressText: String?
    public var failure: String?
    /// Die letzte Zeile seines Verlaufs.
    public var lastLine: String?
    public var updated: Date
    public var canResume: Bool
    public var canCancel: Bool
    /// Alle Balken des laufenden Schritts; fehlt bei älteren Macs.
    public var bars: [RemoteProgress]?

    public init(id: String, gameId: String, title: String, state: State, kind: Kind, step: String?, stepIndex: Int, stepCount: Int,
                progress: Double?, progressText: String?, failure: String?, lastLine: String?, updated: Date,
                canResume: Bool, canCancel: Bool) {
        self.id = id; self.gameId = gameId; self.title = title; self.state = state; self.kind = kind; self.step = step
        self.stepIndex = stepIndex; self.stepCount = stepCount; self.progress = progress; self.progressText = progressText
        self.failure = failure; self.lastLine = lastLine; self.updated = updated
        self.canResume = canResume; self.canCancel = canCancel
    }

    /// Läuft oder wartet.
    public var active: Bool { state == .running || state == .queued }
}

/// Wie es auf dem Mac gerade steht – alles außer der Spieleliste.
public struct RemoteStatus: Codable, Sendable, Equatable {
    /// Die Vision Pro, die der Mac gerade erreicht.
    public var deviceName: String?
    /// `wifi`, `cable` oder `nil`.
    public var deviceVia: String?
    public var deviceProblem: String?
    /// Was auf dem Mac noch eingerichtet werden muss (Xcode, Toolchain, Team), in Worten; `nil` = alles da.
    public var setupProblem: String?
    public var refreshing: Bool
    /// Spiele, für die es eine neuere Fassung gibt und denen nichts im Weg steht.
    public var updatable: [String]
    /// Die neuesten Aufträge, der zuletzt angestellte zuerst.
    public var jobs: [RemoteJob]
    /// Eine Meldung des Macs, die gerade steht.
    public var notice: String?
    /// Was sich aus der Liste der Aufträge nehmen lässt: Kennung (`finished`, `stopped`, `all`) und Titel mit Anzahl.
    public var clearable: [RemoteChoice] = []

    public init(deviceName: String?, deviceVia: String?, deviceProblem: String?, setupProblem: String?, refreshing: Bool,
                updatable: [String], jobs: [RemoteJob], notice: String?, clearable: [RemoteChoice] = []) {
        self.deviceName = deviceName; self.deviceVia = deviceVia; self.deviceProblem = deviceProblem
        self.setupProblem = setupProblem; self.refreshing = refreshing; self.updatable = updatable; self.jobs = jobs
        self.notice = notice; self.clearable = clearable
    }
}

/// Ein eigener Filter des Macs („32 Bit“, „Für Gäste“) mit seinen Spielen.
public struct RemoteFilter: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var games: [String]
    public init(id: String, name: String, games: [String]) { self.id = id; self.name = name; self.games = games }
}

/// Die Spieleliste mit dem, was die Filter dazu brauchen.
public struct RemoteLibrary: Codable, Sendable, Equatable {
    public var games: [RemoteGame]
    public var filters: [RemoteFilter]
    /// Der Online-Katalog ist an (dann gibt es „Von Nutzern bestätigt“).
    public var onlineCatalog: Bool
    /// Ein Horizon+-Katalog ist bekannt (dann gibt es die Horizon+-Filter).
    public var horizonPlus: Bool
    public init(games: [RemoteGame], filters: [RemoteFilter], onlineCatalog: Bool, horizonPlus: Bool) {
        self.games = games; self.filters = filters; self.onlineCatalog = onlineCatalog; self.horizonPlus = horizonPlus
    }
}

/// Eine Wahl in einer Liste: Kennung, Text und – für gegliederte Listen – die Überschrift ihres Abschnitts.
public struct RemoteChoice: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var section: String?
    public init(id: String, title: String, section: String? = nil) { self.id = id; self.title = title; self.section = section }
}

/// Ein Eintrag einer Seite, die der Mac beschreibt und die Fernbedienung nur zeigt: Text, Wert, Schalter, Auswahl,
/// Knopf, Link, Prüfpunkt oder etwas, das gerade läuft. So bleibt alles, was entscheidet, auf dem Mac – die
/// Fernbedienung muss für eine neue Einstellung nicht neu gebaut werden.
public struct RemoteItem: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case text, fact, toggle, choice, action, link, check, progress, log }
    public enum Style: String, Codable, Sendable { case normal, secondary, warning, success, prominent, destructive }

    public var id: String
    public var kind: Kind
    public var title: String
    /// Erklärung unter dem Titel; bei `text` der Text selbst, bei `log` die Zeilen.
    public var detail: String?
    /// Bei `fact` der Wert, bei `choice` die gewählte Kennung, bei `link` die Adresse.
    public var value: String?
    public var on: Bool?
    public var choices: [RemoteChoice]?
    public var enabled: Bool
    public var style: Style
    /// Bei einem Knopf: erst nachfragen, mit diesem Text.
    public var confirm: String?
    /// Bei einem Knopf: erst einen Text erfragen (mit diesem Platzhalter) und mitschicken.
    public var prompt: String?
    /// Bei `check`: `ok`, `warning`, `missing` oder `checking`.
    public var state: String?
    /// Bei einem Link: ob die Fernbedienung ihn zum Teilen anbieten darf.
    public var shareable: Bool?

    public init(id: String, kind: Kind, title: String, detail: String? = nil, value: String? = nil, on: Bool? = nil,
                choices: [RemoteChoice]? = nil, enabled: Bool = true, style: Style = .normal, confirm: String? = nil,
                prompt: String? = nil, state: String? = nil, shareable: Bool? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.detail = detail; self.value = value; self.on = on
        self.choices = choices; self.enabled = enabled; self.style = style; self.confirm = confirm; self.prompt = prompt
        self.state = state; self.shareable = shareable
    }
}

public struct RemoteSection: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String?
    public var footer: String?
    public var items: [RemoteItem]
    public init(id: String, title: String?, footer: String? = nil, items: [RemoteItem]) {
        self.id = id; self.title = title; self.footer = footer; self.items = items
    }
}

/// Eine Seite: `game:<Kennung>`, `job:<Kennung>`, `setup` oder `settings`.
public struct RemotePanel: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var sections: [RemoteSection]
    public init(id: String, sections: [RemoteSection]) { self.id = id; self.sections = sections }
}

/// Was die Fernbedienung vom Mac will.
public enum RemoteRequest: Codable, Sendable, Equatable {
    /// Gleich nach dem Verbinden. Unter der Kennung `pair` folgt darauf `pair`, sonst die Antwort `welcome`.
    case hello(RemoteHello)
    /// Nur unter der Kennung `pair`: einen eigenen Schlüssel erbitten.
    case pair(name: String)
    case refresh
    /// Installiert ein Spiel oder bringt ein installiertes auf den neuesten Stand – wie „Installieren“ auf dem Mac.
    case install(gameId: String)
    /// Lädt nur die Dateien auf den Mac.
    case download(gameId: String)
    case updateAll
    case cancel(jobId: String)
    case resume(jobId: String)
    case cover(gameId: String)
    /// Eine Seite wird gezeigt: Der Mac schickt sie und danach jede Änderung, bis `closePanel`. Bei einem Spiel tut
    /// er dabei, was das Öffnen seiner Seite auf dem Mac tut (nachschlagen, Fassungen und Kauf prüfen).
    case openPanel(id: String)
    case closePanel(id: String)
    /// Ein Schalter, eine Wahl oder ein Knopf einer Seite. `value`: `1`/`0` bei Schaltern, die Kennung bei einer
    /// Wahl, der erfragte Text bei einem Knopf mit `prompt`.
    case panelAction(panel: String, item: String, value: String?)
    /// Nimmt Aufträge aus der Liste: `finished`, `stopped` oder `all` (nie, was läuft oder wartet).
    case clearJobs(kind: String)
}

public struct RemoteClientMessage: Codable, Sendable, Equatable {
    /// Laufende Nummer; die Antwort `reply` nennt sie wieder.
    public var seq: Int
    public var request: RemoteRequest
    public init(seq: Int, request: RemoteRequest) { self.seq = seq; self.request = request }
}

/// Was der Mac der Fernbedienung schickt – als Antwort oder von sich aus, wenn sich etwas geändert hat.
public enum RemoteServerMessage: Codable, Sendable, Equatable {
    case welcome(RemoteServerInfo)
    case paired(RemotePairing)
    case status(RemoteStatus)
    case library(RemoteLibrary)
    case panel(RemotePanel)
    case cover(gameId: String, key: String?, jpeg: Data?)
    /// Die Antwort auf eine Bitte: `error` ist `nil`, wenn sie angenommen ist.
    case reply(seq: Int, error: String?)
    /// Der Mac nimmt die Fernbedienung nicht (mehr) an – die Verbindung endet danach.
    case refused(String)
}

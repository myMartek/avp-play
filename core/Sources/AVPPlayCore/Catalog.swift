import Foundation

/// Ein Spiel aus dem Online-Katalog: ein Titel aus dem Meta-Store, was über seinen neuesten Build bekannt ist und
/// was das Projekt und andere Nutzer dazu sagen. Der Katalog liefert nur Namen und Kennungen – nie Spielinhalte,
/// nie eine Adresse, von der geladen würde. Geladen wird ausschließlich bei Meta, mit dem Konto des Nutzers.
/// Einzige Ausnahme ist ein Titelbild für die wenigen Spiele, deren Store-Seite öffentlich keins zeigt (`cover`).
public struct CatalogGame: Codable, Sendable, Identifiable, Equatable {
    public var appId: String
    public var title: String
    public var package: String
    public var publisher: String?
    /// Was die App zeigt: `verified` (vom Projekt geprüft, Rezept liegt vor), `community` (mehr Nutzer melden, dass
    /// es läuft, als dass es nicht startet), `incompatible` (umgekehrt) oder `untested`. Der Dienst rechnet das aus
    /// den Meldungen aus, sofern das Projekt nichts festgelegt hat.
    public var status: String
    /// Das Projekt hat das Spiel als geprüft markiert, aber noch kein Rezept dafür veröffentlicht.
    public var verifiedPending: Bool?
    public var noteEn: String?
    public var noteDe: String?
    /// Unter welchem Namen die Toolchain das Spiel kennt; fehlt, wenn sie es nicht kennt.
    public var target: String?
    /// Das Spiel hat einen Mixed-Reality-Modus, der mit AVP Play funktioniert.
    public var mixedReality: Bool?
    /// Das Spiel lässt sich hier mit den Händen spielen, ohne Controller – im Katalogdienst vom Projekt gesetzt.
    public var handTracking: Bool?
    /// Der Dienst hält ein Titelbild für dieses Spiel bereit, weil die Store-Seite des Spiels öffentlich keins zeigt
    /// (Richie's Plank Experience). Nur dann fragt die App dort nach einem – und erst nach der Store-Seite.
    public var cover: Bool?
    /// Meldungen von Nutzern; jede zählt, sobald sie eingeht.
    public var works: Int
    public var problems: Int
    public var fails: Int
    public var build: CatalogBuild?

    public var id: String { appId }
    public var note: String? { (L10n.language == .de ? noteDe : noteEn).flatMap { $0.isEmpty ? nil : $0 } ?? noteEn.flatMap { $0.isEmpty ? nil : $0 } }

    /// Taugt der Eintrag? Kennungen sind Ziffern, Namen kurz und ohne Steuerzeichen – was vom Server kommt, wird
    /// behandelt wie jede Eingabe von außen.
    public var isSane: Bool {
        CatalogGame.isIdentifier(appId) && !title.isEmpty && title.count <= 200 && package.count <= 300
            && CatalogGame.isPlain(title) && CatalogGame.isPlain(package)
            && (target ?? "").allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
            && (build?.isSane ?? true)
    }

    public static func isIdentifier(_ s: String) -> Bool { (5...24).contains(s.count) && s.allSatisfy { $0.isASCII && $0.isNumber } }
    static func isPlain(_ s: String) -> Bool { !s.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f } }
}

/// Ein Spiel aus der Steam-Liste des Katalogdienstes: ein Steam-Kauf mit Android-Fassung, geführt unter seiner
/// Steam-App-ID. Es hat dieselben Einstufungen, Notizen und Meldungen wie ein Spiel des Meta-Katalogs, aber eigene –
/// eine Meldung zur Steam-Fassung von Moss zählt nicht für Moss im Meta-Store. Die Liste kennt nur Spiele, die das
/// Projekt eingetragen hat; was dort fehlt, ist schlicht nicht in der Antwort.
public struct SteamCatalogGame: Codable, Sendable, Identifiable, Equatable {
    /// Die Steam-App-ID, nur Ziffern.
    public var appId: String
    public var title: String
    public var package: String?
    /// `verified`, `community`, `untested` oder `incompatible` – wie `CatalogGame.status`.
    public var status: String
    /// Das Projekt hat das Spiel als geprüft markiert, aber noch kein Steam-Rezept dafür veröffentlicht.
    public var verifiedPending: Bool?
    public var noteEn: String?
    public var noteDe: String?
    /// Unter welchem Namen die Toolchain das Spiel kennt; fehlt, wenn sie es nicht kennt.
    public var target: String?
    public var mixedReality: Bool?
    /// Das Spiel lässt sich hier mit den Händen spielen – wie `CatalogGame.handTracking`.
    public var handTracking: Bool?
    /// Die Meta-Store-Seite desselben Spiels, wo es eine hat.
    public var metaAppId: String?
    public var works: Int
    public var problems: Int
    public var fails: Int

    public var id: String { appId }
    public var note: String? { (L10n.language == .de ? noteDe : noteEn).flatMap { $0.isEmpty ? nil : $0 } ?? noteEn.flatMap { $0.isEmpty ? nil : $0 } }

    public var isSane: Bool {
        SteamCatalogGame.isIdentifier(appId) && !title.isEmpty && title.count <= 200 && (package ?? "").count <= 300
            && CatalogGame.isPlain(title) && CatalogGame.isPlain(package ?? "")
            && (target ?? "").allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
            && (metaAppId.map(CatalogGame.isIdentifier) ?? true)
    }

    /// Eine Steam-App-ID, wie der Dienst sie annimmt: Ziffern ohne führende Null, höchstens zehn.
    public static func isIdentifier(_ s: String) -> Bool {
        (1...10).contains(s.count) && s.first != "0" && s.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Unter dieser Kennung nehmen Meldungen und Fixes ein Steam-Spiel an: `steam-<Steam-App-ID>` – dieselbe, unter
    /// der die App ihre Steam-Spiele führt. `nil`, wenn es keine Steam-App-ID ist.
    public static func serviceKey(steamAppId: String) -> String? { isIdentifier(steamAppId) ? "steam-" + steamAppId : nil }
}

public struct CatalogBuild: Codable, Sendable, Equatable {
    public var buildId: String
    public var version: String
    public var versionCode: Int
    public var fileName: String?

    var isSane: Bool { CatalogGame.isIdentifier(buildId) && version.count <= 80 && CatalogGame.isPlain(version) && versionCode >= 0 }
}

/// Eine Rückmeldung an das Projekt: welches Spiel, welcher Build, was passiert ist. Nichts darin sagt, von wem.
public struct CatalogFeedback: Codable, Sendable, Equatable {
    public enum Result: String, Codable, Sendable, CaseIterable { case works, problems, fails }
    public var appId: String
    public var versionCode: Int
    public var result: Result
    public var comment: String
    public var appVersion: String
    public var toolchain: String
    public var lang: String

    /// Steht vor dem Kommentar einer Meldung zur Fassung eines Spiels aus Steam, die an die Meta-Seite des Spiels geht –
    /// so meldeten App-Fassungen bis 1.2.x, und so meldet `CatalogClient.sendSteam` an einen Dienst ohne Steam-Liste.
    public static let steamMark = "[Steam] "

    public init(appId: String, versionCode: Int, result: Result, comment: String, appVersion: String, toolchain: String, lang: String) {
        self.appId = appId
        self.versionCode = versionCode
        self.result = result
        self.comment = String(comment.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000))
        self.appVersion = appVersion
        self.toolchain = toolchain
        self.lang = lang
    }
}

/// Die Meldung „diese Kopie ist heute in Gebrauch“. Sie trägt keine Kennung: Die App merkt sich nur den Tag ihrer
/// letzten Meldung und sagt, ob diese die erste überhaupt, die erste in dieser Woche und die erste in diesem
/// Monat ist. Daraus zählt der Dienst Nutzer pro Tag, Woche und Monat, ohne eine Kopie wiedererkennen zu können.
public struct UsagePing: Codable, Sendable, Equatable {
    public var appVersion: String
    public var first: Bool
    public var week: Bool
    public var month: Bool

    /// Tage, Wochen (ab Montag) und Monate in Weltzeit – so zählt auch der Dienst.
    static let calendar: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Der Tag als „2026-10-11“.
    public static func day(_ date: Date) -> String {
        let d = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", d.year ?? 0, d.month ?? 0, d.day ?? 0)
    }

    static func date(ofDay day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Die fällige Meldung – oder `nil`, wenn heute schon gemeldet wurde. `last` ist der Tag der letzten Meldung,
    /// `nil` oder Unlesbares heißt: noch nie.
    public static func due(last: String?, now: Date, appVersion: String) -> UsagePing? {
        guard let before = last.flatMap(date(ofDay:)) else { return UsagePing(appVersion: appVersion, first: true, week: true, month: true) }
        if calendar.isDate(before, inSameDayAs: now) { return nil }
        return UsagePing(appVersion: appVersion, first: false,
                         week: !calendar.isDate(before, equalTo: now, toGranularity: .weekOfYear),
                         month: !calendar.isDate(before, equalTo: now, toGranularity: .month))
    }

    /// Unter welchem Namen der Dienst ein Spiel zählt: die Store-Kennung, oder für Spiele von anderswo der Name
    /// ihres Rezepts. `nil`, wenn es keinen gibt, den der Dienst annähme.
    public static func gameKey(appId: String?, recipe: String) -> String? {
        if let appId { return CatalogGame.isIdentifier(appId) ? appId : nil }
        let plain = recipe.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
        return (2...32).contains(recipe.count) && plain && recipe.first?.isLetter == true ? recipe : nil
    }
}

public enum CatalogError: Error, CustomStringConvertible, Equatable {
    case unreachable(String)
    case refused(Int)
    case unexpected

    public var description: String {
        switch self {
        case .unreachable(let why): return L("The online catalogue could not be reached: \(why)", "Der Online-Katalog war nicht erreichbar: \(why)")
        case .refused(let status):
            return status == 429
                ? L("Too many requests to the online catalogue. Try again later.", "Zu viele Anfragen an den Online-Katalog. Später noch einmal versuchen.")
                : L("The online catalogue answered with an error (\(status)).", "Der Online-Katalog hat mit einem Fehler geantwortet (\(status)).")
        case .unexpected: return L("The online catalogue sent an answer this version does not understand.", "Der Online-Katalog hat eine Antwort geschickt, die diese Fassung nicht versteht.")
        }
    }
}

/// Spricht mit dem Katalogdienst des Projekts. Dorthin gehen nur Suchbegriffe, App-Kennungen, Rückmeldungen und –
/// wenn nicht abgestellt – die beiden Zählmeldungen ohne Kennung; nie der Meta-Token, nie etwas über das Konto
/// oder das Gerät.
public struct CatalogClient: Sendable {
    public static let defaultBase = URL(string: "https://avpplay.martek.de")!
    public let base: URL
    let session: URLSession

    public init(base: URL = CatalogClient.defaultBase, session: URLSession = .shared) {
        self.base = base
        self.session = session
    }

    /// Der Dienst, mit dem dieses Programm spricht: der des Projekts, oder der aus `AVPPLAY_CATALOG` (ein Probelauf
    /// gegen einen eigenen).
    public static var configured: CatalogClient {
        if let custom = ProcessInfo.processInfo.environment["AVPPLAY_CATALOG"], let url = URL(string: custom) { return CatalogClient(base: url) }
        return CatalogClient()
    }

    private func request(_ path: String, query: [URLQueryItem] = []) -> URLRequest {
        var parts = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query }
        var r = URLRequest(url: parts.url!)
        r.timeoutInterval = 20
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }

    private func send(_ request: URLRequest, expecting: Int) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode else { throw CatalogError.unexpected }
            guard status == expecting else { throw CatalogError.refused(status) }
            return data
        } catch let error as CatalogError {
            throw error
        } catch {
            throw CatalogError.unreachable(error.localizedDescription)
        }
    }

    /// Eine Seite des Katalogs.
    public struct Page: Sendable {
        public var games: [CatalogGame]
        /// Gibt es danach eine weitere Seite?
        public var more: Bool
        /// Wie viele Spiele insgesamt passen; `nil`, wenn der Dienst es nicht sagt.
        public var total: Int?
    }

    /// Eine Seite der Liste: alle Quest-Titel, die der Dienst kennt, Geprüftes zuerst. Mit Suchbegriff sucht der
    /// Dienst auch dort, wo er neue Spiele kennenlernt.
    public func catalog(query: String = "", page: Int = 0) async throws -> Page {
        var items = [URLQueryItem(name: "page", value: String(max(0, page)))]
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { items.append(URLQueryItem(name: "q", value: String(q.prefix(80)))) }
        return try await fetchPage(items)
    }

    /// So viele Kennungen nimmt der Dienst in einer Anfrage an.
    public static let idsPerRequest = 100

    /// Teilt Kennungen in Anfragen auf, die der Dienst annimmt; was keine Kennung ist, fällt weg.
    static func batches(of appIds: [String], size: Int = idsPerRequest, valid: (String) -> Bool = CatalogGame.isIdentifier) -> [[String]] {
        let ids = appIds.filter(valid)
        return stride(from: 0, to: ids.count, by: max(1, size)).map { Array(ids[$0..<min($0 + size, ids.count)]) }
    }

    /// Genau diese Spiele – für das, was schon auf dem Mac liegt oder gemerkt ist. Der Dienst nimmt höchstens 100
    /// Kennungen auf einmal; bei mehr wird in mehreren Anfragen gefragt. Bis 1.1.0 fiel alles nach den ersten 100
    /// weg: Wer viele Favoriten hatte, sah unter dem Filter „Favoriten“ nur einen Teil davon.
    public func games(appIds: [String]) async throws -> [CatalogGame] {
        var found: [CatalogGame] = []
        for ids in CatalogClient.batches(of: appIds) {
            found += try await fetchPage([URLQueryItem(name: "ids", value: ids.joined(separator: ","))]).games
        }
        return found
    }

    private func fetchPage(_ items: [URLQueryItem]) async throws -> Page {
        struct Answer: Decodable { let games: [CatalogGame]; let more: Bool; let total: Int? }
        let data = try await send(request("api/v1/catalog", query: items), expecting: 200)
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else { throw CatalogError.unexpected }
        return Page(games: answer.games.filter(\.isSane), more: answer.more, total: answer.total)
    }

    public func game(appId: String) async throws -> CatalogGame {
        guard CatalogGame.isIdentifier(appId) else { throw CatalogError.unexpected }
        let data = try await send(request("api/v1/games/\(appId)"), expecting: 200)
        guard let game = try? JSONDecoder().decode(CatalogGame.self, from: data), game.isSane, game.appId == appId else {
            throw CatalogError.unexpected
        }
        return game
    }

    /// Genau diese Spiele aus der Steam-Liste des Dienstes, nach Steam-App-ID – für die Steam-Spiele, die der Nutzer
    /// besitzt. Spiele, die die Liste nicht kennt, fehlen in der Antwort. Höchstens 100 Kennungen je Anfrage.
    /// Ein Dienst ohne Steam-Liste (vor 2026-10-17) antwortet mit `CatalogError.refused(404)`.
    public func steamGames(appIds: [String]) async throws -> [SteamCatalogGame] {
        struct Answer: Decodable { let games: [SteamCatalogGame] }
        var found: [SteamCatalogGame] = []
        for ids in CatalogClient.batches(of: appIds, valid: SteamCatalogGame.isIdentifier) {
            let data = try await send(request("api/v1/steam", query: [URLQueryItem(name: "ids", value: ids.joined(separator: ","))]), expecting: 200)
            guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else { throw CatalogError.unexpected }
            found += answer.games.filter { $0.isSane && ids.contains($0.appId) }
        }
        return found
    }

    /// Eine Seite der Steam-Liste.
    public struct SteamPage: Sendable {
        public var games: [SteamCatalogGame]
        /// Gibt es danach eine weitere Seite?
        public var more: Bool
        /// Wie viele Spiele insgesamt passen; `nil`, wenn der Dienst es nicht sagt.
        public var total: Int?
    }

    /// Eine Seite der ganzen Steam-Liste (60 Spiele), Geprüftes zuerst – alle Steam-Spiele mit Android-Fassung, die das
    /// Projekt kennt, ob der Nutzer sie besitzt oder nicht. Mit Suchbegriff nur die passenden (Titel, Paket, App-ID).
    /// Ein Dienst ohne Steam-Liste antwortet mit `CatalogError.refused(404)`.
    public func steamCatalog(query: String = "", page: Int = 0) async throws -> SteamPage {
        struct Answer: Decodable { let games: [SteamCatalogGame]; let more: Bool; let total: Int? }
        var items = [URLQueryItem(name: "page", value: String(max(0, page)))]
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { items.append(URLQueryItem(name: "q", value: String(q.prefix(80)))) }
        let data = try await send(request("api/v1/steam", query: items), expecting: 200)
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else { throw CatalogError.unexpected }
        return SteamPage(games: answer.games.filter(\.isSane), more: answer.more, total: answer.total)
    }

    /// Ein Spiel der Steam-Liste. `CatalogError.refused(404)`, wenn die Liste es nicht kennt.
    public func steamGame(appId: String) async throws -> SteamCatalogGame {
        guard SteamCatalogGame.isIdentifier(appId) else { throw CatalogError.unexpected }
        let data = try await send(request("api/v1/steam/\(appId)"), expecting: 200)
        guard let game = try? JSONDecoder().decode(SteamCatalogGame.self, from: data), game.isSane, game.appId == appId else {
            throw CatalogError.unexpected
        }
        return game
    }

    /// Größer ist kein Titelbild des Dienstes; was mehr liefert, wird nicht angenommen.
    static let maxCoverBytes = 1_000_000

    /// Das Titelbild, das der Dienst für ein Spiel bereithält (`CatalogGame.cover`). `nil`, wenn er keins hat, nicht
    /// erreichbar ist oder etwas anderes als ein Bild in dieser Größe und Form schickt. `square`: das quadratische
    /// daneben, für das Icon des installierten Spiels.
    public func cover(appId: String, square: Bool = false) async -> Data? {
        guard CatalogGame.isIdentifier(appId) else { return nil }
        var r = request("api/v1/covers/\(appId)", query: square ? [URLQueryItem(name: "shape", value: "square")] : [])
        r.setValue("image/jpeg", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: r), let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("image/") == true,
              data.count <= CatalogClient.maxCoverBytes, let size = StoreArt.pixelSize(data),
              square ? StoreArt.isSquareCover(width: size.width, height: size.height) : size.width > size.height else { return nil }
        return data
    }

    private func post<Body: Encodable>(_ path: String, _ body: Body) async throws {
        var r = request(path)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONEncoder().encode(body)
        _ = try await send(r, expecting: 202)
    }

    public func send(_ feedback: CatalogFeedback) async throws { try await post("api/v1/feedback", feedback) }

    /// Eine Rückmeldung zur Steam-Fassung eines Spiels: Sie geht an die Steam-Liste des Dienstes (`appId` von
    /// `feedback` wird dafür ersetzt). Ein Dienst ohne Steam-Liste lehnt die Kennung ab (400); dann geht sie wie bis
    /// 1.2.x an die Meta-Seite desselben Spiels, mit `CatalogFeedback.steamMark` vor dem Kommentar – sofern es eine
    /// gibt. Der Dienst mit Steam-Liste holt solche Meldungen später selbst herüber.
    public func sendSteam(_ feedback: CatalogFeedback, steamAppId: String, metaAppId: String?) async throws {
        guard let key = SteamCatalogGame.serviceKey(steamAppId: steamAppId) else { throw CatalogError.unexpected }
        var steam = feedback
        steam.appId = key
        do {
            try await send(steam)
        } catch CatalogError.refused(let status) where status == 400 {
            guard let meta = metaAppId, CatalogGame.isIdentifier(meta) else { throw CatalogError.refused(status) }
            var old = feedback
            old.appId = meta
            old.comment = String((CatalogFeedback.steamMark + feedback.comment).trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000))
            try await send(old)
        }
    }

    /// „Diese Kopie ist heute in Gebrauch“ – höchstens einmal am Tag, siehe `UsagePing`.
    public func send(_ ping: UsagePing) async throws { try await post("api/v1/ping", ping) }

    /// „Dieses Spiel wurde installiert“ – einmal pro Spiel; `game` kommt aus `UsagePing.gameKey`.
    public func countInstall(of game: String) async throws { try await post("api/v1/installs", ["appId": game]) }

    /// Die Summen über alle geteilten Fingerabdrücke (`s2-unlock`).
    public func fingerprintSummary() async throws -> FingerprintSummary {
        try JSONDecoder().decode(FingerprintSummary.self, from: try await send(request("api/v1/fingerprints/summary"), expecting: 200))
    }

    /// Der Fingerabdruck eines Spiels, nur wenn der Nutzer das Teilen eingeschaltet hat – einmal pro Build.
    public func share(_ fingerprint: SharedFingerprint, game: String, versionCode: Int64) async throws {
        struct Body: Encodable { var appId: String; var versionCode: Int64; var fingerprint: SharedFingerprint }
        try await post("api/v1/fingerprints", Body(appId: game, versionCode: versionCode, fingerprint: fingerprint))
    }
}

import Foundation

/// Ein Spiel aus dem Online-Katalog: ein Titel aus dem Meta-Store, was über seinen neuesten Build bekannt ist und
/// was das Projekt und andere Nutzer dazu sagen. Der Katalog liefert nur Namen und Kennungen – nie Spielinhalte,
/// nie eine Adresse, von der geladen würde. Geladen wird ausschließlich bei Meta, mit dem Konto des Nutzers.
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

/// Spricht mit dem Katalogdienst des Projekts. Dorthin gehen nur Suchbegriffe, App-Kennungen und Rückmeldungen;
/// nie der Meta-Token, nie etwas über das Konto oder das Gerät.
public struct CatalogClient: Sendable {
    public static let defaultBase = URL(string: "https://avpplay.martek.de")!
    public let base: URL
    let session: URLSession

    public init(base: URL = CatalogClient.defaultBase, session: URLSession = .shared) {
        self.base = base
        self.session = session
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

    /// Genau diese Spiele (höchstens 100) – für das, was schon auf dem Mac liegt oder gemerkt ist.
    public func games(appIds: [String]) async throws -> [CatalogGame] {
        let ids = appIds.filter(CatalogGame.isIdentifier).prefix(100)
        guard !ids.isEmpty else { return [] }
        return try await fetchPage([URLQueryItem(name: "ids", value: ids.joined(separator: ","))]).games
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

    public func send(_ feedback: CatalogFeedback) async throws {
        var r = request("api/v1/feedback")
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONEncoder().encode(feedback)
        _ = try await send(r, expecting: 202)
    }
}

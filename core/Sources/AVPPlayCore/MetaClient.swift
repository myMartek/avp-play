import Foundation

public enum MetaError: Error, CustomStringConvertible, Equatable {
    /// Meta nimmt den Token nicht an (abgelaufen, unvollständig, widerrufen).
    case tokenRejected(String)
    case api(status: Int, message: String)
    /// Die Download-Adresse liefert die Datei nicht aus (nicht im Besitz oder nicht sichtbar).
    case denied(status: Int)
    case unexpected(status: Int)
    case transport(String)
    case missingAppId

    public var description: String {
        switch self {
        case .tokenRejected(let m): return L("Meta rejected the token (\(m)). Please sign in again.", "Meta lehnt den Token ab (\(m)). Bitte neu anmelden.")
        case .api(let s, let m): return L("Meta responded with an error (HTTP \(s)): \(m)", "Meta antwortet mit einem Fehler (HTTP \(s)): \(m)")
        case .denied(let s): return L("Meta won't deliver this file (HTTP \(s)).", "Meta liefert diese Datei nicht aus (HTTP \(s)).")
        case .unexpected(let s): return L("Unexpected response from Meta (HTTP \(s)).", "Unerwartete Antwort von Meta (HTTP \(s)).")
        case .transport(let m): return L("Connection error: \(m)", "Verbindungsfehler: \(m)")
        case .missingAppId:
            return L("The recipe has no store app ID; ownership can't be checked.",
                     "Im Rezept fehlt die Store-App-ID; der Besitz kann nicht geprüft werden.")
        }
    }
}

/// Alle Abfragen an Meta. Der Token geht ausschließlich als Authorization-Header an
/// `graph.oculus.com` und `securecdn.oculus.com` – nie in eine URL, nie an einen anderen Host.
public struct MetaClient: Sendable {
    public static let graphHost = "graph.oculus.com"
    public static let downloadHost = "securecdn.oculus.com"

    private let token: String
    private let session: URLSession

    public init(token: String) {
        self.token = token
        self.session = URLSession(configuration: MetaClient.configuration())
    }

    static func configuration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.urlCache = nil
        c.httpShouldSetCookies = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 60
        return c
    }

    // MARK: Konto, Besitz, Käufe (graph.oculus.com)

    /// Prüft den Token und liefert die Nutzer-ID. Vor jeder Abfrage an die Download-Seite aufrufen.
    public func me() async throws -> String {
        struct Me: Decodable { let id: String }
        return try decode(Me.self, from: try await graph(path: "/me", query: [URLQueryItem(name: "fields", value: "id")])).id
    }

    /// Besitzt das Konto diese App? (dokumentierte Abfrage `verify_entitlement`)
    public func ownsApp(appId: String, userId: String) async throws -> Bool {
        struct Answer: Decodable { let success: Bool }
        let data = try await graph(path: "/\(appId)/verify_entitlement", form: ["user_id": userId])
        return try decode(Answer.self, from: data).success
    }

    /// Der Build, den der Store für diese App gerade führt – für ein Spiel, das dem Konto gehört.
    ///
    /// Anders als die übrigen Abfragen hier steht diese in keiner Dokumentation für Entwickler: Es ist ein Feld
    /// des App-Eintrags, das Metas eigene Programme lesen. Der Nutzer hat ihr am 2026-10-11 zugestimmt, weil die
    /// öffentliche Versionsdatenbank Wochen zurückliegen kann (Walkabout 6.8 war im Store, dort noch nicht). Sie
    /// liest nur, nennt nichts als Kennung, Namen und Nummer eines Builds, und eine Antwort, die anders aussieht
    /// als erwartet, ist `nil` – „unbekannt“ –, kein Anlass für weitere Versuche.
    /// Die hinterlegte Abfrage „aktuelle Fassung einer App“ in Metas Abfragesprache, unter der Nummer, unter der
    /// sie auch die öffentliche Bibliothek OculusGraphQLApiLib (ComputerElite, `CurrentVersionOfApp`) stellt.
    static let currentVersionQuery = "1586217024733717"

    public func latestBuild(appId: String) async throws -> CatalogBuild? {
        try await builds(appId: appId).first
    }

    /// Alle Fassungen, die Metas Antwort auf dieselbe Abfrage nennt, die neueste zuerst – für die Wahl der
    /// Fassung. Es ist dieselbe eine Anfrage wie für `latestBuild`; gelesen werden dieselben drei Angaben je Build.
    public func builds(appId: String) async throws -> [CatalogBuild] {
        guard CatalogGame.isIdentifier(appId) else { return [] }
        // Der Token geht wie überall im Kopf der Anfrage mit, nie in der Adresse und nicht im Rumpf.
        let data = try await graph(path: "/graphql", form: ["doc_id": MetaClient.currentVersionQuery, "variables": "{\"id\":\"\(appId)\"}"])
        return MetaClient.builds(inAnswer: data)
    }

    /// Liest aus Metas Antwort den Build mit der höchsten Nummer: `data.node.supportedBinaries.edges[].node` mit
    /// `id`, `version`, `versionCode`. Alles andere an der Antwort bleibt ungelesen.
    static func newestBuild(inAnswer data: Data) -> CatalogBuild? { builds(inAnswer: data).first }

    /// Alle brauchbaren Builds der Antwort, je Versionsnummer einer, die höchste Nummer zuerst.
    static func builds(inAnswer data: Data) -> [CatalogBuild] {
        struct Answer: Decodable {
            struct Binary: Decodable {
                let id: String?
                let version: String?
                let versionCode: Int?
            }
            struct Edge: Decodable { let node: Binary? }
            struct Binaries: Decodable { let edges: [Edge]? }
            struct Node: Decodable { let supportedBinaries: Binaries? }
            struct Payload: Decodable { let node: Node? }
            let data: Payload?
        }
        guard let edges = (try? JSONDecoder().decode(Answer.self, from: data))?.data?.node?.supportedBinaries?.edges else { return [] }
        let builds = edges.compactMap { edge -> CatalogBuild? in
            guard let b = edge.node, let id = b.id, CatalogGame.isIdentifier(id), let code = b.versionCode, code > 0 else { return nil }
            let build = CatalogBuild(buildId: id, version: String((b.version ?? "\(code)").prefix(60)), versionCode: code, fileName: nil)
            return build.isSane ? build : nil
        }
        var seen = Set<Int>()
        return builds.sorted { $0.versionCode > $1.versionCode }.filter { seen.insert($0.versionCode).inserted }
    }

    /// Die hinterlegte Abfrage „Details eines Builds“ in Metas Abfragesprache, unter der Nummer, unter der sie die
    /// öffentliche Bibliothek OculusGraphQLApiLib (ComputerElite, `GetBinaryDetails`) stellt.
    static let binaryDetailsQuery = "4734929166632773"

    /// Die Dateien eines Builds, wie Metas Build-Details sie nennen: das APK, das Haupt-OBB und die weiteren Dateien.
    ///
    /// Wie `builds(appId:)` steht auch diese Abfrage in keiner Dokumentation für Entwickler. Der Nutzer hat ihr am
    /// 2026-10-15 zugestimmt – als Ausweg, wenn Metas Werkzeug einem Konto nach vielen Downloads nur noch
    /// „Cannot find apk with ID“ antwortet, die direkte Adresse aber weiter ausliefert. Gelesen werden je Datei nur
    /// Kennung, Name und Größe; eine Antwort, die anders aussieht als erwartet, ergibt eine leere Liste.
    public func buildFiles(buildId: String) async throws -> [ListedFile] {
        guard CatalogGame.isIdentifier(buildId) else { return [] }
        let data = try await graph(path: "/graphql", form: ["doc_id": MetaClient.binaryDetailsQuery,
                                                             "variables": "{\"binaryID\":\"\(buildId)\"}"])
        return MetaClient.files(inBinaryDetails: data, buildId: buildId)
    }

    /// Liest `data.node` (der Build selbst, seine Kennung ist die des APKs) mit `file_name`, `size`, `obb_binary`
    /// und `asset_files` (als `nodes` oder `edges`). Ohne APK, oder für einen anderen Build, ist die Liste leer.
    static func files(inBinaryDetails data: Data, buildId: String) -> [ListedFile] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any], let binary = payload["node"] as? [String: Any],
              (binary["id"] as? String) == buildId, let apk = listedFile(binary, kind: "APK") else { return [] }
        var files = [apk]
        if let obb = binary["obb_binary"] as? [String: Any], let file = listedFile(obb, kind: "OBB") { files.append(file) }
        let assets = binary["asset_files"] as? [String: Any]
        let nodes = (assets?["nodes"] as? [[String: Any]])
            ?? (assets?["edges"] as? [[String: Any]])?.compactMap { $0["node"] as? [String: Any] } ?? []
        var seen = Set(files.map(\.name))
        for node in nodes {
            if let file = listedFile(node, kind: "ASSET"), seen.insert(file.name).inserted { files.append(file) }
        }
        return files
    }

    private static func listedFile(_ object: [String: Any], kind: String) -> ListedFile? {
        guard let id = object["id"] as? String, CatalogGame.isIdentifier(id),
              let name = object["file_name"] as? String, !name.isEmpty, Recipe.isSafeName(name) else { return nil }
        let bytes = (object["size"] as? String).flatMap { Int64($0) } ?? (object["size"] as? NSNumber)?.int64Value
        let size = bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
        return ListedFile(name: name, id: id, kind: kind, sizeText: size)
    }

    /// Die hinterlegte Abfrage „aktive Berechtigungen des Kontos“, unter der Nummer, unter der Metas Horizon-App
    /// (Android, `OCLibraryActiveEntitlementsListQuery`) ihre Bibliothek lädt.
    static let libraryQuery = "35577972275181723"

    /// Die Bibliothek des Kontos: alle Apps, auf die es gerade eine Berechtigung hat – gekauft, im Abo, geschenkt,
    /// vorbestellt –, wie Metas Horizon-App sie zeigt. Für den Filter „Im Besitz“.
    ///
    /// Wie `builds(appId:)` steht auch diese Abfrage in keiner Dokumentation für Entwickler. Der Nutzer hat ihr am
    /// 2026-10-17 zugestimmt (Issue #25), als zweiter solcher Abfrage. Sie liest nur; je App werden Kennung, Name und
    /// Grund der Berechtigung übernommen. Eine Seite, die anders aussieht als erwartet, beendet die Abfrage mit einem
    /// Fehler – keine weiteren Versuche, und keine halbe Liste, die als ganze gälte.
    public func library(userId: String, pageSize: Int = 50, maxPages: Int = 40) async throws -> [LibraryApp] {
        guard CatalogGame.isIdentifier(userId) else { throw MetaError.unexpected(status: 200) }
        var apps: [LibraryApp] = []
        var cursor: String?
        for _ in 0..<maxPages {
            var variables: [String: Any] = [
                "id": userId, "count": pageSize, "platform": "ANDROID_6DOF", "orderBy": "display_name_alphabetical",
                // Was die Horizon-App selbst ausblendet: Umgebungen, Interna, die Tastatur.
                "excludeCategories": ["ENVIRONMENTS", "INTERNAL", "TRACKED_KEYBOARD"],
            ]
            if let cursor { variables["cursor"] = cursor }
            let json = String(decoding: try JSONSerialization.data(withJSONObject: variables, options: [.sortedKeys]), as: UTF8.self)
            let data = try await graph(path: "/graphql", form: ["doc_id": MetaClient.libraryQuery, "variables": json])
            guard let page = MetaClient.libraryPage(inAnswer: data) else { throw MetaError.unexpected(status: 200) }
            apps += page.apps
            guard let next = page.next else { return MetaClient.unique(apps) }
            cursor = next
        }
        // So viele Seiten hat kein Konto; was danach käme, fehlte. Lieber keine Liste als eine falsche.
        throw MetaError.unexpected(status: 200)
    }

    /// Eine Seite der Bibliothek: `data.node.app_entitlements` mit `edges[].node.item` (`id`, `display_name`,
    /// `entitlement.grant_reason`) und `page_info`. `next` ist die Marke der Folgeseite, `nil` am Ende.
    /// `nil` für die ganze Seite, wenn sie nicht so aussieht – auch bei einer Folgeseite ohne brauchbare Marke.
    static func libraryPage(inAnswer data: Data) -> (apps: [LibraryApp], next: String?)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any], let node = payload["node"] as? [String: Any],
              let connection = node["app_entitlements"] as? [String: Any],
              let edges = connection["edges"] as? [[String: Any]],
              let info = connection["page_info"] as? [String: Any] else { return nil }
        var apps: [LibraryApp] = []
        for edge in edges {
            guard let item = (edge["node"] as? [String: Any])?["item"] as? [String: Any] else { continue }
            guard let id = item["id"] as? String, CatalogGame.isIdentifier(id) else { continue }
            let title = (item["display_name"] as? String).map { String($0.prefix(200)) } ?? ""
            let grant = ((item["entitlement"] as? [String: Any])?["grant_reason"] as? String).flatMap { reason in
                reason.count <= 64 && reason.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_") } ? reason : nil
            }
            apps.append(LibraryApp(appId: id, title: title, grant: grant))
        }
        guard (info["has_next_page"] as? Bool) == true else { return (apps, nil) }
        guard let next = info["end_cursor"] as? String, isPageMark(next) else { return nil }
        return (apps, next)
    }

    /// Eine Seitenmarke ist eine Zeile aus Buchstaben, Ziffern und `-_=`, wie Meta sie schickt; anderes geht nicht zurück.
    static func isPageMark(_ s: String) -> Bool {
        (1...2048).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_=".contains($0)) }
    }

    private static func unique(_ apps: [LibraryApp]) -> [LibraryApp] {
        var seen = Set<String>()
        return apps.filter { seen.insert($0.appId).inserted }
    }

    /// Die vom Store bestätigten Käufe innerhalb einer App (SKUs). Abgelaufene Käufe zählen nicht.
    public func purchases(appId: String, now: Date = Date()) async throws -> [String] {
        struct Page: Decodable {
            struct Row: Decodable {
                struct Item: Decodable { let sku: String? }
                let expiration_time: Int?
                let item: Item?
            }
            struct Paging: Decodable { let next: String? }
            let data: [Row]
            let paging: Paging?
        }
        var skus: [String] = []
        var next: URL? = MetaClient.graphURL(path: "/\(appId)/viewer_purchases", query: [
            URLQueryItem(name: "fields", value: "expiration_time,item{sku}"),
            URLQueryItem(name: "limit", value: "200"),
        ])
        var pages = 0
        while let url = next, pages < 25 {
            pages += 1
            let page = try decode(Page.self, from: try await send(MetaClient.request(url, token: token)))
            for row in page.data {
                guard let sku = row.item?.sku, MetaClient.isPlainSKU(sku) else { continue }
                if let exp = row.expiration_time, exp > 0, Double(exp) < now.timeIntervalSince1970 { continue }
                skus.append(sku)
            }
            next = page.paging?.next.flatMap(MetaClient.sanitizedNextPage)
        }
        return Array(Set(skus)).sorted()
    }

    /// Meta hängt an die Adresse der Folgeseite den Token als Parameter an. Der gehört nicht in eine URL:
    /// er wird entfernt, und die Seite wird nur verfolgt, wenn sie auf denselben Host zeigt.
    static func sanitizedNextPage(_ raw: String) -> URL? {
        guard var parts = URLComponents(string: raw), parts.scheme == "https", parts.host == graphHost else { return nil }
        parts.queryItems = parts.queryItems?.filter { $0.name.lowercased() != "access_token" }
        return parts.url
    }

    static func isPlainSKU(_ s: String) -> Bool {
        !s.isEmpty && s.count < 96 && s.allSatisfy { $0.isASCII && !$0.isWhitespace && !$0.isNewline && $0 != "\0" }
    }

    // MARK: Download (securecdn.oculus.com)

    public struct DownloadOutcome: Sendable, Equatable {
        public let bytesReceived: Int64
        public let totalSize: Int64?
        public let resumed: Bool
    }

    /// Lädt eine Datei gezielt über ihre ID. Mit `resumeFrom` wird ein begonnener Download fortgesetzt.
    /// Liefert Meta etwas anderes als die Datei (kein HTTP 200/206), wird nichts geschrieben.
    public func download(id: String, to destination: URL, resumeFrom offset: Int64 = 0,
                         progress: (@Sendable (Int64, Int64?) -> Void)? = nil) async throws -> DownloadOutcome {
        precondition(!id.isEmpty && id.allSatisfy(\.isNumber), L("The file ID must be numeric", "Datei-ID muss numerisch sein"))
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = MetaClient.downloadHost
        parts.path = "/binaries/download/"
        parts.queryItems = [URLQueryItem(name: "id", value: id)]
        var request = MetaClient.request(parts.url!, token: token)
        request.timeoutInterval = 120
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }

        let delegate = DownloadDelegate(destination: destination, offset: offset, progress: progress,
                                        authorizedHost: MetaClient.downloadHost)
        let session = URLSession(configuration: MetaClient.configuration(), delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<DownloadOutcome, Error>) in
                delegate.continuation = c
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: Was eine Datei ist, ohne sie zu laden

    /// Was der Store über eine Datei sagt, bevor ihr Inhalt kommt: ihre Länge und – wenn die Auslieferung eine
    /// nennt – eine Prüfsumme ihres Inhalts. Eine Anfrage nach dem ersten Byte; mehr wird nicht gelesen.
    public struct ContentIdentity: Sendable, Equatable {
        public var length: Int64?
        public var md5: String?
        public var etag: String?
        /// Die Namen aller Kopfzeilen der Antwort (ohne Werte) – um zu sehen, was die Auslieferung überhaupt nennt.
        public var headerNames: [String]
    }

    public func identity(id: String) async throws -> ContentIdentity {
        precondition(!id.isEmpty && id.allSatisfy(\.isNumber), L("The file ID must be numeric", "Datei-ID muss numerisch sein"))
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = MetaClient.downloadHost
        parts.path = "/binaries/download/"
        parts.queryItems = [URLQueryItem(name: "id", value: id)]
        var request = MetaClient.request(parts.url!, token: token)
        request.timeoutInterval = 60
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let delegate = IdentityDelegate(authorizedHost: MetaClient.downloadHost)
        let session = URLSession(configuration: MetaClient.configuration(), delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<ContentIdentity, Error>) in
            delegate.continuation = c
            session.dataTask(with: request).resume()
        }
    }

    /// Der Anfang einer Datei und ihre ganze Länge, in einer Anfrage: um zu sehen, ob sie dieselbe ist wie eine,
    /// die schon da liegt, ohne sie zu laden.
    public func head(id: String, bytes: Int) async throws -> (total: Int64?, data: Data) {
        precondition(!id.isEmpty && id.allSatisfy(\.isNumber), L("The file ID must be numeric", "Datei-ID muss numerisch sein"))
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = MetaClient.downloadHost
        parts.path = "/binaries/download/"
        parts.queryItems = [URLQueryItem(name: "id", value: id)]
        var request = MetaClient.request(parts.url!, token: token)
        request.timeoutInterval = 60
        request.setValue("bytes=0-\(max(bytes, 1) - 1)", forHTTPHeaderField: "Range")
        let delegate = IdentityDelegate(authorizedHost: MetaClient.downloadHost, collect: max(bytes, 1))
        let session = URLSession(configuration: MetaClient.configuration(), delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let identity = try await withCheckedThrowingContinuation { (c: CheckedContinuation<ContentIdentity, Error>) in
            delegate.continuation = c
            session.dataTask(with: request).resume()
        }
        return (identity.length, delegate.body)
    }

    // MARK: Hilfen

    static func graphURL(path: String, query: [URLQueryItem] = []) -> URL {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = graphHost
        parts.path = path
        if !query.isEmpty { parts.queryItems = query }
        return parts.url!
    }

    static func request(_ url: URL, token: String) -> URLRequest {
        precondition(url.scheme == "https" && (url.host == graphHost || url.host == downloadHost),
                     L("The token is only ever sent to Meta's own hosts", "Der Token wird nur an Metas eigene Hosts geschickt"))
        var r = URLRequest(url: url)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }

    func graph(path: String, query: [URLQueryItem] = [], form: [String: String]? = nil) async throws -> Data {
        var request = MetaClient.request(MetaClient.graphURL(path: path, query: query), token: token)
        if let form {
            request.httpMethod = "POST"
            var body = URLComponents()
            body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.httpBody = body.percentEncodedQuery?.data(using: .utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MetaError.transport(Redaction.redact(error.localizedDescription))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            struct Failure: Decodable {
                struct Body: Decodable { let message: String?; let code: Int? }
                let error: Body
            }
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            let message = Redaction.redact(failure?.error.message ?? L("no details given", "ohne Angabe"))
            if status == 401 || failure?.error.code == 190 { throw MetaError.tokenRejected(message) }
            throw MetaError.api(status: status, message: message)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch {
            throw MetaError.api(status: 200, message: L("the response doesn't have the expected form", "Antwort hat nicht die erwartete Form"))
        }
    }
}

/// Schreibt die Antwort der Download-Adresse in eine Datei, sofern sie wirklich die Datei ist.
final class DownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL
    private let offset: Int64
    private let progress: (@Sendable (Int64, Int64?) -> Void)?
    /// Der eine Host, an den ein Authorization-Header mitgehen darf; `nil` bei freien Downloads.
    private let authorizedHost: String?
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var total: Int64?
    private var resumed = false
    private var failure: Error?
    var continuation: CheckedContinuation<MetaClient.DownloadOutcome, Error>?

    init(destination: URL, offset: Int64, progress: (@Sendable (Int64, Int64?) -> Void)?, authorizedHost: String?) {
        self.destination = destination
        self.offset = offset
        self.progress = progress
        self.authorizedHost = authorizedHost
    }

    /// `Content-Range: bytes 0-4095/43406683` -> 43406683
    static func totalSize(contentRange: String?) -> Int64? {
        guard let value = contentRange, let slash = value.lastIndex(of: "/") else { return nil }
        return Int64(value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        do {
            switch status {
            case 200:
                // vollständige Datei (auch wenn eine Fortsetzung erbeten war): von vorn schreiben
                FileManager.default.createFile(atPath: destination.path, contents: nil)
                handle = try FileHandle(forWritingTo: destination)
                total = response.expectedContentLength > 0 ? response.expectedContentLength : nil
            case 206 where offset > 0:
                handle = try FileHandle(forWritingTo: destination)
                try handle?.seekToEnd()
                resumed = true
                received = offset
                total = DownloadDelegate.totalSize(contentRange: http?.value(forHTTPHeaderField: "Content-Range"))
            case 401, 403, 404:
                throw MetaError.denied(status: status)
            default:
                throw MetaError.unexpected(status: status)
            }
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
            received += Int64(data.count)
            progress?(received, total)
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        let c = continuation
        continuation = nil
        if let failure {
            c?.resume(throwing: failure)
        } else if let error {
            c?.resume(throwing: (error as? CancellationError) ?? MetaError.transport(Redaction.redact(error.localizedDescription)))
        } else {
            c?.resume(returning: .init(bytesReceived: received, totalSize: total, resumed: resumed))
        }
    }

    /// Falls Meta weiterleitet: der Token wandert nicht zu einem anderen Host mit.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var next = request
        if authorizedHost == nil || next.url?.host != authorizedHost || next.url?.scheme != "https" {
            next.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(next)
    }
}

/// Liest die Kopfzeilen einer Antwort der Auslieferung und bricht ab, bevor Inhalt fließt.
private final class IdentityDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    var continuation: CheckedContinuation<MetaClient.ContentIdentity, Error>?
    let authorizedHost: String
    /// Wie viele Bytes des Inhalts mitgelesen werden (0: keine – die Antwort wird nach den Kopfzeilen beendet).
    let collect: Int
    private(set) var body = Data()
    private var pending: MetaClient.ContentIdentity?
    init(authorizedHost: String, collect: Int = 0) {
        self.authorizedHost = authorizedHost
        self.collect = collect
    }

    private func finish(_ result: Result<MetaClient.ContentIdentity, Error>) {
        guard let c = continuation else { return }
        continuation = nil
        c.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return finish(.failure(MetaError.unexpected(status: 0)))
        }
        completionHandler(collect > 0 && (http.statusCode == 200 || http.statusCode == 206) ? .allow : .cancel)
        switch http.statusCode {
        case 200, 206:
            func header(_ name: String) -> String? {
                http.value(forHTTPHeaderField: name).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
            }
            let length = DownloadDelegate.totalSize(contentRange: http.value(forHTTPHeaderField: "Content-Range"))
                ?? (http.statusCode == 200 && http.expectedContentLength > 0 ? http.expectedContentLength : nil)
            let identity = MetaClient.ContentIdentity(length: length, md5: header("x-fb-content-md5") ?? header("Content-MD5"),
                                                      etag: header("ETag"),
                                                      headerNames: http.allHeaderFields.keys.compactMap { $0 as? String }.sorted())
            if collect > 0 { pending = identity } else { finish(.success(identity)) }
        case 401, 403, 404: finish(.failure(MetaError.denied(status: http.statusCode)))
        default: finish(.failure(MetaError.unexpected(status: http.statusCode)))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard collect > 0 else { return }
        body.append(data.prefix(max(0, collect - body.count)))
        // Eine Auslieferung, die den Bereich übergeht und die ganze Datei schickt: nach dem Verlangten ist Schluss.
        if body.count >= collect, let identity = pending {
            pending = nil
            dataTask.cancel()
            finish(.success(identity))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, (error as NSError).code != NSURLErrorCancelled {
            return finish(.failure(MetaError.transport(Redaction.redact(error.localizedDescription))))
        }
        if let identity = pending {
            pending = nil
            finish(.success(identity))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var next = request
        if next.url?.host != authorizedHost || next.url?.scheme != "https" { next.setValue(nil, forHTTPHeaderField: "Authorization") }
        completionHandler(next)
    }
}

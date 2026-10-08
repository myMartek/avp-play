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

    private func graph(path: String, query: [URLQueryItem] = [], form: [String: String]? = nil) async throws -> Data {
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

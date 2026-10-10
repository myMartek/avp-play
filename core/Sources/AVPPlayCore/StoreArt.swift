import Foundation
import ImageIO

/// Holt das quadratische Titelbild eines Spiels von dessen öffentlicher Store-Seite – das Bild, das auch
/// die Quest in der Bibliothek zeigt. Viele APKs enthalten selbst nur den Platzhalter ihrer Engine.
///
/// Die Abfrage läuft ohne Zugangsdaten: Die Seite ist öffentlich, und der Meta-Token geht nie an diesen Host.
/// Das Bild bleibt auf dem Rechner des Nutzers und wird nur in dessen eigenen Build eingebunden.
public struct StoreArt: Sendable {
    public init() {}

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// Bildadressen aus dem JSON-LD-Block der Store-Seite, in der Reihenfolge der Seite.
    static func imageURLs(inStorePage html: String) -> [URL] {
        guard let re = try? NSRegularExpression(pattern: #"<script type="application/ld\+json"[^>]*>(.*?)</script>"#,
                                                options: [.dotMatchesLineSeparators]) else { return [] }
        var out: [URL] = []
        for match in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range(at: 1), in: html),
                  let json = try? JSONSerialization.jsonObject(with: Data(html[range].utf8)) else { continue }
            let nodes: [Any] = (json as? [Any]) ?? ((json as? [String: Any])?["@graph"] as? [Any]) ?? [json]
            for case let node as [String: Any] in nodes {
                let images = (node["image"] as? [Any]) ?? node["image"].map { [$0] } ?? []
                for image in images {
                    let raw = (image as? String) ?? (image as? [String: Any]).flatMap { ($0["@id"] ?? $0["url"] ?? $0["contentUrl"]) as? String }
                    if let raw, let url = URL(string: raw), isAllowedImageHost(url) { out.append(url) }
                }
            }
        }
        return out
    }

    /// Bilder werden nur von Metas eigenen Auslieferungs-Hosts geladen.
    static func isAllowedImageHost(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host.hasSuffix(".oculuscdn.com") || host.hasSuffix(".fbcdn.net")
    }

    static func pixelSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    static func isSquareCover(width: Int, height: Int) -> Bool {
        width >= 512 && abs(width - height) * 50 <= width          // höchstens 2 % Abweichung
    }

    static func isLandscapeCover(width: Int, height: Int) -> Bool {
        width >= 1024 && height > 0 && width * 10 >= height * 15 && width * 10 <= height * 21   // 1,5 bis 2,1 zu 1
    }

    /// Das erste quadratische Bild der Store-Seite. `nil`, wenn es keins gibt oder die Seite nicht erreichbar ist.
    public func squareCover(appId: String) async -> Data? {
        await cover(appId: appId, accept: StoreArt.isSquareCover)
    }

    /// Das erste Titelbild im Querformat – für das Startfenster der App.
    public func landscapeCover(appId: String) async -> Data? {
        await cover(appId: appId, accept: StoreArt.isLandscapeCover)
    }

    /// Der Anfang der Store-Seite, bis einschließlich des Blocks mit den Bildadressen. Die Seite ist einige hundert
    /// Kilobyte groß, der Block steht in den ersten dreißig; danach wird nicht weitergelesen.
    static func pageHead(_ request: URLRequest, session: URLSession, limit: Int = 300_000) async -> String? {
        guard let (bytes, response) = try? await session.bytes(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        var data = Data()
        data.reserveCapacity(64_000)
        let opening = Data("application/ld+json".utf8), closing = Data("</script>".utf8)
        var seenAt: Int?
        do {
            for try await byte in bytes {
                data.append(byte)
                // Nur am Ende eines Tags nachsehen, nicht bei jedem Byte.
                if byte == 0x3E {
                    if seenAt == nil, let r = data.range(of: opening) { seenAt = r.upperBound }
                    if let from = seenAt, data.count - from >= closing.count, data.suffix(closing.count) == closing { break }
                }
                if data.count >= limit { break }
            }
        } catch { return nil }
        bytes.task.cancel()
        return String(decoding: data, as: UTF8.self)
    }

    func cover(appId: String, accept: (Int, Int) -> Bool) async -> Data? {
        guard !appId.isEmpty, appId.allSatisfy(\.isNumber),
              let page = URL(string: "https://www.meta.com/experiences/\(appId)/") else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: page)
        request.setValue(StoreArt.userAgent, forHTTPHeaderField: "User-Agent")
        guard let head = await StoreArt.pageHead(request, session: session) else { return nil }
        // Die ersten Bilder der Seite sind die Titelbilder (quer, quadratisch, hoch), danach folgen Screenshots.
        for url in StoreArt.imageURLs(inStorePage: head).prefix(4) {
            guard let (image, imageResponse) = try? await session.data(from: url),
                  (imageResponse as? HTTPURLResponse)?.statusCode == 200,
                  let size = StoreArt.pixelSize(image) else { continue }
            if accept(size.width, size.height) { return image }
        }
        return nil
    }
}

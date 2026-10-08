import Foundation

/// Eine veröffentlichte Fassung des Programms, wie die Liste der Veröffentlichungen sie nennt.
public struct AppRelease: Sendable, Equatable {
    public var version: String
    /// Die Seite der Veröffentlichung, zum Nachlesen und als Ausweg, wenn das Programm sich nicht selbst ersetzen kann.
    public var page: URL
    public var notes: String
    public var image: URL
    public var imageSize: Int64?
    /// SHA-256 des Abbilds laut Liste. Schützt vor einem beschädigten Download – nicht vor einem gefälschten;
    /// dafür ist die Signaturprüfung da.
    public var imageSHA256: String?
}

public enum UpdateError: Error, CustomStringConvertible, Equatable {
    case feed(String)
    case download(String)
    case damaged
    case notTrusted(String)
    case notNewer(found: String, running: String)
    case cannotReplace(String)

    public var description: String {
        switch self {
        case .feed(let why):
            return L("The list of releases could not be read: \(why)", "Die Liste der Veröffentlichungen ließ sich nicht lesen: \(why)")
        case .download(let why):
            return L("The update could not be downloaded: \(why)", "Die neue Fassung ließ sich nicht laden: \(why)")
        case .damaged:
            return L("The downloaded update is damaged (size or checksum do not match). Nothing was installed.",
                     "Die geladene Fassung ist beschädigt (Größe oder Prüfsumme stimmen nicht). Es wurde nichts installiert.")
        case .notTrusted(let why):
            return L("The update was not installed because it could not be verified: \(why)",
                     "Die neue Fassung wurde nicht installiert, weil sie sich nicht prüfen ließ: \(why)")
        case .notNewer(let found, let running):
            return L("The download contains version \(found), which is not newer than the running \(running). Nothing was installed.",
                     "Der Download enthält Version \(found), die nicht neuer ist als die laufende \(running). Es wurde nichts installiert.")
        case .cannotReplace(let why):
            return L("The app could not replace itself: \(why)", "Das Programm konnte sich nicht selbst ersetzen: \(why)")
        }
    }
}

/// Neue Fassungen des Programms finden, prüfen und einspielen.
///
/// Vertraut wird allein Apples Codesignatur: Eine neue Fassung wird nur eingespielt, wenn sie von demselben
/// Entwicklerteam signiert ist wie das laufende Programm, von Apple beglaubigt wurde, dieselbe Kennung trägt
/// und eine höhere Versionsnummer hat. Woher die Datei kam und was die Liste über sie sagt, zählt dafür nicht –
/// wer die Liste oder den Download fälscht, hat damit noch keine gültige Signatur.
public enum Updater {
    public static let defaultFeed = URL(string: "https://api.github.com/repos/myMartek/avp-play/releases/latest")!

    // MARK: Liste

    /// Liest die Antwort von GitHubs „neueste Veröffentlichung“.
    public static func parseLatest(_ data: Data) throws -> AppRelease {
        struct Release: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: String; let size: Int64?; let digest: String? }
            let tag_name: String
            let html_url: String
            let body: String?
            let assets: [Asset]
        }
        guard let r = try? JSONDecoder().decode(Release.self, from: data) else {
            throw UpdateError.feed(L("unexpected answer", "unerwartete Antwort"))
        }
        guard let asset = r.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }),
              let image = URL(string: asset.browser_download_url), let page = URL(string: r.html_url) else {
            throw UpdateError.feed(L("the release has no disk image", "die Veröffentlichung enthält kein Abbild"))
        }
        let version = r.tag_name.hasPrefix("v") ? String(r.tag_name.dropFirst()) : r.tag_name
        guard version.range(of: #"^\d+(\.\d+){0,3}$"#, options: .regularExpression) != nil else {
            throw UpdateError.feed(L("unreadable version '\(r.tag_name)'", "unlesbare Version „\(r.tag_name)“"))
        }
        let sha = asset.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)).lowercased() : nil }
        return AppRelease(version: version, page: page, notes: r.body ?? "", image: image, imageSize: asset.size, imageSHA256: sha)
    }

    /// Ist `a` eine höhere Version als `b`? Verglichen wird Zahl für Zahl; fehlende Stellen zählen als null.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    public static func latest(feed: URL = defaultFeed) async throws -> AppRelease {
        if feed.isFileURL {
            guard let data = try? Data(contentsOf: feed) else { throw UpdateError.feed(feed.path) }
            return try parseLatest(data)
        }
        var request = URLRequest(url: feed)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateError.feed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            return try parseLatest(data)
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.feed(error.localizedDescription)
        }
    }

    // MARK: Signaturen

    /// Das Team in der Codesignatur; `nil` ohne Signatur oder bei einer Signatur ohne Identität („ad hoc“).
    public static func team(of url: URL) -> String? {
        let info = MetaTool.captureBoth(["/usr/bin/codesign", "-dv", "--verbose=2", url.path])
        let team = info.split(separator: "\n").first { $0.hasPrefix("TeamIdentifier=") }.map { String($0.dropFirst("TeamIdentifier=".count)) }
        guard let team, team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { return nil }
        return team
    }

    /// Prüft ein Programmpaket: unversehrt, vom erwarteten Team, von Apple beglaubigt, dieselbe Kennung und
    /// eine höhere Version als die laufende. Gibt die gefundene Version zurück.
    @discardableResult
    public static func verify(app: URL, team expected: String, bundleId: String, newerThan running: String) throws -> String {
        guard Toolchain.status(["/usr/bin/codesign", "--verify", "--deep", "--strict", app.path]) == 0 else {
            throw UpdateError.notTrusted(L("the signature is invalid", "die Signatur ist ungültig"))
        }
        guard let found = team(of: app), found == expected else {
            throw UpdateError.notTrusted(L("it is signed by a different developer", "sie ist von einem anderen Entwickler signiert"))
        }
        guard Toolchain.status(["/usr/bin/codesign", "--verify", "-R=notarized", "--check-notarization", app.path]) == 0 else {
            throw UpdateError.notTrusted(L("Apple has not notarised it", "Apple hat sie nicht beglaubigt"))
        }
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == bundleId,
              let version = info["CFBundleShortVersionString"] as? String else {
            throw UpdateError.notTrusted(L("it is a different app", "es ist ein anderes Programm"))
        }
        guard isNewer(version, than: running) else { throw UpdateError.notNewer(found: version, running: running) }
        return version
    }

    // MARK: Laden und Einspielen

    /// Lädt das Abbild und prüft Größe und Prüfsumme gegen die Liste.
    public static func download(_ release: AppRelease, to directory: URL) async throws -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("AVP-Play-\(release.version).dmg")
        try? fm.removeItem(at: target)
        do {
            if release.image.isFileURL {
                try fm.copyItem(at: release.image, to: target)
            } else {
                let (temp, response) = try await URLSession.shared.download(from: release.image)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw UpdateError.download("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                }
                try fm.moveItem(at: temp, to: target)
            }
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.download(error.localizedDescription)
        }
        if let size = release.imageSize, ContentStore.fileSize(target) != size {
            try? fm.removeItem(at: target)
            throw UpdateError.damaged
        }
        if let expected = release.imageSHA256, (try? Hashing.sha256(of: target)) != expected {
            try? fm.removeItem(at: target)
            throw UpdateError.damaged
        }
        return target
    }

    /// Kann das Programm an seinem Ort ersetzt werden? Nicht, wenn es aus dem geladenen Abbild oder von einem
    /// Ort läuft, an den macOS es zur Sicherheit verlegt hat – dann ist der Ort schreibgeschützt.
    public static func canReplace(app: URL) -> Bool {
        let path = app.resolvingSymlinksInPath().path
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") { return false }
        return FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path)
            && FileManager.default.isWritableFile(atPath: app.path)
    }

    /// Spielt die Fassung aus einem Abbild ein: einhängen, das Programm darin prüfen, daneben ablegen, noch
    /// einmal prüfen, dann tauschen. Schlägt irgendetwas fehl, bleibt das laufende Programm, wie es ist.
    /// - Returns: die eingespielte Version.
    @discardableResult
    public static func install(image: URL, replacing app: URL, team: String, bundleId: String, running: String) throws -> String {
        let fm = FileManager.default
        guard canReplace(app: app) else {
            throw UpdateError.cannotReplace(L("it is running from a place that cannot be written to. Move it to your Applications folder first.",
                                              "es läuft von einem Ort, an den nicht geschrieben werden kann. Verschiebe es zuerst in den Ordner „Programme“."))
        }
        let mount = fm.temporaryDirectory.appendingPathComponent("avpplay-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: mount) }
        guard Toolchain.status(["/usr/bin/hdiutil", "attach", "-quiet", "-nobrowse", "-readonly", "-noautoopen",
                                "-mountpoint", mount.path, image.path]) == 0 else {
            throw UpdateError.damaged
        }
        var attached = true
        defer { if attached { _ = Toolchain.status(["/usr/bin/hdiutil", "detach", "-quiet", "-force", mount.path]) } }

        guard let source = (try? fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "app" && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true }) else {
            throw UpdateError.notTrusted(L("the disk image contains no app", "das Abbild enthält kein Programm"))
        }
        try verify(app: source, team: team, bundleId: bundleId, newerThan: running)

        let folder = app.deletingLastPathComponent()
        let staged = folder.appendingPathComponent(".\(app.lastPathComponent).update")
        let old = folder.appendingPathComponent(".\(app.lastPathComponent).old")
        try? fm.removeItem(at: staged)
        try? fm.removeItem(at: old)
        do {
            try fm.copyItem(at: source, to: staged)
        } catch {
            throw UpdateError.cannotReplace(error.localizedDescription)
        }
        _ = Toolchain.status(["/usr/bin/hdiutil", "detach", "-quiet", "-force", mount.path])
        attached = false

        // Geprüft wird, was eingespielt wird – nicht nur, was im Abbild lag.
        let version: String
        do {
            version = try verify(app: staged, team: team, bundleId: bundleId, newerThan: running)
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
        do {
            try fm.moveItem(at: app, to: old)
            do {
                try fm.moveItem(at: staged, to: app)
            } catch {
                try? fm.moveItem(at: old, to: app)      // zurück zum alten Stand
                throw error
            }
        } catch {
            try? fm.removeItem(at: staged)
            throw UpdateError.cannotReplace(error.localizedDescription)
        }
        try? fm.removeItem(at: old)
        return version
    }
}

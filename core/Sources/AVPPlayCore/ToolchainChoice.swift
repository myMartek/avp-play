import Foundation

/// Mit welcher Toolchain ein Spiel gebaut wird, wo es nicht die neueste sein soll.
///
/// Ohne Wahl gilt die neueste installierte. Eine Wahl hält ein Spiel bei einem Stand fest – einem älteren Paket
/// des Projekts oder einer bearbeiteten Arbeitskopie –, etwa weil es mit einem neueren schlechter läuft oder weil
/// ein eigener Fix noch in keinem Paket steckt. Sie gilt für alles, was das Spiel baut: Installieren,
/// Aktualisieren und das Erneuern der Signatur. Ein gewähltes Paket wird beim Aufräumen nicht entfernt.
///
/// Die Wahl steht in einer Datei bei den Daten des Programms, damit App, Kommandozeile und Hintergrunddienst
/// dasselbe lesen.
public struct ToolchainChoices: Codable, Sendable, Equatable {
    public struct Pin: Codable, Sendable, Equatable {
        public var version: Int
        public var commit: String
        public var modified: Bool
        /// Nur bei einer Arbeitskopie: wo sie liegt. Ein installiertes Paket findet sich über seinen Commit.
        public var path: String?

        public init(version: Int, commit: String, modified: Bool = false, path: String? = nil) {
            self.version = version
            self.commit = commit
            self.modified = modified
            self.path = path
        }

        public var name: String { Toolchain.name(version: version, modified: modified) }
    }

    /// Je Spiel (Kennung des Rezepts) der gewählte Stand.
    public var games: [String: Pin]

    public init(games: [String: Pin] = [:]) { self.games = games }

    /// Wählt für ein Spiel einen Stand; `nil` heißt: wieder die neueste.
    public mutating func choose(_ pin: Pin?, for recipeId: String) { games[recipeId] = pin }

    /// Die Commits der gewählten Pakete – was ein Aufräumen stehen lassen muss. Arbeitskopien liegen nicht bei den
    /// Paketen und zählen hier nicht: Das Paket, aus dem eine entstand, braucht ihretwegen niemand mehr.
    public var packageCommits: Set<String> { Set(games.values.filter { $0.path == nil }.map(\.commit)) }

    public static var url: URL { DataLocation.base.appendingPathComponent("toolchain-choices.json") }

    public static func load(from url: URL = ToolchainChoices.url) -> ToolchainChoices {
        guard let data = try? Data(contentsOf: url), let choices = try? JSONDecoder().decode(ToolchainChoices.self, from: data) else {
            return ToolchainChoices()
        }
        return choices
    }

    public func save(to url: URL = ToolchainChoices.url) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

extension ToolchainPackager {
    /// Die Wahl, die diesen Stand meint.
    public func pin(for toolchain: Toolchain) -> ToolchainChoices.Pin {
        ToolchainChoices.Pin(version: toolchain.version(), commit: toolchain.commit(), modified: toolchain.isModified,
                             path: holds(toolchain.root) ? nil : toolchain.root.standardizedFileURL.path)
    }

    /// Der gewählte Stand, sofern er noch auf diesem Mac liegt: die Arbeitskopie an ihrem Ort, das Paket unter den
    /// installierten. `nil` heißt: weg – dann wird nicht stillschweigend mit einem anderen gebaut.
    public func toolchain(for pin: ToolchainChoices.Pin) -> Toolchain? {
        if let path = pin.path {
            guard let copy = try? Toolchain(root: URL(fileURLWithPath: path, isDirectory: true)),
                  copy.manifest?.commit == pin.commit else { return nil }
            return copy
        }
        return installed().first { $0.manifest?.commit == pin.commit && !$0.isModified }
    }
}

/// Wo die Arbeitskopien liegen, in denen eine KI eine Toolchain für ein Spiel bearbeitet („Fix with AI“).
public enum FixWorkspace {
    public static let folderName = "avpplay-fix"

    public static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Die Arbeitskopien dort, die als bearbeitet gekennzeichnet sind – neueste Nummer zuerst.
    public static func modifiedToolchains(in root: URL = FixWorkspace.root) -> [Toolchain] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.filter { !$0.lastPathComponent.hasPrefix(".") }
            .compactMap { try? Toolchain(root: $0) }
            .filter(\.isModified)
            .sorted { ($0.version(), $1.root.lastPathComponent) > ($1.version(), $0.root.lastPathComponent) }
    }
}

/// Ein Toolchain-Paket, das mit einer Veröffentlichung von AVP Play auf GitHub liegt.
public struct ReleasedToolchain: Sendable, Equatable, Identifiable {
    public var version: Int
    public var commit: String
    /// Die erste Veröffentlichung von AVP Play, die diesen Stand mitbrachte.
    public var appVersion: String
    public var archive: URL
    public var sidecar: URL
    public var size: Int64?
    /// SHA-256 des Archivs, wie GitHubs Liste es nennt.
    public var sha256: String?
    public var id: String { commit }
}

/// Die Pakete früherer Veröffentlichungen: auflisten und eines laden. Installiert wird ein geladenes Paket wie
/// jedes andere, geprüft gegen seine Beschreibung (`ToolchainPackager.install`).
public enum ToolchainReleases {
    public static let defaultFeed = URL(string: "https://api.github.com/repos/myMartek/avp-play/releases")!
    static let pageSize = 100

    /// Liest eine Seite von GitHubs Liste der Veröffentlichungen. Zählt nur, was Paket und Beschreibung hat.
    public static func parse(_ data: Data) throws -> (toolchains: [ReleasedToolchain], releases: Int) {
        struct Release: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: String; let size: Int64?; let digest: String? }
            let tag_name: String
            let assets: [Asset]
        }
        guard let releases = try? JSONDecoder().decode([Release].self, from: data) else {
            throw UpdateError.feed(L("unexpected answer", "unerwartete Antwort"))
        }
        var found: [ReleasedToolchain] = []
        for release in releases {
            let tag = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
            guard tag.range(of: #"^\d+(\.\d+){0,3}$"#, options: .regularExpression) != nil else { continue }
            for asset in release.assets {
                guard let match = asset.name.wholeMatch(of: #/klepton-toolchain-(\d{1,9})-([0-9a-f]{7,40})\.tar\.gz/#),
                      let version = Int(match.1), let archive = URL(string: asset.browser_download_url), archive.scheme == "https",
                      let side = release.assets.first(where: { $0.name == asset.name + ".json" }),
                      let sidecar = URL(string: side.browser_download_url), sidecar.scheme == "https" else { continue }
                let sha = asset.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)).lowercased() : nil }
                found.append(ReleasedToolchain(version: version, commit: String(match.2), appVersion: tag, archive: archive,
                                               sidecar: sidecar, size: asset.size, sha256: sha))
            }
        }
        return (found, releases.count)
    }

    /// Mehrere Veröffentlichungen können denselben Stand mitbringen: Er steht einmal da, mit der frühesten.
    /// Neueste Nummer zuerst.
    public static func merged(_ all: [ReleasedToolchain]) -> [ReleasedToolchain] {
        var byCommit: [String: ReleasedToolchain] = [:]
        for t in all {
            if let have = byCommit[t.commit], !Updater.isNewer(have.appVersion, than: t.appVersion) { continue }
            byCommit[t.commit] = t
        }
        return byCommit.values.sorted { ($0.version, $0.commit) > ($1.version, $1.commit) }
    }

    /// Fragt GitHub nach den Veröffentlichungen von AVP Play. Gesendet wird nichts außer der Anfrage selbst.
    public static func list(feed: URL = defaultFeed, pages: Int = 10) async throws -> [ReleasedToolchain] {
        if feed.isFileURL {
            guard let data = try? Data(contentsOf: feed) else { throw UpdateError.feed(feed.path) }
            return merged(try parse(data).toolchains)
        }
        var all: [ReleasedToolchain] = []
        for page in 1...max(1, pages) {
            guard var parts = URLComponents(url: feed, resolvingAgainstBaseURL: false) else { break }
            parts.queryItems = [URLQueryItem(name: "per_page", value: String(pageSize)), URLQueryItem(name: "page", value: String(page))]
            guard let url = parts.url else { break }
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 20
            let data: Data
            do {
                let (body, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw UpdateError.feed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                }
                data = body
            } catch let error as UpdateError {
                throw error
            } catch {
                throw UpdateError.feed(error.localizedDescription)
            }
            let (found, count) = try parse(data)
            all += found
            if count < pageSize { break }
        }
        return merged(all)
    }

    /// Lädt Paket und Beschreibung in `directory` und prüft das Archiv gegen Größe und Prüfsumme aus GitHubs Liste.
    /// - Returns: das Archiv; die Beschreibung liegt daneben, wie `ToolchainPackager.install` sie erwartet.
    public static func download(_ toolchain: ReleasedToolchain, to directory: URL) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = directory.appendingPathComponent("klepton-toolchain-\(toolchain.version)-\(toolchain.commit).tar.gz")
        func fetch(_ source: URL, to target: URL) async throws {
            try? fm.removeItem(at: target)
            do {
                if source.isFileURL {
                    try fm.copyItem(at: source, to: target)
                } else {
                    let (temp, response) = try await URLSession.shared.download(from: source)
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
        }
        try await fetch(toolchain.sidecar, to: ToolchainPackager.sidecar(for: archive))
        try await fetch(toolchain.archive, to: archive)
        if let size = toolchain.size, ContentStore.fileSize(archive) != size { throw PackageError.sizeMismatch }
        if let expected = toolchain.sha256, (try? Hashing.sha256(of: archive)) != expected { throw PackageError.checksumMismatch }
        return archive
    }

    /// Lädt ein Paket und installiert es. Was ankommt, muss der Stand sein, den die Liste nannte.
    public static func install(_ toolchain: ReleasedToolchain, with packager: ToolchainPackager) async throws -> Toolchain {
        if let have = packager.installed().first(where: { $0.manifest?.commit == toolchain.commit && !$0.isModified }) { return have }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("avpplay-toolchain-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let archive = try await download(toolchain, to: scratch)
        // Die Beschreibung entscheidet, wohin ausgepackt wird: Sie muss denselben Stand nennen wie die Liste.
        guard let data = try? Data(contentsOf: ToolchainPackager.sidecar(for: archive)),
              let described = try? ToolchainPackager.decoder.decode(ToolchainManifest.self, from: data),
              described.commit == toolchain.commit, described.version == toolchain.version, described.modified != true else {
            throw PackageError.contentMismatch
        }
        let installed = try packager.install(archive: archive)
        return installed
    }
}

/// Eine Toolchain, die auf der Seite eines Spiels zur Wahl steht.
public struct ToolchainOption: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Keine Wahl: immer die neueste installierte.
        case newest
        /// Ein installiertes Paket des Projekts.
        case installed
        /// Eine als bearbeitet gekennzeichnete Arbeitskopie.
        case copy
        /// Ein Paket einer früheren Veröffentlichung auf GitHub; geladen wird es erst, wenn es gewählt ist.
        case released
        /// Gewählt, aber nicht mehr auf diesem Mac.
        case missing
    }

    public static let newestId = "newest", missingId = "missing"

    public let id: String
    public let kind: Kind
    public let version: Int
    public let commit: String
    public var modified: Bool
    public var path: String?
    /// Die Veröffentlichung von AVP Play, mit der das Paket kam.
    public var appVersion: String?
    public var size: Int64?

    public init(id: String, kind: Kind, version: Int, commit: String, modified: Bool = false, path: String? = nil,
                appVersion: String? = nil, size: Int64? = nil) {
        self.id = id
        self.kind = kind
        self.version = version
        self.commit = commit
        self.modified = modified
        self.path = path
        self.appVersion = appVersion
        self.size = size
    }

    /// Unter welcher Kennung eine Wahl in der Liste steht.
    public static func key(for pin: ToolchainChoices.Pin) -> String { pin.path.map { "copy:\($0)" } ?? pin.commit }
}

/// Was für ein Spiel zur Wahl steht, nach Herkunft.
public struct ToolchainOptions: Equatable, Sendable {
    public var newest: ToolchainOption?
    public var installed: [ToolchainOption] = []
    public var copies: [ToolchainOption] = []
    public var released: [ToolchainOption] = []
    public var missing: ToolchainOption?

    public init() {}

    /// Angeboten wird nur, womit sich das Rezept des Spiels bauen lässt: was dessen Mindeststand enthält.
    /// Für ein Paket auf GitHub lässt sich das vor dem Laden nur schätzen – aus der Reihenfolge, in der die
    /// neueste Toolchain ihre Vorgänger nennt; geprüft wird es nach dem Laden.
    public static func make(recipe: Recipe, pin: ToolchainChoices.Pin?, packager: ToolchainPackager, newest: Toolchain?,
                     released: [ReleasedToolchain]?, workspace: URL = FixWorkspace.root) -> ToolchainOptions {
        let need = recipe.toolchain.minCommit
        // Only what is of the game's kind: a game with a toolchain of its own is not offered Klepton, and no other
        // game is offered that toolchain.
        func builds(_ t: Toolchain) -> Bool { t.builds(recipe) && (need.isEmpty || t.satisfies(minCommit: need)) }
        let newest = newest.flatMap { $0.builds(recipe) ? $0 : nil }
        var options = ToolchainOptions()
        if let newest {
            options.newest = ToolchainOption(id: ToolchainOption.newestId, kind: .newest, version: newest.version(), commit: newest.commit())
        }
        let installed = packager.installed().filter { !$0.isModified }
        options.installed = installed.filter(builds).map {
            ToolchainOption(id: $0.commit(), kind: .installed, version: $0.version(), commit: $0.commit())
        }
        var copies = FixWorkspace.modifiedToolchains(in: workspace)
        // Eine gewählte Arbeitskopie an einem anderen Ort steht auch da.
        if let pin, pin.path != nil, let chosen = packager.toolchain(for: pin),
           !copies.contains(where: { $0.root.standardizedFileURL.path == chosen.root.standardizedFileURL.path }) {
            copies.insert(chosen, at: 0)
        }
        options.copies = copies.filter(builds).map {
            let path = $0.root.standardizedFileURL.path
            return ToolchainOption(id: "copy:\(path)", kind: .copy, version: $0.version(), commit: $0.commit(), modified: true, path: path)
        }
        if let pin, packager.toolchain(for: pin) == nil {
            options.missing = ToolchainOption(id: ToolchainOption.missingId, kind: .missing, version: pin.version, commit: pin.commit,
                                              modified: pin.modified, path: pin.path)
        }
        let have = Set(installed.map { $0.commit() })
        let ancestors = newest?.manifest?.ancestors ?? []
        func place(_ commit: String) -> Int? { ancestors.firstIndex { $0.hasPrefix(commit) || commit.hasPrefix($0) } }
        let needed = need.isEmpty ? nil : place(need)
        // The packages on GitHub are Klepton's.
        options.released = (recipe.toolchain.kind == nil ? released ?? [] : []).filter { r in
            guard !have.contains(r.commit), r.version < (newest?.version() ?? Int.max) else { return false }
            guard !need.isEmpty else { return true }
            guard let needed else { return false }
            return place(r.commit).map { $0 <= needed } ?? true
        }.map {
            ToolchainOption(id: "released:\($0.commit)", kind: .released, version: $0.version, commit: $0.commit,
                            appVersion: $0.appVersion, size: $0.size)
        }
        return options
    }
}

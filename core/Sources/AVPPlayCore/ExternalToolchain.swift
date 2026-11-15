import Foundation

/// Where a game's own toolchain comes from, when it is not Klepton (`Recipe.Toolchain.kind`): one exact state of a
/// public repository. The recipe names the commit in full, so what is fetched is what the project looked at; a
/// branch or a tag would be whatever its owner makes of it later.
public struct ToolchainSource: Codable, Sendable, Hashable {
    /// The repository, as `https://github.com/<owner>/<name>`.
    public var repository: String
    /// The commit, all 40 characters.
    public var commit: String
    /// The number of this state (as a Klepton package has one): stamped into the built app, and a larger number in a
    /// later recipe makes the installed game show “Update available”.
    public var version: Int
    /// The folder inside the repository that is the toolchain (it holds `visionos/run.sh`); absent: the repository
    /// itself.
    public var path: String?

    public init(repository: String, commit: String, version: Int, path: String? = nil) {
        self.repository = repository
        self.commit = commit
        self.version = version
        self.path = path
    }

    /// The first seven characters of the commit, as toolchains name their state everywhere else.
    public var shortCommit: String { String(commit.prefix(7)) }

    /// What is in a recipe becomes arguments of git and paths on disk: a plain GitHub address, a full lower-case
    /// commit, a number that fits the stamp, and a folder of plain names.
    public var isSane: Bool {
        func plain(_ s: Substring) -> Bool {
            !s.isEmpty && s != "." && s != ".." && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
        }
        let prefix = "https://github.com/"
        guard repository.hasPrefix(prefix) else { return false }
        let parts = repository.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy(plain), !parts[1].hasSuffix(".git") else { return false }
        guard commit.count == 40, commit.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }) else { return false }
        guard (1...999_999_999).contains(version) else { return false }
        if let path { guard path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy(plain) else { return false } }
        return true
    }
}

/// What can go wrong while one pinned state of a repository is fetched (`ToolchainSource.checkOut`).
public enum PinnedSourceError: Error, Equatable {
    case fetchFailed(String)
    case wrongCommit(have: String, want: String)
}

extension ToolchainSource {
    /// Fetches exactly this commit into an empty folder, without the repository's history, and checks that what
    /// arrived is that commit. Used for a game's own toolchain and for the builder of a game's parts.
    /// - Parameter remote: the address git is given – the repository's, or one on disk in a test.
    func checkOut(into fresh: URL, from remote: String) throws {
        func git(_ arguments: [String]) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", fresh.path] + arguments
            // Nothing of the user's git setup: no helpers, no hooks, no prompt that would wait for an answer.
            p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": fresh.path, "GIT_TERMINAL_PROMPT": "0",
                             "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = FileHandle.nullDevice
            try p.run()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let problem = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                let line = problem.split(whereSeparator: \.isNewline).last.map(String.init) ?? "git \(arguments.first ?? "")"
                throw PinnedSourceError.fetchFailed(String(line.prefix(200)))
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try git(["init", "--quiet"])
        _ = try git(["fetch", "--quiet", "--depth", "1", remote, commit])
        _ = try git(["-c", "advice.detachedHead=false", "checkout", "--quiet", "--detach", "FETCH_HEAD"])
        let head = try git(["rev-parse", "HEAD"])
        guard head == commit else { throw PinnedSourceError.wrongCommit(have: String(head.prefix(12)), want: shortCommit) }
    }
}

public enum ExternalToolchainError: Error, CustomStringConvertible {
    case noSource(String)
    case blankInPath(String)
    case fetchFailed(String)
    case wrongCommit(have: String, want: String)
    case notAToolchain(String)
    case offline(String)

    public var description: String {
        switch self {
        case .offline(let title):
            return L("\(title) cannot be built offline yet: its toolchain is not on this Mac. Switch Offline off so that it can be fetched, then try again.",
                     "\(title) lässt sich offline noch nicht bauen: Seine Toolchain liegt nicht auf diesem Mac. Schalte Offline aus, damit sie geholt werden kann, und versuche es dann noch einmal.")
        case .noSource(let title):
            return L("\(title) is built with a toolchain of its own, and its recipe does not say where that comes from.",
                     "\(title) wird mit einer eigenen Toolchain gebaut, und sein Rezept sagt nicht, woher sie kommt.")
        case .blankInPath(let path):
            return L("The toolchain for this game cannot be kept in \(path): its build tools do not work in a folder with a blank in its path.",
                     "Die Toolchain für dieses Spiel kann nicht unter \(path) liegen: Ihre Bauwerkzeuge arbeiten nicht in einem Ordner mit Leerzeichen im Pfad.")
        case .fetchFailed(let detail):
            return L("The toolchain for this game could not be fetched from GitHub (\(detail)).",
                     "Die Toolchain für dieses Spiel ließ sich nicht von GitHub holen (\(detail)).")
        case .wrongCommit(let have, let want):
            return L("GitHub delivered another state of the toolchain (\(have)) than the recipe names (\(want)). Nothing was installed.",
                     "GitHub hat einen anderen Stand der Toolchain geliefert (\(have)), als das Rezept nennt (\(want)). Es wurde nichts installiert.")
        case .notAToolchain(let path):
            return L("What the recipe names as this game's toolchain is none (\(path)/visionos/run.sh is missing).",
                     "Was das Rezept als Toolchain dieses Spiels nennt, ist keine (\(path)/visionos/run.sh fehlt).")
        }
    }
}

/// The toolchains of games that are not built with Klepton: fetched from the repository their recipe names, one
/// folder per state, kept apart from the Klepton packages (“the newest toolchain” never means one of these).
///
/// They live in `~/.avpplay/toolchains`, not beside the program's other data: that folder is under
/// “Application Support”, and make does not survive a blank in a path.
public struct ExternalToolchains: Sendable {
    public let root: URL

    public static var defaultRoot: URL {
        if let given = ProcessInfo.processInfo.environment["AVPPLAY_EXTERNAL_TOOLCHAINS"], !given.isEmpty {
            return URL(fileURLWithPath: given, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".avpplay/toolchains", isDirectory: true)
    }

    public init(root: URL = ExternalToolchains.defaultRoot) { self.root = root }

    /// The folder one state is checked out to.
    public func checkout(for source: ToolchainSource, kind: String) -> URL {
        root.appendingPathComponent("\(kind)-\(source.version)-\(source.shortCommit)", isDirectory: true)
    }

    /// Where the toolchain of this recipe's game is (or will be, once fetched); `nil` for a game without one.
    public func directory(for recipe: Recipe) -> URL? {
        guard let kind = recipe.toolchain.kind, let source = recipe.toolchain.source, source.isSane, Recipe.isSafeName(kind) else { return nil }
        let base = checkout(for: source, kind: kind)
        return source.path.map { base.appendingPathComponent($0, isDirectory: true) } ?? base
    }

    /// The choice a recipe makes for its game by naming its toolchain: exactly that state, at that place. It
    /// counts where nothing else is chosen for the game (`ToolchainChoices.pin(for:)`).
    public func pin(for recipe: Recipe) -> ToolchainChoices.Pin? {
        guard let source = recipe.toolchain.source, let directory = directory(for: recipe) else { return nil }
        return ToolchainChoices.Pin(version: source.version, commit: source.shortCommit, path: directory.standardizedFileURL.path)
    }

    /// The fetched toolchain, if it is there and is what the recipe names.
    public func installed(for recipe: Recipe) -> Toolchain? {
        guard let source = recipe.toolchain.source, let directory = directory(for: recipe),
              let toolchain = try? Toolchain(root: directory), let manifest = toolchain.manifest,
              manifest.commit == source.shortCommit, manifest.version == source.version, toolchain.builds(recipe) else { return nil }
        return toolchain
    }

    /// Fetches the state the recipe names, checks that it is that state, and describes it (`toolchain.json`) – or
    /// returns the one already there. Only this commit is fetched, without the repository's history.
    @discardableResult
    public func fetch(for recipe: Recipe, report: (String) -> Void = { _ in }) throws -> Toolchain {
        try fetch(for: recipe, from: { $0.repository + ".git" }, report: report)
    }

    /// The same, with the address git is given for a source – so that a test can fetch from a repository on disk.
    @discardableResult
    func fetch(for recipe: Recipe, from remote: (ToolchainSource) -> String, report: (String) -> Void = { _ in }) throws -> Toolchain {
        if let present = installed(for: recipe) { return present }
        guard let kind = recipe.toolchain.kind, let source = recipe.toolchain.source, source.isSane, Recipe.isSafeName(kind),
              let directory = directory(for: recipe) else { throw ExternalToolchainError.noSource(recipe.title) }
        let target = checkout(for: source, kind: kind)
        guard !target.path.contains(" ") else { throw ExternalToolchainError.blankInPath(root.path) }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // What a fetch left behind that never ended (the app was quit meanwhile) is of no use to anyone.
        for left in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where left.lastPathComponent.hasPrefix(".fetching-") {
            let changed = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let changed, Date().timeIntervalSince(changed) > 3600 { try? fm.removeItem(at: left) }
        }
        let fresh = root.appendingPathComponent(".fetching-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: fresh) }
        try fm.createDirectory(at: fresh, withIntermediateDirectories: true)
        report(L("Fetching this game's toolchain from \(source.repository) (state \(source.shortCommit)) …",
                 "Die Toolchain dieses Spiels wird von \(source.repository) geholt (Stand \(source.shortCommit)) …"))
        do {
            try source.checkOut(into: fresh, from: remote(source))
        } catch PinnedSourceError.fetchFailed(let detail) {
            throw ExternalToolchainError.fetchFailed(detail)
        } catch PinnedSourceError.wrongCommit(let have, let want) {
            throw ExternalToolchainError.wrongCommit(have: have, want: want)
        }

        let inside = source.path.map { fresh.appendingPathComponent($0, isDirectory: true) } ?? fresh
        guard fm.fileExists(atPath: inside.appendingPathComponent("visionos/run.sh").path) else {
            throw ExternalToolchainError.notAToolchain(source.path ?? source.repository)
        }
        // The description is written here, from the recipe: what the state is called is the project's word, not
        // something the fetched files say about themselves.
        var manifest = ToolchainManifest(format: ToolchainManifest.currentFormat, version: source.version, commit: source.shortCommit,
                                         ancestors: [source.shortCommit], created: Date())
        manifest.appRevision = source.version
        manifest.kind = kind
        try ToolchainPackager.encoder.encode(manifest).write(to: inside.appendingPathComponent("toolchain.json"), options: .atomic)

        try? fm.removeItem(at: target)
        try fm.moveItem(at: fresh, to: target)
        let named = recipe.toolchainName(String(source.version))
        report(L("This game's toolchain \(named) is ready.", "Die Toolchain dieses Spiels, \(named), ist bereit."))
        return try Toolchain(root: directory)
    }
}

extension ToolchainChoices {
    /// The state chosen for a game: what the user chose for it, otherwise what its recipe names as the game's own
    /// toolchain (`ExternalToolchains.pin(for:)`), otherwise nothing – then the newest Klepton package builds it.
    public func pin(for recipe: Recipe, external: ExternalToolchains = ExternalToolchains()) -> Pin? {
        games[recipe.id] ?? external.pin(for: recipe)
    }

    /// Whether the game's toolchain is the one its recipe names, not one the user chose: then a missing toolchain is
    /// not lost, only not fetched yet, and the next job fetches it.
    public func usesRecipeToolchain(_ recipe: Recipe) -> Bool {
        games[recipe.id] == nil && recipe.toolchain.source != nil && recipe.toolchain.kind != nil
    }
}

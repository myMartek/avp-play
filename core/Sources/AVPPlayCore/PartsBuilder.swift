import Darwin
import Foundation

/// What builds a game's parts on the user's own Mac, for a game whose program is not delivered ready-made
/// (`Recipe.builder`). Minecraft is the first: its client comes from Mojang's servers and is compiled here, ahead of
/// time, into the libraries and files the toolchain then packs into the app.
///
/// The builder is a script in a public repository, named like a game's own toolchain: one exact commit
/// (`ToolchainSource`). It is fetched to `PartsBuilders`, run by `PartsBuild`, and what it writes is kept in the
/// library as `GameParts`.
public struct PartsBuilder: Codable, Sendable, Equatable {
    /// The repository and the commit; `path` is the folder in it that holds `tools/avpplay/build_parts.sh`.
    public var source: ToolchainSource
    /// What the user is told before the first build starts: how long it takes, what it needs, what they will see.
    public var notes: [LocalizedText]

    public init(source: ToolchainSource, notes: [LocalizedText]) {
        self.source = source
        self.notes = notes
    }
}

public enum PartsError: Error, CustomStringConvertible, Equatable {
    /// “ in step 14 of 20 (“Creating a test world”)” for `14/20 world`, in the language of the moment.
    static func stepWords(_ stage: String) -> String {
        let parts = stage.split(separator: " ", maxSplits: 1).map(String.init)
        let numbers = parts.first?.split(separator: "/").compactMap { Int($0) } ?? []
        guard numbers.count == 2 else { return L(" in step \(stage)", " in Schritt \(stage)") }
        let name = parts.count > 1 ? parts[1] : ""
        let title = BuildStepNames.title(name) ?? name
        return title.isEmpty ? L(" in step \(numbers[0]) of \(numbers[1])", " in Schritt \(numbers[0]) von \(numbers[1])")
                             : L(" in step \(numbers[0]) of \(numbers[1]) (“\(title)”)", " in Schritt \(numbers[0]) von \(numbers[1]) („\(title)“)")
    }

    case blankInPath(String)
    case fetchFailed(String)
    case wrongCommit(have: String, want: String)
    case notABuilder(String)
    case offline(String)
    case notBuilt(String)
    case couldNotStart(String)
    /// The builder's own check found something missing on this Mac; its lines, as it printed them.
    case prerequisites([String])
    /// The build ended early: the step it was in (`<i>/<n> <short name>`), the builder's reason or the last thing it
    /// said, and where everything it said is kept.
    case buildFailed(stage: String?, reason: String, log: URL)
    /// The build ended without naming what it built, or what it named is not what lies there.
    case badResult(String, log: URL)

    public var description: String {
        switch self {
        case .blankInPath(let path):
            return L("The game's parts cannot be built in \(path): the build tools do not work in a folder with a blank in its path.",
                     "Die Spielteile lassen sich nicht unter \(path) bauen: Die Bauwerkzeuge arbeiten nicht in einem Ordner mit Leerzeichen im Pfad.")
        case .fetchFailed(let detail):
            return L("The builder for this game's parts could not be fetched from GitHub (\(detail)).",
                     "Das Bauwerkzeug für die Teile dieses Spiels ließ sich nicht von GitHub holen (\(detail)).")
        case .wrongCommit(let have, let want):
            return L("GitHub delivered another state of the builder (\(have)) than the recipe names (\(want)). Nothing was built.",
                     "GitHub hat einen anderen Stand des Bauwerkzeugs geliefert (\(have)), als das Rezept nennt (\(want)). Es wurde nichts gebaut.")
        case .notABuilder(let path):
            return L("There is no builder for the game's parts at \(path) (\(PartsBuilders.entry) is missing).",
                     "Unter \(path) liegt kein Bauwerkzeug für die Spielteile (\(PartsBuilders.entry) fehlt).")
        case .offline(let title):
            return L("\(title) cannot be installed offline yet: its parts have not been built on this Mac. Switch Offline off so that they can be built, then try again.",
                     "\(title) lässt sich offline noch nicht installieren: Seine Teile sind auf diesem Mac noch nicht gebaut. Schalte Offline aus, damit sie gebaut werden können, und versuche es dann noch einmal.")
        case .notBuilt(let title):
            return L("The parts of \(title) are not on this Mac (any more). Install the game again from its page: that builds them first.",
                     "Die Teile von \(title) liegen nicht (mehr) auf diesem Mac. Installiere das Spiel von seiner Seite aus neu: Dabei werden sie zuerst gebaut.")
        case .couldNotStart(let why):
            return L("The builder for the game's parts could not be started (\(why)).", "Das Bauwerkzeug für die Spielteile ließ sich nicht starten (\(why)).")
        case .prerequisites(let lines):
            return L("This Mac cannot build the game's parts yet: ", "Dieser Mac kann die Spielteile noch nicht bauen: ") + lines.joined(separator: " · ")
        case .buildFailed(let stage, let reason, let log):
            let at = stage.map(PartsError.stepWords) ?? ""
            // The builder's sentence ends with its own full stop; ours follows.
            let sentence = reason.hasSuffix(".") ? String(reason.dropLast()) : reason
            let why = sentence.isEmpty ? "" : ": \(sentence)"
            return L("Building the game's parts stopped\(at)\(why). Log: \(log.path). “Resume” continues with the steps that are not finished.",
                     "Der Bau der Spielteile ist\(at) stehen geblieben\(why). Protokoll: \(log.path). „Fortsetzen“ macht mit den Schritten weiter, die noch nicht fertig sind.")
        case .badResult(let why, let log):
            return L("The builder ended without usable parts (\(why)). Nothing was added to the library. Log: \(log.path)",
                     "Das Bauwerkzeug endete ohne brauchbare Spielteile (\(why)). In den Bestand wurde nichts übernommen. Protokoll: \(log.path)")
        }
    }
}

/// A builder folder chosen by hand for a game instead of the state its recipe names: a working copy on this Mac,
/// for trying a change before it is pinned (`avpplay builder use <id> --builder <folder>`). The counterpart of a
/// toolchain chosen for a game.
public struct BuilderChoices: Codable, Sendable, Equatable {
    /// Recipe id → folder.
    public var games: [String: String] = [:]

    public init() {}

    public static var url: URL { DataLocation.base.appendingPathComponent("builder-choices.json") }

    public static func load(from url: URL = BuilderChoices.url) -> BuilderChoices {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(BuilderChoices.self, from: $0) } ?? BuilderChoices()
    }

    public func save(to url: URL = BuilderChoices.url) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Where builders and their working folders live: `~/.avpplay/builders`, beside the games' own toolchains and for the
/// same reason – build tools do not survive a blank in a path, and “Application Support” has one.
public struct PartsBuilders: Sendable {
    public let root: URL

    /// The script every builder is entered through, below its folder.
    public static let entry = "tools/avpplay/build_parts.sh"

    public static var defaultRoot: URL {
        if let given = ProcessInfo.processInfo.environment["AVPPLAY_BUILDERS"], !given.isEmpty {
            return URL(fileURLWithPath: given, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".avpplay/builders", isDirectory: true)
    }

    public init(root: URL = PartsBuilders.defaultRoot) { self.root = root }

    func checkout(for recipe: Recipe, source: ToolchainSource) -> URL {
        root.appendingPathComponent("\(recipe.id)-\(source.version)-\(source.shortCommit)", isDirectory: true)
    }

    /// Where the builder this recipe names is (or will be, once fetched); `nil` for a game without one.
    public func directory(for recipe: Recipe) -> URL? {
        guard let source = recipe.builder?.source, source.isSane, Recipe.isSafeName(recipe.id) else { return nil }
        let base = checkout(for: recipe, source: source)
        return source.path.map { base.appendingPathComponent($0, isDirectory: true) } ?? base
    }

    /// Everything the builder downloads and builds on the way (`AVPPLAY_WORK`): one folder per game, kept between
    /// runs and across builder states, so that a second run only does what is new.
    public func work(for recipe: Recipe) -> URL {
        root.appendingPathComponent("work/\(recipe.id)", isDirectory: true)
    }

    /// Where the builder writes its result before it is checked and taken into the library.
    func outbox(for recipe: Recipe) -> URL {
        root.appendingPathComponent("out/\(recipe.id)", isDirectory: true)
    }

    private struct Mark: Codable, Equatable { var commit: String; var version: Int }
    private static let markName = ".avpplay-builder.json"

    /// The fetched builder, if it is there and is the state the recipe names.
    public func installed(for recipe: Recipe) -> URL? {
        guard let source = recipe.builder?.source, let directory = directory(for: recipe),
              let data = try? Data(contentsOf: checkout(for: recipe, source: source).appendingPathComponent(PartsBuilders.markName)),
              (try? JSONDecoder().decode(Mark.self, from: data)) == Mark(commit: source.commit, version: source.version),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent(PartsBuilders.entry).path) else { return nil }
        return directory
    }

    /// Fetches the state the recipe names and checks that it is that state – or returns the one already there.
    @discardableResult
    public func fetch(for recipe: Recipe, report: (String) -> Void = { _ in }) throws -> URL {
        try fetch(for: recipe, from: { $0.repository + ".git" }, report: report)
    }

    /// The same, with the address git is given – so that a test can fetch from a repository on disk.
    @discardableResult
    func fetch(for recipe: Recipe, from remote: (ToolchainSource) -> String, report: (String) -> Void = { _ in }) throws -> URL {
        if let present = installed(for: recipe) { return present }
        guard let source = recipe.builder?.source, let directory = directory(for: recipe) else { throw PartsError.notABuilder(recipe.id) }
        let target = checkout(for: recipe, source: source)
        guard !target.path.contains(" ") else { throw PartsError.blankInPath(root.path) }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let fresh = root.appendingPathComponent(".fetching-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: fresh) }
        try fm.createDirectory(at: fresh, withIntermediateDirectories: true)
        report(L("Fetching the builder for the game's parts from \(source.repository) (state \(source.shortCommit)) …",
                 "Das Bauwerkzeug für die Spielteile wird von \(source.repository) geholt (Stand \(source.shortCommit)) …"))
        do {
            try source.checkOut(into: fresh, from: remote(source))
        } catch PinnedSourceError.fetchFailed(let detail) {
            throw PartsError.fetchFailed(detail)
        } catch PinnedSourceError.wrongCommit(let have, let want) {
            throw PartsError.wrongCommit(have: have, want: want)
        }
        let inside = source.path.map { fresh.appendingPathComponent($0, isDirectory: true) } ?? fresh
        guard fm.fileExists(atPath: inside.appendingPathComponent(PartsBuilders.entry).path) else {
            throw PartsError.notABuilder(source.path.map { "\(source.repository)/\($0)" } ?? source.repository)
        }
        try JSONEncoder().encode(Mark(commit: source.commit, version: source.version))
            .write(to: fresh.appendingPathComponent(PartsBuilders.markName), options: .atomic)
        try? fm.removeItem(at: target)
        try fm.moveItem(at: fresh, to: target)
        return directory
    }
}

/// The parts of a game, built on this Mac and kept in the library: one zip in the game's folder, named after the
/// builder that made it. A new state of the builder makes a new file, a new version of the game a new folder; what
/// an older builder made is removed once the new parts are there.
public enum GameParts {
    public enum State: Sendable, Equatable {
        case missing
        case built(Date, bytes: Int64)

        public var isBuilt: Bool { self != .missing }
    }

    /// What is noted beside the zip: what made it and what it was when it arrived.
    public struct Record: Codable, Sendable, Equatable {
        public var builder: String
        public var sha256: String
        public var size: Int64
        public var built: Date
    }

    /// How the builder is named in the file's name and its note: the pinned state, or `local` for a folder chosen by hand.
    static func key(recipe: Recipe, local: Bool) -> String? {
        if local { return "local" }
        return recipe.builder.map { "\($0.source.version)-\($0.source.shortCommit)" }
    }

    public static func url(recipe: Recipe, store: ContentStore, local: Bool) -> URL? {
        key(recipe: recipe, local: local).map { store.directory(for: recipe).appendingPathComponent("\(recipe.id)-parts-\($0).zip") }
    }

    static func recordURL(for zip: URL) -> URL {
        zip.deletingLastPathComponent().appendingPathComponent(".\(zip.lastPathComponent).json")
    }

    /// The parts made by this builder, if they are in the library as they arrived.
    public static func built(recipe: Recipe, store: ContentStore, local: Bool) -> (url: URL, record: Record)? {
        guard let zip = url(recipe: recipe, store: store, local: local), let key = key(recipe: recipe, local: local),
              let data = try? Data(contentsOf: recordURL(for: zip)), let record = try? JSONDecoder.iso.decode(Record.self, from: data),
              record.builder == key, ContentStore.fileSize(zip) == record.size else { return nil }
        return (zip, record)
    }

    /// Whether a builder folder is chosen by hand for this game (`BuilderChoices`).
    public static func usesLocalBuilder(_ recipe: Recipe) -> Bool { BuilderChoices.load().games[recipe.id] != nil }

    /// For the game's page: are the parts there? `nil` for a game that has none to build.
    public static func state(recipe: Recipe, store: ContentStore) -> State? {
        guard recipe.builder != nil else { return nil }
        guard let have = built(recipe: recipe, store: store, local: usesLocalBuilder(recipe)) else { return .missing }
        return .built(have.record.built, bytes: have.record.size)
    }

    /// Takes a checked result into the library and removes what other builder states left there.
    static func adopt(_ result: URL, sha256: String, recipe: Recipe, store: ContentStore, local: Bool, now: Date = Date()) throws -> URL {
        guard let zip = url(recipe: recipe, store: store, local: local), let key = key(recipe: recipe, local: local),
              let size = ContentStore.fileSize(result) else { throw PartsError.notBuilt(recipe.title) }
        let fm = FileManager.default
        let directory = store.directory(for: recipe)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fm.removeItem(at: recordURL(for: zip))
        try? fm.removeItem(at: zip)
        // On the same disk this is a rename; onto another one (a library on an external disk) a copy.
        do { try fm.moveItem(at: result, to: zip) } catch {
            try fm.copyItem(at: result, to: zip)
            try? fm.removeItem(at: result)
        }
        try JSONEncoder.iso.encode(Record(builder: key, sha256: sha256, size: size, built: now)).write(to: recordURL(for: zip), options: .atomic)
        let prefix = "\(recipe.id)-parts-"
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] {
            let plain = name.hasPrefix(".") ? String(name.dropFirst()) : name
            guard plain.hasPrefix(prefix), plain != zip.lastPathComponent, plain != zip.lastPathComponent + ".json" else { continue }
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
        return zip
    }
}

/// Ends a running build when its job is cancelled: the builder and everything it started (compilers, the game it
/// runs for a few minutes) are one process group, and the whole group is told to end – and made to, if it does not.
public final class ProcessGroupStop: @unchecked Sendable {
    private let lock = NSLock()
    private var group: pid_t?
    private var stopped = false
    /// How long the group gets to end by itself before it is killed.
    let grace: TimeInterval

    public init(grace: TimeInterval = 5) { self.grace = grace }

    public var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    func attach(_ pid: pid_t) {
        lock.lock()
        group = pid
        let already = stopped
        lock.unlock()
        if already { end(pid) }
    }

    func detach() {
        lock.lock(); group = nil; lock.unlock()
    }

    public func stop() {
        lock.lock()
        stopped = true
        let pid = group
        lock.unlock()
        if let pid { end(pid) }
    }

    private func end(_ pid: pid_t) {
        guard pid > 1 else { return }
        kill(-pid, SIGTERM)
        let grace = self.grace
        Thread.detachNewThread {
            let until = Date().addingTimeInterval(grace)
            while Date() < until {
                if kill(-pid, 0) != 0 { return }           // nobody left in the group
                Thread.sleep(forTimeInterval: 0.1)
            }
            kill(-pid, SIGKILL)
        }
    }
}

/// One run of a builder (`tools/avpplay/build_parts.sh`).
///
/// The contract: it gets `AVPPLAY_WORK` (a folder without blanks for everything it downloads and builds; kept between
/// runs) and `AVPPLAY_OUT` (the zip to write). It prints `STAGE <i>/<n> <short name>` when a step begins
/// (`STAGE <i>/<n> <short name> (already done)` for a step whose result is there and that it skips), anything else as
/// plain lines, and on success ends with status 0 and a last line `PARTS <path> <sha256>`. A failure ends with
/// `FAILED <i>/<n> <short name>: <one sentence>` and `LOG <path>`. Finished steps are skipped on the next run.
/// `--check` only tests what the Mac needs and prints one line per problem (status 1 if any).
///
/// Two more lines feed the progress display (`BuildProgress`); a builder may print neither, and then the display
/// shows “Step i of n” and the time spent in it:
/// - `PLAN <name>:<seconds>[:<flags>] …` once, before the first `STAGE` line: every step in order with how many
///   seconds it took on the builder's reference Mac in the state its work folder is in. Flags: `d` its result is
///   there (it will be skipped), `n` its time is mostly a download.
/// - `PROGRESS <done> <total> <unit>[ <w1>,<w2>,…]` within the running step, at most about once a second. Units:
///   `files`, `bytes`, `entries`, `libraries` (counted work), `parts` (done = parts finished; the weights are the
///   reference seconds of each part), `seconds` (a timed wait: done = seconds behind it when the line was written,
///   total = its expected length). An unknown unit is shown as plain numbers.
/// - `WAIT <reason>` when the build waits for the user, `WAIT end` when it goes on. Known reason: `screen-locked`
///   (the game must run on this Mac for a moment, and it cannot while the screen is locked). The display asks the
///   user to unlock the Mac and holds the estimate still until `WAIT end`.
///
/// A line with a leading blank is the builder quoting a tool's output, never one of these. Lines this side does not
/// know are text for the log, and so is any of these lines that does not parse.
public struct PartsBuild: Sendable {
    public struct Stage: Sendable, Equatable {
        public var index: Int
        public var count: Int
        public var name: String

        /// `STAGE 3/7 native image` → 3, 7, “native image”; `nil` for any other line.
        public static func parse(_ line: String) -> Stage? {
            guard line.hasPrefix("STAGE ") else { return nil }
            let rest = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            let parts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard let first = parts.first else { return nil }
            let numbers = first.split(separator: "/", omittingEmptySubsequences: false)
            guard numbers.count == 2, let i = Int(numbers[0]), let n = Int(numbers[1]), (1...99).contains(n), (1...n).contains(i) else { return nil }
            let name = parts.count > 1 ? PartsBuild.clean(String(parts[1]), limit: 80) : ""
            return Stage(index: i, count: n, name: name)
        }
    }

    public struct Result: Sendable, Equatable {
        public var url: URL
        public var sha256: String
    }

    /// The builder's folder (it holds `PartsBuilders.entry`).
    public let builder: URL
    public let work: URL

    public init(builder: URL, work: URL) {
        self.builder = builder
        self.work = work
    }

    /// A line of a foreign tool, as it may stand in a sentence of ours: one line, printable, not endless.
    static func clean(_ text: String, limit: Int) -> String {
        let plain = String(String.UnicodeScalarView(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        return String(plain.trimmingCharacters(in: .whitespaces).prefix(limit))
    }

    /// `PARTS <path> <sha256>`: the path may hold blanks, the checksum is the last word.
    static func parseResult(_ line: String) -> (path: String, sha256: String)? {
        guard line.hasPrefix("PARTS ") else { return nil }
        let rest = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
        guard let blank = rest.lastIndex(of: " ") else { return nil }
        let sha = rest[rest.index(after: blank)...].lowercased()
        let path = rest[..<blank].trimmingCharacters(in: .whitespaces)
        guard sha.count == 64, sha.allSatisfy({ $0.isHexDigit }), path.hasPrefix("/") else { return nil }
        return (path, sha)
    }

    func environment(out: URL?) -> [String: String] {
        // AVP Play's own switches stay here. A builder reads variables of the same prefix, and one name meant two
        // things once: a jobs folder to AVP Play, a number of compiler jobs to the builder.
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("AVPPLAY_") }
        // Only what macOS and Xcode bring: the same on every Mac. What else the builder needs, it fetches into its
        // working folder itself.
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env["AVPPLAY_WORK"] = work.path
        env["AVPPLAY_OUT"] = out?.path
        return env
    }

    /// Starts the builder as the leader of a process group of its own, with both of its outputs in one pipe.
    func start(arguments: [String], out: URL?) throws -> (pid: pid_t, output: FileHandle) {
        let script = builder.appendingPathComponent(PartsBuilders.entry)
        guard FileManager.default.fileExists(atPath: script.path) else { throw PartsError.notABuilder(builder.path) }
        guard !work.path.contains(" ") else { throw PartsError.blankInPath(work.path) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        // A script that lost its mark as a program (an unpacked archive) is run by the shell all the same.
        let direct = FileManager.default.isExecutableFile(atPath: script.path)
        let tool = direct ? script.path : "/bin/bash"
        let argv = (direct ? [script.path] : ["/bin/bash", script.path]) + arguments

        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw PartsError.couldNotStart(String(cString: strerror(errno))) }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 2)
        posix_spawn_file_actions_addchdir_np(&actions, builder.path)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // A group of its own (so that cancelling reaches everything it starts), and none of this program's open files.
        // …and its signals as a program started by hand has them. Whoever started us may ignore SIGTERM, and a
        // child inherits that: the builder's own `kill` then ended nothing, and one of its steps waited for ever on
        // a helper it thought it had stopped.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                                              | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)
        var everySignal = sigset_t()
        sigfillset(&everySignal)
        posix_spawnattr_setsigdefault(&attr, &everySignal)
        var noSignal = sigset_t()
        sigemptyset(&noSignal)
        posix_spawnattr_setsigmask(&attr, &noSignal)
        let cArguments: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        let cEnvironment: [UnsafeMutablePointer<CChar>?] = environment(out: out).map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in cArguments + cEnvironment { free(p) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, tool, &actions, &attr, cArguments, cEnvironment)
        close(fds[1])
        guard rc == 0 else {
            close(fds[0])
            throw PartsError.couldNotStart(String(cString: strerror(rc)))
        }
        return (pid, FileHandle(fileDescriptor: fds[0], closeOnDealloc: true))
    }

    /// Reads the builder's lines as they come and waits for it to end. Something it left running that still holds
    /// its output does not hold this up for long.
    func follow(_ pid: pid_t, _ output: FileHandle, line: @escaping @Sendable (String) -> Void) -> Int32 {
        let drained = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            var pending = Data()
            while true {
                let chunk = output.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0a) {
                    line(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                    pending.removeSubrange(pending.startIndex...newline)
                }
            }
            if !pending.isEmpty { line(String(decoding: pending, as: UTF8.self)) }
            drained.signal()
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        _ = drained.wait(timeout: .now() + 3)
        let exited = (status & 0x7f) == 0
        return exited ? (status >> 8) & 0xff : -(status & 0x7f)
    }

    /// Asks the builder whether this Mac can build (`--check`): what it finds missing, one line each. Empty: all there.
    public func check() throws -> [String] {
        let (pid, output) = try start(arguments: ["--check"], out: nil)
        let lines = Lines()
        let status = follow(pid, output) { lines.add(PartsBuild.clean($0, limit: 300)) }
        let said = lines.all.filter { !$0.isEmpty }
        if status == 0 { return [] }
        return said.isEmpty ? [L("the builder's check ended with status \(status)", "die Prüfung des Bauwerkzeugs endete mit Status \(status)")] : said
    }

    /// Builds the parts into `out`. Everything the builder says goes into `log`; each step it begins is passed on,
    /// and so is the state of the build whenever a display would show something new.
    public func run(out: URL, log: URL, stop: ProcessGroupStop? = nil, stage: @escaping @Sendable (Stage) -> Void = { _ in },
                    progress: @escaping @Sendable (BuildProgress) -> Void = { _ in }) throws -> Result {
        let fm = FileManager.default
        guard !out.path.contains("\n") else { throw PartsError.couldNotStart("output path") }
        try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: out)
        fm.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }

        let (pid, output) = try start(arguments: [], out: out)
        stop?.attach(pid)
        defer { stop?.detach() }
        let state = RunState()
        let status = follow(pid, output) { raw in
            handle.write(Data((raw + "\n").utf8))
            // Control characters out, but the leading blank stays: it marks a quoted line.
            let plain = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).prefix(2000))
            let line = PartsBuild.clean(raw, limit: 400)
            guard !line.isEmpty else { return }
            let parsed = BuildProgress.Line.parse(plain)
            if case .stage(let s, _)? = parsed {
                state.set(stage: s)
                stage(s)
            } else if parsed == nil {
                state.set(last: line)
            }
            if let snapshot = state.apply(plain, result: parsed == nil && PartsBuild.parseResult(line) != nil) { progress(snapshot) }
        }
        if stop?.isStopped == true { throw CancellationError() }
        let (current, last) = state.snapshot
        guard status == 0 else {
            let built = state.progress
            let index = built.failure?.index ?? current?.index
            let count = current?.count ?? built.count
            let name = index.flatMap { i in built.plan.flatMap { i <= $0.count ? $0[i - 1].name : nil } } ?? current?.name ?? ""
            let named = index.map { name.isEmpty ? "\($0)/\(count)" : "\($0)/\(count) \(name)" }
            var reason = built.failure?.reason ?? (last.hasPrefix("PARTS ") ? "" : last)
            if reason.isEmpty, status < 0 { reason = L("ended by signal \(-status)", "durch Signal \(-status) beendet") }
            throw PartsError.buildFailed(stage: named, reason: reason, log: log)
        }
        guard let result = PartsBuild.parseResult(last) else {
            throw PartsError.badResult(L("its last line does not name them", "seine letzte Zeile nennt sie nicht"), log: log)
        }
        guard URL(fileURLWithPath: result.path).standardizedFileURL.path == out.standardizedFileURL.path, ContentStore.fileSize(out) != nil else {
            throw PartsError.badResult(L("nothing was written where it was asked for", "am verlangten Ort wurde nichts geschrieben"), log: log)
        }
        guard (try? Hashing.sha256(of: out)) == result.sha256 else {
            try? fm.removeItem(at: out)
            throw PartsError.badResult(L("the archive is not the one the builder named", "das Archiv ist nicht das, das das Bauwerkzeug genannt hat"), log: log)
        }
        return Result(url: out, sha256: result.sha256)
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.lock(); if lines.count < 40 { lines.append(line) }; lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var stage: Stage?
        private var last = ""
        private var built = BuildProgress()
        func set(stage: Stage) { lock.lock(); self.stage = stage; lock.unlock() }
        func set(last: String) { lock.lock(); self.last = last; lock.unlock() }
        var snapshot: (Stage?, String) { lock.lock(); defer { lock.unlock() }; return (stage, last) }
        var progress: BuildProgress { lock.lock(); defer { lock.unlock() }; return built }
        /// The new state of the build when this line changed it.
        func apply(_ line: String, result: Bool, at now: Date = Date()) -> BuildProgress? {
            lock.lock(); defer { lock.unlock() }
            if result { built.finish(at: now); return built }
            return built.apply(line, at: now) ? built : nil
        }
    }
}

extension Toolchain {
    /// Under this name `run.sh` learns where the archive of a game's parts lies, for a game whose parts were built on
    /// this Mac (a Mach-O guest): the toolchain takes the game's libraries and files out of it.
    public static let gameArchiveVariable = "KLEPTON_MACHO_IPA"
}

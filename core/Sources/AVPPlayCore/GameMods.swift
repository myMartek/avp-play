import Foundation

/// Mods a game's own toolchain can build the game with, as sets the player switches on and off (the "Mods" box on
/// the game's page; `InstallRequest.gameMods`).
///
/// This is the general form, for toolchains of their own kind (`Recipe.Toolchain.kind`); Beat Saber's mods, which
/// ship inside AVP Play's toolchain, stay `Toolchain.coreMods…`. The contract (docs/recipes.md, "Mods of a toolchain"):
///
/// - `visionos/gen_xcodeproj.py` names `KLEPTON_GAME_MODS`, and `visionos/mods.json` describes the sets;
/// - `visionos/mods_fetch.py` gets the files of the chosen sets onto this Mac before the build. It says what
///   happens in lines starting with `@@mods ` (`GameModsFetch.Event`); where a file needs the player (a download
///   page of Nexus Mods), the script opens the page and waits for the file;
/// - `visionos/run.sh device` builds with the sets named in `KLEPTON_GAME_MODS`, and `stage_sync.py` puts their
///   files on the headset.
///
/// AVP Play never holds mod files and does not know where they come from beyond what `mods.json` says.
public struct GameMods: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var name: String
        public var version: String?
        public var url: String?
        public var about: LocalizedText?
    }

    public struct ModSet: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var title: LocalizedText
        public var about: LocalizedText?
        /// On unless the player switched it off.
        public var `default`: Bool?
        /// Building with this set runs the game on the Mac for some minutes.
        public var macRun: Bool?
        public var downloadBytes: Int64?
        public var mods: [Entry]?
    }

    /// Where the files come from, and whether a key of the player's own account can fetch them without the browser.
    public struct Source: Codable, Sendable, Equatable {
        public struct Key: Codable, Sendable, Equatable {
            /// The environment variable `mods_fetch.py` takes the key in.
            public var variable: String
            /// Where the player makes the key.
            public var page: String?
            /// Which of the things on that page is the key, in a sentence (the page of Nexus Mods lists a key for every
            /// program that ever asked for one, and the player's own at the very bottom).
            public var hint: LocalizedText?
            /// The key only downloads for a paid account of that site; a free one goes through the browser anyway.
            public var premiumOnly: Bool?
        }
        public var name: String
        public var account: String?
        public var key: Key?
    }

    public var schema: Int
    public var about: LocalizedText?
    public var source: Source?
    public var sets: [ModSet]

    /// The sets that are on when the player chose nothing.
    public var defaultSets: [String] { sets.filter { $0.default == true }.map(\.id) }

    /// `asked` reduced to the sets there are, in the order of the description.
    public func known(_ asked: [String]) -> [String] { sets.map(\.id).filter(asked.contains) }

    /// The description in a toolchain, or nil when it has none or one this program cannot read.
    public static func load(toolchainRoot: URL) -> GameMods? {
        let file = toolchainRoot.appendingPathComponent("visionos/mods.json")
        guard let data = try? Data(contentsOf: file), let mods = try? JSONDecoder().decode(GameMods.self, from: data),
              mods.schema == 1, !mods.sets.isEmpty,
              mods.sets.allSatisfy({ GameMods.isSafeId($0.id) }), Set(mods.sets.map(\.id)).count == mods.sets.count else { return nil }
        if let variable = mods.source?.key?.variable, !GameMods.isSafeVariable(variable) { return nil }
        return mods
    }

    static func isSafeId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 32 && id.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func isSafeVariable(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 48 && name.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_") }
            && !name.hasPrefix("KLEPTON_") && !name.hasPrefix("KL_") && !["PATH", "HOME", "USER", "SHELL", "TMPDIR"].contains(name)
    }
}

public enum GameModsError: Error, CustomStringConvertible {
    /// The player did not download a file in time, or closed the page: nothing is broken, the job can run again.
    case notFetched(hint: String, log: URL)
    case fetchFailed(hint: String, log: URL)

    public var description: String {
        switch self {
        case .notFetched(let hint, let log):
            let detail = hint.isEmpty ? "" : " \(hint)"
            return L("The mods are not complete on this Mac yet.\(detail) What is already here is kept; start again when you are ready. Log: \(log.path)",
                     "Die Mods sind auf diesem Mac noch nicht vollständig.\(detail) Was schon da ist, bleibt; starte erneut, wenn du so weit bist. Protokoll: \(log.path)")
        case .fetchFailed(let hint, let log):
            let detail = hint.isEmpty ? "" : ": \(hint)"
            return L("Getting the mod files failed\(detail). Log: \(log.path)",
                     "Das Holen der Mod-Dateien ist fehlgeschlagen\(detail). Protokoll: \(log.path)")
        }
    }
}

/// What `mods_fetch.py` says while it runs, and the sentences the job log shows for it.
public enum GameModsFetch {
    public enum Event: Equatable {
        case total(Int)
        case have(name: String, how: String)
        case need(name: String, page: String)
        case done(Int)
    }

    /// A line of the script's output as an event; nil for every other line (those are for the log only).
    public static func event(in line: String) -> Event? {
        guard line.hasPrefix("@@mods ") else { return nil }
        let parts = line.dropFirst("@@mods ".count).split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard let kind = parts.first else { return nil }
        switch kind {
        case "total": return parts.count > 1 ? Int(parts[1]).map(Event.total) : nil
        case "done": return parts.count > 1 ? Int(parts[1]).map(Event.done) : nil
        case "have": return parts.count > 1 ? .have(name: clean(parts[1]), how: parts.count > 2 ? clean(parts[2]) : "") : nil
        case "need": return parts.count > 2 ? .need(name: clean(parts[1]), page: clean(parts[2])) : nil
        default: return nil
        }
    }

    /// Text from a toolchain's script, shown to the player: one line, printable, of a bounded length.
    static func clean(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }.prefix(200).map(Character.init))
    }

    public static func sentence(for event: Event, source: String, usesKey: Bool) -> String? {
        switch event {
        case .total(let n):
            guard n > 0 else { return nil }
            return usesKey
                ? L("Mods: \(n) files come from \(source), with your key.", "Mods: \(n) Dateien kommen von \(source), mit deinem Schlüssel.")
                : L("Mods: \(n) files come from \(source). AVP Play opens each download page in your browser; click “Manual download”, then “Slow download” there. The file is picked up from your Downloads folder.",
                    "Mods: \(n) Dateien kommen von \(source). AVP Play öffnet jede Download-Seite in deinem Browser; klicke dort auf „Manual download“ und dann auf „Slow download“. Die Datei wird aus deinem Downloads-Ordner übernommen.")
        case .have(let name, _):
            return L("Mods: \(name) is here.", "Mods: \(name) ist da.")
        case .need(let name, let page):
            return L("Mods: waiting for your download of \(name) – its page is open in the browser (\(page)).",
                     "Mods: Warte auf deinen Download von \(name) – die Seite ist im Browser geöffnet (\(page)).")
        case .done:
            return L("Mods: all files are on this Mac.", "Mods: Alle Dateien liegen auf diesem Mac.")
        }
    }
}

extension Toolchain {
    /// The name under which an install tells the toolchain which mod sets to build with (comma-separated ids of
    /// `visionos/mods.json`; empty: none).
    public static let gameModsVariable = "KLEPTON_GAME_MODS"

    /// The mods this toolchain offers, when it honours `gameModsVariable` and describes them.
    public func gameMods() -> GameMods? {
        guard let text = try? String(contentsOf: root.appendingPathComponent("visionos/gen_xcodeproj.py"), encoding: .utf8),
              text.contains(Toolchain.gameModsVariable),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("visionos/mods_fetch.py").path) else { return nil }
        return GameMods.load(toolchainRoot: root)
    }

    /// Runs `visionos/mods_fetch.py` for the sets and reports what it says (`GameModsFetch`). The key, when the player
    /// wants it used, goes into the script's environment under the name the description gives and nowhere else: not
    /// into the log (the script's promise) and not into this program's own output.
    public func fetchGameMods(sets: [String], mods: GameMods, key: String?, environment: [String: String], log: URL,
                              stop: GameModsFetchStop? = nil, report: (String) -> Void) throws {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env.merge(environment) { _, new in new }
        env[Toolchain.gameModsVariable] = sets.joined(separator: ",")
        if let variable = mods.source?.key?.variable {
            env[variable] = key                       // (never one this program happened to be started with)
        }
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["mods_fetch.py"]
        p.currentDirectoryURL = root.appendingPathComponent("visionos", isDirectory: true)
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        try p.run()
        stop?.attach(p)
        let source = mods.source?.name ?? L("the mods' site", "der Seite der Mods")
        var pending = Data()
        var stopped = ""
        func take(_ line: String) {
            handle.write(Data((line + "\n").utf8))
            if let event = GameModsFetch.event(in: line) {
                if let sentence = GameModsFetch.sentence(for: event, source: source, usesKey: key != nil) { report(sentence) }
            } else if line.hasPrefix("!! mods:") {
                stopped = GameModsFetch.clean(String(line.dropFirst("!! mods:".count)).trimmingCharacters(in: .whitespaces))
            }
        }
        while true {
            let chunk = out.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0a) {
                take(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...newline)
            }
        }
        if !pending.isEmpty { take(String(decoding: pending, as: UTF8.self)) }
        p.waitUntilExit()
        if stop?.isStopped == true { throw CancellationError() }
        switch p.terminationStatus {
        case 0: return
        case 2: throw GameModsError.notFetched(hint: stopped, log: log)
        default: throw GameModsError.fetchFailed(hint: stopped, log: log)
        }
    }
}

/// Ends a running fetch when the job is cancelled. The fetch waits on the player (a download in the browser, up to a
/// quarter of an hour each), so "the current step finishes first" would mean: not for a long time, or never. The
/// toolchain's script takes SIGTERM as "the player cancelled" and ends what it started itself.
public final class GameModsFetchStop: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stopped = false

    public init() {}

    public var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    func attach(_ p: Process) {
        lock.lock()
        process = p
        let already = stopped
        lock.unlock()
        if already, p.isRunning { p.terminate() }
    }

    public func stop() {
        lock.lock()
        stopped = true
        let p = process
        lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }
}

/// Which mod sets the game in the library was last built with: beside the game's files, so the game's page can say
/// when the build and the choice differ (as the stamp does for the options it carries).
public enum GameModsRecord {
    static func file(store: ContentStore, recipe: Recipe) -> URL {
        store.directory(for: recipe).appendingPathComponent(".game-mods.json")
    }

    public static func built(store: ContentStore, recipe: Recipe) -> [String] {
        guard let data = try? Data(contentsOf: file(store: store, recipe: recipe)),
              let sets = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return sets
    }

    public static func save(_ sets: [String], store: ContentStore, recipe: Recipe) {
        let url = file(store: store, recipe: recipe)
        if sets.isEmpty { try? FileManager.default.removeItem(at: url); return }
        if let data = try? JSONEncoder().encode(sets) { try? data.write(to: url, options: .atomic) }
    }
}

/// The player's own key for a mods site (Nexus Mods: the personal API key of a Premium account), in the login
/// keychain like the Meta token (`TokenStore`: through `/usr/bin/security`, the secret over standard input, read back
/// after writing). One entry per site, named by the variable the toolchain takes the key in.
public struct ModsKeyStore: Sendable {
    public static let service = "avpplay-mods-key"
    public var service: String
    public init(service: String = ModsKeyStore.service) { self.service = service }

    /// A key is one line of the characters such keys are made of; anything else is neither stored nor handed on.
    public static func isPlausible(_ key: String) -> Bool {
        key.count >= 16 && key.count <= 512
            && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+/=_-.".contains($0)) }
    }

    static func account(_ variable: String) -> String? {
        GameMods.isSafeVariable(variable) ? variable.lowercased().replacingOccurrences(of: "_", with: "-") : nil
    }

    public func read(variable: String) -> String? {
        guard let account = ModsKeyStore.account(variable) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return ModsKeyStore.isPlausible(key) ? key : nil
    }

    public func has(variable: String) -> Bool { read(variable: variable) != nil }

    public func write(key: String, variable: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ModsKeyStore.isPlausible(key) else { throw TokenError.malformed }
        guard let account = ModsKeyStore.account(variable), TokenStore.isSafeAccount(service) else { throw TokenError.badAccountName }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["-i"]
        let input = Pipe()
        p.standardInput = input
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()
        input.fileHandleForWriting.write(Data("add-generic-password -U -s \(service) -a \(account) -w \(key)\n".utf8))
        try? input.fileHandleForWriting.close()
        p.waitUntilExit()
        guard p.terminationStatus == 0, read(variable: variable) == key else {
            throw TokenError.keychain(L("entry not readable or truncated after writing", "Eintrag nach dem Schreiben nicht lesbar oder verkürzt"))
        }
    }

    @discardableResult
    public func delete(variable: String) -> Bool {
        guard let account = ModsKeyStore.account(variable), TokenStore.isSafeAccount(service) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["delete-generic-password", "-s", service, "-a", account]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

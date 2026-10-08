import Foundation
import Darwin

public enum LoginError: Error, CustomStringConvertible, Equatable {
    case toolMissing(String)
    case wrongSigner(String)
    case couldNotStart(String)
    case toolFailed(Int32)
    case noToken

    public var description: String {
        switch self {
        case .toolMissing(let p):
            return L("Meta's tool ovr-platform-util wasn't found at \(p). Download it from Meta and put it there, or point to it with --tool.",
                     "Metas Werkzeug ovr-platform-util liegt nicht unter \(p). Bei Meta laden und dort ablegen oder mit --tool angeben.")
        case .wrongSigner(let who):
            return L("The file isn't signed by Meta (\(who)). It will not be run.",
                     "Die Datei ist nicht von Meta signiert (\(who)). Sie wird nicht gestartet.")
        case .couldNotStart(let why): return L("ovr-platform-util couldn't be started: \(why)", "ovr-platform-util ließ sich nicht starten: \(why)")
        case .toolFailed(let status):
            return L("Sign-in wasn't completed (ovr-platform-util exited with status \(status)).",
                     "Die Anmeldung wurde nicht abgeschlossen (ovr-platform-util endete mit Status \(status)).")
        case .noToken: return L("ovr-platform-util didn't output a token.", "ovr-platform-util hat keinen Token ausgegeben.")
        }
    }
}

/// Metas eigenes Kommandozeilenwerkzeug. Es wird nicht mitgeliefert; der Nutzer lädt es bei Meta.
public struct MetaTool: Sendable {
    /// Team-ID von „Facebook Technologies, LLC“ in der Signatur des Werkzeugs.
    public static let expectedTeam = "HXH6UQBHD4"
    public let url: URL
    public init(url: URL) { self.url = url }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/ovr-platform-util")
    }

    /// Gestartet wird nur eine Datei mit gültiger Signatur von Meta.
    public func verify() throws {
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw LoginError.toolMissing(url.path) }
        guard Toolchain.status(["/usr/bin/codesign", "--verify", "--strict", url.path]) == 0 else {
            throw LoginError.wrongSigner(L("signature invalid or missing", "Signatur ungültig oder nicht vorhanden"))
        }
        let info = MetaTool.captureBoth(["/usr/bin/codesign", "-dv", "--verbose=2", url.path])
        let team = info.split(separator: "\n").first { $0.hasPrefix("TeamIdentifier=") }.map { String($0.dropFirst("TeamIdentifier=".count)) }
        guard team == MetaTool.expectedTeam else { throw LoginError.wrongSigner(L("team \(team ?? "unknown")", "Team \(team ?? "unbekannt")")) }
    }

    static func captureBoth(_ argv: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Lässt die Ausgabe des Werkzeugs durch, hält aber den Token zurück: Er soll weder auf dem Bildschirm noch
/// in einem Protokoll erscheinen. Ein Token ist eine lange Folge aus Buchstaben und Ziffern.
///
/// Zurückgehalten wird jede solche Folge, bis sie endet – außer sie entsteht Zeichen für Zeichen: Das ist das
/// Echo dessen, was der Nutzer gerade tippt, und muss sofort erscheinen. Das Werkzeug dagegen schreibt seinen
/// Token am Stück.
public struct TokenSieve: Sendable {
    public static var placeholder: String { L("[Token received – not shown]", "[Token erhalten – wird nicht angezeigt]") }
    static let tokenFrom = 64, typingChunk = 4
    private var run: [UInt8] = []
    private var held = false
    public private(set) var token: String?
    public init() {}

    private static func isTokenByte(_ b: UInt8) -> Bool {
        (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122)
    }

    /// `chunk` ist, was ein einzelner Lesevorgang geliefert hat.
    public mutating func feed(_ chunk: some Collection<UInt8>) -> [UInt8] {
        let typing = chunk.count <= TokenSieve.typingChunk
        var out: [UInt8] = []
        for b in chunk {
            if TokenSieve.isTokenByte(b) {
                if run.isEmpty { held = !typing }
                run.append(b)
                if !held { out.append(b) }
            } else {
                out.append(contentsOf: endRun())
                out.append(b)
            }
        }
        return out
    }

    public mutating func finish() -> [UInt8] { endRun() }

    private mutating func endRun() -> [UInt8] {
        defer { run.removeAll(keepingCapacity: true); held = false }
        guard held else { return [] }                 // schon Zeichen für Zeichen gezeigt
        guard run.count >= TokenSieve.tokenFrom else { return run }
        token = String(decoding: run, as: UTF8.self)
        return Array(TokenSieve.placeholder.utf8)
    }
}

/// Anmeldung bei Meta über `ovr-platform-util get-access-token`.
///
/// E-Mail, Passwort und gegebenenfalls der Code der Zwei-Faktor-Anmeldung gehen vom Nutzer direkt an Metas
/// Werkzeug: Es läuft an einem eigenen Pseudo-Terminal, Tastatureingaben werden unverändert durchgereicht
/// und nirgends gespeichert. Aus der Ausgabe wird nur der Token entnommen.
public enum MetaLogin {
    /// Startet die Anmeldung und liefert den Token. `input` und `output` sind das Terminal des Nutzers.
    public static func run(tool: URL, arguments: [String] = ["get-access-token"],
                           input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO) throws -> String {
        var master: Int32 = -1, slave: Int32 = -1
        var size = winsize()
        let haveSize = ioctl(input, TIOCGWINSZ, &size) == 0
        guard (haveSize ? openpty(&master, &slave, nil, nil, &size) : openpty(&master, &slave, nil, nil, nil)) == 0 else {
            throw LoginError.couldNotStart(String(cString: strerror(errno)))
        }
        defer { close(master) }
        guard let slaveName = ttyname(slave).map({ String(cString: $0) }) else {
            close(slave); throw LoginError.couldNotStart(L("no name for the pseudo-terminal", "kein Name für das Pseudo-Terminal"))
        }

        // Das Kind bekommt eine eigene Sitzung und öffnet das Terminal selbst: so wird es dessen steuerndes
        // Terminal, und Strg-C des Nutzers erreicht das Werkzeug. Alle übrigen Deskriptoren bleiben zu.
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, slaveName, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv: [UnsafeMutablePointer<CChar>?] = ([tool.path] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in argv + envp { free(p) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, tool.path, &actions, &attr, argv, envp)
        close(slave)
        guard rc == 0 else { throw LoginError.couldNotStart(String(cString: strerror(rc))) }

        // Das Terminal des Nutzers roh schalten: Echo und Zeilenbearbeitung macht das Pseudo-Terminal.
        var saved = termios()
        let isTerminal = isatty(input) == 1 && tcgetattr(input, &saved) == 0
        if isTerminal {
            var raw = saved
            cfmakeraw(&raw)
            tcsetattr(input, TCSANOW, &raw)
        }
        defer { if isTerminal { tcsetattr(input, TCSANOW, &saved) } }

        var sieve = TokenSieve()
        var inputOpen = true
        var buffer = [UInt8](repeating: 0, count: 4096)
        func emit(_ bytes: [UInt8]) {
            var rest = bytes[...]
            while !rest.isEmpty {
                let n = rest.withUnsafeBytes { write(output, $0.baseAddress, $0.count) }
                if n <= 0 { break }
                rest = rest.dropFirst(n)
            }
        }
        relay: while true {
            var fds = [pollfd(fd: master, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: inputOpen ? input : -1, events: Int16(POLLIN), revents: 0)]
            if poll(&fds, 2, -1) < 0 { if errno == EINTR { continue }; break }
            if fds[1].revents & Int16(POLLIN | POLLHUP) != 0 {
                let n = read(input, &buffer, buffer.count)
                if n > 0 { _ = buffer.withUnsafeBytes { write(master, $0.baseAddress, n) } } else { inputOpen = false }
            }
            if fds[0].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                let n = read(master, &buffer, buffer.count)
                if n <= 0 { break relay }       // das Werkzeug hat sein Terminal geschlossen
                emit(sieve.feed(buffer[..<n]))
            }
        }
        emit(sieve.finish())

        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        let exited = (status & 0x7f) == 0
        let code = exited ? (status >> 8) & 0xff : -(status & 0x7f)
        guard code == 0 else { throw LoginError.toolFailed(code) }
        guard let token = sieve.token, TokenStore.isPlausible(token) else { throw LoginError.noToken }
        return token
    }
}

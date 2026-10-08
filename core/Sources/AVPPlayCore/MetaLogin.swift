import Foundation
import Darwin

public enum LoginError: Error, CustomStringConvertible, Equatable {
    case toolMissing(String)
    case wrongSigner(String)
    case couldNotStart(String)
    case toolFailed(Int32)
    case noToken
    case notExecutable(String)

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
        case .notExecutable(let p):
            return L("\(p) is Meta's tool, but it is not marked as a program yet – files from a browser never are. Make it executable, or let the app set it up.",
                     "\(p) ist Metas Werkzeug, aber noch nicht als Programm gekennzeichnet – das ist bei Dateien aus dem Browser immer so. Ausführbar machen oder von der App einrichten lassen.")
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

    /// Wo eine Oberfläche ihre eigene Kopie des Werkzeugs hält.
    public static var installedURL: URL {
        DataLocation.base.appendingPathComponent("tools/ovr-platform-util")
    }

    /// Gestartet wird nur eine ausführbare Datei mit gültiger Signatur von Meta.
    public func verify() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw LoginError.toolMissing(url.path) }
        try verifySignature()
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw LoginError.notExecutable(url.path) }
    }

    /// Ist die Datei von Meta signiert? Dafür muss sie nicht ausführbar sein – eine Datei aus dem Browser ist
    /// es nie, und geprüft wird sie trotzdem.
    public func verifySignature() throws {
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw LoginError.toolMissing(url.path) }
        guard Toolchain.status(["/usr/bin/codesign", "--verify", "--strict", url.path]) == 0 else {
            throw LoginError.wrongSigner(L("signature invalid or missing", "Signatur ungültig oder nicht vorhanden"))
        }
        let info = MetaTool.captureBoth(["/usr/bin/codesign", "-dv", "--verbose=2", url.path])
        let team = info.split(separator: "\n").first { $0.hasPrefix("TeamIdentifier=") }.map { String($0.dropFirst("TeamIdentifier=".count)) }
        guard team == MetaTool.expectedTeam else { throw LoginError.wrongSigner(L("team \(team ?? "unknown")", "Team \(team ?? "unbekannt")")) }
    }

    /// Richtet eine geladene Datei als Werkzeug ein: Signatur prüfen, eine eigene Kopie ablegen und nur diese
    /// als Programm kennzeichnen. Die geladene Datei bleibt, wie sie ist. Was macOS der Datei beim Laden
    /// angeheftet hat (die Herkunftsmarke für Gatekeeper), wandert mit der Kopie mit und wird nicht entfernt.
    @discardableResult
    public static func adopt(from source: URL, to destination: URL = MetaTool.installedURL) throws -> MetaTool {
        try MetaTool(url: source).verifySignature()
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fresh = destination.appendingPathExtension("new")
        try? fm.removeItem(at: fresh)
        try fm.copyItem(at: source, to: fresh)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fresh.path)
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: fresh, to: destination)
        let tool = MetaTool(url: destination)
        try tool.verify()
        return tool
    }

    /// Geladene Fassungen des Werkzeugs in einem Ordner, neueste zuerst. Browser hängen bei gleichem Namen
    /// eine Zahl an („ovr-platform-util (1)“); unfertige Downloads werden übergangen.
    public static func downloads(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        let found = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        let unfinished: Set<String> = ["crdownload", "download", "part", "partial", "tmp"]
        return found.filter { url in
            url.lastPathComponent.hasPrefix("ovr-platform-util") && !unfinished.contains(url.pathExtension.lowercased())
                && (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return da > db
        }
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
        var sieve = TokenSieve()
        let code = try Pty.run(tool: tool, arguments: arguments, environment: ProcessInfo.processInfo.environment,
                               input: input, output: output, transform: { sieve.feed($0) }, finish: { sieve.finish() })
        guard code == 0 else { throw LoginError.toolFailed(code) }
        guard let token = sieve.token, TokenStore.isPlausible(token) else { throw LoginError.noToken }
        return token
    }
}

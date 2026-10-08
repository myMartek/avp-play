import Foundation

/// Eine Datei, die Metas Werkzeug für einen Build nennt.
public struct ListedFile: Sendable, Equatable {
    public let name: String
    public let id: String
    /// `APK`, `OBB` oder `ASSET`, wie das Werkzeug es schreibt.
    public let kind: String
    /// Die Größe, wie das Werkzeug sie rundet („2.4GB“) – zum Anzeigen, nicht zum Prüfen.
    public let sizeText: String
}

public enum ListingError: Error, CustomStringConvertible, Equatable {
    case refused(String)
    case nothingListed

    public var description: String {
        switch self {
        case .refused(let why):
            return L("Meta's tool did not list the files of this build: \(why)", "Metas Werkzeug hat die Dateien dieses Builds nicht aufgelistet: \(why)")
        case .nothingListed:
            return L("Meta's tool listed no files for this build.", "Metas Werkzeug hat für diesen Build keine Dateien genannt.")
        }
    }
}

/// Fragt Metas eigenes Werkzeug, aus welchen Dateien ein Build besteht.
///
/// Das ist der einzige dokumentierte Weg zu dieser Liste, und er hat zwei Eigenheiten, die hier bewusst in Kauf
/// genommen werden – der Nutzer hat ihm für genau diesen Zweck zugestimmt (Details eines Spiels öffnen):
///  - Das Werkzeug nimmt den Token nur als Argument. Für die Dauer des Aufrufs ist er damit für andere
///    Programme desselben Benutzers sichtbar. Er wird nie protokolliert, und die Ausgabe wird bereinigt.
///  - Das Werkzeug schreibt ein eigenes Protokoll in den temporären Ordner. Es bekommt dafür einen eigenen,
///    der nach dem Aufruf gelöscht wird.
/// Gefragt wird je Build höchstens einmal je Liste; das Ergebnis hält der Aufrufer fest.
public enum MetaListing {
    public enum Command: String, Sendable {
        /// APK und Haupt-OBB.
        case build = "download-quest-build"
        /// Die weiteren Dateien des Builds.
        case assets = "download-asset-file"
    }

    /// Liest die Zeilen des Werkzeugs: `  <Name>  <Größe>  [ART] <Kennung>`, als Text oder in JSON-Protokollzeilen.
    public static func parse(_ output: String) -> [ListedFile] {
        var files: [ListedFile] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            var line = String(raw)
            if line.hasPrefix("{"), let data = line.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let message = object["message"] as? String {
                line = message
            }
            guard line.hasPrefix(" "), let open = line.lastIndex(of: "["), let close = line[open...].firstIndex(of: "]") else { continue }
            let kind = String(line[line.index(after: open)..<close])
            let id = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            let head = line[..<open].trimmingCharacters(in: .whitespaces)
            // Name und Größe trennt eine Lücke von mindestens zwei Leerzeichen; der Name selbst darf einzelne enthalten.
            guard let gap = head.range(of: "  ", options: .backwards) else { continue }
            let name = head[..<gap.lowerBound].trimmingCharacters(in: .whitespaces)
            let size = head[gap.upperBound...].trimmingCharacters(in: .whitespaces)
            guard CatalogGame.isIdentifier(id), !name.isEmpty, !kind.isEmpty, kind.allSatisfy({ $0.isUppercase || $0 == "_" }),
                  Recipe.isSafeName(name) else { continue }
            files.append(ListedFile(name: name, id: id, kind: kind, sizeText: size))
        }
        return files
    }

    /// Ruft das Werkzeug auf. `tool` muss zuvor als Metas Werkzeug geprüft sein (`MetaTool.verify`).
    public static func list(_ command: Command, buildId: String, tool: URL, token: String) throws -> [ListedFile] {
        guard CatalogGame.isIdentifier(buildId), TokenStore.isPlausible(token) else { throw ListingError.refused("–") }
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("avpplay-list-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: scratch) }

        let p = Process()
        p.executableURL = tool
        p.arguments = [command.rawValue, "-b", buildId, "--list", "--output-format", "json", "-t", token]
        p.currentDirectoryURL = scratch
        var env = ProcessInfo.processInfo.environment
        env["TMPDIR"] = scratch.path + "/"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = Redaction.redact(String(decoding: data, as: UTF8.self)).replacingOccurrences(of: token, with: "<REDACTED>")
        let files = parse(text)
        guard p.terminationStatus == 0 else {
            throw ListingError.refused(MetaListing.reason(in: text) ?? "status \(p.terminationStatus)")
        }
        if files.isEmpty, command == .build { throw ListingError.nothingListed }
        return files
    }

    /// Der Satz, mit dem das Werkzeug ablehnt, soweit es einen sagt.
    static func reason(in output: String) -> String? {
        for raw in output.split(whereSeparator: \.isNewline).reversed() {
            var line = String(raw)
            if line.hasPrefix("{"), let data = line.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let message = object["message"] as? String {
                line = message
            }
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, !text.hasPrefix("Logs are written"), !text.hasPrefix("Total time") { return String(text.prefix(200)) }
        }
        return nil
    }
}

/// Ein Rezept für ein Spiel, das noch niemand geprüft hat: gebaut aus dem, was der Katalog und Metas Werkzeug
/// über den neuesten Build sagen. Es kennt weder genaue Größen noch Prüfsummen und ist entsprechend gekennzeichnet.
public enum DraftRecipe {
    /// Die Kennung eines solchen Rezepts – eindeutig je Store-App und nie die eines mitgelieferten Rezepts.
    public static func identifier(appId: String) -> String { "store-\(appId)" }

    /// Platzhalter für ein Spiel, dessen Dateien noch nicht nachgeschlagen sind: nur Name und Kennungen.
    public static func placeholder(game: CatalogGame) -> Recipe {
        Recipe(schema: Recipe.supportedSchema, id: identifier(appId: game.appId), title: game.title, package: game.package,
               versionName: game.build?.version ?? "", versionCode: game.build?.versionCode ?? 0, store: .init(appId: game.appId),
               toolchain: .init(target: game.target ?? "", minCommit: ""), files: [], addons: nil,
               status: .init(playability: game.status == "verified" ? "verified" : "untested", download: "unknown", notes: nil),
               icon: nil, trees: nil)
    }

    /// Der Name, unter dem die Toolchain ein Spiel versucht, das sie nicht kennt: `x` und die Kennung der Store-App.
    /// Er ist zugleich Ordner, APK-Name und – über die Bundle-ID – die Kennung der App auf dem Gerät.
    public static func genericTarget(appId: String) -> String { "x\(appId)" }

    public static func isGeneric(_ target: String) -> Bool {
        target.hasPrefix("x") && CatalogGame.isIdentifier(String(target.dropFirst()))
    }

    /// Steht als Ziel der Haupt-Datendatei im Entwurf. Wo ein Spiel sie sucht, hängt von seiner Engine ab, und
    /// die kennt erst die Toolchain, wenn das APK entpackt ist – deshalb wird der Ort beim Kopieren eingesetzt.
    public static let obbPlaceholder = "@obb"

    /// - Parameter target: der Name des Spiels in der Toolchain – ein Eintrag ihrer Tabelle oder `genericTarget`.
    public static func make(game: CatalogGame, build: CatalogBuild, files: [ListedFile], target: String,
                            minCommit: String) throws -> Recipe {
        guard let apk = files.first(where: { $0.kind == "APK" }) else { throw ListingError.nothingListed }
        let androidObb = "android-files/Android/obb/\(game.package)"
        var list = [RecipeFile(name: apk.name, role: "apk", id: apk.id, size: nil, sha256: nil, required: true, dest: "",
                               localName: "\(target).apk", locale: nil, source: nil)]
        var seen: Set<String> = [apk.name]
        for file in files where file.kind != "APK" && seen.insert(file.name).inserted {
            let isMain = file.kind == "OBB"
            // Weitere Dateien liegen auf einer Quest immer unter Android/obb/<Paket>; den Ort der Haupt-Datendatei
            // setzt die Toolchain ein.
            let dest = isMain ? obbPlaceholder : androidObb
            list.append(RecipeFile(name: file.name, role: isMain ? "main-obb" : "content-bundle", id: file.id, size: nil, sha256: nil,
                                   required: true, dest: dest, localName: nil, locale: nil, source: nil))
        }
        let recipe = Recipe(schema: Recipe.supportedSchema, id: identifier(appId: game.appId), title: game.title, package: game.package,
                            versionName: build.version, versionCode: build.versionCode, store: .init(appId: game.appId),
                            toolchain: .init(target: target, minCommit: minCommit), files: list, addons: nil,
                            status: .init(playability: "untested", download: "listed", notes: nil), icon: nil, trees: nil)
        try recipe.validate()
        return recipe
    }
}

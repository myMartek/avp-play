import Foundation

/// Die Übergabe an AVP Play Remote: was die Remote braucht, um Spiele allein auf der Brille zu installieren, und
/// was nur ein Mac herstellen kann.
///
/// AVP Play legt es, nachdem es die Remote installiert hat, in deren Datenbereich nach `Documents/handover`. Die
/// Remote nimmt es beim nächsten Start in ihren privaten Bereich und löscht den Ordner; das Meta-Token legt sie
/// dabei in ihren Schlüsselbund.
///
///   handover.json       der Präfix für App-Kennungen und der Kopplungsport der Brille
///   meta-token          das Zugangstoken für Meta
///   library.json        die Bibliothek des Meta-Kontos (`MetaLibraryCache`)
///   recipes.json        die Rezepte der Spiele aus dem Meta-Store, als eine Liste: welche Dateien ein Spiel
///                       braucht, wohin sie gehören, seine Sprachen und Zusatzinhalte
///   klepton-template-<Nummer>-<Commit>.zip   die Laufzeit-Vorlage der Toolchain (`visionos/mktemplate.sh`)
///   klepton-mods-<Versionscode>-<Nummer>-<Commit>.zip   dieselbe Vorlage mit den Mods einer Spielfassung, wenn die
///                       Toolchain welche mitbringt (Beat Saber: eigene Songs)
///   pairing.plist       eine Kopplungsdatei für die Brille – nur, wenn der Aufrufer eine mitgibt; sonst koppelt
///                       sich die Remote auf der Brille selbst
///   asc.json, asc-key.p8   der Team-Schlüssel für Apples Entwicklerkonto
///   built-games.json    die Spiele, deren Programm auf diesem Mac gebaut wird (`Recipe.builder`; Minecraft), und ob
///                       ihre Spielteile hier gebaut sind – auch wenn sie nicht mitgehen: Die Remote sagt dann, was fehlt
///   klepton-macho-<Ziel>-<Nummer>-<Commit>.zip   die App eines solchen Spiels ohne das Spiel, aus derselben Toolchain
///   built-<Kennung>-cover.png   das Bild für die Kachel, aus den Spielteilen gemacht (`ArchiveArt`)
///
/// Die Spielteile selbst (ein paar hundert Megabyte) gehen nur mit, wenn der Nutzer dem für dieses Spiel zugestimmt
/// hat (`Plan.parts`), und liegen nicht im Ordner der Übergabe, sondern bleiben, wo sie hinkommen:
///
///   Documents/parts/<Kennung>/<Datei>.zip   die Spielteile, wie sie im Bestand liegen (`GameParts`)
///   Documents/parts/<Kennung>/parts.json    welche Datei das ist; kommt zuletzt, damit eine halbe Kopie nicht gilt
///
/// Das ist eine Ausnahme von der Regel „das Gerät sieht nie einen Token“: Sie gilt nur, wenn der Nutzer diese
/// Übergabe ausdrücklich eingeschaltet hat, und nur für seine eigene Brille. Wer `prepare` aufruft, entscheidet
/// mit `Inputs.token`, ob das Token mitgeht.
public enum CompanionHandover {
    /// Wohin die Übergabe im Datenbereich der Remote gehört.
    public static let folder = "Documents/handover"
    /// Der Port, unter dem eine Vision Pro ihre Kopplung anbietet, wenn sie keinen anderen nennt.
    public static let defaultPairingPort = 49152

    /// Der Team-Schlüssel für die App Store Connect API: zwei Kennungen und die Schlüsseldatei von Apple.
    public struct AppleKey: Sendable, Equatable {
        public var keyId: String
        public var issuerId: String
        public var file: URL
        public init(keyId: String, issuerId: String, file: URL) {
            self.keyId = keyId
            self.issuerId = issuerId
            self.file = file
        }

        /// Kennungen, wie Apple sie vergibt: zehn Zeichen, und eine UUID.
        public var isPlausible: Bool {
            keyId.count == 10 && keyId.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } && UUID(uuidString: issuerId) != nil
        }
    }

    public struct Inputs: Sendable {
        /// Der ganze Präfix der Spiele-Apps, wie AVP Play ihn führt („<Nutzer>.dev.klepton.target“).
        public var bundlePrefix: String
        public var pairingPort: Int
        /// `nil`: Das Token bleibt auf dem Mac; die Remote kann dann nur Spiele installieren, deren Dateien sie hat.
        public var token: String?
        public var library: URL?
        /// Der Ordner mit den Rezepten von AVP Play.
        public var recipes: URL?
        public var template: URL?
        /// Die Vorlagen mit Mods, die zu `template` gehören.
        public var modTemplates: [URL] = []
        public var pairing: URL?
        public var appleKey: AppleKey?
        /// Die Spiele, deren Programm auf diesem Mac gebaut wird, und was von ihnen mitgeht (`builtGames`).
        public var built: [Built] = []
        /// Die Vorlagen solcher Spiele, die zu `template` gehören.
        public var machoTemplates: [URL] = []

        public init(bundlePrefix: String, pairingPort: Int = CompanionHandover.defaultPairingPort, token: String? = nil,
                    library: URL? = nil, recipes: URL? = nil, template: URL? = nil, pairing: URL? = nil, appleKey: AppleKey? = nil) {
            self.bundlePrefix = bundlePrefix
            self.pairingPort = pairingPort
            self.token = token
            self.library = library
            self.recipes = recipes
            self.template = template
            self.pairing = pairing
            self.appleKey = appleKey
        }
    }

    /// Eine Datei der Übergabe: woher sie kommt und unter welchem Namen sie bei der Remote liegt.
    public struct Item: Sendable, Equatable {
        public let source: URL
        public let name: String
        /// Zugangsdaten: Die Datei entsteht nur für das Kopieren und ist danach wieder weg.
        public let secret: Bool
        /// Der Ordner im Datenbereich der Remote; für fast alles der Ordner der Übergabe.
        public var folder = CompanionHandover.folder
        /// Eine kleine Datei, die immer neu kopiert wird, auch wenn dort schon eine gleich große liegt.
        public var always = false
        public var destination: String { "\(folder)/\(name)" }

        public init(source: URL, name: String, secret: Bool, folder: String = CompanionHandover.folder, always: Bool = false) {
            self.source = source
            self.name = name
            self.secret = secret
            self.folder = folder
            self.always = always
        }
    }

    public enum HandoverError: Error, CustomStringConvertible, Equatable {
        case badPrefix(String)
        case badAppleKey
        case missing(String)
        /// Die installierte Remote nimmt keine Übergabe an: Sie kann Spiele nicht allein installieren.
        case notCapable

        public var description: String {
            switch self {
            case .badPrefix(let p):
                return L("The app identifier prefix “\(p)” is not valid.", "Der Präfix für App-Kennungen „\(p)“ ist nicht gültig.")
            case .badAppleKey:
                return L("The Apple team key is not complete: it needs the key ID, the issuer ID and the key file from App Store Connect.",
                         "Der Team-Schlüssel von Apple ist nicht vollständig: Er braucht die Schlüssel-ID, die Issuer-ID und die Schlüsseldatei aus App Store Connect.")
            case .missing(let path):
                return L("A file for the handover is missing: \(path)", "Eine Datei für die Übergabe fehlt: \(path)")
            case .notCapable:
                return L("The AVP Play Remote on the Vision Pro does not take a handover: this version cannot install games by itself, or it has not been opened since it was installed. Nothing was handed over.",
                         "Die AVP Play Remote auf der Vision Pro nimmt keine Übergabe an: Diese Fassung kann Spiele nicht allein installieren, oder sie wurde seit der Installation noch nicht geöffnet. Es wurde nichts übergeben.")
            }
        }
    }

    /// Was von der Übergabe da ist, in einem Satz – für das Protokoll, ohne etwas davon zu zeigen.
    public static func summary(_ items: [Item]) -> String {
        let names = items.compactMap { item -> String? in
            if item.name == partsRecordName { return nil }
            if item.folder.hasPrefix(partsFolder + "/") {
                let size = ContentStore.fileSize(item.source).map { " (\(megabytes($0)))" } ?? ""
                return L("game parts of \(item.folder.dropFirst(partsFolder.count + 1))\(size)", "Spielteile von \(item.folder.dropFirst(partsFolder.count + 1))\(size)")
            }
            return item.name.hasPrefix("klepton-template-") ? L("runtime template", "Laufzeit-Vorlage")
                : item.name.hasPrefix("klepton-mods-") ? L("runtime template with mods", "Laufzeit-Vorlage mit Mods")
                : item.name.hasPrefix("klepton-macho-") ? L("runtime template of a game built on this Mac", "Laufzeit-Vorlage eines hier gebauten Spiels") : item.name
        }
        return names.joined(separator: ", ")
    }

    /// Stellt die Übergabe zusammen. Die kleinen Dateien, die es so nicht auf der Platte gibt, entstehen in
    /// `staging` – einem Ordner nur für diesen Nutzer, den der Aufrufer danach löscht.
    public static func prepare(_ inputs: Inputs, staging: URL) throws -> [Item] {
        guard Toolchain.isValidBundlePrefix(inputs.bundlePrefix) else { throw HandoverError.badPrefix(inputs.bundlePrefix) }
        let files = FileManager.default
        try files.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        func write(_ name: String, _ data: Data) throws -> URL {
            let file = staging.appendingPathComponent(name)
            guard files.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return file
        }
        func existing(_ url: URL) throws -> URL {
            guard files.fileExists(atPath: url.path) else { throw HandoverError.missing(url.lastPathComponent) }
            return url
        }

        var items: [Item] = []
        let facts: [String: Any] = ["bundlePrefix": inputs.bundlePrefix, "pairingPort": inputs.pairingPort]
        items.append(Item(source: try write("handover.json", try JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys])),
                          name: "handover.json", secret: false))
        if let token = inputs.token, TokenStore.isPlausible(token) {
            items.append(Item(source: try write("meta-token", Data(token.utf8)), name: "meta-token", secret: true))
        }
        if let library = inputs.library, files.fileExists(atPath: library.path) {
            items.append(Item(source: library, name: "library.json", secret: false))
        }
        if let recipes = inputs.recipes {
            // Nur Spiele aus dem Meta-Store: Andere kann die Remote allein nicht holen. Ein Rezept, das sich nicht
            // lesen lässt, bleibt weg, statt die Übergabe aufzuhalten.
            let list = try recipeList(in: recipes)
            if !list.isEmpty {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                items.append(Item(source: try write(recipesName, try encoder.encode(list)), name: recipesName, secret: false))
            }
        }
        if let template = inputs.template {
            items.append(Item(source: try existing(template), name: template.lastPathComponent, secret: false))
            for mods in inputs.modTemplates { items.append(Item(source: try existing(mods), name: mods.lastPathComponent, secret: false)) }
        }
        // Spiele, deren Programm auf diesem Mac gebaut wird: die Liste immer (auch ohne Spielteile – dann sagt die
        // Remote, was fehlt), ihre Vorlagen, ihr Bild; die Spielteile nur, wo der Aufrufer sie mitgibt.
        if !inputs.built.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let manifest = BuiltManifest(format: 1, games: inputs.built.map(\.game))
            items.append(Item(source: try write(builtGamesName, try encoder.encode(manifest)), name: builtGamesName, secret: false, always: true))
            for template in inputs.machoTemplates { items.append(Item(source: try existing(template), name: template.lastPathComponent, secret: false)) }
            for built in inputs.built {
                if let cover = built.cover, files.fileExists(atPath: cover.path) {
                    items.append(Item(source: cover, name: "built-\(built.game.id)-cover.png", secret: false))
                }
                guard let parts = built.parts, let name = built.game.parts.name, let size = built.game.parts.size, let sha = built.game.parts.sha256 else { continue }
                let folder = "\(partsFolder)/\(built.game.id)"
                items.append(Item(source: try existing(parts), name: name, secret: false, folder: folder))
                let record = PartsRecord(name: name, size: size, sha256: sha, versionCode: built.game.versionCode)
                items.append(Item(source: try write("parts-\(built.game.id).json", try encoder.encode(record)), name: partsRecordName, secret: false,
                                  folder: folder, always: true))
            }
        }
        if let pairing = inputs.pairing {
            items.append(Item(source: try existing(pairing), name: "pairing.plist", secret: true))
        }
        if let key = inputs.appleKey {
            guard key.isPlausible else { throw HandoverError.badAppleKey }
            let facts = ["keyID": key.keyId, "issuerID": key.issuerId]
            items.append(Item(source: try write("asc.json", try JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys])),
                              name: "asc.json", secret: true))
            items.append(Item(source: try existing(key.file), name: "asc-key.p8", secret: true))
        }
        return items
    }

    /// Der Name der Rezeptliste in der Übergabe.
    public static let recipesName = "recipes.json"

    /// Die Rezepte, die mitgehen: jedes Spiel aus dem Meta-Store, in der Fassung, die AVP Play installiert.
    public static func recipeList(in directory: URL) throws -> [Recipe] {
        let store = RecipeStore(directory: directory)
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return urls.compactMap { try? store.load(url: $0) }.filter { $0.store.appId != nil }
    }

    // MARK: Spiele, deren Programm auf diesem Mac gebaut wird

    /// Der Name der Liste in der Übergabe, der Ordner der Spielteile im Datenbereich der Remote und die Notiz darin.
    public static let builtGamesName = "built-games.json"
    public static let partsFolder = "Documents/parts"
    public static let partsRecordName = "parts.json"

    /// Ein solches Spiel, wie die Remote es liest (`BuiltGame` dort): was es ist, und wie es um seine Spielteile steht.
    public struct BuiltGame: Codable, Sendable, Equatable {
        public var id: String
        public var title: String
        public var target: String
        public var versionName: String
        public var versionCode: Int
        public var parts: Parts
        /// Was man zum Spielen braucht (`Recipe.gameAccount`): Überschrift und Absätze, je Sprache.
        public var account: Account?
        public var playability: String?

        public struct Parts: Codable, Sendable, Equatable {
            /// `missing`: hier noch nie gebaut. `built`: liegen im Bestand, gehen nicht mit. `handedOver`: gehen mit.
            public var state: String
            public var name: String?
            public var size: Int64?
            public var sha256: String?
        }

        public struct Account: Codable, Sendable, Equatable {
            public var title: [String: String]
            public var notes: [[String: String]]
        }
    }

    struct BuiltManifest: Codable, Equatable {
        var format: Int
        var games: [BuiltGame]
    }

    struct PartsRecord: Codable, Equatable {
        var name: String
        var size: Int64
        var sha256: String
        var versionCode: Int
    }

    /// Ein solches Spiel für die Übergabe: der Eintrag der Liste, und die Dateien, die mitgehen.
    public struct Built: Sendable, Equatable {
        public var game: BuiltGame
        /// Die Spielteile im Bestand – nur gesetzt, wenn sie mitgehen sollen.
        public var parts: URL?
        /// Die Spielteile im Bestand, ob sie mitgehen oder nicht (für die Vorlage: Sie nimmt das Icon des Spiels daraus).
        public var archive: URL?
        public var cover: URL?

        /// Wie viel die Übergabe für dieses Spiel aufs Gerät kopiert, wenn die Spielteile mitgehen.
        public var bytes: Int64 { game.parts.size ?? 0 }
    }

    public static func megabytes(_ bytes: Int64) -> String { String(format: "%.0f MB", Double(bytes) / 1_048_576) }

    /// Was die Oberfläche zu einem solchen Spiel fragt, bevor etwas kopiert wird: ob seine Spielteile gebaut sind und wie groß.
    public struct PartsOffer: Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        /// `nil`: auf diesem Mac noch nicht gebaut.
        public var bytes: Int64?

        /// Wie viel Platz die Brille für die Installation frei haben muss: Die App ist ausgepackt etwa anderthalbmal
        /// so groß wie die Spielteile und liegt unterwegs dreimal dort, dazu ein Gigabyte Luft. Dieselbe Rechnung wie
        /// in der Remote.
        public var spaceOnHeadset: Int64? { bytes.map { $0 * 17 / 4 + (1 << 30) } }
    }

    public static func partsOffers(in directory: URL, store: ContentStore) -> [PartsOffer] {
        let recipes = RecipeStore(directory: directory)
        let urls = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let loaded: [Recipe] = urls.compactMap { try? recipes.load(url: $0) }
        return loaded.filter { $0.builder != nil && Recipe.isSafeName($0.id) }.map { recipe in
            PartsOffer(id: recipe.id, title: recipe.title,
                       bytes: GameParts.built(recipe: recipe, store: store, local: GameParts.usesLocalBuilder(recipe))?.record.size)
        }
    }

    /// Die Spiele mit einem Bauwerkzeug unter den Rezepten, und der Stand ihrer Spielteile im Bestand. Die Spielteile
    /// gehen nur für die Spiele mit, deren Kennung in `agreed` steht: Dem hat der Nutzer zugestimmt, in Kenntnis der Größe.
    public static func builtGames(in directory: URL, store: ContentStore, agreed: Set<String>) -> [Built] {
        let recipes = RecipeStore(directory: directory)
        let urls = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let loaded: [Recipe] = urls.compactMap { try? recipes.load(url: $0) }
        return loaded.filter { $0.builder != nil && Recipe.isSafeName($0.id) }.map { (recipe: Recipe) -> Built in
            let have = GameParts.built(recipe: recipe, store: store, local: GameParts.usesLocalBuilder(recipe))
            let goes = have != nil && agreed.contains(recipe.id)
            let parts = BuiltGame.Parts(state: have == nil ? "missing" : goes ? "handedOver" : "built", name: have?.url.lastPathComponent,
                                        size: have?.record.size, sha256: have?.record.sha256)
            let account = recipe.gameAccount.map { BuiltGame.Account(title: $0.title.values, notes: $0.notes.map(\.values)) }
            let game = BuiltGame(id: recipe.id, title: recipe.title, target: recipe.toolchain.target, versionName: recipe.versionName,
                                 versionCode: recipe.versionCode, parts: parts, account: account, playability: recipe.status.playability)
            // Das Bild entsteht aus den Spielteilen und liegt dann neben ihnen.
            let cover = have != nil && ArchiveArt.hero(recipe: recipe, store: store) != nil ? ArchiveArt.heroURL(store: store, recipe: recipe) : nil
            return Built(game: game, parts: goes ? have?.url : nil, archive: have?.url, cover: cover)
        }
    }

    // MARK: Die Laufzeit-Vorlage

    /// Ob diese Toolchain eine Vorlage bauen kann: Das Skript dafür gibt es erst in neueren.
    public static func canBuildTemplate(_ toolchain: Toolchain) -> Bool {
        FileManager.default.fileExists(atPath: toolchain.root.appendingPathComponent("visionos/mktemplate.sh").path)
    }

    /// Der Name der Vorlage einer Toolchain.
    public static func templateName(_ toolchain: Toolchain) -> String {
        "klepton-template-\(toolchain.version())-\(toolchain.commit()).zip"
    }

    /// Die Vorlagen mit Mods zu dieser Toolchain, soweit sie in `cache` liegen: je Fassung eines Spiels eine.
    public static func modTemplates(toolchain: Toolchain, cache: URL) -> [URL] {
        let suffix = "-\(toolchain.version())-\(toolchain.commit()).zip"
        return ((try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? [])
            .filter { $0.hasPrefix("klepton-mods-") && $0.hasSuffix(suffix) }.sorted()
            .map { cache.appendingPathComponent($0) }
    }

    /// Ob diese Toolchain auch die Vorlage eines Spiels baut, dessen Programm auf dem Mac gebaut wird: Ihr Skript
    /// nennt dann die Archive dafür.
    public static func canBuildMachoTemplates(_ toolchain: Toolchain) -> Bool {
        let script = toolchain.root.appendingPathComponent("visionos/mktemplate.sh")
        return (try? String(contentsOf: script, encoding: .utf8))?.contains("klepton-macho-") ?? false
    }

    /// Die Vorlagen solcher Spiele zu dieser Toolchain, soweit sie in `cache` liegen: je Ziel eine
    /// („klepton-macho-<Ziel>-<Nummer>-<Commit>.zip“).
    public static func machoTemplates(toolchain: Toolchain, cache: URL) -> [URL] {
        let suffix = "-\(toolchain.version())-\(toolchain.commit()).zip"
        return ((try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? [])
            .filter { $0.hasPrefix("klepton-macho-") && $0.hasSuffix(suffix) }.sorted()
            .map { cache.appendingPathComponent($0) }
    }

    /// Das Ziel, für das eine solche Vorlage ist, aus ihrem Namen.
    public static func machoTarget(_ template: URL, toolchain: Toolchain) -> String? {
        let name = template.lastPathComponent, suffix = "-\(toolchain.version())-\(toolchain.commit()).zip"
        guard name.hasPrefix("klepton-macho-"), name.hasSuffix(suffix) else { return nil }
        let target = String(name.dropFirst("klepton-macho-".count).dropLast(suffix.count))
        return target.isEmpty ? nil : target
    }

    /// Die Vorlage dieser Toolchain: aus `cache`, sonst gebaut. Der Bau kompiliert die Laufzeit einmal mit Xcode
    /// (ein paar Minuten) und signiert nichts; `nil`, wenn die Toolchain keine Vorlage bauen kann. Bringt die
    /// Toolchain Mods mit, entsteht dabei auch die Vorlage mit ihnen (`modTemplates`) – und, wenn sie es kann, die
    /// Vorlagen der Spiele, deren Programm auf dem Mac gebaut wird (`machoTemplates`). `gameArchive` sind die
    /// Spielteile eines solchen Spiels, wenn es sie gibt: Die Vorlage nimmt dann das Icon des Spiels daraus.
    public static func template(toolchain: Toolchain, cache: URL, wantsMacho: Bool = false, gameArchive: URL? = nil,
                                report: (String) -> Void) throws -> URL? {
        guard canBuildTemplate(toolchain) else { return nil }
        let files = FileManager.default
        let name = templateName(toolchain)
        let cached = cache.appendingPathComponent(name)
        let wantsMods = !toolchain.coreModsProfiles.isEmpty
        let needsMacho = wantsMacho && canBuildMachoTemplates(toolchain)
        if files.fileExists(atPath: cached.path), !wantsMods || !modTemplates(toolchain: toolchain, cache: cache).isEmpty,
           !needsMacho || !machoTemplates(toolchain: toolchain, cache: cache).isEmpty { return cached }
        try files.createDirectory(at: cache, withIntermediateDirectories: true)
        report(L("Building the runtime template of toolchain \(toolchain.name) (once per toolchain, a few minutes) …",
                 "Die Laufzeit-Vorlage der Toolchain \(toolchain.name) wird gebaut (einmal pro Toolchain, ein paar Minuten) …"))
        let log = cache.appendingPathComponent("last-template.log")
        files.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [toolchain.root.appendingPathComponent("visionos/mktemplate.sh").path]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        if let gameArchive, files.fileExists(atPath: gameArchive.path) { env[Toolchain.gameArchiveVariable] = gameArchive.standardizedFileURL.path }
        p.environment = env
        p.currentDirectoryURL = toolchain.root
        p.standardOutput = handle
        p.standardError = handle
        p.standardInput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        let built = toolchain.root.appendingPathComponent("visionos/build").appendingPathComponent(name)
        guard p.terminationStatus == 0, files.fileExists(atPath: built.path) else {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            let hint = text.split(separator: "\n").last(where: { $0.contains("error:") || $0.hasPrefix("!!") }).map { String($0.prefix(300)) }
                ?? "mktemplate.sh \(p.terminationStatus)"
            throw ToolchainError.buildFailed(log: log, hint: hint)
        }
        // Erst daneben ablegen, dann umbenennen; und die Vorlagen älterer Toolchains gehen.
        let folder = toolchain.root.appendingPathComponent("visionos/build")
        let suffix = String(name.dropFirst("klepton-template".count))
        let withMods = ((try? files.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { ($0.hasPrefix("klepton-mods-") || $0.hasPrefix("klepton-macho-")) && $0.hasSuffix(suffix) }
        for arrived in [name] + withMods {
            let arriving = cache.appendingPathComponent(".arriving-\(UUID().uuidString)")
            try files.copyItem(at: folder.appendingPathComponent(arrived), to: arriving)
            try? files.removeItem(at: cache.appendingPathComponent(arrived))
            try files.moveItem(at: arriving, to: cache.appendingPathComponent(arrived))
        }
        for old in (try? files.contentsOfDirectory(atPath: cache.path)) ?? []
        where (old.hasPrefix("klepton-template-") || old.hasPrefix("klepton-mods-") || old.hasPrefix("klepton-macho-")) && !old.hasSuffix(suffix) {
            try? files.removeItem(at: cache.appendingPathComponent(old))
        }
        return cached
    }

    // MARK: Die ganze Übergabe

    /// Was der Nutzer für die Übergabe eingestellt hat. Steht im Auftrag, mit dem AVP Play die Remote installiert.
    public struct Plan: Codable, Sendable, Equatable {
        /// Der ganze Präfix der Spiele-Apps („<Nutzer>.dev.klepton.target“).
        public var bundlePrefix: String
        /// Das Meta-Token geht nur mit, wenn der Nutzer das eigens eingeschaltet hat.
        public var withToken: Bool
        public var account: String
        public var recipes: URL?
        public var library: URL?
        /// Die Toolchain, deren Laufzeit-Vorlage mitgeht.
        public var toolchain: URL?
        /// Der Bestand, in dem die Spielteile der hier gebauten Spiele liegen. Ohne ihn geht von solchen Spielen nichts mit.
        public var store: URL?
        /// Die Spiele, deren Spielteile mitgehen: Für jedes hat der Nutzer zugestimmt, nachdem ihm die Größe genannt wurde.
        /// Ohne Zustimmung geht nur die Liste mit, nie die Spielteile.
        public var parts: [String]?

        public init(bundlePrefix: String, withToken: Bool = false, account: String = "default", recipes: URL? = nil, library: URL? = nil,
                    toolchain: URL? = nil, store: URL? = nil, parts: [String]? = nil) {
            self.bundlePrefix = bundlePrefix
            self.withToken = withToken
            self.account = account
            self.recipes = recipes
            self.library = library
            self.toolchain = toolchain
            self.store = store
            self.parts = parts
        }
    }

    /// Diese Datei legt eine Remote, die Spiele allein installieren kann, bei jedem Start in ihren Ordner
    /// „Documents“. Ohne sie geht nichts aufs Gerät: Eine Remote, die die Übergabe nie liest, soll keine Zugangsdaten
    /// in ihrem Ordner liegen haben.
    public static let marker = "standalone.json"

    public static func accepts(_ documents: [RemoteFile]) -> Bool {
        documents.contains { !$0.isDirectory && $0.relativePath == marker && $0.size > 0 }
    }

    /// Stellt die Übergabe nach `plan` zusammen und bringt sie aufs Gerät. `list` ist `DeviceControl.files` für
    /// einen Ordner der Remote, `copy` ist `DeviceControl.copy`. Die Zugangsdaten kommen aus dem Schlüsselbund und
    /// liegen nur für das Kopieren in einem Ordner für diesen Nutzer.
    ///
    /// - Parameter trusted: AVP Play hat die App selbst mit dem Teil für die Übergabe gebaut; dann braucht es ihr
    ///   Kennzeichen nicht (gleich nach der Installation gibt es das noch nicht).
    public static func deliver(_ plan: Plan, cache: URL, trusted: Bool = false, secrets: HandoverSecrets = HandoverSecrets(),
                               tokens: TokenStore = TokenStore(), list: (String) throws -> [RemoteFile], copy: (URL, String) throws -> Void,
                               report: (String) -> Void) throws {
        guard trusted || accepts((try? list("Documents")) ?? []) else { throw HandoverError.notCapable }
        let files = FileManager.default
        let staging = files.temporaryDirectory.appendingPathComponent("avpplay-handover-\(UUID().uuidString)", isDirectory: true)
        defer { try? files.removeItem(at: staging) }
        let sources = staging.appendingPathComponent("sources", isDirectory: true)
        try files.createDirectory(at: sources, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        func secret(_ name: String, _ data: Data) throws -> URL {
            let file = sources.appendingPathComponent(name)
            guard files.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            return file
        }

        var inputs = Inputs(bundlePrefix: plan.bundlePrefix, library: plan.library, recipes: plan.recipes)
        if plan.withToken {
            do {
                inputs.token = try tokens.read(account: plan.account)
            } catch {
                report(L("The Meta sign-in is not handed over: \(error)", "Die Meta-Anmeldung wird nicht übergeben: \(error)"))
            }
        }
        if let key = secrets.appleKey() {
            inputs.appleKey = AppleKey(keyId: key.keyId, issuerId: key.issuerId, file: try secret("key.p8", Data(key.pem.utf8)))
        }
        if let recipes = plan.recipes, let store = plan.store {
            inputs.built = builtGames(in: recipes, store: ContentStore(root: store), agreed: Set(plan.parts ?? []))
        }
        if let root = plan.toolchain, let toolchain = try? Toolchain(root: root) {
            inputs.template = try template(toolchain: toolchain, cache: cache, wantsMacho: !inputs.built.isEmpty,
                                           gameArchive: inputs.built.compactMap(\.archive).first, report: report)
            if inputs.template != nil {
                inputs.modTemplates = modTemplates(toolchain: toolchain, cache: cache)
                let targets = Set(inputs.built.map(\.game.target))
                inputs.machoTemplates = machoTemplates(toolchain: toolchain, cache: cache).filter { machoTarget($0, toolchain: toolchain).map(targets.contains) ?? false }
            } else {
                report(L("Toolchain \(toolchain.name) cannot build a runtime template; none is handed over.",
                         "Die Toolchain \(toolchain.name) kann keine Laufzeit-Vorlage bauen; es wird keine übergeben."))
            }
        }
        for line in builtNotes(inputs.built, templates: inputs.machoTemplates) { report(line) }
        let items = try prepare(inputs, staging: staging.appendingPathComponent("made", isDirectory: true))
        try push(items, present: (try? list(folder)) ?? [], elsewhere: { (try? list($0)) ?? [] }, copy: copy, report: report)
        // Was der Remote danach noch fehlt, sagt sie selbst unter „Einrichtung“; hier steht, was nicht mitging.
        var missing: [String] = []
        if inputs.token == nil { missing.append(L("the Meta sign-in", "die Meta-Anmeldung")) }
        if inputs.appleKey == nil { missing.append(L("the Apple team key", "der Team-Schlüssel von Apple")) }
        if inputs.template == nil { missing.append(L("the runtime template", "die Laufzeit-Vorlage")) }
        if !missing.isEmpty {
            report(L("Not handed over: \(missing.joined(separator: ", ")).", "Nicht übergeben: \(missing.joined(separator: ", "))."))
        }
    }

    /// Was zu den hier gebauten Spielen zu sagen ist, bevor kopiert wird: wie viel mitgeht, und was nicht mitgeht und warum.
    public static func builtNotes(_ built: [Built], templates: [URL]) -> [String] {
        built.map { entry in
            let title = entry.game.title
            if entry.game.parts.state == "missing" {
                return L("\(title): its parts have not been built on this Mac yet. Install it here once; until then AVP Play Remote says that it needs the Mac first.",
                         "\(title): Seine Spielteile sind auf diesem Mac noch nicht gebaut. Installiere es hier einmal; bis dahin sagt AVP Play Remote, dass es zuerst den Mac braucht.")
            }
            let size = megabytes(entry.bytes)
            if entry.parts == nil {
                return L("\(title): its parts (\(size)) are not handed over – that has not been switched on for this game.",
                         "\(title): Seine Spielteile (\(size)) werden nicht übergeben – das ist für dieses Spiel nicht eingeschaltet.")
            }
            let template = templates.contains { $0.lastPathComponent.hasPrefix("klepton-macho-\(entry.game.target)-") }
            return L("\(title): its parts (\(size)) are copied to the Vision Pro, unless they are there already.",
                     "\(title): Seine Spielteile (\(size)) werden auf die Vision Pro kopiert, falls sie dort noch nicht liegen.")
                + (template ? "" : L(" The installed toolchain has no runtime template for this game, so it cannot be installed on the headset yet.",
                                     " Die installierte Toolchain hat keine Laufzeit-Vorlage für dieses Spiel; auf der Brille lässt es sich damit noch nicht installieren."))
        }
    }

    // MARK: Aufs Gerät

    /// Kopiert die Übergabe in den Datenbereich der Remote. Was dort schon gleich groß liegt und keine
    /// Zugangsdaten sind, bleibt (die Vorlage hat ein paar Megabyte). `copy` ist `DeviceControl.copy`.
    /// `elsewhere` nennt, was in einem anderen Ordner der Remote liegt (die Spielteile unter `partsFolder`): Auch
    /// sie werden nicht noch einmal kopiert, wenn sie dort gleich groß liegen.
    public static func push(_ items: [Item], present: [RemoteFile], elsewhere: (String) -> [RemoteFile] = { _ in [] },
                            copy: (URL, String) throws -> Void, report: (String) -> Void) throws {
        let files = FileManager.default
        var listed: [String: [RemoteFile]] = [folder: present]
        for item in items {
            let size = ((try? files.attributesOfItem(atPath: item.source.path))?[.size] as? NSNumber)?.int64Value
            if listed[item.folder] == nil { listed[item.folder] = elsewhere(item.folder) }
            if !item.secret, !item.always, let size,
               listed[item.folder]?.contains(where: { !$0.isDirectory && $0.relativePath == item.name && $0.size == size }) == true {
                continue
            }
            try copy(item.source, item.destination)
        }
        report(L("Handed over to AVP Play Remote: \(summary(items)).", "An AVP Play Remote übergeben: \(summary(items))."))
    }
}

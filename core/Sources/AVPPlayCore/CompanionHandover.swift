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
        public var destination: String { "\(CompanionHandover.folder)/\(name)" }
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
        let names = items.map { $0.name.hasPrefix("klepton-template-") ? L("runtime template", "Laufzeit-Vorlage")
            : $0.name.hasPrefix("klepton-mods-") ? L("runtime template with mods", "Laufzeit-Vorlage mit Mods") : $0.name }
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

    /// Die Vorlage dieser Toolchain: aus `cache`, sonst gebaut. Der Bau kompiliert die Laufzeit einmal mit Xcode
    /// (ein paar Minuten) und signiert nichts; `nil`, wenn die Toolchain keine Vorlage bauen kann. Bringt die
    /// Toolchain Mods mit, entsteht dabei auch die Vorlage mit ihnen (`modTemplates`).
    public static func template(toolchain: Toolchain, cache: URL, report: (String) -> Void) throws -> URL? {
        guard canBuildTemplate(toolchain) else { return nil }
        let files = FileManager.default
        let name = templateName(toolchain)
        let cached = cache.appendingPathComponent(name)
        let wantsMods = !toolchain.coreModsProfiles.isEmpty
        if files.fileExists(atPath: cached.path), !wantsMods || !modTemplates(toolchain: toolchain, cache: cache).isEmpty { return cached }
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
        let withMods = ((try? files.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix("klepton-mods-") && $0.hasSuffix(suffix) }
        for arrived in [name] + withMods {
            let arriving = cache.appendingPathComponent(".arriving-\(UUID().uuidString)")
            try files.copyItem(at: folder.appendingPathComponent(arrived), to: arriving)
            try? files.removeItem(at: cache.appendingPathComponent(arrived))
            try files.moveItem(at: arriving, to: cache.appendingPathComponent(arrived))
        }
        for old in (try? files.contentsOfDirectory(atPath: cache.path)) ?? []
        where (old.hasPrefix("klepton-template-") || old.hasPrefix("klepton-mods-")) && !old.hasSuffix(suffix) {
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

        public init(bundlePrefix: String, withToken: Bool = false, account: String = "default", recipes: URL? = nil, library: URL? = nil,
                    toolchain: URL? = nil) {
            self.bundlePrefix = bundlePrefix
            self.withToken = withToken
            self.account = account
            self.recipes = recipes
            self.library = library
            self.toolchain = toolchain
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
        if let root = plan.toolchain, let toolchain = try? Toolchain(root: root) {
            inputs.template = try template(toolchain: toolchain, cache: cache, report: report)
            if inputs.template != nil {
                inputs.modTemplates = modTemplates(toolchain: toolchain, cache: cache)
            } else {
                report(L("Toolchain \(toolchain.name) cannot build a runtime template; none is handed over.",
                         "Die Toolchain \(toolchain.name) kann keine Laufzeit-Vorlage bauen; es wird keine übergeben."))
            }
        }
        let items = try prepare(inputs, staging: staging.appendingPathComponent("made", isDirectory: true))
        try push(items, present: (try? list(folder)) ?? [], copy: copy, report: report)
        // Was der Remote danach noch fehlt, sagt sie selbst unter „Einrichtung“; hier steht, was nicht mitging.
        var missing: [String] = []
        if inputs.token == nil { missing.append(L("the Meta sign-in", "die Meta-Anmeldung")) }
        if inputs.appleKey == nil { missing.append(L("the Apple team key", "der Team-Schlüssel von Apple")) }
        if inputs.template == nil { missing.append(L("the runtime template", "die Laufzeit-Vorlage")) }
        if !missing.isEmpty {
            report(L("Not handed over: \(missing.joined(separator: ", ")).", "Nicht übergeben: \(missing.joined(separator: ", "))."))
        }
    }

    // MARK: Aufs Gerät

    /// Kopiert die Übergabe in den Datenbereich der Remote. Was dort schon gleich groß liegt und keine
    /// Zugangsdaten sind, bleibt (die Vorlage hat ein paar Megabyte). `copy` ist `DeviceControl.copy`.
    public static func push(_ items: [Item], present: [RemoteFile], copy: (URL, String) throws -> Void,
                            report: (String) -> Void) throws {
        let files = FileManager.default
        for item in items {
            let size = ((try? files.attributesOfItem(atPath: item.source.path))?[.size] as? NSNumber)?.int64Value
            if !item.secret, let size, present.contains(where: { !$0.isDirectory && $0.relativePath == item.name && $0.size == size }) {
                continue
            }
            try copy(item.source, item.destination)
        }
        report(L("Handed over to AVP Play Remote: \(summary(items)).", "An AVP Play Remote übergeben: \(summary(items))."))
    }
}

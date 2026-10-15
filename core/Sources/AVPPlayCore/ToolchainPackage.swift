import Foundation

/// Was ein Toolchain-Paket über sich sagt. Liegt als `toolchain.json` im Paket und – ergänzt um Prüfsumme und
/// Größe des Archivs – als eigene Datei daneben.
public struct ToolchainManifest: Codable, Sendable, Equatable {
    public static let currentFormat = 1
    public var format: Int
    /// Fortlaufende Nummer: die Zahl der Commits des Fork-Stands. Größer heißt neuer.
    public var version: Int
    /// Der Fork-Stand, aus dem das Paket gebaut wurde (kurzer Hash).
    public var commit: String
    /// Kurze Hashes aller Stände, die in diesem enthalten sind. Daran wird `minCommit` eines Rezepts geprüft,
    /// denn ein installiertes Paket hat keine Versionsgeschichte mehr.
    public var ancestors: [String]
    public var created: Date
    public var archive: String?
    public var sha256: String?
    public var size: Int64?
    /// Die Nummer des letzten Stands, der etwas an den gebauten Spielen geändert hat. Ein Spiel, das mit diesem
    /// oder einem späteren Stand gebaut wurde, ist aktuell – auch wenn die Toolchain seither neuere Nummern
    /// bekommen hat, etwa für ein geändertes Bauskript. Fehlt bei älteren Paketen; dann gilt `version`.
    public var appRevision: Int?
    /// Gesetzt bei einer Arbeitskopie, an der jemand etwas geändert hat (etwa eine KI beim Reparieren eines Spiels):
    /// kein Stand des Projekts mehr, auch wenn Nummer und Commit die des Pakets sind, aus dem sie entstand. Überall,
    /// wo der Stand genannt wird, steht dann „(modified)“ dabei.
    public var modified: Bool?

    public func contains(commit wanted: String) -> Bool {
        guard wanted.count >= 7, wanted.allSatisfy({ $0.isHexDigit }) else { return false }
        return ancestors.contains { $0.hasPrefix(wanted) || wanted.hasPrefix($0) }
    }
}

public enum PackageError: Error, CustomStringConvertible, Equatable {
    case notACheckout(String)
    case uncommittedChanges([String])
    case missingPrebuilt(String)
    case tool(String)
    case manifestMissing(String)
    case checksumMismatch
    case sizeMismatch
    case contentMismatch
    case notAWorkingCopy(String)
    case installedPackage(String)

    public var description: String {
        switch self {
        case .notACheckout(let p):
            return L("\(p) is not a working copy of the fork (no git state, or visionos/run.sh is missing).",
                     "\(p) ist kein Arbeitsverzeichnis des Forks (kein Git-Stand oder visionos/run.sh fehlt).")
        case .uncommittedChanges(let f):
            let list = f.prefix(3).joined(separator: ", ")
            return L("The fork has uncommitted changes (\(list)). A package can only be made from a committed state.",
                     "Im Fork gibt es nicht eingecheckte Änderungen (\(list)). Ein Paket entsteht nur aus einem eingecheckten Stand.")
        case .missingPrebuilt(let p): return L("A prebuilt part is missing: \(p).", "Vorgebauter Teil fehlt: \(p).")
        case .tool(let m): return L("Helper tool failed: \(m)", "Hilfsprogramm fehlgeschlagen: \(m)")
        case .manifestMissing(let p): return L("The archive's description \(p) is missing.", "Zum Archiv fehlt die Beschreibung \(p).")
        case .checksumMismatch:
            return L("The archive's checksum doesn't match its description. It will not be installed.",
                     "Die Prüfsumme des Archivs stimmt nicht mit der Beschreibung überein. Es wird nicht installiert.")
        case .sizeMismatch:
            return L("The archive's size doesn't match its description. It will not be installed.",
                     "Die Größe des Archivs stimmt nicht mit der Beschreibung überein. Es wird nicht installiert.")
        case .contentMismatch:
            return L("The archive contains a different state than its description says. It will not be installed.",
                     "Das Archiv enthält einen anderen Stand, als seine Beschreibung angibt. Es wird nicht installiert.")
        case .notAWorkingCopy(let p):
            return L("\(p) is not a copy of an installed toolchain (visionos/run.sh or toolchain.json is missing).",
                     "\(p) ist keine Kopie einer installierten Toolchain (visionos/run.sh oder toolchain.json fehlt).")
        case .installedPackage(let p):
            return L("\(p) is a toolchain that AVP Play installed. Work in a copy of it and mark the copy.",
                     "\(p) ist eine von AVP Play installierte Toolchain. Arbeite in einer Kopie davon und markiere die Kopie.")
        }
    }
}

/// Baut aus einem Arbeitsverzeichnis des Forks ein Toolchain-Paket und installiert Pakete.
///
/// Ein Paket enthält den eingecheckten Quelltext des Forks, die vorgebauten Bibliotheken Dritter (ANGLE,
/// MoltenVK) samt deren Lizenztexten und seine Beschreibung. Es enthält nie Spielinhalte: aus dem
/// Arbeitsverzeichnis wird nur genommen, was versioniert ist, dazu ausdrücklich benannte Ordner.
public struct ToolchainPackager: Sendable {
    /// Vorgebaute Teile, relativ zur Wurzel des Forks. Ohne sie ließe sich auf einem Rechner ohne den
    /// 20 GB großen ANGLE-Quellbaum nichts bauen.
    static let prebuilt = ["vendor/out/xros", "vendor/out/xrsim",
                           "vendor-moltenvk/out/include", "vendor-moltenvk/out/xros", "vendor-moltenvk/out/xrsim"]

    public let root: URL
    public init(root: URL) { self.root = root }

    public static var defaultRoot: URL {
        DataLocation.base.appendingPathComponent("toolchains", isDirectory: true)
    }

    // MARK: Packen

    public static func pack(checkout: URL, to directory: URL, now: Date = Date()) throws -> (archive: URL, manifest: ToolchainManifest) {
        let fm = FileManager.default
        let git = { (args: [String]) throws -> String in
            try run(["/usr/bin/git", "-C", checkout.path] + args)
        }
        guard fm.fileExists(atPath: checkout.appendingPathComponent("visionos/run.sh").path),
              let head = try? git(["rev-parse", "--short=7", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines),
              head.count >= 7 else { throw PackageError.notACheckout(checkout.path) }
        // Nur Versioniertes zählt; nicht eingecheckte Änderungen an versionierten Dateien wären im Paket unsichtbar.
        let dirty = try git(["status", "--porcelain", "--untracked-files=no"]).split(separator: "\n").map { String($0.dropFirst(3)) }
        guard dirty.isEmpty else { throw PackageError.uncommittedChanges(dirty) }
        for part in prebuilt where !fm.fileExists(atPath: checkout.appendingPathComponent(part).path) {
            throw PackageError.missingPrebuilt(part)
        }
        let version = Int(try git(["rev-list", "--count", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let ancestors = try git(["rev-list", "--abbrev-commit", "--abbrev=7", "HEAD"]).split(separator: "\n").map(String.init)
        var manifest = ToolchainManifest(format: ToolchainManifest.currentFormat, version: version, commit: head,
                                         ancestors: ancestors, created: now, archive: nil, sha256: nil, size: nil)
        manifest.appRevision = ToolchainPackager.appRevision(checkout: checkout)

        let stage = fm.temporaryDirectory.appendingPathComponent("qi-toolchain-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        let sources = stage.appendingPathComponent("src.tar")
        _ = try run(["/usr/bin/git", "-C", checkout.path, "archive", "--format=tar", "-o", sources.path, "HEAD"])
        let tree = stage.appendingPathComponent("tree", isDirectory: true)
        try fm.createDirectory(at: tree, withIntermediateDirectories: true)
        _ = try run(["/usr/bin/tar", "-xf", sources.path, "-C", tree.path])
        for part in prebuilt {
            let target = tree.appendingPathComponent(part)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: checkout.appendingPathComponent(part), to: target)
        }
        try encoder.encode(manifest).write(to: tree.appendingPathComponent("toolchain.json"), options: .atomic)

        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "klepton-toolchain-\(version)-\(head).tar.gz"
        let archive = directory.appendingPathComponent(name)
        try? fm.removeItem(at: archive)
        _ = try run(["/usr/bin/tar", "-czf", archive.path, "-C", tree.path, "."])
        manifest.archive = name
        manifest.sha256 = try Hashing.sha256(of: archive)
        manifest.size = ContentStore.fileSize(archive)
        try encoder.encode(manifest).write(to: sidecar(for: archive), options: .atomic)
        return (archive, manifest)
    }

    /// Was am Fork die gebauten Spiele nicht verändert: Bau- und Installationsskripte, Texte, Tests und die
    /// Grafiken, die ohnehin beim Bauen aus dem Bestand des Nutzers entstehen.
    static let pathsWithoutEffectOnApps = ["visionos/run.sh", "visionos/stage_assets.sh", "visionos/stage_sync.py", "visionos/Assets.xcassets", "build_run_*.sh",
                                           "*.md", "tests", "spikes", ".gitignore", "third-party-licenses", "LICENSE"]

    /// Die Nummer des letzten Commits, der etwas außerhalb dieser Pfade geändert hat; `nil`, wenn Git nichts sagt.
    public static func appRevision(checkout: URL) -> Int? {
        func git(_ args: [String]) -> String? {
            (try? run(["/usr/bin/git", "-C", checkout.path] + args))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let spec = ["."] + pathsWithoutEffectOnApps.map { ":(exclude,glob)\($0)" } + pathsWithoutEffectOnApps.map { ":(exclude,glob)\($0)/**" }
        guard let commit = git(["log", "-1", "--format=%H", "--"] + spec), !commit.isEmpty,
              let count = git(["rev-list", "--count", commit]) else { return nil }
        return Int(count)
    }

    /// Die Beschreibung liegt neben dem Archiv: `<Archiv>.json`.
    public static func sidecar(for archive: URL) -> URL { archive.appendingPathExtension("json") }

    // MARK: Installieren

    /// Prüft das Archiv gegen seine Beschreibung und entpackt es. Ein schon vorhandener gleicher Stand bleibt.
    public func install(archive: URL) throws -> Toolchain {
        let fm = FileManager.default
        let side = ToolchainPackager.sidecar(for: archive)
        guard let data = try? Data(contentsOf: side),
              let manifest = try? ToolchainPackager.decoder.decode(ToolchainManifest.self, from: data),
              let expected = manifest.sha256 else { throw PackageError.manifestMissing(side.lastPathComponent) }
        if let size = manifest.size, ContentStore.fileSize(archive) != size { throw PackageError.sizeMismatch }
        guard try Hashing.sha256(of: archive) == expected.lowercased() else { throw PackageError.checksumMismatch }

        let target = directory(for: manifest)
        if let existing = try? Toolchain(root: target), existing.manifest?.commit == manifest.commit { return existing }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let fresh = root.appendingPathComponent(".\(target.lastPathComponent).new", isDirectory: true)
        try? fm.removeItem(at: fresh)
        try fm.createDirectory(at: fresh, withIntermediateDirectories: true)
        _ = try ToolchainPackager.run(["/usr/bin/tar", "-xzf", archive.path, "-C", fresh.path])
        // Was ausgepackt wurde, muss der Stand sein, den die geprüfte Beschreibung nennt.
        guard let inner = try? ToolchainPackager.decoder.decode(
                ToolchainManifest.self, from: Data(contentsOf: fresh.appendingPathComponent("toolchain.json"))),
              inner.commit == manifest.commit, inner.version == manifest.version else {
            try? fm.removeItem(at: fresh)
            throw PackageError.contentMismatch
        }
        try? fm.removeItem(at: target)
        try fm.moveItem(at: fresh, to: target)
        return try Toolchain(root: target)
    }

    public func directory(for manifest: ToolchainManifest) -> URL {
        root.appendingPathComponent("\(manifest.version)-\(manifest.commit)", isDirectory: true)
    }

    /// Installierte Pakete, neueste zuerst.
    public func installed() -> [Toolchain] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        // Die Nummer einmal je Paket lesen, nicht bei jedem Vergleich des Sortierens.
        return urls.filter { !$0.lastPathComponent.hasPrefix(".") }
            .compactMap { url -> (toolchain: Toolchain, version: Int)? in
                guard let t = try? Toolchain(root: url), let m = t.manifest else { return nil }
                return (t, m.version)
            }
            .sorted { $0.version > $1.version }
            .map(\.toolchain)
    }

    /// Liegt dieser Ordner unter den installierten Paketen?
    public func holds(_ toolchain: URL) -> Bool {
        toolchain.resolvingSymlinksInPath().deletingLastPathComponent().path == root.resolvingSymlinksInPath().path
    }

    /// Kennzeichnet eine Arbeitskopie als bearbeitet (`modified` in ihrer `toolchain.json`). Ein installiertes Paket
    /// wird nicht gekennzeichnet: Es ist der Stand des Projekts und soll es bleiben.
    @discardableResult
    public func markModified(_ copy: URL) throws -> Toolchain {
        guard let toolchain = try? Toolchain(root: copy), var manifest = toolchain.manifest else {
            throw PackageError.notAWorkingCopy(copy.path)
        }
        guard !holds(copy) else { throw PackageError.installedPackage(copy.path) }
        if manifest.modified != true {
            manifest.modified = true
            try ToolchainPackager.encoder.encode(manifest).write(to: copy.appendingPathComponent("toolchain.json"), options: .atomic)
        }
        return toolchain
    }

    /// Entfernt installierte Pakete bis auf die `keep` neuesten und gibt die entfernten zurück.
    /// Ein Paket wächst beim Bauen auf über ein Gigabyte; alte Stände braucht nur noch ein Auftrag,
    /// der mit ihnen begonnen wurde – die nennt der Aufrufer in `protecting` (Commit oder dessen Anfang).
    @discardableResult
    public func prune(keep: Int = 1, protecting commits: Set<String> = []) throws -> [ToolchainManifest] {
        var removed: [ToolchainManifest] = []
        for t in installed().dropFirst(max(keep, 1)) {
            guard let m = t.manifest else { continue }
            if commits.contains(where: { !$0.isEmpty && (m.commit.hasPrefix($0) || $0.hasPrefix(m.commit)) }) { continue }
            try FileManager.default.removeItem(at: t.root)
            removed.append(m)
        }
        return removed
    }

    /// Das Aufräumen von selbst: wie `prune`, aber nur, wenn gerade kein Prozess baut oder aufs Gerät kopiert –
    /// die App, die Kommandozeile und der Hintergrunddienst bauen alle im Ordner einer Toolchain, und der darf
    /// ihnen nicht unter den Händen verschwinden. Läuft etwas, passiert nichts (`nil`); der nächste Anlass holt
    /// es nach. Dazu fallen die Reste eines abgebrochenen Auspackens weg (`.<Name>.new`), sobald sie älter als
    /// eine Stunde sind.
    ///
    /// Mit `leftoversOlderThan` räumt es auch in der neuesten Toolchain auf: was ein Spiel beim Bauen dort
    /// hinterlässt, fällt weg, wenn sein letzter Bau länger her ist (siehe `removeBuildLeftovers`).
    @discardableResult
    public func pruneWhenIdle(protecting commits: Set<String> = [], leftoversOlderThan age: TimeInterval? = nil,
                              apkNames: [String: String] = [:], busyTargets: Set<String> = [],
                              lock: URL = ProcessLock.installURL, now: Date = Date()) -> Cleared? {
        guard let held = ProcessLock.acquire(lock) else { return nil }
        defer { held.release() }
        let toolchains = removeOlderAndUnpackingLeftovers(protecting: commits, now: now)
        var games: [String] = []
        if let age, let newest = installed().first {
            games = ToolchainPackager.removeBuildLeftovers(in: newest.root, olderThan: age, apkNames: apkNames,
                                                           skipping: busyTargets, now: now)
        }
        return Cleared(toolchains: toolchains, games: games)
    }

    /// Was ein Aufräumen entfernt hat: ältere Toolchains und die Spiele, deren Bau-Reste wegfielen (Target-Namen).
    public struct Cleared: Sendable, Equatable {
        public var toolchains: [ToolchainManifest]
        public var games: [String]
        public var isEmpty: Bool { toolchains.isEmpty && games.isEmpty }
    }

    /// Wann ein Spiel in diesem Toolchain-Ordner zuletzt gebaut wurde: Xcode schreibt bei jedem Bau die Datei
    /// `info.plist` seines Zwischenordners neu; fehlt der, zählt der Stempel des entpackten Baums.
    public static func lastBuilt(target: String, in root: URL) -> Date? {
        let marks = [root.appendingPathComponent("visionos/build/dd-device-\(target)/info.plist"),
                     root.appendingPathComponent("\(target)/.qi-prepared")]
        return marks.compactMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }.first
    }

    /// Entfernt, was Spiele beim Bauen im Ordner einer Toolchain hinterlassen, sobald ihr letzter Bau länger als
    /// `age` her ist: Xcodes Zwischenstände, die übersetzten Bibliotheken, den entpackten Baum und die Kopie des
    /// APK – zusammen leicht ein Gigabyte und mehr je Spiel. Nichts davon ist das Spiel selbst: Die App auf der
    /// Vision Pro und die Downloads bleiben, und ein späterer Bau legt alles neu an (er dauert dann etwa eine
    /// Minute länger). Spiele, deren Signatur wöchentlich erneuert wird, werden dabei jedes Mal neu gebaut und
    /// behalten ihre Reste so von selbst.
    ///
    /// Ein Spiel wird nur angefasst, wenn sich sein letzter Bau datieren lässt und es nicht in `skipping` steht
    /// (Aufträge, die warten oder laufen). Gibt die Target-Namen zurück.
    @discardableResult
    public static func removeBuildLeftovers(in root: URL, olderThan age: TimeInterval, apkNames: [String: String] = [:],
                                            skipping: Set<String> = [], now: Date = Date()) -> [String] {
        let fm = FileManager.default
        let build = root.appendingPathComponent("visionos/build", isDirectory: true)
        var targets = Set<String>()
        for name in (try? fm.contentsOfDirectory(atPath: build.path)) ?? [] where name.hasPrefix("dd-device-") {
            targets.insert(String(name.dropFirst("dd-device-".count)))
        }
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        where fm.fileExists(atPath: root.appendingPathComponent("\(name)/.qi-prepared").path) {
            targets.insert(name)
        }
        var cleared: [String] = []
        for target in targets.sorted() where Recipe.isSafeName(target) && !skipping.contains(target) {
            // Der Zwischenordner des Baus mit eigenem Startfenster heißt wie der gewöhnliche mit Anhang; er gehört
            // zum selben Spiel und nicht zu einem eigenen.
            if target.hasSuffix("-launcher"), targets.contains(String(target.dropLast("-launcher".count))) { continue }
            guard let built = lastBuilt(target: target, in: root), now.timeIntervalSince(built) > age else { continue }
            var paths = ["visionos/build/dd-device-\(target)", "visionos/build/dd-device-\(target)-launcher",
                         "visionos/build/dd-sim-\(target)", "visionos/build/guest/\(target)",
                         "visionos/Frameworks/\(target)", "\(target).apk"]
            // Der Ordner mit dem Namen des Targets nur, wenn er ein entpackter Baum ist (er trägt dann den Stempel
            // der Vorbereitung): Ein Target, das wie ein Ordner der Toolchain selbst heißt, darf den nicht mitnehmen.
            if fm.fileExists(atPath: root.appendingPathComponent("\(target)/.qi-prepared").path) { paths.append(target) }
            if let apk = apkNames[target], Recipe.isSafeName(apk), apk.hasSuffix(".apk") { paths.append(apk) }
            var any = false
            for path in paths {
                let url = root.appendingPathComponent(path)
                guard fm.fileExists(atPath: url.path) else { continue }
                if (try? fm.removeItem(at: url)) != nil { any = true }
            }
            if any { cleared.append(target) }
        }
        return cleared
    }

    private func removeOlderAndUnpackingLeftovers(protecting commits: Set<String>, now: Date) -> [ToolchainManifest] {
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where url.lastPathComponent.hasPrefix(".") && url.pathExtension == "new" {
            let changed = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(changed) > 3600 { try? fm.removeItem(at: url) }
        }
        return (try? prune(keep: 1, protecting: commits)) ?? []
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }
    static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    @discardableResult
    static func run(_ argv: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let problem = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let text = String(decoding: problem, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
            throw PackageError.tool("\(URL(fileURLWithPath: argv[0]).lastPathComponent) \(argv.dropFirst().first ?? ""): \(text)")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Die Versionsangaben, die eine installierte App trägt. Die App-Liste des Geräts ist die einzige Stelle, an
/// der sich vom Mac aus ablesen lässt, was installiert ist – also steht dort, welche Spielversion es ist und
/// mit welchem Toolchain-Stand sie gebaut wurde.
public enum AppStamp {
    /// `CFBundleShortVersionString`: die Version des Spiels, auf höchstens drei Zahlen gekürzt
    /// ("1.40.8_7379" → "1.40.8", "Steam-Build 25487405" → "25487405").
    public static func short(versionName: String) -> String {
        // Folgen aus Ziffern und Punkten; die erste brauchbare gewinnt.
        var tokens: [String] = []
        var current = ""
        for ch in versionName {
            if ch.isASCII, ch.isNumber || ch == "." {
                current.append(ch)
            } else {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        for token in tokens {
            let parts = token.split(separator: ".").map(String.init).prefix(3)
            if !parts.isEmpty, parts.allSatisfy({ $0.count <= 9 }) { return parts.joined(separator: ".") }
        }
        return "1.0"
    }

    /// `CFBundleVersion`: Versionscode des Spiels und Nummer der Toolchain – und eine dritte Zahl, wenn der Bau
    /// etwas Besonderes ist: 1 für eine bearbeitete Arbeitskopie der Toolchain, 2 für einen Bau, in dem die
    /// experimentellen Implementierungen von Anfang an eingeschaltet sind (`Toolchain.experimentalSwitches`),
    /// 3 für beides; dazu 4, wenn das MetalFX-Hochskalieren von Anfang an eingeschaltet ist (`Toolchain.metalFXSwitch`).
    /// Hat ein MetalFX-Bau eine vorgegebene Startauflösung (`MetalFXResolution`), kommt 8 × die Stufe darunter hinzu:
    /// (100 − Prozent) / 5, also 5 für 75 % – so übernimmt das Erneuern sie unverändert.
    /// Mehr als drei Zahlen nimmt der Schlüssel nicht.
    public static func build(versionCode: Int, toolchainVersion: Int, modified: Bool = false, experimental: Bool = false,
                             metalFX: Bool = false, resolution: Int? = nil) -> String {
        let step = metalFX ? resolutionStep(resolution) : 0
        let extra = (modified ? 1 : 0) + (experimental ? 2 : 0) + (metalFX ? 4 : 0) + 8 * step
        return "\(max(0, min(versionCode, 999_999_999))).\(max(0, min(toolchainVersion, 999_999_999)))" + (extra > 0 ? ".\(extra)" : "")
    }

    /// Was ein Stempel dieses Werkzeugs über den Bau sagt.
    public struct Built: Sendable, Equatable {
        public var versionCode: Int
        public var toolchain: Int
        public var modified: Bool
        /// Die experimentellen Implementierungen sind in diesem Bau von Anfang an eingeschaltet.
        public var experimental = false
        /// Das MetalFX-Hochskalieren ist in diesem Bau von Anfang an eingeschaltet.
        public var metalFX = false
        /// Die Auflösung in Prozent, mit der ein MetalFX-Bau beginnt; `nil`: die des Targets.
        public var resolution: Int?

        public init(versionCode: Int, toolchain: Int, modified: Bool, experimental: Bool = false, metalFX: Bool = false,
                    resolution: Int? = nil) {
            self.versionCode = versionCode; self.toolchain = toolchain; self.modified = modified; self.experimental = experimental
            self.metalFX = metalFX; self.resolution = resolution
        }
    }

    /// Die Stufe unter 100 % (`MetalFXResolution.range` in Schritten von 5); 0 ohne Vorgabe oder bei 100 %.
    private static func resolutionStep(_ percent: Int?) -> Int {
        guard let percent else { return 0 }
        return (MetalFXResolution.full - MetalFXResolution.clamped(percent)) / 5
    }
    private static let maxResolutionStep = (MetalFXResolution.full - MetalFXResolution.range.lowerBound) / 5

    /// Liest `CFBundleVersion` einer installierten App; `nil`, wenn es kein Stempel dieses Werkzeugs ist.
    public static func parse(_ bundleVersion: String) -> Built? {
        let parts = bundleVersion.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 2 || parts.count == 3, let code = parts[0], let toolchain = parts[1] else { return nil }
        guard parts.count == 2 || parts[2] != nil else { return nil }
        // Die dritte Zahl ist eine Summe (siehe `build`): Schalter in den unteren drei Bits, darüber die Stufe der
        // Auflösung, die es nur mit MetalFX gibt. Alles andere stammt nicht von diesem Werkzeug und sagt nichts.
        let extra = parts.count == 3 ? parts[2] ?? 0 : 0
        let step = extra >> 3
        let valid = extra >= 0 && step <= maxResolutionStep && (step == 0 || extra & 4 != 0)
        let bits = valid ? extra & 7 : 0
        return Built(versionCode: code, toolchain: toolchain, modified: bits & 1 != 0, experimental: bits & 2 != 0,
                     metalFX: bits & 4 != 0, resolution: valid && step > 0 ? MetalFXResolution.full - 5 * step : nil)
    }
}

import Foundation

public enum ToolchainError: Error, CustomStringConvertible {
    case notAToolchain(String)
    case tooOld(have: String, need: String)
    case buildFailed(log: URL, hint: String)
    case syncFailed(log: URL, hint: String)
    case installFailed(log: URL, hint: String)

    public var description: String {
        switch self {
        case .notAToolchain(let p): return L("There is no toolchain at \(p) (visionos/run.sh is missing).", "Unter \(p) liegt keine Toolchain (visionos/run.sh fehlt).")
        case .tooOld(let have, let need):
            return L("The toolchain (\(have)) is older than the recipe requires (\(need)).",
                     "Die Toolchain (\(have)) ist älter als vom Rezept verlangt (\(need)).")
        case .syncFailed(let log, let hint):
            let detail = hint.isEmpty ? "" : ": \(hint)"
            return L("Syncing the game data failed\(detail). Log: \(log.path)",
                     "Abgleich der Spieldaten fehlgeschlagen\(detail). Protokoll: \(log.path)")
        case .installFailed(let log, let hint):
            let detail = hint.isEmpty ? "" : ": \(hint)"
            return L("The game was built, but installing it on the Vision Pro failed\(detail). Log: \(log.path)",
                     "Das Spiel wurde gebaut, aber die Installation auf der Vision Pro ist gescheitert\(detail). Protokoll: \(log.path)")
        case .buildFailed(let log, let hint):
            let detail = hint.isEmpty ? "" : ": \(hint)"
            return L("Build or installation failed\(detail). Log: \(log.path)",
                     "Build oder Installation fehlgeschlagen\(detail). Protokoll: \(log.path)")
        }
    }
}

/// Die Toolchain ist der projektgepflegte Klepton-Fork samt vorgebauter Frameworks. Sie enthält alles
/// Spielspezifische, das Code braucht; das Rezept nennt nur das Target und den Mindeststand.
public struct Toolchain: Sendable {
    public let root: URL
    public init(root: URL) throws {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("visionos/run.sh").path) else {
            throw ToolchainError.notAToolchain(root.path)
        }
        self.root = root
    }

    /// Die Beschreibung eines installierten Pakets; `nil` bei einem Arbeitsverzeichnis des Forks.
    public var manifest: ToolchainManifest? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("toolchain.json")) else { return nil }
        return try? ToolchainPackager.decoder.decode(ToolchainManifest.self, from: data)
    }

    public func commit() -> String {
        if let m = manifest { return m.commit }
        let out = (try? Toolchain.capture(["/usr/bin/git", "-C", root.path, "rev-parse", "--short=7", "HEAD"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? "unbekannt" : out
    }

    /// Ab welcher Nummer ein gebautes Spiel als aktuell gilt: der letzte Stand, der an den Spielen selbst etwas
    /// geändert hat. Ohne diese Angabe (ältere Pakete) die Nummer des Stands.
    public func appRevision() -> Int {
        if let m = manifest { return m.appRevision ?? m.version }
        return ToolchainPackager.appRevision(checkout: root) ?? version()
    }

    /// Die fortlaufende Nummer des Stands (Zahl der Commits); 0, wenn sie sich nicht ermitteln lässt.
    public func version() -> Int {
        if let m = manifest { return m.version }
        let out = (try? Toolchain.capture(["/usr/bin/git", "-C", root.path, "rev-list", "--count", "HEAD"])) ?? ""
        return Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Enthält der Stand der Toolchain den vom Rezept verlangten Commit? Ein Paket beantwortet das aus seiner
    /// Beschreibung, ein Arbeitsverzeichnis aus der Versionsgeschichte.
    public func satisfies(minCommit: String) -> Bool {
        guard !minCommit.isEmpty, minCommit.allSatisfy({ $0.isHexDigit }) else { return false }
        if let m = manifest { return m.contains(commit: minCommit) }
        return Toolchain.status(["/usr/bin/git", "-C", root.path, "merge-base", "--is-ancestor", minCommit, "HEAD"]) == 0
    }

    /// Die Bundle-ID, unter der die Toolchain ein Target baut, sofern keine andere vorgegeben wird.
    public static func defaultBundleId(target: String, user: String = NSUserName()) -> String {
        let scope = user.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return "\(scope.isEmpty ? "user" : scope).dev.klepton.target.\(target)"
    }

    /// Legt APK und entpackten Baum dort ab, wo die Toolchain sie erwartet. Der Baum entsteht frisch aus dem
    /// APK im Bestand; ein schon passender Baum (gleiche APK-Prüfsumme) bleibt stehen.
    public func heroDirectory(target: String) -> URL {
        root.appendingPathComponent("visionos/Assets.xcassets/StartHero-\(target).imageset", isDirectory: true)
    }

    public func prepare(recipe: Recipe, store: ContentStore) throws {
        // Das Bild fürs Startfenster. Jedes Mal neu: es ist klein, und ein inzwischen hinterlegtes eigenes Bild
        // soll ohne weiteres Zutun greifen.
        if Recipe.isSafeName(recipe.toolchain.target), let hero = StartHero.choose(recipe: recipe, store: store) {
            try? StartHero.writeImageSet(hero.image, to: heroDirectory(target: recipe.toolchain.target))
        }
        guard let apk = recipe.files.first(where: { $0.role == "apk" }), let localName = apk.localName else {
            // Ein Spiel aus Ordnerbeständen hat kein APK: die Toolchain liest die Bäume selbst, hier fehlt nur das Icon.
            guard recipe.trees?.isEmpty == false, Recipe.isSafeName(recipe.toolchain.target) else {
                throw RecipeError.invalid(L("the APK or its destination name is missing", "APK oder dessen Zielname fehlt"))
            }
            if let icon = Toolchain.chooseIcon(recipe: recipe, store: store)?.source {
                try AppIcon.writeImageStack(icon, to: iconDirectory(target: recipe.toolchain.target))
            }
            return
        }
        let target = recipe.toolchain.target
        guard Recipe.isSafeName(target), Recipe.isSafeName(localName) else { throw RecipeError.invalid(L("target name", "Target-Name")) }
        let source = store.url(for: apk, in: recipe)
        let tree = root.appendingPathComponent(target, isDirectory: true)
        let stamp = tree.appendingPathComponent(".qi-prepared")
        // Ein vom Nutzer hinterlegtes Icon gehört zum Stand: ändert es sich, wird neu vorbereitet.
        let customIcon = Toolchain.customIconURL(store: store, recipe: recipe)
        let storeCover = Toolchain.storeCoverURL(store: store, recipe: recipe)
        let customMark = (try? Hashing.sha256(of: customIcon)).map { String($0.prefix(16)) } ?? "-"
        let coverMark = (try? Hashing.sha256(of: storeCover)).map { String($0.prefix(16)) } ?? "-"
        let want = "\(apk.sha256 ?? "ohne-pruefsumme") \(recipe.versionCode) icon4 \(customMark) \(coverMark)"
        let fm = FileManager.default

        let apkTarget = root.appendingPathComponent(localName)
        if ContentStore.fileSize(apkTarget) != ContentStore.fileSize(source) {
            try? fm.removeItem(at: apkTarget)
            try fm.copyItem(at: source, to: apkTarget)
        }
        if (try? String(contentsOf: stamp, encoding: .utf8)) == want { return }

        let fresh = root.appendingPathComponent(".\(target).qi-new", isDirectory: true)
        try? fm.removeItem(at: fresh)
        let info = try ApkUnpacker().unpack(apk: source, to: fresh)
        // Ein Entwurf kennt den Paketnamen nur, wenn der Katalog ihn kennt – und der hat ihn nicht für jedes Spiel
        // (Eye of the Temple: leer). Dann gibt es nichts zu vergleichen; der Versionscode bleibt die Prüfung.
        guard recipe.package.isEmpty || info.package == recipe.package, info.versionCode == String(recipe.versionCode) else {
            try? fm.removeItem(at: fresh)
            throw RecipeError.invalid(L("the APK in the library doesn't match the recipe (\(info.package ?? "?"), code \(info.versionCode ?? "?"))",
                                        "Das APK im Bestand passt nicht zum Rezept (\(info.package ?? "?"), Code \(info.versionCode ?? "?"))"))
        }
        // Das Icon des Spiels, falls das APK eines hergibt. Die Toolchain bindet es über den Ordnernamen ein.
        if let icon = Toolchain.chooseIcon(recipe: recipe, store: store)?.source {
            try? AppIcon.writeImageStack(icon, to: iconDirectory(target: target))
        }
        try want.write(to: fresh.appendingPathComponent(".qi-prepared"), atomically: true, encoding: .utf8)
        try? fm.removeItem(at: tree)
        try fm.moveItem(at: fresh, to: tree)
    }

    /// Welches Icon ein Spiel bekommt und woher es stammt. Reihenfolge: eigenes Bild des Nutzers, dann das
    /// Titelbild aus dem Meta-Store (das, was auch die Quest zeigt), dann die Bilder aus der Steam-Bibliothek
    /// des Nutzers (für Titel ohne Meta-Eintrag), dann das Icon aus dem APK – außer es ist nur der Platzhalter
    /// der Engine. Gibt es keins, bleibt es beim Standard der Toolchain.
    public static func chooseIcon(recipe: Recipe, store: ContentStore) -> (source: AppIcon.Source, origin: String)? {
        if let own = AppIcon.custom(at: customIconURL(store: store, recipe: recipe)) { return (own, L("custom image", "eigenes Bild")) }
        if let cover = AppIcon.custom(at: storeCoverURL(store: store, recipe: recipe)) {
            return (cover, L("cover image from the Meta Store", "Titelbild aus dem Meta-Store"))
        }
        if let steam = recipe.icon?.steamAppId, let art = AppIcon.steamLibrary(appId: steam) {
            return (art, L("Steam library", "Steam-Bibliothek"))
        }
        if let apk = recipe.files.first(where: { $0.role == "apk" }),
           let found = try? AppIcon.extract(apk: store.url(for: apk, in: recipe)), !AppIcon.isEnginePlaceholder(found) {
            return (found, L("icon from the APK", "Icon aus dem APK"))
        }
        return nil
    }

    /// Hier kann der Nutzer ein eigenes Icon hinterlegen (PNG, am besten quadratisch und groß).
    public static func customIconURL(store: ContentStore, recipe: Recipe) -> URL {
        store.directory(for: recipe).appendingPathComponent("icon.png")
    }

    /// Das zwischengespeicherte Titelbild aus dem Store (siehe `StoreArt`).
    public static func storeCoverURL(store: ContentStore, recipe: Recipe) -> URL {
        store.directory(for: recipe).appendingPathComponent("store-cover.img")
    }

    public func iconDirectory(target: String) -> URL {
        root.appendingPathComponent("visionos/Assets.xcassets/AppIcon-\(target).solidimagestack", isDirectory: true)
    }

    public func assetsDirectory(recipe: Recipe) -> URL {
        root.appendingPathComponent(recipe.toolchain.target).appendingPathComponent("assets", isDirectory: true)
    }

    /// Dateien, die ein Spiel zusätzlich als Dateien im Datenbereich braucht, obwohl sie auch als übersetzter Code im
    /// Programm stecken: die Qt-Plugins von Steam Link. Qt listet den Ordner auf und liest jede Datei, bevor es sie
    /// lädt; geladen wird dann trotzdem die signierte Fassung. Leer bei allen Spielen, die das nicht brauchen.
    public func qtPlugins(recipe: Recipe) -> [URL] {
        guard let relative = targetValue(recipe.toolchain.target, key: "qtplugins"), !relative.contains("..") else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(relative), includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("libplugins_") && $0.pathExtension == "so" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Anzahl und Gesamtgröße der Asset-Dateien aus dem APK – für den Abgleich mit dem Gerät.
    public func assetsSummary(recipe: Recipe) -> (count: Int, bytes: Int64) {
        var count = 0
        var bytes: Int64 = 0
        guard let walker = FileManager.default.enumerator(at: assetsDirectory(recipe: recipe),
                                                          includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return (0, 0) }
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true { count += 1; bytes += Int64(values?.fileSize ?? 0) }
        }
        return (count, bytes)
    }

    /// Baut das Target und installiert es. Kopiert werden dabei nur die zwei kleinen Metadateien der Toolchain;
    /// die Spieldaten überträgt anschließend das ergänzende Kopieren.
    public func buildAndInstall(recipe: Recipe, team: String, device: Device, bundleId: String?, log: URL,
                                extraEnvironment: [String: String] = [:]) throws {
        guard team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw RecipeError.invalid(L("team ID '\(team)' (expected: 10 characters)", "Team-ID '\(team)' (erwartet: 10 Zeichen)"))
        }
        var env = ProcessInfo.processInfo.environment
        // Nur was macOS und Xcode mitbringen – auf jedem Mac dasselbe, ob dort Homebrew oder ein anderes
        // Python liegt oder nicht. Sonst baut es beim einen mit Werkzeugen, die dem anderen fehlen.
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env["KLEPTON_TEAM"] = team                      // nie die Zertifikats-Erkennung der Toolchain benutzen
        env["KLEPTON_TARGET"] = recipe.toolchain.target
        env["KLEPTON_DEVICE"] = device.udid
        env["KL_SKIP_STAGE"] = "1"
        env["KL_SKIP_LAUNCH"] = "1"
        // Was die App-Liste des Geräts später über diese Installation sagt.
        // Eine installierte App zeigt das Startfenster eines Spiels, nicht den Boot-Bericht der Entwicklung.
        env["KLEPTON_START_SCREEN"] = "1"
        env["KLEPTON_APP_VERSION"] = AppStamp.short(versionName: recipe.versionName)
        env["KLEPTON_APP_BUILD"] = AppStamp.build(versionCode: recipe.versionCode, toolchainVersion: version())
        if let bundleId { env["KLEPTON_BUNDLE_ID"] = bundleId }
        env.merge(Toolchain.genericEnvironment(recipe: recipe)) { _, new in new }
        env.merge(extraEnvironment) { _, new in new }

        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let p = Process()
        p.executableURL = root.appendingPathComponent("visionos/run.sh")
        p.arguments = ["device"]
        p.currentDirectoryURL = root
        p.environment = env
        p.standardOutput = handle
        p.standardError = handle
        p.standardInput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        // Gebaut, aber nicht aufs Gerät gekommen: das ist kein Baufehler und braucht einen anderen Rat.
        if p.terminationStatus != 0, let line = text.split(separator: "\n").last(where: { $0.hasPrefix("!! install FAILED") }) {
            let why = line.dropFirst("!! install FAILED:".count).trimmingCharacters(in: .whitespaces)
            throw ToolchainError.installFailed(log: log, hint: String(why.prefix(200)))
        }
        guard p.terminationStatus == 0, text.contains("BUILD SUCCEEDED") else {
            // Was die Toolchain selbst zur Signatur sagt, geht vor: es nennt die Ursache und den nächsten Handgriff.
            let lines = text.split(separator: "\n")
            if lines.contains(where: { $0.hasPrefix("!! signing:") }) {
                throw ToolchainError.buildFailed(log: log, hint: L(
                    "your Apple developer team has no registered device yet, and registering this Vision Pro did not work. Keep the headset on, unlocked and on the same Wi-Fi as this Mac, then choose “Resume”. If it stops here again, add the headset by hand: Xcode › Window › Devices and Simulators shows its identifier, and it goes under Certificates, Identifiers & Profiles › Devices at developer.apple.com (the team's Admin or Account Holder can do that)",
                    "dein Apple-Entwicklerteam hat noch kein registriertes Gerät, und diese Vision Pro ließ sich nicht registrieren. Headset anlassen, entsperrt und im selben WLAN wie dieser Mac halten, dann „Fortsetzen“ wählen. Hält es hier wieder an, das Headset von Hand eintragen: Xcode › Window › Devices and Simulators zeigt seine Kennung (Identifier), und sie gehört bei developer.apple.com unter Certificates, Identifiers & Profiles › Devices (das kann der Admin oder Account Holder des Teams)"))
            }
            let hint = lines.last { $0.contains("error:") || $0.contains("No profiles") || $0.contains("No Account") }
            throw ToolchainError.buildFailed(log: log, hint: hint.map { String($0.prefix(160)) } ?? "")
        }
    }

    /// Der Ordner, in dem die Toolchain für ein Spiel aus Ordnerbeständen das Abbild dessen aufbaut, was aufs
    /// Gerät gehört (`Documents/lx`). Es besteht aus harten Links und kostet keinen Platz – solange es auf demselben
    /// Laufwerk liegt wie der Bestand, denn ein harter Link verlässt sein Laufwerk nicht. Liegt der Bestand woanders
    /// als die Toolchain, entsteht das Abbild deshalb im Bestand; neben der Toolchain würde aus jedem Link eine Kopie
    /// (bei Half-Life: Alyx rund 70 GB auf dem Systemlaufwerk). Die Toolchain erfährt den Ort über `KL_LX_MIRROR`.
    public func mirrorDirectory(recipe: Recipe, store: ContentStore) -> URL {
        if StoreLocation.sameVolume(root, store.root) {
            return root.appendingPathComponent("visionos/build/lxstage/\(recipe.toolchain.target)/lx", isDirectory: true)
        }
        return store.root.appendingPathComponent(".lxstage/\(recipe.id)-\(recipe.versionCode)/lx", isDirectory: true)
    }

    /// Lässt die Toolchain das Abbild aufbauen (`copy: false`) oder es aufs Gerät übertragen. Welche Dateien
    /// dazugehören, entscheidet die Toolchain: Bibliotheken nur, soweit das Spiel sie lädt; keine Links.
    public func syncTrees(recipe: Recipe, environment: [String: String], device: Device, bundleId: String?,
                          copy: Bool, log: URL) throws {
        var env = ProcessInfo.processInfo.environment
        env["KLEPTON_TARGET"] = recipe.toolchain.target
        if let bundleId { env["KLEPTON_BUNDLE_ID"] = bundleId }
        env.merge(environment) { _, new in new }
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["stage_sync.py", "--phase", "all", "--device", device.udid] + (copy ? [] : ["--dry-run"])
        p.currentDirectoryURL = root.appendingPathComponent("visionos", isDirectory: true)
        p.environment = env
        p.standardOutput = handle
        p.standardError = handle
        p.standardInput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            let hint = text.split(separator: "\n").last { $0.contains("!!") }
            throw ToolchainError.syncFailed(log: log, hint: hint.map { String($0.prefix(160)) } ?? "")
        }
    }

    static func capture(_ argv: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static func status(_ argv: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

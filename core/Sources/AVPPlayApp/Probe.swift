import AppKit
import AVPPlayCore

/// Stellt die Lage fest: Rezepte, Bestand, Gerät, Xcode, Toolchain. Fragt nur diesen Mac und das Gerät,
/// nie Meta. Läuft außerhalb des Hauptfadens, weil `devicectl` und `xcodebuild` Sekunden brauchen.
enum Probe {
    struct Snapshot: @unchecked Sendable {
        var games: [Game] = []
        var loadProblem: String?
        var device: Device?
        var deviceProblem: String?
        var toolchainText: String?
        var toolPresent = false
        var xcodeText: String?
        var xcodeProblem: String?
        var teamCandidates: [Team] = []
        /// Freier Platz auf dem Laufwerk des Bestands.
        var freeBytes: Int64?
    }

    /// Ein Entwicklerteam, wie Xcode es kennt.
    struct Team: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        /// Kostenloses „Personal Team“: Apps laufen nur sieben Tage, und nötige Berechtigungen fehlen.
        let free: Bool
    }

    static func run(paths: Paths, bundlePrefix: String) -> Snapshot {
        var s = Snapshot()

        let control = DeviceControl()
        var apps: [InstalledApp]?
        do {
            let device = try control.pick(udid: nil)
            s.device = device
            if !device.developerMode {
                s.deviceProblem = L("Developer Mode is off on the Vision Pro (Settings › Privacy & Security › Developer Mode).", "Auf der Vision Pro ist der Entwicklermodus aus (Einstellungen › Datenschutz & Sicherheit › Entwicklermodus).")
            }
            apps = try? control.apps(device: device)
        } catch DeviceError.noDevice {
            s.deviceProblem = L("The Vision Pro is not reachable. Turn it on, put it on or unlock it, and connect it to the same Wi-Fi as this Mac.", "Die Vision Pro ist nicht erreichbar. Einschalten, aufsetzen oder entsperren und im selben WLAN wie dieser Mac anmelden.")
        } catch DeviceError.ambiguous(let names) {
            s.deviceProblem = L("Several devices are reachable (\(names.joined(separator: ", "))). Please leave only one switched on.", "Es sind mehrere Geräte erreichbar (\(names.joined(separator: ", "))). Bitte nur eines eingeschaltet lassen.")
        } catch {
            s.deviceProblem = "\(error)"
        }

        let toolchain = paths.toolchain()
        if let toolchain {
            s.toolchainText = toolchain.manifest != nil
                ? L("Version \(toolchain.version()) is installed.", "Version \(toolchain.version()) ist installiert.")
                : L("Development checkout \(toolchain.commit()) (not an installed package).", "Entwicklungsstand \(toolchain.commit()) (kein installiertes Paket).")
        }

        if let recipes = paths.recipes {
            do {
                s.games = try RecipeStore(directory: recipes).loadAll().map { r in
                    Game(recipe: r,
                         status: GameStatus.of(recipe: r, store: paths.store, apps: apps, toolchainVersion: toolchain?.version(),
                                                bundlePrefix: bundlePrefix),
                         cover: StartHero.choose(recipe: r, store: paths.store).flatMap { NSImage(data: $0.image) },
                         storeBytes: directorySize(paths.store.directory(for: r)))
                }.sorted { $0.recipe.title.localizedCaseInsensitiveCompare($1.recipe.title) == .orderedAscending }
            } catch {
                s.loadProblem = L("The list of games could not be read: \(error)", "Die Spieleliste konnte nicht gelesen werden: \(error)")
            }
        } else {
            s.loadProblem = L("No list of games was found.", "Es wurde keine Spieleliste gefunden.")
        }

        s.toolPresent = (try? MetaTool(url: metaToolURL).verify()) != nil

        let version = capture(["/usr/bin/xcrun", "xcodebuild", "-version"])
        if let first = version.out.split(separator: "\n").first, version.status == 0 {
            if capture(["/usr/bin/xcrun", "xcodebuild", "-showsdks"]).out.contains("xros") {
                s.xcodeText = L("\(first) with visionOS support.", "\(first) mit visionOS-Unterstützung.")
            } else {
                s.xcodeText = String(first)
                s.xcodeProblem = L("Xcode is missing the visionOS platform. Open Xcode › Settings › Components › download visionOS.", "In Xcode fehlt die visionOS-Plattform. Xcode öffnen › Einstellungen › Components › visionOS laden.")
            }
        } else {
            s.xcodeProblem = L("Xcode is not installed or has never been opened. Get Xcode from the App Store and open it once.", "Xcode ist nicht installiert oder noch nie geöffnet worden. Xcode aus dem App Store laden und einmal starten.")
        }

        s.teamCandidates = teams()
        try? FileManager.default.createDirectory(at: paths.store.root, withIntermediateDirectories: true)
        s.freeBytes = (try? paths.store.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        return s
    }

    /// Belegter Platz eines Ordners; Verweise werden nicht verfolgt.
    static func directorySize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Wo Metas Werkzeug liegt: vom Nutzer gewählt, sonst im Ordner „Downloads“.
    static var metaToolURL: URL {
        UserDefaults.standard.string(forKey: "metaToolPath").map { URL(fileURLWithPath: $0) } ?? MetaTool.defaultURL
    }

    /// Die Teams, mit denen Xcode auf diesem Mac angemeldet ist: Kennung, Name und ob es ein kostenloses Team
    /// ist. Gelesen wird nur diese Liste aus Xcodes Einstellungen, keine Kontodaten. Kennt Xcode keine Teams,
    /// bleiben die Kennungen aus den Entwicklerzertifikaten – ein Vorschlag, keine Prüfung.
    static func teams() -> [Team] {
        var found: [Team] = []
        let exported = capture(["/usr/bin/defaults", "export", "com.apple.dt.Xcode", "-"]).out
        if let plist = try? PropertyListSerialization.propertyList(from: Data(exported.utf8), format: nil) as? [String: Any],
           let byAccount = plist["IDEProvisioningTeamByIdentifier"] as? [String: Any] {
            for case let list as [[String: Any]] in byAccount.values {
                for entry in list {
                    guard let id = entry["teamID"] as? String, !found.contains(where: { $0.id == id }) else { continue }
                    found.append(Team(id: id, name: entry["teamName"] as? String ?? id,
                                      free: (entry["isFreeProvisioningTeam"] as? Bool) ?? false))
                }
            }
        }
        if !found.isEmpty { return found.sorted { !$0.free && $1.free } }
        return certificateTeams().map { Team(id: $0, name: L("Team \($0)", "Team \($0)"), free: false) }
    }

    /// Team-IDs aus den Entwicklerzertifikaten im Schlüsselbund (das Feld „OU“ des Zertifikats).
    static func certificateTeams() -> [String] {
        let pem = capture(["/usr/bin/security", "find-certificate", "-a", "-c", "Apple Development", "-p"]).out
        var found: [String] = []
        for block in pem.components(separatedBy: "-----END CERTIFICATE-----") where block.contains("BEGIN CERTIFICATE") {
            let subject = capture(["/usr/bin/openssl", "x509", "-noout", "-subject", "-nameopt", "multiline"],
                                  input: block + "-----END CERTIFICATE-----\n").out
            for line in subject.split(separator: "\n") where line.contains("organizationalUnitName") {
                if let id = line.split(separator: "=").last?.trimmingCharacters(in: .whitespaces),
                   id.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil, !found.contains(id) {
                    found.append(id)
                }
            }
        }
        return found
    }

    static func capture(_ argv: [String], input: String? = nil) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let out = Pipe(), stdin = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        if input != nil { p.standardInput = stdin }
        guard (try? p.run()) != nil else { return (-1, "") }
        if let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

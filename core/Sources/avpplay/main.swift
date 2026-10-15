import Foundation
import AVPPlayCore

// Kommandozeile zur Kern-Bibliothek. Sie tut nichts Eigenes, sondern macht die Bibliothek ohne Oberfläche prüfbar.

struct Options {
    var positional: [String] = []
    var values: [String: [String]] = [:]
    var flags: Set<String> = []

    init(_ args: [String], valued: Set<String>) {
        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--") {
                let name = String(a.dropFirst(2))
                if valued.contains(name), i + 1 < args.count {
                    values[name, default: []].append(args[i + 1]); i += 1
                } else {
                    flags.insert(name)
                }
            } else {
                positional.append(a)
            }
            i += 1
        }
    }
    func value(_ name: String) -> String? { values[name]?.last }
}

/// Ein Hinweis auf stderr, ohne abzubrechen.
func warn(_ message: String) {
    FileHandle.standardError.write(Data((L("Warning: ", "Warnung: ") + Redaction.redact(message) + "\n").utf8))
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((Redaction.redact(message) + "\n").utf8))
    exit(1)
}

func recipesDirectory(_ o: Options) -> URL {
    if let p = o.value("recipes") ?? ProcessInfo.processInfo.environment["AVPPLAY_RECIPES"] { return URL(fileURLWithPath: p) }
    // vom Arbeitsverzeichnis aufwärts nach einem Ordner "recipes" suchen
    var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    for _ in 0..<5 {
        let candidate = dir.appendingPathComponent("recipes", isDirectory: true)
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        dir.deleteLastPathComponent()
    }
    fail(L("No recipes folder found. Give one with --recipes <folder>.",
           "Kein Rezeptordner gefunden. Mit --recipes <Ordner> angeben."))
}

/// Metas Werkzeug für den Ausweg bei HTTP 404: `--tool`, sonst die Kopie der App, sonst `~/Downloads`.
func metaToolURL(_ o: Options) -> URL {
    if let p = o.value("tool") { return URL(fileURLWithPath: p) }
    return FileManager.default.fileExists(atPath: MetaTool.installedURL.path) ? MetaTool.installedURL : MetaTool.defaultURL
}

func contentStore(_ o: Options) -> ContentStore {
    if let p = o.value("store") ?? ProcessInfo.processInfo.environment["AVPPLAY_STORE"] {
        return ContentStore(root: URL(fileURLWithPath: p))
    }
    // Der in der Oberfläche gewählte Ordner gilt auch hier. Fehlt seine Platte, wird nicht so getan, als sei der
    // Bestand leer.
    let root = ContentStore.defaultRoot
    guard StoreLocation.isAvailable(root) else { fail("\(StoreMoveError.notAvailable(root.path))") }
    return ContentStore(root: root)
}

func gigabytes(_ bytes: Int64) -> String { String(format: "%.2f GB", Double(bytes) / 1e9) }

/// Token lesen und sofort gegen Meta prüfen. Ohne gültigen Token wird keine weitere Abfrage gestellt.
func signedIn(_ o: Options) async -> (MetaClient, userId: String) {
    let account = o.value("account") ?? "default"
    do {
        let client = MetaClient(token: try TokenStore().read(account: account))
        return (client, try await client.me())
    } catch {
        fail("\(error)")
    }
}

// Die Sprache der Kommandozeile: AVPPLAY_LANG, wenn dort "en" oder "de" steht, sonst die Sprache des Systems.
// Sie wird gesetzt, bevor irgendein Text entsteht; die Meldungen der Bibliothek folgen derselben Einstellung.
L10n.language = ProcessInfo.processInfo.environment["AVPPLAY_LANG"].flatMap { Language(rawValue: $0) }
    ?? L10n.systemLanguage()
// Daten aus der Zeit vor dem Namen „AVP Play“ einmalig übernehmen (der Ordner wird umbenannt).
DataLocation.adoptLegacyData()

// Zeilenweise ausgeben, auch wenn die Ausgabe in eine Pipe geht – sonst erscheint der Fortschritt erst am Ende.
setvbuf(stdout, nil, _IOLBF, 0)

func usage() -> String {
    L("""
avpplay – command line for the AVP Play core library

  avpplay recipes                              list the recipes
  avpplay show <id>                            files of a recipe
  avpplay login                                sign in to Meta (starts ovr-platform-util; --tool <path>, default ~/Downloads)
  avpplay logout                               delete the stored Meta token
  avpplay account                              check the stored Meta token
  avpplay owns <id>                            does the account own the game?
  avpplay files <build ID> [--details]         the files of a build (Meta's tool; its build details if the tool can't find it)
  avpplay steam setup|login <name>|logout      Valve's SteamCMD: fetch it, sign in to Steam (you type the password into Valve's tool), sign out
  avpplay steam fetch <id> --steam-account <name> [--with <file name>]   get the files a recipe needs from your own Steam purchase
  avpplay purchases <id>                       confirmed in-game purchases and the add-on content that goes with them
           --skus              also name each purchase as the store names it
  avpplay plan <id>   [selection]              show what would be downloaded (no request to the download site)
  avpplay fetch <id>  [selection]              download missing files and check them
  avpplay verify <id>                          check the files you have against the recipe's checksums
  avpplay adopt <id> --from <folder> […]       check existing files and folders, then add them to the library (no network)
  avpplay unpack <id> --to <folder>            unpack the APK from the library for the toolchain (replaces apktool)
  avpplay icon <id> --to <folder>              save the app icon from the APK as a visionOS icon (three layers)
  avpplay devices                              paired Vision Pro devices
  avpplay status                               per game: library on the Mac and state on the device
  avpplay toolchains [--released]              installed toolchain packages; with --released also the older ones that came
                                               with releases of AVP Play on GitHub
  avpplay toolchain get <number>               download one of those from GitHub, check it and install it next to the others
  avpplay toolchain pack --from <Fork> --to <folder>      build a package from a committed state of the fork
  avpplay toolchain install <archive>          check and install a package
  avpplay toolchain mark <folder>              mark a working copy of a toolchain as modified; it is then listed as “(modified)”
  avpplay toolchain use <id> --toolchain <folder> | --newest
                                               build this game with that toolchain from now on (an installed package or a
                                               working copy) – or with the newest one again
  avpplay install <id> --team <team ID>        build, install, copy missing data, unlock add-on content
  avpplay stage <id>                           only copy missing data and add-on content (no build)
  avpplay renew [--dry-run] [--force <id>]     sign installed games again whose signature runs out soon (what the background service does)
  avpplay saves [<id> …] [--saves <folder>]    fetch the saved games of installed games from the Vision Pro to this Mac (nothing changes on the device)
  avpplay saves <id> --restore                 put the newest copy back on the Vision Pro, replacing what is there (which is fetched first)
  avpplay servers <id> [add <address> [--name <name>] [--admin-stdin] | remove <address> | push]
                                               your own game servers for a game that understands such a list; the admin
                                               password is read from standard input and kept in the keychain
  avpplay job start <id> --team <team ID>      job: check, download, build, install, copy, unlock
  avpplay job resume <job>                     resume an interrupted or stopped job
  avpplay job show|cancel <job>                show progress / cancel            avpplay jobs   all jobs
             --device <UDID>  --bundle-id <ID>  --toolchain <folder>  --no-addons
             --display-name <name>   name of the app on the Vision Pro instead of the game's usual one
             --display-suffix <text> append this to the app's name, e.g. " (Test)" – with --bundle-id for a test copy
                                     next to the installed game; its signature is kept apart and doesn't replace
                                     the game's (renew, saves and servers keep using the game's own installation)
             --source steam          the game as bought on Steam instead of from the Meta Store (where the project has a
                                     recipe for it); needs --steam-account <name>
             --icon <image file>     use your own app icon (takes priority over everything else)
             --no-store-art          don't fetch the cover image from the store page (the icon from the APK is used instead)
             --replace-running       install even if the game is running (it will be quit)
             --experimental          build with the toolchain's new pose and audio implementations switched on from the start
                                     (they can be turned off in the game; the app's setting “Experimental” does the same)
             --metalfx               build with the compositor's MetalFX upscaling switched on from the start (sharpens the picture
                                     when the game's resolution is below 100%; off in the game under Settings › Rendering)
             --resolution <percent>  with --metalfx: the resolution the game starts at (default 75; 100: the game's own)
             --xr-prediction         build with XR head prediction switched on from the start (off by default; in the game under
                                     Settings › Advanced › Test; the game page's option “XR prediction” does the same)
             --addons-only           job start: only sync purchased add-on content of an installed game (no build, no --team)
             --download-only         job start: only download the files (needs no Xcode, toolchain, --team or device)
             --build-only            job start: check, download, build and install the app, but do not copy the game data yet

Selection: --locale de-DE      also include a language variant (can be repeated)
           --with <file name>  also include an optional file (can be repeated)
           --only <file name>  only this file (can be repeated)
           --addons            also include purchased add-on content (asks for the list of purchases)
General:   --account <name>    keychain entry (default: default)
           --store <folder>    where the files are kept   --recipes <folder>
           --interval <s>      minimum pause between requests (default: none)
""", """
avpplay – Kommandozeile zur Kern-Bibliothek von AVP Play

  avpplay recipes                              Rezepte auflisten
  avpplay show <id>                            Dateien eines Rezepts
  avpplay login                                bei Meta anmelden (startet ovr-platform-util; --tool <Pfad>, Standard ~/Downloads)
  avpplay logout                               hinterlegten Meta-Token löschen
  avpplay account                              hinterlegten Meta-Token prüfen
  avpplay owns <id>                            Besitzt das Konto das Spiel?
  avpplay files <Build-ID> [--details]         die Dateien eines Builds (Metas Werkzeug; findet es ihn nicht, die Build-Details)
  avpplay steam setup|login <Name>|logout      Valves SteamCMD: holen, bei Steam anmelden (das Passwort tippst du in Valves Werkzeug), abmelden
  avpplay steam fetch <id> --steam-account <Name> [--with <Dateiname>]   die Dateien eines Rezepts aus dem eigenen Steam-Kauf holen
  avpplay purchases <id>                       bestätigte Käufe im Spiel und zugehörige Zusatzinhalte
           --skus              jeden Kauf auch so nennen, wie der Store ihn nennt
  avpplay plan <id>   [Auswahl]                zeigen, was geladen würde (keine Abfrage an die Download-Seite)
  avpplay fetch <id>  [Auswahl]                fehlende Dateien laden und prüfen
  avpplay verify <id>                          vorhandene Dateien gegen die Prüfsummen des Rezepts prüfen
  avpplay adopt <id> --from <Ordner> […]       vorhandene Dateien und Ordner nach Prüfung in den Bestand übernehmen (kein Netz)
  avpplay unpack <id> --to <Ordner>            APK aus dem Bestand für die Toolchain entpacken (ersetzt apktool)
  avpplay icon <id> --to <Ordner>              App-Icon aus dem APK als visionOS-Icon (drei Ebenen) ablegen
  avpplay devices                              gekoppelte Vision-Pro-Geräte
  avpplay status                               je Spiel: Bestand auf dem Mac und Stand auf dem Gerät
  avpplay toolchains [--released]              installierte Toolchain-Pakete; mit --released auch die älteren, die mit
                                               Veröffentlichungen von AVP Play auf GitHub kamen
  avpplay toolchain get <Nummer>               eines davon von GitHub laden, prüfen und neben den anderen installieren
  avpplay toolchain pack --from <Fork> --to <Ordner>      Paket aus einem eingecheckten Fork-Stand bauen
  avpplay toolchain install <Archiv>           Paket prüfen und installieren
  avpplay toolchain mark <Ordner>              eine Arbeitskopie einer Toolchain als bearbeitet kennzeichnen; sie steht dann
                                               mit „(modifiziert)“ in den Listen
  avpplay toolchain use <id> --toolchain <Ordner> | --newest
                                               dieses Spiel ab jetzt mit dieser Toolchain bauen (ein installiertes Paket oder
                                               eine Arbeitskopie) – oder wieder mit der neuesten
  avpplay install <id> --team <Team-ID>        bauen, installieren, Daten ergänzend kopieren, Zusatzinhalte freischalten
  avpplay stage <id>                           nur Daten und Zusatzinhalte ergänzend kopieren (ohne Build)
  avpplay renew [--dry-run] [--force <id>]     installierte Spiele neu signieren, deren Signatur bald abläuft (was der Hintergrunddienst tut)
  avpplay saves [<id> …] [--saves <Ordner>]    Spielstände installierter Spiele von der Vision Pro auf den Mac holen (auf dem Gerät ändert sich nichts)
  avpplay saves <id> --restore                 den neuesten Stand auf die Vision Pro zurückspielen; ersetzt, was dort liegt (das wird vorher geholt)
  avpplay servers <id> [add <Adresse> [--name <Name>] [--admin-stdin] | remove <Adresse> | push]
                                               eigene Spielserver für ein Spiel, das so eine Liste versteht; das Admin-Passwort
                                               wird von der Standardeingabe gelesen und im Schlüsselbund abgelegt
  avpplay job start <id> --team <Team-ID>      Auftrag: prüfen, laden, bauen, installieren, kopieren, freischalten
  avpplay job resume <Auftrag>                 unterbrochenen oder angehaltenen Auftrag fortsetzen
  avpplay job show|cancel <Auftrag>            Stand zeigen / abbrechen          avpplay jobs   alle Aufträge
             --device <UDID>  --bundle-id <ID>  --toolchain <Ordner>  --no-addons
             --display-name <Name>   Name der App auf der Vision Pro statt des üblichen des Spiels
             --display-suffix <Text> das an den Namen der App anhängen, z. B. " (Test)" – mit --bundle-id für eine Testkopie
                                     neben dem installierten Spiel; ihre Signatur wird getrennt gemerkt und ersetzt nicht
                                     die des Spiels (renew, saves und servers bleiben bei dessen eigener Installation)
             --source steam          das Spiel aus dem Steam-Kauf statt aus dem Meta-Store (wo das Projekt ein Rezept
                                     dafür führt); braucht --steam-account <Name>
             --icon <Bilddatei>      eigenes App-Icon hinterlegen (hat Vorrang vor allem anderen)
             --no-store-art          kein Titelbild von der Store-Seite holen (dann Icon aus dem APK)
             --replace-running       auch installieren, wenn das Spiel gerade läuft (es wird dabei beendet)
             --restore-saves         nach dem Kopieren die Spielstände vom Mac zurückspielen, wenn das Spiel auf dem Gerät noch keine hat
             --experimental          mit von Anfang an eingeschalteter neuer Pose- und Audio-Implementierung der Toolchain bauen
                                     (im Spiel abschaltbar; die Einstellung „Experimentell“ des Programms tut dasselbe)
             --metalfx               mit von Anfang an eingeschaltetem MetalFX-Hochskalieren des Compositors bauen (schärft das Bild,
                                     wenn die Auflösung des Spiels unter 100 % steht; im Spiel abschaltbar unter Einstellungen › Rendering)
             --resolution <Prozent>  mit --metalfx: die Auflösung, mit der das Spiel beginnt (Vorgabe 75; 100: die des Spiels)
             --xr-prediction         mit von Anfang an eingeschalteter XR-Vorhersage der Kopfpose bauen (sonst aus; im Spiel unter
                                     Einstellungen › Erweitert › Test; die Option „XR-Vorhersage“ auf der Seite des Spiels tut dasselbe)
             --addons-only           job start: nur gekaufte Zusatzinhalte eines installierten Spiels abgleichen (kein Bau, kein --team)
             --download-only         job start: nur die Dateien laden (braucht weder Xcode noch Toolchain, --team oder Gerät)
             --build-only            job start: prüfen, laden, bauen und die App installieren, aber die Spieldaten noch nicht kopieren

Auswahl:   --locale de-DE      Sprachvariante dazunehmen (mehrfach möglich)
           --with <Dateiname>  wählbare Datei dazunehmen (mehrfach möglich)
           --only <Dateiname>  nur diese Datei (mehrfach möglich)
           --addons            gekaufte Zusatzinhalte dazunehmen (fragt die Kaufliste ab)
Allgemein: --account <Name>    Eintrag im Schlüsselbund (Standard: default)
           --store <Ordner>    Ablage der Dateien      --recipes <Ordner>
           --interval <s>      Mindestabstand zwischen Abrufen (Standard: keiner)
""")
}

let valued: Set<String> = ["account", "steam-account", "source", "store", "recipes", "locale", "with", "only", "interval", "from", "to", "force", "name",
                           "team", "device", "bundle-id", "display-name", "display-suffix", "toolchain", "icon", "tool", "jobs", "toolchains", "saves", "resolution"]
let o = Options(Array(CommandLine.arguments.dropFirst()), valued: valued)
guard let command = o.positional.first else { print(usage()); exit(0) }
OtherSources.use(recipes: recipesDirectory(o))

/// Das Rezept eines Spiels. Mit `--source steam` das für die andere Kaufquelle (`recipes/sources`); ohne die
/// Angabe gilt, was in der App für das Spiel gewählt ist.
func recipe(_ o: Options, at index: Int = 1) -> Recipe {
    guard o.positional.count > index else { fail(L("The recipe ID is missing.\n\n", "Rezept-Kennung fehlt.\n\n") + usage()) }
    do {
        let recipes = RecipeStore(directory: recipesDirectory(o))
        let shipped = try recipes.load(id: o.positional[index])
        var wanted = StoreUpdate.Choices.load().sources[shipped.id]
        if let named = o.value("source") {
            guard let source = Recipe.Source(rawValue: named) else {
                fail(L("Unknown purchase source '\(named)' (meta or steam).", "Unbekannte Kaufquelle '\(named)' (meta oder steam)."))
            }
            wanted = source
        }
        guard let wanted, wanted != shipped.source else { return shipped }
        guard let other = recipes.loadSources().first(where: { $0.id == shipped.id && $0.source == wanted }) else {
            // Nur wer die Quelle ausdrücklich nennt, bekommt gesagt, dass es sie nicht gibt.
            if o.value("source") == nil { return shipped }
            fail(L("There is no \(wanted.rawValue) recipe for \(shipped.title).", "Für \(shipped.title) gibt es kein Rezept aus \(wanted.rawValue)."))
        }
        return other
    } catch { fail("\(error)") }
}

/// Die Versionscodes, unter denen dasselbe Spiel aus einer anderen Kaufquelle als der von `recipe` installiert wäre.
func otherSourceBuilds(of recipe: Recipe, _ o: Options) -> [Int] {
    let recipes = RecipeStore(directory: recipesDirectory(o))
    let all = ((try? recipes.loadAll()) ?? []) + recipes.loadVariants() + recipes.loadSources()
    return all.filter { $0.id == recipe.id && $0.source != recipe.source }.map(\.versionCode)
}

func toolchainPackager(_ o: Options) -> ToolchainPackager {
    ToolchainPackager(root: (o.value("toolchains") ?? ProcessInfo.processInfo.environment["AVPPLAY_TOOLCHAINS"])
                          .map { URL(fileURLWithPath: $0) } ?? ToolchainPackager.defaultRoot)
}

func jobStore(_ o: Options) -> JobStore {
    JobStore(directory: (o.value("jobs") ?? ProcessInfo.processInfo.environment["AVPPLAY_JOBS"]).map { URL(fileURLWithPath: $0) }
             ?? JobStore.defaultDirectory)
}

/// Die Toolchain, die für ein Spiel gewählt ist (`avpplay toolchain use`, oder auf seiner Seite in der App).
/// Liegt sie nicht mehr auf diesem Mac, wird nicht stillschweigend mit einer anderen gebaut.
func chosenToolchain(_ o: Options, recipe id: String) -> String? {
    guard let pin = ToolchainChoices.load().games[id] else { return nil }
    guard let kept = toolchainPackager(o).toolchain(for: pin) else {
        fail(L("Toolchain \(pin.name), chosen for this game, is no longer on this Mac. Name one with --toolchain <folder>, or go back to the newest with: avpplay toolchain use \(id) --newest",
               "Toolchain \(pin.name), für dieses Spiel gewählt, liegt nicht mehr auf diesem Mac. Nenne eine mit --toolchain <Ordner>, oder kehre zur neuesten zurück mit: avpplay toolchain use \(id) --newest"))
    }
    return kept.root.path
}

/// Die Angaben der Kommandozeile als Auftrag an die Bibliothek.
func installRequest(_ o: Options, recipe id: String? = nil) -> InstallRequest {
    // Reihenfolge: ausdrücklich genannt, dann die für das Spiel gewählte, dann das neueste installierte Paket,
    // zuletzt das Arbeitsverzeichnis der Entwicklung neben den Rezepten.
    let toolchain = o.value("toolchain") ?? ProcessInfo.processInfo.environment["AVPPLAY_TOOLCHAIN"]
        ?? id.flatMap { chosenToolchain(o, recipe: $0) }
        ?? toolchainPackager(o).installed().first?.root.path
        ?? recipesDirectory(o).deletingLastPathComponent().appendingPathComponent("klepton-fork-test").path
    var request = InstallRequest(toolchain: URL(fileURLWithPath: toolchain).standardizedFileURL.path)
    request.account = o.value("account") ?? "default"
    request.locales = (o.values["locale"] ?? []).sorted()
    request.optionalNames = (o.values["with"] ?? []).sorted()
    request.addons = !o.flags.contains("no-addons")
    request.team = o.value("team")
    request.device = o.value("device")
    request.bundleId = o.value("bundle-id")
    for key in ["display-name", "display-suffix"] {
        if let text = o.value(key), !Toolchain.isValidDisplayText(text) {
            fail(L("--\(key): at most 60 characters, no line breaks or other control characters.",
                   "--\(key): höchstens 60 Zeichen, keine Zeilenumbrüche oder anderen Steuerzeichen."))
        }
    }
    request.displayName = o.value("display-name").flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    request.displaySuffix = o.value("display-suffix").flatMap { $0.isEmpty ? nil : $0 }
    request.steamAccount = o.value("steam-account")
    request.customIcon = o.value("icon").map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    request.storeArt = !o.flags.contains("no-store-art")
    if o.flags.contains("replace-running") { request.replaceRunning = true }
    if o.flags.contains("restore-saves") { request.restoreSaves = true }
    if o.flags.contains("experimental") { request.experimental = true }
    if o.flags.contains("metalfx") { request.metalFX = true }
    if o.flags.contains("xr-prediction") { request.xrPrediction = true }
    let resolution = MetalFXResolution.commandLine(metalFX: request.metalFX == true, value: o.value("resolution"))
    request.resolution = resolution.resolution
    if let warning = resolution.warning { warn(warning) }
    request.interval = Double(o.value("interval") ?? "") ?? 0
    return request
}

/// Sagt beim Kopieren aufs Gerät, wie weit es ist – höchstens einmal je Sekunde, und nur, wenn sich etwas getan hat.
final class CopyProgressPrinter: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private var shown: Int64 = -1
    private var via: Device.Transport?

    func show(_ p: InstallProgress) {
        lock.lock(); defer { lock.unlock() }
        if let v = p.via { via = v }
        guard p.total > 0, p.done != shown, p.done == p.total || Date().timeIntervalSince(last) >= 1 else { return }
        (last, shown) = (Date(), p.done)
        let over = via.map { L(" over \($0.text)", " über \($0.text)") } ?? ""
        print(L("    \(p.done / 1_000_000) of \(p.total / 1_000_000) MB copied\(over)", "    \(p.done / 1_000_000) von \(p.total / 1_000_000) MB kopiert\(over)"))
    }
}

func describe(_ j: Job) -> String {
    let state: String
    switch j.state {
    case .waiting: state = L("waiting", "wartet")
    case .running: state = L("interrupted at “\(j.current?.title ?? "?")”", "unterbrochen bei „\(j.current?.title ?? "?")“")
    case .failed: state = L("stopped at “\(j.current?.title ?? "?")”", "angehalten bei „\(j.current?.title ?? "?")“")
    case .finished: state = L("finished", "abgeschlossen")
    case .cancelled: state = L("cancelled", "abgebrochen")
    }
    return L("\(j.id)  \(j.recipe.title) \(j.recipe.versionName) – \(state), \(j.completed.count)/\(j.steps.count) steps",
             "\(j.id)  \(j.recipe.title) \(j.recipe.versionName) – \(state), \(j.completed.count)/\(j.steps.count) Schritte")
}

func selection(_ o: Options, recipe: Recipe, client: MetaClient?) async -> FetchSelection {
    var s = FetchSelection(locales: Set(o.values["locale"] ?? []), optionalNames: Set(o.values["with"] ?? []),
                           withheld: contentStore(o).withheld(for: recipe))
    if let only = o.values["only"] { s.only = Set(only) }
    if o.flags.contains("addons"), recipe.addons?.kind == .deliveredAssets {
        guard let client, let app = recipe.store.appId else { fail("\(MetaError.missingAppId)") }
        do { s.ownedSKUs = Set(try await client.purchases(appId: app)) } catch { fail("\(error)") }
    }
    return s
}

switch command {
case "recipes":
    do {
        for r in try RecipeStore(directory: recipesDirectory(o)).loadAll() {
            let required = r.files.filter(\.required)
            let known = required.compactMap(\.size).reduce(0, +)
            print("\(r.id.padding(toLength: 14, withPad: " ", startingAt: 0)) \(r.title) \(r.versionName) – "
                  + L("required files: \(required.count) (\(gigabytes(known)) known), download: \(r.status.download), "
                      + "playability: \(r.status.playability)",
                      "\(required.count) Pflichtdateien (\(gigabytes(known)) bekannt), Download: \(r.status.download), "
                      + "Spielbarkeit: \(r.status.playability)"))
        }
    } catch { fail("\(error)") }

case "show":
    let r = recipe(o)
    print(L("\(r.title) \(r.versionName) (\(r.package), version code \(r.versionCode))",
            "\(r.title) \(r.versionName) (\(r.package), Code \(r.versionCode))"))
    for f in r.files {
        print("  \(f.required ? L("required", "Pflicht ") : L("optional", "wählbar ")) \(f.role.padding(toLength: 15, withPad: " ", startingAt: 0)) "
              + "\(f.name)\(f.size.map { L("  \($0) bytes", "  \($0) Bytes") } ?? "")\(f.sha256 == nil ? L("  (no checksum)", "  (ohne Prüfsumme)") : "")")
    }
    if let a = r.addons {
        print(L("  Add-on content: \(a.kind.rawValue)\(a.items.map { ", \($0.count) entries" } ?? "")",
                "  Zusatzinhalte: \(a.kind.rawValue)\(a.items.map { ", \($0.count) Einträge" } ?? "")"))
    }
    for t in r.trees ?? [] {
        print(L("  folder   \(t.role.rawValue.padding(toLength: 15, withPad: " ", startingAt: 0)) \(t.name)  "
                + "(marker files: \(t.markers.count))\(t.source.hint.map { " – \($0)" } ?? "")",
                "  Ordner   \(t.role.rawValue.padding(toLength: 15, withPad: " ", startingAt: 0)) \(t.name)  "
                + "(\(t.markers.count) Kenndateien)\(t.source.hint.map { " – \($0)" } ?? "")"))
    }

case "login":
    let account = o.value("account") ?? "default"
    let tool = MetaTool(url: o.value("tool").map { URL(fileURLWithPath: $0) } ?? MetaTool.defaultURL)
    do {
        try tool.verify()
        print(L("Signing in to Meta with ovr-platform-util. Your email, password and, if asked for, the code go straight to "
                + "Meta's tool; this program stores none of it and does not show the token.\n",
                "Anmeldung bei Meta über ovr-platform-util. E-Mail, Passwort und gegebenenfalls der Code gehen direkt an "
                + "Metas Werkzeug; dieses Programm speichert davon nichts und zeigt den Token nicht an.\n"))
        let token = try MetaLogin.run(tool: tool.url)
        // Erst prüfen, dann ablegen: ein Token, den Meta nicht annimmt, kommt nicht in den Schlüsselbund.
        _ = try await MetaClient(token: token).me()
        try TokenStore().write(token: token, account: account)
        print(L("\nSigned in. The token has been checked and is stored in the keychain (account '\(account)').",
                "\nAngemeldet. Der Token ist geprüft und liegt im Schlüsselbund (Konto '\(account)')."))
    } catch { fail("\n\(error)") }

case "steam":
    // Dateien aus dem eigenen Steam-Kauf, geholt von Valves Werkzeug SteamCMD.
    let tool = SteamTool()
    func accountName() -> String {
        guard let name = o.value("steam-account") ?? (o.positional.count > 2 ? o.positional[2] : nil), SteamTool.isAccountName(name) else {
            fail("\(SteamError.badAccountName)")
        }
        return name
    }
    switch o.positional.count > 1 ? o.positional[1] : "" {
    case "setup":
        do {
            print(L("Downloading SteamCMD from Valve (\(SteamTool.archiveURL.host ?? "")) …", "SteamCMD wird von Valve geladen (\(SteamTool.archiveURL.host ?? "")) …"))
            let archive = try await SteamTool.downloadArchive()
            defer { try? FileManager.default.removeItem(at: archive) }
            try SteamTool.install(archive: archive, as: tool)
            print(L("SteamCMD is set up and signed by Valve: \(tool.directory.path)", "SteamCMD ist eingerichtet und von Valve signiert: \(tool.directory.path)"))
        } catch { fail("\(error)") }
    case "login":
        let account = accountName()
        do {
            try tool.verify()
            print(L("Signing in to Steam with Valve's tool SteamCMD. Your password and the Steam Guard code go straight to that tool; "
                    + "this program stores neither. SteamCMD remembers the sign-in in its own folder (\(tool.home.path)).\n",
                    "Anmeldung bei Steam über Valves Werkzeug SteamCMD. Passwort und Steam-Guard-Code gehen direkt an dieses Werkzeug; "
                    + "dieses Programm speichert beides nicht. SteamCMD merkt sich die Anmeldung in seinem eigenen Ordner (\(tool.home.path)).\n"))
            try SteamLogin.run(tool: tool, account: account)
            print(L("\nSigned in to Steam.", "\nBei Steam angemeldet."))
        } catch { fail("\n\(error)") }
    case "logout":
        do {
            try tool.signOut()
            print(L("Signed out: SteamCMD's folder with the remembered sign-in has been deleted.", "Abgemeldet: Der Ordner von SteamCMD mit der gemerkten Anmeldung ist gelöscht."))
        } catch { fail("\(error)") }
    case "fetch":
        guard o.positional.count > 2 else { fail(L("The recipe ID is missing.", "Rezept-Kennung fehlt.")) }
        guard let account = o.value("steam-account"), SteamTool.isAccountName(account) else { fail("\(SteamError.badAccountName)") }
        do {
            let r = try RecipeStore(directory: recipesDirectory(o)).load(id: o.positional[2])
            try SteamFetcher(tool: tool, store: contentStore(o), account: account).fetch(recipe: r, optionalNames: Set(o.values["with"] ?? []), progress: { p in
                FileHandle.standardError.write(Data(String(format: "\r  %.1f %%  ", 100 * Double(p.done) / Double(max(p.total, 1))).utf8))
            }, report: { print($0) })
        } catch { fail("\(error)") }
    default:
        fail(L("Usage: avpplay steam setup | steam login <account name> | steam logout | steam fetch <recipe> --steam-account <account name>",
               "Aufruf: avpplay steam setup | steam login <Kontoname> | steam logout | steam fetch <Rezept> --steam-account <Kontoname>"))
    }

case "logout":
    let account = o.value("account") ?? "default"
    do {
        print(try TokenStore().delete(account: account)
              ? L("Signed out: the token for the account '\(account)' has been deleted from the keychain.",
                  "Abgemeldet: Der Token für das Konto '\(account)' ist aus dem Schlüsselbund gelöscht.")
              : L("No token was stored for the account '\(account)'.",
                  "Für das Konto '\(account)' war kein Token hinterlegt."))
    } catch { fail("\(error)") }

case "account":
    let (_, _) = await signedIn(o)
    print(L("The token is valid (account '\(o.value("account") ?? "default")').",
            "Token gültig (Konto '\(o.value("account") ?? "default")')."))

case "owns":
    let r = recipe(o)
    guard let app = r.store.appId else { fail("\(MetaError.missingAppId)") }
    let (client, user) = await signedIn(o)
    do {
        print(try await client.ownsApp(appId: app, userId: user)
              ? L("\(r.title): owned.", "\(r.title): im Besitz.")
              : L("\(r.title): not owned.", "\(r.title): nicht im Besitz."))
    }
    catch { fail("\(error)") }

case "files":
    // Die Dateien eines Builds, wie die App sie für ein ungeprüftes Spiel nachschlägt. Mit --details nur über
    // Metas Build-Details (MetaClient.buildFiles), ohne das Werkzeug.
    guard o.positional.count > 1, CatalogGame.isIdentifier(o.positional[1]) else { fail(L("A build ID is missing.", "Build-Kennung fehlt.")) }
    let (client, _) = await signedIn(o)
    do {
        let build = o.positional[1]
        let files: [ListedFile]
        if o.flags.contains("details") {
            files = try await client.buildFiles(buildId: build)
        } else {
            let token = try TokenStore().read(account: o.value("account") ?? "default")
            try MetaTool(url: metaToolURL(o)).verify()
            files = try await MetaListing.files(buildId: build, tool: metaToolURL(o), token: token, client: client) { print($0) }
        }
        if files.isEmpty { print(L("No files named.", "Keine Dateien genannt.")) }
        for f in files { print("  \(f.kind)  \(f.name)  \(f.sizeText)  \(f.id)") }
    }
    catch { fail("\(error)") }

case "content-identity":
    // Was die Auslieferung über eine Datei sagt, ohne sie zu laden (MetaClient.identity) – zum Nachsehen.
    guard o.positional.count > 1, CatalogGame.isIdentifier(o.positional[1]) else { fail(L("A file ID is missing.", "Datei-Kennung fehlt.")) }
    let (client, _) = await signedIn(o)
    do {
        let i = try await client.identity(id: o.positional[1])
        print("length \(i.length.map(String.init) ?? "-"), md5 \(i.md5 ?? "-"), etag \(i.etag ?? "-")")
        print("headers: \(i.headerNames.joined(separator: ", "))")
        if let to = o.value("to") {
            let out = try await client.download(id: o.positional[1], to: URL(fileURLWithPath: to))
            print("downloaded \(out.bytesReceived) bytes")
        }
    } catch { fail("\(error)") }

case "store-version":
    // Welche Fassung der Store für ein Spiel des Kontos gerade führt (MetaClient.latestBuild).
    let r = recipe(o)
    guard let app = r.store.appId else { fail("\(MetaError.missingAppId)") }
    let (client, user) = await signedIn(o)
    do {
        guard try await client.ownsApp(appId: app, userId: user) else {
            fail(L("\(r.title): not owned – nothing is asked.", "\(r.title): nicht im Besitz – es wird nichts gefragt."))
        }
        if let build = try await client.latestBuild(appId: app) {
            print(L("\(r.title): the store has version \(build.version) (build number \(build.versionCode)); the recipe is for \(r.versionName) (\(r.versionCode)).",
                    "\(r.title): der Store führt Fassung \(build.version) (Build-Nummer \(build.versionCode)); das Rezept gilt für \(r.versionName) (\(r.versionCode))."))
        } else {
            print(L("\(r.title): Meta's answer names no current build.", "\(r.title): Metas Antwort nennt keinen aktuellen Build."))
        }
    } catch { fail("\(error)") }

case "purchases":
    let r = recipe(o)
    guard let app = r.store.appId else { fail("\(MetaError.missingAppId)") }
    let (client, _) = await signedIn(o)
    do {
        let skus = try await client.purchases(appId: app)
        print(L("\(r.title): confirmed purchases: \(skus.count).", "\(r.title): \(skus.count) bestätigte Käufe."))
        if o.flags.contains("skus") { for sku in skus { print("  \(sku)") } }
        if let items = r.addons?.items {
            let owned = items.filter { skus.contains($0.sku) }
            print(L("Of these, add-on files matched in the recipe: \(owned.count).",
                    "Davon im Rezept zugeordnet: \(owned.count) Zusatzdateien."))
            for (group, list) in Dictionary(grouping: owned, by: { $0.group ?? "-" }).sorted(by: { $0.key < $1.key }) {
                print("  \(group): \(list.map(\.name).sorted().joined(separator: ", "))")
            }
        }
    } catch { fail("\(error)") }

case "plan", "fetch":
    let r = recipe(o)
    let store = contentStore(o)
    // Ein Meta-Konto braucht es nur, wenn etwas aus dem Meta-Store geladen oder abgefragt wird.
    let usesStore = r.files.contains { $0.source == nil } || r.addons != nil
    let needsAccount = usesStore && (command == "fetch" || o.flags.contains("addons"))
    let client = needsAccount ? await signedIn(o).0 : nil
    let sel = await selection(o, recipe: r, client: client)
    let plan = FetchPlan.plan(recipe: r, selection: sel) { store.state(of: $0, in: r) }
    let fromUser = plan.filter { $0.action == .needsUser }
    let todo = plan.filter { $0.action != .keep && $0.action != .needsUser }
    let known = todo.compactMap(\.file.size).reduce(0, +)
    print(L("\(r.title): files needed: \(plan.count), already there: \(plan.filter { $0.action == .keep }.count), to download: \(todo.count)",
            "\(r.title): \(plan.count) Dateien gebraucht, \(plan.filter { $0.action == .keep }.count) vorhanden, \(todo.count) zu laden")
          + (fromUser.isEmpty ? "" : L(", to provide yourself: \(fromUser.count)", ", \(fromUser.count) selbst bereitzustellen"))
          + L(" (\(gigabytes(known)) known\(todo.contains { $0.file.size == nil } ? ", the rest has no size given" : "")).",
              " (\(gigabytes(known)) bekannt\(todo.contains { $0.file.size == nil } ? ", Rest ohne Größenangabe" : ""))."))
    if !fromUser.isEmpty {
        print(L("To provide yourself (\(fromUser.count)): \(fromUser.prefix(4).map(\.file.name).joined(separator: ", "))\(fromUser.count > 4 ? ", …" : "")",
                "Selbst bereitzustellen (\(fromUser.count)): \(fromUser.prefix(4).map(\.file.name).joined(separator: ", "))\(fromUser.count > 4 ? ", …" : "")")
              + (fromUser.first?.file.source?.hint.map { " – \($0)" } ?? ""))
        print(L("  Then add them to the library with 'avpplay adopt \(r.id) --from <folder>'.",
                "  Danach mit 'avpplay adopt \(r.id) --from <Ordner>' übernehmen."))
    }
    let treeStore = TreeStore(store: store)
    // Ordner mit freier Adresse (Valves Laufzeitumgebung, xrizer) holt `fetch` selbst; `plan` nennt sie nur.
    if command == "fetch" {
        for t in treeStore.fetchable(recipe: r) {
            do { try await treeStore.fetch(t, in: r) { print("  " + $0) } } catch { fail("\(error)") }
        }
    }
    let treesMissing = treeStore.missing(recipe: r)
    if let trees = r.trees {
        print(L("Folders: \(trees.count - treesMissing.count) of \(trees.count) in the library.",
                "Ordner: \(trees.count - treesMissing.count) von \(trees.count) im Bestand."))
        for t in treesMissing {
            let fetched = t.source.kind == .url && t.source.archive != nil
            print(L("  missing: \(t.name)\(fetched ? " (downloaded by 'avpplay fetch')" : "")\(t.source.hint.map { " – \($0)" } ?? "")",
                    "  fehlt: \(t.name)\(fetched ? " (lädt 'avpplay fetch')" : "")\(t.source.hint.map { " – \($0)" } ?? "")"))
        }
        if treesMissing.contains(where: { $0.source.kind == .user }) {
            print(L("  Then add them to the library with 'avpplay adopt \(r.id) --from <folder>' (one --from per folder).",
                    "  Danach mit 'avpplay adopt \(r.id) --from <Ordner>' übernehmen (je Ordner ein --from)."))
        }
    }
    if command == "plan" {
        for p in todo.prefix(40) {
            let how: String
            if case .resume(let from) = p.action { how = L("resume from \(from)", "fortsetzen ab \(from)") } else { how = L("download", "laden") }
            print("  \(how): \(p.file.name)\(p.file.size.map { L(" (\($0) bytes)", " (\($0) Bytes)") } ?? "")")
        }
        if todo.count > 40 { print(L("  … and \(todo.count - 40) more", "  … und \(todo.count - 40) weitere")) }
        break
    }
    guard !todo.isEmpty else { break }
    // Vor dem ersten Abruf: gehört das Spiel dem Konto? Ein gelungener Abruf wäre dafür kein Beleg,
    // ein verweigerter eine unnötige Abfrage.
    if let app = r.store.appId, let client {
        do {
            guard try await client.ownsApp(appId: app, userId: try await client.me()) else {
                fail(L("This account does not own \(r.title). Nothing is requested.",
                       "\(r.title) ist nicht im Besitz dieses Kontos. Es wird nichts angefragt."))
            }
        } catch { fail("\(error)") }
    } else if usesStore {
        print(L("Note: the recipe has no store app ID; ownership is not checked beforehand.",
                "Hinweis: Im Rezept fehlt die Store-App-ID; der Besitz wird nicht vorab geprüft."))
    }
    let interval = Double(o.value("interval") ?? "") ?? 0
    // Ohne Meta-Dateien wird der Client nie benutzt; er bekommt dann auch keinen Token.
    var fetcher = Fetcher(client: client ?? MetaClient(token: "unbenutzt"), store: store, gate: RequestGate(minInterval: .seconds(interval)))
    // Verweigert die direkte Adresse eine Datei des Spiels (HTTP 404), wird es einmal über Metas Werkzeug versucht.
    if client != nil, let token = try? TokenStore().read(account: o.value("account") ?? "default"),
       (try? MetaTool(url: metaToolURL(o)).verify()) != nil {
        fetcher.toolFallback = MetaToolDownload(tool: metaToolURL(o), token: token)
    }
    do {
        let summary = try await fetcher.run(plan, recipe: r) { print("  " + $0) }
        print(L("Done: \(summary.downloaded) downloaded (\(gigabytes(summary.bytes))), \(summary.kept) were already there.",
                "Fertig: \(summary.downloaded) geladen (\(gigabytes(summary.bytes))), \(summary.kept) waren vorhanden."))
        for l in summary.learned {
            print(L("  newly recorded: \(l.name)  \(l.size)  \(l.sha256)", "  neu erfasst: \(l.name)  \(l.size)  \(l.sha256)"))
        }
    } catch {
        fail(L("Aborted: \(error)\nNothing further is requested.", "Abgebrochen: \(error)\nEs wird nichts weiter angefragt."))
    }

case "verify":
    let r = recipe(o)
    let store = contentStore(o)
    var ok = 0, bad = 0, missing = 0, unknown = 0
    let files = r.files + (r.addons?.items ?? []).map { $0.asFile(dest: r.addons?.dest) }
    for f in files {
        let url = store.url(for: f, in: r)
        guard FileManager.default.fileExists(atPath: url.path) else { if f.required { missing += 1 }; continue }
        guard let expected = f.sha256 else { unknown += 1; continue }
        do {
            if try Hashing.sha256(of: url) == expected.lowercased() { ok += 1 } else {
                bad += 1; print(L("  MISMATCH: \(f.name)", "  ABWEICHEND: \(f.name)"))
            }
        } catch { fail("\(error)") }
    }
    print(L("\(r.title): \(ok) checked and OK, \(bad) mismatched, required files missing: \(missing), without a checksum in the recipe: \(unknown).",
            "\(r.title): \(ok) geprüft und in Ordnung, \(bad) abweichend, \(missing) Pflichtdateien fehlen, \(unknown) ohne Prüfsumme im Rezept."))
    let trees = TreeStore(store: store)
    for t in r.trees ?? [] {
        let dir = trees.url(for: t, in: r)
        let failing = TreeStore.failingMarkers(of: t, at: dir)
        if failing.isEmpty {
            let files = TreeStore.listing(of: dir)
            print(L("  Folder \(t.name): marker files OK (\(t.markers.count)); \(files.count) files, \(gigabytes(files.values.reduce(0, +))).",
                    "  Ordner \(t.name): \(t.markers.count) Kenndateien in Ordnung; \(files.count) Dateien, \(gigabytes(files.values.reduce(0, +)))."))
        } else if FileManager.default.fileExists(atPath: dir.path) {
            bad += 1
            print(L("  Folder \(t.name): MISMATCH or incomplete (\(failing.prefix(3).joined(separator: ", "))).",
                    "  Ordner \(t.name): ABWEICHEND oder unvollständig (\(failing.prefix(3).joined(separator: ", ")))."))
        } else {
            print(L("  Folder \(t.name): not in the library.", "  Ordner \(t.name): fehlt im Bestand."))
        }
    }
    if bad > 0 { exit(2) }

case "adopt":
    let r = recipe(o)
    guard let sources = o.values["from"], !sources.isEmpty else {
        fail(L("Give at least one --from <folder>.", "Mindestens ein --from <Ordner> angeben."))
    }
    do {
        let result = try Adopter(store: contentStore(o)).adopt(recipe: r, from: sources.map { URL(fileURLWithPath: $0) })
        print(L("\(r.title): \(result.adopted.count) added, \(result.alreadyPresent) were already in the library, "
                + "\(result.mismatched.count) don't match, \(result.unverifiable.count) without a checksum in the recipe, "
                + "\(result.notFound.count) not found.",
                "\(r.title): \(result.adopted.count) übernommen, \(result.alreadyPresent) waren schon im Bestand, "
                + "\(result.mismatched.count) passen nicht, \(result.unverifiable.count) ohne Prüfsumme im Rezept, "
                + "\(result.notFound.count) nicht gefunden."))
        for n in result.mismatched.prefix(8) {
            print(L("  doesn't match (a different version?): \(n)", "  passt nicht (andere Version?): \(n)"))
        }
        if result.mismatched.count > 8 {
            print(L("  … and \(result.mismatched.count - 8) more", "  … und \(result.mismatched.count - 8) weitere"))
        }
        if r.trees?.isEmpty == false {
            let t = try TreeStore(store: contentStore(o)).adopt(recipe: r, from: sources.map { URL(fileURLWithPath: $0) })
            print(L("Folders: \(t.adopted.count) added\(t.adopted.isEmpty ? "" : " (\(t.adopted.joined(separator: ", ")))"), "
                    + "\(t.alreadyPresent.count) were already in the library, \(t.notFound.count) not found"
                    + "\(t.notFound.isEmpty ? "" : " (\(t.notFound.joined(separator: ", ")): none of the given folders has the marker files of this version)").",
                    "Ordner: \(t.adopted.count) übernommen\(t.adopted.isEmpty ? "" : " (\(t.adopted.joined(separator: ", ")))"), "
                    + "\(t.alreadyPresent.count) waren schon im Bestand, \(t.notFound.count) nicht gefunden"
                    + "\(t.notFound.isEmpty ? "" : " (\(t.notFound.joined(separator: ", ")): kein angegebener Ordner trägt die Kenndateien dieser Version)")."))
        }
    } catch { fail("\(error)") }

case "unpack":
    let r = recipe(o)
    guard let to = o.value("to") else {
        fail(L("Give the destination folder with --to <folder>.", "Zielordner mit --to <Ordner> angeben."))
    }
    guard let apk = r.files.first(where: { $0.role == "apk" }) else {
        fail(L("The recipe doesn't list an APK.", "Das Rezept nennt kein APK."))
    }
    let source = contentStore(o).url(for: apk, in: r)
    guard FileManager.default.fileExists(atPath: source.path) else {
        fail(L("The APK is not in the library (run 'avpplay fetch' or 'avpplay adopt' first).",
               "Das APK liegt nicht im Bestand (erst 'avpplay fetch' oder 'avpplay adopt')."))
    }
    do {
        let info = try ApkUnpacker().unpack(apk: source, to: URL(fileURLWithPath: to))
        print(L("\(r.title): \(info.files) files unpacked; package \(info.package ?? "?"), version \(info.versionName ?? "?") (\(info.versionCode ?? "?")).",
                "\(r.title): \(info.files) Dateien entpackt; Paket \(info.package ?? "?"), Version \(info.versionName ?? "?") (\(info.versionCode ?? "?"))."))
        if info.package != r.package || info.versionCode != String(r.versionCode) {
            fail(L("The APK doesn't match the recipe (expected \(r.package), version code \(r.versionCode)).",
                   "Das APK passt nicht zum Rezept (erwartet \(r.package), Code \(r.versionCode))."))
        }
    } catch { fail("\(error)") }

case "icon":
    let r = recipe(o)
    guard let to = o.value("to") else {
        fail(L("Give the destination folder with --to <folder>.", "Zielordner mit --to <Ordner> angeben."))
    }
    do {
        // dieselbe Auswahl wie bei der Installation
        guard let chosen = Toolchain.chooseIcon(recipe: r, store: contentStore(o)) else {
            print(L("\(r.title): no icon available (the APK contains at most the engine's placeholder).",
                    "\(r.title): kein Icon verfügbar (das APK enthält höchstens den Platzhalter der Engine).")); break
        }
        try AppIcon.writeImageStack(chosen.source, to: URL(fileURLWithPath: to))
        print(L("\(r.title): \(chosen.origin) (\(chosen.source.summary)) written to \(to).",
                "\(r.title): \(chosen.origin) (\(chosen.source.summary)) nach \(to) geschrieben."))
        if o.flags.contains("fingerprint") {
            print(L("  Fingerprint: \(AppIcon.fingerprint(chosen.source))", "  Fingerabdruck: \(AppIcon.fingerprint(chosen.source))"))
        }
    } catch { fail("\(error)") }

case "devices":
    do {
        let all = try DeviceControl().devices()
        if all.isEmpty { print(L("No Vision Pro is known to this Mac.", "Keine Vision Pro bekannt.")) }
        for d in all {
            print(L("\(d.name)  visionOS \(d.osVersion)  \(d.udid)  \(d.paired ? "paired" : "not paired"), "
                    + "\(d.reachable ? "reachable" : "not reachable"), Developer Mode \(d.developerMode ? "on" : "off")",
                    "\(d.name)  visionOS \(d.osVersion)  \(d.udid)  \(d.paired ? "gekoppelt" : "nicht gekoppelt"), "
                    + "\(d.reachable ? "erreichbar" : "nicht erreichbar"), Entwicklermodus \(d.developerMode ? "an" : "aus")")
                  + (d.transport.map { L(", connected over \($0.text)", ", verbunden über \($0.text)") } ?? ""))
        }
    } catch { fail("\(error)") }

case "install", "stage":
    // Ohne Download: was im Bestand fehlt, ist ein Fehler. Der ganze Weg samt Laden ist 'avpplay job start'.
    let r = recipe(o)
    if command == "install", o.value("team") == nil {
        fail(L("For 'install', give the Apple Team ID with --team.", "Für 'install' die Apple-Team-ID mit --team angeben."))
    }
    let copying = CopyProgressPrinter()
    var request = installRequest(o, recipe: r.id)
    request.otherSourceBuilds = otherSourceBuilds(of: r, o)
    var installer = Installer(recipe: r, request: request, store: contentStore(o), progress: { copying.show($0) }) { print($0) }
    installer.metaTool = metaToolURL(o)
    do {
        for step in (command == "install" ? [.account, .build, .stage, .unlock] : [.account, .stage, .unlock]) as [InstallStep] {
            try await installer.perform(step)
        }
        print(L("Done: \(r.title) is ready on the device.", "Fertig: \(r.title) ist auf dem Gerät bereit."))
    } catch { fail("\(error)") }

case "toolchains":
    let all = toolchainPackager(o).installed()
    if all.isEmpty { print(L("No toolchain package is installed.", "Kein Toolchain-Paket installiert.")) }
    // Dazu die als bearbeitet gekennzeichneten Arbeitskopien aus „Fix with AI“.
    for t in all + FixWorkspace.modifiedToolchains() {
        guard let m = t.manifest else { continue }
        print(L("Version \(t.name) (\(m.commit)), created \(ISO8601DateFormatter().string(from: m.created))  \(t.root.path)",
                "Version \(t.name) (\(m.commit)), erstellt \(ISO8601DateFormatter().string(from: m.created))  \(t.root.path)"))
    }
    if o.flags.contains("released") {
        do {
            let have = Set(all.map { $0.commit() })
            for r in try await ToolchainReleases.list() where !have.contains(r.commit) {
                print(L("Version \(r.version) (\(r.commit)), from AVP Play \(r.appVersion) on GitHub – avpplay toolchain get \(r.version)",
                        "Version \(r.version) (\(r.commit)), aus AVP Play \(r.appVersion) auf GitHub – avpplay toolchain get \(r.version)"))
            }
        } catch { fail("\(error)") }
    }
    for (game, pin) in ToolchainChoices.load().games.sorted(by: { $0.key < $1.key }) {
        print(L("\(game) is built with version \(pin.name) (\(pin.commit)).", "\(game) wird mit Version \(pin.name) (\(pin.commit)) gebaut."))
    }

case "servers":
    let r = recipe(o)
    let servers = GameServerStore()
    do {
        guard r.servers != nil else { throw GameServerError.notSupported(r.title) }
        switch o.positional.count > 2 ? o.positional[2] : "list" {
        case "add":
            guard o.positional.count > 3 else { fail(L("Give the server's address.", "Die Adresse des Servers angeben.")) }
            let server = try servers.add(address: o.positional[3], name: o.value("name") ?? "", recipe: r)
            if o.flags.contains("admin-stdin") {
                guard let line = readLine(strippingNewline: true), !line.isEmpty else { throw GameServerError.badPassword }
                try servers.setAdminPassword(line, address: server.address, recipe: r)
            }
            print(L("\(server.name) (\(server.address)) is in the list.", "\(server.name) (\(server.address)) steht in der Liste."))
        case "remove":
            guard o.positional.count > 3, let support = r.servers,
                  let address = GameServerStore.normalize(o.positional[3], defaultPort: support.defaultPort ?? 27015) else {
                fail(L("Give the server's address.", "Die Adresse des Servers angeben."))
            }
            try servers.remove(address: address, recipe: r)
            print(L("\(address) has been removed.", "\(address) wurde entfernt."))
        case "push":
            let device = try DeviceControl().pick(udid: o.value("device"))
            let bundle = o.value("bundle-id") ?? SigningRecord.load(store: contentStore(o), recipe: r)?.bundleId
                ?? Toolchain.defaultBundleId(target: r.toolchain.target)
            print(try servers.push(recipe: r, device: device, bundle: bundle)
                ? L("The list is in the game's data on the Vision Pro; it applies from the next start of the game.",
                    "Die Liste liegt bei den Daten des Spiels auf der Vision Pro; sie gilt ab dem nächsten Start des Spiels.")
                : L("Nothing to copy: the list is empty and there is none on the Vision Pro.", "Nichts zu kopieren: Die Liste ist leer, und auf der Vision Pro liegt keine."))
        default:
            let list = servers.all(recipe: r)
            let fixed = Set(GameServerStore.builtin(recipe: r).map(\.address))
            if list.isEmpty { print(L("No servers yet.", "Noch keine Server.")) }
            for server in list {
                let admin = servers.hasAdminPassword(address: server.address, recipe: r)
                print("\(server.address)  \(server.name)  \(admin ? L("admin access stored", "Admin-Zugang hinterlegt") : L("no admin access", "kein Admin-Zugang"))"
                      + (fixed.contains(server.address) ? L("  (built in)", "  (eingebaut)") : ""))
            }
        }
    } catch { fail("\(error)") }

case "renew":
    let chosen = (o.value("toolchain") ?? ProcessInfo.processInfo.environment["AVPPLAY_TOOLCHAIN"]).flatMap { try? Toolchain(root: URL(fileURLWithPath: $0)) }
    let dry = o.flags.contains("dry-run")
    // Eine ausdrücklich genannte Toolchain gilt für alle Spiele; sonst je Spiel die dafür gewählte.
    let report = await Renewal.run(recipes: Renewal.recipes(bundled: recipesDirectory(o), drafts: DataLocation.base.appendingPathComponent("drafts", isDirectory: true)),
                                   store: contentStore(o), toolchain: chosen ?? toolchainPackager(o).installed().first,
                                   choices: chosen == nil ? .load() : ToolchainChoices(), packager: toolchainPackager(o),
                                   preferredDevice: o.value("device"), dryRun: dry, force: Set(o.values["force"] ?? []), log: { print($0) })
    if !dry { report.save() }
    print(report.outcomes.isEmpty
        ? L("Nothing is due (\(report.known) installation(s) with a known date).", "Nichts fällig (\(report.known) Installation(en) mit bekanntem Datum).")
        : L("\(report.outcomes.count) due: \(report.outcomes.filter { $0.result == .renewed }.count) renewed, \(report.outcomes.filter { $0.result == .failed }.count) failed, the rest not tried.",
            "\(report.outcomes.count) fällig: \(report.outcomes.filter { $0.result == .renewed }.count) erneuert, \(report.outcomes.filter { $0.result == .failed }.count) gescheitert, der Rest nicht versucht."))

case "saves":
    // Holt Spielstände – aller installierten Spiele oder der genannten. Was die Oberfläche von selbst tut.
    let known = Renewal.recipes(bundled: recipesDirectory(o), drafts: DataLocation.base.appendingPathComponent("drafts", isDirectory: true))
    let named = Set(o.positional.dropFirst())
    let wanted = named.isEmpty ? known : known.filter { named.contains($0.id) }
    guard !wanted.isEmpty else { fail(L("No recipe by that name.", "Kein Rezept mit diesem Namen.")) }
    let saves = o.value("saves").map { SaveStore(root: URL(fileURLWithPath: $0)) } ?? SaveStore(root: SaveStore.root(forStore: contentStore(o).root))
    if o.flags.contains("restore") {
        // Den neuesten Stand eines Spiels aufs Gerät zurückspielen und ersetzen, was dort liegt. Was dort liegt, wird
        // vorher geholt; läuft das Spiel, passiert nichts.
        guard wanted.count == 1, !named.isEmpty, let r = wanted.first else { fail(L("--restore takes exactly one game.", "--restore braucht genau ein Spiel.")) }
        do {
            let control = DeviceControl()
            let device = try control.pick(udid: o.value("device"))
            let apps = try control.apps(device: device)
            guard let bundle = o.value("bundle-id") ?? SaveSync.installedBundle(recipe: r, store: contentStore(o), prefix: nil, apps: apps),
                  let app = apps.first(where: { $0.bundleIdentifier == bundle }) else { fail("\(InstallError.appNotInstalled(r.title))") }
            guard !DeviceControl.isRunning(app, executables: try control.runningExecutables(device: device)) else { fail("\(InstallError.appRunning(r.title))") }
            guard let snapshot = saves.snapshots(for: r).first else { fail("\(SaveError.nothingSaved(r.title))") }
            let sync = SaveSync(saves: saves, store: contentStore(o))
            _ = try sync.fetch(recipe: r, device: device, bundle: bundle)
            let n = try sync.restore(snapshot, recipe: r, device: device, bundle: bundle, mode: .overwrite)
            print(L("\(r.title): \(n) file(s) from \(snapshot.id) put back on the Vision Pro (\(bundle)).",
                    "\(r.title): \(n) Datei(en) vom \(snapshot.id) auf die Vision Pro zurückgespielt (\(bundle))."))
        } catch { fail("\(error)") }
        exit(0)
    }
    guard let results = SaveRound.run(recipes: wanted, store: contentStore(o), saves: saves, preferredDevice: o.value("device"),
                                      prefix: o.value("bundle-id").map { ($0 as NSString).deletingPathExtension }) else {
        fail("\(DeviceError.noDevice)")
    }
    for r in results {
        let where_ = r.snapshot.map { "  " + saves.directory(for: wanted.first { $0.id == r.recipe }!).appendingPathComponent($0.id).path } ?? ""
        print("\(r.title): \(r.detail)\(r.kind == .saved ? where_ : "")")
    }
    if results.isEmpty { print(L("None of these games is on the Vision Pro.", "Keines dieser Spiele ist auf der Vision Pro.")) }

case "toolchain":
    guard o.positional.count >= 2 else {
        fail(L("Usage: avpplay toolchain pack --from <Fork> --to <folder> | avpplay toolchain install <archive> | avpplay toolchain prune [--keep <count>] | avpplay toolchain get <number> | avpplay toolchain mark <folder> | avpplay toolchain use <id> --toolchain <folder> | --newest",
               "Aufruf: avpplay toolchain pack --from <Fork> --to <Ordner> | avpplay toolchain install <Archiv> | avpplay toolchain prune [--keep <Anzahl>] | avpplay toolchain get <Nummer> | avpplay toolchain mark <Ordner> | avpplay toolchain use <id> --toolchain <Ordner> | --newest"))
    }
    switch o.positional[1] {
    case "pack":
        guard let from = o.value("from"), let to = o.value("to") else {
            fail(L("For 'pack', give --from <fork working directory> and --to <folder>.",
                   "Für 'pack' --from <Fork-Arbeitsverzeichnis> und --to <Ordner> angeben."))
        }
        do {
            let (archive, m) = try ToolchainPackager.pack(checkout: URL(fileURLWithPath: from), to: URL(fileURLWithPath: to))
            print(L("Package version \(m.version) (\(m.commit)): \(archive.path)", "Paket Version \(m.version) (\(m.commit)): \(archive.path)"))
            print("  \(gigabytes(m.size ?? 0)), SHA-256 \(m.sha256 ?? "?")")
            print(L("  Description: \(ToolchainPackager.sidecar(for: archive).lastPathComponent) – belongs with the archive.",
                    "  Beschreibung: \(ToolchainPackager.sidecar(for: archive).lastPathComponent) – gehört zum Archiv."))
        } catch { fail("\(error)") }
    case "install":
        guard o.positional.count >= 3 else {
            fail(L("Give the archive: avpplay toolchain install <archive>", "Archiv angeben: avpplay toolchain install <Archiv>"))
        }
        do {
            let t = try toolchainPackager(o).install(archive: URL(fileURLWithPath: o.positional[2]))
            print(L("Toolchain version \(t.version()) (\(t.commit())) installed: \(t.root.path)",
                    "Toolchain Version \(t.version()) (\(t.commit())) installiert: \(t.root.path)"))
        } catch { fail("\(error)") }
    case "prune":
        // Alte Pakete entfernen; was ein offener Auftrag festhält oder für ein Spiel gewählt ist, bleibt.
        do {
            let open = Set(jobStore(o).all().filter { [.waiting, .running, .failed].contains($0.state) }.map(\.toolchainCommit))
                .union(ToolchainChoices.load().packageCommits)
            let keep = o.value("keep").flatMap { Int($0) } ?? 1
            let removed = try toolchainPackager(o).prune(keep: keep, protecting: open)
            if removed.isEmpty { print(L("Nothing to remove.", "Nichts zu entfernen.")) }
            for m in removed { print(L("Removed: version \(m.version) (\(m.commit))", "Entfernt: Version \(m.version) (\(m.commit))")) }
        } catch { fail("\(error)") }
    case "get":
        guard o.positional.count >= 3, let number = Int(o.positional[2]) else {
            fail(L("Give the toolchain's number: avpplay toolchain get <number> (see avpplay toolchains --released)",
                   "Die Nummer der Toolchain angeben: avpplay toolchain get <Nummer> (siehe avpplay toolchains --released)"))
        }
        do {
            guard let package = try await ToolchainReleases.list().first(where: { $0.version == number }) else {
                fail(L("No release of AVP Play on GitHub came with toolchain \(number).", "Keine Veröffentlichung von AVP Play auf GitHub kam mit Toolchain \(number)."))
            }
            let t = try await ToolchainReleases.install(package, with: toolchainPackager(o))
            print(L("Toolchain version \(t.version()) (\(t.commit())) installed: \(t.root.path)",
                    "Toolchain Version \(t.version()) (\(t.commit())) installiert: \(t.root.path)"))
            print(L("An automatic tidy-up removes it again unless it is chosen for a game: avpplay toolchain use <id> --toolchain \(t.root.path)",
                    "Ein automatisches Aufräumen entfernt sie wieder, solange sie für kein Spiel gewählt ist: avpplay toolchain use <id> --toolchain \(t.root.path)"))
        } catch { fail("\(error)") }
    case "mark":
        guard o.positional.count >= 3 else {
            fail(L("Give the working copy: avpplay toolchain mark <folder>", "Arbeitskopie angeben: avpplay toolchain mark <Ordner>"))
        }
        do {
            let t = try toolchainPackager(o).markModified(URL(fileURLWithPath: o.positional[2]).standardizedFileURL)
            print(L("Marked as modified: toolchain \(t.name) in \(t.root.path). Games built with it say so on the Vision Pro and in AVP Play.",
                    "Als bearbeitet gekennzeichnet: Toolchain \(t.name) in \(t.root.path). Damit gebaute Spiele sagen das auf der Vision Pro und in AVP Play."))
        } catch { fail("\(error)") }
    case "use":
        // Die Wahl der Toolchain für ein Spiel – dieselbe, die seine Seite in der App anbietet.
        let r = recipe(o, at: 2)
        var choices = ToolchainChoices.load()
        do {
            if o.flags.contains("newest") {
                choices.choose(nil, for: r.id)
                try choices.save()
                print(L("\(r.title) is built with the newest toolchain again.", "\(r.title) wird wieder mit der neuesten Toolchain gebaut."))
            } else {
                guard let folder = o.value("toolchain") else {
                    fail(L("Give the toolchain with --toolchain <folder>, or --newest.", "Die Toolchain mit --toolchain <Ordner> angeben, oder --newest."))
                }
                let t = try Toolchain(root: URL(fileURLWithPath: folder).standardizedFileURL)
                guard t.manifest != nil else { throw PackageError.notAWorkingCopy(t.root.path) }
                guard r.toolchain.minCommit.isEmpty || t.satisfies(minCommit: r.toolchain.minCommit) else {
                    throw ToolchainError.tooOld(have: t.commit(), need: r.toolchain.minCommit)
                }
                let pin = toolchainPackager(o).pin(for: t)
                choices.choose(pin, for: r.id)
                try choices.save()
                print(L("\(r.title) is built with toolchain \(pin.name) (\(pin.commit)) from now on – when it is installed, updated or signed again. AVP Play does not remove or replace this toolchain. Back to the newest: avpplay toolchain use \(r.id) --newest, or on the game's page in the app.",
                        "\(r.title) wird ab jetzt mit Toolchain \(pin.name) (\(pin.commit)) gebaut – beim Installieren, Aktualisieren und neu Signieren. AVP Play entfernt oder ersetzt diese Toolchain nicht. Zurück zur neuesten: avpplay toolchain use \(r.id) --newest, oder auf der Seite des Spiels in der App."))
            }
        } catch { fail("\(error)") }
    default:
        fail(L("Unknown toolchain command '\(o.positional[1])'.", "Unbekannter Toolchain-Befehl '\(o.positional[1])'."))
    }

case "status":
    // Was der Mac weiß (Bestand) neben dem, was das Gerät meldet (installierte App und ihr Stempel).
    do {
        let store = contentStore(o)
        let control = DeviceControl()
        let device = try? control.pick(udid: o.value("device"))
        let apps = (try? device.map { try control.apps(device: $0) }) ?? nil
        if let device { print(L("Device: \(device.name) (visionOS \(device.osVersion))", "Gerät: \(device.name) (visionOS \(device.osVersion))")) }
        else { print(L("No reachable device – only the library is shown.", "Kein erreichbares Gerät – es wird nur der Bestand gezeigt.")) }
        let toolchain = try? Toolchain(root: URL(fileURLWithPath: installRequest(o).toolchain))
        if let toolchain {
            print(L("Toolchain: version \(toolchain.version()) (\(toolchain.commit()))",
                    "Toolchain: Version \(toolchain.version()) (\(toolchain.commit()))"))
        }
        let pins = ToolchainChoices.load().games
        for r in try RecipeStore(directory: recipesDirectory(o)).loadAll() {
            let st = GameStatus.of(recipe: r, store: store, apps: apps, toolchainVersion: toolchain?.appRevision(), pin: pins[r.id])
            var bestand = L("\(st.filesPresent)/\(st.filesRequired) files", "\(st.filesPresent)/\(st.filesRequired) Dateien")
            if st.treesRequired > 0 {
                bestand += L(", \(st.treesPresent)/\(st.treesRequired) folders", ", \(st.treesPresent)/\(st.treesRequired) Ordner")
            }
            let geraet: String
            switch st.onDevice {
            case .unknown: geraet = "–"
            case .notInstalled: geraet = L("not installed", "nicht installiert")
            case .current(let stamp): geraet = L("installed, \(stamp)", "installiert, \(stamp)")
            case .olderToolchain(let stamp):
                geraet = pins[r.id].map { L("installed, \(stamp) – not built with toolchain \($0.name), which is chosen for this game",
                                            "installiert, \(stamp) – nicht mit Toolchain \($0.name) gebaut, die für dieses Spiel gewählt ist") }
                    ?? L("installed, \(stamp) – built with an older toolchain", "installiert, \(stamp) – mit älterer Toolchain gebaut")
            case .olderGame(let stamp):
                geraet = L("installed, \(stamp) – an older version of the game", "installiert, \(stamp) – eine ältere Fassung des Spiels")
            case .unstamped(let stamp):
                geraet = L("installed, \(stamp) – without this tool's stamp", "installiert, \(stamp) – ohne Stempel dieses Werkzeugs")
            case .otherSource(let stamp):
                geraet = L("installed, \(stamp) – from another purchase source", "installiert, \(stamp) – aus einer anderen Kaufquelle")
            }
            print("\(r.id.padding(toLength: 13, withPad: " ", startingAt: 0)) \(r.title) \(r.versionName)")
            print(L("              Library: \(bestand)   Device: \(geraet)", "              Bestand: \(bestand)   Gerät: \(geraet)"))
        }
    } catch { fail("\(error)") }

case "jobs":
    let jobs = jobStore(o).all()
    if jobs.isEmpty { print(L("No jobs.", "Keine Aufträge.")) }
    for j in jobs { print(describe(j)) }

case "job":
    guard o.positional.count >= 3 else {
        fail(L("Usage: avpplay job start <recipe> --team <team ID> | avpplay job resume|show|cancel <job>",
               "Aufruf: avpplay job start <Rezept> --team <Team-ID> | avpplay job resume|show|cancel <Auftrag>"))
    }
    let jobs = jobStore(o)
    let runner = JobRunner(store: jobs)
    func run(_ job: Job) async {
        var installer = Installer(recipe: job.recipe, request: job.request, store: contentStore(o)) { print("  " + $0) }
        installer.metaTool = metaToolURL(o)
        do {
            let now = (try? Toolchain(root: URL(fileURLWithPath: job.request.toolchain)).commit()) ?? L("unknown", "unbekannt")
            let done = try await runner.run(job, currentToolchain: now, log: { print($0) }) { step, _ in try await installer.perform(step) }
            print(done.isDownloadOnly
                ? L("Job \(done.id) finished: the files of \(done.recipe.title) are downloaded.",
                    "Auftrag \(done.id) abgeschlossen: Die Dateien von \(done.recipe.title) sind geladen.")
                : done.isAddonSync
                ? L("Job \(done.id) finished: the add-on content of \(done.recipe.title) is up to date.",
                    "Auftrag \(done.id) abgeschlossen: Die Zusatzinhalte von \(done.recipe.title) sind auf dem Stand.")
                : !done.steps.contains(.stage)
                ? L("Job \(done.id) finished: \(done.recipe.title) is built and installed. Its game data has not been copied to the device yet.",
                    "Auftrag \(done.id) abgeschlossen: \(done.recipe.title) ist gebaut und installiert. Die Spieldaten sind noch nicht aufs Gerät kopiert.")
                : L("Job \(done.id) finished: \(done.recipe.title) is ready on the device.",
                    "Auftrag \(done.id) abgeschlossen: \(done.recipe.title) ist auf dem Gerät bereit."))
        } catch let error as JobError {
            fail("\(error)")          // hier gibt es nichts fortzusetzen
        } catch {
            fail(L("\(error)\nJob \(job.id) stopped. Resume it with: avpplay job resume \(job.id)",
                   "\(error)\nAuftrag \(job.id) angehalten. Fortsetzen mit: avpplay job resume \(job.id)"))
        }
    }
    switch o.positional[1] {
    case "start":
        let addonsOnly = o.flags.contains("addons-only")
        // Nur prüfen, laden, bauen und installieren – ohne die Spieldaten aufs Gerät zu kopieren. Zum Ausprobieren,
        // ob ein Spiel überhaupt durch die Toolchain kommt, bevor Dutzende Gigabyte übertragen werden.
        let buildOnly = o.flags.contains("build-only")
        // Nur laden, was das Programm selbst besorgen kann. Braucht weder Xcode noch Toolchain, Team oder Gerät.
        let downloadOnly = o.flags.contains("download-only")
        if o.value("team") == nil, !addonsOnly, !downloadOnly {
            fail(L("For a job, give the Apple Team ID with --team.", "Für einen Auftrag die Apple-Team-ID mit --team angeben."))
        }
        let r = recipe(o, at: 2)
        var request = installRequest(o, recipe: r.id)
        request.otherSourceBuilds = otherSourceBuilds(of: r, o)
        if addonsOnly { request.addons = true }
        if downloadOnly { request.downloadOnly = true }
        do {
            // Eingefroren wird der Stand, mit dem der Auftrag beginnt. Wer nur lädt, braucht keine Toolchain.
            let commit = downloadOnly ? "" : try Toolchain(root: URL(fileURLWithPath: request.toolchain)).commit()
            let steps = downloadOnly ? InstallStep.download : addonsOnly ? InstallStep.addonSync : buildOnly ? [.account, .fetch, .build] : InstallStep.allCases
            // Auch ein Auftrag der Kommandozeile bekommt seinen Platz, sonst stünde er in der Liste unter allen anderen.
            let job = try jobs.enqueue(Job(recipe: r, request: request, steps: steps, toolchainCommit: commit))
            print(downloadOnly ? L("Job \(job.id) created (\(r.title), download only).", "Auftrag \(job.id) angelegt (\(r.title), nur laden).")
                               : L("Job \(job.id) created (\(r.title), toolchain \(commit)).", "Auftrag \(job.id) angelegt (\(r.title), Toolchain \(commit))."))
            await run(job)
        } catch { fail("\(error)") }
    case "resume":
        do { await run(try jobs.load(o.positional[2])) } catch { fail("\(error)") }
    case "show":
        do {
            let j = try jobs.load(o.positional[2])
            print(describe(j))
            for step in j.steps {
                let mark = j.completed.contains(step) ? L("done", "erledigt")
                    : (j.current == step ? (j.state == .failed ? L("failed", "fehlgeschlagen") : L("interrupted here", "hier unterbrochen"))
                                         : L("pending", "offen"))
                print("  \(step.title.padding(toLength: 28, withPad: " ", startingAt: 0)) \(mark)")
            }
            if let f = j.failure { print(L("  Reason: \(f)", "  Grund: \(f)")) }
        } catch { fail("\(error)") }
    case "cancel":
        do {
            let cancelled = try runner.cancel(o.positional[2]).id
            print(L("Job \(cancelled) cancelled. Downloaded files and data on the device are kept.",
                    "Auftrag \(cancelled) abgebrochen. Geladene Dateien und Daten auf dem Gerät bleiben erhalten."))
        }
        catch { fail("\(error)") }
    default:
        fail(L("Unknown job command '\(o.positional[1])'.", "Unbekannter Auftragsbefehl '\(o.positional[1])'."))
    }

default:
    fail(L("Unknown command '\(command)'.\n\n", "Unbekannter Befehl '\(command)'.\n\n") + usage())
}

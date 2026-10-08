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
    fail("Kein Rezeptordner gefunden. Mit --recipes <Ordner> angeben.")
}

func contentStore(_ o: Options) -> ContentStore {
    if let p = o.value("store") ?? ProcessInfo.processInfo.environment["AVPPLAY_STORE"] {
        return ContentStore(root: URL(fileURLWithPath: p))
    }
    return ContentStore(root: ContentStore.defaultRoot)
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

// Die Kommandozeile spricht vorerst nur Deutsch: ihre eigenen Texte sind noch nicht übersetzt, und halb
// englische Ausgaben (Meldungen der Bibliothek) wären schlechter als einheitlich deutsche.
L10n.language = .de
// Daten aus der Zeit vor dem Namen „AVP Play“ einmalig übernehmen (der Ordner wird umbenannt).
DataLocation.adoptLegacyData()

// Zeilenweise ausgeben, auch wenn die Ausgabe in eine Pipe geht – sonst erscheint der Fortschritt erst am Ende.
setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
qi – Kern-Bibliothek, Kommandozeile

  avpplay recipes                              Rezepte auflisten
  avpplay show <id>                            Dateien eines Rezepts
  avpplay login                                bei Meta anmelden (startet ovr-platform-util; --tool <Pfad>, Standard ~/Downloads)
  avpplay logout                               hinterlegten Meta-Token löschen
  qi account                              hinterlegten Meta-Token prüfen
  qi owns <id>                            Besitzt das Konto das Spiel?
  qi purchases <id>                       bestätigte Käufe im Spiel und zugehörige Zusatzinhalte
  avpplay plan <id>   [Auswahl]                zeigen, was geladen würde (keine Abfrage an die Download-Seite)
  avpplay fetch <id>  [Auswahl]                fehlende Dateien laden und prüfen
  qi verify <id>                          vorhandene Dateien gegen die Prüfsummen des Rezepts prüfen
  avpplay adopt <id> --from <Ordner> […]       vorhandene Dateien und Ordner nach Prüfung in den Bestand übernehmen (kein Netz)
  qi unpack <id> --to <Ordner>            APK aus dem Bestand für die Toolchain entpacken (ersetzt apktool)
  avpplay icon <id> --to <Ordner>              App-Icon aus dem APK als visionOS-Icon (drei Ebenen) ablegen
  qi devices                              gekoppelte Vision-Pro-Geräte
  avpplay status                               je Spiel: Bestand auf dem Mac und Stand auf dem Gerät
  avpplay toolchains                           installierte Toolchain-Pakete
  avpplay toolchain pack --from <Fork> --to <Ordner>      Paket aus einem eingecheckten Fork-Stand bauen
  avpplay toolchain install <Archiv>           Paket prüfen und installieren
  avpplay install <id> --team <Team-ID>        bauen, installieren, Daten ergänzend kopieren, Zusatzinhalte freischalten
  avpplay stage <id>                           nur Daten und Zusatzinhalte ergänzend kopieren (ohne Build)
  avpplay job start <id> --team <Team-ID>      Auftrag: prüfen, laden, bauen, installieren, kopieren, freischalten
  avpplay job resume <Auftrag>                 unterbrochenen oder angehaltenen Auftrag fortsetzen
  avpplay job show|cancel <Auftrag>            Stand zeigen / abbrechen          avpplay jobs   alle Aufträge
             --device <UDID>  --bundle-id <ID>  --toolchain <Ordner>  --no-addons
             --icon <Bilddatei>      eigenes App-Icon hinterlegen (hat Vorrang vor allem anderen)
             --no-store-art          kein Titelbild von der Store-Seite holen (dann Icon aus dem APK)
             --replace-running       auch installieren, wenn das Spiel gerade läuft (es wird dabei beendet)

Auswahl:   --locale de-DE      Sprachvariante dazunehmen (mehrfach möglich)
           --with <Dateiname>  wählbare Datei dazunehmen (mehrfach möglich)
           --only <Dateiname>  nur diese Datei (mehrfach möglich)
           --addons            gekaufte Zusatzinhalte dazunehmen (fragt die Kaufliste ab)
Allgemein: --account <Name>    Eintrag im Schlüsselbund (Standard: default)
           --store <Ordner>    Ablage der Dateien      --recipes <Ordner>
           --interval <s>      Mindestabstand zwischen Abrufen (Standard: 5)
"""

let valued: Set<String> = ["account", "store", "recipes", "locale", "with", "only", "interval", "from", "to",
                           "team", "device", "bundle-id", "toolchain", "icon", "tool", "jobs", "toolchains"]
let o = Options(Array(CommandLine.arguments.dropFirst()), valued: valued)
guard let command = o.positional.first else { print(usage); exit(0) }

func recipe(_ o: Options) -> Recipe {
    guard o.positional.count >= 2 else { fail("Rezept-Kennung fehlt.\n\n" + usage) }
    do { return try RecipeStore(directory: recipesDirectory(o)).load(id: o.positional[1]) } catch { fail("\(error)") }
}

func toolchainPackager(_ o: Options) -> ToolchainPackager {
    ToolchainPackager(root: (o.value("toolchains") ?? ProcessInfo.processInfo.environment["AVPPLAY_TOOLCHAINS"])
                          .map { URL(fileURLWithPath: $0) } ?? ToolchainPackager.defaultRoot)
}

func jobStore(_ o: Options) -> JobStore {
    JobStore(directory: (o.value("jobs") ?? ProcessInfo.processInfo.environment["AVPPLAY_JOBS"]).map { URL(fileURLWithPath: $0) }
             ?? JobStore.defaultDirectory)
}

/// Die Angaben der Kommandozeile als Auftrag an die Bibliothek.
func installRequest(_ o: Options) -> InstallRequest {
    // Reihenfolge: ausdrücklich genannt, dann das neueste installierte Paket, zuletzt das Arbeitsverzeichnis
    // der Entwicklung neben den Rezepten.
    let toolchain = o.value("toolchain") ?? ProcessInfo.processInfo.environment["AVPPLAY_TOOLCHAIN"]
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
    request.customIcon = o.value("icon").map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    request.storeArt = !o.flags.contains("no-store-art")
    if o.flags.contains("replace-running") { request.replaceRunning = true }
    request.interval = Double(o.value("interval") ?? "") ?? 5
    return request
}

func describe(_ j: Job) -> String {
    let state: String
    switch j.state {
    case .waiting: state = "wartet"
    case .running: state = "unterbrochen bei „\(j.current?.title ?? "?")“"
    case .failed: state = "angehalten bei „\(j.current?.title ?? "?")“"
    case .finished: state = "abgeschlossen"
    case .cancelled: state = "abgebrochen"
    }
    return "\(j.id)  \(j.recipe.title) \(j.recipe.versionName) – \(state), \(j.completed.count)/\(j.steps.count) Schritte"
}

func selection(_ o: Options, recipe: Recipe, client: MetaClient?) async -> FetchSelection {
    var s = FetchSelection(locales: Set(o.values["locale"] ?? []), optionalNames: Set(o.values["with"] ?? []))
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
                  + "\(required.count) Pflichtdateien (\(gigabytes(known)) bekannt), Download: \(r.status.download), "
                  + "Spielbarkeit: \(r.status.playability)")
        }
    } catch { fail("\(error)") }

case "show":
    let r = recipe(o)
    print("\(r.title) \(r.versionName) (\(r.package), Code \(r.versionCode))")
    for f in r.files {
        print("  \(f.required ? "Pflicht " : "wählbar ") \(f.role.padding(toLength: 15, withPad: " ", startingAt: 0)) "
              + "\(f.name)\(f.size.map { "  \($0) Bytes" } ?? "")\(f.sha256 == nil ? "  (ohne Prüfsumme)" : "")")
    }
    if let a = r.addons { print("  Zusatzinhalte: \(a.kind.rawValue)\(a.items.map { ", \($0.count) Einträge" } ?? "")") }
    for t in r.trees ?? [] {
        print("  Ordner   \(t.role.rawValue.padding(toLength: 15, withPad: " ", startingAt: 0)) \(t.name)  "
              + "(\(t.markers.count) Kenndateien)\(t.source.hint.map { " – \($0)" } ?? "")")
    }

case "login":
    let account = o.value("account") ?? "default"
    let tool = MetaTool(url: o.value("tool").map { URL(fileURLWithPath: $0) } ?? MetaTool.defaultURL)
    do {
        try tool.verify()
        print("Anmeldung bei Meta über ovr-platform-util. E-Mail, Passwort und gegebenenfalls der Code gehen direkt an "
              + "Metas Werkzeug; dieses Programm speichert davon nichts und zeigt den Token nicht an.\n")
        let token = try MetaLogin.run(tool: tool.url)
        // Erst prüfen, dann ablegen: ein Token, den Meta nicht annimmt, kommt nicht in den Schlüsselbund.
        _ = try await MetaClient(token: token).me()
        try TokenStore().write(token: token, account: account)
        print("\nAngemeldet. Der Token ist geprüft und liegt im Schlüsselbund (Konto '\(account)').")
    } catch { fail("\n\(error)") }

case "logout":
    let account = o.value("account") ?? "default"
    do {
        print(try TokenStore().delete(account: account)
              ? "Abgemeldet: Der Token für das Konto '\(account)' ist aus dem Schlüsselbund gelöscht."
              : "Für das Konto '\(account)' war kein Token hinterlegt.")
    } catch { fail("\(error)") }

case "account":
    let (_, _) = await signedIn(o)
    print("Token gültig (Konto '\(o.value("account") ?? "default")').")

case "owns":
    let r = recipe(o)
    guard let app = r.store.appId else { fail("\(MetaError.missingAppId)") }
    let (client, user) = await signedIn(o)
    do { print(try await client.ownsApp(appId: app, userId: user) ? "\(r.title): im Besitz." : "\(r.title): nicht im Besitz.") }
    catch { fail("\(error)") }

case "purchases":
    let r = recipe(o)
    guard let app = r.store.appId else { fail("\(MetaError.missingAppId)") }
    let (client, _) = await signedIn(o)
    do {
        let skus = try await client.purchases(appId: app)
        print("\(r.title): \(skus.count) bestätigte Käufe.")
        if let items = r.addons?.items {
            let owned = items.filter { skus.contains($0.sku) }
            print("Davon im Rezept zugeordnet: \(owned.count) Zusatzdateien.")
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
    print("\(r.title): \(plan.count) Dateien gebraucht, \(plan.filter { $0.action == .keep }.count) vorhanden, \(todo.count) zu laden"
          + (fromUser.isEmpty ? "" : ", \(fromUser.count) selbst bereitzustellen")
          + " (\(gigabytes(known)) bekannt\(todo.contains { $0.file.size == nil } ? ", Rest ohne Größenangabe" : "")).")
    if !fromUser.isEmpty {
        print("Selbst bereitzustellen (\(fromUser.count)): \(fromUser.prefix(4).map(\.file.name).joined(separator: ", "))\(fromUser.count > 4 ? ", …" : "")"
              + (fromUser.first?.file.source?.hint.map { " – \($0)" } ?? ""))
        print("  Danach mit 'avpplay adopt \(r.id) --from <Ordner>' übernehmen.")
    }
    let treesMissing = TreeStore(store: store).missing(recipe: r)
    if let trees = r.trees {
        print("Ordner: \(trees.count - treesMissing.count) von \(trees.count) im Bestand.")
        for t in treesMissing { print("  fehlt: \(t.name)\(t.source.hint.map { " – \($0)" } ?? "")") }
        if !treesMissing.isEmpty { print("  Danach mit 'avpplay adopt \(r.id) --from <Ordner>' übernehmen (je Ordner ein --from).") }
    }
    if command == "plan" {
        for p in todo.prefix(40) {
            let how: String
            if case .resume(let from) = p.action { how = "fortsetzen ab \(from)" } else { how = "laden" }
            print("  \(how): \(p.file.name)\(p.file.size.map { " (\($0) Bytes)" } ?? "")")
        }
        if todo.count > 40 { print("  … und \(todo.count - 40) weitere") }
        break
    }
    guard !todo.isEmpty else { break }
    // Vor dem ersten Abruf: gehört das Spiel dem Konto? Ein gelungener Abruf wäre dafür kein Beleg,
    // ein verweigerter eine unnötige Abfrage.
    if let app = r.store.appId, let client {
        do {
            guard try await client.ownsApp(appId: app, userId: try await client.me()) else {
                fail("\(r.title) ist nicht im Besitz dieses Kontos. Es wird nichts angefragt.")
            }
        } catch { fail("\(error)") }
    } else if usesStore {
        print("Hinweis: Im Rezept fehlt die Store-App-ID; der Besitz wird nicht vorab geprüft.")
    }
    let interval = Double(o.value("interval") ?? "") ?? 5
    // Ohne Meta-Dateien wird der Client nie benutzt; er bekommt dann auch keinen Token.
    let fetcher = Fetcher(client: client ?? MetaClient(token: "unbenutzt"), store: store, gate: RequestGate(minInterval: .seconds(interval)))
    do {
        let summary = try await fetcher.run(plan, recipe: r) { print("  " + $0) }
        print("Fertig: \(summary.downloaded) geladen (\(gigabytes(summary.bytes))), \(summary.kept) waren vorhanden.")
        for l in summary.learned { print("  neu erfasst: \(l.name)  \(l.size)  \(l.sha256)") }
    } catch {
        fail("Abgebrochen: \(error)\nEs wird nichts weiter angefragt.")
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
            if try Hashing.sha256(of: url) == expected.lowercased() { ok += 1 } else { bad += 1; print("  ABWEICHEND: \(f.name)") }
        } catch { fail("\(error)") }
    }
    print("\(r.title): \(ok) geprüft und in Ordnung, \(bad) abweichend, \(missing) Pflichtdateien fehlen, \(unknown) ohne Prüfsumme im Rezept.")
    let trees = TreeStore(store: store)
    for t in r.trees ?? [] {
        let dir = trees.url(for: t, in: r)
        let failing = TreeStore.failingMarkers(of: t, at: dir)
        if failing.isEmpty {
            let files = TreeStore.listing(of: dir)
            print("  Ordner \(t.name): \(t.markers.count) Kenndateien in Ordnung; \(files.count) Dateien, \(gigabytes(files.values.reduce(0, +))).")
        } else if FileManager.default.fileExists(atPath: dir.path) {
            bad += 1; print("  Ordner \(t.name): ABWEICHEND oder unvollständig (\(failing.prefix(3).joined(separator: ", "))).")
        } else {
            print("  Ordner \(t.name): fehlt im Bestand.")
        }
    }
    if bad > 0 { exit(2) }

case "adopt":
    let r = recipe(o)
    guard let sources = o.values["from"], !sources.isEmpty else { fail("Mindestens ein --from <Ordner> angeben.") }
    do {
        let result = try Adopter(store: contentStore(o)).adopt(recipe: r, from: sources.map { URL(fileURLWithPath: $0) })
        print("\(r.title): \(result.adopted.count) übernommen, \(result.alreadyPresent) waren schon im Bestand, "
              + "\(result.mismatched.count) passen nicht, \(result.unverifiable.count) ohne Prüfsumme im Rezept, "
              + "\(result.notFound.count) nicht gefunden.")
        for n in result.mismatched.prefix(8) { print("  passt nicht (andere Version?): \(n)") }
        if result.mismatched.count > 8 { print("  … und \(result.mismatched.count - 8) weitere") }
        if r.trees?.isEmpty == false {
            let t = try TreeStore(store: contentStore(o)).adopt(recipe: r, from: sources.map { URL(fileURLWithPath: $0) })
            print("Ordner: \(t.adopted.count) übernommen\(t.adopted.isEmpty ? "" : " (\(t.adopted.joined(separator: ", ")))"), "
                  + "\(t.alreadyPresent.count) waren schon im Bestand, \(t.notFound.count) nicht gefunden"
                  + "\(t.notFound.isEmpty ? "" : " (\(t.notFound.joined(separator: ", ")): kein angegebener Ordner trägt die Kenndateien dieser Version)").")
        }
    } catch { fail("\(error)") }

case "unpack":
    let r = recipe(o)
    guard let to = o.value("to") else { fail("Zielordner mit --to <Ordner> angeben.") }
    guard let apk = r.files.first(where: { $0.role == "apk" }) else { fail("Das Rezept nennt kein APK.") }
    let source = contentStore(o).url(for: apk, in: r)
    guard FileManager.default.fileExists(atPath: source.path) else { fail("Das APK liegt nicht im Bestand (erst 'avpplay fetch' oder 'avpplay adopt').") }
    do {
        let info = try ApkUnpacker().unpack(apk: source, to: URL(fileURLWithPath: to))
        print("\(r.title): \(info.files) Dateien entpackt; Paket \(info.package ?? "?"), Version \(info.versionName ?? "?") (\(info.versionCode ?? "?")).")
        if info.package != r.package || info.versionCode != String(r.versionCode) {
            fail("Das APK passt nicht zum Rezept (erwartet \(r.package), Code \(r.versionCode)).")
        }
    } catch { fail("\(error)") }

case "icon":
    let r = recipe(o)
    guard let to = o.value("to") else { fail("Zielordner mit --to <Ordner> angeben.") }
    do {
        // dieselbe Auswahl wie bei der Installation
        guard let chosen = Toolchain.chooseIcon(recipe: r, store: contentStore(o)) else {
            print("\(r.title): kein Icon verfügbar (das APK enthält höchstens den Platzhalter der Engine)."); break
        }
        try AppIcon.writeImageStack(chosen.source, to: URL(fileURLWithPath: to))
        print("\(r.title): \(chosen.origin) (\(chosen.source.summary)) nach \(to) geschrieben.")
        if o.flags.contains("fingerprint") { print("  Fingerabdruck: \(AppIcon.fingerprint(chosen.source))") }
    } catch { fail("\(error)") }

case "devices":
    do {
        let all = try DeviceControl().devices()
        if all.isEmpty { print("Keine Vision Pro bekannt.") }
        for d in all {
            print("\(d.name)  visionOS \(d.osVersion)  \(d.udid)  \(d.paired ? "gekoppelt" : "nicht gekoppelt"), "
                  + "\(d.reachable ? "erreichbar" : "nicht erreichbar"), Entwicklermodus \(d.developerMode ? "an" : "aus")")
        }
    } catch { fail("\(error)") }

case "install", "stage":
    // Ohne Download: was im Bestand fehlt, ist ein Fehler. Der ganze Weg samt Laden ist 'avpplay job start'.
    let r = recipe(o)
    if command == "install", o.value("team") == nil { fail("Für 'install' die Apple-Team-ID mit --team angeben.") }
    let installer = Installer(recipe: r, request: installRequest(o), store: contentStore(o)) { print($0) }
    do {
        for step in (command == "install" ? [.account, .build, .stage, .unlock] : [.account, .stage, .unlock]) as [InstallStep] {
            try await installer.perform(step)
        }
        print("Fertig: \(r.title) ist auf dem Gerät bereit.")
    } catch { fail("\(error)") }

case "toolchains":
    let all = toolchainPackager(o).installed()
    if all.isEmpty { print("Kein Toolchain-Paket installiert.") }
    for t in all {
        guard let m = t.manifest else { continue }
        print("Version \(m.version) (\(m.commit)), erstellt \(ISO8601DateFormatter().string(from: m.created))  \(t.root.path)")
    }

case "toolchain":
    guard o.positional.count >= 2 else { fail("Aufruf: avpplay toolchain pack --from <Fork> --to <Ordner> | avpplay toolchain install <Archiv> | avpplay toolchain prune [--keep <Anzahl>]") }
    switch o.positional[1] {
    case "pack":
        guard let from = o.value("from"), let to = o.value("to") else { fail("Für 'pack' --from <Fork-Arbeitsverzeichnis> und --to <Ordner> angeben.") }
        do {
            let (archive, m) = try ToolchainPackager.pack(checkout: URL(fileURLWithPath: from), to: URL(fileURLWithPath: to))
            print("Paket Version \(m.version) (\(m.commit)): \(archive.path)")
            print("  \(gigabytes(m.size ?? 0)), SHA-256 \(m.sha256 ?? "?")")
            print("  Beschreibung: \(ToolchainPackager.sidecar(for: archive).lastPathComponent) – gehört zum Archiv.")
        } catch { fail("\(error)") }
    case "install":
        guard o.positional.count >= 3 else { fail("Archiv angeben: avpplay toolchain install <Archiv>") }
        do {
            let t = try toolchainPackager(o).install(archive: URL(fileURLWithPath: o.positional[2]))
            print("Toolchain Version \(t.version()) (\(t.commit())) installiert: \(t.root.path)")
        } catch { fail("\(error)") }
    case "prune":
        // Alte Pakete entfernen; was ein offener Auftrag festhält, bleibt.
        do {
            let open = Set(jobStore(o).all().filter { [.waiting, .running, .failed].contains($0.state) }.map(\.toolchainCommit))
            let keep = o.value("keep").flatMap { Int($0) } ?? 1
            let removed = try toolchainPackager(o).prune(keep: keep, protecting: open)
            if removed.isEmpty { print("Nichts zu entfernen.") }
            for m in removed { print("Entfernt: Version \(m.version) (\(m.commit))") }
        } catch { fail("\(error)") }
    default:
        fail("Unbekannter Toolchain-Befehl '\(o.positional[1])'.")
    }

case "status":
    // Was der Mac weiß (Bestand) neben dem, was das Gerät meldet (installierte App und ihr Stempel).
    do {
        let store = contentStore(o)
        let control = DeviceControl()
        let device = try? control.pick(udid: o.value("device"))
        let apps = (try? device.map { try control.apps(device: $0) }) ?? nil
        if let device { print("Gerät: \(device.name) (visionOS \(device.osVersion))") }
        else { print("Kein erreichbares Gerät – es wird nur der Bestand gezeigt.") }
        let toolchain = try? Toolchain(root: URL(fileURLWithPath: installRequest(o).toolchain))
        if let toolchain { print("Toolchain: Version \(toolchain.version()) (\(toolchain.commit()))") }
        for r in try RecipeStore(directory: recipesDirectory(o)).loadAll() {
            let st = GameStatus.of(recipe: r, store: store, apps: apps, toolchainVersion: toolchain?.version())
            var bestand = "\(st.filesPresent)/\(st.filesRequired) Dateien"
            if st.treesRequired > 0 { bestand += ", \(st.treesPresent)/\(st.treesRequired) Ordner" }
            let geraet: String
            switch st.onDevice {
            case .unknown: geraet = "–"
            case .notInstalled: geraet = "nicht installiert"
            case .current(let stamp): geraet = "installiert, \(stamp)"
            case .olderToolchain(let stamp): geraet = "installiert, \(stamp) – mit älterer Toolchain gebaut"
            case .unstamped(let stamp): geraet = "installiert, \(stamp) – ohne Stempel dieses Werkzeugs"
            }
            print("\(r.id.padding(toLength: 13, withPad: " ", startingAt: 0)) \(r.title) \(r.versionName)")
            print("              Bestand: \(bestand)   Gerät: \(geraet)")
        }
    } catch { fail("\(error)") }

case "jobs":
    let jobs = jobStore(o).all()
    if jobs.isEmpty { print("Keine Aufträge.") }
    for j in jobs { print(describe(j)) }

case "job":
    guard o.positional.count >= 3 else { fail("Aufruf: avpplay job start <Rezept> --team <Team-ID> | avpplay job resume|show|cancel <Auftrag>") }
    let jobs = jobStore(o)
    let runner = JobRunner(store: jobs)
    func run(_ job: Job) async {
        let installer = Installer(recipe: job.recipe, request: job.request, store: contentStore(o)) { print("  " + $0) }
        do {
            let now = (try? Toolchain(root: URL(fileURLWithPath: job.request.toolchain)).commit()) ?? "unbekannt"
            let done = try await runner.run(job, currentToolchain: now, log: { print($0) }) { step, _ in try await installer.perform(step) }
            print("Auftrag \(done.id) abgeschlossen: \(done.recipe.title) ist auf dem Gerät bereit.")
        } catch let error as JobError {
            fail("\(error)")          // hier gibt es nichts fortzusetzen
        } catch {
            fail("\(error)\nAuftrag \(job.id) angehalten. Fortsetzen mit: avpplay job resume \(job.id)")
        }
    }
    switch o.positional[1] {
    case "start":
        if o.value("team") == nil { fail("Für einen Auftrag die Apple-Team-ID mit --team angeben.") }
        let r: Recipe
        do { r = try RecipeStore(directory: recipesDirectory(o)).load(id: o.positional[2]) } catch { fail("\(error)") }
        let request = installRequest(o)
        do {
            // Eingefroren wird der Stand, mit dem der Auftrag beginnt.
            let commit = try Toolchain(root: URL(fileURLWithPath: request.toolchain)).commit()
            let job = Job(recipe: r, request: request, toolchainCommit: commit)
            try jobs.save(job)
            print("Auftrag \(job.id) angelegt (\(r.title), Toolchain \(commit)).")
            await run(job)
        } catch { fail("\(error)") }
    case "resume":
        do { await run(try jobs.load(o.positional[2])) } catch { fail("\(error)") }
    case "show":
        do {
            let j = try jobs.load(o.positional[2])
            print(describe(j))
            for step in j.steps {
                let mark = j.completed.contains(step) ? "erledigt" : (j.current == step ? (j.state == .failed ? "fehlgeschlagen" : "hier unterbrochen") : "offen")
                print("  \(step.title.padding(toLength: 28, withPad: " ", startingAt: 0)) \(mark)")
            }
            if let f = j.failure { print("  Grund: \(f)") }
        } catch { fail("\(error)") }
    case "cancel":
        do { print("Auftrag \(try runner.cancel(o.positional[2]).id) abgebrochen. Geladene Dateien und Daten auf dem Gerät bleiben erhalten.") }
        catch { fail("\(error)") }
    default:
        fail("Unbekannter Auftragsbefehl '\(o.positional[1])'.")
    }

default:
    fail("Unbekannter Befehl '\(command)'.\n\n" + usage)
}

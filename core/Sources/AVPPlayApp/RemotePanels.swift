import AVPPlayCore
import SwiftUI

// Die Seiten, die die Fernbedienung zeigt, ohne sie selbst zu kennen: die Seite eines Spiels, eines Auftrags, die
// Einrichtung und die Einstellungen. Der Mac beschreibt sie als Abschnitte mit Texten, Schaltern, Auswahlen und
// Knöpfen (`RemotePanel`) und führt aus, was dort gewählt wird – mit denselben Aufrufen und Prüfungen wie die
// Knöpfe hier. Die Texte sind dieselben wie auf dem Mac, wo es sie als Funktion gibt.

/// Was eine Seite zum Bauen braucht und nicht bei jedem Mal neu lesen soll.
@MainActor
final class RemotePanelCache {
    /// Die wählbaren Toolchains eines Spiels; neu bestimmt, wenn sich die Wahl oder die Pakete ändern.
    var toolchains: [String: (key: String, options: ToolchainOptions)] = [:]
    /// Der Verlauf eines abgeschlossenen Auftrags; neu gelesen, wenn die Datei wächst.
    var logs: [String: (size: Int64, tail: LogTail)] = [:]
}

private typealias Item = RemoteItem

extension AppModel {
    // MARK: Seiten

    func remotePanel(_ id: String, cache: RemotePanelCache) -> RemotePanel? {
        if id == "setup" { return RemotePanel(id: id, sections: remoteSetupSections()) }
        if id == "settings" { return RemotePanel(id: id, sections: remoteSettingsSections()) }
        if id.hasPrefix("game:"), let game = allGames.first(where: { $0.id == id.dropFirst(5) }) {
            return RemotePanel(id: id, sections: remoteGameSections(game, cache: cache))
        }
        if id.hasPrefix("job:"), let job = jobs.first(where: { $0.id == id.dropFirst(4) }) {
            return RemotePanel(id: id, sections: remoteJobSections(job, cache: cache))
        }
        return nil
    }

    /// Wird eine Seite geöffnet: bei einem Spiel, was das Öffnen seiner Seite hier auch tut.
    func remotePanelOpened(_ id: String) {
        guard id.hasPrefix("game:"), let game = allGames.first(where: { $0.id == id.dropFirst(5) }) else { return }
        prepare(game)
        checkStoreVersions(only: game)
        purchaseOnOpen(game)
    }

    // MARK: Spiel

    private func remoteGameSections(_ game: Game, cache: RemotePanelCache) -> [RemoteSection] {
        var sections: [RemoteSection] = []
        let busy = isBusy(game.id)

        // Favorit und eigene Filter
        var mine = [Item(id: "favourite", kind: .toggle, title: L("Favourite", "Favorit"), on: isFavourite(game))]
        for filter in customFilters {
            mine.append(Item(id: "filter:\(filter.id)", kind: .toggle, title: filter.name, on: filter.games.contains(game.id)))
        }
        sections.append(RemoteSection(id: "mine", title: customFilters.isEmpty ? nil : L("Favourite and filters", "Favorit und Filter"),
                                      footer: customFilters.isEmpty ? L("Filters of your own are created on the Mac under “Filters”.",
                                                                        "Eigene Filter legst du auf dem Mac unter „Filter“ an.") : nil,
                                      items: mine))

        // Kaufquelle
        if game.sources.count > 1, let current = game.recipe.source {
            var items = [Item(id: "source", kind: .choice, title: L("Purchased from", "Gekauft bei"), value: current.rawValue,
                              choices: game.sources.map { RemoteChoice(id: $0.rawValue, title: $0 == .steam ? "Steam" : L("Meta Store", "Meta-Store")) },
                              enabled: !busy && !steamBusy.contains(game.id))]
            if current == .steam, !steamSignedIn {
                items.append(Item(id: "steam-signin", kind: .text, title: "",
                                  detail: L("Sign in to Steam under “Setup” on the Mac – then the app can check your purchase and download the game.",
                                            "Melde dich auf dem Mac unter „Einrichtung“ bei Steam an – dann kann die App deinen Kauf prüfen und das Spiel laden."),
                                  style: .warning))
            }
            if game.otherSourceInstalled { items.append(Item(id: "other-source", kind: .text, title: "", detail: otherSourceText(game), style: .warning)) }
            sections.append(RemoteSection(id: "source", title: L("Purchase source", "Kaufquelle"), items: items))
        }

        // Fassung
        let newer = storeUpdate(for: game)
        let versions = versions(for: game)
        if newer != nil || game.testedVersion != nil || versions.count > 1 {
            var items: [Item] = []
            if versions.count > 1 {
                let verifiedTitle = L("Verified by the project", "Vom Projekt geprüft")
                let othersTitle = versions.contains(where: { $0.kind == .verified })
                    ? L("Other versions from the Meta Store – not tested", "Weitere Fassungen aus dem Meta-Store – nicht getestet")
                    : L("From the Meta Store", "Aus dem Meta-Store")
                items.append(Item(id: "version", kind: .choice, title: L("Version", "Fassung"), value: "\(game.recipe.versionCode)",
                                  choices: versions.map { RemoteChoice(id: "\($0.versionCode)", title: StoreVersionBox.label($0),
                                                                        section: $0.kind == .verified ? verifiedTitle : othersTitle) },
                                  enabled: !preparing.contains(game.id)))
            }
            if let tested = game.testedVersion {
                items.append(Item(id: "untested-version", kind: .text,
                                  title: L("Version \(game.recipe.versionName) from the Meta Store – not tested with AVP Play",
                                           "Fassung \(game.recipe.versionName) aus dem Meta-Store – mit AVP Play nicht getestet"),
                                  detail: L("The project tested version \(tested). This one may not start, and add-on content may stay locked.",
                                            "Geprüft hat das Projekt Fassung \(tested). Diese startet vielleicht nicht, und Zusatzinhalte bleiben vielleicht gesperrt."),
                                  style: .warning))
                items.append(Item(id: "useTested", kind: .action, title: L("Go Back to Tested Version \(tested)", "Zurück zur geprüften Fassung \(tested)"),
                                  enabled: !preparing.contains(game.id)))
                if let newer {
                    items.append(Item(id: "useNewest", kind: .action, title: L("Switch to \(newer.version)", "Auf \(newer.version) wechseln"),
                                      enabled: !preparing.contains(game.id)))
                }
            } else if let newer {
                items.append(Item(id: "newer", kind: .text, title: L("The Meta Store has a newer version: \(newer.version)", "Im Meta-Store gibt es eine neuere Fassung: \(newer.version)"),
                                  detail: L("AVP Play installs version \(game.recipe.versionName), the one the project tested. The newest one has not been tested: it may not start, and add-on content may stay locked. You can come back at any time.",
                                            "AVP Play installiert Fassung \(game.recipe.versionName), die das Projekt geprüft hat. Die neueste ist nicht getestet: Sie startet vielleicht nicht, und Zusatzinhalte bleiben vielleicht gesperrt. Zurück geht es jederzeit.")))
                items.append(Item(id: "useNewest", kind: .action, title: L("Use Newest Version \(newer.version) (Untested)", "Neueste Fassung \(newer.version) verwenden (ungetestet)"),
                                  enabled: !preparing.contains(game.id)))
            }
            if preparing.contains(game.id), !game.draft {
                items.append(Item(id: "preparing", kind: .progress, title: prepareNote[game.id] ?? L("Looking up …", "Wird nachgeschlagen …")))
            } else if !game.draft, let note = prepareNote[game.id] {
                items.append(Item(id: "prepare-note", kind: .text, title: "", detail: note, style: .secondary))
            }
            sections.append(RemoteSection(id: "version", title: L("Version", "Fassung"), items: items))
        }

        // Ungetestet
        if game.draft {
            var items: [Item] = []
            let reports: (works: Int, problems: Int, fails: Int)? = game.recipe.source == .steam
                ? game.steamCatalog.map { ($0.works, $0.problems, $0.fails) } : game.catalog.map { ($0.works, $0.problems, $0.fails) }
            if let c = reports, c.works + c.problems + c.fails > 0 {
                items.append(Item(id: "reports", kind: .text, title: "",
                                  detail: L("Reports from users: \(c.works) say it works, \(c.problems) report problems, \(c.fails) say it does not start.",
                                            "Meldungen von Nutzern: \(c.works) sagen, es läuft, \(c.problems) melden Probleme, \(c.fails) sagen, es startet nicht.")))
            }
            if let note = game.recipe.source == .steam ? game.steamCatalog?.note : game.catalog?.note {
                items.append(Item(id: "catalog-note", kind: .text, title: "", detail: note))
            }
            if preparing.contains(game.id) {
                items.append(Item(id: "preparing", kind: .progress, title: prepareNote[game.id] ?? L("Looking up …", "Wird nachgeschlagen …")))
            } else if let note = prepareNote[game.id] {
                items.append(Item(id: "prepare-note", kind: .text, title: "", detail: note, style: .secondary))
            }
            sections.append(RemoteSection(id: "untested", title: game.incompatible ? L("Reported not to work", "Läuft nach den Meldungen nicht")
                                                                 : game.trust == .community ? L("Users report that it works", "Nutzer melden, dass es läuft")
                                                                 : L("Nobody has tested this game yet", "Noch nicht getestet"),
                                          footer: L("Each verified game needed its own adjustments, so an untested one may well not start. Say afterwards how it went.",
                                                    "Jedes geprüfte Spiel brauchte eigene Anpassungen – ein ungetestetes startet also womöglich nicht. Sag danach, wie es lief."),
                                          items: items))
        }

        // Auf diesem Mac
        var mac: [Item] = []
        if game.status.filesRequired > 0 {
            mac.append(Item(id: "files", kind: .fact, title: L("Files", "Dateien"),
                            value: L("\(game.status.filesPresent) of \(game.status.filesRequired) present", "\(game.status.filesPresent) von \(game.status.filesRequired) vorhanden")))
        }
        if hasDownloads(game) {
            mac.append(Item(id: "to-download", kind: .fact, title: L("Still to download", "Noch zu laden"), value: downloadSizeText(game)))
        } else if game.status.stockComplete, game.prepared {
            mac.append(Item(id: "to-download", kind: .fact, title: "Download", value: L("nothing left to download", "nichts mehr zu laden")))
        }
        if game.storeBytes > 0 {
            mac.append(Item(id: "space", kind: .fact, title: L("Space used", "Belegter Platz"), value: Installer.gigabytes(game.storeBytes)))
            mac.append(Item(id: "removeFiles", kind: .action, title: L("Remove from the Mac", "Vom Mac entfernen"), enabled: !busy, style: .destructive,
                            confirm: L("Remove the files of \(game.recipe.title) from the Mac? ", "Die Dateien von \(game.recipe.title) vom Mac entfernen? ") + removeWarning(game)))
        }
        if !mac.isEmpty { sections.append(RemoteSection(id: "mac", title: L("On the Mac", "Auf dem Mac"), items: mac)) }

        // Auf der Vision Pro
        var device = [Item(id: "device", kind: .text, title: "", detail: deviceText(game))]
        if let signing = signingText(game) {
            device.append(Item(id: "signing", kind: .text, title: "", detail: signing.text, style: signing.urgent ? .warning : .secondary))
        }
        sections.append(RemoteSection(id: "device", title: L("On the Vision Pro", "Auf der Vision Pro"), items: device))

        // Toolchain
        if game.prepared, toolchainText != nil { sections.append(remoteToolchainSection(game, cache: cache)) }

        // Spielstände
        if hasSaves(game), game.installed || saveSnapshots[game.id] != nil {
            let snapshot = saveSnapshots[game.id]
            let savesBusy = savesBusy.contains(game.id)
            var items: [Item] = []
            if let snapshot {
                let when = snapshot.taken.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.locale))
                items.append(Item(id: "saves", kind: .text, title: "",
                                  detail: snapshot.files.count == 1
                                      ? L("On the Mac: one file (\(StoredGameRow.size(snapshot.bytes))), fetched \(when).", "Auf dem Mac: eine Datei (\(StoredGameRow.size(snapshot.bytes))), geholt am \(when).")
                                      : L("On the Mac: \(snapshot.files.count) files (\(StoredGameRow.size(snapshot.bytes))), fetched \(when).", "Auf dem Mac: \(snapshot.files.count) Dateien (\(StoredGameRow.size(snapshot.bytes))), geholt am \(when).")))
            } else {
                items.append(Item(id: "saves", kind: .text, title: "", detail: L("None on the Mac yet.", "Noch keine auf dem Mac."), style: .secondary))
            }
            if let note = savesNote[game.id] { items.append(Item(id: "saves-note", kind: .text, title: "", detail: note, style: .secondary)) }
            if savesBusy { items.append(Item(id: "saves-busy", kind: .progress, title: L("Working on it …", "In Arbeit …"))) }
            items.append(Item(id: "fetchSaves", kind: .action, title: L("Fetch Now", "Jetzt holen"), enabled: !savesBusy && game.installed))
            if let snapshot {
                let blocker = restoreBlocker(for: game)
                let when = snapshot.taken.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.locale))
                items.append(Item(id: "restoreSaves", kind: .action, title: L("Put Back on the Vision Pro", "Auf die Vision Pro zurückspielen"),
                                  detail: blocker, enabled: !savesBusy && blocker == nil, style: .destructive,
                                  confirm: L("The copy from \(when) replaces what is on the Vision Pro now. What is there now is copied to the Mac first.",
                                             "Die Kopie vom \(when) ersetzt, was jetzt auf der Vision Pro liegt. Was dort jetzt liegt, wird vorher auf den Mac kopiert.")))
                items.append(Item(id: "restoreOnInstall", kind: .toggle,
                                  title: L("When this game is installed and has no saved games on the Vision Pro, put these back",
                                           "Wenn dieses Spiel installiert wird und auf der Vision Pro keine Spielstände hat, diese zurückspielen"),
                                  on: options(for: game).restoreSaves ?? true))
            }
            sections.append(RemoteSection(id: "saves", title: L("Saved Games", "Spielstände"), items: items))
        }

        // Wählbare Inhalte
        let languages = GameDetail.languageFiles(of: game.recipe)
        let extras = AppModel.extras(of: game.recipe)
        if !languages.isEmpty || game.recipe.addons != nil || !extras.isEmpty {
            let chosen = options(for: game)
            var items: [Item] = []
            for entry in languages {
                items.append(Item(id: "locale:\(entry.locale)", kind: .toggle,
                                  title: GameDetail.languageName(entry.locale) + (entry.bytes.map { " · \(Installer.gigabytes($0))" } ?? ""),
                                  on: chosen.locales.contains(entry.locale)))
            }
            for file in extras {
                let on = chosen.optionalNames.contains(file.name)
                let here = inLibrary(file, of: game)
                items.append(Item(id: "extra:\(file.name)", kind: .toggle,
                                  title: (file.title?.text ?? file.name) + (file.size.map { " · \(Installer.gigabytes($0))" } ?? ""),
                                  detail: on ? (here ? L("On the Mac.", "Liegt auf dem Mac.") : L("Not on the Mac yet – choosing it on the Mac fetches it.", "Noch nicht auf dem Mac – auf dem Mac auswählen holt sie."))
                                             : (here ? L("Still on the Mac.", "Liegt noch auf dem Mac.") : file.source?.hint?.text),
                                  on: on))
            }
            if !extras.isEmpty, game.installed, case .current = game.status.onDevice {
                let blocker = extrasBlocker(for: game) ?? (missingExtras(for: game).isEmpty ? nil : L("Something chosen is not on the Mac yet.", "Etwas Gewähltes liegt noch nicht auf dem Mac."))
                items.append(Item(id: "syncExtras", kind: .action, title: L("Bring the Vision Pro up to Date", "Vision Pro auf den Stand bringen"),
                                  detail: blocker ?? L("Copies what is chosen and takes off what is not – without building the game again.",
                                                       "Kopiert, was gewählt ist, und nimmt weg, was nicht gewählt ist – ohne das Spiel neu zu bauen."),
                                  enabled: blocker == nil))
            }
            if game.recipe.addons != nil {
                items.append(Item(id: "addons", kind: .toggle, title: L("Add-on content you have purchased", "Zusatzinhalte, die du gekauft hast"),
                                  detail: L("Only what \(AppModel.name(game.recipe.source)) confirms as purchased is downloaded and unlocked.",
                                            "Geladen und freigeschaltet wird nur, was \(AppModel.name(game.recipe.source)) als gekauft bestätigt."),
                                  on: chosen.addons))
                if game.installed {
                    let blocker = syncBlocker(for: game)
                    items.append(Item(id: "syncAddons", kind: .action, title: L("Sync DLCs", "DLCs abgleichen"),
                                      detail: blocker ?? L("Asks \(AppModel.name(game.recipe.source)) again what you have purchased, downloads what is missing and adds it – without building the game again.",
                                                           "Fragt \(AppModel.name(game.recipe.source)) neu, was du gekauft hast, lädt das Fehlende und legt es dazu – ohne das Spiel neu zu bauen."),
                                      enabled: blocker == nil))
                }
            }
            sections.append(RemoteSection(id: "content", title: L("Optional Content", "Wählbare Inhalte"), items: items))
        }

        // Rückmeldung
        if game.installed, canSendFeedback(game) {
            var items: [Item] = []
            if game.status.builtWith?.modified == true {
                items.append(Item(id: "feedback-modified", kind: .text, title: "",
                                  detail: L("This build comes from a modified toolchain, so no report is sent for it.",
                                            "Dieser Bau stammt aus einer modifizierten Toolchain; für ihn wird deshalb keine Rückmeldung gesendet."), style: .secondary))
            } else if let sent = feedbackSent(game) {
                items.append(Item(id: "feedback-sent", kind: .text, title: "",
                                  detail: L("You reported: \(FeedbackBox.label(sent)). Thank you.", "Du hast gemeldet: \(FeedbackBox.label(sent)). Danke."), style: .success))
            } else {
                let prompt = L("A sentence about it, if you like", "Ein Satz dazu, wenn du magst")
                for result in CatalogFeedback.Result.allCases {
                    items.append(Item(id: "feedback:\(result.rawValue)", kind: .action, title: FeedbackBox.label(result.rawValue).capitalizedFirst,
                                      prompt: prompt))
                }
            }
            sections.append(RemoteSection(id: "feedback", title: L("How does it run?", "Wie läuft es?"),
                                          footer: L("The label of a game follows these reports. Sent are the game, its build, the versions of app and toolchain, and your answer.",
                                                    "Das Kennzeichen eines Spiels richtet sich nach diesen Meldungen. Gesendet werden das Spiel, sein Build, die Versionen von App und Toolchain und deine Antwort."),
                                          items: items))
        }

        // Gut zu wissen
        var know: [Item] = []
        let ownership = OwnershipLabel.describe(owned: owned(game), checking: checkingPurchase.contains(game.id) || checkingOwnership, source: game.recipe.source)
        know.append(Item(id: "owned", kind: .fact, title: L("Ownership", "Besitz"), value: ownership.text))
        if game.fromStore, OwnershipCache.key(for: game.recipe) != nil {
            let checking = checkingPurchase.contains(game.id)
            know.append(Item(id: "checkPurchase", kind: .action, title: checking ? L("Checking …", "Wird geprüft …") : L("Check Purchase", "Kauf prüfen"),
                             detail: purchaseNote[game.id], enabled: !checking))
        }
        if let app = game.recipe.store.appId {
            know.append(Item(id: "store", kind: .link, title: L("View in the Meta Store", "Im Meta-Store ansehen"),
                             value: "https://www.meta.com/experiences/\(app)/", shareable: true))
        } else if game.recipe.source == .steam, let app = game.recipe.store.steamAppId {
            know.append(Item(id: "store", kind: .link, title: L("View on Steam", "Bei Steam ansehen"),
                             value: "https://store.steampowered.com/app/\(app)/", shareable: true))
        }
        know.append(Item(id: "playability", kind: .text, title: "", detail: playabilityText(game)))
        if let app = game.recipe.catalogAppId, let catalogue = horizonPlus?.catalogue(of: app) {
            know.append(Item(id: "horizon", kind: .text, title: "",
                             detail: catalogue == .indie
                                ? L("In the Horizon+ Indie Catalog: with a Meta Horizon+ subscription it can be downloaded without buying it.",
                                    "Im Horizon+-Indie-Katalog: Mit einem Meta-Horizon+-Abo lässt es sich ohne Kauf laden.")
                                : L("In the Horizon+ Games Catalog: with a Meta Horizon+ subscription it can be downloaded without buying it.",
                                    "Im Horizon+-Spielekatalog: Mit einem Meta-Horizon+-Abo lässt es sich ohne Kauf laden.")))
        }
        for (i, note) in (game.recipe.status.notes ?? []).enumerated() {
            know.append(Item(id: "note-\(i)", kind: .text, title: "", detail: "• " + note.text, style: .secondary))
        }
        sections.append(RemoteSection(id: "know", title: L("Good to Know", "Gut zu wissen"), items: know))
        return sections
    }

    private func toolchainOptions(_ game: Game, cache: RemotePanelCache) -> ToolchainOptions {
        let pin = toolchainChoices.games[game.id]
        let key = "\(pin.map(ToolchainOption.key(for:)) ?? "") \(toolchainText ?? "") \(releasedToolchains?.count ?? -1) \(toolchainArriving[game.id]?.commit ?? "")"
        if let known = cache.toolchains[game.id], known.key == key { return known.options }
        let options = ToolchainOptions.make(recipe: game.recipe, pin: pin, packager: paths.packager, newest: paths.toolchain(), released: releasedToolchains)
        cache.toolchains[game.id] = (key, options)
        return options
    }

    private func remoteToolchainSection(_ game: Game, cache: RemotePanelCache) -> RemoteSection {
        let options = toolchainOptions(game, cache: cache)
        let pin = toolchainChoices.games[game.id]
        let newest = options.newest.map { String($0.version) } ?? "?"
        var items: [Item] = []
        if let pin {
            items.append(Item(id: "summary", kind: .text, title: "",
                              detail: !pin.modified && pin.commit == options.newest?.commit
                                ? L("This game stays on toolchain \(pin.name) – the newest right now.", "Dieses Spiel bleibt bei Toolchain \(pin.name) – im Moment die neueste.")
                                : L("This game is built with toolchain \(pin.name), not with the newest (\(newest)).", "Dieses Spiel wird mit Toolchain \(pin.name) gebaut, nicht mit der neuesten (\(newest))."),
                              style: .warning))
        } else {
            items.append(Item(id: "summary", kind: .text, title: "",
                              detail: L("This game is built with the newest toolchain (\(newest)).", "Dieses Spiel wird mit der neuesten Toolchain gebaut (\(newest)).")))
        }
        let all = ToolchainBox.all(options)
        let onMac = L("On the Mac", "Auf dem Mac"), copies = L("Modified working copies", "Bearbeitete Arbeitskopien")
        let github = L("Older ones from GitHub – downloaded when chosen", "Ältere von GitHub – geladen, wenn gewählt")
        let choices = all.map { o -> RemoteChoice in
            let section: String?
            switch o.kind {
            case .newest, .missing: section = nil
            case .installed: section = onMac
            case .copy: section = copies
            case .released: section = github
            }
            return RemoteChoice(id: o.id, title: ToolchainBox.label(o, in: options), section: section)
        }
        let selected = pin.map { options.missing != nil ? ToolchainOption.missingId : ToolchainOption.key(for: $0) } ?? ToolchainOption.newestId
        items.append(Item(id: "toolchain", kind: .choice, title: L("Build with", "Bauen mit"), value: selected, choices: choices,
                          enabled: toolchainArriving[game.id] == nil))
        if let arriving = toolchainArriving[game.id] {
            items.append(Item(id: "arriving", kind: .progress, title: L("Downloading toolchain \(arriving.version) from GitHub and checking it …",
                                                                     "Toolchain \(arriving.version) wird von GitHub geladen und geprüft …")))
        }
        if let note = toolchainNote[game.id] { items.append(Item(id: "toolchain-note", kind: .text, title: "", detail: note, style: .warning)) }
        if releasedToolchainsLoading {
            items.append(Item(id: "released-loading", kind: .progress, title: L("Asking GitHub …", "GitHub wird gefragt …")))
        } else if releasedToolchains == nil {
            items.append(Item(id: "loadReleased", kind: .action, title: L("Show Older Toolchains from GitHub", "Ältere Toolchains von GitHub zeigen")))
        }
        return RemoteSection(id: "toolchain", title: "Toolchain",
                             footer: L("Which toolchain builds this game when it is installed, updated or its signature is renewed. A change does nothing on the Vision Pro until you install; saved games and data are kept.",
                                       "Welche Toolchain dieses Spiel baut – beim Installieren, Aktualisieren und Erneuern der Signatur. Ein Wechsel ändert nichts auf der Vision Pro, bis du installierst; Spielstände und Daten bleiben."),
                             items: items)
    }

    // MARK: Auftrag

    private func remoteJobSections(_ job: Job, cache: RemotePanelCache) -> [RemoteSection] {
        let phase = phase(of: job)
        var sections: [RemoteSection] = []
        var head: [Item] = [Item(id: "phase", kind: .fact, title: L("State", "Stand"), value: phase.text)]
        head.append(Item(id: "created", kind: .fact, title: L("Created", "Angelegt"),
                         value: job.created.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.locale))))
        if phase.canResume, job.failureKind?.resumable ?? true {
            head.append(Item(id: "resume", kind: .action, title: L("Resume", "Fortsetzen"), style: .prominent))
        }
        if phase.canCancel {
            head.append(Item(id: "cancel", kind: .action, title: L("Cancel", "Abbrechen"), style: .destructive,
                             confirm: phase == .running
                                ? L("Cancel this job? The current step finishes first; downloaded files and everything on the Vision Pro stay.",
                                    "Diesen Auftrag abbrechen? Der laufende Schritt wird noch beendet; geladene Dateien und alles auf der Vision Pro bleiben.")
                                : L("Cancel this job? Downloaded files and everything on the Vision Pro stay.",
                                    "Diesen Auftrag abbrechen? Geladene Dateien und alles auf der Vision Pro bleiben.")))
        }
        sections.append(RemoteSection(id: "head", title: nil, items: head))

        if phase == .stopped, let failure = job.failure {
            sections.append(RemoteSection(id: "failure", title: L("What Went Wrong", "Woran es lag"), items: [
                Item(id: "failure", kind: .text, title: "", detail: failure, style: .warning),
                Item(id: "advice", kind: .text, title: "", detail: jobAdvice(job.failureKind ?? .other)),
            ]))
        } else if phase == .interrupted {
            sections.append(RemoteSection(id: "failure", title: nil, items: [
                Item(id: "interrupted", kind: .text, title: "",
                     detail: L("This job was interrupted, for example because the app was quit. “Resume” continues where it stopped.",
                               "Dieser Auftrag wurde unterbrochen, zum Beispiel weil das Programm beendet wurde. Mit „Fortsetzen“ geht es an derselben Stelle weiter."),
                     style: .secondary),
            ]))
        }

        let steps = job.steps.map { step -> Item in
            let state: String
            if job.completed.contains(step) { state = "ok" }
            else if job.current == step, phase == .running { state = "checking" }
            else if job.current == step, phase == .stopped { state = "warning" }
            else { state = "missing" }
            var detail: String?
            if job.current == step, phase == .running {
                let progress = remoteJob(job)
                detail = progress.progressText
            }
            return Item(id: "step:\(step.rawValue)", kind: .check, title: step.title, detail: detail, state: state)
        }
        sections.append(RemoteSection(id: "steps", title: L("Steps", "Schritte"), items: steps))

        // Der Verlauf: der eines laufenden Auftrags liegt im Speicher, sonst wird die Datei nur neu gelesen, wenn
        // sie gewachsen ist.
        let tail: LogTail
        if let live = logs[job.id] {
            tail = live
        } else {
            let size = ((try? FileManager.default.attributesOfItem(atPath: paths.logURL(job: job.id).path))?[.size] as? NSNumber)?.int64Value ?? 0
            if let known = cache.logs[job.id], known.size == size { tail = known.tail } else {
                tail = logTail(for: job.id)
                cache.logs[job.id] = (size, tail)
            }
        }
        let shown = tail.lines.suffix(200)
        sections.append(RemoteSection(id: "log", title: L("Log", "Verlauf"),
                                      footer: tail.total > shown.count ? L("The last \(shown.count) of \(tail.total) lines.", "Die letzten \(shown.count) von \(tail.total) Zeilen.") : nil,
                                      items: [Item(id: "log", kind: .log, title: "", detail: shown.joined(separator: "\n"))]))
        return sections
    }

    // MARK: Einrichtung

    private func remoteSetupSections() -> [RemoteSection] {
        func state(_ s: CheckState) -> String {
            switch s {
            case .ok: return "ok"
            case .warning: return "warning"
            case .missing: return "missing"
            case .checking: return "checking"
            }
        }
        var xcode = [Item(id: "xcode", kind: .check, title: "Xcode",
                          detail: xcodeProblem ?? xcodeText.map { text in xcodeWarning.map { "\(text) \($0)" } ?? text } ?? L("Checking …", "Wird geprüft …"),
                          state: state(xcodeProblem != nil ? .missing : xcodeText == nil ? .checking : xcodeWarning != nil ? .warning : .ok))]
        if let newer = newerXcode, xcodeWarning != nil { xcode.append(Item(id: "xcode-select", kind: .text, title: "", detail: newer.selectCommand, style: .secondary)) }

        let deviceState: CheckState = device == nil ? (devices.count > 1 ? .warning : .missing) : (deviceProblem == nil ? .ok : .warning)
        var visionPro = [Item(id: "device", kind: .check, title: "Vision Pro",
                              detail: device.map { d in deviceProblem ?? L("\(d.name) with visionOS \(d.osVersion) is reachable", "\(d.name) mit visionOS \(d.osVersion) ist erreichbar")
                                  + (d.transport.map { L(" over \($0.text).", " über \($0.text).") } ?? ".") } ?? deviceProblem ?? L("Searching …", "Wird gesucht …"),
                              state: state(deviceState))]
        if devices.count > 1 {
            visionPro.append(Item(id: "chooseDevice", kind: .choice, title: L("Use this one", "Dieses benutzen"), value: device?.udid ?? "",
                                  choices: devices.map { RemoteChoice(id: $0.udid, title: "\($0.name) · visionOS \($0.osVersion)") }))
        }

        var team = [Item(id: "team", kind: .check, title: L("Apple Developer Team", "Apple-Entwicklerteam"), detail: setupTeamDetail, state: state(setupTeamState))]
        if teamCandidates.count > 1 || (!teamValid && !teamCandidates.isEmpty) {
            team.append(Item(id: "chooseTeam", kind: .choice, title: L("Team", "Team"), value: teamId,
                             choices: teamCandidates.map { RemoteChoice(id: $0.id, title: "\($0.name) – \($0.id)\($0.free ? L(" (free)", " (kostenlos)") : "")") }))
        }

        var meta = [Item(id: "meta", kind: .check, title: L("Meta Account (for Meta Store games)", "Meta-Konto (für Spiele aus dem Meta-Store)"),
                         detail: setupAccountDetail, state: state(setupAccountState))]
        if case .problem = account { meta.append(Item(id: "checkAccount", kind: .action, title: L("Check Again", "Erneut prüfen"))) }
        if account != .signedIn {
            meta.append(Item(id: "meta-signin", kind: .text, title: "", detail: L("Signing in happens on the Mac, under “Setup”.", "Angemeldet wird auf dem Mac, unter „Einrichtung“."), style: .secondary))
        }

        let steam = [Item(id: "steam", kind: .check, title: L("Steam Account (for games you bought on Steam)", "Steam-Konto (für Spiele, die du bei Steam gekauft hast)"),
                          detail: steamDetail, state: state(steamSignedIn ? .ok : .missing))]
        let toolchain = [Item(id: "toolchain", kind: .check, title: "Toolchain",
                              detail: toolchainText ?? L("Not installed yet. The toolchain translates the games for the Vision Pro.", "Noch nicht installiert. Die Toolchain übersetzt die Spiele für die Vision Pro."),
                              state: state(toolchainText == nil ? .missing : .ok))]
        return [
            RemoteSection(id: "refresh", title: nil, items: [
                refreshing ? Item(id: "refreshing", kind: .progress, title: L("Checking …", "Wird geprüft …"))
                           : Item(id: "refresh", kind: .action, title: L("Check Again", "Neu prüfen")),
            ]),
            RemoteSection(id: "xcode", title: nil, items: xcode),
            RemoteSection(id: "device", title: nil, items: visionPro),
            RemoteSection(id: "team", title: nil, items: team),
            RemoteSection(id: "meta", title: nil, items: meta),
            RemoteSection(id: "steam", title: nil, items: steam),
            RemoteSection(id: "toolchain", title: nil, items: toolchain),
        ]
    }

    // MARK: Einstellungen

    private func remoteSettingsSections() -> [RemoteSection] {
        var sections: [RemoteSection] = []
        sections.append(RemoteSection(id: "app", title: "AVP Play", items: [
            Item(id: "language", kind: .choice, title: L("Language on the Mac", "Sprache auf dem Mac"), value: languageChoice.rawValue,
                 choices: LanguageChoice.allCases.map { RemoteChoice(id: $0.rawValue, title: $0.title) }),
            Item(id: "autoUpdateCheck", kind: .toggle, title: L("Check for new versions once a day", "Einmal am Tag nach neuen Fassungen sehen"), on: autoUpdateCheck),
            Item(id: "version", kind: .fact, title: L("Version", "Version"), value: appVersion),
        ]))
        var controllers = [Item(id: "surrealSupport", kind: .toggle, title: L("Surreal Touch support", "Surreal-Touch-Unterstützung"), on: surrealSupport)]
        if surrealSupport {
            controllers.append(Item(id: "controllerMode", kind: .choice, title: L("Controller Type", "Controllertyp"), value: controllerMode.rawValue,
                                    choices: ControllerMode.allCases.map { RemoteChoice(id: $0.rawValue, title: $0.title) }))
        }
        if surrealSupport, controllerMode == .surreal, toolchain?.supportsSurrealControllers != true {
            controllers.append(Item(id: "surreal-note", kind: .text, title: "", detail: L("The selected toolchain does not include Surreal Touch yet.", "Die ausgewählte Toolchain enthält Surreal Touch noch nicht."), style: .warning))
        }
        sections.append(RemoteSection(id: "controllers", title: L("Controllers", "Controller"),
                                      footer: L("The initial choice for games you install or rebuild.", "Die erste Wahl für neu installierte oder neu gebaute Spiele."), items: controllers))
        sections.append(RemoteSection(id: "play", title: L("Play area", "Spielbereich"), items: [
            Item(id: "roomMeasuring", kind: .toggle, title: L("Measure room in the games that are installed", "„Raum vermessen“ in den Spielen, die installiert werden"),
                 on: roomMeasuringForNewGames),
        ]))
        let languages = [RemoteChoice(id: "", title: L("As each game has it", "Wie im jeweiligen Spiel")),
                         RemoteChoice(id: GameLanguage.device, title: GameLanguage.name(GameLanguage.device))]
            + GameLanguage.choices.map { RemoteChoice(id: $0.code, title: $0.name) }
        sections.append(RemoteSection(id: "gameLanguage", title: L("Game language", "Sprache der Spiele"), items: [
            Item(id: "gameLanguage", kind: .choice, title: L("Language games start with", "Sprache, mit der Spiele beginnen"), value: gameLanguageForNewGames, choices: languages),
        ]))
        sections.append(RemoteSection(id: "renew", title: L("Renew signatures", "Signaturen erneuern"), items: [
            Item(id: "renewInBackground", kind: .toggle, title: L("Check in the background and renew games before their signature runs out",
                                                                 "Im Hintergrund prüfen und Spiele erneuern, bevor ihre Signatur abläuft"), on: renewInBackground),
            Item(id: "renewInterval", kind: .choice, title: L("Check every", "Prüfen alle"), value: "\(renewIntervalHours)",
                 choices: BackgroundService.intervals.map { hours in
                     RemoteChoice(id: "\(hours)", title: hours == 1 ? L("hour", "Stunde") : L("\(hours) hours", "\(hours) Stunden"))
                 }, enabled: renewInBackground),
        ]))
        sections.append(RemoteSection(id: "catalog", title: L("Online catalogue", "Online-Katalog"), items: [
            Item(id: "onlineCatalog", kind: .toggle, title: L("Show more games from the online catalogue and allow feedback", "Weitere Spiele aus dem Online-Katalog zeigen und Rückmeldungen erlauben"), on: onlineCatalog),
            Item(id: "usageCounts", kind: .toggle, title: L("Let the project count how many people use AVP Play and which games they install", "Das Projekt zählen lassen, wie viele Leute AVP Play nutzen und welche Spiele sie installieren"),
                 on: usageCounts, enabled: onlineCatalog),
        ]))
        sections.append(RemoteSection(id: "saves", title: L("Saved Games", "Spielstände"), items: [
            Item(id: "syncSaves", kind: .toggle, title: L("Fetch saved games from the Vision Pro to the Mac by itself", "Spielstände von selbst von der Vision Pro auf den Mac holen"), on: syncSaves),
        ]))
        sections.append(RemoteSection(id: "pictures", title: L("Pictures", "Bilder"), items: [
            Item(id: "storePictures", kind: .toggle, title: L("Load pictures of games from the Meta Store and Steam", "Bilder der Spiele aus dem Meta-Store und von Steam laden"), on: storePictures),
        ]))
        sections.append(RemoteSection(id: "toolchains", title: L("Toolchains", "Toolchains"), items: [
            Item(id: "autoRemoveOldToolchains", kind: .toggle, title: L("Remove toolchain data that is no longer needed automatically", "Nicht mehr gebrauchte Toolchain-Daten automatisch entfernen"), on: autoRemoveOldToolchains),
        ]))
        var experimental = [Item(id: "metalFX", kind: .toggle, title: L("MetalFX: switch on upscaling automatically when installing", "MetalFX: Hochskalieren bei Installation automatisch einschalten"), on: metalFXUpscaling)]
        if metalFXUpscaling {
            experimental.append(Item(id: "metalFXResolution", kind: .choice, title: L("Resolution at the start", "Auflösung zu Beginn"), value: "\(metalFXResolution)",
                                     choices: stride(from: MetalFXResolution.range.lowerBound, through: MetalFXResolution.range.upperBound, by: 5).map { RemoteChoice(id: "\($0)", title: "\($0) %") }))
        }
        sections.append(RemoteSection(id: "experimental", title: L("Experimental", "Experimentell"), items: experimental))
        sections.append(RemoteSection(id: "more", title: nil, footer: L("The download folder, the app identifier prefix and the sign-ins are changed on the Mac.",
                                                                     "Ordner für Downloads, Präfix der App-Kennung und Anmeldungen änderst du auf dem Mac."), items: []))
        return sections
    }

    // MARK: Ausführen

    /// Führt aus, was auf einer Seite gewählt wurde; zurück kommt, was im Weg stand.
    func remotePanelAction(panel: String, item: String, value: String?, cache: RemotePanelCache) -> String? {
        let on = value == "1"
        if panel.hasPrefix("game:") {
            guard let game = allGames.first(where: { $0.id == panel.dropFirst(5) }) else {
                return L("This game is not in the list on the Mac.", "Dieses Spiel steht auf dem Mac nicht in der Liste.")
            }
            return remoteGameAction(game, item: item, value: value, on: on, cache: cache)
        }
        if panel.hasPrefix("job:") {
            guard let job = jobs.first(where: { $0.id == panel.dropFirst(4) }) else {
                return L("This job is not in the list on the Mac.", "Dieser Auftrag steht auf dem Mac nicht in der Liste.")
            }
            let phase = phase(of: job)
            switch item {
            case "resume":
                guard phase.canResume, job.failureKind?.resumable ?? true else { return L("This job cannot be resumed.", "Dieser Auftrag lässt sich nicht fortsetzen.") }
                resume(job)
            case "cancel":
                guard phase.canCancel else { return L("This job is no longer running.", "Dieser Auftrag läuft nicht mehr.") }
                cancel(job)
            default: return nil
            }
            return nil
        }
        if panel == "setup" {
            switch item {
            case "refresh": refresh()
            case "checkAccount": checkAccount()
            case "chooseDevice":
                guard let value, devices.contains(where: { $0.udid == value }) else { return nil }
                chosenDevice = value
                refresh()
            case "chooseTeam":
                guard let value, teamCandidates.contains(where: { $0.id == value }) else { return nil }
                teamId = value
            default: break
            }
            return nil
        }
        if panel == "settings" {
            switch item {
            case "language": if let value, let choice = LanguageChoice(rawValue: value) { languageChoice = choice }
            case "autoUpdateCheck": autoUpdateCheck = on
            case "controllerMode": if let value, let mode = ControllerMode(rawValue: value) { controllerMode = mode }
            case "surrealSupport": surrealSupport = on
            case "roomMeasuring": roomMeasuringForNewGames = on
            case "gameLanguage": if let value { gameLanguageForNewGames = value }
            case "renewInBackground":
                renewInBackground = on
                applyBackgroundService()
            case "renewInterval":
                if let value, let hours = Int(value), BackgroundService.intervals.contains(hours) {
                    renewIntervalHours = hours
                    if renewInBackground { applyBackgroundService() }
                }
            case "onlineCatalog":
                onlineCatalog = on
                loadCatalog()
            case "usageCounts": usageCounts = on
            case "syncSaves": syncSaves = on
            case "storePictures": storePictures = on
            case "autoRemoveOldToolchains": autoRemoveOldToolchains = on
            case "metalFX":
                setMetalFXUpscaling(on)
                refresh()
            case "metalFXResolution": if let value, let percent = Int(value) { metalFXResolution = MetalFXResolution.clamped(percent) }
            default: break
            }
            return nil
        }
        return nil
    }

    private func remoteGameAction(_ game: Game, item: String, value: String?, on: Bool, cache: RemotePanelCache) -> String? {
        switch item {
        case "favourite":
            if isFavourite(game) != on { toggleFavourite(game) }
        case _ where item.hasPrefix("filter:"):
            setMembership([game.id], in: String(item.dropFirst(7)), member: on)
        case "source":
            guard let value, let source = Recipe.Source(rawValue: value), game.sources.contains(source) else { return nil }
            chooseSource(game, source)
        case "version":
            guard let value, let code = Int(value) else { return nil }
            chooseVersion(game, versionCode: code)
        case "useTested": useTestedVersion(game)
        case "useNewest": useNewestVersion(game)
        case "removeFiles":
            guard !isBusy(game.id) else { return L("A job for this game is running.", "Für dieses Spiel läuft gerade ein Auftrag.") }
            removeFiles(game)
        case "fetchSaves": fetchSaves(game)
        case "restoreSaves":
            if let why = restoreBlocker(for: game) { return why }
            restoreSaves(game)
        case "restoreOnInstall":
            var next = options(for: game)
            next.restoreSaves = on
            setOptions(next, for: game)
        case _ where item.hasPrefix("locale:"):
            let locale = String(item.dropFirst(7))
            var next = options(for: game)
            next.locales = on ? Array(Set(next.locales + [locale])).sorted() : next.locales.filter { $0 != locale }
            setOptions(next, for: game)
        case _ where item.hasPrefix("extra:"):
            let name = String(item.dropFirst(6))
            var next = options(for: game)
            next.optionalNames = on ? Array(Set(next.optionalNames + [name])).sorted() : next.optionalNames.filter { $0 != name }
            setOptions(next, for: game)
        case "addons":
            var next = options(for: game)
            next.addons = on
            setOptions(next, for: game)
        case "syncAddons":
            if let why = syncBlocker(for: game) { return why }
            syncAddons(game)
        case "syncExtras":
            if let why = extrasBlocker(for: game) { return why }
            syncExtras(game)
        case "toolchain":
            guard let value, let option = ToolchainBox.all(toolchainOptions(game, cache: cache)).first(where: { $0.id == value }) else { return nil }
            chooseToolchain(game, option)
            return toolchainNote[game.id]
        case "loadReleased": loadReleasedToolchains()
        case "checkPurchase": checkPurchase(game)
        case _ where item.hasPrefix("feedback:"):
            guard let result = CatalogFeedback.Result(rawValue: String(item.dropFirst(9))) else { return nil }
            sendFeedback(game, result: result, comment: value ?? "")
        default: break
        }
        return nil
    }
}

private extension String {
    /// „es läuft“ → „Es läuft“: die Beschriftung der Rückmeldung als Knopf.
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

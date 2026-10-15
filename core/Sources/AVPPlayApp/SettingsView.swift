import AVPPlayCore
import SwiftUI

/// Welche Sprache das Programm spricht: die des Systems oder eine fest gewählte.
enum LanguageChoice: String, CaseIterable, Identifiable {
    case system, en, de
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return L("Same as macOS", "Wie macOS")
        case .en: return "English"
        case .de: return "Deutsch"
        }
    }
}

/// Die Einstellungen des Programms (⌘,), als letzte Seite des Hauptfensters: Sprache, Katalog, Downloads, das
/// Erneuern der Signaturen und, für Leute die es brauchen, die Kennung der Apps.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var prefixDraft = ""

    var body: some View {
        Form {
            Section {
                Picker(L("Language", "Sprache"), selection: Binding(get: { model.languageChoice }, set: { model.languageChoice = $0 })) {
                    ForEach(LanguageChoice.allCases) { Text($0.title).tag($0) }
                }
                Text(L("Menus that macOS provides itself switch the next time you open the app.",
                       "Menüs, die macOS selbst stellt, wechseln beim nächsten Öffnen des Programms."))
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section(L("Updates", "Aktualisierung")) {
                Toggle(L("Check for new versions once a day", "Einmal am Tag nach neuen Fassungen sehen"),
                       isOn: Binding(get: { model.autoUpdateCheck }, set: { model.autoUpdateCheck = $0 }))
                HStack {
                    Text(L("This is version \(model.appVersion).", "Dies ist Version \(model.appVersion)."))
                    Spacer()
                    switch model.updateState {
                    case .checking: ProgressView().controlSize(.small)
                    case .upToDate: Text(L("Up to date", "Aktuell")).foregroundStyle(.secondary)
                    case .failed(let why): Text(why).foregroundStyle(.orange).lineLimit(2).help(why)
                    default:
                        if let release = model.update {
                            Text(L("Version \(release.version) is available", "Version \(release.version) ist da")).foregroundStyle(.secondary)
                        }
                    }
                    Button(L("Check Now", "Jetzt nachsehen")) { Task { await model.checkForUpdate(manual: true) } }
                        .disabled([.checking, .downloading, .installing].contains(model.updateState))
                }
                if let release = model.update {
                    HStack {
                        switch model.updateState {
                        case .downloading:
                            ProgressView().controlSize(.small)
                            Text(L("Downloading version \(release.version) …", "Version \(release.version) wird geladen …"))
                        case .installing:
                            ProgressView().controlSize(.small)
                            Text(L("Checking and installing …", "Wird geprüft und eingespielt …"))
                        default:
                            Button(model.canSelfUpdate ? L("Install Version \(release.version) and Relaunch", "Version \(release.version) einspielen und neu starten")
                                                       : L("Open Download Page", "Download-Seite öffnen")) {
                                Task { await model.installUpdate() }
                            }
                            .buttonStyle(.borderedProminent)
                            Link(L("What’s new", "Was ist neu"), destination: release.page)
                        }
                        Spacer()
                    }
                }
                Text(L("The check asks GitHub for the latest release of AVP Play and sends nothing else. A new version is only installed if it is signed by the same developer and notarised by Apple.",
                       "Dabei wird GitHub nach der neuesten Veröffentlichung von AVP Play gefragt, sonst wird nichts gesendet. Eine neue Fassung wird nur eingespielt, wenn sie vom selben Entwickler signiert und von Apple beglaubigt ist."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            RenewalSettings()

            Section(L("Online catalogue", "Online-Katalog")) {
                Toggle(L("Show more games from the online catalogue and allow feedback", "Weitere Spiele aus dem Online-Katalog zeigen und Rückmeldungen erlauben"),
                       isOn: Binding(get: { model.onlineCatalog }, set: { model.onlineCatalog = $0; model.loadCatalog() }))
                Text(L("The catalogue is a small service of this project (avpplay.martek.de). The app sends it what you search for and the identifiers of games you open; a report you choose to send contains the game, its build and your answer. It never receives your Meta sign-in or anything about your account or device.",
                       "Der Katalog ist ein kleiner Dienst dieses Projekts (avpplay.martek.de). Die App schickt ihm, wonach du suchst, und die Kennungen der Spiele, die du öffnest; eine Rückmeldung, die du abschickst, enthält das Spiel, seinen Build und deine Antwort. Deine Meta-Anmeldung oder etwas über dein Konto oder Gerät bekommt er nie."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(L("Let the project count how many people use AVP Play and which games they install", "Das Projekt zählen lassen, wie viele Leute AVP Play nutzen und welche Spiele sie installieren"),
                       isOn: Binding(get: { model.usageCounts }, set: { model.usageCounts = $0 }))
                    .disabled(!model.onlineCatalog)
                Text(L("Once a day the app tells the catalogue that it is in use, with its version number, and once per game that you have installed it. Neither message carries an identifier of you, this Mac or your Vision Pro, and the service keeps nothing but totals per day.",
                       "Einmal am Tag sagt die App dem Katalog, dass sie in Gebrauch ist, mit ihrer Versionsnummer, und einmal pro Spiel, dass du es installiert hast. Keine der beiden Meldungen trägt eine Kennung von dir, diesem Mac oder deiner Vision Pro, und der Dienst behält nichts als Summen pro Tag."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L("Saved Games", "Spielstände")) {
                Toggle(L("Fetch saved games from the Vision Pro to this Mac by itself", "Spielstände von selbst von der Vision Pro auf diesen Mac holen"),
                       isOn: Binding(get: { model.syncSaves }, set: { model.syncSaves = $0 }))
                Text(L("While AVP Play is open, it asks the Vision Pro every few minutes which game is running. After you quit a game, and every few hours for all installed games, it copies what the game has saved to this Mac – a new copy each time something has changed. With the background service for signatures turned on, this also happens while AVP Play is closed. Nothing leaves this Mac: the copies are kept in “\(SaveStore.folderName)” next to the downloads folder if you have chosen one, otherwise with the app's data. If a game is installed again and has no saved games on the headset, the last copy is put back; each game's page has the switch for that, and the buttons to fetch and to put back by hand. Games that run as Linux programs (Half-Life: Alyx) are not covered yet.",
                       "Solange AVP Play offen ist, fragt es die Vision Pro alle paar Minuten, welches Spiel läuft. Nachdem du ein Spiel beendet hast, und alle paar Stunden für alle installierten Spiele, kopiert es auf diesen Mac, was das Spiel gespeichert hat – jedes Mal eine neue Kopie, wenn sich etwas geändert hat. Ist der Hintergrunddienst für Signaturen eingeschaltet, passiert das auch, während AVP Play geschlossen ist. Nichts verlässt diesen Mac: Die Kopien liegen in „\(SaveStore.folderName)“ neben dem Ordner für Downloads, wenn du einen gewählt hast, sonst bei den Daten der App. Wird ein Spiel neu installiert und hat auf dem Headset keine Spielstände, wird die letzte Kopie zurückgespielt; die Seite jedes Spiels hat den Schalter dafür und die Knöpfe zum Holen und Zurückspielen von Hand. Spiele, die als Linux-Programm laufen (Half-Life: Alyx), sind noch nicht dabei."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(L("Fetch Now", "Jetzt holen")) { model.fetchAllSaves() }.disabled(!model.savesBusy.isEmpty || model.device == nil)
                    Button(L("Show in Finder", "Im Finder zeigen")) {
                        let folder = model.paths.saves.root
                        if model.storeBlocker == nil { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                    .disabled(model.storeBlocker != nil)
                    if !model.savesBusy.isEmpty { ProgressView().controlSize(.small) }
                }
            }

            Section(L("Pictures", "Bilder")) {
                Toggle(L("Load pictures of games from the Meta Store", "Bilder der Spiele aus dem Meta-Store laden"), isOn: $model.storePictures)
                Text(L("For games whose files are not on this Mac yet, the app fetches the picture from the game's public page in the Meta Store (meta.com) – only for games you are looking at, without your Meta sign-in, and keeps a small copy in a cache that the Data page can empty. For the few games whose store page shows no picture, it comes from the project's catalogue service. Without this, such games show a coloured tile with their name.",
                       "Für Spiele, deren Dateien noch nicht auf diesem Mac liegen, holt die App das Bild von der öffentlichen Seite des Spiels im Meta-Store (meta.com) – nur für Spiele, die du gerade siehst, ohne deine Meta-Anmeldung, und hält eine kleine Kopie in einem Zwischenspeicher, den die Datenverwaltung leeren kann. Für die wenigen Spiele, deren Store-Seite kein Bild zeigt, kommt es vom Katalogdienst des Projekts. Ohne das zeigen solche Spiele eine farbige Fläche mit ihrem Namen."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L("Downloads", "Downloads")) {
                StoreLocationBox()
                Text(L("Downloaded games are kept here – easily tens of gigabytes each. You can choose a folder on another disk, for example an external one; the games already downloaded move there. While that disk is not connected, nothing is downloaded or installed. Under “Data” in the main window you see what is stored and can remove it.",
                       "Hier liegen die heruntergeladenen Spiele – schnell zweistellige Gigabyte pro Spiel. Du kannst einen Ordner auf einer anderen Platte wählen, etwa einer externen; die schon geladenen Spiele ziehen dorthin um. Solange diese Platte nicht angeschlossen ist, wird nichts geladen oder installiert. Unter „Datenverwaltung“ im Hauptfenster siehst du, was gespeichert ist, und kannst es entfernen."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L("Toolchains", "Toolchains")) {
                Toggle(L("Remove toolchain data that is no longer needed automatically", "Nicht mehr gebrauchte Toolchain-Daten automatisch entfernen"),
                       isOn: $model.autoRemoveOldToolchains)
                Text(L("A toolchain is what turns a game into an app for the Vision Pro, and it grows by gigabytes with every game it builds. Games are built with the newest one, unless you chose another for a game on its page. Once a newer toolchain is installed, the older ones and everything they built are removed from this Mac – except one that is chosen for a game. Turn this off if you work on toolchains yourself or want to keep older ones at hand. In the newest one, what a game left behind when it was built is removed once that build is more than a week old; building it again later then takes about a minute longer. Nothing is removed while a job is running, and nothing on the Vision Pro or among your downloads is touched.",
                       "Eine Toolchain macht aus einem Spiel eine App für die Vision Pro und wächst mit jedem Spiel, das sie baut, um Gigabytes. Gebaut wird mit der neuesten, außer du hast für ein Spiel auf seiner Seite eine andere gewählt. Sobald eine neuere installiert ist, werden die älteren samt allem, was sie gebaut haben, von diesem Mac entfernt – außer einer, die für ein Spiel gewählt ist. Schalte das aus, wenn du selbst an Toolchains arbeitest oder ältere griffbereit halten willst. In der neuesten fällt weg, was ein Spiel beim Bauen hinterlassen hat, sobald dieser Bau über eine Woche her ist; ein späterer Neubau dauert dann etwa eine Minute länger. Nichts wird entfernt, während ein Auftrag läuft, und weder die Vision Pro noch deine Downloads werden angefasst."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L("Experimental", "Experimentell")) {
                Toggle(L("Experimental: switch on the new pose and audio implementations automatically when installing",
                         "Experimentell: Automatisch die neue Pose- und Audio-Implementierung bei Installation aktivieren"),
                       isOn: Binding(get: { model.experimentalImplementations },
                                     set: { model.experimentalImplementations = $0; model.refresh() }))
                Text(L("The toolchain carries a second implementation for two things every game runs on – the head pose a game gets for a frame, and everything between a game's sound and the output – as test switches that are normally off. With this on, every game you install or update has both switched on from the start, as if the old ones were gone; in a game they can still be turned off under Settings › Advanced › Test. Games that are already installed then show “Update available”: “Update All” on the Games page rebuilds them, and the same again after you turn this off. Saved games and data are kept. A game with a toolchain of its own choosing is left as it is.",
                       "Die Toolchain bringt für zwei Dinge, auf denen jedes Spiel läuft, eine zweite Implementierung mit – die Kopfpose, die ein Spiel für einen Frame bekommt, und alles zwischen dem Ton eines Spiels und der Ausgabe –, als Test-Schalter, die normalerweise aus sind. Hiermit sind in jedem Spiel, das du installierst oder aktualisierst, beide von Anfang an eingeschaltet, als wären die bisherigen schon entfernt; im Spiel lassen sie sich unter Einstellungen › Erweitert › Test weiterhin ausschalten. Schon installierte Spiele zeigen dann „Aktualisierung möglich“: „Alle aktualisieren“ auf der Seite Spiele baut sie neu, und ebenso, nachdem du das hier wieder ausschaltest. Spielstände und Daten bleiben. Ein Spiel mit eigens gewählter Toolchain bleibt, wie es ist."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.toolchain != nil, model.experimentalExpected == nil {
                    Text(L("The installed toolchain cannot do this yet; it takes effect with a newer one.",
                           "Die installierte Toolchain kann das noch nicht; es wirkt mit einer neueren."))
                        .font(.callout).foregroundStyle(.orange)
                }
                Toggle(L("MetalFX: switch on upscaling automatically when installing",
                         "MetalFX: Hochskalieren bei Installation automatisch einschalten"),
                       isOn: Binding(get: { model.metalFXUpscaling },
                                     set: { model.setMetalFXUpscaling($0); model.refresh() }))
                if model.metalFXUpscaling {
                    LabeledContent(L("Resolution at the start", "Auflösung zu Beginn")) {
                        HStack {
                            Slider(value: Binding(get: { Double(model.metalFXResolution) },
                                                  set: { model.metalFXResolution = MetalFXResolution.clamped(Int($0)) }),
                                   in: Double(MetalFXResolution.range.lowerBound)...Double(MetalFXResolution.range.upperBound),
                                   step: 5)
                            Text("\(model.metalFXResolution) %").monospacedDigit().frame(width: 48, alignment: .trailing)
                        }
                    }
                }
                Text(L("When a game's resolution (its start window › Settings) is below 100%, the game draws a smaller picture and the Vision Pro stretches it to the size of the display. With this on, every game you install or update starts with Apple's MetalFX scaler doing that stretch instead of a plain linear one: the same pixels in, a sharper picture out, for a little graphics time. At 100% there is nothing to upscale, so switching this on sets the resolution a game starts at to 75% (the slider below; your own value counts once you change it, and switching off brings back the one from before, or 100%). What is chosen in a game itself counts there. It works in every game: Vulkan and GL, through Meta's own interface or OpenXR (Half-Life: Alyx, Steam Link, Doom 3, Walkabout, Beat Saber 1.45), with foveated rendering on, too; only where the picture cannot be scaled safely does the game keep the linear stretch. The metrics panel in the headset (Create + Options held for a second) shows the resolution the game renders at, whether MetalFX is upscaling and on which path, and the resolution after it. In a game it can still be switched off under Settings › Rendering › MetalFX upscaling. Games that are already installed then show “Update available”, as with the switch above.",
                       "Steht die Auflösung eines Spiels (Startfenster › Einstellungen) unter 100 %, zeichnet das Spiel ein kleineres Bild, und die Vision Pro streckt es auf die Größe des Displays. Hiermit beginnt jedes Spiel, das du installierst oder aktualisierst, damit, dass Apples MetalFX-Scaler das übernimmt statt einer einfachen linearen Streckung: dieselben Bildpunkte hinein, ein schärferes Bild heraus, für etwas Grafikzeit. Bei 100 % gibt es nichts hochzuskalieren; darum belegt das Einschalten die Auflösung, mit der ein Spiel beginnt, mit 75 % vor (der Regler darunter; ein eigener Wert gilt, sobald du ihn änderst, und das Ausschalten stellt den von davor wieder her, sonst 100 %). Was in einem Spiel selbst gewählt ist, gilt dort. Es wirkt in jedem Spiel: Vulkan und GL, über Metas eigene Schnittstelle oder über OpenXR (Half-Life: Alyx, Steam Link, Doom 3, Walkabout, Beat Saber 1.45), auch mit eingeschaltetem Foveated Rendering; nur wo sich das Bild nicht sicher skalieren lässt, bleibt es bei der linearen Streckung. Das Leistungs-Panel in der Brille (Create + Options eine Sekunde halten) zeigt die Auflösung, in der das Spiel rendert, ob und auf welchem Pfad MetalFX hochskaliert, und die Auflösung danach. Im Spiel lässt es sich unter Einstellungen › Rendering › MetalFX upscaling weiterhin ausschalten. Schon installierte Spiele zeigen dann „Aktualisierung möglich“, wie beim Schalter darüber."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.toolchain != nil, model.metalFXExpected == nil {
                    Text(L("The installed toolchain cannot do this yet (it needs the compositor's MetalFX upscaling and a way for an installation to switch it on); it takes effect with a newer one.",
                           "Die installierte Toolchain kann das noch nicht (sie braucht das MetalFX-Hochskalieren im Compositor und einen Weg, es bei der Installation einzuschalten); es wirkt mit einer neueren."))
                        .font(.callout).foregroundStyle(.orange)
                }
            }

            Section(L("Advanced", "Erweitert")) {
                LabeledContent(L("App identifier prefix", "Präfix der App-Kennung")) {
                    TextField("", text: $prefixDraft, prompt: Text(Toolchain.defaultBundlePrefix()))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(width: 260)
                        .onSubmit(applyPrefix)
                }
                Text(L("Every game is installed under this prefix plus its own name, for example \(model.bundlePrefix).doom3quest. Leave it empty for the default, which starts with your macOS user name.",
                       "Jedes Spiel wird unter diesem Präfix und seinem eigenen Namen installiert, zum Beispiel \(model.bundlePrefix).doom3quest. Leer lassen für den Standard, der mit deinem macOS-Benutzernamen beginnt."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L("If you change it, the Vision Pro treats every game as a new app: the one installed before stays next to it, and game data is copied again.",
                       "Wenn du es änderst, sieht die Vision Pro jedes Spiel als neue App: die bisher installierte bleibt daneben stehen, und die Spieldaten werden neu kopiert."))
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(L("Apply", "Übernehmen"), action: applyPrefix)
                        .disabled(!prefixDraft.isEmpty && !Toolchain.isValidBundlePrefix(prefixDraft))
                    Button(L("Use Default", "Standard verwenden")) {
                        prefixDraft = ""
                        applyPrefix()
                    }
                    .disabled(model.customBundlePrefix.isEmpty)
                    if !prefixDraft.isEmpty, !Toolchain.isValidBundlePrefix(prefixDraft) {
                        Text(L("Letters, digits, hyphens and dots only, like com.example.games.",
                               "Nur Buchstaben, Ziffern, Bindestriche und Punkte, etwa com.example.games."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .navigationTitle(L("Settings", "Einstellungen"))
        .onAppear {
            prefixDraft = model.customBundlePrefix
            model.renewalReport = RenewalReport.load()
        }
    }

    private func applyPrefix() {
        guard prefixDraft.isEmpty || Toolchain.isValidBundlePrefix(prefixDraft) else { return }
        model.customBundlePrefix = prefixDraft
        model.refresh()
    }
}
